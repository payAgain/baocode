import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bao_link/bao_link.dart';
import 'package:bao_markdown/bao_markdown.dart';
import 'package:bao_remote/claude.dart' show ClaudeHistoryPage;
import 'package:bao_remote/local.dart' show ClaudeSessions;
import 'package:baocode/bots/bot.dart';
import 'package:baocode/bots/bot_files.dart';
import 'package:baocode/bots/bot_folders.dart';
import 'package:baocode/bots/bot_group_prompt.dart';
import 'package:baocode/bots/bot_prompt.dart' show BotSuggestions;
import 'package:baocode/bots/bots.dart';
import 'package:baocode/bots/desktop_bot_hub.dart';
import 'package:baocode/bots/desktop_bot_page.dart';
import 'package:baocode/bots/desktop_bot_settings.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/chat_session.dart' show ComposerMessage;
import 'package:baocode/chat/composer/composer.dart';
import 'package:baocode/chat/composer/composer_embeds.dart';
import 'package:baocode/chat/composer/composer_files.dart';
import 'package:baocode/chat/composer/composer_picker.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_transport.dart';
import 'package:baocode/kernel/kernel_types.dart' show KernelHealthStatus;
import 'package:baocode/link/chat_codec.dart';
import 'package:baocode/link/workspace_bridge.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../kernel_test.dart' show FakeCli;

const _main = Bot(
  id: 'assistant',
  name: 'Mia',
  folder: '/bots/assistant',
  assistant: true,
);
const _threadId = 'kept-main-bot';
const _projectId = 'kept-project-chat';
const _other = Bot(id: 'other', name: 'Tao', folder: '/bots/other');
const _otherThreadId = 'kept-other-bot';

