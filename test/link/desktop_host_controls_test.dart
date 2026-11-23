import 'dart:async';

import 'package:bao_link/bao_link.dart';
import 'package:bao_markdown/bao_markdown.dart';
import 'package:baocode/chat/composer/composer_presentation.dart';
import 'package:baocode/chat/composer/composer_picker.dart';
import 'package:baocode/chat/panels/context_usage_panel.dart';
import 'package:baocode/chat/widgets/context_meter.dart';
import 'package:baocode/link/desktop_host_chats.dart';
import 'package:baocode/link/desktop_host_connection.dart';
import 'package:baocode/link/desktop_host_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('mode picker sends the host session and advertised option ID', (
    tester,
  ) async {
    final host = await _Host.show(tester);
    await _tap(tester, 'First session');
    await _tap(tester, 'Host Ask');
    await _tap(tester, 'Host Plan');
    expect(host.actions.single.$1, LinkMethods.choose);
    expect(host.actions.single.$2, {
      'session': 'first',
      'kind': 'mode',
      'option': 'plan',
    });
    // The null response does not say which option the host applied.
    expect(find.text('Host Ask'), findsOneWidget);
    host.update('first', choices: [_mode('plan')]);
    await tester.pumpAndSettle();
    expect(find.text('Host Plan'), findsOneWidget);
  });

  testWidgets('permission, model and model settings use advertised IDs', (
    tester,
  ) async {
    final host = await _Host.show(tester);
    await _tap(tester, 'First session');
    await _tap(tester, 'Host Default');
    await _tap(tester, 'Host Approve Edits');
    host.expectChoice(0, 'first', 'permission', 'edit');
    await _tap(tester, 'Host Model A · Host Low');
    await _tap(tester, 'Host Model B');
    host.expectChoice(1, 'first', 'model', 'vendor/b');
    host.update('first', choices: _choices(model: 'vendor/b'));
    await tester.pumpAndSettle();

    final editor = find.byType(MarkdownEditor);
    await tester.tap(editor);
    await tester.pump();
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'unsent',
        selection: TextSelection.collapsed(offset: 6),
      ),
    );
    await tester.pump();
    final controller = tester.widget<MarkdownEditor>(editor).controller;
    await _tap(tester, 'Host Model B · Host Low');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(find.text('Host High').hitTestable(), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    host.expectChoice(2, 'first', 'effort', 'host-high');
    expect(host.actions, hasLength(3));
    expect(controller.text, 'unsent');
    expect(tester.widget<MarkdownEditor>(editor).controller, same(controller));
    host.update(
      'first',
      choices: _choices(model: 'vendor/b', effort: 'host-high'),
    );
    await tester.pumpAndSettle();
    await _tap(tester, 'Host Model B · Host High');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await _tap(tester, 'Host Extended');
    host.expectChoice(3, 'first', 'context', 'host-long');
  });

  testWidgets(
    'stop targets the live host session once without submitting a draft',
    (tester) async {
      final host = await _Host.show(tester);
      await _tap(tester, 'First session');
      final editor = find.byType(MarkdownEditor);
      await tester.tap(editor);
      await tester.pump();
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'keep me',
          selection: TextSelection.collapsed(offset: 7),
        ),
      );
      await tester.pump();
      final controller = tester.widget<MarkdownEditor>(editor).controller;
      host.update('first', live: true);
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(host.actions, isEmpty);
      final reply = Completer<Object?>();
      host.reply = (_, _) => reply.future;
      final button = find.byType(ComposerSendButton);
      expect(find.byKey(const ValueKey('stop')), findsOneWidget);
      await tester.tap(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(host.actions.single.$1, LinkMethods.stop);
      expect(host.actions.single.$2, {'session': 'first'});

      reply.complete(null);
      await tester.pumpAndSettle();
      await tester.tap(button, warnIfMissed: false);
      expect(host.actions, hasLength(1));
      host.update('first');
      await tester.pumpAndSettle();
      expect(tester.widget<ComposerSendButton>(button).onSend, isNotNull);
      expect(controller.text, 'keep me');
    },
  );

  testWidgets('a late choice rejection is ignored after switching sessions', (
    tester,
  ) async {
    final host = await _Host.show(tester);
    await _tap(tester, 'First session');
    final reply = Completer<Object?>();
    host.reply = (_, _) => reply.future;
    await _tap(tester, 'Host Ask');
    await _tap(tester, 'Host Plan');
    await _tap(tester, 'Second session');
    host.update('first', choices: [_mode('plan')], live: true);
    reply.completeError(
      const LinkRemoteException('busy', 'Host refused the choice'),
    );
    await tester.pumpAndSettle();
    expect(host.chats.selected?.id, 'second');
    expect(find.text('Could not change the host setting.'), findsNothing);
    expect(find.text('Host Ask'), findsOneWidget);

    host.reply = (_, _) =>
        throw const LinkRemoteException('busy', 'Host refused the choice');
    await _tap(tester, 'Host Ask');
    await _tap(tester, 'Host Plan');
    host.expectChoice(1, 'second', 'mode', 'plan');
    expect(find.text('Could not change the host setting.'), findsOneWidget);
  });

  testWidgets('footer follows catalog branch and optional session context', (
    tester,
  ) async {
    final host = await _Host.show(tester);
    await _tap(tester, 'First session');
    expect(find.text('fixture-branch'), findsOneWidget);
    expect(find.byType(ContextMeter), findsNothing);
    host.update(
      'first',
      context: const {
        'window': 200000,
        'used': 13200,
        'parts': [
          {'part': 'system', 'tokens': 1200},
          {'part': 'messages', 'tokens': 12000},
        ],
        'compactAt': 180000,
      },
    );
    await tester.pumpAndSettle();
    expect(find.text('13.2K / 200K'), findsOneWidget);
    expect(find.text('Host Ask'), findsOneWidget);
    await _tap(tester, '13.2K / 200K');
    final panel = tester.widget<ContextUsagePanel>(
      find.byType(ContextUsagePanel),
    );
    expect(panel.usage.segments.map((part) => part.tokens), [1200, 12000]);
    expect(panel.usage.detail?.autoCompactAt, 180000);
    expect(panel.stats, isNull);

    host.update('first');
    await tester.pumpAndSettle();
    expect(find.byType(ContextUsagePanel), findsNothing);
    expect(find.byType(ContextMeter), findsNothing);
    expect(find.text('fixture-branch'), findsOneWidget);
    expect(host.actions, isEmpty);
  });

  testWidgets('an open effort menu cannot change a newly selected host model', (
    tester,
  ) async {
    final host = await _Host.show(tester);
    await _tap(tester, 'First session');
    await _tap(tester, 'Host Model A · Host Low');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    final staleOption = find.text('Host High');
    expect(staleOption.hitTestable(), findsOneWidget);
    host.update('first', choices: _choices(model: 'vendor/b'));
    // Deliver the push while the old menu is still painted.
    await tester.idle();
    await tester.tap(staleOption.hitTestable());
    await tester.pumpAndSettle();
    expect(host.actions, isEmpty);
    expect(find.text('Host Model B · Host Low'), findsOneWidget);
  });

  testWidgets('model settings wait for the host to confirm its new model', (
    tester,
  ) async {
    final host = await _Host.show(tester);
    await _tap(tester, 'First session');
    await _tap(tester, 'Host Model A · Host Low');
    await _tap(tester, 'Host Model B');
    await tester.tap(find.textContaining('Host Model A').hitTestable());
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(find.text('Host High'), findsNothing);
    expect(host.actions, hasLength(1));

    host.update('first', choices: _choices(model: 'vendor/b'));
    await tester.pumpAndSettle();
    await _tap(tester, 'Host Model B · Host Low');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await _tap(tester, 'Host High');
    host.expectChoice(1, 'first', 'effort', 'host-high');
  });

  testWidgets('a host that rejects Stop as unknown is not called again', (
    tester,
  ) async {
    final host = await _Host.show(tester);
    await _tap(tester, 'First session');
    host.reply = (_, _) =>
        throw const LinkRemoteException(LinkErrors.unknown, 'Unknown method');
    host.update('first', live: true);
    await tester.pumpAndSettle();
    final button = find.byType(ComposerSendButton);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.text('Could not stop the host session.'), findsOneWidget);
    expect(find.byKey(const ValueKey('stop')), findsNothing);
    host.update('first');
    host.update('first', live: true);
    await tester.pumpAndSettle();
    expect(tester.widget<ComposerSendButton>(button).onStop, isNull);
    expect(host.actions.single.$1, LinkMethods.stop);
  });

  testWidgets('older Windows snapshots keep the plain editor usable', (
    tester,
  ) async {
    final host = await _Host.show(tester, legacy: true);
    await _tap(tester, 'First session');
    expect(find.byType(ComposerPicker), findsNothing);
    expect(find.byType(ContextMeter), findsNothing);
    expect(find.byKey(const ValueKey('stop')), findsNothing);
    host.reply = (_, params) => {'session': params['session']};
    await tester.tap(find.byType(MarkdownEditor));
    await tester.pump();
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'legacy draft',
        selection: TextSelection.collapsed(offset: 12),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(host.actions.single.$1, LinkMethods.send);
    expect(host.actions.single.$2['session'], 'first');
    expect(host.actions.single.$2['text'], 'legacy draft');
    expect(
      tester
          .widget<MarkdownEditor>(find.byType(MarkdownEditor))
          .controller
          .text,
      isEmpty,
    );
  });

  testWidgets(
    'private bots get model choices and groups have no session controls',
    (tester) async {
      final host = await _Host.show(tester);
      await _tap(tester, 'Private helper');
      host.update('bot-session', live: true);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('stop')), findsNothing);
      expect(host.chats.sessionControls!.canStop, isFalse);
      expect(find.text('Host Ask'), findsNothing);
      expect(find.text('Host Default'), findsNothing);
      expect(find.text('fixture-branch'), findsNothing);
      await _tap(tester, 'Host Model A · Host Low');
      await _tap(tester, 'Host Model B');
      host.expectChoice(0, 'bot-session', 'model', 'vendor/b');
      await _tap(tester, 'Fixture group');
      expect(find.byType(ComposerPicker), findsNothing);
      expect(find.byType(ContextMeter), findsNothing);
      expect(find.byKey(const ValueKey('stop')), findsNothing);
      expect(host.actions, hasLength(1));
    },
  );
}

