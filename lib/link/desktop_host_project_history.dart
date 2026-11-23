import 'package:flutter/material.dart';

import '../chat/chat_history_view.dart';
import '../chat/chat_width.dart';
import '../chat/host_transcript_scope.dart';
import '../chat/panels/reply_suggestion_bar.dart';
import '../theme/app_theme.dart';
import 'desktop_host_project_history_feed.dart';

/// The ordinary chat transcript with a read-only feed from a desktop host.
class DesktopHostProjectHistory extends StatelessWidget {
  const DesktopHostProjectHistory({
    super.key,
    required this.feed,
    required this.earlierEnabled,
    this.emptyLabel,
    this.onPickReply,
  });

  final DesktopHostProjectHistoryFeed feed;
  final bool earlierEnabled;
  final String? emptyLabel;
  final ValueChanged<String>? onPickReply;

  @override
  Widget build(BuildContext context) {
    if (feed.itemCount == 0 && !feed.hasEarlierHistory) {
      return Center(
        child: emptyLabel == null
            ? null
            : Text(emptyLabel!, style: TextStyle(color: AppColors.textMuted)),
      );
    }
    final history = HostTranscriptScope(
      child: ValueListenableBuilder<double>(
        valueListenable: ChatWidth.current,
        builder: (context, width, _) => ChatHistoryView(
          key: ObjectKey(feed),
          feed: feed,
          maxContentWidth: width,
          underTitle: true,
          autoLoadEarlier: false,
          earlierEnabled: earlierEnabled,
          hostTranscript: true,
        ),
      ),
    );
    final pick = onPickReply;
    final suggestions = feed.suggestions;
    return Column(
      children: [
        Expanded(child: history),
        if (pick != null && suggestions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: ReplySuggestionBar(
              key: ValueKey(suggestions.join('\u0000')),
              playKey:
                  '${identityHashCode(feed)}\u0000${suggestions.join('\u0000')}',
              suggestions: suggestions,
              onPick: pick,
            ),
          ),
      ],
    );
  }
}
