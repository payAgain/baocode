import 'dart:async';
import 'dart:math' as math;

import 'package:bao_link/bao_link.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../chat/chat_models.dart'
    show CommandStatus, FileChange, FileChangeKind;
import '../chat/panels/activity_strip.dart';
import '../chat/side_panel/side_panel_section_bar.dart';
import '../ide/ide_code_diff.dart';
import '../ide/ide_list.dart' show IdeListColors, IdeListRow;
import '../kernel/kernel_types.dart' show KernelTask, KernelTaskKind;
import '../l10n/l10n.dart';
import '../settings/pages/settings_widgets.dart' show SettingsText;
import '../theme/app_theme.dart' show AppColors;
import '../theme/codicons.dart';
import '../theme/material_file_icons.dart' show FileIcon;
import '../theme/workbench_theme.dart' show themeColors;
import '../workspace/islands.dart' show IslandTab;
import '../workspace/window_controls.dart';
import 'desktop_host_chats.dart';
import 'desktop_remote_git_client.dart';
import 'desktop_remote_git_view.dart';
import 'desktop_remote_media.dart';

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
    this.files,
  });

  final Widget? files;
  final DesktopRemoteActivitySession? session;
  final String hostName;
  final Widget Function(
    BuildContext context,
    Widget? activityButton,
    Widget? activityStrip,
  )
  builder;

  @override
  State<DesktopRemoteActivity> createState() => _DesktopRemoteActivityState();
}

enum _Section { files, tasks, changes, extensions }

class _DesktopRemoteActivityState extends State<DesktopRemoteActivity> {
  bool _open = false;
  late _Section _section = _defaultSection;
  _Section get _defaultSection =>
      widget.files == null ? _Section.tasks : _Section.files;
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
      if (widget.files == null) _open = false;
      _confirmation = null;
      _stopping.clear();
      _stopError = null;
      _clearOutput();
      _clearReviews();
      _extensions = null;
      _section = _defaultSection;
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
      _section = _defaultSection;
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

  bool _current(DesktopRemoteActivitySession session) =>
      mounted && identical(widget.session, session) && session._available;

  bool _active(DesktopRemoteActivitySession session) =>
      _open && _current(session);

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
    if (!_current(session) || _confirmation != null) return false;
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
          _current(session);
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
      if (!_current(session)) return false;
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

