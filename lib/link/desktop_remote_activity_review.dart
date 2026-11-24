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
  bool undoable,
  bool preview,
});

enum _ReviewError { unconfirmed, stale, unsupported, conflict, busy, failed }

class _ReviewRequest {
  Timer? deadline;
}

class _ReviewPreview {
  _ReviewPreview(this.change);

  final _Change change;
  Widget Function()? content;
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
            undoable: raw['undoable'] != false,
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

  Future<void> _review(
    DesktopRemoteActivitySession session,
    _Change change, {
    required bool keep,
  }) async {
    final path = change.path;
    bool canReview() =>
        _active(session) &&
        _section == _Section.changes &&
        _projectRelative(path) &&
        session._changes[path] == change &&
        (keep || change.undoable) &&
        !_reviewing.containsKey(path);
    if (!canReview()) return;
    final text = _ActivityText(context);
    final host = widget.hostName;
    if (!await _confirm(
      session,
      action: keep ? text.keep : text.undo,
      description: keep
          ? text.keepDescription(host)
          : text.undoDescription(host),
      target: path,
    )) {
      return;
    }
    if (!canReview()) {
      if (_active(session) &&
          _section == _Section.changes &&
          session._changes.containsKey(path) &&
          session._changes[path] != change) {
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
    _Change change,
  ) async {
    final path = change.path;
    final revision = change.revision;
    bool current() =>
        _active(session) &&
        _section == _Section.changes &&
        session._changes[path] == change;
    if (revision == null ||
        !change.preview ||
        !_projectRelative(path) ||
        !current()) {
      return;
    }
    final text = _ActivityText(context);
    if (!await _confirm(
          session,
          action: text.previewDiff,
          description: text.previewDescription(widget.hostName),
          target: path,
        ) ||
        !current()) {
      return;
    }

    final preview = _ReviewPreview(change);
    _changeState(() => _reviewPreview = preview);
    Widget Function() content;
    try {
      final response = await session.peer.call(LinkMethods.read, {
        'session': session.session,
        'path': path,
        'expectedChange': revision,
      });
      content = switch (response) {
        {'original': final String before, 'text': final String after}
            when before.length <= LinkLimits.file &&
                after.length <= LinkLimits.file =>
          () => IdeCodeDiff(
            path: path,
            original: before,
            modified: after,
            sideBySide: false,
            embedded: true,
            bars: false,
          ),
        _ => () => _ActivityNotice(
          icon: Codicons.diff,
          label: text.previewUnavailable,
        ),
      };
    } on LinkRemoteException catch (error) {
      content = () => _ActivityNotice(
        icon: Codicons.warning,
        label: switch (error.code) {
          'stale' ||
          LinkErrors.notFound => text.reviewError(_ReviewError.stale),
          LinkErrors.unsupported ||
          LinkErrors.unknown => text.previewUnavailable,
          _ => text.actionFailed,
        },
      );
    } on Object {
      content = () =>
          _ActivityNotice(icon: Codicons.warning, label: text.actionFailed);
    }
    if (!identical(_reviewPreview, preview) || !current()) return;
    _changeState(() => preview.content = content);
  }

  Widget _changes(_ActivityText text, DesktopRemoteActivitySession session) {
    if (_reviewPreview case final preview?) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ActivityBar(
            leading: _ActivityIconButton(
              tooltip: text.backToChanges,
              icon: Codicons.arrowLeft,
              onPressed: () => _changeState(() => _reviewPreview = null),
            ),
            label: preview.change.path,
          ),
          _activityRule(),
          Expanded(
            child:
                preview.content?.call() ??
                _ActivityNotice(icon: Codicons.diff, label: text.loading),
          ),
        ],
      );
    }
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
        return _ActivityRow(
          icon: Codicons.diff,
          title: change.path,
          selectableTitle: true,
          metadata: [
            text.changeKind(change.kind),
            if (counts.isNotEmpty) counts,
            if (change.binary) text.binary,
            if (change.untracked) text.untracked,
            if (change.conflict) text.conflict,
          ].join(' · '),
          children: [
            if (pending)
              Text(text.awaitingHost, style: _activityDetail)
            else if (_projectRelative(change.path))
              Wrap(
                spacing: 4,
                children: [
                  _ActivityAction(
                    label: text.keep,
                    onPressed: () => _review(session, change, keep: true),
                  ),
                  _ActivityAction(
                    label: text.undo,
                    onPressed: change.undoable
                        ? () => _review(session, change, keep: false)
                        : null,
                    secondary: true,
                  ),
                  if (change.preview && change.revision != null)
                    _ActivityAction(
                      label: text.previewDiff,
                      onPressed: () => _previewChange(session, change),
                    ),
                ],
              )
            else
              Text(text.outsideProject, style: _activityDetail),
            if (_reviewErrors[change.path] case final error?)
              _ActivityError(text.reviewError(error)),
          ],
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
  String previewDescription(String host) => _zh
      ? '从 $host 读取此会话中这个文件的差异？'
      : 'Read the diff for this session’s file on $host?';
  String get previewUnavailable =>
      _zh ? '此更改没有可预览的文本差异。' : 'A text diff is unavailable for this change.';

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
