import '../chat/chat_models.dart';
import '../link/chat_codec.dart';

enum DesktopBotMessageKind { user, reply, narration, chat }

typedef DesktopBotMessage = ({
  DesktopBotMessageKind kind,
  String text,
  List<ImageAttachment> images,
  Uri? imageUrl,
});

/// The private view of the bot's shared transcript. Use the phone's wire
/// format for routing and reply tags, but never expose raw transcript items.
List<DesktopBotMessage> desktopBotMessages(
  Iterable<ChatItem> items, {
  required bool hasEarlier,
}) {
  final messages = <DesktopBotMessage>[];
  // A history window can begin without the user item that routed its turn.
  // Until we see one, only show sends explicitly addressed to private chat.
  var privateTurn = !hasEarlier;
  void add(
    DesktopBotMessageKind kind,
    String text, [
    List<ImageAttachment> images = const [],
    Uri? imageUrl,
  ]) {
    if (text.isEmpty && images.isEmpty && imageUrl == null) return;
    messages.add((kind: kind, text: text, images: images, imageUrl: imageUrl));
  }

  String words(String text) =>
      ChatCodec.withoutBotEvents(text.replaceAll(imageReferencePattern, ''));

  for (final item in items) {
    final privateSend = ChatCodec.botSentToUser(item);
    if (item is ToolCallItem && privateSend != null) {
      add(DesktopBotMessageKind.reply, words(privateSend), item.images);
      continue;
    }
    switch (item) {
      case UserMessageItem()
          when item.fromAgent == null && item.fromSession == null:
        final inGroup = ChatCodec.botGroupOf(item) != null;
        // A queued private message can be displayed amidst a group turn
        // that's still streaming. It doesn't route that turn's reply.
        if (!item.queued) privateTurn = !inGroup;
        if (!inGroup && ChatCodec.botEvent(item) == null) {
          final text =
              ChatCodec.sticker(item.text) != null && item.images.isNotEmpty
              ? ''
              : words(item.text);
          add(DesktopBotMessageKind.user, text, item.images);
        }
      case AssistantTextItem(:final text) when privateTurn:
        for (final (tag, part) in ChatCodec.botParts(
          ChatCodec.withoutBotEvents(text),
        )) {
          switch (tag) {
            case ChatCodec.botSayTag:
              add(
                DesktopBotMessageKind.reply,
                ChatCodec.withoutVoiceCues(words(part)),
              );
            case ChatCodec.botNarrateTag:
              add(
                DesktopBotMessageKind.narration,
                ChatCodec.withoutVoiceCues(words(part)),
              );
            case ChatCodec.botCardTag:
              add(DesktopBotMessageKind.chat, part);
          }
        }
      case ToolCallItem(
            :final kind,
            :final tool,
            :final images,
            status: ToolStatus.succeeded,
          )
          when privateTurn &&
              (kind == ToolKind.image || tool == ChatCodec.botImageTool):
        // Only images intentionally sent or generated in the chat. File
        // reads and browser screenshots can contain unrelated material.
        final url = ChatCodec.botImageUrl(item);
        final uri = url == null ? null : Uri.tryParse(url);
        add(
          DesktopBotMessageKind.reply,
          '',
          images,
          uri?.host.isNotEmpty == true ? uri : null,
        );
      default:
        break;
    }
  }
  return messages;
}