Future<void> _tap(WidgetTester tester, String label) async {
  await tester.tap(find.text(label).hitTestable());
  await tester.pumpAndSettle();
}

const _project = ProjectInfo(
  id: r'C:\fixture\project',
  name: 'Host project',
  path: r'C:\fixture\project',
  branch: 'fixture-branch',
);

LinkChoice _mode(String selected) => LinkChoice(
  kind: 'mode',
  selected: selected,
  options: const [
    LinkOption(id: 'ask', label: 'Host Ask'),
    LinkOption(id: 'plan', label: 'Host Plan'),
  ],
);

List<LinkChoice> _choices({
  String model = 'vendor/a',
  String effort = 'host-low',
}) => [
  _mode('ask'),
  const LinkChoice(
    kind: 'permission',
    selected: 'default',
    options: [
      LinkOption(id: 'default', label: 'Host Default'),
      LinkOption(id: 'edit', label: 'Host Approve Edits', caution: true),
    ],
  ),
  LinkChoice(
    kind: 'model',
    selected: model,
    options: const [
      LinkOption(
        id: 'vendor/a',
        label: 'Host Model A',
        group: 'vendor',
        groupLabel: 'Host Vendor',
      ),
      LinkOption(
        id: 'vendor/b',
        label: 'Host Model B',
        group: 'vendor',
        groupLabel: 'Host Vendor',
      ),
    ],
  ),
  LinkChoice(
    kind: 'effort',
    selected: effort,
    options: const [
      LinkOption(id: 'host-low', label: 'Host Low'),
      LinkOption(id: 'host-high', label: 'Host High'),
    ],
  ),
  const LinkChoice(
    kind: 'context',
    selected: 'host-standard',
    options: [
      LinkOption(id: 'host-standard', label: 'Host Standard'),
      LinkOption(id: 'host-long', label: 'Host Extended'),
    ],
  ),
];

