import 'dart:async';

import 'package:bao_link/bao_link.dart';
import 'package:baocode/link/desktop_host_connection.dart';
import 'package:baocode/link/desktop_mutual_pairing.dart';
import 'package:baocode/link/link_host.dart';
import 'package:baocode/models/secret_store.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_link_platform.dart';

void main() {
  test(
    'retired mutual protocol cannot use either phone pairing path',
    () async {
      final (owner, viewer) = await machines();
      final offer = (await owner.host.beginPairing())!;
      final peer = await LinkPeer.connect(
        await viewer.platform.node!.connect(LinkAddress(owner.host.id)),
      );
      addTearDown(peer.close);
      for (final params in [
        {'token': encodeKey(offer.token)},
        {'request': true},
      ]) {
        await expectLater(
          peer.call(LinkMethods.hello, {
            ...params,
            'capabilities': {DesktopMutualPairing.capability: 1},
          }),
          throwsA(isA<LinkRemoteException>()),
        );
      }
      for (final method in [
        DesktopMutualPairing.prepare,
        DesktopMutualPairing.consent,
        DesktopMutualPairing.link,
        DesktopMutualPairing.reverse,
        DesktopMutualPairing.grant,
        DesktopMutualPairing.abort,
        LinkMethods.confirm,
      ]) {
        await expectLater(
          peer.call(method),
          throwsA(isA<LinkRemoteException>()),
        );
      }
      expect(owner.host.pending, isNull);
      expect(owner.host.phones, isEmpty);
    },
  );
}

Future<void> tick() => Future<void>.delayed(Duration.zero);

Future<(Machine, Machine)> machines() async {
  final network = MemoryLinkNetwork();
  final a = Machine(network, 'First Mac');
  final b = Machine(network, 'Second Mac');
  addTearDown(a.close);
  addTearDown(b.close);
  await Future.wait([a.host.load(), b.host.load()]);
  return (a, b);
}

class Machine {
  Machine(
    this.network,
    this.name, {
    this.offerLifetime = const Duration(minutes: 10),
  }) {
    create();
  }
  final MemoryLinkNetwork network;
  final String name;
  final Duration offerLifetime;
  late final TestMachinePlatform platform = TestMachinePlatform(network, name);
  final workspace = Workspace.mock();
  final store = MemorySecretStore();
  final clientIds = <String>{};
  final adverts = StreamController<List<LinkAdvert>>.broadcast();
  late LinkHost host;
  late DesktopHostConnection client;
  bool workbenchOwnsClient = false;

  void create() {
    host = LinkHost(
      workspace: workspace,
      platform: platform,
      offerLifetime: offerLifetime,
    );
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

class TestMachinePlatform extends FakeLinkPlatform {
  TestMachinePlatform(this._sharedNetwork, this.name) {
    kept = {'enabled': true, 'relayMode': 'direct', 'discoverable': false};
  }
  @override
  MemoryLinkNetwork get network => _sharedNetwork;
  final MemoryLinkNetwork _sharedNetwork;
  final String name;
  Future<void> Function()? beforeGroupWrite;

  @override
  Future<void> writeComputerGroup(Object json) async {
    await beforeGroupWrite?.call();
    await super.writeComputerGroup(json);
  }

  @override
  Future<DeviceInfo> device() async =>
      DeviceInfo(name: name, kind: 'mac', system: 'macOS 26.1');
}
