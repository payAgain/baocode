import 'dart:async';
import 'dart:convert';

import 'package:bao_link/bao_link.dart';
import 'package:bao_markdown/bao_markdown.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/link/desktop_host_chats.dart';
import 'package:baocode/link/desktop_host_connection.dart';
import 'package:baocode/link/desktop_host_page.dart';
import 'package:baocode/models/secret_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _firstId =
    '0101010101010101010101010101010101010101010101010101010101010101';
const _secondId =
    '0202020202020202020202020202020202020202020202020202020202020202';
const _storeKey = 'desktop_host_connection.v2';
const _legacyKey =
    'desktop_host_'
    'connection.v1';
const _desktopPlatforms = TargetPlatformVariant({
  TargetPlatform.macOS,
  TargetPlatform.windows,
});

void main() {
  testWidgets('Add computer opens pairing without forgetting a saved host', (
    tester,
  ) async {
    final store = MemorySecretStore();
    await store.write(
      _legacyKey,
      jsonEncode(_record(_firstId, 'My saved computer')),
    );
    final connection = DesktopHostConnection.withDependencies(
      store: store,
      bind: (_, _) async => throw const LinkClosedException('offline fixture'),
      device: () async => throw StateError('offline fixture'),
    );
    final chats = DesktopHostChats();
    await connection.load();
    final record = await store.read(_storeKey) ?? await store.read(_legacyKey);
    await tester.pumpWidget(_page(connection, chats));
    expect(find.text('My saved computer').hitTestable(), findsOneWidget);
    expect(find.text('Pairing link'), findsNothing);

    await tester.tap(find.text('Add computer'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField).hitTestable(), findsOneWidget);
    expect(find.text('Pairing link'), findsOneWidget);
    expect(connection.hostName, 'My saved computer');
    expect(await store.read(_storeKey) ?? await store.read(_legacyKey), record);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Pairing link'), findsNothing);
    expect(find.text('My saved computer').hitTestable(), findsOneWidget);
    expect(connection.hostName, 'My saved computer');
    await tester.pumpWidget(const SizedBox.shrink());
    connection.dispose();
    chats.dispose();
  }, variant: _desktopPlatforms);

  testWidgets('canceling a safety code shows the previous saved computer', (
    tester,
  ) async {
    final network = MemoryLinkNetwork();
    final nearby = _Host(network, _secondId);
    final discovery = StreamController<List<LinkAdvert>>.broadcast();
    final store = MemorySecretStore();
    await store.write(
      _legacyKey,
      jsonEncode(_record(_firstId, 'Offline computer')),
    );
    final connection = _connection(
      store,
      network,
      discover: () => discovery.stream,
    );
    final chats = DesktopHostChats();
    await connection.load();
    await tester.pumpWidget(_page(connection, chats));
    await tester.tap(find.text('Add computer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nearby computers'));
    discovery.add([
      LinkAdvert(
        name: 'Nearby fixture',
        key: keyOfDeviceId(_secondId)!,
        port: 47100,
        pairing: true,
        addresses: const ['127.0.0.1'],
      ),
    ]);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nearby fixture'));
    await tester.pumpAndSettle();
    expect(find.text('Compare Safety Codes'), findsOneWidget);
    await tester.tap(find.text('Cancel pairing'));
    await _finishConnection(tester, connection);
    await tester.pumpAndSettle();
    expect(find.text('Pairing link'), findsNothing);
    expect(find.text('Offline computer').hitTestable(), findsOneWidget);
    expect(connection.savedHosts.map((host) => host.id), [_firstId]);
    expect(connection.selectedHostId, _firstId);

    await tester.pumpWidget(const SizedBox.shrink());
    connection.dispose();
    chats.dispose();
    await nearby.close();
    await discovery.close();
  }, variant: _desktopPlatforms);

  testWidgets('canceling host approval preserves the previous computer draft', (
    tester,
  ) async {
    final network = MemoryLinkNetwork();
    final first = _Host(network, _firstId);
    final approval = Completer<Map<String, Object?>>();
    final nearby = _Host(network, _secondId, confirmation: approval.future);
    final discovery = StreamController<List<LinkAdvert>>.broadcast();
    final store = MemorySecretStore();
    await store.write(
      _legacyKey,
      jsonEncode(_record(_firstId, 'Shared computer')),
    );
    final connection = _connection(
      store,
      network,
      discover: () => discovery.stream,
    );
    final chats = DesktopHostChats();
    void bind() => chats.bind(connection.peer);
    connection.addListener(bind);
    await connection.load();
    await tester.pumpWidget(_page(connection, chats));
    await tester.pumpAndSettle();
    await tester.tap(find.text('First conversation'));
    await tester.pumpAndSettle();
    final editor = find.byType(MarkdownEditor);
    await tester.tap(editor);
    await tester.pump();
    const draft = 'Still mine';
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(text: draft),
    );
    await tester.pump();

    await tester.tap(find.text('Add computer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nearby computers'));
    discovery.add([
      LinkAdvert(
        name: 'Nearby fixture',
        key: keyOfDeviceId(_secondId)!,
        port: 47100,
        pairing: true,
        addresses: const ['127.0.0.1'],
      ),
    ]);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nearby fixture'));
    await _finishConnection(tester, connection);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Codes match, pair'));
    await tester.pump();
    expect(connection.waitingForHostApproval, isTrue);
    await tester.tap(find.text('Cancel pairing'));
    await _finishConnection(tester, connection);
    await tester.pumpAndSettle();
    expect(connection.peer?.remote, _firstId);
    expect(tester.state<MarkdownEditorState>(editor).controller.text, draft);

    approval.complete(const {});
    await tester.pumpWidget(const SizedBox.shrink());
    connection.removeListener(bind);
    connection.dispose();
    chats.dispose();
    await first.close();
    await nearby.close();
    await discovery.close();
  }, variant: _desktopPlatforms);

  testWidgets('forgetting one computer leaves the other selectable', (
    tester,
  ) async {
    final network = MemoryLinkNetwork();
    final second = _Host(network, _secondId);
    final store = await _twoComputers();
    final connection = _connection(store, network);
    final chats = DesktopHostChats();
    await connection.load();
    await tester.pumpWidget(_page(connection, chats));

    await tester.tap(find.text('Computers'));
    await tester.pumpAndSettle();
    final firstRow = find.ancestor(
      of: find.text(fingerprintOf(keyOfDeviceId(_firstId)!)),
      matching: find.byType(ListTile),
    );
    await tester.tap(
      find.descendant(of: firstRow, matching: find.byTooltip('Forget host')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Forget host'));
    await tester.pumpAndSettle();
    expect(connection.savedHosts.map((host) => host.id), [_secondId]);
    expect(connection.selectedHostId, _secondId);

    if (connection.peer == null) {
      await tester.tap(find.text('Computers'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(ListTile),
          matching: find.text('Shared computer'),
        ),
      );
      await _finishConnection(tester, connection);
      await tester.pumpAndSettle();
    }
    expect(connection.peer?.remote, _secondId);
    expect(second.calls, isNot(contains(LinkMethods.unpair)));

    await tester.pumpWidget(const SizedBox.shrink());
    connection.dispose();
    chats.dispose();
    await second.close();
  }, variant: _desktopPlatforms);

  testWidgets(
    'a stale active-host confirmation cannot forget a same-name host',
    (tester) async {
      final network = MemoryLinkNetwork();
      final connection = _connection(await _twoComputers(), network);
      final chats = DesktopHostChats();
      await connection.load();
      await tester.pumpWidget(_page(connection, chats));
      await tester.tap(find.byTooltip('Host options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Forget host'));
      await tester.pumpAndSettle();

      await connection.selectHost(_secondId);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Forget host'),
        ),
      );
      await tester.pumpAndSettle();
      expect(connection.savedHosts.map((host) => host.id), [
        _firstId,
        _secondId,
      ]);
      expect(connection.selectedHostId, _secondId);
      await tester.pumpWidget(const SizedBox.shrink());
      connection.dispose();
      chats.dispose();
    },
    variant: _desktopPlatforms,
  );

  testWidgets(
    'the chooser cancels without switching and isolates same-name drafts',
    (tester) async {
      final network = MemoryLinkNetwork();
      final first = _Host(network, _firstId);
      final second = _Host(network, _secondId);
      final store = await _twoComputers();
      final connection = _connection(store, network);
      final chats = DesktopHostChats();
      void bind() => chats.bind(connection.peer);
      connection.addListener(bind);
      await connection.load();
      await tester.pumpWidget(_page(connection, chats));
      await tester.pumpAndSettle();

      await tester.tap(find.text('First conversation'));
      await tester.pumpAndSettle();
      final editor = find.byType(MarkdownEditor);
      await tester.tap(editor);
      await tester.pump();
      const draft = 'Unsent on the first computer';
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: draft,
          selection: TextSelection.collapsed(offset: draft.length),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Computers'));
      await tester.pumpAndSettle();
      expect(find.text('Shared computer'), findsNWidgets(2));
      final secondFingerprint = find.text(
        fingerprintOf(keyOfDeviceId(_secondId)!),
      );
      expect(secondFingerprint.hitTestable(), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(connection.peer?.remote, _firstId);
      expect(second.calls, isEmpty);
      expect(tester.state<MarkdownEditorState>(editor).controller.text, draft);

      await tester.tap(find.text('Computers'));
      await tester.pumpAndSettle();
      final previous = connection.peer!;
      await tester.tap(secondFingerprint);
      await _finishConnection(tester, connection);
      expect(connection.peer?.remote, _secondId);
      expect(previous.isClosed, isTrue);
      await tester.pumpAndSettle();
      expect(find.text('First conversation'), findsNothing);
      await tester.tap(find.text('Second conversation'));
      await tester.pumpAndSettle();
      expect(
        tester.state<MarkdownEditorState>(editor).controller.text,
        isEmpty,
      );
      expect(first.calls.where((call) => call == LinkMethods.send), isEmpty);
      expect(second.calls.where((call) => call == LinkMethods.send), isEmpty);

      await tester.tap(find.text('Computers'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(fingerprintOf(keyOfDeviceId(_firstId)!)));
      await _finishConnection(tester, connection);
      await tester.pumpAndSettle();
      expect(connection.peer?.remote, _firstId);
      await tester.tap(find.text('First conversation'));
      await tester.pumpAndSettle();
      expect(tester.state<MarkdownEditorState>(editor).controller.text, draft);

      await tester.pumpWidget(const SizedBox.shrink());
      connection.removeListener(bind);
      connection.dispose();
      chats.dispose();
      await first.close();
      await second.close();
    },
    variant: _desktopPlatforms,
  );
}

Future<void> _finishConnection(
  WidgetTester tester,
  DesktopHostConnection connection,
) async {
  // Dart's broadcast subscription cancellation can complete outside the
  // widget's fake clock. Give both zones a chance to settle before asserting.
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (!connection.busy) return;
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }
  expect(connection.busy, isFalse, reason: connection.error);
}

