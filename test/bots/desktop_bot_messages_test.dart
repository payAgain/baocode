import 'dart:typed_data';

import 'package:baocode/bots/desktop_bot_messages.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/chat_session.dart';

import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final archived in [false, true]) {
    test('mixed DM admits only known private content (archived=$archived)', () {
      final groupPicture = ImageAttachment(
        bytes: Uint8List(0),
        mediaType: 'image/png',
        name: 'group.png',
      );
      final privatePicture = ImageAttachment(
        bytes: Uint8List(0),
        mediaType: 'image/png',
        name: 'private.png',
      );
      final items = [
        const AssistantTextItem('<bot_say>unattributed reply</bot_say>'),
        const UserMessageItem(text: '<bao-event>[group room] note</bao-event>'),
        UserMessageItem(
          text: 'queued private words [Image #1] ![room](queued.png)',
          images: [groupPicture],
          queued: true,
        ),
        const AssistantTextItem('<bot_say>group answer</bot_say>'),
        UserMessageItem(
          text:
              'private words [Image #1] ![room](merged.png)\n'
              '<bao-event>\n[group room] merged group note</bao-event>',
          images: [groupPicture],
        ),
        const AssistantTextItem(
          '<bot_say>ambiguous answer</bot_say>'
          '<bot_narrate>ambiguous narration</bot_narrate>',
        ),
        ToolCallItem(
          kind: ToolKind.image,
          target: 'group',
          images: [groupPicture],
        ),
        const ToolCallItem(
          kind: ToolKind.other,
          target: 'bot_send_image',
          tool: 'bot_send_image',
          input: {'url': 'https://example.invalid/ambiguous.png'},
        ),
        ToolCallItem(
          kind: ToolKind.message,
          target: 'room',
          tool: 'bot_send',
          input: const {'to': 'room', 'text': 'group delivery'},
          images: [groupPicture],
        ),
        ToolCallItem(
          kind: ToolKind.message,
          target: 'private',
          tool: 'bot_send',
          input: const {'to': 'private', 'text': 'explicit private delivery'},
          images: [privatePicture],
        ),
        const ToolCallItem(
          kind: ToolKind.message,
          target: 'private',
          tool: 'bot_send',
          status: ToolStatus.failed,
          input: {'to': 'private', 'text': 'failed private delivery'},
        ),
        const UserMessageItem(
          text: '<bao-event>unattributed app note</bao-event>',
        ),
        const AssistantTextItem('<bot_say>still unattributed</bot_say>'),
        const UserMessageItem(
          text: 'unattributed words <bao-event>[group room] truncated',
        ),
        const AssistantTextItem('<bot_say>truncated event reply</bot_say>'),
        UserMessageItem(
          text: 'private question [Image #2]',
          images: [privatePicture],
        ),
        const AssistantTextItem('<bot_say>private answer</bot_say>'),
        const ToolCallItem(
          kind: ToolKind.other,
          target: 'bot_send_image',
          tool: 'bot_send_image',
          input: {'url': 'https://example.invalid/private.png'},
        ),
      ];
      final projected = archived
          ? privateBotItems(
              _Session(items),
              legacy: true,
            ).map((entry) => entry.item)
          : items;
      final messages = desktopBotMessages(projected, hasEarlier: !archived);
      expect(messages.map((message) => message.text), [
        'queued private words',
        'private words',
        'explicit private delivery',
        'private question',
        'private answer',
        '',
      ]);
      expect(messages.map((message) => message.images), [
        [],
        [],
        [privatePicture],
        [privatePicture],
        [],
        [],
      ]);
      expect(
        messages.where((message) => message.imageUrl != null).single.imageUrl,
        Uri.parse('https://example.invalid/private.png'),
      );
      if (!archived) {
        final preview = desktopBotMessages(
          items,
          hasEarlier: true,
          previewOnly: true,
        );
        expect(preview.map((message) => message.text), [
          'queued private words',
          'private words',
          'private question',
          'private answer',
        ]);
      }
    });
  }

  test('only explicitly sent private pictures are projected', () {
    const url = 'https://example.invalid/private.png';
    const webPicture = ToolCallItem(
      kind: ToolKind.other,
      target: 'bot_send_image',
      tool: 'bot_send_image',
      input: {'url': url},
    );
    final picture = ImageAttachment(
      bytes: Uint8List(10),
      mediaType: 'image/png',
    );
    final messages = desktopBotMessages([
      const UserMessageItem(text: '<bao-event>[group g] hidden</bao-event>'),
      webPicture,
      ToolCallItem(
        kind: ToolKind.other,
        target: 'bot_send',
        tool: 'bot_send',
        input: const {'to': 'private'},
        images: [picture],
      ),
      const UserMessageItem(text: 'Show the picture privately'),
      webPicture,
      const ToolCallItem(
        kind: ToolKind.other,
        target: 'bot_send_image',
        tool: 'bot_send_image',
        status: ToolStatus.failed,
        input: {'url': 'https://example.invalid/failed.png'},
      ),
    ], hasEarlier: false);
    expect(messages.first.images, [picture]);
    expect(messages.map((message) => message.imageUrl), [
      null,
      null,
      Uri.parse(url),
    ]);
  });

  test('preview text requires a private turn and excludes tool deliveries', () {
    final at = DateTime(2026, 2, 3, 14, 15);
    final messages = desktopBotMessages(
      [
        const AssistantTextItem('<bot_say>unrouted reply</bot_say>'),
        UserMessageItem(text: 'private question', sentAt: at),
        const AssistantTextItem('<bot_say>private answer</bot_say>'),
        const UserMessageItem(text: '<bao-event>internal app note</bao-event>'),
        const AssistantTextItem('<bot_say>system turn reply</bot_say>'),
        const UserMessageItem(
          text: '<bao-event>[group g] group input</bao-event>',
        ),
        const AssistantTextItem('<bot_say>group answer</bot_say>'),
        const ToolCallItem(
          kind: ToolKind.other,
          target: 'send',
          tool: 'bot_send',
          input: {'to': 'private', 'text': 'tool delivery'},
        ),
      ],
      hasEarlier: false,
      previewOnly: true,
    );
    expect(messages.map((message) => (message.text, message.sentAt)), [
      ('private question', at),
      ('private answer', at),
    ]);
  });

  test('private projection shows only explicit replies and private sends', () {
    final picture = ImageAttachment(
      bytes: Uint8List(0),
      mediaType: 'image/png',
    );
    final messages = desktopBotMessages([
      const AssistantTextItem('<bot_say>unknown page head</bot_say>'),
      const UserMessageItem(
        text: '<bao-event>[group g] group secret</bao-event>',
      ),
      const UserMessageItem(text: 'queued private', queued: true),
      const AssistantTextItem('<bot_say>group answer</bot_say>'),
      const ToolCallItem(
        kind: ToolKind.other,
        target: 'send',
        tool: 'bot_send',
        input: {'to': 'private', 'text': 'private delivery'},
      ),
      const AssistantTextItem('<bot_say>still group</bot_say>'),
      const UserMessageItem(
        text: 'private question <bao-event>embedded note</bao-event>',
      ),
      const UserMessageItem(
        text: 'Internal handoff',
        fromAgent: 'agent',
        fromSession: 'a',
      ),
      ToolCallItem(
        kind: ToolKind.read,
        target: 'unrelated screenshot',
        images: [picture],
      ),
      const AssistantTextItem(
        'internal prose <bot_narrate>[laughs] A wave</bot_narrate>'
        '<bot_say>[whispers] private answer</bot_say>'
        '<bot_show_chat>project-1</bot_show_chat>'
        '<bot_suggest>private suggestion</bot_suggest><bot_say>unclosed',
      ),
      const UserMessageItem(text: '<bao-event>private wakeup data</bao-event>'),
      const AssistantTextItem('<bot_say>proactive private</bot_say>'),
    ], hasEarlier: true);
    expect(messages.map((message) => (message.kind, message.text)), [
      (DesktopBotMessageKind.user, 'queued private'),
      (DesktopBotMessageKind.reply, 'private delivery'),
      (DesktopBotMessageKind.user, 'private question'),
      (DesktopBotMessageKind.narration, 'A wave'),
      (DesktopBotMessageKind.reply, 'private answer'),
      (DesktopBotMessageKind.chat, 'project-1'),
      (DesktopBotMessageKind.reply, 'proactive private'),
    ]);
  });
}

class _Session extends Fake implements ChatSession {
  _Session(this.items);

  final List<ChatItem> items;

  @override
  int get itemCount => items.length;

  @override
  ChatItem itemAt(int index) => items[index];
}
