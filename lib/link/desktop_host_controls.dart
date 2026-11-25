import 'dart:async';

import 'package:bao_link/bao_link.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chat/chat_session.dart' show ModelSettingChoice;
import '../chat/composer/composer_picker.dart';
import '../chat/composer/pickers_row.dart';
import '../chat/floating/floating_layer.dart';
import '../chat/floating/floating_placement.dart';
import '../chat/floating/floating_registry.dart';
import '../chat/panels/context_usage_panel.dart';
import '../chat/widgets/context_meter.dart';
import '../ide/ide_hover.dart';
import '../kernel/agent_kernel.dart' show KernelChoiceKind;
import '../kernel/kernel_types.dart';
import '../l10n/l10n.dart';
import '../theme/app_theme.dart';
import '../theme/codicons.dart';
import 'desktop_host_session_controls.dart';

/// Native toolbar pickers, with values and mutations supplied by the host.
class DesktopHostPickers extends StatelessWidget {
  const DesktopHostPickers({
    super.key,
    required this.controls,
    required this.focusNode,
  });

  final DesktopHostSessionControls? controls;
  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) {
    final controls = this.controls;
    if (controls == null || controls.choices.isEmpty) {
      return const SizedBox.shrink();
    }
    final l10n = context.l10n;
    final choices = controls.choices;
    final settings = [
      for (final (kind, wire, icon) in const [
        (KernelChoiceKind.effort, 'effort', Codicons.sparkle),
        (KernelChoiceKind.context, 'context', Codicons.database),
      ])
        if (choices[wire] case final choice?)
          _setting(controls, choice, kind, icon),
    ];
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: PickersRow(
          key: ObjectKey(choices),
          maxWidth: constraints.maxWidth,
          children: [
            if (choices['mode'] case final choice?) ...[
              _picker(
                controls,
                choice,
                l10n.composerSetMode,
                Codicons.commentDiscussion,
              ),
              const SizedBox(width: 2),
            ],
            if (choices['permission'] case final choice?) ...[
              _picker(
                controls,
                choice,
                _zh(context) ? '权限' : 'Permissions',
                Codicons.shield,
              ),
              const SizedBox(width: 2),
            ],
            if (choices['model'] case final choice?)
              _picker(
                controls,
                choice,
                l10n.composerPickModel,
                Codicons.sparkle,
                settings: settings,
                search: l10n.modelsSearch,
              ),
          ],
        ),
      ),
    );
  }

  Widget _picker(
    DesktopHostSessionControls controls,
    LinkChoice choice,
    String tooltip,
    IconData icon, {
    List<ModelSettingChoice> settings = const [],
    String? search,
  }) {
    final options = _options(choice, icon);
    final selected = options
        .where((option) => option.id == choice.selected)
        .firstOrNull;
    final model = choice.kind == 'model';
    return ComposerPicker(
      options: options,
      selected: selected ?? KernelOption('', tooltip, icon, ''),
      label: !model || selected == null
          ? null
          : [
              if (selected.group case final group?
                  when options.any(
                    (other) =>
                        other.label == selected.label &&
                        other.group?.id != group.id,
                  ))
                group.label,
              selected.label,
              for (final setting in settings)
                if (setting.selected case final picked?
                    when setting.kind != KernelChoiceKind.context ||
                        picked != setting.options.first)
                  picked.label,
            ].join(' · '),
      emphasized: choice.kind == 'mode',
      describes: !model,
      tooltip: tooltip,
      title: choice.kind == 'permission' ? tooltip : null,
      focusNode: focusNode,
      menuWidth: model
          ? 260
          : choice.kind == 'permission'
          ? 290
          : 248,
      searchPlaceholder: search,
      // The protocol advertises settings only for the selected host model.
      settingsOf: model && controls.modelSettingsReady
          ? (option) => option.id == choice.selected ? settings : const []
          : null,
      onSelected: (option) => unawaited(controls.choose(choice, option.id)),
    );
  }

  ModelSettingChoice _setting(
    DesktopHostSessionControls controls,
    LinkChoice choice,
    KernelChoiceKind kind,
    IconData icon,
  ) {
    final options = _options(choice, icon);
    return ModelSettingChoice(
      kind: kind,
      options: options,
      selected: options
          .where((option) => option.id == choice.selected)
          .firstOrNull,
      onSelected: (option) => unawaited(controls.choose(choice, option.id)),
    );
  }
}

List<KernelOption> _options(LinkChoice choice, IconData icon) => [
  for (final option in choice.options)
    if (option.id.isNotEmpty) _option(option, icon),
];

KernelOption _option(LinkOption option, IconData icon) => KernelOption(
  option.id,
  option.label.isEmpty ? option.id : option.label,
  icon,
  option.description,
  group: option.group == null
      ? null
      : KernelOptionGroup(option.group!, option.groupLabel ?? option.group!),
  caution: option.caution,
);