  Widget? _activityStrip(DesktopRemoteActivitySession session) {
    final tasks = session._tasks;
    final running = [
      for (final task in tasks.values)
        if (task.status == 'running')
          KernelTask(
            id: task.id,
            description: task.description.isEmpty ? task.id : task.description,
            kind: switch (task.kind) {
              'agent' => KernelTaskKind.agent,
              'command' => KernelTaskKind.command,
              _ => KernelTaskKind.other,
            },
            status: CommandStatus.running,
            startedAt: task.startedAt,
            summary: task.summary,
          ),
    ];
    final changes = [
      for (final change in session._changes.values)
        FileChange(
          path: change.path,
          added: change.added ?? 0,
          removed: change.removed ?? 0,
          kind: switch (change.kind) {
            'added' => FileChangeKind.added,
            'deleted' => FileChangeKind.deleted,
            _ => FileChangeKind.modified,
          },
          binary: change.binary,
          tracked: !change.untracked,
          conflict: change.conflict,
        ),
    ];
    if (!ActivityStrip.hasContent(running, changes)) return null;
    return ActivityStrip(
      key: ObjectKey(session),
      tasks: running,
      changes: changes,
      paths: p.posix,
      showLineCounts: session._changes.values.every(
        (change) =>
            change.binary || change.added != null && change.removed != null,
      ),
      detailOf: (task) => task.summary,
      onStopTask: (task) => unawaited(_stop(session, tasks[task.id]!)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = _ActivityText(context);
    final session = widget.session;
    final sessionAvailable = session?._available == true;
    final activityStrip = sessionAvailable ? _activityStrip(session!) : null;
    final hasFiles = widget.files != null;
    final available = hasFiles || sessionAvailable;
    final label = hasFiles ? text.projectSidebar : text.activity;
    final activityButton = available
        ? IconButton(
            key: const ValueKey('desktop-remote-project-sidebar-toggle'),
            tooltip: label,
            visualDensity: VisualDensity.compact,
            icon: Icon(
              _open
                  ? Codicons.layoutSidebarRight
                  : Codicons.layoutSidebarRightOff,
              size: 16,
            ),
            isSelected: _open,
            onPressed: _toggle,
          )
        : null;
    return LayoutBuilder(
      builder: (context, constraints) {
        final visible = _open && available;
        final docked = visible && constraints.maxWidth >= 600;
        final compact = visible && !docked;
        final preview =
            visible && sessionAvailable && _section == _Section.changes
            ? _reviewPreview
            : null;
        final hideChat = compact || preview != null;
        final wideGit =
            hasFiles &&
            _section == _Section.changes &&
            constraints.maxWidth >= 1200;
        final panelWidth = docked
            ? wideGit
                  ? math.min(760.0, constraints.maxWidth * .52)
                  : math.min(400.0, constraints.maxWidth * .37)
            : 0.0;
        return Stack(
          fit: StackFit.expand,
          children: [
            PositionedDirectional(
              start: 0,
              end: docked ? panelWidth + 1 : 0,
              top: 0,
              bottom: 0,
              child: Offstage(
                offstage: hideChat,
                child: ExcludeFocus(
                  excluding: hideChat,
                  child: TickerMode(
                    enabled: !hideChat,
                    child: widget.builder(
                      context,
                      activityButton,
                      activityStrip,
                    ),
                  ),
                ),
              ),
            ),
            if (visible)
              PositionedDirectional(
                start: docked ? null : 0,
                end: 0,
                top: 0,
                bottom: 0,
                width: docked ? panelWidth + 1 : null,
                child: Offstage(
                  offstage: compact && preview != null,
                  child: ExcludeFocus(
                    excluding: compact && preview != null,
                    child: Row(
                      children: [
                        if (docked)
                          VerticalDivider(
                            width: 1,
                            color: AppColors.partBorder,
                          ),
                        Expanded(
                          child: Material(
                            key: const ValueKey(
                              'desktop-remote-project-sidebar',
                            ),
                            color: AppColors.background,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _ActivityBar(
                                  label: label,
                                  heading: true,
                                  trailing: _ActivityIconButton(
                                    tooltip: hasFiles
                                        ? text.closeProjectSidebar
                                        : text.close,
                                    icon: compact
                                        ? Codicons.arrowLeft
                                        : Codicons.close,
                                    onPressed: _toggle,
                                  ),
                                ),
                                _sections(text, sessionAvailable),
                                Expanded(
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      if (hasFiles)
                                        Offstage(
                                          offstage: _section != _Section.files,
                                          child: ExcludeFocus(
                                            excluding:
                                                _section != _Section.files,
                                            child: widget.files!,
                                          ),
                                        ),
                                      if (sessionAvailable &&
                                          _section != _Section.files)
                                        switch (_section) {
                                          _Section.tasks when _output != null =>
                                            _outputPane(text, _output!),
                                          _Section.tasks => _tasks(
                                            text,
                                            session!,
                                          ),
                                          _Section.changes when hasFiles =>
                                            DesktopRemoteGitView(
                                              key: ObjectKey(session),
                                              client: DesktopRemoteGitClient(
                                                session!.peer,
                                              ),
                                              project: session.projectId,
                                              review: _changes(text, session),
                                            ),
                                          _Section.changes => _changes(
                                            text,
                                            session!,
                                          ),
                                          _Section.extensions =>
                                            _extensionsPane(text),
                                          _Section.files =>
                                            const SizedBox.shrink(),
                                        },
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (preview != null)
              PositionedDirectional(
                start: 0,
                end: docked ? panelWidth + 1 : 0,
                top: 0,
                bottom: 0,
                child: _reviewPane(text, session!, preview, compact: compact),
              ),
          ],
        );
      },
    );
  }

  Widget _sections(_ActivityText text, bool sessionAvailable) => SizedBox(
    height: IslandTab.height,
    child: Stack(
      fit: StackFit.expand,
      children: [
        Align(alignment: Alignment.bottomCenter, child: _activityRule()),
        SidePanelSectionBar(
          color: AppColors.background,
          sections: [
            if (widget.files != null)
              _tab(_Section.files, Codicons.files, text.files),
            if (sessionAvailable) ...[
              _tab(_Section.tasks, Codicons.tasklist, text.tasks),
              _tab(_Section.changes, Codicons.sourceControl, text.changes),
              _tab(_Section.extensions, Codicons.extensions, text.extensions),
            ],
          ],
        ),
      ],
    ),
  );

  SidePanelSectionEntry _tab(_Section section, IconData icon, String label) =>
      SidePanelSectionEntry(
        key: ValueKey('desktop-remote-tab-${section.name}'),
        icon: icon,
        label: label,
        selected: _section == section,
        onTap: () {
          if (_section != section) _selectSection(section);
        },
      );

  void _changeState(VoidCallback change) => setState(change);

  Widget _tasks(_ActivityText text, DesktopRemoteActivitySession session) {
    final tasks = session._tasks.values.toList();
    if (tasks.isEmpty) {
      return _ActivityNotice(icon: Codicons.tasklist, label: text.noTasks);
    }
    return _activityList(
      count: tasks.length,
      itemBuilder: (context, index) {
        final task = tasks[index];
        return _ActivityRow(
          icon: task.kind == 'command' ? Codicons.terminal : Codicons.tasklist,
          title: task.description.isEmpty ? task.id : task.description,
          metadata: [
            text.taskKind(task.kind),
            text.taskStatus(task.status),
          ].join(' · '),
          children: [
            if (task.command case final command? when command.isNotEmpty)
              _ActivityCode(text: command),
            if (task.summary case final summary? when summary.isNotEmpty)
              Text(summary, style: _activityDetail),
            if (task.output || task.status == 'running')
              Wrap(
                spacing: 4,
                children: [
                  if (task.output)
                    _ActivityAction(
                      label: text.viewOutput,
                      onPressed: () => _showOutput(session, task),
                    ),
                  if (task.status == 'running')
                    _ActivityAction(
                      label: _stopping.contains(task.id)
                          ? text.awaitingHost
                          : text.stop,
                      onPressed: _stopping.contains(task.id)
                          ? null
                          : () => _stop(session, task),
                      secondary: true,
                    ),
                ],
              ),
            if (_stopError == task.id) _ActivityError(text.actionFailed),
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
            _ActivityBar(
              leading: _ActivityIconButton(
                tooltip: text.backToTasks,
                icon: Codicons.arrowLeft,
                onPressed: () => setState(_clearOutput),
              ),
              label: output.task.description.isEmpty
                  ? output.task.id
                  : output.task.description,
              trailing: _ActivityIconButton(
                tooltip: text.reloadOutput,
                icon: Codicons.refresh,
                onPressed: output.loading
                    ? null
                    : () => _showOutput(output.session, output.task),
              ),
            ),
            _activityRule(),
            Expanded(
              child: switch (output) {
                _TaskOutput(loading: true) => _ActivityNotice(
                  icon: Codicons.terminal,
                  label: text.loading,
                ),
                _TaskOutput(failed: true) => _ActivityNotice(
                  icon: Codicons.warning,
                  label: text.outputFailed,
                ),
                _TaskOutput(tail: '') => _ActivityNotice(
                  icon: Codicons.terminal,
                  label: text.noOutput,
                ),
                _ => SingleChildScrollView(
                  key: ObjectKey(output),
                  padding: const EdgeInsets.all(12),
                  child: _ActivityCode(text: output.tail),
                ),
              },
            ),
          ],
        ),
      );
}

TextStyle get _activityTitle =>
    SettingsText.label.copyWith(color: AppColors.textPrimary);
TextStyle get _activityDetail =>
    SettingsText.description.copyWith(color: AppColors.textMuted);

Widget _activityRule() => Divider(height: 1, color: AppColors.partBorder);

ButtonStyle _activityButtonStyle(
  BuildContext context, {
  required Color foreground,
  Color? background,
  bool selected = false,
}) => ButtonStyle(
  foregroundColor: WidgetStateProperty.resolveWith(
    (states) => states.contains(WidgetState.disabled)
        ? AppColors.textFaint
        : foreground,
  ),
  backgroundColor: WidgetStatePropertyAll(background),
  overlayColor: WidgetStateProperty.resolveWith(
    (states) =>
        states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.pressed)
        ? themeColors['toolbar.hoverBackground']
        : Colors.transparent,
  ),
  side: WidgetStateProperty.resolveWith((states) {
    final outline = states.contains(WidgetState.focused)
        ? themeColors['focusBorder']
        : selected
        ? themeColors.get('contrastActiveBorder')
        : null;
    return outline == null ? BorderSide.none : BorderSide(color: outline);
  }),
  textStyle: WidgetStatePropertyAll(
    Theme.of(context).textTheme.labelLarge
        ?.merge(_activityDetail.copyWith(fontWeight: FontWeight.w500)),
  ),
  minimumSize: const WidgetStatePropertyAll(Size(28, 28)),
  padding: const WidgetStatePropertyAll(
    EdgeInsets.symmetric(horizontal: 8, vertical: 4),
  ),
  shape: WidgetStatePropertyAll(
    RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
  ),
  visualDensity: VisualDensity.standard,
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
);

class _ActivityBar extends StatelessWidget {
  const _ActivityBar({
    required this.label,
    this.leading,
    this.trailing,
    this.heading = false,
  });

  final String label;
  final Widget? leading;
  final Widget? trailing;
  final bool heading;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    child: Row(
      spacing: 6,
      children: [
        ?leading,
        Expanded(
          child: Semantics(
            header: heading,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: heading
                  ? SettingsText.heading.copyWith(color: AppColors.textPrimary)
                  : _activityTitle,
            ),
          ),
        ),
        ?trailing,
      ],
    ),
  );
}

class _ActivityIconButton extends StatelessWidget {
  const _ActivityIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    icon: Icon(icon, size: 16),
    onPressed: onPressed,
    style: _activityButtonStyle(
      context,
      foreground: AppColors.textMuted,
    ).copyWith(padding: const WidgetStatePropertyAll(EdgeInsets.zero)),
  );
}

class _ActivityAction extends StatelessWidget {
  const _ActivityAction({
    required this.label,
    required this.onPressed,
    this.secondary = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool secondary;

  @override
  Widget build(BuildContext context) => TextButton(
    style: _activityButtonStyle(
      context,
      foreground: secondary ? AppColors.textMuted : AppColors.accent,
    ),
    onPressed: onPressed,
    child: Text(label),
  );
}

Widget _activityList({
  Key? key,
  required int count,
  required IndexedWidgetBuilder itemBuilder,
}) => ListView.separated(
  key: key,
  primary: false,
  padding: const EdgeInsets.symmetric(horizontal: 12),
  itemCount: count,
  separatorBuilder: (_, _) => _activityRule(),
  itemBuilder: itemBuilder,
);

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({
    required this.icon,
    required this.title,
    required this.metadata,
    this.children = const [],
  });

  final IconData icon;
  final String title;
  final String metadata;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 8,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, size: 15, color: AppColors.textMuted),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 3,
            children: [
              Text(title, style: _activityTitle),
              Text(metadata, style: _activityDetail),
              ...children,
            ],
          ),
        ),
      ],
    ),
  );
}

class _ActivityNotice extends StatelessWidget {
  const _ActivityNotice({required this.icon, required this.label, this.action});

  final IconData icon;
  final String label;
  final Widget? action;

  Widget get content => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    spacing: 8,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Icon(icon, size: 15, color: AppColors.textMuted),
      ),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: _activityDetail),
            ?action,
          ],
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    primary: false,
    padding: const EdgeInsets.all(12),
    child: content,
  );
}

class _ActivityCode extends StatelessWidget {
  const _ActivityCode({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: AppColors.code,
      borderRadius: BorderRadius.circular(5),
      border: Border.all(color: AppColors.partBorder),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: SelectableText(
        text,
        style: SettingsText.path.copyWith(
          color: AppColors.text,
          fontFamilyFallback: [
            ...?SettingsText.path.fontFamilyFallback,
            ?Theme.of(context).textTheme.bodyMedium?.fontFamily,
            ...?Theme.of(context).textTheme.bodyMedium?.fontFamilyFallback,
          ],
        ),
      ),
    ),
  );
}

class _ActivityError extends StatelessWidget {
  const _ActivityError(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Text(
    label,
    style: _activityDetail.copyWith(color: IdeListColors.errorForeground),
  );
}

class _ActivityText {
  _ActivityText(BuildContext context)
    : _zh = Localizations.localeOf(context).languageCode == 'zh';

  final bool _zh;
  String get activity => _zh ? '主机活动' : 'Host activity';
  String get projectSidebar => _zh ? '项目侧栏' : 'Project sidebar';
  String get closeProjectSidebar => _zh ? '关闭项目侧栏' : 'Close project sidebar';
  String get files => _zh ? '文件' : 'Files';
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
