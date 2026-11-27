import 'dart:async';

import 'package:bao_link/bao_link.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:bao_markdown/bao_markdown.dart';
import 'package:baocode/chat/composer/composer_presentation.dart';
import 'package:baocode/chat/panels/activity_strip.dart';
import 'package:baocode/link/desktop_host_chats.dart';
import 'package:baocode/link/desktop_host_composer.dart';
import 'package:baocode/link/desktop_host_connection.dart';
import 'package:baocode/link/desktop_host_page.dart';
import 'package:baocode/link/desktop_remote_media.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('host options read the connected transport route and RTT', (
    tester,
  ) async {
    final (a, b) = MemoryLinkConnection.pair(
      a: 'desktop',
      b: 'fixture-host',
      path: const LinkPath(LinkPathKind.lan, rtt: Duration(milliseconds: 42)),
    );
    final accepting = LinkPeer.accept(b);
    final peer = await LinkPeer.connect(a);
    final host = await accepting;
    final connection = _Connection()
      ..hostName = 'Fixture host'
      ..peer = peer;
    await _pumpPage(tester, connection);
    await tester.tap(find.byTooltip('Host options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connection info'));
    await tester.pumpAndSettle();
    expect(find.text('Local network'), findsOneWidget);
    expect(find.text('Round-trip time: 42 ms'), findsOneWidget);

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    a.setPath(const LinkPath(LinkPathKind.relay));
    await tester.tap(find.byTooltip('Host options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connection info'));
    await tester.pumpAndSettle();
    expect(find.text('Relay'), findsOneWidget);
    expect(find.textContaining('Round-trip time'), findsNothing);

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    a.setPath(LinkPath.none);
    await tester.tap(find.byTooltip('Host options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connection info'));
    await tester.pumpAndSettle();
    expect(find.text('Route unavailable'), findsOneWidget);
    expect(find.text('Relay'), findsNothing);

    connection.disconnect();
    await tester.pumpAndSettle();
    expect(find.text('Route unavailable'), findsNothing);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Host options'), findsNothing);
    expect(find.text('Connection info'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await peer.close();
    await host.close();
  });

  testWidgets('active project delivery choices open from the composer', (
    tester,
  ) async {
    final fixture = await _InspectionHost.show(tester);
    await tester.tap(find.text('Fixture first chat'));
    await tester.pumpAndSettle();
    final menu = find.byTooltip('Message delivery');
    expect(menu, findsNothing);

    fixture.push({
      'live': true,
      'actions': {'queue': true, 'turn': 123},
    });
    await tester.pumpAndSettle();
    expect(find.text('Queue message'), findsNothing);
    expect(find.text('Send now'), findsNothing);
    expect(
      find.descendant(of: find.byType(ComposerSurface), matching: menu),
      findsOneWidget,
    );
    await tester.tap(menu);
    await tester.pumpAndSettle();
    expect(find.text('Queue message'), findsOneWidget);
    expect(find.text('Send now'), findsOneWidget);

    fixture.push({
      'live': true,
      'actions': {'queue': true, 'turn': 124},
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send now'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    await fixture.close(tester);
  });

  testWidgets('project activity above the composer follows host updates', (
    tester,
  ) async {
    final fixture = await _InspectionHost.show(tester);
    await tester.tap(find.text('Fixture first chat'));
    await tester.pumpAndSettle();
    await _enterDraft(tester, 'Unsent draft');
    final strip = find.byType(ActivityStrip);
    expect(strip, findsNothing);

    final startedAt = DateTime.now().millisecondsSinceEpoch;
    final agent = LinkTask(
      id: 'agent',
      kind: 'agent',
      description: 'Fixture subagent',
      status: 'running',
      startedAt: DateTime.fromMillisecondsSinceEpoch(startedAt),
      summary: 'Reading fixture',
    ).toJson();
    final command = LinkTask(
      id: 'command',
      kind: 'command',
      description: 'Fixture background command',
      status: 'running',
      startedAt: DateTime.fromMillisecondsSinceEpoch(startedAt),
    ).toJson();
    fixture.push({
      'tasks': [agent, command],
      'changes': [
        {'path': 'src/fixture.dart', 'added': 4, 'removed': 2},
      ],
    });
    await tester.pumpAndSettle();
    expect(find.text('Fixture subagent'), findsOneWidget);
    expect(find.text('· Reading fixture'), findsOneWidget);
    expect(find.text('Fixture background command'), findsOneWidget);
    expect(find.textContaining('Running ·'), findsNWidgets(2));
    expect(find.text('1 file changed'), findsOneWidget);
    expect(find.text('+4'), findsOneWidget);
    expect(find.text('-2'), findsOneWidget);
    expect(
      tester.getBottomLeft(strip).dy,
      lessThan(tester.getTopLeft(find.byType(ComposerSurface)).dy),
    );
    expect(_editor(tester).controller.text, 'Unsent draft');

    await tester.tap(find.text('1 file changed'));
    await tester.pumpAndSettle();
    expect(find.text('fixture.dart'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.stop_rounded).first);
    await tester.pumpAndSettle();
    final confirm = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.widgetWithText(FilledButton, 'Stop task'),
    );
    expect(fixture.calls, isNot(contains(LinkMethods.stopTask)));
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(fixture.calls.last, LinkMethods.stopTask);

    fixture.push({
      'tasks': [
        {...agent, 'summary': 'Checking results'},
        {...command, 'status': 'succeeded'},
      ],
    });
    await tester.pumpAndSettle();
    expect(find.text('· Checking results'), findsOneWidget);
    expect(find.text('Fixture background command'), findsNothing);
    expect(find.text('1 file changed'), findsOneWidget);

    fixture.push({'tasks': [], 'changes': []});
    await tester.pumpAndSettle();
    expect(strip, findsNothing);
    expect(_editor(tester).controller.text, 'Unsent draft');
    await fixture.close(tester);
  });

  testWidgets('project goal details follow the selected host snapshot', (
    tester,
  ) async {
    const goal = {
      'condition': 'Verify the synthetic project tests',
      'state': 'active',
      'checks': 2,
      'reason': 'One fixture still needs checking',
      'setAt': 1780000000000,
    };
    final fixture = await _InspectionHost.show(tester, goal: goal);
    expect(find.text('Host goal'), findsNothing);
    await tester.tap(find.text('Fixture first chat'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Host goal').hitTestable());
    await tester.pumpAndSettle();
    expect(find.text(goal['condition']! as String), findsOneWidget);
    expect(find.text(goal['reason']! as String), findsOneWidget);
    expect(find.textContaining('2 times'), findsOneWidget);
    expect(find.textContaining('Set at'), findsOneWidget);

    fixture.push({
      'goal': {
        ...goal,
        'state': 'met',
        'reason': 'All fixtures checked',
        'duration': 12000,
        'tokens': 400,
      },
    });
    await tester.pumpAndSettle();
    expect(find.text('Met'), findsOneWidget);
    expect(find.text('All fixtures checked'), findsOneWidget);
    expect(find.textContaining('12s'), findsOneWidget);
    expect(find.textContaining('400'), findsOneWidget);

    fixture.push({'goal': null});
    await tester.pumpAndSettle();
    expect(find.text('All fixtures checked'), findsNothing);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Host goal'), findsNothing);
    expect(fixture.calls, [LinkMethods.state, LinkMethods.open]);
    await tester.tap(find.text('Fixture second chat').hitTestable());
    await tester.pumpAndSettle();
    fixture.push({'goal': goal});
    await tester.pumpAndSettle();
    expect(find.text('Host goal'), findsNothing);
    await fixture.close(tester);
  });

  testWidgets('host quota details show the advertised accounts and windows', (
    tester,
  ) async {
    final fixture = await _InspectionHost.show(
      tester,
      quota: {
        'provider': 'Fixture provider',
        'back': 1780100000000,
        'accounts': [
          {
            'name': 'Fixture primary',
            'plan': 'Fixture plan',
            'current': true,
            'at': 1780000000000,
            'windows': [
              {'minutes': 300, 'left': 42, 'resets': 1780020000000},
              {'name': 'Fixture window', 'minutes': 10080, 'left': 78},
              {'left': 999, 'resets': 9000000000000000},
            ],
          },
          {
            'name': 'Fixture secondary',
            'off': true,
            'until': 1780100000000,
            'error': 'Fixture account error',
          },
        ],
      },
    );
    expect(find.text('Host quota details'), findsNothing);
    await tester.tap(find.text('Fixture first chat'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Host quota details').hitTestable());
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    Finder detail(String text) =>
        find.descendant(of: dialog, matching: find.textContaining(text));
    for (final text in [
      'Fixture provider',
      'back ',
      'Fixture primary',
      'Fixture plan',
      'This chat',
      'Last updated',
      '42% left',
      'resets ',
      'Fixture window',
      '78% left',
      'Fixture secondary',
      'Unavailable',
      'Limited until',
      'Fixture account error',
    ]) {
      expect(detail(text), findsOneWidget);
    }
    expect(detail('999%'), findsNothing);
    expect(fixture.calls, [LinkMethods.state, LinkMethods.open]);

    fixture.push({'quota': null});
    await tester.pumpAndSettle();
    expect(detail('Fixture secondary'), findsNothing);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Host quota details'), findsNothing);
    expect(find.text('Refresh host quota'), findsNothing);
    await fixture.close(tester);
  });

  testWidgets(
    'paired project header opens host tasks and shows pending question',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final (a, b) = MemoryLinkConnection.pair(a: 'desktop', b: 'pc');
      final accepting = LinkPeer.accept(b);
      final peer = await LinkPeer.connect(a);
      final host = await accepting;
      final chats = DesktopHostChats();
      final calls = <String>[];
      host.onRequest = (method, params) {
        calls.add(method);
        if (method == LinkMethods.state) {
          return LinkState(
            device: const DeviceInfo(
              name: 'PC',
              kind: 'desktop',
              system: 'windows',
            ),
            projects: const [
              ProjectInfo(id: 'pr', name: 'Folder', path: 'D:/fixture'),
            ],
            sessions: [
              SessionSummary(
                id: 's',
                project: 'pr',
                title: 'Paired session',
                updatedAt: DateTime(2026),
              ),
            ],
          ).toJson();
        }
        if (method == LinkMethods.open) {
          return {
            'session': 's',
            'start': 0,
            'items': [],
            'count': 0,
            'interaction': {
              't': 'question',
              'id': 'q1',
              'questions': [
                {
                  'prompt': 'A fixture question?',
                  'options': [
                    {'label': 'Yes'},
                  ],
                },
              ],
            },
            'tasks': [
              {
                'id': 'task',
                'kind': 'command',
                'description': 'Fixture task',
                'status': 'running',
                'startedAt': DateTime.now().millisecondsSinceEpoch,
              },
            ],
          };
        }
        return null;
      };
      chats.bind(peer);
      await tester.idle();
      await _pumpPage(tester, _Connection()..peer = peer, chats: chats);
      await tester.tap(find.text('Paired session'));
      await tester.pumpAndSettle();
      expect(find.text('A fixture question?').hitTestable(), findsOneWidget);
      expect(find.text('Yes').hitTestable(), findsOneWidget);
      final conversation = find.byKey(const ValueKey('host-content'));
      final cardWidth = tester.getSize(conversation).width;
      final rules = find.descendant(
        of: conversation,
        matching: find.byType(Divider),
      );
      expect(
        rules.evaluate().where(
          (element) => element.size!.width >= cardWidth * .9,
        ),
        isEmpty,
        reason: 'The title and composer join the transcript without full-width rules.',
      );
      await tester.tap(find.byTooltip('Project sidebar'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('desktop-remote-tab-tasks')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('desktop-remote-project-sidebar')),
          matching: find.text('Fixture task'),
        ),
        findsOneWidget,
      );
      expect(calls.where((m) => m == LinkMethods.open), hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      peer.close();
      await host.done;
    },
  );
  testWidgets('reconnects a group workspace without offering legacy pairing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(700, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final connection = _Connection()..hostName = 'Development Host';
    final chats = _Chats()
      ..chats = [_Chat('project', 'Project chat', 'project')];
    await _pumpPage(tester, connection, chats: chats);
    expect(find.text('Group computer not connected'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Project chat'), findsNothing);
    await tester.tap(find.text('Reconnect'));
    await tester.pump();
    expect(connection.reconnections, 1);
    expect(find.text('Project chat'), findsOneWidget);
    await tester.tap(find.byTooltip('Host options'));
    await tester.pumpAndSettle();
    expect(find.text('Connection info'), findsOneWidget);
    expect(find.text('Forget host'), findsNothing);
  });

  testWidgets(
    'host catalog shows which project needs an answer and counts unread bot messages',
    (tester) async {
      final chats = _Chats()
        ..chats = [
          _Chat('waiting', 'Waiting chat', 'project'),
          _Chat('new-bot', 'Helper', 'bot'),
        ];
      await _pumpPage(tester, _Connection()..peer = _Peer(), chats: chats);
      final semantics = tester.ensureSemantics();
      try {
        expect(find.bySemanticsLabel('Needs input'), findsOneWidget);
        expect(find.text('3'), findsOneWidget);
      } finally {
        semantics.dispose();
      }
    },
  );
  testWidgets('remote folders contain their sessions and keep empty projects', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final chats = _Chats()
      ..projects = const [
        ProjectInfo(
          id: r'C:\work\claude',
          name: 'claude',
          path: r'C:\work\claude',
        ),
        ProjectInfo(
          id: r'D:\orm',
          name: 'orm-adaptation-factory',
          path: r'D:\orm',
        ),
      ]
      ..chats = [
        _Chat('a', 'Install CLI', 'project', pinned: true),
        _Chat('b', 'Configure domain', 'project'),
        _Chat('bot', 'Helper', 'bot'),
      ];
    final peer = _Peer();
    await _pumpPage(tester, _Connection()..peer = peer, chats: chats);
    expect(find.text('claude'), findsOneWidget);
    expect(find.text('orm-adaptation-factory'), findsOneWidget);
    expect(
      find.byKey(const ValueKey(('new-session', r'D:\orm'))).hitTestable(),
      findsOneWidget,
    );
    expect(
      tester.getTopLeft(find.text('Install CLI')).dx,
      greaterThan(tester.getTopLeft(find.text('claude')).dx),
    );
    await tester.tap(find.text('claude'));
    await tester.pump();
    expect(find.text('Install CLI'), findsNothing);
    expect(find.text('Configure domain'), findsNothing);
    expect(find.text('Helper'), findsOneWidget);
    expect(chats.opens, isEmpty);
    await tester.tap(find.text('claude'));
    await tester.pump();
    expect(find.byIcon(Icons.push_pin_outlined), findsOneWidget);
    final manage = find.byKey(const ValueKey(('manage-session', 'b')));
    final manageIcon = find.descendant(of: manage, matching: find.byType(Icon));
    final manageFocus = Focus.of(tester.element(manageIcon));
    manageFocus.requestFocus();
    await tester.pump();
    expect(manageFocus.hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Rename'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Rename'), findsNothing);
    expect(manageFocus.hasPrimaryFocus, isTrue);
    await tester.tap(manage);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(chats.opens, isEmpty);
    expect(peer.calls, isEmpty);
    for (final method in [
      LinkMethods.pin,
      LinkMethods.rename,
      LinkMethods.archive,
      LinkMethods.delete,
    ]) {
      if (method == LinkMethods.pin) {
        manageFocus.requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      } else {
        await tester.tap(manage);
      }
      await tester.pumpAndSettle();
      final label = {
        LinkMethods.pin: 'Pin',
        LinkMethods.rename: 'Rename',
        LinkMethods.archive: 'Archive',
        LinkMethods.delete: 'Delete',
      }[method]!;
      if (method == LinkMethods.pin) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      } else {
        await tester.tap(find.text(label));
      }
      await tester.pumpAndSettle();
      if (method == LinkMethods.rename) {
        await tester.enterText(find.byType(TextFormField), 'New title');
        await tester.tap(find.text('Save'));
      }
      if (method == LinkMethods.archive || method == LinkMethods.delete) {
        await tester.tap(find.widgetWithText(TextButton, label));
      }
      await tester.pumpAndSettle();
      expect(peer.calls.last.$1, method);
      expect(peer.calls.last.$2, {
        'session': 'b',
        if (method == LinkMethods.pin) 'pinned': true,
        if (method == LinkMethods.rename) 'title': 'New title',
      });
    }
    await tester.tap(find.text('Configure domain'));
    await tester.pump();
    expect(chats.opens, ['b']);
    final create = find.byKey(const ValueKey(('new-session', r'D:\orm')));
    final createIcon = find.descendant(of: create, matching: find.byType(Icon));
    Focus.of(tester.element(createIcon)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(chats.created, [r'D:\orm']);
    expect(chats.selected?.id, 'fresh');
  });

  testWidgets('wide workspace keeps chat navigation beside the composer', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final connection = _Connection()..peer = _Peer();
    final chats = _Chats()
      ..chats = [
        _Chat('project', 'Project chat', 'project'),
        _Chat('bot', 'Helper bot', 'bot'),
      ];
    var back = 0;
    final switcher = find.byKey(const ValueKey('local-computer'));
    await _pumpPage(tester, connection, chats: chats, onBack: () => back++);
    expect(chats.opens, isEmpty);
    final switcherBounds = tester.getRect(switcher);

    await tester.tap(find.text('Project chat'));
    await tester.pump();
    final pane = find.byKey(const ValueKey('host-content'));
    final title = find.descendant(
      of: pane,
      matching: find.text('Project chat'),
    );
    expect(
      tester.getTopLeft(title).dx - tester.getTopLeft(pane).dx,
      lessThan(28),
    );
    expect(
      tester.getTopLeft(title).dy - tester.getTopLeft(pane).dy,
      lessThan(27),
    );
    final bot = find.text('Helper bot');
    expect(bot.hitTestable(), findsOneWidget);
    expect(tester.getRect(bot).right, lessThan(tester.getRect(_composer).left));
    expect(tester.getRect(switcher), switcherBounds);
    expect(find.text('1d'), findsOneWidget);
    await tester.tap(title);
    await tester.pump(const Duration(milliseconds: 70));
    await tester.tap(title);
    await tester.pump();
    final rename = find.descendant(of: pane, matching: find.byType(TextField));
    expect(rename, findsOneWidget);
    await tester.enterText(rename, 'Revised project chat');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect((connection.peer as _Peer).calls.single.$1, LinkMethods.rename);
    expect((connection.peer as _Peer).calls.single.$2, {
      'session': 'project',
      'title': 'Revised project chat',
    });
    expect(
      title,
      findsOneWidget,
    ); // The host catalog, not a local optimistic rename.
    final fileRail = find.byKey(
      const ValueKey('desktop-remote-project-sidebar-toggle'),
    );
    expect(fileRail.hitTestable(), findsOneWidget);
    final toggle = find.byKey(const ValueKey('host-toggle-sidebar'));
    await tester.tap(toggle);
    await tester.pump();
    expect(bot, findsNothing);
    expect(find.text('Project chat'), findsOneWidget);
    expect(chats.opens, ['project']);
    await tester.tap(toggle);
    await tester.pump();
    expect(bot.hitTestable(), findsOneWidget);
    expect(find.text('Pairing link'), findsNothing);

    await tester.tap(bot);
    await tester.pump();
    expect(chats.opens, ['project', 'bot']);
    expect(chats.selected?.id, 'bot');
    expect(back, 0);

    await tester.tap(switcher);
    await tester.pump();
    expect(chats.selected, isNull);
    expect(back, 1);
  });

  testWidgets('opens only the selected chat, renders updates, and closes it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(700, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final connection = _Connection()..peer = _Peer();
    final chats = _Chats()
      ..chats = [
        _Chat('bot-1', 'Helper bot', 'bot'),
        _Chat('group-1', 'Team chat', 'group'),
        _Chat('project-1', 'Project chat', 'project'),
      ];
    var back = 0;
    await _pumpPage(tester, connection, chats: chats, onBack: () => back++);
    expect(chats.opens, isEmpty);
    expect(find.text('Projects'), findsOneWidget);
    expect(find.text('Bots'), findsOneWidget);
    expect(find.text('Groups'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Project chat')).dy,
      lessThan(tester.getTopLeft(find.text('Helper bot')).dy),
    );

    await tester.tap(find.text('Team chat'));
    await tester.pump();
    expect(chats.opens, ['group-1']);
    expect(find.text('Helper bot'), findsNothing);
    expect(find.text('New host message'), findsNothing);
    chats.append(_Message('New host message', 'Teammate', false));
    await tester.pump();
    expect(find.text('New host message'), findsOneWidget);
    await tester.tap(find.text('Load earlier messages'));
    await tester.pump();
    expect(find.text('From earlier'), findsOneWidget);

    await tester.tap(find.byTooltip('Back to host chats'));
    await tester.pump();
    expect(chats.closes, 1);
    expect(back, 0);
    expect(find.text('Helper bot'), findsOneWidget);
    await tester.tap(find.text('Helper bot'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('host-toggle-sidebar')));
    await tester.pumpAndSettle();
    final local = find.byKey(const ValueKey('local-computer')).hitTestable();
    expect(local, findsOneWidget);
    await tester.tap(local);
    await tester.pump();
    expect(chats.closes, 2);
    expect(back, 1);
  });

  testWidgets('resizing a live chat keeps its selection and draft', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final connection = _Connection()..peer = _Peer();
    final chats = _Chats()
      ..chats = [
        _Chat('project', 'Project chat', 'project'),
        _Chat('bot', 'Helper bot', 'bot'),
      ];
    await _pumpPage(tester, connection, chats: chats, scale: 2);
    final projectChat = find.text('Project chat');
    await tester.scrollUntilVisible(projectChat, 80);
    await tester.tap(projectChat.hitTestable());
    await tester.pump();
    await _enterDraft(tester, 'Unsent');
    final composer = _editor(tester);

    tester.view.physicalSize = const Size(300, 640);
    await tester.pump();
    expect(find.text('Helper bot'), findsNothing);
    expect(find.byTooltip('Back to host chats').hitTestable(), findsOneWidget);
    final backSemantics = find.semantics.byPredicate(
      (node) => node.getSemanticsData().tooltip == 'Back to host chats',
    );
    expect(backSemantics, findsOne);
    final directory = find.byKey(const ValueKey('host-toggle-sidebar'));
    final catalog = find.byKey(const ValueKey('host-catalog'));
    expect(directory.hitTestable(), findsOneWidget);
    expect(find.text('Session directory'), findsOneWidget);
    final titleBarTop = tester.getTopLeft(directory).dy;
    await tester.tap(directory);
    await tester.pumpAndSettle();
    expect(catalog.hitTestable(), findsOneWidget);
    expect(_composer.hitTestable(), findsNothing);
    expect(backSemantics, findsNothing);
    expect(find.text('Return to current conversation'), findsOneWidget);
    expect(tester.getTopLeft(directory).dy, titleBarTop);
    expect(
      tester.getRect(directory).bottom,
      lessThanOrEqualTo(tester.getRect(catalog).top),
    );
    await tester.tap(directory);
    await tester.pump();
    expect(catalog, findsNothing);
    expect(_editor(tester).controller.text, 'Unsent');
    expect(_editor(tester), same(composer));
    expect(chats.opens, ['project']);
    expect(chats.closes, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('removing the page closes the chat subscription', (tester) async {
    final connection = _Connection()..peer = _Peer();
    final chats = _Chats()
      ..chats = [_Chat('project', 'Project chat', 'project')];
    await _pumpPage(tester, connection, chats: chats);
    await tester.tap(find.text('Project chat'));
    await tester.pump();
    expect(chats.selected, isNotNull);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(chats.closes, 1);
    expect(chats.selected, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed send keeps the draft and prevents duplicate sends', (
    tester,
  ) async {
    final connection = _Connection()..peer = _Peer();
    final result = Completer<void>();
    final chats = _Chats()
      ..chats = [_Chat('project', 'Project chat', 'project')]
      ..sendResult = result.future;
    await _pumpPage(tester, connection, chats: chats);
    await tester.tap(find.text('Project chat'));
    await tester.pump();
    await _enterDraft(tester, '  My message  ');
    await tester.tap(_sendButton);
    await tester.tap(_sendButton);
    await tester.pump();
    expect(chats.sends, ['My message']);
    result.completeError(const FormatException('Could not send.'));
    await tester.pump();
    expect(find.text('Could not send.'), findsOneWidget);
    expect(_editor(tester).controller.text, '  My message  ');

    await tester.tap(_sendButton);
    await tester.pump();
    expect(chats.sends, ['My message', 'My message']);
    expect(_editor(tester).controller.text, isEmpty);
  });

  testWidgets('restores an offline draft only within the same host chat', (
    tester,
  ) async {
    final connection = _Connection()
      ..hostName = 'Development Host'
      ..peer = _Peer();
    final chats = _Chats()
      ..chats = [_Chat('project', 'Project chat', 'project')];
    await _pumpPage(tester, connection, chats: chats);
    await tester.tap(find.text('Project chat'));
    await tester.pump();
    await _enterDraft(tester, 'A private draft');

    connection.disconnect();
    await tester.pump();
    final catalog = find.byKey(const ValueKey('host-catalog'));
    expect(
      find.descendant(
        of: catalog,
        matching: find.text('Group computer not connected'),
      ),
      findsOneWidget,
    );
    expect(_composer, findsNothing);
    await tester.tap(
      find.descendant(of: catalog, matching: find.text('Reconnect')),
    );
    await tester.pump();
    expect(_editor(tester).controller.text, 'A private draft');

    // Workbench resets the catalog when selecting a different authenticated host.
    chats.closeChat();
    connection.replacePeer(_Peer('another-host'));
    await tester.pump();
    // Another host may have a chat with the same public ID.
    await tester.tap(find.text('Project chat'));
    await tester.pump();
    expect(_editor(tester).controller.text, isEmpty);
  });

  testWidgets('catalog navigation retains independent chat drafts', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(700, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final connection = _Connection()..peer = _Peer();
    final chats = _Chats()
      ..chats = [
        _Chat('same-id', 'Project chat', 'project'),
        _Chat('same-id', 'Helper bot', 'bot'),
      ];
    await _pumpPage(tester, connection, chats: chats);
    await tester.tap(find.text('Project chat'));
    await tester.pump();
    await _enterDraft(tester, 'Unsent project notes');
    const selection = TextSelection(baseOffset: 14, extentOffset: 7);
    _editor(tester).controller.selection = selection;
    await tester.tap(find.byTooltip('Back to host chats'));
    await tester.pump();

    await tester.tap(find.text('Helper bot'));
    await tester.pump();
    expect(_editor(tester).controller.text, isEmpty);
    await _enterDraft(tester, 'Unsent bot notes');
    await tester.tap(find.byTooltip('Back to host chats'));
    await tester.pump();

    await tester.tap(find.text('Project chat'));
    await tester.pump();
    expect(_editor(tester).controller.text, 'Unsent project notes');
    expect(_editor(tester).controller.selection, selection);
    expect(chats.sends, isEmpty);
  });

  testWidgets('narrow Chinese remote workspace fits enlarged text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(300, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final connection = _Connection()..hostName = '开发电脑';
    await _pumpPage(tester, connection, locale: const Locale('zh'), scale: 1.8);
    expect(find.text('开发电脑'), findsOneWidget);
    expect(find.text('切回本地').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('local workspace switch preserves an unsent remote draft', (
    tester,
  ) async {
    final connection = _Connection()..peer = _Peer();
    final chats = _Chats()
      ..chats = [_Chat('project', 'Project chat', 'project')];
    var back = 0;
    await _pumpPage(tester, connection, chats: chats, onBack: () => back++);
    await tester.tap(find.text('Project chat'));
    await tester.pump();
    await _enterDraft(tester, 'Draft kept in memory');
    final local = find.byKey(const ValueKey('local-computer'));
    if (local.evaluate().isEmpty) {
      await tester.tap(find.byKey(const ValueKey('host-toggle-sidebar')));
      await tester.pump();
    }
    await tester.tap(local);
    await tester.pump();
    expect(chats.selected, isNull);
    expect(back, 1);
    await tester.pumpWidget(const SizedBox.shrink());

    await _pumpPage(tester, connection, chats: chats, disposeModels: false);
    expect(chats.selected, isNull);
    await tester.tap(find.text('Project chat'));
    await tester.pump();
    expect(_editor(tester).controller.text, 'Draft kept in memory');
    expect(chats.sends, isEmpty);
  });

  testWidgets('reconnect does not resubmit a draft with a pending reply', (
    tester,
  ) async {
    final reply = Completer<void>();
    final connection = _Connection()
      ..hostName = 'Development Host'
      ..peer = _Peer();
    final chats = _Chats()
      ..chats = [_Chat('project', 'Project chat', 'project')]
      ..sendResult = reply.future;
    await _pumpPage(tester, connection, chats: chats);
    await tester.tap(find.text('Project chat'));
    await tester.pump();
    await _enterDraft(tester, 'Check before retrying');
    await tester.tap(_sendButton);
    connection.disconnect();
    await tester.pump();
    await tester.tap(find.text('Reconnect'));
    await tester.pump();
    reply.complete();
    await tester.pumpAndSettle();
    expect(_editor(tester).controller.text, 'Check before retrying');
    expect(chats.sends, ['Check before retrying']);
  });

  testWidgets('restores last opened chat from this host after a page restart', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(700, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final storage = _LastChats();
    final project = _Chat('same-id', 'Project chat', 'project');
    final bot = _Chat('same-id', 'Helper bot', 'bot');
    final connection = _Connection()..peer = _Peer('first-host');
    final chats = _Chats()..chats = [project, bot];
    await _pumpPage(tester, connection, chats: chats, lastChatStore: storage);
    await tester.pumpAndSettle();
    expect(chats.opens, isEmpty);
    await tester.tap(find.text('Helper bot'));
    await tester.pumpAndSettle();
    expect(storage.saved, {'first-host': (kind: 'bot', id: 'same-id')});
    await tester.pumpWidget(const SizedBox.shrink());

    final different = _Connection()..peer = _Peer('second-host');
    final otherChats = _Chats()..chats = [project, bot];
    await _pumpPage(
      tester,
      different,
      chats: otherChats,
      lastChatStore: storage,
    );
    await tester.pumpAndSettle();
    expect(otherChats.opens, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());

    final restarted = _Connection()..peer = _Peer('first-host');
    final restoredChats = _Chats()..busy = true;
    await _pumpPage(
      tester,
      restarted,
      chats: restoredChats,
      lastChatStore: storage,
    );
    expect(restoredChats.opens, isEmpty);
    restoredChats.catalog([project, bot]);
    await tester.pumpAndSettle();
    expect(restoredChats.selected?.kind, 'bot');
    expect(restoredChats.opens, ['same-id']);
    expect(restoredChats.sends, isEmpty);

    await tester.tap(find.byTooltip('Back to host chats'));
    await tester.pumpAndSettle();
    expect(restoredChats.selected, isNull);
    expect(restoredChats.opens, ['same-id']);
  });

  testWidgets('a late last chat read cannot override manual selection', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(700, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final read = Completer<DesktopHostChatKey?>();
    final storage = _LastChats()..pendingRead = read.future;
    final connection = _Connection()..peer = _Peer();
    final chats = _Chats()
      ..chats = [
        _Chat('project', 'Project chat', 'project'),
        _Chat('bot', 'Helper bot', 'bot'),
      ];
    await _pumpPage(tester, connection, chats: chats, lastChatStore: storage);
    await tester.tap(find.text('Project chat'));
    await tester.pump();
    await tester.tap(find.byTooltip('Back to host chats'));
    await tester.pump();
    read.complete((kind: 'bot', id: 'bot'));
    await tester.pumpAndSettle();
    expect(chats.opens, ['project']);
    expect(chats.selected, isNull);
  });
}

final _hostComposer = find.byType(DesktopHostComposer);
final _composer = find.descendant(
  of: _hostComposer,
  matching: find.byType(MarkdownEditor),
);
final _sendButton = find.descendant(
  of: _hostComposer,
  matching: find.byType(ComposerSendButton),
);

MarkdownEditorState _editor(WidgetTester tester) =>
    tester.state<MarkdownEditorState>(_composer);

Future<void> _enterDraft(WidgetTester tester, String text) async {
  await tester.tap(_composer);
  await tester.pump();
  tester.testTextInput.updateEditingValue(
    TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    ),
  );
  await tester.pump();
}

Future<void> _pumpPage(
  WidgetTester tester,
  _Connection connection, {
  DesktopHostChats? chats,
  VoidCallback? onBack,
  DesktopHostLastChatStore? lastChatStore,
  Locale locale = const Locale('en'),
  double scale = 1,
  bool disposeModels = true,
}) async {
  final model = chats ?? _Chats();
  if (disposeModels) {
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      model.dispose();
      connection.dispose();
    });
  }
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      supportedLocales: const [Locale('en'), Locale('zh')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        ...GlobalMaterialLocalizations.delegates,
      ],
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
        body: DesktopHostPage(
          connection: connection,
          chats: model,
          onBack: onBack ?? () {},
          lastChatStore: lastChatStore,
        ),
      ),
    ),
  );
}

class _InspectionHost {
  _InspectionHost(this.peer, this.host, this.calls);

  final LinkPeer peer;
  final LinkPeer host;
  final List<String> calls;

  static Future<_InspectionHost> show(
    WidgetTester tester, {
    Map<String, Object?>? goal,
    Map<String, Object?>? quota,
  }) async {
    tester.view.physicalSize = const Size(1440, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final (a, b) = MemoryLinkConnection.pair();
    final calls = <String>[];
    final accepting = LinkPeer.accept(
      b,
      onRequest: (method, params) {
        calls.add(method);
        return switch (method) {
          LinkMethods.state => LinkState(
            device: const DeviceInfo(
              name: 'Fixture host',
              kind: 'desktop',
              system: 'windows',
            ),
            projects: const [
              ProjectInfo(
                id: 'fixture',
                name: 'Fixture project',
                path: 'D:/fixture',
              ),
            ],
            sessions: [
              for (final id in ['first', 'second'])
                SessionSummary(
                  id: id,
                  project: 'fixture',
                  title: 'Fixture $id chat',
                  updatedAt: DateTime(2026),
                ),
            ],
          ).toJson(),
          LinkMethods.open => LinkSessionUpdate(
            session: params['session']! as String,
            start: 0,
            count: 0,
            items: const [],
            goal: params['session'] == 'first' ? goal : null,
            quota: params['session'] == 'first' ? quota : null,
          ).toJson(),
          _ => null,
        };
      },
    );
    final peer = await LinkPeer.connect(a, mirror: LinkSessionMirror());
    final host = await accepting;
    final chats = DesktopHostChats()..bind(peer);
    await tester.idle();
    await _pumpPage(
      tester,
      _Connection()..peer = peer,
      chats: chats,
      lastChatStore: _LastChats(),
    );
    await tester.pumpAndSettle();
    return _InspectionHost(peer, host, calls);
  }

  void push(Map<String, Object?> fields) {
    host.emit(LinkEvents.session, {
      'session': 'first',
      'partial': true,
      'start': 0,
      'count': 0,
      'items': const [],
      ...fields,
    });
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await peer.close();
    await host.close();
  }
}

class _LastChats implements DesktopHostLastChatStore {
  final saved = <String, ({String kind, String id})>{};
  Future<DesktopHostChatKey?>? pendingRead;

  @override
  Future<DesktopHostChatKey?> read(String host) async =>
      pendingRead == null ? saved[host] : await pendingRead;

  @override
  Future<void> write(String host, ({String kind, String id}) chat) async {
    saved[host] = chat;
  }
}

class _Connection extends ChangeNotifier implements DesktopHostConnection {
  @override
  bool get groupSelected => true;
  @override
  String? get selectedHostId =>
      peer?.remote ?? (hostName != null ? 'fixture-host' : null);
  @override
  String? hostName;
  @override
  String? error;
  @override
  bool busy = false;
  @override
  LinkPeer? peer;

  int reconnections = 0;

  @override
  Future<void> reconnect() async {
    reconnections++;
    peer = _Peer();
    notifyListeners();
  }

  void disconnect() => replacePeer(null);

  void replacePeer(LinkPeer? next) {
    busy = false;
    peer = next;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Peer extends Fake implements LinkPeer {
  final calls = <(String, Map<String, Object?>)>[];
  @override
  Future<Object?> call(
    String method, [
    Map<String, Object?> params = const {},
    Duration timeout = const Duration(seconds: 30),
  ]) async {
    calls.add((method, params));
    return null;
  }

  @override
  bool get isClosed => false;
  @override
  Stream<LinkEvent> get events => const Stream.empty();
  _Peer([this.remote = 'development-host-key']);

  @override
  final String remote;
}

class _Chat extends Fake implements DesktopHostChat {
  _Chat(this.id, this.title, this.kind, {this.pinned = false});
  @override
  LinkSessionStatus get status =>
      id == 'waiting' ? LinkSessionStatus.needsInput : LinkSessionStatus.idle;
  @override
  int get unread => id == 'new-bot' ? 3 : 0;
  @override
  final bool pinned;
  @override
  bool get provisional => false;
  @override
  DateTime? get updatedAt => kind == 'project'
      ? DateTime.now().subtract(const Duration(days: 1))
      : null;
  @override
  String? get projectId => kind == 'project' ? r'C:\work\claude' : null;

  @override
  final String id;
  @override
  final String title;
  @override
  final String kind;
}

class _Message extends DesktopHostMessage {
  const _Message(String text, String sender, bool mine)
    : super(text: text, sender: sender, mine: mine);
}

class _Chats extends ChangeNotifier implements DesktopHostChats {
  @override
  Null remoteActionSnapshot(LinkPeer? peer, DesktopHostChat chat) => null;

  @override
  Null botById(String id) => null;

  @override
  Null get sessionControls => null;

  @override
  List<ProjectInfo> projects = const [
    ProjectInfo(id: r'C:\work\claude', name: 'Work', path: r'C:\work\claude'),
  ];
  @override
  List<DesktopHostChat> chats = [];
  @override
  DesktopHostChat? selected;
  @override
  List<DesktopHostMessage> messages = [];
  @override
  DesktopHostGroupQuote? get groupReply => null;
  @override
  bool isCurrentConversation(LinkPeer? peer, DesktopHostChat chat) =>
      peer?.isClosed == false && identical(selected, chat);
  @override
  Null projectBranchView(LinkPeer? peer, DesktopHostChat chat) => null;
  @override
  bool busy = false;
  @override
  bool hasEarlier = false;
  @override
  String? error;

  final created = <String>[];
  @override
  Future<void> createInProject(String projectId, String placeholder) async {
    created.add(projectId);
    await open(
      DesktopHostChat(
        id: 'fresh',
        title: placeholder,
        kind: 'project',
        projectId: projectId,
        provisional: true,
      ),
    );
  }

  final opens = <String>[];
  final sends = <String>[];
  int closes = 0;
  Future<void>? sendResult;

  void catalog(List<DesktopHostChat> entries) {
    chats = entries;
    busy = false;
    notifyListeners();
  }

  @override
  Future<void> open(DesktopHostChat chat) async {
    opens.add(chat.id);
    selected = chat;
    hasEarlier = true;
    notifyListeners();
  }

  @override
  Future<void> earlier() async {
    messages.insert(0, _Message('From earlier', 'Teammate', false));
    hasEarlier = false;
    notifyListeners();
  }

  @override
  Future<void> send(String text) async {
    sends.add(text);
    error = null;
    final result = sendResult;
    sendResult = null;
    try {
      if (result != null) await result;
    } on FormatException catch (failure) {
      error = failure.message;
    }
    notifyListeners();
  }

  @override
  Future<bool> sendWithAttachments(
    String text,
    DesktopRemoteAttachments attachments,
  ) async {
    await send(text.trim());
    return error == null;
  }

  void append(DesktopHostMessage message) {
    messages.add(message);
    notifyListeners();
  }

  @override
  void closeChat() {
    closes++;
    selected = null;
    messages.clear();
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
