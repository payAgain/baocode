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

_ReviewError _reviewFailure(LinkRemoteException error) => switch (error.code) {
  'stale' || LinkErrors.notFound => _ReviewError.stale,
  LinkErrors.unsupported || LinkErrors.unknown => _ReviewError.unsupported,
  'conflict' => _ReviewError.conflict,
  LinkErrors.busy => _ReviewError.busy,
  _ => _ReviewError.failed,
};

class _ReviewRequest {
  Timer? deadline;
}

class _BatchReview {
  _BatchReview(this.changes);

  final Map<String, _Change> changes;
  Set<String>? resolved;
  String? result;
  Timer? deadline;
}

class _ReviewPreview {
  _ReviewPreview(this.change, {required this.fromStrip});

  final _Change change;
  final bool fromStrip;
  (String, String)? diff;
  String? error;
  bool stale = false;
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

extension _ChangeReview on _DesktopRemoteActivityState {
  void _clearReviews() {
    for (final request in _reviewing.values) {
      request.deadline?.cancel();
    }
    _reviewing.clear();
    _reviewErrors.clear();
    _batch?.deadline?.cancel();
    _batch = null;
    _batchNotice = null;
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
    if (_batch case final batch?) {
      final resolved = batch.resolved;
      if (resolved != null &&
          resolved.every(
            (path) => changes[path]?.revision != batch.changes[path]!.revision,
          )) {
        batch.deadline?.cancel();
        _batch = null;
        _batchNotice = batch.result;
      }
    }
    if (_reviewPreview case final preview?
        when changes[preview.change.path] != preview.change) {
      _reviewPreview = null;
    }
  }

  bool _reviewSurface(DesktopRemoteActivitySession session, bool fromStrip) =>
      _current(session) && (fromStrip || _open && _section == _Section.changes);

  String? _reviewBlocked(
    _ActivityText text,
    DesktopRemoteActivitySession session,
    _Change change, {
    required bool guarded,
  }) {
    if (!_projectRelative(change.path)) return text.outsideProject;
    if (_batch != null || _reviewing.containsKey(change.path)) {
      return text.awaitingHost;
    }
    if (session._live) return text.generating;
    if (guarded && change.revision == null) return text.legacyReview;
    return null;
  }

  bool _canUndo(_Change change, {required bool guarded}) => guarded
      ? !change.untracked && change.undoable == true
      : change.undoable != false;

  bool _canBatch(DesktopRemoteActivitySession session, {required bool keep}) {
    final changes = session._changes;
    return session._batchReview &&
        !session._live &&
        _batch == null &&
        _reviewing.isEmpty &&
        changes.length > 1 &&
        changes.length <= LinkLimits.reviewChanges &&
        changes.values.every((change) => change.revision != null) &&
        changes.values.any((change) => _batchTarget(change, keep: keep));
  }

  bool _batchTarget(_Change change, {required bool keep}) =>
      _projectRelative(change.path) &&
      (keep || _canUndo(change, guarded: true));

  Future<void> _reviewAll(
    DesktopRemoteActivitySession session, {
    required bool keep,
  }) async {
    if (!_current(session) || !_canBatch(session, keep: keep)) return;
    final changes = session._changes;
    final text = _ActivityText(context);
    final action = keep ? context.l10n.stripKeepAll : context.l10n.stripUndoAll;
    final count = changes.values
        .where((change) => _batchTarget(change, keep: keep))
        .length;
    if (!await _confirm(
      session,
      action: action,
      description: text.batchDescription(widget.hostName, keep: keep),
      target: text.batchCount(count, changes.length - count),
      icon: keep ? Icons.check_rounded : Icons.undo_rounded,
      destructive: !keep,
    )) {
      return;
    }
    if (!_canBatch(session, keep: keep) ||
        session._changes.length != changes.length ||
        changes.entries.any(
          (entry) => session._changes[entry.key] != entry.value,
        )) {
      _changeState(() => _batchNotice = text.reviewError(_ReviewError.stale));
      return;
    }

    final batch = _BatchReview(changes);
    _changeState(() {
      _batch = batch;
      _batchNotice = null;
      _reviewErrors.clear();
    });
    bool current() => _current(session) && identical(_batch, batch);
    void fail(_ReviewError error) {
      if (!mounted ||
          !identical(widget.session, session) ||
          !identical(_batch, batch)) {
        return;
      }
      _changeState(() {
        batch.deadline?.cancel();
        _batch = null;
        _batchNotice = error == _ReviewError.unsupported
            ? text.legacyBatchReview
            : text.reviewError(error);
      });
    }

    try {
      final reply = await session.peer.call(LinkMethods.reviewChanges, {
        'session': session.session,
        'action': keep ? 'keep' : 'undo',
        'changes': [
          for (final change in changes.values)
            {'path': change.path, 'revision': change.revision},
        ],
      });
      if (!current()) return;
      final remaining = changes.keys.toSet();
      Set<String> consume(Object? value) {
        if (value is! List) {
          throw const FormatException('Invalid review result');
        }
        return {
          for (final path in value)
            if (path is String && remaining.remove(path))
              path
            else
              throw const FormatException('Invalid review path'),
        };
      }

      if (reply is! Map) throw const FormatException('Invalid review result');
      final resolved = consume(reply['resolved']);
      final conflicts = consume(reply['conflicts']);
      final skipped = consume(reply['skipped']);
      final pending = consume(reply['pending']);
      if (remaining.isNotEmpty) {
        throw const FormatException('Incomplete review result');
      }
      _changeState(() {
        batch.resolved = resolved;
        batch.result = text.batchResult(
          resolved.length,
          conflicts.length,
          skipped.length,
          pending.length,
        );
        batch.deadline = Timer(
          const Duration(seconds: 10),
          () => fail(_ReviewError.unconfirmed),
        );
        _syncReviews();
      });
    } on TimeoutException {
      fail(_ReviewError.unconfirmed);
    } on LinkRemoteException catch (error) {
      fail(_reviewFailure(error));
    } on Object {
      fail(_ReviewError.failed);
    }
  }

