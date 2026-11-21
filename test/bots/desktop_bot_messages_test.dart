import 'dart:typed_data';

import 'package:baocode/bots/desktop_bot_messages.dart';
import 'package:baocode/chat/chat_models.dart';

import 'package:flutter_test/flutter_test.dart';

void main() {
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
