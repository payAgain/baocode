import 'dart:async';
import 'dart:convert';

import 'package:bao_link/bao_link.dart';
import 'package:baocode/link/desktop_host_connection.dart';
import 'package:baocode/link/link_host.dart';
import 'package:baocode/models/secret_store.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_link_platform.dart';

void main() {
  late FakeLinkPlatform platform;
  late Workspace workspace;
  late LinkHost host;
  late _ClientStore store;
  late DesktopHostConnection client;
  late List<MemoryLinkNode> clientNodes;
  late Future<void> Function()? beforeBind;
  late StreamController<List<LinkAdvert>> discovery;
  late List<LinkAddress> dials;
  late bool Function(LinkAddress)? canDial;

  DesktopHostConnection newClient() => DesktopHostConnection.withDependencies(
    store: store,
    discover: () => discovery.stream,
    bind: (identity, relays) async {
      await beforeBind?.call();
      final node = platform.network.node(identity.id, relays: relays);
      clientNodes.add(node);
      return _DialNode(node, (address) async {
        dials.add(address);
        if (canDial?.call(address) == false) {
          throw const LinkClosedException('unreachable');
        }
        return node.connect(address);
      });
    },
    device: () async => const DeviceInfo(
      name: 'Client Desktop',
      kind: 'linux',
      system: 'Test OS',
    ),
  );

  setUp(() async {
    platform = FakeLinkPlatform()
      ..kept = {'relayMode': 'direct', 'discoverable': false};
    workspace = Workspace.mock();
    host = LinkHost(workspace: workspace, platform: platform);
    await host.load();
    store = _ClientStore();
    clientNodes = [];
    beforeBind = null;
    discovery = StreamController<List<LinkAdvert>>.broadcast();
    dials = [];
    canDial = null;
    client = newClient();
  });

  tearDown(() async {
    client.dispose();
    await discovery.close();
    await host.setEnabled(false);
    host.dispose();
    workspace.dispose();
  });

  Future<LinkAdvert> showNearbyHost() async {
    final offer = (await host.beginPairing())!;
    final advert = LinkAdvert(
      name: 'Advertised Mac',
      key: offer.key,
      port: 47100,
      pairing: true,
      addresses: const ['192.168.1.5'],
    );
    client.startDiscovery();
    discovery.add([advert]);
    await Future<void>.delayed(Duration.zero);
    return advert;
  }

  test('selecting a nearby host requires both users to approve', () async {
    await client.load();
    expect(discovery.hasListener, isFalse);
    final advert = await showNearbyHost();
    expect(client.nearbyHosts.map((host) => host.id), [advert.id]);
    expect(clientNodes, isEmpty);
    await client.pairNearby(advert.id);

    expect(client.pendingNeedsApproval, isTrue);
    expect(host.pending?.needsApproval, isTrue);
    expect(client.pendingCode, host.pending!.code.join('  '));
    expect(client.peer, isNull);
    expect(store.records, isEmpty);
    final confirmation = client.confirm();
    await Future<void>.delayed(Duration.zero);
    expect(client.waitingForHostApproval, isTrue);
    expect(host.phones, isEmpty);
    expect(client.peer, isNull);
    expect(store.records, isEmpty);

    host.approvePending();
    await confirmation.timeout(const Duration(seconds: 2));
    expect(client.waitingForHostApproval, isFalse);
    expect(client.pendingCode, isNull);
    expect(client.peer?.remote, advert.id);
    expect(host.phones.single.id, clientNodes.single.id);
    expect(await client.peer!.call(LinkMethods.state), isA<Map>());
  });

  test(
    'cancelling a nearby pairing rolls back a racing host approval',
    () async {
      final advert = await showNearbyHost();
      await client.pairNearby(advert.id);
      final confirmation = client.confirm();
      await Future<void>.delayed(Duration.zero);
      expect(client.waitingForHostApproval, isTrue);
      host.approvePending();
      expect(host.phones, hasLength(1));
      await client.cancelPairing();
      await confirmation;
      expect(client.pendingCode, isNull);
      expect(client.peer, isNull);
      expect(store.records, isEmpty);
      expect(host.phones, isEmpty);
    },
  );

  test(
    'stopping discovery invalidates stale selections without dialing',
    () async {
      final advert = await showNearbyHost();
      await client.stopDiscovery();
      expect(discovery.hasListener, isFalse);
      expect(client.nearbyHosts, isEmpty);
      await client.pairNearby(advert.id);
      expect(client.error, contains('no longer available'));
      expect(dials, isEmpty);
    },
  );

  test(
    'rejected nearby pairing never authorizes or saves the client',
    () async {
      final advert = await showNearbyHost();
      await client.pairNearby(advert.id);
      final confirmation = client.confirm();
      await Future<void>.delayed(Duration.zero);
      host.rejectPending();
      await confirmation;
      expect(client.error, contains('rejected'));
      expect(client.pendingCode, isNull);
      expect(client.peer, isNull);
      expect(host.phones, isEmpty);
      expect(store.records, isEmpty);
    },
  );

  test('a discovery failure leaves the literal invite usable', () async {
    final advert = await showNearbyHost();
    expect(client.nearbyHosts.single.id, advert.id);
    discovery.addError(StateError('private platform details'));
    await Future<void>.delayed(Duration.zero);
    expect(client.discoveryError, isNot(contains('private')));
    expect(client.discoveryError, isNotNull);
    expect(client.discovering, isFalse);
    expect(client.nearbyHosts, isEmpty);
    await client.pair(host.offer!.uri);
    await client.confirm();
    expect(client.peer?.remote, advert.id);
  });

  test(
    'literal invite requires comparing the codes and explicit confirmation',
    () async {
      final offer = (await host.beginPairing())!;
      await client.pair(offer.uri);

      expect(client.error, isNull);
      expect(client.busy, isFalse);
      expect(client.peer, isNull);
      expect(host.phones, isEmpty);
      expect(store.records.isEmpty, isTrue);
      final clientId = clientNodes.single.id;
      expect(clientId, isNot(host.id));
      expect(clientNodes.single.relays, isEmpty);
      expect(host.pending?.needsApproval, isFalse);
      expect(host.pending?.name, 'Client Desktop');
      expect(client.pendingCode == host.pending!.code.join('  '), isTrue);
      expect(
        client.pendingCode ==
            safetyCode(offer.key, keyOfDeviceId(clientId)!).join('  '),
        isTrue,
      );

      await client.confirm();
      expect(client.error, isNull);
      expect(client.pendingCode, isNull);
      expect(client.hostName, 'Test Mac');
      expect(client.peer?.remote, host.id);
      expect(host.phones.single.id, clientId);
      expect(await client.peer!.call(LinkMethods.state), isA<Map>());
      final kept = store.records.values.single;
      expect(kept.contains(offer.uri), isFalse);
      expect(kept.contains(encodeKey(offer.token)), isFalse);
    },
  );

  Future<void> pairAndConfirm() async {
    final offer = (await host.beginPairing())!;
    await client.pair(offer.uri);
    await client.confirm();
    expect(client.peer?.remote, host.id);
  }

  test('load reconnects as the same client without a fresh invite', () async {
    await pairAndConfirm();
    final first = client.peer!;
    final clientId = host.phones.single.id;
    expect(host.offer, isNull);
    client.dispose();
    await first.done;

    client = newClient();
    await client.load();

    expect(client.error, isNull);
    expect(client.hostName, 'Test Mac');
    expect(client.pendingCode, isNull);
    expect(clientNodes.last.id, clientId);
    expect(host.phones.single.id, clientId);
    expect(host.isConnected(clientId), isTrue);
    expect(await client.peer!.call(LinkMethods.state), isA<Map>());
  });

  test('a matching LAN advert retries an offline saved identity', () async {
    await pairAndConfirm();
    final savedId = clientNodes.single.id;
    final oldPeer = client.peer!;
    client.dispose();
    await oldPeer.done;

    const moved = '192.168.2.70:47222';
    canDial = (address) => address.addrs.firstOrNull == moved;
    client = newClient();
    await client.load();
    expect(client.peer, isNull);
    expect(discovery.hasListener, isFalse);
    final failedDials = dials.length;
    client.startDiscovery();

    discovery.add([
      LinkAdvert(
        name: 'Test Mac',
        key: LinkIdentity.generate().publicKey,
        port: 47222,
        pairing: true,
        addresses: const ['192.168.2.70'],
      ),
    ]);
    await Future<void>.delayed(Duration.zero);
    expect(dials, hasLength(failedDials));

    final reconnected = Completer<void>();
    client.addListener(() {
      if (client.peer != null && !reconnected.isCompleted) {
        reconnected.complete();
      }
    });
    discovery.add([
      LinkAdvert(
        name: 'Unverified update',
        key: keyOfDeviceId(host.id)!,
        port: 47222,
        addresses: const ['192.168.2.70'],
      ),
    ]);
    await reconnected.future.timeout(const Duration(seconds: 2));
    expect(dials, hasLength(failedDials + 1));
    expect(dials.last.id, host.id);
    expect(dials.last.relays, isEmpty);
    expect(client.hostName, 'Test Mac');
    expect(clientNodes.last.id, savedId);
    expect(host.phones.single.id, savedId);
  });

  test('the invite relay is retained for reconnect', () async {
    const relay = 'https://relay.invalid';
    await host.pinRelay(relay);
    await pairAndConfirm();
    expect(clientNodes.single.relays, [relay]);
    expect(dials.single.relays, [relay, ...defaultLinkRelays]);

    final connected = client.peer!;
    client.dispose();
    await connected.done;
    client = newClient();
    await client.load();
    expect(clientNodes.last.relays, [relay]);
    expect(dials.last.relays, [relay, ...defaultLinkRelays]);
    expect(client.peer?.remote, host.id);
  });

  test('network failure preserves pairing for retry', () async {
    await pairAndConfirm();
    final connection = client.peer!;
    await host.setEnabled(false);
    await connection.done;

    await client.reconnect();
    expect(client.peer, isNull);
    expect(client.hostName, 'Test Mac');
    expect(client.error, contains('reach'));
    expect(store.records.length, 1);
    await expectLater(clientNodes.last.changes.isEmpty, completion(isTrue));

    await host.setEnabled(true);
    await client.reconnect();
    expect(client.error, isNull);
    expect(client.peer?.remote, host.id);
  });

  test(
    'live revocation removes the saved host and closes the client',
    () async {
      await pairAndConfirm();
      final oldPeer = client.peer!;
      final idle = Completer<void>();
      client.addListener(() {
        if (!client.busy && client.hostName == null && !idle.isCompleted) {
          idle.complete();
        }
      });
      final closed = clientNodes.last.changes.isEmpty;
      host.unpair(host.phones.single);

      await idle.future.timeout(const Duration(seconds: 2));
      await oldPeer.done;
      expect(await closed, isTrue);
      expect(client.peer, isNull);
      expect(client.error, contains('removed your access'));
      expect(store.records.isEmpty, isTrue);
    },
  );

  test('reconnect handles revocation while the client was offline', () async {
    await pairAndConfirm();
    final oldPeer = client.peer!;
    client.dispose();
    await oldPeer.done;
    host.unpair(host.phones.single);

    client = newClient();
    await client.load();

    expect(client.peer, isNull);
    expect(client.hostName, isNull);
    expect(client.error, contains('removed your access'));
    expect(store.records.isEmpty, isTrue);
    await expectLater(clientNodes.last.changes.isEmpty, completion(isTrue));
  });

  test(
    'forget unpairs and clears the persisted desktop client identity',
    () async {
      await pairAndConfirm();
      final oldPeer = client.peer!;
      final firstId = clientNodes.last.id;
      await client.forget();
      await oldPeer.done;
      expect(client.peer, isNull);
      expect(client.hostName, isNull);
      expect(host.phones, isEmpty);
      expect(store.records.isEmpty, isTrue);
      await expectLater(clientNodes.last.changes.isEmpty, completion(isTrue));

      client.dispose();
      client = newClient();
      final previousBinds = clientNodes.length;
      await client.load();
      expect(clientNodes.length, previousBinds);
      await pairAndConfirm();
      expect(clientNodes.last.id, isNot(firstId));
    },
  );

  test('cancel closes the pending pairing without granting access', () async {
    final offer = (await host.beginPairing())!;
    await client.pair(offer.uri);
    expect(client.pendingCode, isNotNull);
    final closed = clientNodes.last.changes.isEmpty;
    await client.cancelPairing();
    await client.confirm();

    expect(client.pendingCode, isNull);
    expect(client.peer, isNull);
    expect(host.pending, isNull);
    expect(host.phones, isEmpty);
    expect(store.records.isEmpty, isTrue);
    expect(await closed, isTrue);
  });

  test(
    'cancel during a pending bind prevents the late node from dialing',
    () async {
      final offer = (await host.beginPairing())!;
      final started = Completer<void>();
      final release = Completer<void>();
      beforeBind = () {
        started.complete();
        return release.future;
      };
      final pairing = client.pair(offer.uri);
      await started.future;
      await client.cancelPairing();
      release.complete();
      await pairing;

      expect(client.peer, isNull);
      expect(client.pendingCode, isNull);
      expect(client.busy, isFalse);
      expect(clientNodes.single.connections, isEmpty);
      await expectLater(clientNodes.single.changes.isEmpty, completion(isTrue));
    },
  );

  test('malformed, expired and wrapped invites never dial', () async {
    final offer = (await host.beginPairing())!;
    final expired = PairingOffer(
      name: offer.name,
      key: offer.key,
      token: offer.token,
      expires: DateTime.fromMillisecondsSinceEpoch(0),
    );
    for (final invite in [
      'Join this machine: ${offer.uri}',
      '${offer.uri}&d=duplicate',
      '${offer.uri}#extra',
      expired.uri,
    ]) {
      await client.pair(invite);
      expect(client.error, isNotNull);
      expect(client.error!.contains(encodeKey(offer.token)), isFalse);
      expect(client.peer, isNull);
    }
    expect(clientNodes, isEmpty);
    expect(store.records.isEmpty, isTrue);
  });

  test(
    'a wrong invite token never grants access or leaves a node open',
    () async {
      final offer = (await host.beginPairing())!;
      final wrong = PairingOffer(
        name: offer.name,
        key: offer.key,
        token: offer.token.sublist(0)..[0] ^= 1,
        expires: offer.expires,
        addrs: offer.addrs,
        direct: true,
      );
      await client.pair(wrong.uri);
      expect(client.error, contains('no longer valid'));
      expect(client.peer, isNull);
      expect(client.pendingCode, isNull);
      expect(host.pending, isNull);
      expect(store.records.isEmpty, isTrue);
      await expectLater(clientNodes.single.changes.isEmpty, completion(isTrue));
    },
  );

  test('storage failure rolls back the confirmed host pairing', () async {
    final offer = (await host.beginPairing())!;
    await client.pair(offer.uri);
    store.failWrites = true;
    await client.confirm();

    expect(client.error, contains('save'));
    expect(client.peer, isNull);
    expect(client.hostName, isNull);
    expect(host.phones, isEmpty);
    expect(store.records.isEmpty, isTrue);
    await expectLater(clientNodes.single.changes.isEmpty, completion(isTrue));
  });

  test(
    'pairing stays private if a storage write cannot be read back',
    () async {
      final offer = (await host.beginPairing())!;
      await client.pair(offer.uri);
      store.dropWrites = true;
      await client.confirm();

      expect(client.error, contains('save'));
      expect(client.peer, isNull);
      expect(client.hostName, isNull);
      expect(host.phones, isEmpty);
    },
  );

  test(
    'revocation during persistence cannot expose a peer or keep its key',
    () async {
      final offer = (await host.beginPairing())!;
      await client.pair(offer.uri);
      final started = Completer<void>();
      final release = Completer<void>();
      store.beforeWrite = () {
        started.complete();
        return release.future;
      };
      final confirmation = client.confirm();
      await started.future;
      expect(client.peer, isNull);
      host.unpair(host.phones.single);
      release.complete();
      await confirmation;

      expect(client.error, contains('removed your access'));
      expect(client.peer, isNull);
      expect(client.hostName, isNull);
      expect(store.records.isEmpty, isTrue);
    },
  );

  test('cancel while loading protected storage prevents any dial', () async {
    final offer = (await host.beginPairing())!;
    final started = Completer<void>();
    final release = Completer<void>();
    store.beforeRead = () {
      started.complete();
      return release.future;
    };
    final pairing = client.pair(offer.uri);
    await started.future;
    await client.cancelPairing();
    release.complete();
    await pairing;

    expect(clientNodes, isEmpty);
    expect(client.pendingCode, isNull);
  });

  test('a saved computer is preserved until the user forgets it', () async {
    await pairAndConfirm();
    final saved = client.peer;
    final next = (await host.beginPairing())!;
    await client.pair(next.uri);
    expect(client.error, contains('Forget'));
    expect(client.peer, same(saved));
    expect(clientNodes.length, 1);
    final record = jsonDecode(store.records.values.single) as Map;
    expect(record.keys.toSet(), {'identity', 'name', 'address', 'direct'});
  });
}

class _DialNode implements LinkNode {
  _DialNode(this.node, this.dial);

  final MemoryLinkNode node;
  final Future<LinkConnection> Function(LinkAddress) dial;

  @override
  String get id => node.id;

  @override
  Stream<LinkConnection> get incoming => node.incoming;

  @override
  Future<LinkConnection> connect(
    LinkAddress address, {
    Duration timeout = const Duration(seconds: 15),
  }) => dial(address);

  @override
  Future<LinkNodeInfo> info() => node.info();

  @override
  Stream<LinkNodeInfo> get changes => node.changes;

  @override
  void networkChanged() => node.networkChanged();

  @override
  Future<void> close() => node.close();
}

class _ClientStore implements SecretStore {
  final records = <String, String>{};
  bool failWrites = false;
  bool dropWrites = false;
  Future<void> Function()? beforeRead;
  Future<void> Function()? beforeWrite;

  @override
  Future<String?> read(String id) async {
    await beforeRead?.call();
    return records[id];
  }

  @override
  Future<void> write(String id, String value) async {
    await beforeWrite?.call();
    if (failWrites) throw const SecretStoreException('Test write failure');
    if (!dropWrites) records[id] = value;
  }

  @override
  Future<void> delete(String id) async => records.remove(id);
}
