import 'dart:async';

import 'package:bao_link/bao_link.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/link/desktop_host_connection.dart';
import 'package:baocode/link/desktop_host_page.dart';
import 'package:baocode/link/desktop_mutual_pairing.dart';
import 'package:baocode/link/link_host.dart';
import 'package:baocode/models/secret_store.dart';
import 'package:baocode/settings/app_locale.dart';
import 'package:baocode/settings/app_settings.dart';
import 'package:baocode/settings/pages/mobile_page.dart';
import 'package:baocode/workbench.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_link_platform.dart';

void main() {
  testWidgets('workspace and Mobile settings approve the same two codes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1550, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final (a, b) = await machines();
    final locale = AppLocale();
    addTearDown(locale.dispose);
    a.host.desktopClient = null;
    var created = 0;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Row(
            children: [
              Expanded(
                child: Workbench(
                  workspace: a.workspace,
                  settings: AppSettings(locale: locale, link: a.host),
                  createDesktopHostConnection: () {
                    created++;
                    a.workbenchOwnsClient = true;
                    return a.client;
                  },
                ),
              ),
              Expanded(child: MobileSettingsPage(host: b.host)),
            ],
          ),
        ),
      ),
    );
    expect(a.host.desktopClient, isNotNull);
    expect(created, 0);
    await tester.tap(find.text('Switch to remote workspace'));
    await tester.pump();
    expect(created, 1);
    expect(
      tester.widget<DesktopHostPage>(find.byType(DesktopHostPage)).connection,
      same(a.client),
    );
    final showInvite = find.text('Show QR Code');
    await tester.ensureVisible(showInvite);
    await tester.pump();
    await tester.tap(showInvite.hitTestable());
    await tester.pump();
    final offer = b.host.offer!;
    await tester.pump();
    await tester.tap(find.text('Pair with mutual workspace access'));
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, offer.uri);
    await tester.pump();
    await tester.tap(find.text('Pair'));
    await tester.pumpAndSettle();
    expect(b.host.pending, isNotNull, reason: a.client.error);
    expect(a.client.pendingReverseCode, b.host.pending!.reverseCode);
    expect(find.text(a.client.pendingReverseCode!), findsNWidgets(2));
    await tester.tap(find.text('Codes match, trust both computers'));
    await tester.pump();
    expect(a.client.peer, isNull);
    expect(find.text('Cancel pairing').hitTestable(), findsWidgets);
    final approve = find.text('Trust both computers');
    expect(approve.hitTestable(), findsOneWidget);
    await tester.tap(approve);
    await tester.pumpAndSettle();
    expect(a.client.peer?.remote, b.host.id, reason: a.client.error);
    expect(b.client.savedHosts.single.id, a.host.id);
    expect(find.text('Mutual workspace access is ready'), findsOneWidget);
    await Future.wait([a.client.peer!.close(), b.client.peer!.close()]);
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(a.host.desktopClient, isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  test('one invite and two local approvals grant the real bridge in both directions', () async {
    final (a, b) = await machines();
    final offer = (await b.host.beginPairing())!;
    await a.client.pairMutually(offer.uri);
    final pending = b.host.pending!;
    expect(pending.mutual, isTrue);
    expect(a.client.pendingCode, pending.code.join('  '));

    // Ordinary approval cannot be substituted for mutual consent.
    b.host.approvePending();
    final confirming = a.client.confirm();
    await tick();
    expect(a.client.waitingForHostApproval, isTrue);
    expect(a.client.peer, isNull);
    expect(a.client.savedHosts, isEmpty);
    expect(b.clientIds, isEmpty);
    expect(a.host.desktopGrants, isEmpty);
    expect(b.host.desktopGrants, isEmpty);
    expect(a.store.writes, 0);
    expect(b.store.writes, 0);

    b.host.approveMutual(pending);
    await confirming;
    expect(a.client.error, isNull);
    expect(a.client.peer!.remote, b.host.id);
    expect(b.client.peer!.remote, a.host.id);
    expect(a.host.desktopGrants.single.clientId, b.clientIds.single);
    expect(b.host.desktopGrants.single.clientId, a.clientIds.single);
    expect({
      a.host.id,
      b.host.id,
      ...a.clientIds,
      ...b.clientIds,
    }, hasLength(4));
    expect(a.host.phones, isEmpty);
    expect(b.host.phones, isEmpty);
    for (final (viewer, owner) in [(a, b), (b, a)]) {
      final peer = viewer.client.peer!;
      final state = LinkState.fromJson(
        (await peer.call(LinkMethods.state))! as Map<String, Object?>,
      );
      final thread = state.sessions.first;
      final name = 'Renamed from ${viewer.name}';
      await peer.call(LinkMethods.rename, {
        'session': thread.id,
        'title': name,
      });
      expect(
        owner.workspace.threads.any((local) => local.title == name),
        isTrue,
      );
      expect(
        viewer.workspace.threads.any((local) => local.title == name),
        isFalse,
      );
    }

    // Each can resume the same standard saved connection independently.
    await a.restart();
    await b.restart();
    await a.client.reconnect();
    expect(a.client.peer!.remote, b.host.id);
    expect(b.client.peer!.remote, a.host.id);
    expect(a.clientIds, hasLength(1));
    expect(b.clientIds, hasLength(1));
    expect(await a.client.peer!.call(LinkMethods.state), isA<Map>());
    expect(await b.client.peer!.call(LinkMethods.state), isA<Map>());
  });

  test(
    'host approval alone never dials reverse and cancellation clears consent',
    () async {
      final (a, b) = await machines();
      await a.client.pairMutually((await b.host.beginPairing())!.uri);
      final pending = b.host.pending!;
      b.host.approveMutual(pending);
      await tick();
      expect(b.clientIds, isEmpty);
      expect(b.store.writes, 0);
      await a.client.cancelPairing();
      await tick();
      expect(b.host.pending, isNull);
      expect(a.host.desktopGrants, isEmpty);
      expect(b.host.desktopGrants, isEmpty);
      expect(b.clientIds, isEmpty);
    },
  );

  test(
    'cancellation during a grant write removes both records and bridges',
    () async {
      final (a, b) = await machines();
      await a.client.pairMutually((await b.host.beginPairing())!.uri);
      a.platform.grantGate = Completer<void>();
      b.host.approveMutual(b.host.pending!);
      final confirming = a.client.confirm();
      await a.platform.grantStarted.future;
      final cancel = a.client.cancelPairing();
      await tick();
      a.platform.grantGate!.complete();
      await Future.wait([confirming, cancel]);
      await tick();
      for (final machine in [a, b]) {
        expect(machine.host.desktopGrants, isEmpty);
        expect(machine.platform.kept['desktopGrants'], isEmpty);
        expect(machine.client.savedHosts, isEmpty);
        expect(machine.client.peer, isNull);
      }
    },
  );

  test(
    'legacy invite stays one way after an explicit ordinary retry',
    () async {
      final (a, b) = await machines(legacyB: true);
      final offer = (await b.host.beginPairing())!;
      await a.client.pairMutually(offer.uri);
      expect(a.client.pendingCode, isNull);
      expect(a.client.error, contains('one-way'));
      await tick();
      await a.client.pair(offer.uri);
      await a.client.confirm();
      expect(a.client.peer!.remote, b.host.id);
      expect(b.host.phones.single.id, a.clientIds.last);
      expect(a.host.desktopGrants, isEmpty);
      expect(b.clientIds, isEmpty);
    },
  );

  test(
    'a new dial cannot bypass the exact staged reverse peer during grants',
    () async {
      final (a, b) = await machines();
      final identity = LinkIdentity.generate();
      final binding = DesktopPairBinding(
        attempt: encodeKey(randomBytes(16)),
        forwardHost: b.host.id,
        forwardClient: LinkIdentity.generate().id,
        reverseHost: a.host.id,
        reverseClient: identity.id,
      );
      final reservation = a.host.armDesktopReverse(binding, b.name, () => true);
      final node = a.network.node(identity.id);
      addTearDown(node.close);
      Future<LinkPeer> dial() async =>
          LinkPeer.connect(await node.connect(LinkAddress(a.host.id)));
      final staged = await dial();
      await staged.call(DesktopMutualPairing.reverse, binding.toJson());
      await staged.call(DesktopMutualPairing.grant, binding.toJson());
      final other = await dial();
      await expectLater(
        other.call(LinkMethods.hello),
        throwsA(isA<LinkRemoteException>()),
      );
      await a.host.endDesktopReverse(reservation, keep: false);
      await expectLater(
        other.call(LinkMethods.hello),
        throwsA(isA<LinkRemoteException>()),
      );
    },
  );

  test(
    'stopping and restarting local sharing invalidates pending consent',
    () async {
      final (a, b) = await machines();
      await a.client.pairMutually((await b.host.beginPairing())!.uri);
      final confirmed = a.client.confirm();
      await tick();
      await a.host.setEnabled(false);
      await a.host.setEnabled(true);
      if (b.host.pending case final pending?) b.host.approveMutual(pending);
      await confirmed;
      expect(a.client.error, isNotNull);
      expect(b.clientIds, isEmpty);
      expect(a.host.desktopGrants, isEmpty);
      expect(b.host.desktopGrants, isEmpty);
    },
  );

  test(
    'stop sharing revokes this direction, including after restart',
    () async {
      final (a, b) = await machines();
      await a.client.pairMutually((await b.host.beginPairing())!.uri);
      b.host.approveMutual(b.host.pending!);
      await a.client.confirm();
      expect(
        await b.host.removeDesktopGrant(b.host.desktopGrants.single),
        isTrue,
      );
      expect(b.host.desktopMutualStatus, isNot(DesktopMutualStatus.complete));
      await tick();
      expect(a.client.peer, isNull);
      expect(a.client.savedHosts, isEmpty);
      await b.restart();
      expect(b.host.desktopGrants, isEmpty);
      expect(a.host.desktopGrants.single.clientId, b.clientIds.single);
      expect(await b.client.peer!.call(LinkMethods.state), isA<Map>());
    },
  );

  test('failed secure save does not leave a grant or saved host', () async {
    final (a, b) = await machines();
    await a.client.pairMutually((await b.host.beginPairing())!.uri);
    b.store.fail = true;
    b.host.approveMutual(b.host.pending!);
    await a.client.confirm();
    expect(a.client.error, isNotNull);
    expect(a.client.peer, isNull);
    expect(b.client.peer, isNull);
    expect(a.client.savedHosts, isEmpty);
    expect(b.client.savedHosts, isEmpty);
    expect(a.host.desktopGrants, isEmpty);
    expect(b.host.desktopGrants, isEmpty);
  });

  test(
    'the reverse reservation checks the actual key, tuple and exact live peer',
    () async {
      final (a, b) = await machines();
      final reverse = LinkIdentity.generate();
      final binding = DesktopPairBinding(
        attempt: encodeKey(randomBytes(16)),
        forwardHost: b.host.id,
        forwardClient: LinkIdentity.generate().id,
        reverseHost: a.host.id,
        reverseClient: reverse.id,
      );
      Future<LinkPeer> dial(String id) async {
        final node = a.network.node(id);
        addTearDown(node.close);
        return LinkPeer.connect(await node.connect(LinkAddress(a.host.id)));
      }

      final reservation = a.host.armDesktopReverse(binding, b.name, () => true);
      final wrong = await dial(LinkIdentity.generate().id);
      final real = await dial(reverse.id);
      await expectLater(
        wrong.call(DesktopMutualPairing.reverse, binding.toJson()),
        throwsA(isA<LinkRemoteException>()),
      );
      await expectLater(
        real.call(DesktopMutualPairing.grant, binding.toJson()),
        throwsA(isA<LinkRemoteException>()),
      );
      await expectLater(
        real.call(DesktopMutualPairing.reverse, {
          ...binding.toJson(),
          'forwardHost': binding.reverseHost,
        }),
        throwsA(isA<LinkRemoteException>()),
      );
      expect(
        binding.matches(
          await real.call(DesktopMutualPairing.reverse, binding.toJson()),
        ),
        isTrue,
      );
      await expectLater(
        real.call(LinkMethods.state),
        throwsA(isA<LinkRemoteException>()),
      );
      await a.host.endDesktopReverse(reservation, keep: false);
      final replay = await dial(reverse.id);
      await expectLater(
        replay.call(DesktopMutualPairing.reverse, binding.toJson()),
        throwsA(isA<LinkRemoteException>()),
      );
      expect(a.host.desktopGrants, isEmpty);
    },
  );

  test(
    'issuer retains its selected host and can later select the new workspace',
    () async {
      final (a, b) = await machines();
      final c = Machine(a.network, 'Previously selected Mac');
      addTearDown(c.close);
      await c.host.load();
      await b.client.pair((await c.host.beginPairing())!.uri);
      await b.client.confirm();
      final oldPeer = b.client.peer!;
      final offer = (await b.host.beginPairing())!;
      b.host.setDiscoverable(true);
      a.client.startDiscovery();
      a.adverts.add([
        LinkAdvert(
          name: b.name,
          key: offer.key,
          port: 47100,
          pairing: true,
          addresses: const ['192.168.1.5'],
        ),
      ]);
      await tick();
      await a.client.pairNearbyMutually(b.host.id);
      expect(b.host.pending?.mutual, isTrue);
      b.host.approveMutual(b.host.pending!);
      await a.client.confirm();
      expect(a.client.error, isNull);
      expect(oldPeer.isClosed, isTrue);
      expect(b.client.selectedHostId, c.host.id);
      expect(b.client.peer?.remote, c.host.id);
      expect(
        b.client.savedHosts.map((host) => host.id),
        unorderedEquals([a.host.id, c.host.id]),
      );
      await b.client.selectHost(a.host.id);
      expect(await b.client.peer!.call(LinkMethods.state), isA<Map>());
      expect(c.host.phones.single.id, b.clientIds.first);
    },
  );

  test('initiator storage failure preserves the issuer selection and adds no grant', () async {
    final (a, b) = await machines();
    final c = Machine(a.network, 'Previously selected Mac');
    addTearDown(c.close);
    await c.host.load();
    await b.client.pair((await c.host.beginPairing())!.uri);
    await b.client.confirm();
    await a.client.pairMutually((await b.host.beginPairing())!.uri);
    a.store.fail = true;
    b.host.approveMutual(b.host.pending!);
    await a.client.confirm();
    expect(a.client.error, isNotNull);
    expect(a.host.desktopGrants, isEmpty);
    expect(b.host.desktopGrants, isEmpty);
    expect(b.client.savedHosts.single.id, c.host.id);
    expect(b.client.peer?.remote, c.host.id);
  });

  test(
    'failed inbound grant write does not persist or expose either workspace',
    () async {
      final (a, b) = await machines();
      a.platform.failGrants = true;
      await a.client.pairMutually((await b.host.beginPairing())!.uri);
      b.host.approveMutual(b.host.pending!);
      await a.client.confirm();
      for (final machine in [a, b]) {
        expect(machine.host.desktopGrants, isEmpty);
        expect(machine.platform.kept['desktopGrants'], isEmpty);
        expect(machine.client.savedHosts, isEmpty);
        expect(machine.client.peer, isNull);
      }
    },
  );
}

