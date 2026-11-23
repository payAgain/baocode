import 'dart:async';
import 'dart:convert';

import 'package:bao_link/bao_link.dart';
import 'package:bao_markdown/bao_markdown.dart'
    show MarkdownEditor, MarkdownEditorState;
import 'package:baocode/bots/bot_folders.dart' show MemoryBotFolders;
import 'package:baocode/bots/bots.dart' show Bots;
import 'package:baocode/chat/chat_models.dart' show ImageAttachment;
import 'package:baocode/l10n/l10n.dart' show AppLocalizations;
import 'package:baocode/link/desktop_host_chats.dart';
import 'package:baocode/link/desktop_host_connection.dart';
import 'package:baocode/link/desktop_host_page.dart';
import 'package:baocode/link/desktop_remote_people.dart';
import 'package:baocode/link/workspace_bridge.dart' show WorkspaceBridge;
import 'package:baocode/workspace/workspace.dart' show Workspace;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _assistant = LinkBot(id: 'assistant', name: 'Assistant', assistant: true);
const _bot = LinkBot(
  id: 'b1',
  name: 'Fixture Bot',
  avatar: 'avatar-abc.png',
  identity: 'Fixture identity',
  style: 'Fixture style',
  abilities: {BotAbility.browser},
  chatOnly: true,
  writesFirst: false,
  proactive: BotProactive(perDay: 3, quietFrom: 55, quietTo: 90),
);
const _group = LinkGroup(id: 'g1', name: 'Fixture Group', members: ['b1']);
const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
    '+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

class _Host {
  _Host({this.legacy = false});

  final bool legacy;
  final calls = <(String, Map<String, Object?>)>[];
  late final LinkPeer peer;
  late final LinkPeer server;
  final bots = <String, Map<String, Object?>>{
    'assistant': _assistant.toJson(),
    'b1': _bot.toJson(),
  };
  final group = _group.toJson();
  List<Map<String, Object?>> groupMessages = [];
  List<Map<String, Object?>> earlierGroupMessages = [];
  Object? groupSendReply;
  List<String> groupOptions = [];
  String memory = 'Initial memory';
  String self = 'Initial notes';
  String session = 'prior-chat';
  Map<String, Object?>? profile;
  Completer<Object?>? gatedState;
  final pictures = <String, Object?>{};
  final unavailable = <String>{};

  Future<void> open({String host = 'fixture-host'}) async {
    final (a, b) = MemoryLinkConnection.pair(a: 'fixture-client', b: host);
    final pending = LinkPeer.accept(b, onRequest: _handle);
    peer = await LinkPeer.connect(a);
    server = await pending;
  }

  Future<void> close() async {
    await peer.close();
    await server.close();
  }

  Map<String, Object?> get catalog => {
    'device': const DeviceInfo(
      name: 'Fixture Host',
      kind: 'mac',
      system: '',
    ).toJson(),
    'bots': [
      for (final bot in bots.values)
        {...bot, if (bot['id'] == 'b1') 'session': session},
    ],
    'groups': [if (group.isNotEmpty) group],
    if (groupOptions.isNotEmpty) 'groupOptions': groupOptions,
  };

  List<Map<String, Object?>> writes(String method) => [
    for (final (m, args) in calls)
      if (m == method) args,
  ];

  FutureOr<Object?> _handle(String method, Map<String, Object?> args) {
    calls.add((method, args));
    if (unavailable.contains(method)) {
      throw const LinkRemoteException('unknown', 'fixture');
    }
    switch (method) {
      case LinkMethods.state:
        if (gatedState case final gate?) return gate.future;
        return catalog;
      case LinkMethods.open:
        return LinkSessionUpdate(
          session: args['session'] as String,
          start: 0,
          count: 0,
          items: [],
        ).toJson();
      case LinkMethods.openGroup:
        return {
          'group': args['group'],
          'messages': groupMessages,
          'more': earlierGroupMessages.isNotEmpty,
        };
      case LinkMethods.earlierGroup:
        return {'messages': earlierGroupMessages, 'more': false};
      case LinkMethods.sendGroup:
        return groupSendReply;
      case LinkMethods.close:
      case LinkMethods.closeGroup:
        return null;
      case LinkMethods.saveBot:
        final id = args['bot'] as String? ?? 'created';
        bots[id] = {...?bots[id], ...args, 'id': id};
        if (args['avatarImage'] case final picture?) {
          pictures[id] = picture;
          bots[id]!['avatar'] = 'avatar-changed.png';
        }
        return {'bot': bots[id]};
      case LinkMethods.botAvatar:
        if (pictures[args['bot']] case final picture?) return picture;
        throw const LinkRemoteException(LinkErrors.notFound, 'fixture');
      case LinkMethods.botMemory:
        return {'text': memory, if (!legacy) 'self': self};
      case LinkMethods.setBotMemory:
        memory = args['text'] as String;
        return null;
      case LinkMethods.setBotSelf:
        self = args['text'] as String;
        return null;
      case LinkMethods.clearBotChat:
        session = 'new-chat';
        return null;
      case LinkMethods.deleteBot:
        bots.remove(args['bot']);
        return null;
      case LinkMethods.saveGroup:
        group.addAll({...args, 'id': args['group'] ?? 'made-group'});
        if (legacy) group.remove('gap');
        if (group['lead'] == null) group.remove('lead');
        return {'group': group};
      case LinkMethods.deleteGroup:
        group.clear();
        return null;
      case LinkMethods.setMe:
        profile = args;
        return null;
      default:
        throw const LinkRemoteException('unknown', 'fixture');
    }
  }
}

