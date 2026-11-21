import 'dart:async';
import 'dart:typed_data';

import 'package:bao_link/bao_link.dart';
import 'package:bao_remote/claude.dart' show ClaudeHistoryPage;
import 'package:baocode/bots/bot.dart';
import 'package:baocode/bots/bot_files.dart';
import 'package:baocode/bots/bot_folders.dart';
import 'package:baocode/bots/bots.dart';
import 'package:baocode/bots/desktop_bot_page.dart';
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

void main() {
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
      workspace: fixture.workspace,
      peer: desktop,
      device: () => const DeviceInfo(name: 'Mac', kind: 'mac', system: 'macOS'),
      bots: fixture.bots,
      throttle: const Duration(milliseconds: 10),
    )..start();
    addTearDown(() async {
      bridge.dispose();
      await phone.close();
      await desktop.close();
    });

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
    bridge.dispose();
    await phone.close();
    await desktop.close();
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
    Future<ClaudeHistoryPage> Function(String?) history,
  ) {
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
        readHistoryPage: (_, {required turns, before}) => history(before),
      ),
    );
    workspace = Workspace(kernels: [descriptor]);
    final folders = MemoryBotFolders()..make(_main.folder);
    folders.writeFile(
      p.join(_main.folder, BotFiles.card),
      Uint8List.fromList(BotFiles.cardText(_main).codeUnits),
    );
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

  Widget page() => MaterialApp(
    home: Scaffold(
      body: DesktopBotPage(
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

Map<String, Object?> _user(String id, String text) => {
  'type': 'user',
  'uuid': id,
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