Future<void> tick() => Future<void>.delayed(Duration.zero);

Future<(Machine, Machine)> machines({bool legacyB = false}) async {
  final network = MemoryLinkNetwork();
  final a = Machine(network, 'First Mac');
  final b = Machine(network, 'Second Mac', legacy: legacyB);
  addTearDown(a.close);
  addTearDown(b.close);
  await Future.wait([a.host.load(), b.host.load()]);
  return (a, b);
}

class Machine {
  Machine(this.network, this.name, {this.legacy = false}) {
    create();
  }
  final MemoryLinkNetwork network;
  final String name;
  final bool legacy;
  late final TestMachinePlatform platform = TestMachinePlatform(network, name);
  final workspace = Workspace.mock();
  final store = PairingTestStore();
  final clientIds = <String>{};
  final adverts = StreamController<List<LinkAdvert>>.broadcast();
  late LinkHost host;
  late DesktopHostConnection client;
  bool workbenchOwnsClient = false;

  void create() {
    host = LinkHost(workspace: workspace, platform: platform);
    client = DesktopHostConnection.withDependencies(
      localHost: host,
      store: store,
      bind: (identity, relays) async {
        clientIds.add(identity.id);
        return network.node(identity.id, relays: relays);
      },
      device: platform.device,
      discover: () => adverts.stream,
    );
    if (!legacy) host.desktopClient = () => client;
  }

