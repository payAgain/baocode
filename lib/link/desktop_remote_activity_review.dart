part of 'desktop_remote_activity.dart';

typedef _Change = ({
  String path,
  String kind,
  int? added,
  int? removed,
  bool binary,
  bool untracked,
  bool conflict,
  String? revision,
  bool? undoable,
  bool preview,
});

enum _ReviewError { unconfirmed, stale, unsupported, conflict, busy, failed }

class _ReviewRequest {
  Timer? deadline;
}

class _ReviewPreview {
  _ReviewPreview(this.change, {required this.fromStrip});

  final _Change change;
  final bool fromStrip;
  (String, String)? diff;
  String? error;
  bool downloading = false;
  String? downloadStatus;
}

Map<String, _Change> _parseChanges(Object? value) {
  int? count(Object? value) => value is int && value >= 0 ? value : null;
  return {
    if (value case final List<Object?> list)
      for (final raw in list)
        if (raw case {'path': final String path} when path.isNotEmpty)
          path: (
            path: path,
            kind: switch (raw['kind']) {
              final String kind => kind,
              _ => 'modified',
            },
            added: count(raw['added']),
            removed: count(raw['removed']),
            binary: raw['binary'] == true,
            untracked: raw['tracked'] == false,
            conflict: raw['conflict'] == true,
            revision: switch (raw['revision']) {
              final String revision when revision.isNotEmpty => revision,
              _ => null,
            },
            undoable: switch (raw['undoable']) {
              final bool undoable => undoable,
              _ => null,
            },
            preview: raw['preview'] == true && raw['binary'] != true,
          ),
  };
}