Future<MemorySecretStore> _twoComputers() async {
  final store = MemorySecretStore();
  await store.write(
    _storeKey,
    jsonEncode({
      'selected': _firstId,
      'hosts': [
        for (final id in [_firstId, _secondId]) _record(id, 'Shared computer'),
      ],
    }),
  );
  return store;
}

Map<String, Object?> _record(String id, String name) => {
  'identity': LinkIdentity.generate().toJson(),
  'name': name,
  'address': LinkAddress(id).toJson(),
  'direct': true,
};

DesktopHostConnection _connection(
  MemorySecretStore store,
  MemoryLinkNetwork network, {
  Stream<List<LinkAdvert>> Function()? discover,
}) => DesktopHostConnection.withDependencies(
  store: store,
  bind: (identity, relays) async => network.node(identity.id, relays: relays),
  device: () async =>
      const DeviceInfo(name: 'Client', kind: 'desktop', system: 'test'),
  discover: discover,
);

class _Host {
  _Host(
    MemoryLinkNetwork network,
    String id, {
    Future<Map<String, Object?>>? confirmation,
  }) : node = network.node(id) {
    incoming = node.incoming.listen((link) async {
      peers.add(
        await LinkPeer.accept(
          link,
          onRequest: (method, params) {
            calls.add(method);
            return switch (method) {
              LinkMethods.hello => {
                'device': _device.toJson(),
                if (params['request'] == true) ...{
                  'pairing': true,
                  'approval': true,
                },
              },
              LinkMethods.confirm => confirmation,
              LinkMethods.state => LinkState(
                device: _device,
                projects: const [
                  ProjectInfo(
                    id: 'shared-project',
                    name: 'Shared project',
                    path: '/test',
                  ),
                ],
                sessions: [
                  SessionSummary(
                    id: 'shared-chat',
                    project: 'shared-project',
                    title: id == _firstId
                        ? 'First conversation'
                        : 'Second conversation',
                    updatedAt: DateTime(2026),
                  ),
                ],
              ).toJson(),
              LinkMethods.open => LinkSessionUpdate(
                session: 'shared-chat',
                start: 0,
                count: 0,
                items: [],
              ).toJson(),
              _ => null,
            };
          },
        ),
      );
    });
  }

  static const _device = DeviceInfo(
    name: 'Shared computer',
    kind: 'desktop',
    system: 'test',
    direct: true,
  );
  final MemoryLinkNode node;
  final calls = <String>[];
  final peers = <LinkPeer>[];
  late final StreamSubscription<LinkConnection> incoming;

  Future<void> close() async {
    unawaited(incoming.cancel());
    for (final peer in peers) {
      await peer.close();
    }
    await node.close();
  }
}

Widget _page(DesktopHostConnection connection, DesktopHostChats chats) =>
    MaterialApp(
      localizationsDelegates: const [AppLocalizations.delegate],
      home: Scaffold(
        body: DesktopHostPage(
          connection: connection,
          chats: chats,
          onBack: () {},
        ),
      ),
    );
