import 'dart:async';

import 'package:bao_link/bao_link.dart';
import 'package:bao_remote/claude.dart' show ClaudeHistoryPage;
import 'package:baocode/bots/bot_folders.dart';
import 'package:baocode/bots/bots.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/link/desktop_host_chats.dart';
import 'package:baocode/link/workspace_bridge.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/material.dart' show Icons;
import 'package:flutter_test/flutter_test.dart';

import '../kernel_test.dart' show FakeCli;

const _device = DeviceInfo(name: 'Host', kind: 'mac', system: 'macOS');
const _project = ProjectInfo(
  id: '/host/project',
  name: 'Project',
  path: '/host/project',
);
final _session = SessionSummary(
  id: 'kept',
  project: _project.id,
  title: 'Kept session',
  updatedAt: DateTime(2026),
);

Map<String, Object?> _state({
  List<LinkBot> bots = const [],
  List<LinkGroup> groups = const [],
}) => LinkState(
  device: _device,
  projects: const [_project],
  sessions: [_session],
  bots: bots,
  groups: groups,
).toJson();

Map<String, Object?> _user(String text) => {'t': 'user', 'text': text};
Map<String, Object?> _reply(String text) => {'t': 'text', 'text': text};

LinkSessionUpdate _update(
  String id,
  List<Object?> items, {
  int start = 0,
  bool? earlier,
}) => LinkSessionUpdate(
  session: id,
  start: start,
  count: start + items.length,
  items: items,
  earlier: earlier,
);

Future<(LinkPeer, LinkPeer)> _peers(
  LinkRequestHandler handler, {
  String remote = 'host-key',
  String local = 'client-key',
  bool mirror = true,
}) async {
  final (a, b) = MemoryLinkConnection.pair(a: local, b: remote);
  final accepting = LinkPeer.accept(b, onRequest: handler);
  final client = await LinkPeer.connect(
    a,
    mirror: mirror ? LinkSessionMirror() : null,
  );
  final host = await accepting;
  addTearDown(client.close);
  addTearDown(host.close);
  return (client, host);
}

List<String> _texts(DesktopHostChats chats) => [
  for (final m in chats.messages) m.text,
];

