import 'package:flutter/material.dart';

import '../ide/ide_switch.dart';
import '../settings/pages/settings_widgets.dart' show SettingsColors;
import '../theme/app_theme.dart';
import '../theme/workbench_theme.dart' show themeColors;

Color get _editorForeground => themeColors['editor.foreground'];

Color _surfaceMix(double foregroundAlpha, Color base) => Color.alphaBlend(
  _editorForeground.withValues(alpha: _editorForeground.a * foregroundAlpha),
  base,
);

/// Soft tonal surface for nested cards inside Bot dialogs.
Color get botDialogCardColor => _surfaceMix(0.045, AppColors.surface);

/// Subtle footer strip tint for Bot dialogs.
Color get botDialogFooterColor => _surfaceMix(0.025, AppColors.surface);

/// Recessed fill for modern inputs and segmented controls.
Color get botInputFillColor => _surfaceMix(0.035, AppColors.code);

/// Shared chrome for the local and paired desktop Bot editors.
class BotEditorLayout extends StatelessWidget {
  const BotEditorLayout({
    super.key,
    required this.title,
    required this.icon,
    required this.body,
    this.name,
    this.avatar,
    this.close,
    this.controller,
    this.actions,
    this.status,
    this.busy = false,
    this.warning = false,
  });

  final String title;
  final String? name;
  final IconData icon;
  final Widget? avatar;
  final Widget? close;
  final ScrollController? controller;
  final Widget body;
  final Widget? actions;
  final Widget? status;
  final bool busy;
  final bool warning;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final compact = bounds.maxWidth < 240;
      final inset = compact ? 8.0 : (bounds.maxWidth < 380 ? 12.0 : 20.0);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _EditorBand(
            inset: inset,
            vertical: 11,
            child: Row(
              children: [
                if (!compact) ...[
                  BotEditorIcon(icon: icon, warning: warning, child: avatar),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Semantics(
                        header: true,
                        child: Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style:
                              (name == null
                                      ? Theme.of(context).textTheme.titleMedium
                                      : Theme.of(context).textTheme.labelMedium)
                                  ?.copyWith(
                                    color: name == null
                                        ? SettingsColors.textPrimary
                                        : SettingsColors.textSecondary,
                                    fontWeight: name == null
                                        ? FontWeight.w600
                                        : FontWeight.w500,
                                  ),
                        ),
                      ),
                      if (name case final name?)
                        Tooltip(
                          message: name,
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(
                                  color: SettingsColors.textPrimary,
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (close != null) ...[const SizedBox(width: 4), close!],
              ],
            ),
          ),
          if (busy)
            const LinearProgressIndicator(minHeight: 2)
          else
            Container(height: 1, color: SettingsColors.divider),
          if (status != null) _EditorBand(inset: inset, child: status!),
          Expanded(
            child: SingleChildScrollView(
              controller: controller,
              primary: false,
              padding: EdgeInsets.symmetric(horizontal: inset, vertical: 16),
              child: _EditorWidth(child: body),
            ),
          ),
          if (actions != null) ...[
            Container(height: 1, color: SettingsColors.divider),
            _EditorBand(inset: inset, vertical: 10, child: actions!),
          ],
        ],
      );
    },
  );
}

class _EditorWidth extends StatelessWidget {
  const _EditorWidth({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 600),
      child: child,
    ),
  );
}

class _EditorBand extends StatelessWidget {
  const _EditorBand({
    required this.inset,
    required this.child,
    this.vertical = 8,
  });

  final double inset;
  final double vertical;
  final Widget child;

  @override
  Widget build(BuildContext context) => Material(
    color: AppColors.conversationSurface,
    child: Padding(
      padding: EdgeInsets.symmetric(horizontal: inset, vertical: vertical),
      child: _EditorWidth(
        child: SizedBox(width: double.infinity, child: child),
      ),
    ),
  );
}

class BotEditorIcon extends StatelessWidget {
  const BotEditorIcon({
    super.key,
    required this.icon,
    this.child,
    this.warning = false,
    this.accentColor,
    this.size = 40,
  });

