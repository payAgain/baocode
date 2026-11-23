import 'dart:async';

import 'package:bao_link/bao_link.dart';
import 'package:flutter/material.dart';

import '../ide/ide_code_diff.dart';
import 'desktop_host_chats.dart';

part 'desktop_remote_activity_output.dart';
part 'desktop_remote_activity_review.dart';
part 'desktop_remote_activity_extensions.dart';

/// An adapter for the chat's existing project follow. It never opens one.
class DesktopRemoteActivitySession {
  DesktopRemoteActivitySession._({
    required this.peer,
    required this.projectId,
    required this.session,
    required this._currentState,
  });

  static final _bindings = Expando<DesktopRemoteActivitySession>();

  /// Call from the same build that listens to the page's shared chats model.
  /// A binding keeps its identity until selection, peer or follow changes.
  static DesktopRemoteActivitySession? fromChats(
    DesktopHostChats chats,
    LinkPeer? peer,
    DesktopHostChat? chat,
  ) {
    final project = chat?.projectId;
    if (peer == null || chat == null || project == null || project.isEmpty) {
      return null;
    }
    final snapshot = chats.remoteActionSnapshot(peer, chat);
    if (snapshot == null) return null;
    final follow = snapshot.follow;
    if (_bindings[follow]?.projectId != project) _bindings[follow] = null;
    final binding = _bindings[follow] ??= DesktopRemoteActivitySession._(
      peer: peer,
      projectId: project,
      session: chat.id,
      currentState: () {
        final current = chats.remoteActionSnapshot(peer, chat);
        return current != null && identical(current.follow, follow)
            ? current.state
            : null;
      },
    );
    binding._apply(snapshot.state);
    return binding;
  }

  final LinkPeer peer;
  final String projectId;
  final String session;
  final Map<String, Object?>? Function() _currentState;

  Map<String, Object?>? _lastState;
  Map<String, LinkTask> _tasks = const {};
  Map<String, _Change> _changes = const {};

  void _apply(Map<String, Object?> update) {
    if (update['session'] != session || identical(update, _lastState)) return;
    _lastState = update;
    final tasks = <String, LinkTask>{};
    if (update['tasks'] case final List<Object?> list) {
      for (final raw in list) {
        if (raw is! Map<String, Object?> || raw['status'] is! String) continue;
        try {
          final task = LinkTask.fromJson(raw);
          if (task.id.isNotEmpty && !task.id.contains('\n')) {
            tasks[task.id] = task;
          }
        } on TypeError {
          // An invalid record cannot replace an otherwise usable update.
        } on ArgumentError {
          // An invalid timestamp cannot break the chat's follow.
        }
      }
    }
    _tasks = tasks;
    _changes = _parseChanges(update['changes']);
  }

  bool get _available {
    if (peer.isClosed) return false;
    final update = _currentState();
    if (update == null || update['session'] != session) return false;
    // Re-check the latest host state even before the next widget rebuild.
    _apply(update);
    return true;
  }
}

/// Supplies a launcher for the existing conversation header and docks its
/// panel beside the chat, keeping the chat subtree mounted across toggles.
class DesktopRemoteActivity extends StatefulWidget {
  const DesktopRemoteActivity({
    super.key,
    required this.session,
    required this.hostName,
    required this.builder,
  });

  final DesktopRemoteActivitySession? session;
  final String hostName;
  final Widget Function(BuildContext context, Widget? activityButton) builder;

  @override
  State<DesktopRemoteActivity> createState() => _DesktopRemoteActivityState();
}

enum _Section { tasks, changes, extensions }

class _DesktopRemoteActivityState extends State<DesktopRemoteActivity> {
  bool _open = false;
  _Section _section = _Section.tasks;
  Future<_ExtensionInventory>? _extensions;
  final _reviewing = <String, _ReviewRequest>{};
  final _reviewErrors = <String, _ReviewError>{};
  _ReviewPreview? _reviewPreview;
  _TaskOutput? _output;
  Object? _confirmation;
  final _stopping = <String>{};
  String? _stopError;