void main() {
  test(
    'real bridge shares project, private and group chats with two clients',
    () async {
      late final KernelDescriptor descriptor;
      descriptor = KernelDescriptor(
        id: 'claude-code',
        label: 'Synthetic Claude',
        icon: Icons.chat,
        description: '',
        catalog: _Catalog(),
        create: (context) => ClaudeCodeKernel(
          descriptor,
          context,
          start: (_) async => FakeCli(),
          readHistoryPage: (session, {required turns, before}) async =>
              switch ((session.id, before)) {
                ('private-kept', null) => ClaudeHistoryPage([
                  _historyReply(
                    'group-reply',
                    '<bot_say>group reply from the session</bot_say>',
                  ),
                  _historyUser(
                    'system',
                    '<bao-event>internal host note</bao-event>',
                  ),
                  _historyReply(
                    'system-reply',
                    '<bot_say>internal answer</bot_say>',
                  ),
                  _historyUser('private-prompt', 'private prompt'),
                  _historyReply(
                    'private-reply',
                    'scratch<bot_say>private reply</bot_say><bot_narrate>private narration</bot_narrate>',
                  ),
                ], earlier: 'group-reply'),
                ('private-kept', 'group-reply') => ClaudeHistoryPage([
                  _historyUser('older-private', 'older private prompt'),
                  _historyReply(
                    'older-reply',
                    '<bot_say>older private reply</bot_say>',
                  ),
                  _historyUser(
                    'group-prompt',
                    '<bao-event>[group room] hidden group prompt</bao-event>',
                  ),
                ]),
                _ => ClaudeHistoryPage([
                  _historyUser('project-prompt', 'saved project prompt'),
                ]),
              },
        ),
      );
      final workspace = Workspace(kernels: [descriptor]);
      addTearDown(workspace.dispose);
      final bots = Bots(workspace: workspace, folders: MemoryBotFolders());
      addTearDown(bots.dispose);
      await Future.wait([workspace.load(), bots.start()]);
      bots.groups.tell = (_, _, _) {};
      final bot = bots.bots.single;
      final room = bots.groups.save(name: 'Room', members: [bot.id]);
      for (var i = 0; i < 51; i++) {
        bots.groups.say(room.id, bot.id, 'room history $i');
      }

      Future<LinkPeer> connect(String id) async {
        late final WorkspaceBridge bridge;
        final (client, host) = await _peers(
          (method, params) => bridge.handle(method, params),
          local: id,
        );
        bridge = WorkspaceBridge(
          workspace: workspace,
          peer: host,
          device: () => _device,
          bots: bots,
          throttle: Duration.zero,
        )..start();
        addTearDown(bridge.dispose);
        return client;
      }

      final desktop = DesktopHostChats();
      addTearDown(desktop.dispose);
      desktop.bind(await connect('desktop'));
      final otherClient = await connect('other-client');
      await pumpEventQueue();
      final projectChat = desktop.chats.singleWhere(
        (chat) => chat.kind == 'project' && chat.id == _session.id,
      );
      expect(
        desktop.chats.map((chat) => chat.id),
        isNot(contains('private-kept')),
      );
      final initialThreadCount = workspace.threads.length;
      await desktop.open(projectChat);
      await pumpEventQueue();
      expect(_texts(desktop), ['saved project prompt']);
      await otherClient.call(LinkMethods.open, {'session': projectChat.id});
      final projectEvent = _eventContaining(
        otherClient,
        LinkEvents.session,
        'desktop project prompt',
      );
      await desktop.send('desktop project prompt');
      await projectEvent;
      await pumpEventQueue();
      expect(_texts(desktop), contains('desktop project prompt'));

      await desktop.open(
        desktop.chats.singleWhere((chat) => chat.kind == 'bot'),
      );
      await pumpEventQueue();
      expect(_texts(desktop), ['private prompt', 'private reply']);
      await desktop.earlier();
      expect(_texts(desktop), [
        'older private prompt',
        'older private reply',
        'private prompt',
        'private reply',
      ]);
      expect(WorkspaceBridge.idOf(bots.threadOf(bot)!), 'private-kept');
      await otherClient.call(LinkMethods.send, {
        'bot': bot.id,
        'text': 'other client private prompt',
      });
      await pumpEventQueue();
      expect(_texts(desktop), contains('other client private prompt'));
      expect(workspace.threads, hasLength(initialThreadCount));

      await desktop.open(
        desktop.chats.singleWhere((chat) => chat.kind == 'group'),
      );
      expect(_texts(desktop), [for (var i = 1; i < 51; i++) 'room history $i']);
      expect(desktop.hasEarlier, isTrue);
      await desktop.earlier();
      expect(desktop.hasEarlier, isFalse);
      await otherClient.call(LinkMethods.openGroup, {'group': room.id});
      final groupEvent = _eventContaining(
        otherClient,
        LinkEvents.group,
        'desktop group prompt',
      );
      await desktop.send('desktop group prompt');
      await groupEvent;
      await otherClient.call(LinkMethods.sendGroup, {
        'group': room.id,
        'text': 'other client group prompt',
      });
      await pumpEventQueue();
      expect(_texts(desktop), [
        for (var i = 0; i < 51; i++) 'room history $i',
        'desktop group prompt',
        'other client group prompt',
      ]);
      expect(desktop.messages.last.mine, isTrue);
    },
  );

  test(
    'lost acknowledgment stays uncertain across reconnect without replay',
    () async {
      final received = Completer<void>();
      final reply = Completer<Object?>();
      final history = <Object?>[_user('saved prompt')];
      final sends = <Map<String, Object?>>[];
      final chats = DesktopHostChats();
      addTearDown(chats.dispose);
      Object? handler(String method, Map<String, Object?> params) {
        switch (method) {
          case LinkMethods.state:
            return _state();
          case LinkMethods.open:
            return _update('kept', history).toJson();
          case LinkMethods.send:
            sends.add(params);
            history.add(_user(params['text']! as String));
            received.complete();
            return reply.future;
          default:
            return null;
        }
      }

      final (first, host) = await _peers(handler);
      chats.bind(first);
      await pumpEventQueue();
      await chats.open(chats.chats.single);
      final sending = chats.send('  once  ');
      await received.future;
      await chats.send('duplicate');
      expect(chats.busy, isTrue);
      expect(_texts(chats), ['saved prompt']);
      expect(sends.single['id'], isA<String>());
      await host.close();
      await sending;
      reply.complete({'session': 'kept'});
      expect(chats.error, contains('did not confirm'));
      final (second, _) = await _peers(handler);
      chats.bind(second);
      await pumpEventQueue();
      expect(chats.selected?.id, 'kept');
      expect(_texts(chats), ['saved prompt', 'once']);
      expect(chats.error, contains('did not confirm'));
      expect(sends, hasLength(1));
      chats.reset();
      expect(chats.selected, isNull);
      expect(chats.chats, isEmpty);
      expect(chats.messages, isEmpty);
      expect(chats.error, isNull);
      chats.bind(second);
      await pumpEventQueue();
      await chats.open(chats.chats.single);
      final (other, _) = await _peers(handler, remote: 'other-host');
      chats.bind(other);
      await pumpEventQueue();
      expect(chats.selected, isNull);
      expect(chats.messages, isEmpty);
    },
  );

  test(
    'withholds ambiguous bot turns and offers a read-only attachment fallback',
    () async {
      const bot = LinkBot(id: 'bot', name: 'Mia', session: 'private');
      const privateDelivery = {
        't': 'tool',
        'tool': 'bot_send',
        'status': 'succeeded',
        'sent': 'explicit private delivery',
        'output': 'internal tool output',
      };
      final sent = <Object?>[];
      final (client, host) = await _peers(
        (method, params) => switch (method) {
          LinkMethods.state => _state(bots: [bot]),
          LinkMethods.send => () {
            sent.add(params['text']);
            return null;
          }(),
          LinkMethods.open => LinkSessionUpdate(
            session: 'private',
            start: 0,
            count: 11,
            earlier: false,
            interaction: {
              'id': 'approval',
              'command': 'internal approval payload',
            },
            items: [
              _reply('<bot_say>unattributed reply</bot_say>'),
              _user('<bao-event>[group room] hidden group prompt</bao-event>'),
              {..._user('queued in private'), 'queued': true},
              _reply('<bot_say>still a group reply</bot_say>'),
              privateDelivery,
              _user(
                '<bao-event>[group room] merged group prompt</bao-event>\nprivate words',
              ),
              _reply('<bot_say>ambiguous group reply</bot_say>'),
              _user(
                'private question <system-reminder>internal</system-reminder>',
              ),
              {'t': 'thinking', 'text': 'internal reasoning'},
              {
                ..._user('[Image #1]'),
                'images': [
                  {'data': 'redacted'},
                ],
              },
              _reply('<bot_say>private answer</bot_say>'),
            ],
          ).toJson(),
          LinkMethods.close => null,
          _ => throw StateError('Unexpected $method'),
        },
      );
      final chats = DesktopHostChats();
      addTearDown(chats.dispose);
      chats.bind(client);
      await pumpEventQueue();
      await chats.open(chats.chats.singleWhere((chat) => chat.kind == 'bot'));
      expect(_texts(chats), [
        'queued in private',
        'explicit private delivery',
        'private words',
        'private question',
        '[Attachment]',
        'private answer',
      ]);
      expect(chats.error, contains('Continue on the host'));
      await chats.send('blocked until answered');
      expect(chats.error, contains('Continue on the host'));
      expect(sent, isEmpty);
      host.emit(
        LinkEvents.session,
        _update('private', [_user('next turn')]).toJson(),
      );
      await pumpEventQueue();
      expect(chats.error, isNull);
    },
  );

  test('first bot send follows the confirmed session without waiting for a catalog event', () async {
    final methods = <String>[];
    final (client, _) = await _peers((method, params) {
      methods.add(method);
      switch (method) {
        case LinkMethods.state:
          return _state(
            bots: const [LinkBot(id: 'bot', name: 'Mia')],
          );
        case LinkMethods.send:
          expect(params, containsPair('bot', 'bot'));
          expect(params.containsKey('session'), isFalse);
          return {'session': 'first-session'};
        case LinkMethods.open:
          expect(params, containsPair('session', 'first-session'));
          return _update('first-session', [_user('hello')]).toJson();
        default:
          return null;
      }
    });
    final chats = DesktopHostChats();
    addTearDown(chats.dispose);
    chats.bind(client);
    await pumpEventQueue();
    await chats.open(chats.chats.singleWhere((chat) => chat.kind == 'bot'));
    expect(methods, [LinkMethods.state]);
    await chats.send('hello');
    expect(methods, [LinkMethods.state, LinkMethods.send, LinkMethods.open]);
    expect(_texts(chats), ['hello']);
    expect(chats.error, isNull);
  });

  test(
    'reset ignores the prior catalog request even if the same peer is rebound',
    () async {
      final first = Completer<Object?>();
      final requested = Completer<void>();
      final (client, _) = await _peers((method, _) {
        if (method != LinkMethods.state) throw StateError('Unexpected $method');
        if (requested.isCompleted) {
          return _state(
            bots: const [LinkBot(id: 'new', name: 'New bot')],
          );
        }
        requested.complete();
        return first.future;
      });
      final chats = DesktopHostChats();
      addTearDown(chats.dispose);
      chats.bind(client);
      await requested.future;
      chats.reset();
      chats.bind(client);
      await pumpEventQueue();
      first.complete(
        _state(
          bots: const [LinkBot(id: 'stale', name: 'Stale bot')],
        ),
      );
      await pumpEventQueue();
      expect(chats.chats.map((chat) => chat.id), [_session.id, 'new']);
    },
  );

  for (final mirror in [true, false]) {
    test(
      'follows a cold project session and paginates live deltas (mirror: $mirror)',
      () async {
        final history = Completer<Object?>();
        final requests = <(String, Map<String, Object?>)>[];
        final slimmer = LinkSessionSlimmer();
        final last = _reply('partial');
        final (client, host) = await _peers((method, params) {
          requests.add((method, params));
          return switch (method) {
            LinkMethods.state => _state(),
            LinkMethods.open => history.future,
            LinkMethods.earlier => {
              'items': [_user('older')],
              'earlier': false,
            },
            LinkMethods.close => null,
            _ => throw StateError('Unexpected $method'),
          };
        }, mirror: mirror);
        final chats = DesktopHostChats();
        addTearDown(chats.dispose);
        chats.bind(client);
        await pumpEventQueue();
        final chat = chats.chats.single;
        expect(
          (chat.kind, chat.id, chat.title),
          ('project', 'kept', 'Kept session'),
        );
        final opening = chats.open(chat);
        expect(chats.busy, isTrue);
        await chats.send('must not send while opening');
        history.complete(
          slimmer.encode(
            _update('kept', [_user('recent'), last], earlier: true),
            full: true,
          ),
        );
        await opening;
        expect(chats.busy, isFalse);
        expect(_texts(chats), ['recent', 'partial']);
        expect(chats.messages.map((m) => m.mine), [true, false]);
        host.emit(
          LinkEvents.session,
          slimmer.encode(
            _update('kept', [_reply('partial reply')], start: 1, earlier: true),
            before: last,
          ),
        );
        await chats.earlier();
        expect(_texts(chats), ['older', 'recent', 'partial reply']);
        expect(chats.hasEarlier, isFalse);
        host.emit(
          LinkEvents.session,
          slimmer.encode(
            _update(
              'kept',
              [_user('another client')],
              start: 3,
              earlier: false,
            ),
          ),
        );
        await pumpEventQueue();
        expect(_texts(chats), [
          'older',
          'recent',
          'partial reply',
          'another client',
        ]);
        chats.closeChat();
        await pumpEventQueue();
        expect(chats.selected, isNull);
        expect(chats.messages, isEmpty);
        expect(requests.map((call) => call.$1), [
          LinkMethods.state,
          LinkMethods.open,
          LinkMethods.earlier,
          LinkMethods.close,
        ]);
        expect(requests[1].$2, containsPair('session', 'kept'));
        expect(requests[1].$2['window'], isA<int>());
      },
    );
  }
}

Future<LinkEvent> _eventContaining(LinkPeer peer, String name, String text) =>
    peer.events
        .firstWhere(
          (event) => event.name == name && event.data.toString().contains(text),
        )
        .timeout(const Duration(seconds: 3));

Map<String, Object?> _historyUser(String id, String text) => {
  'type': 'user',
  'uuid': id,
  'message': {'role': 'user', 'content': text},
};

Map<String, Object?> _historyReply(String id, String text) => {
  'type': 'assistant',
  'uuid': id,
  'message': {
    'id': 'message-$id',
    'role': 'assistant',
    'model': 'synthetic',
    'content': [
      {'type': 'text', 'text': text},
    ],
  },
};

class _Catalog implements SessionCatalog {
  @override
  Future<List<ProjectRecord>> projects() async => [
    for (final (path, id) in [
      (_project.id, _session.id),
      ('/bots/assistant', 'private-kept'),
    ])
      ProjectRecord(
        path: path,
        sessions: [
          SessionRecord(
            id: id,
            title: id,
            updatedAt: DateTime(2026),
            cwd: path,
          ),
        ],
      ),
  ];

  @override
  Future<List<SessionRecord>> sessionsIn(String cwd) async => const [];

  @override
  Future<void> delete(String id) async {}
}
