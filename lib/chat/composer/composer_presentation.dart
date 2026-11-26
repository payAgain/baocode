import 'dart:math' as math;

import 'package:bao_markdown/bao_markdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../ide/ide_hover.dart';
import '../../theme/app_theme.dart';
import '../../theme/workbench_theme.dart' show themeColors;
import '../floating/floating_registry.dart';
import '../widgets/hover_builder.dart';
import 'pickers_row.dart';

const _editorPadding = EdgeInsets.fromLTRB(12, 10, 12, 2);
const _toolbarPadding = EdgeInsets.fromLTRB(6, 4, 6, 6);
const _fontSize = 13.5;
const _lineHeight = _fontSize * 1.5;
const _minEditorHeight = _lineHeight + 28;

/// Grow up to ten lines or a third of a short window, then scroll inside.
BoxConstraints _editorConstraints(BuildContext context) => BoxConstraints(
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

/// Keep key-up and IME events in the editor. An already handled window
/// binding or an open picker takes priority over the composer's own commands.
KeyEventResult handleComposerKey(
  KeyEvent event, {
  required bool composing,
  bool Function(KeyEvent)? alreadyHandled,
  required KeyEventResult? Function(KeyEvent) dispatch,
}) {
  if (event is KeyUpEvent || composing) return KeyEventResult.ignored;
  if (alreadyHandled?.call(event) == true) return KeyEventResult.handled;
  return FloatingRegistry.handleKey(event) ??
      dispatch(event) ??
      KeyEventResult.ignored;
}

/// Default submit binding for composers without remappable chat shortcuts.
/// Swallow repeats without sending a second time or inserting a newline.
KeyEventResult? handleComposerEnter(KeyEvent event, VoidCallback submit) {
  final key = event.logicalKey;
  final keyboard = HardwareKeyboard.instance;
  if ((key != LogicalKeyboardKey.enter &&
          key != LogicalKeyboardKey.numpadEnter) ||
      keyboard.isShiftPressed ||
      keyboard.isAltPressed ||
      keyboard.isControlPressed ||
      keyboard.isMetaPressed) {
    return null;
  }
  if (event is KeyDownEvent) submit();
  return KeyEventResult.handled;
}

/// Visual slots shared by the local input and the paired host input. The
/// editor stays in the same slot when attachments or status appear.
class ComposerLayout extends StatelessWidget {
  const ComposerLayout({
    super.key,
    required this.focused,
    required this.editor,
    required this.toolbar,
    this.aboveEditor = const [],
    this.status = const [],
  });

  final bool focused;
  final Widget editor;
  final Widget toolbar;
  final List<Widget> aboveEditor;
  final List<Widget> status;

  @override
  Widget build(BuildContext context) => ComposerSurface(
    focused: focused,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: aboveEditor,
        ),
        editor,
        toolbar,
        ...status,
      ],
    ),
  );
}

class ComposerEditorViewport extends StatelessWidget {
  const ComposerEditorViewport({
    super.key,
    required this.controller,
    required this.child,
  });

  final ScrollController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) => ScrollbarTheme(
    data: ScrollbarTheme.of(
      context,
    ).copyWith(thickness: const WidgetStatePropertyAll(4), crossAxisMargin: 3),
    child: Scrollbar(
      controller: controller,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: Padding(
          padding: _editorPadding,
          child: ClipRect(
            child: ConstrainedBox(
              constraints: _editorConstraints(context),
              child: child,
            ),
          ),
        ),
      ),
    ),
  );
}

class ComposerToolbar extends StatelessWidget {
  const ComposerToolbar({
    super.key,
    required this.pickers,
    required this.submit,
    this.actions = const [],
  });

  final Widget pickers;
  final Widget submit;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Padding(
    padding: _toolbarPadding,
    child: Row(
      children: [
        Expanded(child: pickers),
        const SizedBox(width: 8),
        ...actions,
        const SizedBox(width: 2),
        submit,
      ],
    ),
  );
}

/// The model label can shrink first. When that is insufficient, the pickers
/// scroll horizontally while the action buttons stay visible.
class ComposerPickerStrip extends StatelessWidget {
  const ComposerPickerStrip({super.key, required this.children, this.rowKey});

  final List<Widget> children;
  final Key? rowKey;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: PickersRow(
        key: rowKey,
        maxWidth: constraints.maxWidth,
        children: children,
      ),
    ),
  );
}

/// Project/branch information at the start and context usage at the end.
class ComposerStatusRow extends StatelessWidget {
  const ComposerStatusRow({
    super.key,
    this.leading,
    this.trailing,
    this.compact = false,
  });

  final Widget? leading;
  final Widget? trailing;
  final bool compact;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Row(
      mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
      children: [
        if (compact) ...[
          if (leading case final content?) Flexible(child: content),
        ] else
          Expanded(
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: leading,
            ),
          ),
        if (trailing case final content?)
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: constraints.maxWidth / 2),
            child: content,
          ),
      ],
    ),
  );
}

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
    this.showStop = false,
    this.onStop,
  });

  final String tooltip;
  final VoidCallback? onSend;
  final bool showStop;
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    final action = showStop ? onStop : onSend;
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
                child: showStop
                    ? Container(
                        key: const ValueKey('stop'),
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: active ? foreground : AppColors.textFaint,
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
