import 'package:bao_link/bao_link.dart';
import 'package:flutter/material.dart';

import '../chat/chat_history_view.dart';
import '../chat/chat_models.dart';
import '../chat/chat_width.dart';
import '../chat/widgets/chat_minimap.dart';
import '../chat/host_transcript_scope.dart';
import '../chat/panels/reply_suggestion_bar.dart';
import '../theme/app_theme.dart';
import 'desktop_host_chats.dart';
import 'desktop_host_project_history_feed.dart';
import 'desktop_remote_media_preview.dart';

/// The ordinary chat transcript with a read-only feed from a desktop host.
class DesktopHostProjectHistory extends StatelessWidget {
  const DesktopHostProjectHistory({
    super.key,
    required this.feed,
    required this.earlierEnabled,
    this.emptyLabel,
    this.onPickReply,
    this.openMessageEditor,
    this.media,
  });

  final ({LinkPeer? peer, DesktopHostChat chat, bool Function() isCurrent})?
  media;

  final DesktopHostProjectHistoryFeed feed;
  final bool earlierEnabled;
  final String? emptyLabel;
  final ValueChanged<String>? onPickReply;
  final ChatHistoryMessageEditor? Function(int index, UserMessageItem item)?
  openMessageEditor;

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
      child: ListenableBuilder(
        listenable: Listenable.merge([ChatWidth.current, ChatMinimap.enabled]),
        builder: (context, _) => ChatHistoryView(
          key: ObjectKey(feed),
          feed: feed,
          maxContentWidth: ChatWidth.current.value,
          minimap: ChatMinimap.enabled.value,
          minimapForOverflow: true,
          underTitle: true,
          autoLoadEarlier: false,
          earlierEnabled: earlierEnabled,
          hostTranscript: true,
          openMessageEditor: openMessageEditor,
          wrapItem: (index, item, child) {
            final images = feed.imagesAt(index);
            final target = media;
            if (target == null || images.isEmpty) return child;
            return DesktopRemoteMessageImages(
              key: ObjectKey(feed.itemAt(index)),
              peer: target.peer,
              chat: target.chat,
              images: images,
              isCurrent: target.isCurrent,
              trailing: item is UserMessageItem,
              child: child,
            );
          },
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
