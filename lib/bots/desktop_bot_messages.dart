import '../chat/chat_models.dart';
import '../link/chat_codec.dart';

enum DesktopBotMessageKind { user, reply, narration, chat }

typedef DesktopBotMessage = ({
  DesktopBotMessageKind kind,
  String text,
  List<ImageAttachment> images,
  Uri? imageUrl,
  DateTime? sentAt,
});

/// The private view of the bot's shared transcript. Use the phone's wire
/// format for routing and reply tags, but never expose raw transcript items.
/// A preview needs an explicit private turn and contains only message text.
List<DesktopBotMessage> desktopBotMessages(
  Iterable<ChatItem> items, {
  required bool hasEarlier,
  bool previewOnly = false,
}) {
  final messages = <DesktopBotMessage>[];
  // A history window can begin without the user item that routed its turn.
  // Until we see one, only show sends explicitly addressed to private chat.
  var privateTurn = !hasEarlier && !previewOnly;
  DateTime? turnAt;
  void add(
    DesktopBotMessageKind kind,
    String text, {
    List<ImageAttachment> images = const [],
    Uri? imageUrl,
    DateTime? sentAt,
  }) {
    if (text.isEmpty && images.isEmpty && imageUrl == null) return;
    if (previewOnly && (text.isEmpty || kind == DesktopBotMessageKind.chat)) {
      return;
    }
    messages.add((
      kind: kind,
      text: text,
      images: images,
      imageUrl: imageUrl,
      sentAt: sentAt,
    ));
  }

  String words(String text) =>
      ChatCodec.withoutBotEvents(text.replaceAll(imageReferencePattern, ''));

  for (final item in items) {
    if (previewOnly && item is ToolCallItem) continue;
    final privateSend = ChatCodec.botSentToUser(item);
    if (item is ToolCallItem && privateSend != null) {
      add(DesktopBotMessageKind.reply, words(privateSend), images: item.images);
      continue;
    }
    switch (item) {
      case UserMessageItem()
          when item.fromAgent == null && item.fromSession == null:
        final event = ChatCodec.botEvent(item);
        final inGroup = event != null && ChatCodec.botGroupOf(item) != null;
        // A queued private message can be displayed amidst a group turn
        // that's still streaming. It doesn't route that turn's reply.
        if (!item.queued) {
          privateTurn = !inGroup && (!previewOnly || event == null);
          turnAt = item.sentAt;
        }
        if (event == null) {
          final text =
              ChatCodec.sticker(item.text) != null && item.images.isNotEmpty
              ? ''
              : words(item.text);
          add(
            DesktopBotMessageKind.user,
            text,
            images: item.images,
            sentAt: item.sentAt,
          );
        }
      case UserMessageItem(queued: false) when previewOnly:
        // A handoff from another agent does not establish a private turn.
        privateTurn = false;
      case AssistantTextItem(:final text) when privateTurn:
        for (final (tag, part) in ChatCodec.botParts(
          ChatCodec.withoutBotEvents(text),
        )) {
          switch (tag) {
            case ChatCodec.botSayTag:
              add(
                DesktopBotMessageKind.reply,
                ChatCodec.withoutVoiceCues(words(part)),
                sentAt: turnAt,
              );
            case ChatCodec.botNarrateTag:
              add(
                DesktopBotMessageKind.narration,
                ChatCodec.withoutVoiceCues(words(part)),
                sentAt: turnAt,
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
          images: images,
          imageUrl: uri?.host.isNotEmpty == true ? uri : null,
        );
      default:
        break;
    }
  }
  return messages;
}