  final IconData icon;
  final Widget? child;
  final bool warning;
  final Color? accentColor;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final tint = warning ? colors.error : (accentColor ?? AppColors.accent);
    final radius = size * 0.25;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            tint.withValues(alpha: 0.2),
            tint.withValues(alpha: 0.08),
          ],
        ),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: tint.withValues(alpha: 0.26)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: SizedBox.square(
          dimension: size,
          child: Center(
            child: child ?? Icon(icon, size: size * 0.5, color: tint),
          ),
        ),
      ),
    );
  }
}

class BotEditorSection extends StatelessWidget {
  const BotEditorSection({
    super.key,
    required this.title,
    required this.children,
    this.danger = false,
  });

  final String title;
  final List<Widget> children;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final contrastBorder = themeColors.get('contrastBorder');
    final side = danger
        ? BorderSide(color: theme.colorScheme.error.withValues(alpha: 0.26))
        : (contrastBorder != null
              ? BorderSide(color: contrastBorder)
              : BorderSide.none);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 7),
            child: Semantics(
              header: true,
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  color: danger
                      ? theme.colorScheme.error
                      : SettingsColors.textSecondary,
                ),
              ),
            ),
          ),
          Material(
            color: SettingsColors.card,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: side,
            ),
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 10,
                children: children,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Sleek recessed input decoration without a border-slicing floating label.
InputDecoration botEditorInput(
  String? label, {
  String? hint,
  String? hintText,
  String? errorText,
  Widget? prefixIcon,
  Widget? suffixIcon,
  bool multiline = false,
  bool filled = true,
}) => InputDecoration(
  labelText: label,
  hintText: hintText,
  helperText: hint,
  helperMaxLines: 4,
  errorText: errorText,
  errorMaxLines: 3,
  prefixIcon: prefixIcon,
  suffixIcon: suffixIcon,
  isDense: true,
  filled: filled,
  fillColor: filled ? botInputFillColor : null,
  alignLabelWithHint: multiline,
  labelStyle: TextStyle(
    fontSize: 12.5,
    color: SettingsColors.textSecondary,
  ),
  hintStyle: TextStyle(
    fontSize: 13,
    color: SettingsColors.textQuaternary,
  ),
  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
  border: OutlineInputBorder(
    borderRadius: BorderRadius.circular(9),
    borderSide: BorderSide(color: SettingsColors.stroke),
  ),
  enabledBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(9),
    borderSide: BorderSide(color: SettingsColors.stroke),
  ),
  focusedBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(9),
    borderSide: BorderSide(
      color: AppColors.accent.withValues(alpha: 0.8),
      width: 1.2,
    ),
  ),
);

/// Border-notch-free inset field whose label renders inside the rounded surface
/// with a subtle focus glow while remaining discoverable as a [TextFormField].
class BotEditorInsetField extends StatefulWidget {
  const BotEditorInsetField({
    super.key,
    this.fieldKey,
    this.controller,
    this.initialValue,
    this.focusNode,
    required this.label,
    this.hint,
    this.multiline = false,
    this.minLines,
    this.maxLines,
    this.keyboardType,
    this.textInputAction,
    this.enabled = true,
    this.validator,
    this.onChanged,
  });

  final Key? fieldKey;
  final TextEditingController? controller;
  final String? initialValue;
  final FocusNode? focusNode;
  final String label;
  final String? hint;
  final bool multiline;
  final int? minLines;
  final int? maxLines;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final bool enabled;
  final FormFieldValidator<String>? validator;
  final ValueChanged<String>? onChanged;

  @override
  State<BotEditorInsetField> createState() => _BotEditorInsetFieldState();
}

