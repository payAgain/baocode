import 'dart:async';

import 'package:bao_markdown/bao_markdown.dart';
import 'package:baocode/chat/chat_keys.dart';
import 'package:baocode/chat/composer/composer_presentation.dart';
import 'package:baocode/link/desktop_host_composer.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Shift+Enter adds a line and Enter submits the draft', (
    tester,
  ) async {
    final sends = <String>[];
    await _mountComposer(
      tester,
      onSend: (text) async {
        sends.add(text);
        return true;
      },
    );
    await _focus(tester);
    await _type(tester, 'First line');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(_draft(tester), 'First line\n');
    expect(sends, isEmpty);

    await _type(tester, 'First line\nSecond line');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(sends, ['First line\nSecond line']);
    expect(_draft(tester), isEmpty);
  });

  testWidgets('IME candidate confirmation never sends the draft', (
    tester,
  ) async {
    final sends = <String>[];
    await _mountComposer(
      tester,
      onSend: (text) async {
        sends.add(text);
        return true;
      },
    );
    await _focus(tester);
    await _type(tester, 'ni', composing: const TextRange(start: 0, end: 2));
    expect(ChatKeys.isComposing, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.tap(_sendButton);
    await tester.pump();
    expect(sends, isEmpty);
    expect(_draft(tester), 'ni');

    await _type(tester, '你');
    expect(ChatKeys.isComposing, isFalse);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(sends, isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(sends, ['你']);
  });

  testWidgets('a pending send ignores further send gestures', (tester) async {
    final sends = <String>[];
    final reply = Completer<bool>();
    await _mountComposer(
      tester,
      onSend: (text) {
        sends.add(text);
        return reply.future;
      },
    );
    await _focus(tester);
    await _type(tester, 'Keep this draft');

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.tap(_sendButton);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(sends, ['Keep this draft']);
    reply.complete(false);
    await tester.pump();
    expect(_draft(tester), 'Keep this draft');
    expect(sends, hasLength(1));
  });

  testWidgets('an acknowledgment preserves a newer draft', (tester) async {
    final sends = <String>[];
    final drafts = <String>[];
    final reply = Completer<bool>();
    await _mountComposer(
      tester,
      onChanged: drafts.add,
      onSend: (text) {
        sends.add(text);
        return reply.future;
      },
    );
    await _focus(tester);
    await _type(tester, 'Send this');
    await tester.tap(_sendButton);
    await _type(tester, 'Keep this instead');
    reply.complete(true);
    await tester.pump();
    expect(_draft(tester), 'Keep this instead');
    expect(drafts, ['Send this', 'Keep this instead']);
    expect(sends, ['Send this']);
  });

  testWidgets('paste inserts only the visible clipboard text', (tester) async {
    final sends = <String>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      return call.method == 'Clipboard.getData'
          ? {'text': 'Visible text'}
          : null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      MdClipboard.reset();
    });
    await MdClipboard.instance.write(
      MdClip(
        plain: 'Visible text',
        markdown: MdAtoms.encode('app-local attachment metadata'),
        fromPlain: true,
      ),
    );
    await _mountComposer(
      tester,
      onSend: (text) async {
        sends.add(text);
        return true;
      },
    );
    await _focus(tester);
    await tester.state<MarkdownEditorState>(_editor).paste();
    await tester.pump();
    expect(_draft(tester), 'Visible text');
    expect(sends, isEmpty);
    await tester.tap(_sendButton);
    await tester.pump();
    expect(sends, ['Visible text']);
  });
}

final _editor = find.byType(MarkdownEditor);
final _sendButton = find.byType(ComposerSendButton);

String _draft(WidgetTester tester) =>
    tester.widget<MarkdownEditor>(_editor).controller.text;

Future<void> _focus(WidgetTester tester) async {
  await tester.tap(_editor);
  await tester.pump();
}

Future<void> _type(
  WidgetTester tester,
  String text, {
  TextRange composing = TextRange.empty,
}) async {
  tester.testTextInput.updateEditingValue(
    TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
      composing: composing,
    ),
  );
  await tester.pump();
}

Future<void> _mountComposer(
  WidgetTester tester, {
  String initialDraft = '',
  bool busy = false,
  ValueChanged<String>? onChanged,
  required Future<bool> Function(String) onSend,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: DesktopHostComposer(
          initialDraft: initialDraft,
          busy: busy,
          placeholder: 'Message',
          sendLabel: 'Send',
          onChanged: onChanged ?? (_) {},
          onSend: onSend,
        ),
      ),
    ),
  ),
);
