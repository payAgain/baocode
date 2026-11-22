import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bao_link/bao_link.dart';
import 'package:bao_remote/claude.dart' show ClaudeHistoryPage;
import 'package:bao_remote/local.dart' show ClaudeSessions;
import 'package:baocode/bots/bot.dart';
import 'package:baocode/bots/bot_files.dart';
import 'package:baocode/bots/bot_folders.dart';
import 'package:baocode/bots/bot_group_prompt.dart';
import 'package:baocode/bots/bots.dart';
import 'package:baocode/bots/desktop_bot_hub.dart';
import 'package:baocode/bots/desktop_bot_page.dart';
import 'package:baocode/bots/desktop_bot_settings.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/link/chat_codec.dart';
import 'package:baocode/link/workspace_bridge.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
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
    await tester.enterText(find.byType(TextField), 'Mia draft');

    await tester.pumpWidget(fixture.page(botId: _other.id));
    await tester.pump();
    expect(find.text('Tao'), findsOneWidget);
    expect(find.text('Mia on the phone'), findsNothing);
    expect(find.text('Mia draft'), findsNothing);
    expect(find.text('Loading conversation…'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Tao draft');

    await tester.pumpWidget(fixture.page());
    await tester.pump();
    pending.complete(ClaudeHistoryPage([_user('tao', 'Tao on the phone')]));
    await tester.pump();
    expect(find.text('Mia on the phone'), findsOneWidget);
    expect(find.text('Mia draft'), findsOneWidget);
    expect(find.text('Tao on the phone'), findsNothing);

    await tester.pumpWidget(fixture.page(botId: _other.id));
    await tester.pump();
    expect(find.text('Tao on the phone'), findsOneWidget);
    expect(find.text('Tao draft'), findsOneWidget);
    expect(find.text('Mia on the phone'), findsNothing);
    expect(fixture.bots.threadOf(_other), same(other));

    await tester.pumpWidget(fixture.page(botId: 'missing'));
    await tester.pump();
    expect(find.text('Tao on the phone'), findsNothing);
    expect(find.text('Mia on the phone'), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
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
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.arrow_upward),
          )
          .onPressed,
      isNull,
    );

    listing.complete(_kept());
    await load;
    await start;
    await tester.pump();
    final original = fixture.bots.threadOf(_main)!;
    expect(original.id, _threadId);
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
    await tester.enterText(find.byType(TextField), 'hello from desktop');
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'hello from desktop',
    );
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.arrow_upward),
          )
          .onPressed,
      isNull,
    );
    expect(find.text('Loading conversation…'), findsOneWidget);

    history.complete(
      ClaudeHistoryPage([
        _user('private', 'previous phone message'),
        _assistant('previous', '<bot_say>kept private reply</bot_say>'),
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
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'hello from desktop',
    );
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.arrow_upward),
          )
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
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
    final open = LinkSessionUpdate.fromJson(
      (await phone.call(LinkMethods.open, {
            'session': _threadId,
            'window': 50,
          }))!
          as Map<String, Object?>,
    );
    expect(
      open.items
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

      await tester.enterText(find.byType(TextField), 'unsent draft');
      await tester.tap(find.byTooltip('Back'));
      expect(fixture.back, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(fixture.page());
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'unsent draft',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
}

class _Fixture {
  _Fixture(
    Future<List<ProjectRecord>> listing,
    Future<ClaudeHistoryPage> Function(String?) history, {
    Future<ClaudeHistoryPage>? otherHistory,
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
        start: (_) async => cli[context.cwd] = FakeCli(),
        readHistoryPage: (session, {required turns, before}) =>
            session.id == _otherThreadId ? otherHistory! : history(before),
      ),
    );
    workspace = Workspace(kernels: [descriptor]);
    final folders = MemoryBotFolders();
    for (final bot in [_main, if (otherHistory != null) _other]) {
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