Future<void> _mount(
  WidgetTester tester,
  LinkPeer? peer, {
  Future<ImageAttachment?> Function()? pickImage,
  void Function(LinkPeer, Map<String, Object?>)? onCatalog,
  Locale? locale,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: DesktopRemotePeopleManager(
          peer: peer,
          pickImage: pickImage,
          onCatalog: onCatalog,
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _tap(WidgetTester tester, String text) async {
  final button = find.text(text).last;
  await tester.ensureVisible(button);
  await tester.pump();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String field, String text) async {
  final input = find.byWidgetPredicate(
    (widget) => widget is TextField && widget.decoration?.labelText == field,
  );
  await tester.ensureVisible(input);
  await tester.pump();
  await tester.enterText(input, text);
  await tester.pump();
}

Future<void> _finish(WidgetTester tester, List<_Host> hosts) async {
  await tester.pumpWidget(const SizedBox.shrink());
  for (final host in hosts) {
    await host.close();
  }
  await tester.pump();
}

class _PageConnection extends ChangeNotifier implements DesktopHostConnection {
  _PageConnection(this.peer);

  @override
  LinkPeer? peer;
  @override
  String? get pendingCode => null;
  @override
  String? get hostName => 'Fixture Host';
  @override
  String? get error => null;
  @override
  bool get busy => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  void replacePeer(LinkPeer next) {
    peer = next;
    notifyListeners();
  }
}

Future<void> _mountPage(
  WidgetTester tester,
  _PageConnection connection,
  DesktopHostChats chats, {
  Size size = const Size(1280, 850),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(connection.dispose);
  addTearDown(chats.dispose);
  chats.bind(connection.peer);
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: DesktopHostPage(
          connection: connection,
          chats: chats,
          onBack: () {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'a preflight reply cannot write to a replaced peer before the page repaints',
    (tester) async {
      final first = _Host();
      final second = _Host();
      await first.open();
      await second.open();
      final connection = _PageConnection(first.peer);
      final chats = DesktopHostChats();
      await _mountPage(tester, connection, chats);
      try {
        await _tap(tester, 'Fixture Bot');
        await tester.tap(find.byTooltip('Bot settings'));
        await tester.pumpAndSettle();
        await _enter(tester, 'Name', 'Do not save on the previous peer');
        final gate = first.gatedState = Completer<Object?>();
        final button = find.text('Save');
        await tester.ensureVisible(button);
        await tester.pump();
        await tester.tap(button);
        await tester.pump();
        final received = first.writes(LinkMethods.state).length;
        expect(received, 3); // Bind, open the editor, preflight.

        chats.bind(second.peer);
        connection.replacePeer(second.peer);
        first.gatedState = null;
        gate.complete(first.catalog);
        // Flush the RPC reply without drawing the frame that removes the dock.
        await tester.idle();
        expect(first.writes(LinkMethods.saveBot), isEmpty);
        expect(second.writes(LinkMethods.saveBot), isEmpty);
        await tester.pumpAndSettle();
        expect(find.byType(DesktopRemotePeopleManager), findsNothing);
      } finally {
        await _finish(tester, [first, second]);
      }
    },
  );

  testWidgets('catalog launches People and applies reply-only changes', (
    tester,
  ) async {
    final host = _Host();
    await host.open();
    final chats = DesktopHostChats();
    await _mountPage(tester, _PageConnection(host.peer), chats);
    try {
      await _tap(tester, 'Manage bots, groups & profile');
      final panel = find.byType(DesktopRemotePeopleManager);
      expect(panel, findsOneWidget);
      final catalog = find.byKey(const ValueKey('host-catalog'));
      expect(
        tester.getRect(catalog).right,
        lessThan(tester.getRect(panel).left),
      );
      await tester.tap(
        find.descendant(of: panel, matching: find.text('Fixture Group')),
      );
      await tester.pumpAndSettle();
      await _enter(tester, 'Name', 'Group from catalog');
      await _tap(tester, 'Save');
      expect(host.writes(LinkMethods.saveGroup).single['group'], 'g1');
      expect(
        find.descendant(of: catalog, matching: find.text('Group from catalog')),
        findsOneWidget,
      );
    } finally {
      await _finish(tester, [host]);
    }
  });

  testWidgets(
    'private Bot settings dock beside the live editor and preserve its draft',
    (tester) async {
      final host = _Host();
      await host.open();
      final chats = DesktopHostChats();
      await _mountPage(tester, _PageConnection(host.peer), chats);
      try {
        await _tap(tester, 'Fixture Bot');
        final editor = find.byType(MarkdownEditor);
        final editorState = tester.state<MarkdownEditorState>(editor);
        Future<void> typeChat(String text) async {
          await tester.tap(editor);
          await tester.pump();
          tester.testTextInput.updateEditingValue(
            TextEditingValue(
              text: text,
              selection: TextSelection.collapsed(offset: text.length),
            ),
          );
          await tester.pump();
          expect(editorState.controller.text, text);
        }

        await typeChat('Chat draft');
        final initialWidth = tester.getSize(editor).width;
        await tester.tap(find.byTooltip('Bot settings'));
        await tester.pumpAndSettle();
        final panel = find.byType(DesktopRemotePeopleManager);
        expect(find.text('Bot settings'), findsOneWidget);
        expect(
          tester.getRect(editor).right,
          lessThanOrEqualTo(tester.getRect(panel).left),
        );
        expect(tester.getSize(editor).width, lessThan(initialWidth));
        expect(tester.state<MarkdownEditorState>(editor), same(editorState));
        expect(editor.hitTestable(), findsOneWidget);
        await typeChat('Updated chat draft');
        await _enter(tester, 'Name', 'Bot from settings');
        await _tap(tester, 'Save');
        expect(panel, findsNothing);
        expect(host.writes(LinkMethods.saveBot).single['bot'], 'b1');
        expect(chats.selected?.title, 'Bot from settings');
        expect(host.writes(LinkMethods.open).single['session'], 'prior-chat');
        expect(tester.state<MarkdownEditorState>(editor), same(editorState));
        expect(editorState.controller.text, 'Updated chat draft');
        expect(tester.getSize(editor).width, initialWidth);
      } finally {
        await _finish(tester, [host]);
      }
    },
  );

  testWidgets(
    'group Reply sends the selected sequence and clears on confirmation',
    (tester) async {
      final host = _Host()
        ..groupMessages = [
          {
            'seq': 41,
            'from': 'b1',
            'text': '<bot_say>Original thought</bot_say>',
          },
        ];
      await host.open();
      final chats = DesktopHostChats();
      await _mountPage(tester, _PageConnection(host.peer), chats);
      try {
        await _tap(tester, 'Fixture Group');
        await tester.tap(find.byTooltip('Reply to message'));
        await tester.pumpAndSettle();
        expect(find.text('Replying to #41 · Fixture Bot'), findsOneWidget);
        final editor = find.byType(MarkdownEditor);
        await tester.tap(editor);
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: 'Follow-up',
            selection: TextSelection.collapsed(offset: 9),
          ),
        );
        await tester.pump();
        await tester.tap(find.byTooltip('Cancel reply'));
        await tester.pumpAndSettle();
        expect(find.text('Replying to #41 · Fixture Bot'), findsNothing);
        expect(
          tester.state<MarkdownEditorState>(editor).controller.text,
          'Follow-up',
        );
        await tester.tap(find.byTooltip('Reply to message'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Send'));
        await tester.pumpAndSettle();
        expect(host.writes(LinkMethods.sendGroup).single, {
          'group': 'g1',
          'text': 'Follow-up',
          'id': isA<String>(),
          'ref': 41,
        });
        expect(find.text('Replying to #41 · Fixture Bot'), findsOneWidget);
        host.groupSendReply = {'seq': 42};
        await tester.tap(find.byTooltip('Send'));
        await tester.pumpAndSettle();
        expect(host.writes(LinkMethods.sendGroup).last['ref'], 41);
        expect(find.text('Replying to #41 · Fixture Bot'), findsNothing);
        expect(
          tester.state<MarkdownEditorState>(editor).controller.text,
          isEmpty,
        );
        expect(host.writes(LinkMethods.openGroup), hasLength(1));
      } finally {
        await _finish(tester, [host]);
      }
    },
  );

  testWidgets(
    'a group reply is discarded when the authenticated peer is replaced',
    (tester) async {
      final first = _Host()
        ..groupMessages = [
          {'seq': 41, 'from': 'b1', 'text': '<bot_say>First peer</bot_say>'},
        ];
      final second = _Host()
        ..groupMessages = [
          {'seq': 41, 'from': 'b1', 'text': '<bot_say>Second peer</bot_say>'},
        ];
      await first.open();
      await second.open();
      final connection = _PageConnection(first.peer);
      final chats = DesktopHostChats();
      await _mountPage(tester, connection, chats);
      try {
        await _tap(tester, 'Fixture Group');
        final reply = find.byTooltip('Reply to message');
        final staleReply = tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is IconButton &&
                    widget.tooltip == 'Reply to message',
              ),
            )
            .onPressed!;
        await tester.tap(reply);
        await tester.pumpAndSettle();
        expect(find.text('Replying to #41 · Fixture Bot'), findsOneWidget);

        connection.replacePeer(second.peer);
        chats.bind(second.peer);
        staleReply();
        await tester.pumpAndSettle();
        expect(find.text('Replying to #41 · Fixture Bot'), findsNothing);
        expect(second.writes(LinkMethods.openGroup).single['group'], 'g1');
        expect(second.writes(LinkMethods.sendGroup), isEmpty);
        await tester.tap(reply);
        await tester.pumpAndSettle();
        expect(
          find.byWidgetPredicate(
            (widget) => widget is Text && widget.data == 'Second peer',
          ),
          findsOneWidget,
        );
        expect(find.text('First peer'), findsNothing);
      } finally {
        await _finish(tester, [first, second]);
      }
    },
  );

  testWidgets(
    'group transcript resolves host references within its own history',
    (tester) async {
      final host = _Host()
        ..groupMessages = [
          {'seq': 41, 'from': 'user', 'text': 'User reply', 'ref': 40},
          {
            'seq': 42,
            'from': 'b1',
            'text': '<bot_say ref="41">Bot reply</bot_say>',
          },
        ]
        ..earlierGroupMessages = [
          {
            'seq': 40,
            'from': 'b1',
            'text': '<bot_say>Earlier message</bot_say>',
          },
        ];
      await host.open();
      await _mountPage(tester, _PageConnection(host.peer), DesktopHostChats());
      try {
        await _tap(tester, 'Fixture Group');
        expect(find.text('Quoted #41 · You'), findsOneWidget);
        expect(find.text('Quoted #40'), findsOneWidget);
        expect(host.writes(LinkMethods.earlierGroup), isEmpty);
        await _tap(tester, 'Load earlier messages');
        expect(host.writes(LinkMethods.earlierGroup).single['before'], 41);
        expect(find.text('Quoted #40 · Fixture Bot'), findsOneWidget);
        expect(find.text('Quoted #40'), findsNothing);
        expect(host.writes(LinkMethods.openGroup), hasLength(1));
      } finally {
        await _finish(tester, [host]);
      }
    },
  );

  testWidgets('compact group settings close back to the same group chat', (
    tester,
  ) async {
    final host = _Host();
    await host.open();
    final chats = DesktopHostChats();
    await _mountPage(
      tester,
      _PageConnection(host.peer),
      chats,
      size: const Size(550, 740),
    );
    try {
      await _tap(tester, 'Fixture Group');
      final editor = find.byType(MarkdownEditor);
      final editorState = tester.state<MarkdownEditorState>(editor);
      await tester.tap(find.byTooltip('Group settings'));
      await tester.pumpAndSettle();
      expect(find.text('Group settings'), findsOneWidget);
      expect(editor.hitTestable(), findsNothing);
      await _enter(tester, 'Name', 'Unsent group settings');
      tester.view.physicalSize = const Size(915, 740);
      await tester.pumpAndSettle();
      expect(find.text('Unsent group settings'), findsOneWidget);
      expect(editor.hitTestable(), findsOneWidget);
      tester.view.physicalSize = const Size(550, 740);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Back to workspace'));
      await tester.pumpAndSettle();
      expect(editor.hitTestable(), findsOneWidget);
      expect(tester.state<MarkdownEditorState>(editor), same(editorState));
      expect(chats.selected?.id, 'g1');
      expect(host.writes(LinkMethods.openGroup).single['group'], 'g1');
    } finally {
      await _finish(tester, [host]);
    }
  });

  testWidgets(
    'a closed dock forwards replies only from the currently bound peer',
    (tester) async {
      final first = _Host();
      final second = _Host();
      await first.open();
      // Even reconnecting to the same authenticated host must reject old replies.
      await second.open();
      second.bots['b1']!['name'] = 'Replacement peer Bot';
      final connection = _PageConnection(first.peer);
      final chats = DesktopHostChats();
      await _mountPage(tester, connection, chats);
      try {
        final firstReply = first.gatedState = Completer<Object?>();
        await tester.tap(find.text('Manage bots, groups & profile'));
        await tester.pump();
        await tester.tap(find.byTooltip('Close settings'));
        await tester.pump();
        first.bots['b1']!['name'] = 'Updated after close';
        firstReply.complete(first.catalog);
        await tester.pumpAndSettle();
        expect(find.text('Updated after close'), findsOneWidget);

        final oldReply = first.gatedState = Completer<Object?>();
        await tester.tap(find.text('Manage bots, groups & profile'));
        await tester.pump();
        chats.bind(second.peer);
        connection.replacePeer(second.peer);
        await tester.pumpAndSettle();
        expect(find.byType(DesktopRemotePeopleManager), findsNothing);
        oldReply.complete(first.catalog);
        await tester.pumpAndSettle();
        expect(find.text('Replacement peer Bot'), findsOneWidget);
        expect(find.text('Updated after close'), findsNothing);
      } finally {
        for (final gate in [first.gatedState]) {
          if (gate != null && !gate.isCompleted) gate.complete(first.catalog);
        }
        await _finish(tester, [first, second]);
      }
    },
  );

  testWidgets(
    'Bot edit rebases unchanged host fields and keeps its picture token',
    (tester) async {
      final host = _Host();
      await host.open();
      await _mount(tester, host.peer);
      await _tap(tester, 'Fixture Bot');
      expect(host.writes(LinkMethods.botAvatar).single, {'bot': 'b1'});
      await _enter(tester, 'Name', 'Renamed Bot');
      host.bots['b1']!['style'] = 'Changed on host while editing';
      await _tap(tester, 'Save');

      expect(host.writes(LinkMethods.saveBot).single, {
        'bot': 'b1',
        'name': 'Renamed Bot',
        'avatar': 'avatar-abc.png',
        'identity': 'Fixture identity',
        'style': 'Changed on host while editing',
        'abilities': ['browser'],
        'proactive': {'perDay': 3, 'quietFrom': 55, 'quietTo': 90},
      });
      expect(find.text('Renamed Bot'), findsOneWidget);
      await _finish(tester, [host]);
    },
  );

  testWidgets('a concurrent change to the edited Bot field blocks the write', (
    tester,
  ) async {
    final host = _Host();
    await host.open();
    await _mount(tester, host.peer);
    await _tap(tester, 'Fixture Bot');
    await _enter(tester, 'Name', 'Desktop edit');
    host.bots['b1']!['name'] = 'Host edit';
    await _tap(tester, 'Save');
    expect(host.writes(LinkMethods.saveBot), isEmpty);
    expect(
      find.text(
        'Settings changed on the host. Reopen the editor to try again.',
      ),
      findsOneWidget,
    );
    await _finish(tester, [host]);
  });

  testWidgets('creates a Bot without an existing Bot ID', (tester) async {
    final host = _Host();
    await host.open();
    await _mount(tester, host.peer);
    await _tap(tester, 'New Bot');
    await _enter(tester, 'Name', 'Created Bot');
    await _tap(tester, 'Save');
    final request = host.writes(LinkMethods.saveBot).single;
    expect(request.containsKey('bot'), isFalse);
    expect(request['name'], 'Created Bot');
    expect(find.text('Created Bot'), findsOneWidget);
    await _finish(tester, [host]);
  });

  testWidgets('legacy group edit omits unadvertised settings', (tester) async {
    final host = _Host(legacy: true);
    await host.open();
    await _mount(tester, host.peer);
    await _tap(tester, 'Fixture Group');
    expect(find.text('Reply delay (seconds)'), findsNothing);
    expect(find.text('Default lead'), findsNothing);
    await _enter(tester, 'Name', 'Renamed Group');
    await _tap(tester, 'Save');
    expect(host.writes(LinkMethods.saveGroup).single, {
      'group': 'g1',
      'name': 'Renamed Group',
      'members': ['b1'],
    });
    await _finish(tester, [host]);
  });

  testWidgets(
    'group settings edit advanced options when the host omits defaults',
    (tester) async {
      final workspace = Workspace();
      final bots = Bots(workspace: workspace, folders: MemoryBotFolders());
      final bot = bots.save(
        name: 'Group member',
        identity: 'Synthetic member',
        abilities: const {},
      );
      final group = bots.groups.save(name: 'Fixture Group', members: [bot.id]);
      final (local, remote) = MemoryLinkConnection.pair();
      final accepting = LinkPeer.accept(remote);
      final peer = await LinkPeer.connect(local);
      final server = await accepting;
      final bridge = WorkspaceBridge(
        workspace: workspace,
        peer: server,
        device: () =>
            const DeviceInfo(name: 'Fixture', kind: 'mac', system: ''),
        bots: bots,
      )..start();
      final writes = <Map<String, Object?>>[];
      var opens = 0;
      server.onRequest = (method, args) {
        if (method == LinkMethods.saveGroup) writes.add(args);
        if (method == LinkMethods.openGroup) opens++;
        return bridge.handle(method, args);
      };
      try {
        final state =
            await peer.call(LinkMethods.state) as Map<String, Object?>;
        expect(state['groupOptions'], ['passes', 'rules', 'gap', 'lead']);
        final wireGroup = (state['groups'] as List).single as Map;
        expect(
          wireGroup.keys,
          isNot(contains(anyOf('passes', 'rules', 'gap'))),
        );
        await _mountPage(tester, _PageConnection(peer), DesktopHostChats());
        await _tap(tester, 'Fixture Group');
        await tester.tap(find.byTooltip('Group settings'));
        await tester.pumpAndSettle();
        expect(find.text('Conversation passes'), findsOneWidget);
        expect(find.text('Default lead'), findsNothing);
        await _enter(tester, 'Conversation passes', '6');
        await _enter(tester, 'Rules', 'Synthetic group rules');
        await _enter(tester, 'Reply delay (seconds)', '4');
        await _tap(tester, 'Save');
        expect(writes.single, {
          'group': group.id,
          'name': 'Fixture Group',
          'members': [bot.id],
          'passes': 6,
          'rules': 'Synthetic group rules',
          'gap': 4,
        });
        await tester.tap(find.byTooltip('Group settings'));
        await tester.pumpAndSettle();
        expect(find.text('Synthetic group rules'), findsOneWidget);
        expect(find.text('4'), findsOneWidget);
        expect(opens, 1);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        bridge.dispose();
        await peer.close();
        await server.close();
        bots.dispose();
        workspace.dispose();
        await tester.pump();
      }
    },
  );

  testWidgets(
    'group lead uses the existing member ID, omission and null contract',
    (tester) async {
      final host = _Host()..group['lead'] = 'b1';
      await host.open();
      await _mountPage(tester, _PageConnection(host.peer), DesktopHostChats());
      try {
        await _tap(tester, 'Fixture Group');
        Future<void> openSettings() async {
          await tester.tap(find.byTooltip('Group settings'));
          await tester.pumpAndSettle();
          expect(find.text('Default lead'), findsOneWidget);
        }

        Future<void> chooseLead(String value) async {
          final picker = find.byKey(const ValueKey('remote-group-lead'));
          await tester.ensureVisible(picker);
          await tester.tap(picker);
          await tester.pumpAndSettle();
          expect(
            find.descendant(
              of: find.byType(DropdownMenuItem<String>),
              matching: find.text('Assistant'),
            ),
            findsNothing,
          );
          await tester.tap(find.text(value).last);
          await tester.pumpAndSettle();
          await _tap(tester, 'Save');
        }

        await openSettings();
        await _enter(tester, 'Name', 'Renamed fixture');
        await _tap(tester, 'Save');
        expect(
          host.writes(LinkMethods.saveGroup).single.containsKey('lead'),
          isFalse,
        );
        expect(host.group['lead'], 'b1');

        await openSettings();
        await chooseLead('Automatic');
        final clear = host.writes(LinkMethods.saveGroup).last;
        expect(clear.containsKey('lead'), isTrue);
        expect(clear['lead'], isNull);
        expect(host.group.containsKey('lead'), isFalse);

        await openSettings();
        await chooseLead('Fixture Bot');
        expect(host.writes(LinkMethods.saveGroup).last['lead'], 'b1');
        expect(host.group['lead'], 'b1');
        expect(host.writes(LinkMethods.openGroup), hasLength(1));
      } finally {
        await _finish(tester, [host]);
      }
    },
  );

  testWidgets('group editor sends only changed advertised optional fields', (
    tester,
  ) async {
    final host = _Host();
    host.group.addAll({'passes': 6, 'rules': 'Synthetic rules', 'gap': 15});
    await host.open();
    await _mount(tester, host.peer);
    await _tap(tester, 'Fixture Group');
    await _enter(tester, 'Rules', '');
    await _enter(tester, 'Reply delay (seconds)', '0');
    await _tap(tester, 'Save');
    expect(host.writes(LinkMethods.saveGroup).single, {
      'group': 'g1',
      'name': 'Fixture Group',
      'members': ['b1'],
      'rules': '',
      'gap': 0,
    });
    expect(host.group['passes'], 6);
    await _finish(tester, [host]);
  });

  testWidgets('group lead can be set with explicit support and no prior lead', (
    tester,
  ) async {
    final host = _Host()..groupOptions = ['lead'];
    await host.open();
    await _mountPage(tester, _PageConnection(host.peer), DesktopHostChats());
    try {
      await _tap(tester, 'Fixture Group');
      await tester.tap(find.byTooltip('Group settings'));
      await tester.pumpAndSettle();
      expect(find.text('Default lead'), findsOneWidget);
      expect(find.text('Automatic'), findsOneWidget);
      final picker = find.byKey(const ValueKey('remote-group-lead'));
      await tester.ensureVisible(picker);
      await tester.tap(picker);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fixture Bot').last);
      await tester.pumpAndSettle();
      await _tap(tester, 'Save');
      expect(host.writes(LinkMethods.saveGroup).single['lead'], 'b1');
      expect(host.group['lead'], 'b1');
    } finally {
      await _finish(tester, [host]);
    }
  });

  testWidgets('old memory reply cannot enable editing self notes', (
    tester,
  ) async {
    final host = _Host(legacy: true);
    await host.open();
    await _mount(tester, host.peer);
    await _tap(tester, 'Fixture Bot');
    await _tap(tester, 'Memory & self notes');
    expect(find.text('Self notes'), findsNothing);
    await _enter(tester, 'Memory', 'Fixture update');
    await _tap(tester, 'Save memory');
    expect(host.writes(LinkMethods.setBotMemory).single, {
      'bot': 'b1',
      'text': 'Fixture update',
    });
    expect(host.writes(LinkMethods.setBotSelf), isEmpty);
    await _finish(tester, [host]);
  });

  testWidgets(
    'clear chat and group deletion each require explicit confirmation',
    (tester) async {
      final host = _Host();
      await host.open();
      await _mount(tester, host.peer);
      await _tap(tester, 'Fixture Bot');
      await _tap(tester, 'Clear chat');
      expect(host.writes(LinkMethods.clearBotChat), isEmpty);
      await _tap(tester, 'Cancel');
      expect(host.writes(LinkMethods.clearBotChat), isEmpty);
      await _tap(tester, 'Clear chat');
      await _tap(tester, 'Confirm');
      expect(host.writes(LinkMethods.clearBotChat).single, {'bot': 'b1'});
      await _tap(tester, 'Fixture Group');
      await _tap(tester, 'Delete group');
      expect(host.writes(LinkMethods.deleteGroup), isEmpty);
      await _tap(tester, 'Confirm');
      expect(host.writes(LinkMethods.deleteGroup).single, {'group': 'g1'});
      expect(find.text('Fixture Group'), findsNothing);
      await _finish(tester, [host]);
    },
  );

  testWidgets(
    'write-only host profile requires confirmation before replacing fields and picture',
    (tester) async {
      final host = _Host();
      await host.open();
      await _mount(tester, host.peer);
      await _tap(tester, 'My host profile');
      await _enter(tester, 'Name', 'Fixture Profile');
      await _tap(tester, 'Review replacement');
      expect(host.profile, isNull);
      expect(
        find.textContaining('remove the existing picture'),
        findsOneWidget,
      );
      await _tap(tester, 'Confirm');
      expect(host.profile, {
        'name': 'Fixture Profile',
        'gender': '',
        'signature': '',
      });
      await _finish(tester, [host]);
    },
  );

  testWidgets(
    'a late catalog from a previous peer cannot replace the new host',
    (tester) async {
      final first = _Host()..gatedState = Completer<Object?>();
      final second = _Host();
      second.bots['b1']!['name'] = 'Second host Bot';
      await first.open();
      await second.open(host: 'other-fixture-host');
      await _mount(tester, first.peer);
      await _mount(tester, second.peer);
      first.gatedState!.complete(first.catalog);
      await tester.pumpAndSettle();
      expect(find.text('Second host Bot'), findsOneWidget);
      expect(find.text('Fixture Bot'), findsNothing);
      expect(first.writes(LinkMethods.saveBot), isEmpty);
      await _finish(tester, [first, second]);
    },
  );

  testWidgets('a new avatar replaces the old picture after confirmation', (
    tester,
  ) async {
    final host = _Host()..pictures['b1'] = {'data': _png, 'type': 'image/png'};
    await host.open();
    await _mount(
      tester,
      host.peer,
      pickImage: () async =>
          ImageAttachment(bytes: base64Decode(_png), mediaType: 'image/png'),
    );
    await _tap(tester, 'Fixture Bot');
    await _tap(tester, 'Choose picture');
    await _tap(tester, 'Save');
    expect(host.writes(LinkMethods.saveBot), isEmpty);
    await _tap(tester, 'Confirm');
    expect(host.writes(LinkMethods.saveBot).single['avatarImage'], {
      'data': _png,
      'type': 'image/png',
    });
    expect(host.writes(LinkMethods.botAvatar), [
      {'bot': 'b1'},
      {'bot': 'b1'},
    ]);
    await _finish(tester, [host]);
  });

  testWidgets('creates a group with the selected advertised Bot ID', (
    tester,
  ) async {
    final host = _Host();
    host.group.clear();
    await host.open();
    await _mount(tester, host.peer);
    await _tap(tester, 'New group');
    await _enter(tester, 'Name', 'Created Group');
    await _tap(tester, 'Fixture Bot');
    await _tap(tester, 'Save');
    expect(host.writes(LinkMethods.saveGroup).single, {
      'name': 'Created Group',
      'members': ['b1'],
    });
    expect(find.text('Created Group'), findsOneWidget);
    await _finish(tester, [host]);
  });

  testWidgets('clearing self notes is confirmed separately from memory', (
    tester,
  ) async {
    final host = _Host();
    await host.open();
    await _mount(tester, host.peer);
    await _tap(tester, 'Fixture Bot');
    await _tap(tester, 'Memory & self notes');
    await _enter(tester, 'Self notes', '');
    await _tap(tester, 'Save self notes');
    expect(host.writes(LinkMethods.setBotSelf), isEmpty);
    await _tap(tester, 'Confirm');
    expect(host.writes(LinkMethods.setBotSelf).single, {
      'bot': 'b1',
      'text': '',
    });
    expect(host.writes(LinkMethods.setBotMemory), isEmpty);
    expect(host.memory, 'Initial memory');
    await _finish(tester, [host]);
  });

  testWidgets(
    'protects the assistant and forwards the catalog after deleting another Bot',
    (tester) async {
      final host = _Host();
      await host.open();
      final catalogs = <Map<String, Object?>>[];
      await _mount(
        tester,
        host.peer,
        onCatalog: (peer, state) => catalogs.add(state),
      );
      await _tap(tester, 'Assistant');
      expect(find.text('Delete Bot'), findsNothing);
      await _tap(tester, 'Back');
      await _tap(tester, 'Fixture Bot');
      await _tap(tester, 'Delete Bot');
      expect(host.writes(LinkMethods.deleteBot), isEmpty);
      await _tap(tester, 'Confirm');
      expect(host.writes(LinkMethods.deleteBot).single, {'bot': 'b1'});
      expect((catalogs.last['bots'] as List).single['id'], 'assistant');
      await _finish(tester, [host]);
    },
  );

  testWidgets('an unknown clear-chat RPC leaves the conversation intact', (
    tester,
  ) async {
    final host = _Host()..unavailable.add(LinkMethods.clearBotChat);
    await host.open();
    await _mount(tester, host.peer);
    await _tap(tester, 'Fixture Bot');
    await _tap(tester, 'Clear chat');
    await _tap(tester, 'Confirm');
    expect(host.writes(LinkMethods.clearBotChat), hasLength(1));
    expect(
      find.text('This host does not provide this setting.'),
      findsOneWidget,
    );
    expect(host.session, 'prior-chat');
    await _finish(tester, [host]);
  });

  testWidgets('the manager uses Chinese strings in a Chinese workspace', (
    tester,
  ) async {
    final host = _Host();
    await host.open();
    await _mount(tester, host.peer, locale: const Locale('zh'));
    await tester.pumpAndSettle();
    expect(find.text('机器人、群聊和资料'), findsOneWidget);
    expect(find.text('新建机器人'), findsOneWidget);
    await _finish(tester, [host]);
  });

  testWidgets(
    'real host bridge keeps an untouched picture, policy and newer flags',
    (tester) async {
      final workspace = Workspace();
      // The store is memory-only and never started; it cannot create Bot chats.
      final bots = Bots(workspace: workspace, folders: MemoryBotFolders());
      final seed = bots.save(
        name: 'Bridge Bot',
        identity: 'Synthetic identity',
        abilities: {BotAbility.proactive},
        proactive: _bot.proactive,
        chatOnly: true,
        writesFirst: false,
        avatarImage: (bytes: base64Decode(_png), type: 'image/png'),
      );
      final (local, remote) = MemoryLinkConnection.pair();
      final accepting = LinkPeer.accept(remote);
      final peer = await LinkPeer.connect(local);
      final server = await accepting;
      final bridge = WorkspaceBridge(
        workspace: workspace,
        peer: server,
        device: () =>
            const DeviceInfo(name: 'Fixture', kind: 'mac', system: ''),
        bots: bots,
      )..start();
      server.onRequest = bridge.handle;
      try {
        await _mount(tester, peer);
        await _tap(tester, 'Bridge Bot');
        await _enter(tester, 'Name', 'Renamed through bridge');
        await _tap(tester, 'Save');
        final saved = bots.byId(seed.id)!;
        expect(saved.name, 'Renamed through bridge');
        expect(saved.avatar, seed.avatar);
        expect(bots.avatarImage(saved)!.bytes, base64Decode(_png));
        expect(saved.identity, seed.identity);
        expect(saved.abilities, seed.abilities);
        expect(saved.proactive, seed.proactive);
        expect(saved.chatOnly, isTrue);
        expect(saved.writesFirst, isFalse);
        expect(workspace.threads, isEmpty);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        bridge.dispose();
        await peer.close();
        await server.close();
        bots.dispose();
        workspace.dispose();
      }
    },
  );
}
