import 'package:bao_link/bao_link.dart';
import 'package:flutter/material.dart';

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
  });

  final LinkPeer? peer;
  final DesktopHostChat chat;
  final DesktopHostMessage message;
  final String sender;
  final String replyTooltip;
  final bool Function() isCurrent;
  final Widget? quote;
  final VoidCallback? onReply;

  @override
  Widget build(BuildContext context) => SelectionArea(
    child: DesktopRemoteMessageImages.inRow(
      peer: peer,
      chat: chat,
      images: message.images,
      isCurrent: isCurrent,
      mediaBuilder: (media) => DesktopBotMessageRow(
        mine: message.mine,
        sender: chat.kind == 'group' ? sender : null,
        avatar: !message.mine && message.senderEmoji != null
            ? DesktopBotMessageAvatar(
                sender: sender,
                emoji: message.senderEmoji,
              )
            : null,
        sentAt: message.sentAt,
        quote: quote,
        reply: message.groupReplyTarget == null
            ? null
            : IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: replyTooltip,
                onPressed: onReply,
                icon: const Icon(Icons.reply, size: 16),
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
