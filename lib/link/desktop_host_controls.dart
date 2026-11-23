import 'dart:async';

import 'package:bao_link/bao_link.dart';
import 'package:flutter/material.dart';

import '../chat/chat_session.dart' show ModelSettingChoice;
import '../chat/composer/composer_picker.dart';
import '../chat/composer/pickers_row.dart';
import '../chat/floating/floating_layer.dart';
import '../chat/floating/floating_placement.dart';
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

/// The host's project and its reported window usage. The project path and
/// branch are display-only: neither is resolved against the client machine.
class DesktopHostSessionFooter extends StatelessWidget {
  const DesktopHostSessionFooter({super.key, this.project, this.controls});

  final ProjectInfo? project;
  final DesktopHostSessionControls? controls;

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
                : _HostProject(project),
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

class _HostProject extends StatelessWidget {
  const _HostProject(this.project);

  final ProjectInfo project;

  @override
  Widget build(BuildContext context) {
    final color = AppColors.textFaint;
    final name = project.name.isEmpty ? project.path : project.name;
    final branch = project.branch;
    Widget label(IconData icon, String text) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: color, fontSize: 12),
          ),
        ),
      ],
    );
    final location = Row(
      children: [
        if (name.isNotEmpty) Flexible(child: label(Codicons.folder, name)),
        if (branch != null && branch.isNotEmpty) ...[
          if (name.isNotEmpty) const SizedBox(width: 8),
          Flexible(child: label(Codicons.gitBranch, branch)),
        ],
      ],
    );
    return project.path.isEmpty
        ? location
        : IdeHover(message: project.path, child: location);
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