class _Host {
  _Host({required this.legacy});

  final bool legacy;
  final actions = <(String, Map<String, Object?>)>[];
  LinkRequestHandler? reply;
  final chats = DesktopHostChats();
  late final LinkPeer _host;
  late final LinkPeer _client;
  final _slimmers = <String, LinkSessionSlimmer>{};

  static Future<_Host> show(WidgetTester tester, {bool legacy = false}) async {
    final host = _Host(legacy: legacy);
    final (a, b) = MemoryLinkConnection.pair(
      a: 'fixture-client',
      b: 'fixture-host',
    );
    final accepting = LinkPeer.accept(b, onRequest: host._handle);
    host._client = await LinkPeer.connect(a, mirror: LinkSessionMirror());
    host._host = await accepting;
    final connection = _Connection(host._client);
    addTearDown(() async {
      host.chats.dispose();
      connection.dispose();
      await host._client.close();
      await host._host.close();
    });
    // Wide enough to switch sessions while a request is outstanding.
    tester.view.physicalSize = const Size(1150, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    host.chats.bind(host._client);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DesktopHostPage(
            chats: host.chats,
            connection: connection,
            onBack: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return host;
  }

  FutureOr<Object?> _handle(String method, Map<String, Object?> params) {
    switch (method) {
      case LinkMethods.state:
        return LinkState(
          device: const DeviceInfo(
            name: 'Fixture Host',
            kind: 'desktop',
            system: 'windows',
          ),
          projects: const [_project],
          bots: const [
            LinkBot(id: 'bot', name: 'Private helper', session: 'bot-session'),
          ],
          groups: const [LinkGroup(id: 'group', name: 'Fixture group')],
          sessions: [
            SessionSummary(
              id: 'first',
              project: _project.id,
              title: 'First session',
              updatedAt: DateTime(2026),
            ),
            SessionSummary(
              id: 'second',
              project: _project.id,
              title: 'Second session',
              updatedAt: DateTime(2026),
            ),
          ],
        ).toJson();
      case LinkMethods.open:
        final session = params['session']! as String;
        if (legacy) {
          return {'session': session, 'start': 0, 'count': 0, 'items': []};
        }
        return (_slimmers[session] = LinkSessionSlimmer()).encode(
          _snapshot(session, choices: _choices()),
          full: true,
        );
      case LinkMethods.close:
      case LinkMethods.closeGroup:
        return null;
      case LinkMethods.openGroup:
        return {'group': params['group'], 'messages': []};
      default:
        actions.add((method, params));
        return reply?.call(method, params);
    }
  }

  void update(
    String session, {
    List<LinkChoice>? choices,
    bool live = false,
    Map<String, Object?>? context,
  }) {
    _host.emit(
      LinkEvents.session,
      _slimmers[session]!.encode(
        _snapshot(
          session,
          choices: choices ?? _choices(),
          live: live,
          context: context,
        ),
      ),
    );
  }

  void expectChoice(int index, String session, String kind, String option) {
    expect(actions[index].$1, LinkMethods.choose);
    expect(actions[index].$2, {
      'session': session,
      'kind': kind,
      'option': option,
    });
  }

  LinkSessionUpdate _snapshot(
    String session, {
    required List<LinkChoice> choices,
    bool live = false,
    Map<String, Object?>? context,
  }) => LinkSessionUpdate(
    session: session,
    start: 0,
    count: 0,
    items: const [],
    choices: choices,
    live: live,
    context: context,
  );
}

class _Connection extends ChangeNotifier implements DesktopHostConnection {
  _Connection(this.peer);

  @override
  final LinkPeer peer;
  @override
  bool get busy => false;
  @override
  String? get error => null;
  @override
  String? get pendingCode => null;
  @override
  String get hostName => 'Fixture Host';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
