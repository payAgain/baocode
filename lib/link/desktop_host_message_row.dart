import 'package:bao_link/bao_link.dart';
import 'package:flutter/material.dart';

import '../bots/desktop_bot_editor_ui.dart';
import '../bots/desktop_bot_message_row.dart';
import '../chat/widgets/markdown_view.dart';
import '../l10n/l10n.dart';
import '../settings/pages/settings_widgets.dart' show SettingsText;
import 'desktop_host_chats.dart';
import 'desktop_remote_media_preview.dart';

/// Renders an admitted paired-host transcript row using the local Bot row
/// presentation while keeping all media loading inside the host RPC boundary.
class DesktopHostMessageRow extends StatelessWidget {
  const DesktopHostMessageRow({
    super.key,
    required this.peer,
    required this.chat,
    required this.message,
    required this.sender,
    required this.replyTooltip,
    required this.isCurrent,
    this.quote,
    this.onReply,
    this.grouped = false,
    this.botEmoji,
  });

  final LinkPeer? peer;
  final DesktopHostChat chat;
  final DesktopHostMessage message;
  final String sender;
  final String replyTooltip;
  final bool Function() isCurrent;
  final Widget? quote;
  final VoidCallback? onReply;
  final bool grouped;
  final String? botEmoji;

  @override
  Widget build(BuildContext context) {
    final botName = sender.isNotEmpty ? sender : chat.title;
    final resolvedSender = chat.kind == 'group'
        ? sender
        : (message.mine ? null : botName);
    final emoji = message.senderEmoji ?? botEmoji;
    return SelectionArea(
      child: DesktopRemoteMessageImages.inRow(
        peer: peer,
        chat: chat,
        images: message.images,
        isCurrent: isCurrent,
        mediaBuilder: (media) => DesktopBotMessageRow(
          mine: message.mine,
          sender: resolvedSender,
          avatar: !message.mine
              ? DesktopBotMessageAvatar(sender: botName, emoji: emoji)
              : null,
          sentAt: message.sentAt,
          grouped: grouped,
          quote: quote,
          reply: message.groupReplyTarget == null
              ? null
              : IconButton(
                  style: botToolbarIconButtonStyle(context, size: 24),
                  tooltip: replyTooltip,
                  onPressed: onReply,
                  icon: const Icon(Icons.reply, size: 14),
                ),
          content: [
            if (message.text.isNotEmpty)
              if (message.mine)
                DesktopBotMessageText(message.text, inlineCode: true)
              else if (message.literal)
                DesktopBotMessageText(message.text)
              else
                MarkdownView(message.text, textOnly: true),
            if (message.queued)
              Text(
                context.l10n.queuedMessages(1),
                style: SettingsText.description,
              ),
          ],
          media: media,
        ),
      ),
    );
  }
}