typedef DesktopHostBranchAccess = ({
  LinkPeer peer,
  Object view,
  bool Function() isCurrent,
});

/// The host's project, Git branch and reported window usage.
class DesktopHostSessionFooter extends StatelessWidget {
  const DesktopHostSessionFooter({
    super.key,
    this.project,
    this.controls,
    this.branchAccess,
  });

  final ProjectInfo? project;
  final DesktopHostSessionControls? controls;
  final DesktopHostBranchAccess? branchAccess;

  @override
  Widget build(BuildContext context) {
    final project = this.project;
    final usage = controls?.context;
    if (project == null && usage == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 0, 6, 4),
      child: Row(
        children: [
          Expanded(
            child: project == null
                ? const SizedBox.shrink()
                : _HostProject(project, branchAccess),
          ),
          if (usage != null)
            Flexible(
              child: _HostContextMeter(key: ObjectKey(controls), usage: usage),
            ),
        ],
      ),
    );
  }
}

Widget _projectLabel(IconData icon, String text) => Row(
  mainAxisSize: MainAxisSize.min,
  children: [
    Icon(icon, size: 13, color: AppColors.textFaint),
    const SizedBox(width: 4),
    Flexible(
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: AppColors.textFaint, fontSize: 12),
      ),
    ),
  ],
);

class _HostProject extends StatelessWidget {
  const _HostProject(this.project, this.branchAccess);

  final ProjectInfo project;
  final DesktopHostBranchAccess? branchAccess;

  @override
  Widget build(BuildContext context) {
    final name = project.name.isEmpty ? project.path : project.name;
    final branch = project.branch;
    final access = branchAccess;
    return Row(
      children: [
        if (name.isNotEmpty)
          Flexible(
            child: IdeHover(
              message: project.path,
              child: _projectLabel(Codicons.folder, name),
            ),
          ),
        if (branch != null && branch.isNotEmpty) ...[
          if (name.isNotEmpty) const SizedBox(width: 8),
          Flexible(
            child: access == null || !project.canSwitchBranch
                ? _projectLabel(Codicons.gitBranch, branch)
                : _HostBranch(
                    key: ObjectKey(access.view),
                    project: project,
                    access: access,
                  ),
          ),
        ],
      ],
    );
  }
}

KernelOption _branchOption(String name) =>
    KernelOption(name, name, Codicons.gitBranch, '');

class _HostBranch extends StatefulWidget {
  const _HostBranch({super.key, required this.project, required this.access});

  final ProjectInfo project;
  final DesktopHostBranchAccess access;

  @override
  State<_HostBranch> createState() => _HostBranchState();
}

class _HostBranchState extends State<_HostBranch> {
  final _picker = GlobalKey<ComposerPickerState>();
  final _focus = FocusNode(debugLabel: 'Host branch picker');
  Object? _listing;
  List<String> _branches = const [];
  ({String oid, String? branch})? _head;
  bool _switching = false;
  bool _unsupported = false;
  String? _error;