  Future<void> restart() async {
    client.dispose();
    // Stop without changing the persisted listener setting.
    host.dispose();
    await tick();
    create();
    await host.load();
    await client.load();
  }

  Future<void> close() async {
    if (!workbenchOwnsClient) client.dispose();
    host.dispose();
    await adverts.close();
    workspace.dispose();
  }
}

class PairingTestStore extends MemorySecretStore {
  bool fail = false;
  int writes = 0;
  @override
  Future<void> write(String id, String value) async {
    writes++;
    if (fail) throw StateError('Synthetic write failure');
    await super.write(id, value);
  }
}

class TestMachinePlatform extends FakeLinkPlatform {
  TestMachinePlatform(this._sharedNetwork, this.name) {
    kept = {'enabled': true, 'relayMode': 'direct', 'discoverable': false};
  }
  @override
  MemoryLinkNetwork get network => _sharedNetwork;
  final MemoryLinkNetwork _sharedNetwork;
  final String name;
  bool failGrants = false;
  Completer<void>? grantGate;
  final grantStarted = Completer<void>();

  @override
  Future<DeviceInfo> device() async =>
      DeviceInfo(name: name, kind: 'mac', system: 'Synthetic');

  @override
  Future<void> write(Map<String, Object?> json) async {
    if ((json['desktopGrants'] as List?)?.isNotEmpty == true) {
      if (failGrants) throw StateError('Synthetic host write failure');
      if (grantGate case final gate?) {
        if (!grantStarted.isCompleted) grantStarted.complete();
        await gate.future;
      }
    }
    await super.write(json);
  }
}
