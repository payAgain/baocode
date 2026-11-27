import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../settings/pages/settings_widgets.dart' show SettingsColors;
import '../theme/app_theme.dart' show AppColors;
import '../theme/workbench_theme.dart' show themeColors;

/// Modern compact desktop modal frame backed by [AlertDialog].
class RemoteActionDialog extends StatelessWidget {
  const RemoteActionDialog({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    required this.actions,
    this.destructive = false,
    this.scrollable = true,
    this.maxWidth = 400,
  });

  final IconData icon;
  final String title;
  final Widget body;
  final List<Widget> actions;
  final bool destructive;
  final bool scrollable;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final tint = destructive
        ? Theme.of(context).colorScheme.error
        : AppColors.accent;
    final available = math.max(240.0, MediaQuery.sizeOf(context).width - 48);
    final width = math.min(maxWidth, available);
    final content = DefaultTextStyle.merge(
      style: TextStyle(
        fontSize: 13,
        height: 1.5,
        color: SettingsColors.textSecondary,
      ),
      child: body,
    );
    return AlertDialog(
      backgroundColor: AppColors.surfaceRaised,
      surfaceTintColor: Colors.transparent,
      elevation: 16,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      titlePadding: EdgeInsets.zero,
      contentPadding: EdgeInsets.zero,
      actionsPadding: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: SettingsColors.stroke),
      ),
      content: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: width,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
                child: Row(
                  children: [
                    Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: tint.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      alignment: Alignment.center,
                      child: Icon(icon, size: 16, color: tint),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                          color: SettingsColors.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (scrollable)
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
                    child: content,
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 0, 18, 16),
                  child: content,
                ),
              Container(height: 1, color: SettingsColors.divider),
              Container(
                color: Color.alphaBlend(
                  SettingsColors.textPrimary.withValues(alpha: 0.02),
                  AppColors.surfaceRaised,
                ),
                padding: const EdgeInsets.fromLTRB(16, 11, 16, 12),
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 6,
                  children: actions,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

ButtonStyle remoteDialogSecondaryButtonStyle(BuildContext context) {
  final textStyle = Theme.of(
    context,
  ).textTheme.labelMedium?.copyWith(fontSize: 12.5, fontWeight: FontWeight.w500);
  return ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(Size(0, 30)),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 14, vertical: 0),
    ),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    textStyle: textStyle == null ? null : WidgetStatePropertyAll(textStyle),
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
    ),
    side: WidgetStatePropertyAll(BorderSide(color: SettingsColors.stroke)),
    foregroundColor: WidgetStateProperty.resolveWith(
      (states) =>
          states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.pressed)
          ? SettingsColors.textPrimary
          : SettingsColors.textSecondary,
    ),
    backgroundColor: WidgetStateProperty.resolveWith(
      (states) =>
          states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.pressed)
          ? SettingsColors.hover
          : Colors.transparent,
    ),
    overlayColor: WidgetStatePropertyAll(SettingsColors.hover),
  );
}

ButtonStyle remoteDialogPrimaryButtonStyle(BuildContext context) {
  final textStyle = Theme.of(
    context,
  ).textTheme.labelMedium?.copyWith(fontSize: 12.5, fontWeight: FontWeight.w500);
  final bg = themeColors['button.background'];
  final hoverBg = themeColors['button.hoverBackground'];
  final fg = themeColors['button.foreground'];
  return ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(Size(0, 30)),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 14, vertical: 0),
    ),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    textStyle: textStyle == null ? null : WidgetStatePropertyAll(textStyle),
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
    ),
    backgroundColor: WidgetStateProperty.resolveWith(
      (states) =>
          states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.pressed)
          ? hoverBg
          : bg,
    ),
    foregroundColor: WidgetStatePropertyAll(fg),
    overlayColor: WidgetStatePropertyAll(hoverBg),
  );
}

ButtonStyle remoteDialogDangerButtonStyle(BuildContext context) {
  final textStyle = Theme.of(
    context,
  ).textTheme.labelMedium?.copyWith(fontSize: 12.5, fontWeight: FontWeight.w500);
  final scheme = Theme.of(context).colorScheme;
  final bg = scheme.error;
  final hoverBg = Color.alphaBlend(
    Colors.black.withValues(alpha: 0.14),
    bg,
  );
  return ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(Size(0, 30)),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 14, vertical: 0),
    ),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    textStyle: textStyle == null ? null : WidgetStatePropertyAll(textStyle),
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
    ),
    backgroundColor: WidgetStateProperty.resolveWith(
      (states) =>
          states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.pressed)
          ? hoverBg
          : bg,
    ),
    foregroundColor: WidgetStatePropertyAll(scheme.onError),
    overlayColor: WidgetStatePropertyAll(hoverBg),
  );
}
