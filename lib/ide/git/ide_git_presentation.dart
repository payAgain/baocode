import 'package:flutter/material.dart';

import '../../base/give_way_row.dart';
import '../../l10n/l10n.dart';
import '../../theme/codicons.dart';
import '../../theme/workbench_theme.dart';
import '../../workspace/islands.dart';
import '../ide_button.dart';
import '../ide_hover.dart';
import '../ide_list.dart';
import 'git_graph_painter.dart';
import 'git_model.dart';

/// Gives pointer-driven Git controls a tab stop and keyboard activation.
class IdeGitKeyboardAction extends StatefulWidget {
  const IdeGitKeyboardAction({
    super.key,
    required this.onActivate,
    required this.child,
  });

  final VoidCallback onActivate;
  final Widget child;

  @override
  State<IdeGitKeyboardAction> createState() => _IdeGitKeyboardActionState();
}

class _IdeGitKeyboardActionState extends State<IdeGitKeyboardAction> {
  bool _showFocus = false;

  @override
  Widget build(BuildContext context) => FocusableActionDetector(
    onShowFocusHighlight: (show) => setState(() => _showFocus = show),
    actions: {
      ActivateIntent: CallbackAction<ActivateIntent>(
        onInvoke: (_) {
          widget.onActivate();
          return null;
        },
      ),
    },
    child: DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        border: _showFocus
            ? Border.all(color: themeColors['focusBorder'])
            : null,
        borderRadius: BorderRadius.circular(Islands.rowRadius),
      ),
      child: widget.child,
    ),
  );
}

/// The history row height and graph lane shared by local and paired Git.
const ideGitHistoryRowHeight = 26.0;

class IdeGitHistoryGraph extends StatelessWidget {
  const IdeGitHistoryGraph({
    super.key,
    required this.row,
    required this.width,
    required this.background,
    required this.hovered,
    this.narrowed = false,
  });

  final IdeGraphRow row;
  final double width;
  final Color background;
  final bool hovered;
  final bool narrowed;

  static Color rowBackground({
    required Color background,
    required bool selected,
    required bool focused,
    required bool hovered,
  }) => Color.alphaBlend(
    selected
        ? (focused
              ? IdeListColors.activeSelection
              : IdeListColors.inactiveSelection)
        : hovered
        ? IdeListColors.hover
        : Colors.transparent,
    background,
  );

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: ClipRect(
      child: SizedBox(
        width: width,
        height: ideGitHistoryRowHeight,
        child: narrowed
            ? CustomPaint(painter: _DotPainter(themeColors[row.circleColor]))
            : OverflowBox(
                alignment: Alignment.centerLeft,
                maxWidth: double.infinity,
                child: CustomPaint(
                  size: Size(ideGraphWidth(row), ideGitHistoryRowHeight),
                  painter: IdeGraphPainter(
                    row,
                    background: background,
                    hovered: hovered,
                    height: ideGitHistoryRowHeight,
                  ),
                ),
              ),
      ),
    ),
  );
}

class _DotPainter extends CustomPainter {
  const _DotPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) => canvas.drawCircle(
    Offset(ideGraphLaneWidth, size.height / 2),
    4,
    Paint()..color = color,
  );

  @override
  bool shouldRepaint(_DotPainter oldDelegate) => oldDelegate.color != color;
}

/// The message and its actions, with optional controls above the message.
class IdeGitCommitForm extends StatelessWidget {
  const IdeGitCommitForm({
    super.key,
    required this.message,
    required this.actions,
    this.controls = const [],
    this.expandMessage = false,
  });

  final Widget message;
  final Widget actions;
  final List<Widget> controls;
  final bool expandMessage;

  @override
  Widget build(BuildContext context) {
    final inset = Islands.on(context) ? Islands.inset : 8.0;
    return Padding(
      padding: EdgeInsets.fromLTRB(inset, 6, inset, inset),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (controls.isNotEmpty) ...[...controls, const SizedBox(height: 6)],
          if (expandMessage) Expanded(child: message) else message,
          const SizedBox(height: 8),
          actions,
        ],
      ),
    );
  }
}

