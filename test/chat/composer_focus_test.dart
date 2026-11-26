import 'package:bao_markdown/bao_markdown.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/composer/composer.dart';
import 'package:baocode/chat/composer/composer_presentation.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('local composer preserves IME composition on Enter and send', (
    tester,
  ) async {
    final session = ChatSession(historyCount: 0);
    addTearDown(session.dispose);
    final sent = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        localizationsDelegates: const [AppLocalizations.delegate],
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: ChatComposer(
              session: session,
              onSubmit: (message) => sent.add(message.text),
            ),
          ),
        ),
      ),
    );
    final editor = find.byType(MarkdownEditor);
    final send = find.byType(ComposerSendButton);
    expect(find.byType(ComposerLayout), findsOneWidget);
    expect(find.byType(ComposerEditorViewport), findsOneWidget);
    expect(find.byType(ComposerToolbar), findsOneWidget);
    await tester.tap(editor);
    await tester.pump();
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'ni',
        selection: TextSelection.collapsed(offset: 2),
        composing: TextRange(start: 0, end: 2),
      ),
    );
    await tester.pump();
    expect(tester.widget<ComposerSendButton>(send).onSend, isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.tap(send);
    await tester.pump();
    expect(sent, isEmpty);
    expect(tester.widget<MarkdownEditor>(editor).controller.text, 'ni');
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '你',
        selection: TextSelection.collapsed(offset: 1),
      ),
    );
    await tester.pump();
    await tester.tap(send);
    expect(sent, ['你']);
  });

  testWidgets(
    'two composers typed into give the focus to each other at once, and '
    'the keyboard\'s text goes to the focused one',
    (tester) async {
      final session = ChatSession(historyCount: 0);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          localizationsDelegates: const [AppLocalizations.delegate],
          home: Scaffold(
            body: Column(
              children: [
                for (var i = 0; i < 2; i++)
                  Expanded(
                    child: ChatComposer(session: session, draft: session.draft),
                  ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      final editors = tester
          .widgetList<MarkdownEditor>(find.byType(MarkdownEditor))
          .toList();
      final nodes = [for (final editor in editors) editor.focusNode!];
      nodes.first.requestFocus();
      await tester.pump();

      // Bound a regression: otherwise a loop of focus taken back and forth
      // in microtasks hangs the test runner too, preventing even its
      // timeout from running.
      var notifications = 0;
      void limitFocusLoop() {
        if (++notifications > 20) {
          for (final node in nodes) {
            node.canRequestFocus = false;
          }
        }
      }

      for (final node in nodes) {
        node.addListener(limitFocusLoop);
      }
      // Both edited, neither laid out again yet.
      for (final editor in editors) {
        editor.controller.replace(
          0,
          0,
          'a',
          selection: const TextSelection.collapsed(offset: 1),
        );
      }
      nodes.last.requestFocus();
      await tester.idle();
      for (final node in nodes) {
        node.removeListener(limitFocusLoop);
      }
      final settled = notifications <= 20;
      final focused = nodes.last.hasFocus;
      await tester.pump();
      var typed = false, refocused = false;
      if (settled) {
        final editor = tester.state<MarkdownEditorState>(
          find.byType(MarkdownEditor).last,
        );
        final told = editor.currentTextEditingValue!;
        tester.testTextInput.updateEditingValue(
          TextEditingValue(
            text: '${told.text}typed',
            selection: TextSelection.collapsed(offset: told.text.length + 5),
          ),
        );
        await tester.pump();
        typed = editors.last.controller.text.endsWith('typed');
        nodes.first.requestFocus();
        await tester.idle();
        refocused = nodes.first.hasFocus;
        await tester.pump();
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      session.dispose();
      expect(
        settled,
        isTrue,
        reason: 'Focus must settle without the safety cap.',
      );
      expect(focused, isTrue);
      expect(typed, isTrue);
      expect(refocused, isTrue);
      expect(tester.takeException(), isNull);
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    }),
  );
}