class _BotEditorInsetFieldState extends State<BotEditorInsetField> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accent;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Focus(
          skipTraversal: true,
          onFocusChange: (focused) => setState(() => _focused = focused),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              color: botInputFillColor,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(
                color: _focused
                    ? accent.withValues(alpha: 0.8)
                    : SettingsColors.stroke,
                width: _focused ? 1.2 : 1,
              ),
              boxShadow: _focused
                  ? [
                      BoxShadow(
                        color: accent.withValues(alpha: 0.14),
                        blurRadius: 6,
                        spreadRadius: 1,
                      ),
                    ]
                  : const [],
            ),
            child: TextFormField(
              key: widget.fieldKey,
              controller: widget.controller,
              initialValue: widget.initialValue,
              focusNode: widget.focusNode,
              enabled: widget.enabled,
              minLines: widget.minLines ?? (widget.multiline ? 2 : 1),
              maxLines: widget.maxLines ?? (widget.multiline ? 8 : 1),
              keyboardType: widget.keyboardType,
              textInputAction:
                  widget.textInputAction ??
                  (widget.multiline
                      ? TextInputAction.newline
                      : TextInputAction.next),
              style: TextStyle(
                fontSize: 13.5,
                height: 1.45,
                color: SettingsColors.textPrimary,
              ),
              decoration: InputDecoration(
                labelText: widget.label,
                floatingLabelBehavior: FloatingLabelBehavior.always,
                isDense: true,
                labelStyle: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                  color: _focused ? accent : SettingsColors.textSecondary,
                ),
                floatingLabelStyle: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w500,
                  color: _focused ? accent : SettingsColors.textSecondary,
                ),
                contentPadding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                errorBorder: InputBorder.none,
                focusedErrorBorder: InputBorder.none,
              ),
              validator: widget.validator,
              onChanged: widget.onChanged,
            ),
          ),
        ),
        if (widget.hint case final hint? when hint.isNotEmpty) ...[
          const SizedBox(height: 5),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Text(
              hint,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.4,
                color: SettingsColors.textTertiary,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Sleek desktop switch row using BaoCode's [IdeSwitch] instead of Material's
/// oversized pill toggle.
class BotEditorSwitchTile extends StatelessWidget {
  const BotEditorSwitchTile({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    this.onChanged,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final enabled = onChanged != null;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        hoverColor: SettingsColors.hover,
        onTap: enabled ? () => onChanged!(!value) : null,
        child: Opacity(
          opacity: enabled ? 1 : 0.55,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 9),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w500,
                          color: SettingsColors.textPrimary,
                        ),
                      ),
                      if (subtitle case final text? when text.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          text,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.4,
                            color: SettingsColors.textSecondary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                IdeSwitch(
                  value: value,
                  enabled: enabled,
                  semanticLabel: title,
                  height: 18,
                  onChanged: onChanged ?? (_) {},
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

typedef BotEditorMember = ({String id, String name});

class BotEditorMemberTile extends StatelessWidget {
  const BotEditorMemberTile({
    super.key,
    required this.member,
    required this.selected,
    this.onChanged,
  });

  final BotEditorMember member;
  final bool selected;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => CheckboxListTile(
    contentPadding: EdgeInsets.zero,
    controlAffinity: ListTileControlAffinity.leading,
    title: Text(member.name),
    value: selected,
    onChanged: onChanged == null
        ? null
        : (checked) => onChanged!(checked == true),
  );
}

class BotEditorLeadPicker extends StatelessWidget {
  const BotEditorLeadPicker({
    super.key,
    required this.pickerKey,
    required this.label,
    required this.defaultLabel,
    required this.members,
    required this.lead,
    this.onChanged,
  });

  final Key pickerKey;
  final String label;
  final String defaultLabel;
  final List<BotEditorMember> members;
  final String? lead;
  final ValueChanged<String?>? onChanged;

  @override
  Widget build(BuildContext context) => InputDecorator(
    decoration: botEditorInput(label),
    child: DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        key: pickerKey,
        isExpanded: true,
        value: members.any((member) => member.id == lead) ? lead : '',
        items: [
          DropdownMenuItem(value: '', child: Text(defaultLabel)),
          for (final member in members)
            DropdownMenuItem(
              value: member.id,
              child: Text(member.name, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: onChanged == null
            ? null
            : (id) => onChanged!(id == '' ? null : id),
      ),
    ),
  );
}

class BotEditorActions extends StatelessWidget {
  const BotEditorActions({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => OverflowBar(
    alignment: MainAxisAlignment.end,
    overflowAlignment: OverflowBarAlignment.end,
    spacing: 8,
    overflowSpacing: 6,
    children: children,
  );
}

ButtonStyle botEditorButtonStyle(
  BuildContext context, {
  bool destructive = false,
}) {
  final theme = Theme.of(context);
  final colors = theme.colorScheme;
  return FilledButton.styleFrom(
    minimumSize: const Size(72, 34),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    textStyle: theme.textTheme.labelLarge?.copyWith(
      fontSize: 13,
      fontWeight: FontWeight.w600,
    ),
    backgroundColor: destructive ? colors.error : null,
    foregroundColor: destructive ? colors.onError : null,
  );
}

/// Borderless soft-tonal secondary action style for desktop panels & footers.
ButtonStyle botEditorTonalButtonStyle(
  BuildContext context, {
  bool destructive = false,
}) {
  final theme = Theme.of(context);
  final colors = theme.colorScheme;
  return TextButton.styleFrom(
    minimumSize: const Size(68, 34),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    backgroundColor: destructive
        ? colors.error.withValues(alpha: 0.12)
        : _surfaceMix(0.06, AppColors.surface),
    foregroundColor: destructive ? colors.error : SettingsColors.textPrimary,
    textStyle: theme.textTheme.labelLarge?.copyWith(
      fontSize: 13,
      fontWeight: FontWeight.w500,
    ),
  );
}

/// Borderless subtle ghost action for inline card & toolbar controls.
ButtonStyle botEditorGhostButtonStyle(
  BuildContext context, {
  bool destructive = false,
}) {
  final theme = Theme.of(context);
  final colors = theme.colorScheme;
  return TextButton.styleFrom(
    minimumSize: const Size(0, 28),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
    foregroundColor: destructive ? colors.error : SettingsColors.textSecondary,
    textStyle: theme.textTheme.labelMedium?.copyWith(
      fontSize: 12,
      fontWeight: FontWeight.w500,
    ),
  );
}

/// Alias kept for secondary outlined buttons that are being transitioned to tonal.
ButtonStyle botEditorSecondaryButtonStyle(
  BuildContext context, {
  bool destructive = false,
}) => botEditorTonalButtonStyle(context, destructive: destructive);

/// Alias kept for inline compact actions using the borderless ghost style.
ButtonStyle botEditorCompactButtonStyle(
  BuildContext context, {
  bool destructive = false,
}) => botEditorGhostButtonStyle(context, destructive: destructive);

/// Bordered rounded dialog shape used across Bot management dialogs.
ShapeBorder botEditorDialogShape() => RoundedRectangleBorder(
  borderRadius: BorderRadius.circular(16),
  side: BorderSide(color: SettingsColors.stroke),
);

/// Semantic tone for status badges and inline notices.
enum BotEditorTone { neutral, accent, success, warning, danger }

({Color foreground, Color background, Color border, IconData icon})
_tonePalette(BuildContext context, BotEditorTone tone) {
  final colors = Theme.of(context).colorScheme;
  return switch (tone) {
    BotEditorTone.neutral => (
      foreground: SettingsColors.textSecondary,
      background: _surfaceMix(0.05, AppColors.surface),
      border: SettingsColors.stroke,
      icon: Icons.info_outline,
    ),
    BotEditorTone.accent => (
      foreground: AppColors.accent,
      background: AppColors.accent.withValues(alpha: 0.1),
      border: AppColors.accent.withValues(alpha: 0.3),
      icon: Icons.info_outline,
    ),
    BotEditorTone.success => (
      foreground: AppColors.added,
      background: AppColors.added.withValues(alpha: 0.11),
      border: AppColors.added.withValues(alpha: 0.3),
      icon: Icons.check_circle_outline,
    ),
    BotEditorTone.warning => (
      foreground: AppColors.caution,
      background: AppColors.caution.withValues(alpha: 0.11),
      border: AppColors.caution.withValues(alpha: 0.35),
      icon: Icons.warning_amber_rounded,
    ),
    BotEditorTone.danger => (
      foreground: colors.error,
      background: colors.error.withValues(alpha: 0.1),
      border: colors.error.withValues(alpha: 0.35),
      icon: Icons.error_outline,
    ),
  };
}

/// Modern floating desktop modal frame backed by [AlertDialog].
class BotModernDialog extends StatelessWidget {
  const BotModernDialog({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.headerTrailing,
    required this.body,
    this.actions = const [],
    this.footerLeading,
    this.width = 540,
    this.height,
    this.maxHeight,
    this.bodyPadding = const EdgeInsets.fromLTRB(22, 16, 22, 18),
    this.busy = false,
    this.warning = false,
    this.accentColor,
    this.showCloseButton = true,
    this.scrollable = true,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? headerTrailing;
  final Widget body;
  final List<Widget> actions;
  final Widget? footerLeading;
  final double width;
  final double? height;
  final double? maxHeight;
  final EdgeInsetsGeometry bodyPadding;
  final bool busy;
  final bool warning;
  final Color? accentColor;
  final bool showCloseButton;
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final tint = warning ? colors.error : (accentColor ?? AppColors.accent);
    final viewportHeight = MediaQuery.sizeOf(context).height * 0.9;
    final resolvedHeight = height != null
        ? (height! > viewportHeight ? viewportHeight : height!)
        : null;
    final maxAllowedHeight = maxHeight ?? viewportHeight;

    final header = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            tint.withValues(alpha: 0.08),
            Colors.transparent,
          ],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 14, 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            BotEditorIcon(
              icon: icon,
              warning: warning,
              accentColor: accentColor,
              size: 36,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w600,
                      color: SettingsColors.textPrimary,
                    ),
                  ),
                  if (subtitle case final text? when text.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: SettingsColors.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (headerTrailing case final widget?) ...[
              const SizedBox(width: 8),
              widget,
            ],
            if (showCloseButton) ...[
              const SizedBox(width: 4),
              Material(
                type: MaterialType.transparency,
                child: InkWell(
                  borderRadius: BorderRadius.circular(7),
                  hoverColor: SettingsColors.hover,
                  onTap: busy ? null : () => Navigator.maybePop(context),
                  child: SizedBox.square(
                    dimension: 28,
                    child: Icon(
                      Icons.close,
                      size: 16,
                      color: SettingsColors.iconTertiary,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );

    final footer = (actions.isNotEmpty || footerLeading != null)
        ? DecoratedBox(
            decoration: BoxDecoration(
              color: botDialogFooterColor,
              border: Border(top: BorderSide(color: SettingsColors.divider)),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Row(
                children: [
                  if (footerLeading case final leading?) ...[
                    leading,
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: OverflowBar(
                      alignment: MainAxisAlignment.end,
                      overflowAlignment: OverflowBarAlignment.end,
                      spacing: 8,
                      overflowSpacing: 8,
                      children: actions,
                    ),
                  ),
                ],
              ),
            ),
          )
        : null;

    return AlertDialog(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shadowColor: Colors.black.withValues(alpha: 0.32),
      shape: botEditorDialogShape(),
      clipBehavior: Clip.antiAlias,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      titlePadding: EdgeInsets.zero,
      contentPadding: EdgeInsets.zero,
      actionsPadding: EdgeInsets.zero,
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: width,
          maxHeight: resolvedHeight ?? maxAllowedHeight,
        ),
        child: SizedBox(
          width: width,
          height: resolvedHeight,
          child: Column(
            mainAxisSize: resolvedHeight == null
                ? MainAxisSize.min
                : MainAxisSize.max,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              if (busy)
                const LinearProgressIndicator(minHeight: 2)
              else
                Container(height: 1, color: SettingsColors.divider),
              if (scrollable)
                Flexible(
                  child: SingleChildScrollView(
                    padding: bodyPadding,
                    child: body,
                  ),
                )
              else
                Expanded(
                  child: Padding(padding: bodyPadding, child: body),
                ),
              ?footer,
            ],
          ),
        ),
      ),
    );
  }
}

/// Consistent dialog header matching [BotEditorLayout]'s top band.
class BotEditorDialogHeader extends StatelessWidget {
  const BotEditorDialogHeader({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.warning = false,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final bool warning;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      BotEditorIcon(icon: icon, warning: warning, size: 36),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 15.5,
                fontWeight: FontWeight.w600,
                color: SettingsColors.textPrimary,
              ),
            ),
            if (subtitle case final text? when text.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: SettingsColors.textSecondary,
                ),
              ),
            ],
          ],
        ),
      ),
      if (trailing case final widget?) ...[const SizedBox(width: 8), widget],
    ],
  );
}

/// Full-width settings navigation row with tinted icon well and soft hover.
class BotEditorNavTile extends StatelessWidget {
  const BotEditorNavTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
    this.trailing,
    this.tint,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final color = tint ?? AppColors.accent;
    final iconColor = enabled
        ? color
        : SettingsColors.textQuaternary;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        hoverColor: SettingsColors.hover,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 9),
          child: Row(
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: color.withValues(alpha: enabled ? 0.14 : 0.06),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: SizedBox.square(
                  dimension: 34,
                  child: Icon(icon, size: 17, color: iconColor),
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w500,
                        color: enabled
                            ? SettingsColors.textPrimary
                            : SettingsColors.textQuaternary,
                      ),
                    ),
                    if (subtitle case final text? when text.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        text,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.35,
                          color: SettingsColors.textSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing case final widget?) ...[
                const SizedBox(width: 6),
                widget,
              ],
              const SizedBox(width: 4),
              Icon(
                Icons.chevron_right,
                size: 18,
                color: SettingsColors.iconTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Borderless tonal card for grouped content inside Bot editors and dialogs.
class BotEditorCard extends StatelessWidget {
  const BotEditorCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(13),
    this.backgroundColor,
    this.borderColor,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? backgroundColor;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final contrastBorder = themeColors.get('contrastBorder');
    final side = borderColor != null
        ? BorderSide(color: borderColor!)
        : (contrastBorder != null
              ? BorderSide(color: contrastBorder)
              : BorderSide.none);
    return Material(
      color: backgroundColor ?? botDialogCardColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(11),
        side: side,
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(padding: padding, child: child),
    );
  }
}

/// Pill-shaped status tag with live colored dot indicator.
class BotStatusPill extends StatelessWidget {
  const BotStatusPill({
    super.key,
    required this.label,
    this.tone = BotEditorTone.neutral,
  });

  final String label;
  final BotEditorTone tone;

  @override
  Widget build(BuildContext context) {
    final palette = _tonePalette(context, tone);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: palette.foreground,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
                color: palette.foreground,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Inline monospace pill for commands, paths, and JSON snippets.
class BotCodeChip extends StatelessWidget {
  const BotCodeChip(this.text, {super.key, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: AppColors.code,
      borderRadius: BorderRadius.circular(5),
      border: Border.all(color: SettingsColors.stroke),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: Text(
        text,
        style: AppFonts.uiCodeStyle(11.5).copyWith(
          color: color ?? SettingsColors.textPrimary,
          fontWeight: FontWeight.w500,
        ),
      ),
    ),
  );
}

/// Recessed segmented control replacing underline Material [TabBar]s.
class BotSegmentedTabs extends StatelessWidget {
  const BotSegmentedTabs({
    super.key,
    required this.tabs,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<String> tabs;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: AppColors.code,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: SettingsColors.divider),
    ),
    child: Padding(
      padding: const EdgeInsets.all(3),
      child: Row(
        children: [
          for (var i = 0; i < tabs.length; i++)
            Expanded(
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  borderRadius: BorderRadius.circular(7),
                  hoverColor: i == selectedIndex
                      ? Colors.transparent
                      : SettingsColors.hover,
                  onTap: () => onSelected(i),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 140),
                    curve: Curves.easeOut,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    decoration: i == selectedIndex
                        ? BoxDecoration(
                            color: botDialogCardColor,
                            borderRadius: BorderRadius.circular(7),
                            border: Border.all(color: SettingsColors.stroke),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.2),
                                blurRadius: 4,
                                offset: const Offset(0, 1),
                              ),
                            ],
                          )
                        : null,
                    child: Center(
                      child: Text(
                        tabs[i],
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: i == selectedIndex
                              ? FontWeight.w600
                              : FontWeight.w500,
                          color: i == selectedIndex
                              ? SettingsColors.textPrimary
                              : SettingsColors.textSecondary,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

/// Compact rounded dropdown without Material's notch box.
class BotModernDropdown<T> extends StatelessWidget {
  const BotModernDropdown({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.hint,
    this.width,
  });

  final T? value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final Widget? hint;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final child = DecoratedBox(
      decoration: BoxDecoration(
        color: botInputFillColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: SettingsColors.stroke),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: SizedBox(
          height: 34,
          child: DropdownButtonHideUnderline(
            child: DropdownButton<T>(
              value: value,
              items: items,
              onChanged: onChanged,
              hint: hint,
              isExpanded: true,
              isDense: true,
              dropdownColor: AppColors.surfaceRaised,
              borderRadius: BorderRadius.circular(10),
              icon: Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 17,
                color: SettingsColors.textSecondary,
              ),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontSize: 13,
                color: SettingsColors.textPrimary,
              ),
            ),
          ),
        ),
      ),
    );
    return width == null ? child : SizedBox(width: width, child: child);
  }
}

/// Compact pill-free status tag kept for index & path badges.
class BotEditorStatusBadge extends StatelessWidget {
  const BotEditorStatusBadge({
    super.key,
    required this.label,
    this.tone = BotEditorTone.neutral,
    this.mono = false,
  });

  final String label;
  final BotEditorTone tone;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final palette = _tonePalette(context, tone);
    final baseStyle = mono
        ? AppFonts.uiCodeStyle(11.5)
        : Theme.of(context).textTheme.labelSmall;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.background,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Text(
          label,
          style: baseStyle?.copyWith(
            color: palette.foreground,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// Left-accented tinted callout for notices, warnings, and errors.
class BotEditorNotice extends StatelessWidget {
  const BotEditorNotice({
    super.key,
    this.message,
    this.child,
    this.tone = BotEditorTone.neutral,
    this.icon,
  }) : assert(message != null || child != null);

  final String? message;
  final Widget? child;
  final BotEditorTone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final palette = _tonePalette(context, tone);
    return ClipRRect(
      borderRadius: BorderRadius.circular(9),
      child: DecoratedBox(
        decoration: BoxDecoration(color: palette.background),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 3, color: palette.foreground),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: Icon(
                          icon ?? palette.icon,
                          size: 16,
                          color: palette.foreground,
                        ),
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: DefaultTextStyle.merge(
                          style: TextStyle(
                            fontSize: 12.5,
                            color: tone == BotEditorTone.danger
                                ? palette.foreground
                                : SettingsColors.textPrimary,
                            height: 1.45,
                          ),
                          child: child ?? Text(message!),
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
    );
  }
}

class BotEditorDangerButton extends StatelessWidget {
  const BotEditorDangerButton({
    super.key,
    required this.label,
    required this.icon,
    this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Align(
    alignment: AlignmentDirectional.centerStart,
    child: OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        foregroundColor: Theme.of(context).colorScheme.error,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      onPressed: onPressed,
      icon: Icon(icon, size: 17),
      label: Text(label),
    ),
  );
}
