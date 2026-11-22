import 'dart:async';

import 'package:bao_link/bao_link.dart';
import 'package:baocode/bots/bot.dart';
import 'package:baocode/bots/bot_folders.dart';
import 'package:baocode/bots/bots.dart';
import 'package:baocode/bots/desktop_bot_groups.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/link/workspace_bridge.dart';
import 'package:baocode/workspace/workspace.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../kernel_test.dart' show FakeCli;

void main() {
  testWidgets('opens the selected shared group and shows only its history', (
    tester,
  ) async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    await fixture.start();
    final groups = fixture.bots.groups;
    for (final (name, history) in [
      ('Planning', ['Earlier planning update', 'Later planning update']),
      ('Research', ['Research-only update']),
    ]) {
      final room = groups.save(name: name, members: [fixture.mia.id]);
      for (final text in history) {
        groups.say(room.id, fixture.mia.id, text);
      }
    }

    await tester.pumpWidget(fixture.page());
    await tester.tap(find.text('Planning'));
    await tester.pump();
    final early = find.text('Earlier planning update');
    final late = find.text('Later planning update');
    expect(early, findsOneWidget);
    expect(late, findsOneWidget);
    expect(tester.getTopLeft(early).dy, lessThan(tester.getTopLeft(late).dy));
    expect(find.text('Research-only update'), findsNothing);
    expect(groups.unread(groups.groups.first.id), 0);
    expect(groups.unread(groups.groups.last.id), 1);
    await tester.tap(find.byTooltip('Back'));
    await tester.pump();
    await tester.tap(find.text('Research'));
    await tester.pump();
    expect(find.text('Research-only update'), findsOneWidget);
    expect(early, findsNothing);
    await tester.tap(find.byTooltip('Back'));
    await tester.pump();
    await tester.tap(find.byTooltip('Back'));
    expect(fixture.back, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('creates a group from selected bots and opens it', (
    tester,
  ) async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    await fixture.start();
    final bots = fixture.bots;
    final leo = bots.save(name: 'Leo', identity: '', abilities: {});

    await tester.pumpWidget(fixture.page());
    await tester.tap(find.byTooltip('New group'));
    await tester.pumpAndSettle();
    final create = find.widgetWithText(FilledButton, 'Create');
    expect(tester.widget<FilledButton>(create).onPressed, isNull);
    await tester.enterText(
      find.widgetWithText(TextField, 'Group name'),
      '  Release  ',
    );
    await tester.tap(find.widgetWithText(CheckboxListTile, 'Leo'));
    await tester.tap(find.widgetWithText(CheckboxListTile, 'Mia'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('group-lead-picker')));
    await tester.pumpAndSettle();
    expect(find.text('Leo'), findsWidgets);
    await tester.tap(find.text('Leo').last);
    await tester.pumpAndSettle();
    await tester.tap(create);
    await tester.pumpAndSettle();

    final group = bots.groups.groups.single;
    expect(group.name, 'Release');
    expect(group.members, [leo.id, fixture.mia.id]);
    expect(group.lead, leo.id);
    expect(find.text('Release'), findsOneWidget);
    expect(find.text('Leo, Mia'), findsOneWidget);
    expect(find.text('No messages yet'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('edits title and members on the existing group', (tester) async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    await fixture.start();
    final bots = fixture.bots;
    final leo = bots.save(name: 'Leo', identity: '', abilities: {});
    final group = bots.groups.save(
      name: 'Planning',
      members: [fixture.mia.id],
      lead: fixture.mia.id,
      rules: 'Keep updates short.',
      gap: 12,
    );
    bots.groups.say(group.id, fixture.mia.id, 'Previous update');

    await tester.pumpWidget(fixture.page());
    await tester.tap(find.text(group.name));
    await tester.pump();
    await tester.tap(find.byTooltip('Edit group'));
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertDialog);
    final title = find.descendant(of: dialog, matching: find.byType(TextField));
    expect(tester.widget<TextField>(title).controller!.text, 'Planning');
    await tester.enterText(title, 'Launch');
    await tester.tap(find.widgetWithText(CheckboxListTile, 'Mia'));
    await tester.tap(find.widgetWithText(CheckboxListTile, 'Leo'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('group-lead-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Leo').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    final updated = bots.groups.groups.single;
    expect(updated.id, group.id);
    expect(updated.name, 'Launch');
    expect(updated.members, [leo.id]);
    expect(updated.lead, leo.id);
    expect((updated.rules, updated.gap), (group.rules, group.gap));
    expect(find.text('Previous update'), findsOneWidget);
    expect(find.text('Mia'), findsOneWidget);
    expect(find.text('Launch'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the room shows the actual handler while changing the default', (
    tester,
  ) async {
    final fixture = _Fixture();
    await fixture.start();
    final bots = fixture.bots;
    final mia = fixture.mia;
    final leo = bots.save(name: 'Leo', identity: '', abilities: {});
    final ann = bots.save(name: 'Ann', identity: '', abilities: {});
    final groups = bots.groups;
    final told = <String>[];
    groups.tell = (_, member, _) => told.add(member);
    final room = groups.save(
      name: 'Planning',
      members: [mia.id, leo.id, ann.id],
      lead: leo.id,
      gap: 1,
    );
    try {
      await tester.pumpWidget(fixture.page());
      await tester.tap(find.text(room.name));
      await tester.pump();
      expect(find.text('Default lead: Leo'), findsOneWidget);
      expect(find.text('No bot handling this turn'), findsOneWidget);

      Future<void> send(String text) async {
        await tester.enterText(find.byType(TextField), text);
        await tester.pump();
        await tester.tap(find.widgetWithIcon(IconButton, Icons.arrow_upward));
        await tester.pump();
      }

      Future<void> changeLead(String choice) async {
        await tester.tap(find.byTooltip('Change default lead'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(choice));
        await tester.pumpAndSettle();
      }

      await send('@Mia start');
      expect(find.text('Handling: Mia'), findsOneWidget);
      expect(told, [mia.id]);
      await changeLead('Ann');
      expect(find.text('Default lead: Ann'), findsOneWidget);
      expect(find.text('Handling: Mia'), findsOneWidget);
      expect(told, [mia.id]);
      expect(groups.messages(room.id), hasLength(1));

      groups.turnEnded(
        room.id,
        mia.id,
        '<bot_say>Ready</bot_say>',
        next: 'Leo',
      );
      await tester.pump();
      expect(find.text('Waiting for: Leo'), findsOneWidget);
      expect(told, [mia.id]);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Handling: Leo'), findsOneWidget);
      groups.turnEnded(room.id, leo.id, '');
      await tester.pump();

      await send('Continue');
      expect(find.text('Handling: Ann'), findsOneWidget);
      expect(told, [mia.id, leo.id, ann.id]);
      await changeLead('No default lead');
      expect(find.text('Default lead: None'), findsOneWidget);
      expect(find.text('Handling: Ann'), findsOneWidget);
      expect(told, [mia.id, leo.id, ann.id]);
      groups.turnEnded(room.id, ann.id, '');
      await tester.pump();
      expect(find.text('No bot handling this turn'), findsOneWidget);
      expect(groups.byId(room.id)!.lead, isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      fixture.dispose();
      await tester.pump();
    }
  });

  testWidgets('desktop and phone share an ordered log and one member thread', (
    tester,
  ) async {
    final fixture = _Fixture();
    await fixture.start();
    final bots = fixture.bots;
    final mia = fixture.mia;
    final thread = bots.threadOf(mia)!;
    final group = bots.groups.save(name: 'Planning', members: [mia.id]);
    final other = bots.groups.save(name: 'Research', members: [mia.id]);
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
      bots: bots,
      peer: desktop,
      device: () => const DeviceInfo(name: 'Mac', kind: 'mac', system: 'macOS'),
    )..start();
    try {
      await tester.pumpWidget(fixture.page());
      await tester.tap(find.text(group.name));
      await tester.pump();
      final input = find.byType(TextField);
      final send = find.widgetWithIcon(IconButton, Icons.arrow_upward);
      await tester.enterText(input, '   ');
      await tester.pump();
      expect(tester.widget<IconButton>(send).onPressed, isNull);

      thread.session.send(const ComposerMessage(text: 'Private question'));
      await tester.pump();
      final cli = fixture.cli[mia.folder]!;
      _finishTurn(cli, 'private', '<bot_say>Private answer</bot_say>');
      await tester.pump();

      final initial = await phone.call(LinkMethods.openGroup, {
        'group': group.id,
      });
      expect(initial, {'messages': [], 'more': false});
      final updates = <LinkGroupMessage>[];
      final updatedGroups = <Object?>{};
      final events = phone.events.listen((event) {
        if (event.name != LinkEvents.group) return;
        final data = event.data! as Map;
        updatedGroups.add(data['group']);
        updates.addAll(
          (data['messages'] as List).cast<Map<String, Object?>>().map(
            LinkGroupMessage.fromJson,
          ),
        );
      });
      try {
        await tester.enterText(input, '  Desktop update  ');
        await tester.pump();
        await tester.tap(send);
        await tester.pump();
        expect(tester.widget<TextField>(input).controller!.text, isEmpty);
        expect(bots.groups.messages(group.id).single.text, 'Desktop update');
        expect(cli.users.last.toString(), contains('[group ${group.id}]'));

        _finishTurn(
          cli,
          'first',
          'private scratchpad <bot_say>[laughs] First reply</bot_say><bot_next></bot_next>',
        );
        await tester.pump();

        expect(
          await phone.call(LinkMethods.sendGroup, {
            'group': group.id,
            'text': 'From the phone',
            'id': 'test-phone-update',
          }),
          {'seq': 3},
        );
        await tester.pump();
        _finishTurn(cli, 'second', '<bot_say>Second reply</bot_say>');
        bots.groups.say(other.id, mia.id, 'Other room reply');
        await tester.pumpAndSettle();

        final expected = [
          ('Desktop update', linkGroupUser),
          ('First reply', mia.id),
          ('From the phone', linkGroupUser),
          ('Second reply', mia.id),
        ];
        var previousY = 0.0;
        for (final (text, _) in expected) {
          final shown = find.text(text);
          expect(shown, findsOneWidget);
          final y = tester.getTopLeft(shown).dy;
          expect(y, greaterThan(previousY));
          previousY = y;
        }
        for (final hidden in [
          'Private question',
          'Private answer',
          'Other room reply',
          'private scratchpad',
          '[group ',
          '[laughs]',
          '<bot_',
        ]) {
          expect(find.textContaining(hidden), findsNothing);
        }
        expect(updates.map((m) => (m.seq, m.from)), [
          for (final (index, (_, sender)) in expected.indexed)
            (index + 1, sender),
        ]);
        expect(updatedGroups, {group.id});
        expect(
          updates.map((m) => m.toJson()),
          bots.groups.messages(group.id).map((m) => m.toJson()),
        );
        expect(
          fixture.workspace.threads.where((t) => t.project.path == mia.folder),
          [thread],
        );
        expect(fixture.workspace.threads, hasLength(bots.bots.length));
      } finally {
        unawaited(events.cancel());
      }
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      bridge.dispose();
      await phone.close();
      await desktop.close();
      fixture.dispose();
      await tester.pump();
    }
  });
}

void _finishTurn(FakeCli cli, String id, String reply) => cli
  ..push({
    'type': 'assistant',
    'message': {
      'id': id,
      'role': 'assistant',
      'content': [
        {'type': 'text', 'text': reply},
      ],
    },
  })
  ..push({'type': 'result', 'subtype': 'success', 'is_error': false});

class _Fixture {
  _Fixture() {
    late final KernelDescriptor kernel;
    kernel = KernelDescriptor(
      id: 'claude-code',
      label: 'Claude Code',
      icon: Icons.chat,
      description: '',
      create: (context) => ClaudeCodeKernel(
        kernel,
        context,
        start: (_) async => cli[context.cwd] = FakeCli(),
      ),
    );
    workspace = Workspace(kernels: [kernel]);
    bots = Bots(
      workspace: workspace,
      folders: MemoryBotFolders(),
      computer: () async => 'Test desktop',
      clock: () => DateTime(2026),
    )..hasPhone = () => false;
  }

  final cli = <String?, FakeCli>{};
  late final Workspace workspace;
  late final Bots bots;
  late final Bot mia;
  int back = 0;

  Future<void> start() async {
    await bots.start();
    mia = bots.save(name: 'Mia', identity: '', abilities: {});
  }

  Widget page() => MaterialApp(
    home: Scaffold(
      body: DesktopBotGroups(bots: bots, onBack: () => back++),
    ),
  );

  void dispose() {
    bots.dispose();
    workspace.dispose();
  }
}