// The bridge sends POSIX paths relative to this project, or an absolute
// host path for changes outside it. Only the former are actionable here.
bool _projectRelative(String path) =>
    !path.contains(r'\') &&
    !path.contains('\u0000') &&
    !RegExp(r'^[A-Za-z]:').hasMatch(path) &&
    path
        .split('/')
        .every((part) => part.isNotEmpty && part != '.' && part != '..');

bool _canStripReview(_Change change, {required bool keep}) =>
    _projectRelative(change.path) &&
    change.revision != null &&
    (keep || !change.untracked && change.undoable == true);

extension _ChangeReview on _DesktopRemoteActivityState {
  void _clearReviews() {
    for (final request in _reviewing.values) {
      request.deadline?.cancel();
    }
    _reviewing.clear();
    _reviewErrors.clear();
    _reviewPreview = null;
  }

  void _syncReviews() {
    final changes = widget.session?._changes ?? const {};
    _reviewing.removeWhere((path, request) {
      if (changes.containsKey(path)) return false;
      request.deadline?.cancel();
      return true;
    });
    _reviewErrors.removeWhere((path, _) => !changes.containsKey(path));
    if (_reviewPreview case final preview?
        when changes[preview.change.path] != preview.change) {
      _reviewPreview = null;
    }
  }

  bool _reviewSurface(DesktopRemoteActivitySession session, bool fromStrip) =>
      _current(session) && (fromStrip || _open && _section == _Section.changes);

  Future<void> _review(
    DesktopRemoteActivitySession session,
    _Change change, {
    required bool keep,
    bool fromStrip = false,
    bool header = false,
  }) async {
    final path = change.path;
    bool canReview() =>
        _reviewSurface(session, fromStrip) &&
        session._changes[path] == change &&
        (!header || session._changes.length == 1) &&
        !_reviewing.containsKey(path) &&
        (fromStrip
            ? _canStripReview(change, keep: keep)
            : _projectRelative(path) && (keep || change.undoable != false));
    if (!canReview()) return;
    final text = _ActivityText(context);
    final host = widget.hostName;
    final action = switch ((keep, header)) {
      (true, true) => context.l10n.stripKeepAll,
      (false, true) => context.l10n.stripUndoAll,
      (true, false) => text.keep,
      (false, false) => text.undo,
    };
    if (!await _confirm(
      session,
      action: action,
      description: keep
          ? text.keepDescription(host)
          : text.undoDescription(host),
      target: path,
    )) {
      return;
    }
    if (!canReview()) {
      if (_reviewSurface(session, fromStrip) &&
          session._changes.containsKey(path) &&
          (session._changes[path] != change ||
              (header && session._changes.length != 1))) {
        _changeState(() => _reviewErrors[path] = _ReviewError.stale);
      }
      return;
    }

    final request = _ReviewRequest();
    _changeState(() {
      _reviewErrors.remove(path);
      _reviewing[path] = request;
    });
    void fail(_ReviewError error) {
      if (!mounted ||
          !identical(widget.session, session) ||
          !identical(_reviewing[path], request)) {
        return;
      }
      _changeState(() {
        request.deadline?.cancel();
        _reviewing.remove(path);
        if (session._available && session._changes.containsKey(path)) {
          _reviewErrors[path] = error;
        }
      });
    }

    try {
      await session.peer.call(keep ? LinkMethods.keep : LinkMethods.undo, {
        'session': session.session,
        'paths': [path],
        'expectedChange': ?change.revision,
      });
      // Legacy hosts can acknowledge without effect. Bound the wait for
      // the followed change to disappear and leave the host row intact.
      if (identical(_reviewing[path], request)) {
        request.deadline = Timer(
          const Duration(seconds: 10),
          () => fail(_ReviewError.unconfirmed),
        );
      }
    } on TimeoutException {
      fail(_ReviewError.unconfirmed);
    } on LinkRemoteException catch (error) {
      fail(switch (error.code) {
        'stale' || LinkErrors.notFound => _ReviewError.stale,
        LinkErrors.unsupported => _ReviewError.unsupported,
        'conflict' => _ReviewError.conflict,
        LinkErrors.busy => _ReviewError.busy,
        _ => _ReviewError.failed,
      });
    } on Object {
      fail(_ReviewError.failed);
    }
  }

  Future<void> _previewChange(
    DesktopRemoteActivitySession session,
    _Change change, {
    bool fromStrip = false,
  }) async {
    final path = change.path;
    final revision = change.revision;
    if (!_reviewSurface(session, fromStrip) ||
        session._changes[path] != change ||
        _reviewPreview?.change == change) {
      return;
    }
    final text = _ActivityText(context);
    final preview = _ReviewPreview(change, fromStrip: fromStrip);
    if (!_projectRelative(path)) {
      if (!fromStrip) return;
      preview.error = text.outsideProject;
    } else if (revision == null || !change.preview) {
      preview.error = change.binary
          ? text.binaryPreview
          : text.previewUnavailable;
    }
    _changeState(() => _reviewPreview = preview);
    if (revision == null || preview.error != null) return;

    (String, String)? diff;
    String? error;
    try {
      final response = await session.peer.call(LinkMethods.read, {
        'session': session.session,
        'path': path,
        'expectedChange': revision,
      });
      if (response
          case {'original': final String before, 'text': final String after}
          when before.length <= LinkLimits.file &&
              after.length <= LinkLimits.file) {
        diff = (before, after);
      } else {
        error = switch (response) {
          {'binary': true} => text.binaryPreview,
          {'tooLarge': true} ||
          {'original': String(), 'text': String()} => text.largePreview,
          _ => text.previewUnavailable,
        };
      }
    } on LinkRemoteException catch (failure) {
      error = switch (failure.code) {
        'stale' || LinkErrors.notFound => text.reviewError(_ReviewError.stale),
        LinkErrors.unsupported || LinkErrors.unknown => text.previewUnavailable,
        _ => text.actionFailed,
      };
    } on Object {
      error = text.actionFailed;
    }
    if (!_currentReview(session, preview)) return;
    _changeState(() {
      preview.diff = diff;
      preview.error = error;
    });
  }

  bool _currentReview(
    DesktopRemoteActivitySession session,
    _ReviewPreview preview,
  ) =>
      identical(_reviewPreview, preview) &&
      _reviewSurface(session, preview.fromStrip) &&
      session._changes[preview.change.path] == preview.change;

  Future<void> _downloadChangeFile(
    DesktopRemoteActivitySession session,
    _ReviewPreview preview,
  ) async {
    bool current() => _currentReview(session, preview);
    if (preview.downloading || !current()) return;
    final l10n = context.l10n;
    final text = _ActivityText(context);
    _changeState(() {
      preview.downloading = true;
      preview.downloadStatus = null;
    });
    try {
      final saved = await downloadRemoteFile(
        peer: session.peer,
        project: session.projectId,
        path: preview.change.path,
        isCurrent: current,
      );
      if (saved && current()) preview.downloadStatus = text.fileSaved;
    } on Object catch (error) {
      if (current()) preview.downloadStatus = remoteMediaError(l10n, error);
    } finally {
      if (current()) _changeState(() => preview.downloading = false);
    }
  }

  Widget _reviewPane(
    _ActivityText text,
    DesktopRemoteActivitySession session,
    _ReviewPreview preview, {
    required bool compact,
  }) => Material(
    key: const ValueKey('desktop-remote-diff-editor'),
    color: AppColors.code,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ActivityBar(
          leading: _ActivityIconButton(
            tooltip: preview.fromStrip ? text.closeDiff : text.backToChanges,
            icon: compact ? Codicons.arrowLeft : Codicons.close,
            onPressed: () => _changeState(() => _reviewPreview = null),
          ),
          label: preview.change.path,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Tooltip(
                message: text.readOnlyDiff,
                child: Text(context.l10n.shownReadOnly, style: _activityDetail),
              ),
              if (WindowControls.canPickFiles &&
                  preview.change.kind != 'deleted' &&
                  remoteRelativePath(preview.change.path))
                _ActivityIconButton(
                  icon: Codicons.cloudDownload,
                  tooltip: text.downloadCurrentFile,
                  onPressed: preview.downloading
                      ? null
                      : () => _downloadChangeFile(session, preview),
                ),
            ],
          ),
        ),
        _activityRule(),
        if (preview.downloadStatus case final status?)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Text(status, style: _activityDetail),
          ),
        Expanded(
          child: switch (preview) {
            _ReviewPreview(diff: (final before, final after)) => IdeCodeDiff(
              key: ObjectKey(preview),
              path: preview.change.path,
              original: before,
              modified: after,
              sideBySide: compact ? false : null,
            ),
            _ReviewPreview(error: final error?) => _ActivityNotice(
              icon: Codicons.warning,
              label: error,
            ),
            _ => _ActivityNotice(icon: Codicons.diff, label: text.loading),
          },
        ),
      ],
    ),
  );

  Widget _changes(_ActivityText text, DesktopRemoteActivitySession session) {
    final changes = session._changes.values.toList();
    if (changes.isEmpty) {
      return _ActivityNotice(icon: Codicons.diff, label: text.noChanges);
    }
    return _activityList(
      key: const ValueKey(_Section.changes),
      count: changes.length,
      itemBuilder: (context, index) {
        final change = changes[index];
        final pending = _reviewing.containsKey(change.path);
        final counts = [
          if (change.added case final added?) '+$added',
          if (change.removed case final removed?) '−$removed',
        ].join(' ');
        final inProject = _projectRelative(change.path);
        final selected = _reviewPreview?.change == change;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              IdeListRow(
                key: ValueKey(('remote-change', change.path)),
                tooltip: change.path,
                selected: selected,
                height: math.max(
                  IdeListColors.rowHeight,
                  MediaQuery.textScalerOf(context).scale(13) * 1.45,
                ),
                onTap: inProject ? () => _previewChange(session, change) : null,
                builder: (context, hovered) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    spacing: 6,
                    children: [
                      FileIcon(change.path.split('/').last),
                      Expanded(
                        child: Text(
                          change.path,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: _activityTitle.copyWith(
                            color: selected
                                ? IdeListColors.inactiveSelectionForeground
                                : hovered
                                ? IdeListColors.hoverForeground
                                : IdeListColors.foreground,
                          ),
                        ),
                      ),
                      if (counts.isNotEmpty)
                        Text(counts, style: _activityDetail),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 30, end: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      [
                        text.changeKind(change.kind),
                        if (change.binary) text.binary,
                        if (change.untracked) text.untracked,
                        if (change.conflict) text.conflict,
                      ].join(' · '),
                      style: _activityDetail,
                    ),
                    if (pending)
                      Text(text.awaitingHost, style: _activityDetail)
                    else if (inProject)
                      Wrap(
                        spacing: 4,
                        children: [
                          if (change.preview && change.revision != null)
                            _ActivityAction(
                              label: text.previewDiff,
                              onPressed: () => _previewChange(session, change),
                            ),
                          _ActivityAction(
                            label: text.keep,
                            onPressed: () =>
                                _review(session, change, keep: true),
                            secondary: true,
                          ),
                          _ActivityAction(
                            label: text.undo,
                            onPressed: change.undoable != false
                                ? () => _review(session, change, keep: false)
                                : null,
                            secondary: true,
                          ),
                        ],
                      )
                    else
                      Text(text.outsideProject, style: _activityDetail),
                    if (_reviewErrors[change.path] case final error?)
                      _ActivityError(text.reviewError(error)),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

extension _ReviewText on _ActivityText {
  String get noChanges =>
      _zh ? '此会话没有待处理的更改。' : 'No pending changes in this session.';
  String get keep => _zh ? '保留' : 'Keep';
  String get undo => _zh ? '撤销' : 'Undo';
  String keepDescription(String host) => _zh
      ? '保留 $host 上此会话对此文件的更改？'
      : 'Keep this session’s changes to this file on $host?';
  String undoDescription(String host) => _zh
      ? '撤销 $host 上此会话对此文件的更改？此操作会修改主机上的文件。'
      : 'Undo this session’s changes to this file on $host? This modifies the file on the host.';

  String get binary => _zh ? '二进制' : 'Binary';
  String get untracked => _zh ? '未跟踪' : 'Untracked';
  String get conflict => _zh ? '冲突' : 'Conflict';
  String get outsideProject => _zh ? '所选项目之外' : 'Outside the selected project';
  String get previewDiff => _zh ? '预览差异' : 'Preview diff';
  String get backToChanges => _zh ? '返回更改' : 'Back to changes';
  String get closeDiff => _zh ? '关闭差异' : 'Close diff';
  String get previewUnavailable => _zh
      ? '主机未提供此更改的文本差异。'
      : 'The host did not provide a text diff for this change.';
  String get binaryPreview =>
      _zh ? '二进制文件无法显示文本差异。' : 'Binary files cannot be shown as a text diff.';
  String get largePreview =>
      _zh ? '此差异超过预览大小限制。' : 'This diff exceeds the preview size limit.';
  String get readOnlyDiff => _zh
      ? '差异来自主机，文件需要在主机上编辑。'
      : 'This diff is from the host. The file can be edited on the host.';
  String get downloadCurrentFile => _zh ? '下载当前文件…' : 'Download current file…';
  String get fileSaved => _zh ? '已保存文件。' : 'File saved.';

  String reviewError(_ReviewError error) => switch (error) {
    _ReviewError.unconfirmed =>
      _zh
          ? '主机未确认此更改已处理。'
          : 'The host did not confirm that this change was resolved.',
    _ReviewError.stale =>
      _zh
          ? '主机上的更改已更新，请重新查看。'
          : 'This change has changed on the host. Review it again.',
    _ReviewError.unsupported =>
      _zh
          ? '主机无法对这个文件执行此操作。'
          : 'The host cannot perform this action for this file.',
    _ReviewError.conflict =>
      _zh ? '撤销发生冲突，文件仍待处理。' : 'Undo conflicted. The change is still pending.',
    _ReviewError.busy =>
      _zh ? '主机或代理正忙，请稍后重试。' : 'The host or agent is busy. Try again shortly.',
    _ReviewError.failed => actionFailed,
  };

  String changeKind(String kind) => switch (kind) {
    'added' => _zh ? '已新增' : 'Added',
    'modified' => _zh ? '已修改' : 'Modified',
    'deleted' => _zh ? '已删除' : 'Deleted',
    _ => kind,
  };
}