  @override
  void didUpdateWidget(DesktopRemoteActivity oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, widget.session)) {
      _open = false;
      _confirmation = null;
      _stopping.clear();
      _stopError = null;
      _clearReviews();
      _extensions = null;
      _section = _Section.tasks;
    }
    if (!_open ||
        widget.session?._available != true ||
        _output?.advertised == false) {
      _clearOutput();
    }
    _stopping.removeWhere(
      (id) => widget.session?._tasks[id]?.status != 'running',
    );
    _syncReviews();
  }

  @override
  void dispose() {
    _clearReviews();
    _clearOutput();
    super.dispose();
  }

  void _clearOutput() {
    final output = _output;
    _output = null;
    output?.dispose();
  }

  void _toggle() => setState(() {
    _open = !_open;
    if (!_open) {
      _confirmation = null;
      _clearOutput();
      _reviewPreview = null;
    }
  });

  void _selectSection(_Section section) => setState(() {
    _section = section;
    _clearOutput();
    _reviewPreview = null;
    if (section == _Section.extensions) {
      if (widget.session case final session? when _active(session)) {
        _extensions ??= _loadExtensions(session);
      }
    }
  });

  bool _active(DesktopRemoteActivitySession session) =>
      mounted &&
      _open &&
      identical(widget.session, session) &&
      session._available;

  void _showOutput(DesktopRemoteActivitySession session, LinkTask task) {
    if (!_active(session) || session._tasks[task.id]?.output != true) return;
    _clearOutput();
    final output = _TaskOutput(session, session._tasks[task.id]!);
    setState(() => _output = output);
    unawaited(output.load());
  }

  Future<bool> _confirm(
    DesktopRemoteActivitySession session, {
    required String action,
    required String description,
    required String target,
  }) async {
    if (!_active(session) || _confirmation != null) return false;
    final token = _confirmation = Object();
    final text = _ActivityText(context);
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: Text(action),
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(description),
              const SizedBox(height: 8),
              Text(target),
            ],
          ),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.pop(context, false),
              child: Text(text.cancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      );
      return confirmed == true &&
          identical(_confirmation, token) &&
          _active(session);
    } finally {
      if (identical(_confirmation, token)) _confirmation = null;
    }
  }

  Future<void> _stop(
    DesktopRemoteActivitySession session,
    LinkTask task,
  ) async {
    final id = task.id;
    bool canStop() {
      if (!_active(session)) return false;
      final latest = session._tasks[id];
      return !_stopping.contains(id) &&
          latest?.status == 'running' &&
          latest?.startedAt == task.startedAt &&
          latest?.description == task.description;
    }

    if (!canStop()) return;
    final text = _ActivityText(context);
    if (!await _confirm(
          session,
          action: text.stop,
          description: text.stopDescription(widget.hostName),
          target: task.description.isEmpty ? id : task.description,
        ) ||
        !canStop()) {
      return;
    }
    setState(() {
      _stopError = null;
      _stopping.add(id);
    });
    try {
      await session.peer.call(LinkMethods.stopTask, {
        'session': session.session,
        'task': id,
      });
    } on Object {
      if (mounted &&
          identical(widget.session, session) &&
          session._available &&
          _stopping.contains(id)) {
        setState(() {
          _stopping.remove(id);
          _stopError = id;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = _ActivityText(context);
    final session = widget.session;
    final available = session?._available == true;
    final activityButton = available
        ? IconButton(
            tooltip: text.activity,
            visualDensity: VisualDensity.compact,
            icon: Icon(
              _open ? Icons.fact_check : Icons.fact_check_outlined,
              size: 16,
            ),
            isSelected: _open,
            onPressed: () {
              if (identical(widget.session, session) && session!._available) {
                _toggle();
              }
            },
          )
        : null;
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = constraints.maxWidth >= 720;
        return Flex(
          direction: side ? Axis.horizontal : Axis.vertical,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: widget.builder(context, activityButton)),
            if (_open && available) ...[
              if (side)
                const VerticalDivider(width: 1)
              else
                const Divider(height: 1),
              SizedBox(
                width: side ? 324 : null,
                height: side ? null : constraints.maxHeight * .48,
                child: Material(
                  color: Theme.of(context).colorScheme.surface,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ListTile(
                        dense: true,
                        title: Text(text.activity),
                        trailing: IconButton(
                          tooltip: text.close,
                          icon: const Icon(Icons.close),
                          onPressed: _toggle,
                        ),
                      ),
                      _sections(text),
                      Expanded(
                        child: switch (_section) {
                          _Section.tasks when _output != null => _outputPane(
                            text,
                            _output!,
                          ),
                          _Section.tasks => _tasks(text, session!),
                          _Section.changes => _changes(text, session!),
                          _Section.extensions => _extensionsPane(text),
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _sections(_ActivityText text) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    padding: const EdgeInsets.symmetric(horizontal: 8),
    child: Row(
      children: [
        _tab(_Section.tasks, text.tasks),
        _tab(_Section.changes, text.changes),
        _tab(_Section.extensions, text.extensions),
      ],
    ),
  );

  Widget _tab(_Section section, String label) => Semantics(
    selected: _section == section,
    child: TextButton(
      style: _section == section
          ? TextButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
            )
          : null,
      onPressed: () {
        if (_section != section) _selectSection(section);
      },
      child: Text(label),
    ),
  );

  void _changeState(VoidCallback change) => setState(change);

  Widget _tasks(_ActivityText text, DesktopRemoteActivitySession session) {
    final tasks = session._tasks.values.toList();
    return ListView.separated(
      primary: false,
      padding: const EdgeInsets.all(12),
      itemCount: tasks.isEmpty ? 1 : tasks.length,
      separatorBuilder: (_, _) => const Divider(),
      itemBuilder: (context, index) {
        if (tasks.isEmpty) return Text(text.noTasks);
        final task = tasks[index];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(task.description.isEmpty ? task.id : task.description),
            Text(
              [
                text.taskKind(task.kind),
                text.taskStatus(task.status),
              ].join(' · '),
            ),
            if (task.command case final command? when command.isNotEmpty)
              SelectableText(
                command,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            if (task.summary case final summary? when summary.isNotEmpty)
              Text(summary),
            if (task.output || task.status == 'running')
              Wrap(
                children: [
                  if (task.output)
                    TextButton(
                      onPressed: () => _showOutput(session, task),
                      child: Text(text.viewOutput),
                    ),
                  if (task.status == 'running')
                    TextButton(
                      onPressed: _stopping.contains(task.id)
                          ? null
                          : () => _stop(session, task),
                      child: Text(
                        _stopping.contains(task.id)
                            ? text.awaitingHost
                            : text.stop,
                      ),
                    ),
                ],
              ),
            if (_stopError == task.id) Text(text.actionFailed),
          ],
        );
      },
    );
  }

  Widget _outputPane(_ActivityText text, _TaskOutput output) =>
      ListenableBuilder(
        listenable: output,
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              leading: IconButton(
                tooltip: text.backToTasks,
                icon: const Icon(Icons.arrow_back),
                onPressed: () => setState(_clearOutput),
              ),
              title: Text(
                output.task.description.isEmpty
                    ? output.task.id
                    : output.task.description,
              ),
              trailing: IconButton(
                tooltip: text.reloadOutput,
                icon: const Icon(Icons.refresh),
                onPressed: output.loading
                    ? null
                    : () => _showOutput(output.session, output.task),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                key: ObjectKey(output),
                padding: const EdgeInsets.all(12),
                child: switch (output) {
                  _TaskOutput(loading: true) => Text(text.loading),
                  _TaskOutput(failed: true) => Text(text.outputFailed),
                  _TaskOutput(tail: '') => Text(text.noOutput),
                  _ => SelectableText(
                    output.tail,
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                },
              ),
            ),
          ],
        ),
      );
}

class _ActivityText {
  _ActivityText(BuildContext context)
    : _zh = Localizations.localeOf(context).languageCode == 'zh';

  final bool _zh;
  String get activity => _zh ? '主机活动' : 'Host activity';
  String get tasks => _zh ? '任务' : 'Tasks';
  String get changes => _zh ? '更改' : 'Changes';
  String get close => _zh ? '关闭主机活动' : 'Close host activity';
  String get noTasks => _zh ? '此会话没有任务。' : 'No tasks in this session.';
  String get cancel => _zh ? '取消' : 'Cancel';
  String get stop => _zh ? '停止任务' : 'Stop task';
  String stopDescription(String host) =>
      _zh ? '停止 $host 上此会话的任务？' : 'Stop this session’s task on $host?';
  String get awaitingHost => _zh ? '等待主机确认' : 'Waiting for host';
  String get actionFailed =>
      _zh ? '主机未确认请求。' : 'The host did not confirm the request.';
  String get viewOutput => _zh ? '查看输出' : 'View output';
  String get backToTasks => _zh ? '返回任务' : 'Back to tasks';
  String get reloadOutput => _zh ? '重新加载输出' : 'Reload output';
  String get loading => _zh ? '正在加载…' : 'Loading…';
  String get noOutput => _zh ? '还没有输出。' : 'No output yet.';
  String get outputFailed => _zh
      ? '无法读取主机输出，请重新加载。'
      : 'Could not read host output. Reload to try again.';

  String taskKind(String kind) => switch (kind) {
    'command' => _zh ? '命令任务' : 'Command task',
    'agent' => _zh ? '子智能体' : 'Subagent',
    _ => _zh ? '任务' : 'Task',
  };

  String taskStatus(String status) => switch (status) {
    'running' => _zh ? '运行中' : 'Running',
    'succeeded' => _zh ? '已成功' : 'Succeeded',
    'failed' => _zh ? '已失败' : 'Failed',
    _ => status,
  };
}
