import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../workspace/islands.dart';
import '../../workspace/title_bar_double_click.dart';

/// Shared card header: its geometry does not depend on the width of the transcript.
class ConversationCardHeader extends StatelessWidget {
  const ConversationCardHeader({
    super.key,
    required this.title,
    this.leading = const [],
    this.trailing = const [],
    this.compactLeading = false,
  });
  static const endInset = Islands.inset - 2;
  final Widget title;
  final List<Widget> leading, trailing;
  final bool compactLeading;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: AppMetrics.titleBarHeight,
    child: Padding(
      // Its buttons first, their left edge on the rail's at the left.
      padding: EdgeInsets.only(
        left: compactLeading ? endInset : Islands.inset,
        right: endInset,
      ),
      child: Row(
        children: [
          if (leading.isNotEmpty) ...[
            TitleBarControls(
              child: Row(mainAxisSize: MainAxisSize.min, children: leading),
            ),
            const SizedBox(width: 4),
          ],
          Expanded(child: title),
          if (trailing.isNotEmpty) ...[
            const SizedBox(width: 6),
            TitleBarControls(
              child: Row(mainAxisSize: MainAxisSize.min, children: trailing),
            ),
          ],
        ],
      ),
    ),
  );
}