/// The commit action row, with slots for optional local controls and counts.
class IdeGitCommitActions extends StatelessWidget {
  const IdeGitCommitActions({
    super.key,
    this.onCommit,
    this.onPush,
    this.leading,
    this.trailing,
  });

  final VoidCallback? onCommit;
  final VoidCallback? onPush;
  final GiveWay? leading;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final islands = Islands.on(context);
    final radius = islands ? Islands.controlRadius : 4.0;
    final padding = islands
        ? const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: (Islands.controlHeight - 18) / 2,
          )
        : const EdgeInsets.symmetric(horizontal: 8, vertical: 4);
    GiveWay action({
      required String label,
      required IconData icon,
      required VoidCallback? onPressed,
      required int priority,
      bool secondary = false,
    }) {
      Widget button({bool compact = false}) => IdeButton(
        label: compact ? '' : label,
        icon: compact ? icon : null,
        padding: compact ? padding.copyWith(left: 6, right: 6) : padding,
        radius: radius,
        secondary: secondary,
        onPressed: onPressed,
      );
      return GiveWay(
        button(),
        priority: priority,
        compact: Semantics(
          label: label,
          child: IdeHover(message: label, child: button(compact: true)),
        ),
      );
    }

    return GiveWayRow(
      children: [
        if (leading case final control?) ...[
          control,
          const GiveWay(SizedBox(width: 8)),
        ],
        action(
          label: l10n.gitCommitButton,
          icon: Codicons.gitCommit,
          onPressed: onCommit,
          priority: 2,
        ),
        const GiveWay(SizedBox(width: 8)),
        action(
          label: l10n.gitCommitAndPush,
          icon: Codicons.cloudUpload,
          onPressed: onPush,
          priority: 1,
          secondary: true,
        ),
        if (trailing case final summary?) ...[
          const GiveWay(SizedBox(width: 8)),
          GiveWay.fill(summary),
        ],
      ],
    );
  }
}

/// A stash entry, whether it expands in place or opens another view.
class IdeGitStashRow extends StatelessWidget {
  const IdeGitStashRow({
    super.key,
    required this.message,
    required this.onTap,
    this.description,
    this.tooltip,
    this.open = false,
    this.selected = false,
    this.onContextMenu,
    this.actions,
  });

  final String message;
  final VoidCallback onTap;
  final String? description;
  final String? tooltip;
  final bool open;
  final bool selected;
  final ValueChanged<Offset>? onContextMenu;
  final Widget? actions;

  @override
  Widget build(BuildContext context) => IdeGitKeyboardAction(
    onActivate: onTap,
    child: IdeListRow(
      selected: selected,
      onTap: onTap,
      onContextMenu: onContextMenu,
      height: actions == null
          ? IdeListColors.rowHeight
          : ideGitHistoryRowHeight,
      builder: (context, _) {
        final label = IdeResourceLabel(name: message, description: description);
        return Row(
          children: [
            const SizedBox(width: 4),
            Icon(
              open ? Codicons.chevronDown : Codicons.chevronRight,
              size: 14,
              color: IdeListColors.description,
            ),
            const SizedBox(width: 2),
            Icon(Codicons.gitStash, size: 14, color: IdeListColors.description),
            const SizedBox(width: 6),
            Expanded(
              child: tooltip == null
                  ? label
                  : IdeHover(message: tooltip!, child: label),
            ),
            ?actions,
          ],
        );
      },
    ),
  );
}

/// A Git file name with its icon, optional directory and status decoration.
class IdeGitFileLabel extends StatelessWidget {
  const IdeGitFileLabel({
    super.key,
    required this.name,
    required this.icon,
    this.description,
    this.nameColor,
    this.strikeThrough = false,
    this.status,
    this.statusColor,
  });

  final String name;
  final Widget icon;
  final String? description;
  final Color? nameColor;
  final bool strikeThrough;
  final String? status;
  final Color? statusColor;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      icon,
      const SizedBox(width: 6),
      Expanded(
        child: IdeResourceLabel(
          name: name,
          description: description,
          nameColor: nameColor,
          strikeThrough: strikeThrough,
          letter: status,
          letterColor: statusColor,
        ),
      ),
    ],
  );
}
