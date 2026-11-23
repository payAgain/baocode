import 'dart:async';

import 'package:bao_link/bao_link.dart';
import 'package:baocode/link/desktop_host_chats.dart';
import 'package:baocode/link/desktop_remote_session_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('permission approval is specific and waits for the host push', (
    tester,
  ) async {
    final host = await _Host.show(tester);
    await host.select(tester, 'first');
    host.update('first', interaction: _approval('request-1'));
    await tester.pumpAndSettle();
    await _tap(tester, 'Review host request');
    expect(find.text('fixture command'), findsOneWidget);
    expect(find.text('Fixture blanket approval'), findsNothing);
    expect(host.actions, isEmpty);
    await _tap(tester, 'Cancel');
    expect(host.actions, isEmpty);
    await _tap(tester, 'Review host request');
    await _tap(tester, 'Allow once');
    expect(host.actions.single.$1, LinkMethods.answer);
    expect(host.actions.single.$2, {
      'session': 'first',
      'request': 'request-1',
      'answer': {'t': 'approval', 'decision': 'allowOnce'},
    });
    final button = tester.widget<TextButton>(
      find.widgetWithText(TextButton, 'Review host request'),
    );
    expect(button.onPressed, isNull);
    host.update('first');
    await tester.pumpAndSettle();
    expect(find.text('Review host request'), findsNothing);
    await host.close(tester);
  });

  testWidgets('start plan requires confirmation and waits for host state', (
    tester,
  ) async {
    final host = await _Host.show(tester);
    await host.select(tester, 'first');
    const plan = {
      't': 'plan',
      'path': '/fixture/plan',
      'status': 'awaiting',
      'title': 'Fixture plan',
    };
    host.update('first', items: [plan], live: true);
    await tester.pumpAndSettle();
    expect(find.text('Start host plan'), findsNothing);
    host.update(
      'first',
      items: [
        {'t': 'user', 'text': 'Earlier prompt'},
        plan,
      ],
    );
    await tester.pumpAndSettle();
    expect(find.text('Start host plan'), findsNothing);
    expect(find.text('Edit old message'), findsNothing);
    host.update('first', items: [plan], sessionActions: {'startPlan': true});
    await tester.pumpAndSettle();
    await _tap(tester, 'Start host plan');
    expect(find.text('Fixture plan'), findsOneWidget);
    expect(host.actions, isEmpty);
    await _tap(tester, 'Start plan');
    expect(host.actions.single.$1, LinkMethods.startPlan);
    expect(host.actions.single.$2['session'], 'first');
    await tester.tap(find.text('Start host plan'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(host.actions, hasLength(1));
    host.update(
      'first',
      items: [
        plan,
        {'t': 'user', 'text': 'Fixture started'},
      ],
    );
    await tester.pumpAndSettle();
    expect(find.text('Start host plan'), findsNothing);
    await host.close(tester);
  });

  testWidgets('quota reads values only from host updates', (tester) async {
    final host = await _Host.show(tester);
    await host.select(tester, 'first');
    expect(find.text('Refresh host quota'), findsNothing);
    Map<String, Object?> quota(int left) => {
      'provider': 'Fixture provider',
      'accounts': [
        {
          'windows': [
            {'name': 'Fixture window', 'left': left},
          ],
        },
      ],
    };
    host.update('first', quota: quota(30));
    await tester.pumpAndSettle();
    await _tap(tester, 'Refresh host quota');
    expect(host.actions.single.$1, LinkMethods.quota);
    expect(host.actions.single.$2, {'session': 'first'});
    expect(find.textContaining('30%'), findsOneWidget);
    host.update('first', quota: quota(65));
    await tester.pumpAndSettle();
    expect(find.textContaining('65%'), findsOneWidget);
    await host.close(tester);
  });

  testWidgets('edit reviews the host rewind plan at the paged wire index', (
    tester,
  ) async {
    final host = await _Host.show(tester);
    await host.select(tester, 'first');
    host.update(
      'first',
      items: [
        {'t': 'text', 'text': 'Fixture reply'},
        {'t': 'user', 'text': 'Newer prompt'},
        {'t': 'user', 'text': 'Hidden queued prompt', 'queued': true},
      ],
      earlier: true,
      sessionActions: {'edit': true},
    );
    await tester.pumpAndSettle();
    host.earlierItems = [
      {'t': 'text', 'text': 'Already present reply'},
      {'t': 'user', 'text': 'Older prompt'},
    ];
    await host.chats.earlier();
    await tester.pumpAndSettle();
    host.reply = (method, _) => method == LinkMethods.rewindPlan
        ? {
            'files': [
              {'name': 'fixture.txt', 'outcome': 'restore'},
              {'name': 'changed.txt', 'outcome': 'conflict'},
            ],
            'setting': 'revert',
          }
        : null;
    await _tap(tester, 'Edit old message');
    expect(find.text('Hidden queued prompt'), findsNothing);
    await _tap(tester, 'Older prompt');
    await tester.enterText(find.byType(TextField), 'Revised prompt');
    await _tap(tester, 'Review edit');
    expect(host.actions.single.$1, LinkMethods.rewindPlan);
    expect(host.actions.single.$2['index'], 1);
    expect(find.textContaining('fixture.txt'), findsOneWidget);
    expect(find.textContaining('changed.txt'), findsOneWidget);
    await _tap(tester, 'Keep files and resend');
    expect(host.actions.last.$1, LinkMethods.edit);
    expect(host.actions.last.$2, containsPair('session', 'first'));
    expect(host.actions.last.$2, containsPair('index', 1));
    expect(host.actions.last.$2, containsPair('text', 'Revised prompt'));
    expect(host.actions.last.$2, containsPair('revertFiles', false));
    await host.close(tester);
  });

  testWidgets('a late rewind preview cannot submit after switching chats', (
    tester,
  ) async {
    final host = await _Host.show(tester);
    await host.select(tester, 'first');
    host.update(
      'first',
      items: [
        {'t': 'user', 'text': 'Fixture original'},
      ],
      sessionActions: {'edit': true},
    );
    await tester.pumpAndSettle();
    final response = Completer<Object?>();
    host.reply = (method, _) => response.future;
    await _tap(tester, 'Edit old message');
    await _tap(tester, 'Fixture original');
    await _tap(tester, 'Review edit');
    expect(host.actions.single.$1, LinkMethods.rewindPlan);
    await host.select(tester, 'second');
    response.complete({
      'files': [
        {'name': 'stale.txt', 'outcome': 'restore'},
      ],
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('stale.txt'), findsNothing);
    expect(find.text('Keep files and resend'), findsNothing);
    expect(host.actions, hasLength(1));
    await host.close(tester);
  });

  testWidgets(
    'delivery choices are usually hidden and route a supported active turn',
    (tester) async {
      final host = await _Host.show(tester);
      await host.select(tester, 'first');
      host.update('first', live: true);
      await tester.pumpAndSettle();
      expect(find.text('Queue message'), findsNothing);
      expect(find.text('Send now'), findsNothing);
      host.update(
        'first',
        live: true,
        sessionActions: const {'queue': true, 'turn': 123},
      );
      host.reply = (_, params) => {'session': params['session']};
      await tester.pumpAndSettle();
      await _tap(tester, 'Queue message');
      await tester.enterText(find.byType(TextField), 'Queue fixture');
      await tester.pump();
      await _tap(tester, 'Add to queue');
      expect(host.actions.single.$1, LinkMethods.send);
      expect(host.actions.single.$2, containsPair('now', false));
      expect(host.actions.single.$2, containsPair('session', 'first'));
      expect(host.actions.single.$2, containsPair('text', 'Queue fixture'));
      expect(find.text('Host accepted the queued message.'), findsOneWidget);
      await _tap(tester, 'Send now');
      await tester.enterText(find.byType(TextField), 'Immediate fixture');
      await tester.pump();
      await _tap(tester, 'Review interrupt');
      expect(host.actions, hasLength(1));
      await _tap(tester, 'Interrupt and send');
      expect(host.actions.last.$2, containsPair('now', true));
      expect(host.actions.last.$2, containsPair('expectedTurn', 123));
      expect(host.actions.last.$2, containsPair('text', 'Immediate fixture'));
      expect(host.actions.last.$2['id'], isNot(host.actions.first.$2['id']));
      await host.close(tester);
    },
  );

  testWidgets(
    'host questions answer in order and never route to bot or group',
    (tester) async {
      final host = await _Host.show(tester);
      await host.select(tester, 'first');
      host.update(
        'first',
        interaction: {
          't': 'question',
          'id': 'question-fixture',
          'title': 'Fixture questions',
          'questions': [
            {
              'prompt': 'Which fixtures?',
              'multiple': true,
              'options': [
                {'label': 'Fixture A'},
                {'label': 'Fixture B'},
              ],
            },
          ],
        },
      );
      await tester.pumpAndSettle();
      await _tap(tester, 'Review host request');
      await _tap(tester, 'Fixture A');
      await _tap(tester, 'Fixture B');
      await _tap(tester, 'Submit');
      expect(host.actions.single.$1, LinkMethods.answer);
      expect(host.actions.single.$2, {
        'session': 'first',
        'request': 'question-fixture',
        'answer': {
          't': 'question',
          'picks': [
            ['Fixture A', 'Fixture B'],
          ],
        },
      });
      await host.select(tester, 'private', kind: 'bot');
      host.update('bot-session', interaction: _approval('group-request'));
      await tester.pumpAndSettle();
      expect(find.text('Review host request'), findsNothing);
      await host.select(tester, 'first', kind: 'group');
      host.update('first', interaction: _approval('same-id-project-request'));
      await tester.pumpAndSettle();
      expect(find.text('Review host request'), findsNothing);
      expect(host.actions, hasLength(1));
      await host.close(tester);
    },
  );

  testWidgets('a replacement permission invalidates the still-painted button', (
    tester,
  ) async {
    final host = await _Host.show(tester);
    await host.select(tester, 'first');
    host.update('first', interaction: _approval('original'));
    await tester.pumpAndSettle();
    await _tap(tester, 'Review host request');
    host.update('first', interaction: _approval('replacement'));
    await tester.idle();
    await tester.tap(find.text('Allow once'));
    await tester.pumpAndSettle();
    expect(host.actions, isEmpty);
    await _tap(tester, 'Review host request');
    await _tap(tester, 'Deny');
    expect(host.actions.single.$2, containsPair('request', 'replacement'));
    expect(host.actions.single.$2['answer'], containsPair('decision', 'deny'));
    await host.close(tester);
  });
}

Map<String, Object?> _approval(String id) => {
  't': 'approval',
  'id': id,
  'title': 'Fixture permission',
  'tool': 'Fixture tool',
  'reason': 'Fixture reason',
  'always': 'Fixture blanket approval',
  'preview': {'t': 'command', 'command': 'fixture command'},
};

Future<void> _tap(WidgetTester tester, String label) async {
  await tester.tap(find.text(label).hitTestable());
  await tester.pumpAndSettle();
}

class _Host {
  final chats = DesktopHostChats();
  late final LinkPeer peer;
  late final LinkPeer _host;
  final _slimmers = <String, LinkSessionSlimmer>{};
  final actions = <(String, Map<String, Object?>)>[];
  LinkRequestHandler? reply;
  List<Object?> earlierItems = const [];

  static Future<_Host> show(WidgetTester tester) async {
    final fixture = _Host();
    final (a, b) = MemoryLinkConnection.pair(a: 'client', b: 'host');
    final accepting = LinkPeer.accept(b, onRequest: fixture._handle);
    fixture.peer = await LinkPeer.connect(a, mirror: LinkSessionMirror());
    fixture._host = await accepting;
    fixture.chats.bind(fixture.peer);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: fixture.chats,
            builder: (context, _) {
              final chat = fixture.chats.selected;
              return chat == null
                  ? const SizedBox()
                  : DesktopRemoteSessionActions(
                      peer: fixture.peer,
                      chat: chat,
                      chats: fixture.chats,
                    );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return fixture;
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    chats.dispose();
    await peer.close();
    await _host.close();
    await tester.pump();
  }

  Future<void> select(
    WidgetTester tester,
    String id, {
    String kind = 'project',
  }) async {
    await chats.open(
      chats.chats.singleWhere((chat) => chat.id == id && chat.kind == kind),
    );
    await tester.pumpAndSettle();
  }

  void update(
    String id, {
    Map<String, Object?>? interaction,
    Map<String, Object?>? quota,
    List<Object?> items = const [],
    bool live = false,
    bool earlier = false,
    Map<String, Object?>? sessionActions,
  }) {
    _host.emit(
      LinkEvents.session,
      _slimmers[id]!.encode(
        LinkSessionUpdate(
          session: id,
          start: 0,
          count: items.length,
          items: items,
          interaction: interaction,
          quota: quota,
          live: live,
          earlier: earlier,
          actions: sessionActions,
        ),
      ),
    );
  }

  FutureOr<Object?> _handle(String method, Map<String, Object?> params) {
    switch (method) {
      case LinkMethods.state:
        return LinkState(
          device: const DeviceInfo(
            name: 'Fixture',
            kind: 'desktop',
            system: 'windows',
          ),
          projects: const [
            ProjectInfo(
              id: '/fixture',
              name: 'Fixture project',
              path: '/fixture',
            ),
          ],
          sessions: [
            for (final id in ['first', 'second', 'bot-session'])
              SessionSummary(
                id: id,
                project: '/fixture',
                title: id,
                updatedAt: DateTime(2026),
              ),
          ],
          bots: const [
            LinkBot(id: 'private', name: 'Fixture bot', session: 'bot-session'),
          ],
          groups: const [LinkGroup(id: 'first', name: 'Fixture group')],
        ).toJson();
      case LinkMethods.open:
        final id = params['session']! as String;
        return (_slimmers[id] = LinkSessionSlimmer()).encode(
          LinkSessionUpdate(session: id, start: 0, count: 0, items: const []),
          full: true,
        );
      case LinkMethods.openGroup:
        return {'group': params['group'], 'messages': []};
      case LinkMethods.earlier:
        return {'items': earlierItems, 'earlier': false};
      case LinkMethods.close:
      case LinkMethods.closeGroup:
        return null;
      default:
        actions.add((method, params));
        return reply?.call(method, params);
    }
  }
}
