import 'dart:async';

import 'package:markdown/markdown.dart' as md;

import '../chat/chat_models.dart';
import '../chat/chat_session.dart';
import '../chat/composer/composer_files.dart';
import '../link/chat_codec.dart';
import 'bot.dart';
import 'bots.dart';

enum DesktopBotMessageKind { user, reply, narration, chat }

typedef DesktopBotMessage = ({
  DesktopBotMessageKind kind,
  String text,
  String? textWithAttachments,
  List<ImageAttachment> images,
  Uri? imageUrl,
  DateTime? sentAt,
  bool queued,
  ({String delivery, List<int> sequences})? recallSources,
});

// A group event can be embedded in a legacy prompt that also contains the
// user's queued private words. botGroupOf only recognizes a standalone note.
final _groupNote = RegExp('<${ChatCodec.botEventTag}>\\s*\\[group\\s');

bool _hasGroupNote(UserMessageItem item) =>
    _groupNote.hasMatch(item.text) || ChatCodec.botGroupOf(item) != null;

bool _ownerPrompt(UserMessageItem item) =>
    item.fromAgent == null && item.fromSession == null;

/// The user's own prompts, with any app notes cut out. For ordinary private
/// prompts retain the attachment appendix so prompt recall can restore chips.
String? desktopBotPromptText(UserMessageItem item) => _ownerPromptText(
  item,
  groupNote: _hasGroupNote(item),
  showMedia: true,
  hideSticker: true,
);

String? _ownerPromptText(
  UserMessageItem item, {
  required bool groupNote,
  required bool showMedia,
  bool hideSticker = false,
}) {
  if (!_ownerPrompt(item) || !groupNote && ChatCodec.botEvent(item) != null) {
    return null;
  }
  final prompt = ChatCodec.withoutBotEvents(item.text);
  // Do not display fragments of a malformed note as the user's own words.
  const tag = ChatCodec.botEventTag;
  if (groupNote && (prompt.contains('<$tag>') || prompt.contains('</$tag>'))) {
    return null;
  }
  if (!groupNote && showMedia) {
    if (hideSticker &&
        item.images.isNotEmpty &&
        ChatCodec.sticker(item.text) != null) {
      return '';
    }
    return prompt;
  }
  final words = _withoutPromptMedia(prompt);
  return words.isEmpty ? null : words;
}