void main() {
  testWidgets('hub restores and opens the exact recent conversations', (
    tester,
  ) async {
    const group = BotGroup(
      id: 'g',
      name: 'Release room',
      members: ['assistant'],
    );
    const otherGroup = BotGroup(id: 'g2', name: 'Other room', members: []);
    final at = DateTime(2026, 2, 3, 14, 15);
    final groupAt = at.add(const Duration(hours: 1));
    final pages = <String?>[];
    final fixture = _Fixture(Future.value([_kept().first]), (before) async {
      pages.add(before);
      return before == null
          ? ClaudeHistoryPage([
              _assistant('head', '<bot_say>group at page head</bot_say>'),
              _user(
                'g-question',
                '<bao-event>[group g] hidden input</bao-event>',
              ),
              _assistant('g-reply', '<bot_say>hidden group answer</bot_say>'),
            ], earlier: 'head')
          : ClaudeHistoryPage([
              _user('phone', 'saved phone question', at: at),
              _assistant('private', '<bot_say>saved phone answer</bot_say>'),
              _assistant('raw', 'internal tool plan'),
              _user(
                'g-start',
                '<bao-event>[group g] earlier route</bao-event>',
              ),
            ]);
    });
    addTearDown(fixture.dispose);
    void keep(String path, Object data) => fixture.bots.folders.writeFile(
      p.join('/bots/groups', path),
      Uint8List.fromList(utf8.encode('${jsonEncode(data)}\n')),
    );
    keep('groups.json', [group.toJson(), otherGroup.toJson()]);
    keep(
      'g/messages.jsonl',
      LinkGroupMessage(
        seq: 1,
        at: groupAt,
        from: 'assistant',
        text: '<bot_say>saved group answer</bot_say>',
      ).toJson(),
    );

    final load = fixture.workspace.load();
    await fixture.bots.start();
    await load;
    final newBot = fixture.bots.save(
      name: 'New helper',
      signature: 'Ready for a first chat',
      identity: 'Helps',
      abilities: {},
    );
    await tester.pumpWidget(fixture.hub());
    await tester.pumpAndSettle();

    expect(find.text('saved phone answer'), findsOneWidget);
    expect(find.text('saved group answer'), findsOneWidget);
    expect(find.text('Ready for a first chat'), findsOneWidget);
    expect(find.textContaining('hidden'), findsNothing);
    expect(find.textContaining('group at page head'), findsNothing);
    expect(find.text('internal tool plan'), findsNothing);
    expect(pages, [null, 'head']);
    expect(fixture.cli, isEmpty);
    expect(fixture.bots.threadOf(_main)?.id, _threadId);

    final material = MaterialLocalizations.of(tester.element(find.text('Mia')));
    String time(DateTime date) =>
        '${material.formatMediumDate(date)} '
        '${material.formatTimeOfDay(TimeOfDay.fromDateTime(date))}';
    expect(find.text(time(at)), findsOneWidget);
    expect(find.text(time(groupAt)), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Release room')).dy,
      lessThan(tester.getTopLeft(find.text('Mia')).dy),
    );
    expect(
      tester.getTopLeft(find.text('Mia')).dy,
      lessThan(tester.getTopLeft(find.text(newBot.name)).dy),
    );

    await tester.tap(find.text('Release room'));
    await tester.pumpAndSettle();
    expect(find.text('saved group answer'), findsOneWidget);
    expect(find.text('Other room'), findsNothing);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Group chats'), findsOneWidget);
    expect(find.text('Other room'), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mia'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<DesktopBotPage>(find.byType(DesktopBotPage)).botId,
      _main.id,
    );
    expect(find.text('saved phone question'), findsOneWidget);
    expect(find.text('saved phone answer'), findsOneWidget);
    expect(find.text('saved group answer'), findsNothing);
    expect(fixture.cli.keys, [_main.folder]);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Configure ${newBot.name}'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<DesktopBotSettings>(find.byType(DesktopBotSettings))
          .bot
          ?.id,
      newBot.id,
    );
    await tester.pumpWidget(const SizedBox());
    fixture.dispose();
  });

  testWidgets('hub updates from a phone turn and clears the selected unread', (
    tester,
  ) async {
    final fixture = _Fixture(Future.value([_kept().first]), (_) async {
      return ClaudeHistoryPage([
        _user('old', 'saved question', at: DateTime(2026, 1, 1)),
      ]);
    });
    addTearDown(fixture.dispose);
    final load = fixture.workspace.load();
    await fixture.bots.start();
    await load;
    final group = fixture.bots.groups.save(
      name: 'Live room',
      members: [_main.id],
    );
    final (phone, closePhone) = await fixture.openPhone();
    await tester.pumpWidget(fixture.hub());
    await tester.pumpAndSettle();
    final privateRow = find.ancestor(
      of: find.text('Mia'),
      matching: find.byType(ListTile),
    );
    final groupRow = find.ancestor(
      of: find.text(group.name),
      matching: find.byType(ListTile),
    );
    Finder badge(Finder row) =>
        find.descendant(of: row, matching: find.byType(Badge));
    expect(badge(privateRow), findsNothing);
    expect(badge(groupRow), findsNothing);

    fixture.bots.groups.say(group.id, _main.id, 'live group reply');
    await tester.pump();
    expect(find.text('live group reply'), findsOneWidget);
    expect(badge(groupRow), findsOneWidget);

    expect(
      await phone.call(LinkMethods.send, {
        'bot': _main.id,
        'text': 'new phone question',
      }),
      {'session': _threadId},
    );
    await tester.pumpAndSettle();
    expect(find.text('new phone question'), findsOneWidget);
    expect(badge(privateRow), findsNothing);
    fixture.cli[_main.folder]!.push(
      _assistant('live', 'raw tool plan <bot_say>new private reply</bot_say>'),
    );
    await tester.pumpAndSettle();
    expect(find.text('new private reply'), findsOneWidget);
    expect(find.textContaining('raw tool plan'), findsNothing);
    expect(badge(privateRow), findsOneWidget);

    await tester.tap(find.text('Mia'));
    await tester.pumpAndSettle();
    expect(find.text('new private reply'), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(badge(privateRow), findsNothing);
    expect(badge(groupRow), findsOneWidget);

    await tester.tap(find.text(group.name));
    await tester.pumpAndSettle();
    expect(find.text('live group reply'), findsOneWidget);
    expect(fixture.bots.groups.unread(group.id), 0);
    await tester.pumpWidget(const SizedBox());
    await closePhone();
    fixture.dispose();
    await tester.pump();
  });

  testWidgets('cold start restores history when the catalog only has bots', (
    tester,
  ) async {
    final fixture = _Fixture(Future.value([_kept().first]), (_) async {
      return ClaudeHistoryPage([
        _user('phone-before-relaunch', 'saved phone question'),
        _assistant('answer', '<bot_say>saved phone answer</bot_say>'),
      ]);
    });
    addTearDown(fixture.dispose);
    final load = fixture.workspace.load();
    await fixture.bots.start();
    await load;
    await tester.pumpWidget(fixture.page());
    await tester.pump();

    expect(fixture.bots.threadOf(_main)?.id, _threadId);
    expect(fixture.workspace.threads.map((thread) => thread.id), [_threadId]);
    expect(find.text('saved phone question'), findsOneWidget);
    expect(find.text('saved phone answer'), findsOneWidget);
    expect(find.byType(MarkdownEditor), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    fixture.dispose();
  });

  testWidgets('loads saved private history behind a group-only first page', (
    tester,
  ) async {
    final pages = (await tester.runAsync(() async {
      final dir = Directory.systemTemp.createTempSync('private-bot-history-');
      try {
        final transcript = File(p.join(dir.path, '$_threadId.jsonl'));
        final entries = [
          _user('phone', 'older phone question'),
          _assistant('private', '<bot_say>older phone reply</bot_say>'),
          for (var i = 0; i < 10; i++) ...[
            _user(
              'group-$i',
              '<bao-event>[group g] group question</bao-event>',
            ),
            _assistant('group-reply-$i', '<bot_say>group reply</bot_say>'),
          ],
        ];
        await transcript.writeAsString(
          [
            for (final (index, entry) in entries.indexed)
              jsonEncode({
                ...entry,
                'parentUuid': index == 0 ? null : entries[index - 1]['uuid'],
              }),
          ].join('\n'),
        );
        final first = await ClaudeSessions.readPage(transcript.path, turns: 10);
        expect(first.earlier, 'group-0');
        final older = await ClaudeSessions.readPage(
          transcript.path,
          turns: 20,
          before: first.earlier,
        );
        return {null: first, first.earlier: older};
      } finally {
        dir.deleteSync(recursive: true);
      }
    }))!;
    final requested = <String?>[];
    final fixture = _Fixture(Future.value(_kept()), (before) async {
      requested.add(before);
      return pages[before]!;
    });
    addTearDown(fixture.dispose);
    final load = fixture.workspace.load();
    await fixture.bots.start();
    await load;
    await tester.pumpWidget(fixture.page());
    await tester.pumpAndSettle();

    expect(requested, [null, 'group-0']);
    expect(find.text('older phone question'), findsOneWidget);
    expect(find.text('older phone reply'), findsOneWidget);
    expect(find.textContaining('group question'), findsNothing);
    expect(find.text('group reply'), findsNothing);
    final (phone, closePhone) = await fixture.openPhone();
    addTearDown(closePhone);
    final state = LinkState.fromJson(
      (await phone.call(LinkMethods.state, {}))! as Map<String, Object?>,
    );
    final id = state.bots.single.session;
    expect(id, _threadId);
    final opened = LinkSessionUpdate.fromJson(
      (await phone.call(LinkMethods.open, {'session': id, 'window': 2}))!
          as Map<String, Object?>,
    );
    expect(opened.earlier, isTrue);
    final history =
        (await phone.call(LinkMethods.earlier, {'session': id, 'count': 50}))!
            as Map<String, Object?>;
    final earlier = (history['items']! as List).cast<Map<String, Object?>>();
    expect(
      (ChatCodec.decode(earlier.first) as UserMessageItem).text,
      'older phone question',
    );
    expect(
      (ChatCodec.decode(earlier[1]) as AssistantTextItem).text,
      '<bot_say>older phone reply</bot_say>',
    );
    expect(history['earlier'], isFalse);
    await tester.pumpWidget(const SizedBox());
    await closePhone();
    fixture.dispose();
  });

  testWidgets('switches existing bot threads and keeps separate drafts', (
    tester,
  ) async {
    final pending = Completer<ClaudeHistoryPage>();
    final fixture = _Fixture(
      Future.value([
        ..._kept(),
        ProjectRecord(
          path: _other.folder,
          sessions: [
            SessionRecord(
              id: _otherThreadId,
              title: 'Second bot conversation',
              updatedAt: DateTime(2026),
              cwd: _other.folder,
            ),
          ],
        ),
      ]),
      (_) async => ClaudeHistoryPage([_user('main', 'Mia on the phone')]),
      otherHistory: pending.future,
    );
    addTearDown(fixture.dispose);
    final load = fixture.workspace.load();
    await fixture.bots.start();
    await load;
    await tester.pumpWidget(fixture.page());
    await tester.pump();
    expect(find.text('Mia on the phone'), findsOneWidget);
    final main = fixture.bots.threadOf(_main)!;
    final other = fixture.bots.threadOf(_other)!;
    expect(main.id, _threadId);
    expect(other.id, _otherThreadId);
    await _type(tester, 'Mia draft');

    await tester.pumpWidget(fixture.page(botId: _other.id));
    await tester.pump();
    expect(find.text('Tao'), findsOneWidget);
    expect(find.text('Mia on the phone'), findsNothing);
    expect(_editor(tester).controller.text, isEmpty);
    expect(find.text('Loading conversation…'), findsOneWidget);
    await _type(tester, 'Tao draft');

    await tester.pumpWidget(fixture.page());
    await tester.pump();
    pending.complete(ClaudeHistoryPage([_user('tao', 'Tao on the phone')]));
    await tester.pump();
    expect(find.text('Mia on the phone'), findsOneWidget);
    expect(_editor(tester).controller.text, 'Mia draft');
    expect(find.text('Tao on the phone'), findsNothing);

    await tester.pumpWidget(fixture.page(botId: _other.id));
    await tester.pump();
    expect(find.text('Tao on the phone'), findsOneWidget);
    expect(_editor(tester).controller.text, 'Tao draft');
    expect(find.text('Mia on the phone'), findsNothing);
    expect(fixture.bots.threadOf(_other), same(other));

    await tester.pumpWidget(fixture.page(botId: 'missing'));
    await tester.pump();
    expect(find.text('Tao on the phone'), findsNothing);
    expect(find.text('Mia on the phone'), findsNothing);
    expect(find.byType(ChatComposer), findsNothing);
    await tester.pumpWidget(const SizedBox());
    fixture.dispose();
  });

  testWidgets('waits for workspace and shares desktop and phone messages', (
    tester,
  ) async {
    final listing = Completer<List<ProjectRecord>>();
    final history = Completer<ClaudeHistoryPage>();
    final fixture = _Fixture(listing.future, (before) => history.future);
    addTearDown(fixture.dispose);
    final load = fixture.workspace.load();
    final start = fixture.bots.start();
    await tester.pumpWidget(fixture.page());
    expect(find.text('Mia'), findsOneWidget);
    expect(
      fixture.workspace.threads.where((t) => t.project.path == _main.folder),
      isEmpty,
    );
    expect(find.byType(ChatComposer), findsNothing);

    listing.complete(_kept());
    await load;
    await start;
    await tester.pump();
    final original = fixture.bots.threadOf(_main)!;
    expect(original.id, _threadId);
    await tester.pump();
    await _type(tester, 'hello from desktop');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.tap(_send);
    await tester.pump();
    expect(_editor(tester).controller.text, 'hello from desktop');
    expect(fixture.cli[_main.folder]?.users ?? [], isEmpty);
    expect(find.text('Loading conversation…'), findsOneWidget);

    history.complete(
      ClaudeHistoryPage([
        _user('private', 'previous phone message'),
        _assistant(
          'previous',
          '<bot_say>kept private reply</bot_say><bot_suggest>Continue</bot_suggest>',
        ),
      ]),
    );
    await tester.pump();
    expect(find.text('previous phone message'), findsOneWidget);
    expect(find.text('kept private reply'), findsOneWidget);

    final (phone, closePhone) = await fixture.openPhone();
    addTearDown(closePhone);

    expect(
      original.session.health.status.name,
      isNot('failed'),
      reason: original.session.health.message,
    );
    expect(original.session.loadingHistory, isFalse);
    expect(original.session.canSend, isTrue);
    expect(_editor(tester).controller.text, 'hello from desktop');
    final events = <LinkEvent>[];
    final subscription = phone.events.listen(events.add);
    await phone.call(LinkMethods.open, {'session': _threadId, 'window': 50});
    await tester.pump();
    events.clear();

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'hello from desktop',
        selection: TextSelection.collapsed(offset: 18),
        composing: TextRange(start: 11, end: 18),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(fixture.cli[_main.folder]!.users, isEmpty);
    await _type(tester, 'hello from desktop');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump();
    expect(_editor(tester).controller.text, isEmpty);
    expect(
      jsonEncode(fixture.cli[_main.folder]!.users.single),
      contains(BotSuggestions.off),
    );
    final raw = [
      for (var i = 0; i < original.session.itemCount; i++)
        original.session.itemAt(i),
    ];
    expect(
      raw.whereType<UserMessageItem>().map((item) => item.text),
      contains('hello from desktop'),
    );
    expect(find.text('hello from desktop'), findsOneWidget);
    final updates = events
        .where((event) => event.name == LinkEvents.session)
        .map(
          (event) =>
              LinkSessionUpdate.fromJson(event.data! as Map<String, Object?>),
        );
    expect(
      updates.last.items
          .map(ChatCodec.decode)
          .whereType<UserMessageItem>()
          .map((item) => item.text),
      contains('hello from desktop'),
    );

    expect(
      await phone.call(LinkMethods.send, {
        'bot': _main.id,
        'text': 'hello from phone',
      }),
      {'session': _threadId},
    );
    await tester.pump();
    expect(find.text('hello from phone'), findsOneWidget);
    expect(fixture.bots.threadOf(_main), same(original));
    expect(
      fixture.workspace.threads.where((t) => t.project.path == _main.folder),
      [original],
    );

    fixture.cli[_main.folder]!.push(
      _assistant('live', 'internal text <bot_say>local stream'),
    );
    await tester.pump();
    expect(find.text('local stream'), findsNothing);
    fixture.cli[_main.folder]!.push(
      _assistant('live', 'internal text <bot_say>local stream reply</bot_say>'),
    );
    await tester.pump();
    expect(find.text('local stream reply'), findsOneWidget);
    expect(find.textContaining('internal text'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    unawaited(subscription.cancel());
    await closePhone();
    fixture.dispose();
    await tester.pump();
  });

  testWidgets(
    'loads earlier private history, opens project cards and keeps draft on return',
    (tester) async {
      final history = <String?>[];
      final fixture = _Fixture(Future.value(_kept()), (before) async {
        history.add(before);
        return before == null
            ? ClaudeHistoryPage([
                _assistant(
                  'group-tail',
                  '<bot_say>group response at page head</bot_say>',
                ),
                _user('private', 'private question'),
                _assistant(
                  'card',
                  '<bot_show_chat>$_projectId</bot_show_chat><bot_show_chat>$_threadId</bot_show_chat>',
                ),
              ], earlier: 'private')
            : ClaudeHistoryPage([
                _user('old', 'older private message'),
                _assistant(
                  'old-a',
                  '<bot_say>older private response</bot_say>',
                ),
                _user(
                  'g',
                  '<bao-event>[group g] internal group event</bao-event>',
                ),
              ]);
      });
      addTearDown(fixture.dispose);
      final load = fixture.workspace.load();
      await fixture.bots.start();
      await load;
      await tester.pumpWidget(fixture.page());
      await tester.pump();
      expect(find.textContaining('group response'), findsNothing);
      expect(find.textContaining(_threadId), findsNothing);
      await tester.tap(find.text('Project conversation'));
      expect(fixture.opened, [_projectId]);
      await tester.tap(find.text('Load earlier messages'));
      await tester.pump();
      expect(history, [null, 'private']);
      expect(find.text('older private message'), findsOneWidget);
      expect(find.textContaining('group response'), findsNothing);
      expect(find.textContaining('internal group event'), findsNothing);
      expect(find.text('Load earlier messages'), findsNothing);

      await _type(tester, 'unsent draft');
      await tester.tap(find.byTooltip('Back'));
      expect(fixture.back, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(fixture.page());
      await tester.pump();
      expect(_editor(tester).controller.text, 'unsent draft');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('restores image, file and pasted text chips with the bot draft', (
    tester,
  ) async {
    final fixture = _Fixture(
      Future.value([_kept().first]),
      (_) async => const ClaudeHistoryPage([]),
    );
    addTearDown(fixture.dispose);
    final load = fixture.workspace.load();
    await fixture.bots.start();
    await load;
    await tester.pumpWidget(fixture.page());
    await tester.pumpAndSettle();

    final session = fixture.bots.threadOf(_main)!.session;
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
    );
    const window = MethodChannel('baocode/window');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(window, (call) async {
      return switch (call.method) {
        'readPasteboardFiles' => [
          {'path': '${_main.folder}/shot.png', 'directory': false},
          {'path': '${_main.folder}/notes.md', 'directory': false},
        ],
        'readImageFile' => {
          'bytes': png,
          'type': 'image/png',
          'name': 'shot.png',
        },
        _ => null,
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(window, null));
    await _type(tester, 'look at ');
    await tester.runAsync(
      () => tester
          .state<MarkdownEditorState>(find.byType(MarkdownEditor))
          .paste(),
    );
    await tester.pump();
    expect(session.draft.images.single.bytes, png);
    final controller = _editor(tester).controller;
    const paste = PastedText(
      number: 1,
      text: 'private pasted attachment bytes',
    );
    final atom = ComposerPastedTextEmbed.of(paste).atom;
    controller.replace(controller.length, controller.length, atom);
    const selection = TextSelection.collapsed(offset: 5);
    controller.selection = selection;
    await tester.pump();
    final content = controller.text;
    expect(find.text('notes.md'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(fixture.page());
    await tester.pumpAndSettle();
    expect(_editor(tester).controller.text, content);
    expect(_editor(tester).controller.selection, selection);
    expect(find.text('notes.md'), findsOneWidget);
    expect(session.draft.images.single.bytes, png);

    final (phone, closePhone) = await fixture.openPhone();
    addTearDown(closePhone);
    await tester.tap(_send);
    await tester.pumpAndSettle();
    expect(session.draft.content, isEmpty);
    expect(session.draft.images, isEmpty);
    final wire = jsonEncode(fixture.cli[_main.folder]!.users.single);
    expect(wire, contains('notes.md'));
    expect(wire, contains('private pasted attachment bytes'));
    expect(wire, contains(base64Encode(png)));
    expect(find.byType(ComposerPastedTextChip), findsOneWidget);
    expect(
      find.textContaining('private pasted attachment bytes'),
      findsNothing,
    );
    expect(find.textContaining('[Image #'), findsNothing);
    expect(find.byType(Image), findsOneWidget);
    await tester.tap(find.byType(ComposerPastedTextChip));
    await tester.pumpAndSettle();
    expect(find.text('private pasted attachment bytes'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    final open = LinkSessionUpdate.fromJson(
      (await phone.call(LinkMethods.open, {
            'session': _threadId,
            'window': 50,
          }))!
          as Map<String, Object?>,
    );
    expect(open.session, _threadId);
    final delivered = open.items
        .map(ChatCodec.decode)
        .whereType<UserMessageItem>()
        .single;
    expect(delivered.text, contains('notes.md'));
    expect(delivered.images.single.bytes, png);
    await tester.pumpWidget(const SizedBox());
    await closePhone();
    fixture.dispose();
    await tester.pump();
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('blocks send until a failed bot transport recovers', (
    tester,
  ) async {
    final fixture = _Fixture(
      Future.value([_kept().first]),
      (_) async => const ClaudeHistoryPage([]),
      failFirstLaunch: true,
    );
    addTearDown(fixture.dispose);
    final load = fixture.workspace.load();
    await fixture.bots.start();
    await load;
    await tester.pumpWidget(fixture.page());
    await tester.pumpAndSettle();

    final session = fixture.bots.threadOf(_main)!.session;
    expect(session.health.status, KernelHealthStatus.failed);
    expect(fixture.launches, hasLength(1));
    await _type(tester, 'keep this draft');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.tap(_send);
    await tester.pump();
    expect(fixture.launches, hasLength(1));
    expect(session.itemCount, 0);
    expect(_editor(tester).controller.text, 'keep this draft');

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(session.health.status, KernelHealthStatus.ready);
    await tester.tap(_send);
    await tester.pumpAndSettle();
    expect(fixture.cli[_main.folder]!.users, hasLength(1));
    expect(find.text('keep this draft'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    fixture.dispose();
  });

  testWidgets('recalls only private prompts and keeps the bot tool policy', (
    tester,
  ) async {
    final fixture = _Fixture(
      Future.value([_kept().first]),
      (_) async => ClaudeHistoryPage([
        _user(
          'private',
          'private question <bao-event>embedded note</bao-event>',
        ),
        _assistant('private-answer', '<bot_say>private response</bot_say>'),
        _user('group', '<bao-event>[group g] hidden question</bao-event>'),
        _assistant('group-answer', '<bot_say>hidden response</bot_say>'),
      ]),
      mainBot: _main.copyWith(chatOnly: true),
    );
    addTearDown(fixture.dispose);
    final load = fixture.workspace.load();
    await fixture.bots.start();
    await load;
    await tester.pumpWidget(fixture.page());
    await tester.pumpAndSettle();

    final session = fixture.bots.threadOf(_main)!.session;
    final launch = fixture.launches.single;
    expect(launch.ownPrompt, isTrue);
    expect(launch.tools, ['WebSearch', 'WebFetch', 'Read']);
    expect(launch.userServers, isFalse);
    expect(session.selected(KernelChoiceKind.mode), 'agent');
    expect(session.selected(KernelChoiceKind.permission), 'bypassPermissions');
    expect(find.byType(ComposerPicker), findsNothing);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(session.selected(KernelChoiceKind.mode), 'agent');
    _editor(tester).focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(_editor(tester).controller.text, 'private question');
    expect(find.textContaining('hidden'), findsNothing);
    expect(find.textContaining('embedded note'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    fixture.dispose();
  });

  testWidgets('queues private input without interrupting a live group turn', (
    tester,
  ) async {
    final fixture = _Fixture(
      Future.value([_kept().first]),
      (_) async => const ClaudeHistoryPage([]),
    );
    addTearDown(fixture.dispose);
    final load = fixture.workspace.load();
    await fixture.bots.start();
    await load;
    await tester.pumpWidget(fixture.page());
    await tester.pumpAndSettle();
    final session = fixture.bots.threadOf(_main)!.session;
    final cli = fixture.cli[_main.folder]!;
    session.send(
      const ComposerMessage(
        text: '<bao-event>[group g] group input</bao-event>',
      ),
    );
    await tester.pumpAndSettle();
    expect(session.isStreaming, isTrue);
    expect(find.byKey(const ValueKey('stop')), findsNothing);

    await _type(tester, 'first line');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(_editor(tester).controller.text, 'first line\n');
    await _type(tester, 'first line\nsecond line');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(session.isStreaming, isTrue);
    Iterable<UserMessageItem> queued() => Iterable.generate(
      session.itemCount,
      session.itemAt,
    ).whereType<UserMessageItem>().where((item) => item.queued);
    expect(queued().single.text, 'first line\nsecond line');
    expect(_editor(tester).controller.text, isEmpty);
    expect(cli.users.last['priority'], 'next');

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(cli.requests('interrupt'), isEmpty);
    expect(session.isStreaming, isTrue);
    expect(cli.users, hasLength(2));
    expect(queued().single.text, 'first line\nsecond line');
    expect(find.textContaining('group input'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    fixture.dispose();
  });
}

final _send = find.byKey(const ValueKey('send'));

MarkdownEditor _editor(WidgetTester tester) =>
    tester.widget<MarkdownEditor>(find.byType(MarkdownEditor));

Future<void> _type(WidgetTester tester, String text) async {
  _editor(tester).focusNode!.requestFocus();
  await tester.pump();
  tester.testTextInput.updateEditingValue(
    TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    ),
  );
  await tester.pump();
}

class _Fixture {
  _Fixture(
    Future<List<ProjectRecord>> listing,
    Future<ClaudeHistoryPage> Function(String?) history, {
    Future<ClaudeHistoryPage>? otherHistory,
    Bot mainBot = _main,
    bool failFirstLaunch = false,
  }) {
    late final KernelDescriptor descriptor;
    descriptor = KernelDescriptor(
      id: 'claude-code',
      label: 'Claude Code',
      icon: Icons.auto_awesome_rounded,
      description: '',
      catalog: _Catalog(listing),
      create: (context) => ClaudeCodeKernel(
        descriptor,
        context,
        start: (launch) async {
          launches.add(launch);
          if (failFirstLaunch && launches.length == 1) {
            throw const ClaudeUnavailable('Test transport unavailable');
          }
          return cli[context.cwd] = FakeCli();
        },
        readHistoryPage: (session, {required turns, before}) =>
            session.id == _otherThreadId ? otherHistory! : history(before),
      ),
    );
    workspace = Workspace(kernels: [descriptor]);
    final folders = MemoryBotFolders();
    for (final bot in [mainBot, if (otherHistory != null) _other]) {
      folders.make(bot.folder);
      folders.writeFile(
        p.join(bot.folder, BotFiles.card),
        Uint8List.fromList(BotFiles.cardText(bot).codeUnits),
      );
    }
    bots = Bots(
      workspace: workspace,
      folders: folders,
      computer: () async => 'Mac',
    )..hasPhone = () => false;
  }

  late final Workspace workspace;
  late final Bots bots;
  final cli = <String?, FakeCli>{};
  final launches = <ClaudeLaunch>[];
  final opened = <String>[];
  int back = 0;

  Future<(LinkPeer, Future<void> Function())> openPhone() async {
    final (phoneConn, desktopConn) = MemoryLinkConnection.pair(
      a: LinkIdentity.generate().id,
      b: LinkIdentity.generate().id,
    );
    late final WorkspaceBridge bridge;
    final accepting = LinkPeer.accept(
      desktopConn,
      onRequest: (method, params) => bridge.handle(method, params),
    );
    final phone = await LinkPeer.connect(phoneConn);
    final desktop = await accepting;
    bridge = WorkspaceBridge(
      workspace: workspace,
      peer: desktop,
      device: () => const DeviceInfo(name: 'Mac', kind: 'mac', system: 'macOS'),
      bots: bots,
      throttle: const Duration(milliseconds: 10),
    )..start();
    return (
      phone,
      () async {
        bridge.dispose();
        await phone.close();
        await desktop.close();
      },
    );
  }

  Widget page({String? botId}) => MaterialApp(
    home: Scaffold(
      body: DesktopBotPage(
        bots: bots,
        botId: botId,
        onBack: () => back++,
        onOpenChat: opened.add,
      ),
    ),
  );

  Widget hub() => MaterialApp(
    home: Scaffold(
      body: DesktopBotHub(
        bots: bots,
        onBack: () => back++,
        onOpenChat: opened.add,
      ),
    ),
  );

  bool _disposed = false;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    bots.dispose();
    workspace.dispose();
  }
}

class _Catalog(this.listing) implements SessionCatalog {
  final Future<List<ProjectRecord>> listing;
  @override
  Future<List<ProjectRecord>> projects() => listing;
  @override
  Future<List<SessionRecord>> sessionsIn(String cwd) async => const [];
  @override
  Future<void> delete(String id) async {}
}

List<ProjectRecord> _kept() => [
  ProjectRecord(
    path: _main.folder,
    sessions: [
      SessionRecord(
        id: _threadId,
        title: 'Bot conversation',
        updatedAt: DateTime(2026),
        cwd: _main.folder,
      ),
    ],
  ),
  ProjectRecord(
    path: '/project',
    sessions: [
      SessionRecord(
        id: _projectId,
        title: 'Project conversation',
        updatedAt: DateTime(2026),
        cwd: '/project',
      ),
    ],
  ),
];

Map<String, Object?> _user(String id, String text, {DateTime? at}) => {
  'type': 'user',
  'uuid': id,
  if (at != null) 'timestamp': at.toIso8601String(),
  'message': {'role': 'user', 'content': text},
};

Map<String, Object?> _assistant(String id, String text) => {
  'type': 'assistant',
  'uuid': id,
  'message': {
    'id': 'm-$id',
    'role': 'assistant',
    'model': 'claude-opus-5-5',
    'content': [
      {'type': 'text', 'text': text},
    ],
  },
};
