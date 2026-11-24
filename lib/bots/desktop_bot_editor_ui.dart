import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

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
                          style: name == null
                              ? Theme.of(context).textTheme.titleMedium
                              : Theme.of(context).textTheme.labelMedium,
                        ),
                      ),
                      if (name case final name?)
                        Tooltip(
                          message: name,
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium,
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
            const Divider(height: 1, thickness: 1),
          if (status != null) _EditorBand(inset: inset, child: status!),
          Expanded(
            child: SingleChildScrollView(
              controller: controller,
              primary: false,
              padding: EdgeInsets.symmetric(horizontal: inset, vertical: 14),
              child: _EditorWidth(child: body),
            ),
          ),
          if (actions != null) ...[
            const Divider(height: 1, thickness: 1),
            _EditorBand(inset: inset, child: actions!),
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
  const _EditorBand({required this.inset, required this.child});

  final double inset;
  final Widget child;

  @override
  Widget build(BuildContext context) => Material(
    color: AppColors.surface,
    child: Padding(
      padding: EdgeInsets.symmetric(horizontal: inset, vertical: 8),
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
  });

  final IconData icon;
  final Widget? child;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: warning ? colors.errorContainer : colors.secondaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox.square(
          dimension: 40,
          child: Center(
            child:
                child ??
                Icon(
                  icon,
                  size: 21,
                  color: warning
                      ? colors.onErrorContainer
                      : colors.onSecondaryContainer,
                ),
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
    return Material(
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: AppColors.partBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 10,
          children: [
            Semantics(
              header: true,
              child: Text(
                title,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: danger ? theme.colorScheme.error : null,
                ),
              ),
            ),
            ...children,
          ],
        ),
      ),
    );
  }
}

InputDecoration botEditorInput(
  String label, {
  String? hint,
  bool multiline = false,
}) => InputDecoration(
  labelText: label,
  helperText: hint,
  helperMaxLines: 4,
  isDense: true,
  alignLabelWithHint: multiline,
  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
  border: OutlineInputBorder(borderRadius: BorderRadius.circular(7)),
);

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
  final colors = Theme.of(context).colorScheme;
  return FilledButton.styleFrom(
    minimumSize: const Size(72, 36),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    backgroundColor: destructive ? colors.error : null,
    foregroundColor: destructive ? colors.onError : null,
  );
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
