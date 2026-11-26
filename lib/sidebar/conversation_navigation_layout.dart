import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/workbench_theme.dart' show themeColors;
import '../workspace/islands.dart';

/// The navigation drawer or dock beside a conversation workspace. The caller
/// owns the selected conversation and the requested visibility and width.
class ConversationNavigationLayout extends StatefulWidget {
  const ConversationNavigationLayout({
    super.key,
    required this.sidebar,
    required this.child,
    required this.width,
    required this.open,
    required this.narrow,
    required this.onClose,
    this.atRight = false,
    this.duration = const Duration(milliseconds: 200),
    this.handle,
    this.drawerHandleWidth = 0,
    this.onDrawerSettled,
    this.cursorLayer,
  });

  static const narrowWidth = 720.0;

  final Widget? sidebar;
  final Widget child;
  final double width;
  final bool open;
  final bool narrow;
  final VoidCallback onClose;
  final bool atRight;
  final Duration duration;
  final Widget? handle;
  final double drawerHandleWidth;
  final VoidCallback? onDrawerSettled;
  final Widget? cursorLayer;

  @override
  State<ConversationNavigationLayout> createState() =>
      _ConversationNavigationLayoutState();
}

class _ConversationNavigationLayoutState
    extends State<ConversationNavigationLayout> {
  final _contentKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final ConversationNavigationLayout(
      :sidebar,
      :child,
      :width,
      :open,
      :narrow,
      :onClose,
      :atRight,
      :duration,
      :handle,
      :drawerHandleWidth,
      :onDrawerSettled,
      :cursorLayer,
    ) = widget;
    final content = KeyedSubtree(key: _contentKey, child: child);
    return ColoredBox(
      color: AppColors.sidebarSurface,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (narrow) ...[
            Positioned.fill(
              child: ExcludeSemantics(
                excluding: open,
                child: ExcludeFocus(
                  excluding: open,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Islands.gap,
                    ),
                    child: content,
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                ignoring: !open,
                child: GestureDetector(
                  onTap: onClose,
                  child: AnimatedOpacity(
                    opacity: open ? 1 : 0,
                    duration: duration,
                    child: const ColoredBox(color: Color(0x66000000)),
                  ),
                ),
              ),
            ),
            TweenAnimationBuilder<double>(
              tween: Tween(end: open ? 1 : 0),
              duration: duration,
              curve: Curves.easeOutCubic,
              onEnd: onDrawerSettled,
              builder: (context, shown, drawer) {
                final extent = width + drawerHandleWidth;
                final offset = -(extent + 24) * (1 - shown);
                return Positioned(
                  top: 0,
                  bottom: 0,
                  left: atRight ? null : offset,
                  right: atRight ? offset : null,
                  width: extent,
                  child: drawer!,
                );
              },
              child: sidebar == null
                  ? const SizedBox.shrink()
                  : ExcludeFocus(
                      excluding: !open,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: AppColors.background,
                          boxShadow: [
                            BoxShadow(
                              color: themeColors['widget.shadow'],
                              blurRadius: 24,
                            ),
                          ],
                        ),
                        child: Row(
                          textDirection: TextDirection.ltr,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (atRight) ?handle,
                            Expanded(child: sidebar),
                            if (!atRight) ?handle,
                          ],
                        ),
                      ),
                    ),
            ),
          ] else
            Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              textDirection: atRight ? TextDirection.rtl : TextDirection.ltr,
              children: [
                AnimatedContainer(
                  duration: duration,
                  curve: Curves.easeOutCubic,
                  width: open ? width : 0,
                  child: ExcludeFocus(
                    excluding: !open,
                    child: ClipRect(
                      child: OverflowBox(
                        alignment: atRight
                            ? Alignment.centerLeft
                            : Alignment.centerRight,
                        minWidth: width,
                        maxWidth: width,
                        child: sidebar,
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Positioned.fill(
                        child: Padding(
                          padding: EdgeInsets.only(
                            left: atRight ? Islands.gap : 0,
                            right: atRight ? 0 : Islands.gap,
                          ),
                          child: AnimatedPadding(
                            duration: duration,
                            curve: Curves.easeOutCubic,
                            padding: EdgeInsets.only(
                              left: !atRight && !open ? Islands.gap : 0,
                              right: atRight && !open ? Islands.gap : 0,
                            ),
                            child: content,
                          ),
                        ),
                      ),
                      if (open && handle != null)
                        Positioned(
                          left: atRight ? null : 0,
                          right: atRight ? 0 : null,
                          top: 0,
                          bottom: 0,
                          child: handle,
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ?cursorLayer,
        ],
      ),
    );
  }
}