String _withoutPromptMedia(String prompt) {
  final body = splitCodeAppendix(prompt).body
      .replaceAll(imageReferencePattern, '')
      .trim();
  if (!body.contains('![')) return body;
  // The same Markdown parser as the paired desktop's image preview: a
  // relative image path in a mixed prompt must not become a private action.
  String words(md.Node node) => switch (node) {
    md.Element(tag: 'img') => '',
    md.Element(:final children?) => children.map(words).join(),
    _ => node.textContent,
  };
  try {
    return md.Document()
        .parse(body)
        .map(words)
        .join('\n')
        .replaceAll('![', '&#33;[')
        .trim();
  } on Object {
    // Never fall back to the raw, unattributed media markup.
    return '';
  }
}

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
    String? textWithAttachments,
    List<ImageAttachment> images = const [],
    Uri? imageUrl,
    DateTime? sentAt,
    bool queued = false,
    ({String delivery, List<int> sequences})? recallSources,
  }) {
    if (text.isEmpty && images.isEmpty && imageUrl == null) return;
    if (previewOnly && (text.isEmpty || kind == DesktopBotMessageKind.chat)) {
      return;
    }
    messages.add((
      kind: kind,
      text: text,
      textWithAttachments: textWithAttachments,
      images: images,
      imageUrl: imageUrl,
      sentAt: sentAt,
      queued: queued,
      recallSources: recallSources,
    ));
  }

  String words(String text) =>
      ChatCodec.withoutBotEvents(text.replaceAll(imageReferencePattern, ''));

  for (final item in items) {
    if (previewOnly && item is ToolCallItem) continue;
    final privateSend = ChatCodec.botSentToUser(item);
    if (item is ToolCallItem && privateSend != null) {
      final hits = item.input['recallHits'];
      final delivery = item.callId;
      add(
        DesktopBotMessageKind.reply,
        words(privateSend),
        images: item.images,
        recallSources: delivery != null && hits is List<int> && hits.isNotEmpty
            ? (delivery: delivery, sequences: hits)
            : null,
      );
      continue;
    }
    switch (item) {
      case UserMessageItem():
        final groupNote = _hasGroupNote(item);
        final own = _ownerPrompt(item);
        final event = ChatCodec.botEvent(item);
        // Queued messages don't route the reply that's still streaming.
        // Neither a mixed prompt nor an unattributed app note can open a DM.
        if (!item.queued) {
          if (groupNote || previewOnly && (!own || event != null)) {
            privateTurn = false;
          } else if (own) {
            if (event == null) privateTurn = true;
            turnAt = item.sentAt;
          }
        }
        final showMedia = !groupNote && privateTurn;
        if (_ownerPromptText(
              item,
              groupNote: groupNote,
              showMedia: showMedia,
              hideSticker: true,
            )
            case final prompt?) {
          final (:body, :references) = splitCodeAppendix(prompt);
          final display = words(body);
          add(
            DesktopBotMessageKind.user,
            display,
            textWithAttachments: previewOnly || references.isEmpty
                ? null
                : display + codeAppendix(references.values),
            images: showMedia ? item.images : const [],
            sentAt: item.sentAt,
            queued: item.queued,
          );
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

/// Only chat-facing items belong in the public DM window. Carry the worker's
/// item index for actions on the current conversation, never for archived data.
Iterable<({ChatItem item, int? index, DateTime? at})> privateBotItems(
  ChatSession session, {
  bool legacy = false,
  bool active = false,
  int? beforeIndex,
  String? Function(String id)? cardSession,
}) sync* {
  var inPrivate = !legacy;
  DateTime? at;
  for (
    var index = 0;
    index < session.itemCount && (beforeIndex == null || index < beforeIndex);
    index++
  ) {
    final item = session.itemAt(index);
    if (item case UserMessageItem(:final queued, :final sentAt)) {
      final groupNote = _hasGroupNote(item);
      if (!queued) {
        at = sentAt;
        final privatePrompt =
            _ownerPrompt(item) && ChatCodec.botEvent(item) == null;
        inPrivate = !groupNote && (privatePrompt || !legacy && inPrivate);
      }
      final showMedia = !groupNote && inPrivate;
      final prompt = _ownerPromptText(
        item,
        groupNote: groupNote,
        showMedia: showMedia,
      );
      if (prompt == null) continue;
      final visible = UserMessageItem(
        text: prompt,
        queued: active && queued,
        images: showMedia ? item.images : const [],
        stopped: item.stopped,
        sentAt: sentAt,
      );
      yield (
        item: visible,
        index: active && showMedia ? index : null,
        at: sentAt,
      );
    } else if (item case ToolCallItem(:final images)
        when ChatCodec.botSentToUser(item) != null) {
      final sent = ChatCodec.botSentToUser(item)!;
      yield (
        item: ToolCallItem(
          kind: ToolKind.message,
          target: ChatCodec.botToUser,
          tool: ChatCodec.botSendTool,
          input: {'to': ChatCodec.botToUser, 'text': sent},
          images: images,
        ),
        index: null,
        at: at,
      );
    } else if (inPrivate && item is AssistantTextItem) {
      final text = StringBuffer();
      for (final (tag, part) in ChatCodec.botParts(
        ChatCodec.withoutBotEvents(item.text),
      )) {
        final visible = tag == ChatCodec.botCardTag && cardSession != null
            ? cardSession(part)
            : part;
        if (visible != null) text.writeln('<$tag>$visible</$tag>');
      }
      if (active) {
        for (final suggestion in ChatCodec.botSuggestions(item.raw)) {
          text.writeln(
            '<${ChatCodec.botSuggestTag}>$suggestion</${ChatCodec.botSuggestTag}>',
          );
        }
      }
      if (text.isNotEmpty) {
        yield (
          item: AssistantTextItem(text.toString().trim()),
          index: null,
          at: at,
        );
      }
    } else if (inPrivate &&
        item is ToolCallItem &&
        (item.status == ToolStatus.succeeded ||
            active && item.status == ToolStatus.running) &&
        (item.kind == ToolKind.image || item.tool == ChatCodec.botImageTool)) {
      final url = ChatCodec.botImageUrl(item);
      yield (
        item: ToolCallItem(
          kind: item.kind,
          target: '',
          tool: item.kind == ToolKind.image ? null : ChatCodec.botImageTool,
          status: item.status,
          input: {'url': ?url},
          images: item.images,
        ),
        index: null,
        at: at,
      );
    }
  }
}

/// Merges the retained private transcript and explicit private deliveries with
/// the current worker's projected items. Only current prompts carry an index
/// for an edit. Deliveries are ordered by the host's send time.
List<({ChatItem item, int? index})> privateBotTimeline(
  Bots bots,
  Bot bot,
  ChatSession session,
  List<ChatItem> history, {
  String? Function(String id)? cardSession,
  bool includeRecallSources = false,
}) {
  final deliveries = bots
      .privateDeliveries(bot, includeRecallSources: includeRecallSources)
      .iterator;
  var hasDelivery = deliveries.moveNext();
  final entries = <({ChatItem item, int? index})>[];
  void addDelivery() {
    final delivery = deliveries.current;
    if (delivery.item.input['hostCommand'] case final String request) {
      entries.add((
        item: UserMessageItem(text: request, sentAt: delivery.at),
        index: null,
      ));
    }
    entries.add((item: delivery.item, index: null));
    hasDelivery = deliveries.moveNext();
  }

  void add(ChatItem item, int? index, DateTime? at) {
    while (at != null && hasDelivery && !deliveries.current.at.isAfter(at)) {
      addDelivery();
    }
    entries.add((item: item, index: index));
  }

  for (final item in history) {
    add(item, null, item is UserMessageItem ? item.sentAt : null);
  }
  for (final (:item, :index, :at) in privateBotItems(
    session,
    active: true,
    cardSession: cardSession,
  )) {
    add(item, index, at);
  }
  while (hasDelivery) {
    addDelivery();
  }
  for (final item in bots.pendingPrivateItems(bot)) {
    entries.add((item: item, index: null));
  }
  return entries;
}

/// Reads projected history without attaching a UI or preparing a model.
Future<void> loadBotChatHistory(ChatSession session) async {
  if (session.loadingHistory) {
    final loaded = Completer<void>();
    void changed() {
      if (!session.loadingHistory && !loaded.isCompleted) loaded.complete();
    }

    session.addListener(changed);
    try {
      changed();
      await loaded.future.timeout(const Duration(seconds: 20));
    } on TimeoutException {
      // Still show every loaded and attributable message.
    } finally {
      session.removeListener(changed);
    }
  }
  while (session.hasEarlierHistory) {
    final before = session.prependedCount;
    await session.loadEarlier();
    if (session.prependedCount == before) break;
  }
}

Future<List<ChatItem>> loadPrivateBotHistory(
  Bots bots,
  Bot bot, {
  String? Function(String id)? cardSession,
}) async {
  final history = <ChatItem>[];
  for (final thread in bots.privateHistory(bot)) {
    final session = thread.session;
    await loadBotChatHistory(session);
    history.addAll([
      for (final (:item, index: _, at: _) in privateBotItems(
        session,
        legacy: bots.isLegacyPrivateThread(bot, thread),
        cardSession: cardSession,
      ))
        item,
    ]);
  }
  return history;
}