  Future<void> _review(
    DesktopRemoteActivitySession session,
    _Change change, {
    required bool keep,
    bool fromStrip = false,
    bool header = false,
    _ReviewPreview? preview,
  }) async {
    final path = change.path;
    final guarded = fromStrip || preview != null;
    final text = _ActivityText(context);
    bool canReview() =>
        _reviewSurface(session, fromStrip) &&
        session._changes[path] == change &&
        (!header || session._changes.length == 1) &&
        (preview == null ||
            identical(_reviewPreview, preview) && !preview.stale) &&
        _reviewBlocked(text, session, change, guarded: guarded) == null &&
        (keep || _canUndo(change, guarded: guarded));
    if (!canReview()) return;
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
      icon: keep ? Icons.check_rounded : Icons.undo_rounded,
      destructive: !keep,
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
          if (_reviewPreview case final current?
              when error == _ReviewError.stale && current.change == change) {
            current.stale = true;
          }
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
      fail(_reviewFailure(error));
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
    var stale = false;
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
      stale = failure.code == 'stale' || failure.code == LinkErrors.notFound;
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
      preview.stale = stale;
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
            onPressed: () => _changeState(() {
              _reviewPreview = null;
              if (!preview.fromStrip && _open) _requests++;
            }),
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
        _diffReviewActions(text, session, preview),
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

  Widget _diffReviewActions(
    _ActivityText text,
    DesktopRemoteActivitySession session,
    _ReviewPreview preview,
  ) {
    final change = preview.change;
    final error = _reviewErrors[change.path];
    final blocked = preview.stale
        ? text.reviewError(_ReviewError.stale)
        : _reviewBlocked(text, session, change, guarded: true);
    final undoable = _canUndo(change, guarded: true);
    void review({required bool keep}) => unawaited(
      _review(
        session,
        change,
        keep: keep,
        fromStrip: preview.fromStrip,
        preview: preview,
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Wrap(
        spacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (blocked != null) ...[
            if (blocked != preview.error) Text(blocked, style: _activityDetail),
          ] else ...[
            _ActivityAction(
              label: text.keep,
              onPressed: () => review(keep: true),
            ),
            _ActivityAction(
              label: text.undo,
              onPressed: undoable ? () => review(keep: false) : null,
              secondary: true,
            ),
            if (!undoable) Text(text.undoUnavailable, style: _activityDetail),
          ],
          if (error != null && !preview.stale)
            _ActivityError(text.reviewError(error)),
        ],
      ),
    );
  }

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
        final blocked = _reviewBlocked(text, session, change, guarded: false);
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
                    if (blocked != null)
                      Text(blocked, style: _activityDetail)
                    else
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
                      ),
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
  String get undoUnavailable =>
      _zh ? '此文件无法单独撤销。' : 'This file cannot be undone individually.';
  String get generating => _zh
      ? '代理正在生成，完成后可保留或撤销。'
      : 'Wait for the agent to finish before keeping or undoing changes.';
  String get legacyReview => _zh
      ? '此主机版本不支持带版本校验的文件操作。'
      : 'This host version does not support guarded file actions.';
  String keepDescription(String host) => _zh
      ? '保留 $host 上此会话对此文件的更改？'
      : 'Keep this session’s changes to this file on $host?';
  String undoDescription(String host) => _zh
      ? '撤销 $host 上此会话对此文件的更改？此操作会修改主机上的文件。'
      : 'Undo this session’s changes to this file on $host? This modifies the file on the host.';

  String get legacyBatchReview => _zh
      ? '此主机版本不支持批量审阅，可逐个处理文件。'
      : 'This host does not support batch review. Review files individually.';
  String get batchLimit => _zh
      ? '文件数超过批量审阅上限，可逐个处理文件。'
      : 'Too many files for batch review. Review files individually.';
  String batchDescription(String host, {required bool keep}) => switch ((
    _zh,
    keep,
  )) {
    (true, true) => '保留 $host 上此会话的更改？文件内容不变。',
    (true, false) => '撤销 $host 上此会话的更改？此操作会修改主机上的文件，冲突文件会保留。',
    (false, true) =>
      'Keep this session’s changes on $host? File contents will not change.',
    (false, false) =>
      'Undo this session’s changes on $host? This modifies files on the host and leaves conflicts pending.',
  };
  String batchCount(int count, int skipped) => _zh
      ? '$count 个文件待处理${skipped == 0 ? '' : '，跳过 $skipped 个'}'
      : '$count files to review${skipped == 0 ? '' : ', $skipped skipped'}';
  String batchResult(int resolved, int conflicts, int skipped, int pending) => [
    _zh
        ? '已处理 $resolved 个文件'
        : 'Resolved $resolved ${resolved == 1 ? 'file' : 'files'}',
    if (conflicts > 0)
      _zh
          ? '$conflicts 个冲突'
          : '$conflicts ${conflicts == 1 ? 'conflict' : 'conflicts'}',
    if (skipped > 0) _zh ? '跳过 $skipped 个' : '$skipped skipped',
    if (pending > 0) _zh ? '$pending 个仍待处理' : '$pending still pending',
  ].join(' · ');

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
