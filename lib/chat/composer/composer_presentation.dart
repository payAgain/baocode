import 'dart:math' as math;

import 'package:bao_markdown/bao_markdown.dart';
import 'package:flutter/material.dart';

import '../../ide/ide_hover.dart';
import '../../theme/app_theme.dart';
import '../../theme/workbench_theme.dart' show themeColors;
import '../widgets/hover_builder.dart';

const composerEditorPadding = EdgeInsets.fromLTRB(12, 10, 12, 2);
const composerToolbarPadding = EdgeInsets.fromLTRB(6, 4, 6, 6);
const _fontSize = 13.5;
const _lineHeight = _fontSize * 1.5;
const _minEditorHeight = _lineHeight + 28;

/// Grow up to ten lines or a third of a short window, then scroll inside.
BoxConstraints composerEditorConstraints(BuildContext context) =>
    BoxConstraints(
      minHeight: _minEditorHeight,
      maxHeight: math.max(
        _minEditorHeight,
        math.min(_lineHeight * 10, MediaQuery.sizeOf(context).height / 3),
      ),
    );

MarkdownEditorStyle composerEditorStyle(BuildContext context) =>
    MarkdownEditorStyle(
      text: DefaultTextStyle.of(context).style.merge(
        TextStyle(
          color: AppColors.textPrimary,
          fontSize: _fontSize,
          height: 1.5,
          // Center glyphs in the line box to align with the editor's caret.
          leadingDistribution: TextLeadingDistribution.even,
        ),
      ),
      selection: AppColors.textSelection,
      caret: themeColors['editorCursor.foreground'],
      placeholder: TextStyle(
        color: themeColors['agentsChatInput.placeholderForeground'],
      ),
    );

class ComposerSurface extends StatelessWidget {
  const ComposerSurface({
    super.key,
    required this.focused,
    required this.child,
  });

  final bool focused;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: const Duration(milliseconds: 150),
    decoration: BoxDecoration(
      color: AppColors.bubbleFill,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: AppColors.bubbleBorder(focused: focused)),
    ),
    child: child,
  );
}

class ComposerSendButton extends StatelessWidget {
  const ComposerSendButton({
    super.key,
    required this.tooltip,
    required this.onSend,
    this.onStop,
  });

  final String tooltip;
  final VoidCallback? onSend;
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    final streaming = onStop != null;
    final action = onStop ?? onSend;
    final active = action != null;
    final colors = themeColors;
    final foreground = colors['button.foreground'];
    return IdeHover(
      message: tooltip,
      child: Semantics(
        button: true,
        enabled: active,
        child: HoverBuilder(
          cursor: active ? SystemMouseCursors.click : SystemMouseCursors.basic,
          builder: (context, hovered) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: action,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: !active
                    ? Colors.transparent
                    : hovered
                    ? colors['button.hoverBackground']
                    : colors['button.background'],
                shape: BoxShape.circle,
              ),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 150),
                transitionBuilder: (child, animation) =>
                    ScaleTransition(scale: animation, child: child),
                child: streaming
                    ? Container(
                        key: const ValueKey('stop'),
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: foreground,
                          borderRadius: BorderRadius.circular(1.5),
                        ),
                      )
                    : Icon(
                        key: const ValueKey('send'),
                        Icons.arrow_upward_rounded,
                        size: 15,
                        color: active ? foreground : AppColors.textFaint,
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