  bool get _current => mounted && widget.access.isCurrent();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (!node.hasPrimaryFocus) return KeyEventResult.ignored;
    if (FloatingRegistry.handleKey(event) case final result?) return result;
    if (_picker.currentState?.isOpen == true &&
        (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
            event.logicalKey == LogicalKeyboardKey.arrowRight)) {
      // Without a submenu, leave focus on the picker (also while loading).
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.space) &&
        _current &&
        !_switching) {
      _picker.currentState?.toggle();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _list() async {
    if (!_current || _switching) {
      _picker.currentState?.close();
      return;
    }
    final request = Object();
    bool current() =>
        _current &&
        identical(_listing, request) &&
        _picker.currentState?.isOpen == true;
    setState(() {
      _listing = request;
      _error = null;
      _head = null;
      _branches = const [];
    });
    try {
      final response = await widget.access.peer.call(
        LinkMethods.projectBranches,
        {'project': widget.project.id},
      );
      if (!current()) return;
      if (response
          case final Map<String, Object?> result &&
              {'branches': final List branches, 'head': final String oid}
          when oid.isNotEmpty) {
        final branch = result['branch'] as String?;
        setState(() {
          _listing = null;
          _head = (oid: oid, branch: branch);
          _branches = branches
              .whereType<String>()
              .where((name) => name.isNotEmpty)
              .toSet()
              .toList();
        });
      } else {
        throw const FormatException('Missing host branches');
      }
    } on Object catch (error) {
      if (!current()) return;
      _picker.currentState?.close();
      _report(error, listing: true);
    }
  }

  Future<void> _switch(String branch) async {
    final head = _head;
    if (!_current ||
        _switching ||
        _unsupported ||
        head == null ||
        !_branches.contains(branch) ||
        branch == head.branch) {
      return;
    }
    setState(() {
      _switching = true;
      _error = null;
    });
    try {
      await widget.access.peer.call(LinkMethods.switchProjectBranch, {
        'project': widget.project.id,
        'branch': branch,
        'expectedHead': head.oid,
        'expectedBranch': ?head.branch,
      });
    } on Object catch (error) {
      if (_current) _report(error);
    } finally {
      if (_current) setState(() => _switching = false);
    }
  }

  void _report(Object error, {bool listing = false}) {
    final zh = _zh(context);
    setState(() {
      _listing = null;
      _unsupported =
          error is LinkRemoteException &&
          (error.code == LinkErrors.unknown ||
              error.code == LinkErrors.unsupported);
      _error = switch (error) {
        LinkRemoteException(code: LinkErrors.gitRejected, :final message) =>
          message,
        LinkRemoteException(code: 'stale') =>
          zh
              ? '主机的 HEAD 已更改。请重新打开分支菜单。'
              : 'The host HEAD changed. Reopen the branch menu.',
        LinkRemoteException(code: LinkErrors.busy) =>
          zh
              ? '主机仓库正在使用中。请稍后重试。'
              : 'The host repository is busy. Try again later.',
        _ when listing =>
          zh ? '无法读取主机的本地分支。' : 'Could not list local branches on the host.',
        _ => zh ? '无法切换主机分支。' : 'Could not switch the host branch.',
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    final branch = widget.project.branch!;
    final current = _head?.branch;
    final l10n = context.l10n;
    final zh = _zh(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_unsupported)
          _projectLabel(Codicons.gitBranch, branch)
        else
          Focus(
            key: const ValueKey('host-branch-picker'),
            focusNode: _focus,
            onKeyEvent: _handleKey,
            child: ComposerPicker(
              key: _picker,
              options: [for (final name in _branches) _branchOption(name)],
              selected: _branchOption(current ?? ''),
              // The menu checks the RPC snapshot, while the pill follows the
              // catalog, including after a successful switch.
              label: branch,
              foreground: AppColors.textFaint,
              descriptionAside: true,
              title: l10n.branchBarSwitch,
              searchPlaceholder: l10n.branchBarSearch,
              focusNode: _focus,
              enabled: !_switching,
              emptyMessage: _listing != null
                  ? (zh ? '正在读取分支…' : 'Loading branches…')
                  : (zh ? '没有本地分支' : 'No local branches'),
              onOpen: () => unawaited(_list()),
              onSelected: (option) => unawaited(_switch(option.id)),
            ),
          ),
        if (_error case final error?)
          Semantics(
            liveRegion: true,
            child: Text(
              error,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 12,
              ),
            ),
          ),
      ],
    );
  }
}

class _HostContextMeter extends StatefulWidget {
  const _HostContextMeter({super.key, required this.usage});

  final ContextUsage usage;

  @override
  State<_HostContextMeter> createState() => _HostContextMeterState();
}

class _HostContextMeterState extends State<_HostContextMeter> {
  final _group = Object();
  bool _open = false;

  void _close() {
    if (_open) setState(() => _open = false);
  }

  @override
  Widget build(BuildContext context) => Align(
    alignment: AlignmentDirectional.centerEnd,
    // Use the native panel, with only the usage fields in the wire schema.
    child: FloatingLayer(
      visible: _open,
      placement: (side: FloatingSide.top, align: FloatingAlign.end),
      tapRegionGroupId: _group,
      onTapOutside: _close,
      builder: (context) => SizedBox(
        width: 460,
        child: ContextUsagePanel(usage: widget.usage, onClose: _close),
      ),
      child: TapRegion(
        groupId: _group,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: ContextMeter(
            usage: widget.usage,
            active: _open,
            labeled: true,
            tooltip: context.l10n.composerContextUsage,
            onTap: () => setState(() => _open = !_open),
          ),
        ),
      ),
    ),
  );
}

bool _zh(BuildContext context) =>
    Localizations.localeOf(context).languageCode == 'zh';

class DesktopHostActionError extends StatelessWidget {
  const DesktopHostActionError({super.key, required this.controls});

  final DesktopHostSessionControls controls;

  @override
  Widget build(BuildContext context) {
    final zh = _zh(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      child: Semantics(
        liveRegion: true,
        child: Text(
          [
            if (controls.choiceFailed)
              zh ? '无法更改主机设置。' : 'Could not change the host setting.',
            if (controls.stopFailed)
              zh ? '无法停止主机会话。' : 'Could not stop the host session.',
          ].join('\n'),
          style: TextStyle(
            color: Theme.of(context).colorScheme.error,
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}
