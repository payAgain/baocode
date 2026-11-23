import 'dart:async';
import 'dart:convert';

import 'package:bao_link/bao_link.dart';
import 'package:baocode/link/computer_group.dart';
import 'package:baocode/link/link_host.dart';
import 'package:flutter_test/flutter_test.dart';

import 'desktop_mutual_pairing_test.dart' show Machine, machines, tick;

void main() {
  test('nearby preparation does not enable sharing on the joiner', () async {
    final (sponsor, joiner) = await machines();
    await joiner.host.setEnabled(false);
    await sponsor.host.createComputerGroup();
    sponsor.host.createGroupInvite(nearby: true);
    await sponsor.host.advertising;
    final advert = sponsor.platform.advertised.single;
    joiner.client.startDiscovery();
    joiner.adverts.add([foundAdvert(advert)]);
    await tick();
    await expectLater(
      joiner.client.prepareNearbyGroup(advert.id),
      throwsA(isA<LinkRemoteException>()),
    );
    expect(joiner.host.enabled, isFalse);
    expect(joiner.host.groupConnectionsAvailable, isFalse);
    expect(joiner.platform.keptComputerGroup, isNull);
    expect(sponsor.host.pendingGroupApproval, isNull);
  });

  test('nearby invitation expiration withdraws the advert and invalidates the link', () async {
    final (_, joiner) = await machines();
    final sponsor = Machine(
      joiner.network,
      'Expiring invite',
      offerLifetime: const Duration(milliseconds: 250),
    );
    addTearDown(sponsor.close);
    await sponsor.host.load();
    await sponsor.host.createComputerGroup();
    final invite = sponsor.host.createGroupInvite(nearby: true);
    await sponsor.host.advertising;
    expect(sponsor.platform.advertised.single.groupInviting, isTrue);
    final expired = Completer<void>();
    void changed() {
      if (!sponsor.host.invitingNearbyGroupMembers && !expired.isCompleted) {
        expired.complete();
      }
    }

    sponsor.host.addListener(changed);
    try {
      await expired.future.timeout(const Duration(seconds: 3));
    } finally {
      sponsor.host.removeListener(changed);
    }
    await sponsor.host.advertising;
    expect(sponsor.platform.advertised, isEmpty);
    await expectLater(
      joiner.host.prepareGroupJoin(invite),
      throwsA(isA<LinkRemoteException>()),
    );
    expect(sponsor.host.pendingGroupApproval, isNull);
  });

  test(
    'nearby preview reveals only the authenticated sponsor and challenge',
    () async {
      final (sponsor, joiner) = await machines();
      await sponsor.host.createComputerGroup();
      sponsor.host.createGroupInvite(nearby: true);
      final peer = await LinkPeer.connect(
        await joiner.platform.node!.connect(LinkAddress(sponsor.host.id)),
      );
      addTearDown(peer.close);
      final response = await peer.call(ComputerGroupWire.prepareNearby) as Map;
      expect(response.keys, ['invite']);
      expect(sponsor.host.pendingGroupApproval, isNull);
      await expectLater(
        peer.call(LinkMethods.state),
        throwsA(isA<LinkRemoteException>()),
      );
    },
  );

  test('nearby challenges are bound to the original connection', () async {
    final (sponsor, joiner) = await machines();
    await sponsor.host.createComputerGroup();
    final manual = sponsor.host.createGroupInvite(nearby: true);
    final node = joiner.platform.node!;
    Future<LinkPeer> dial() async {
      final peer = await LinkPeer.connect(
        await node.connect(LinkAddress(sponsor.host.id)),
      );
      addTearDown(peer.close);
      return peer;
    }

    final original = await dial();
    final reply = await original.call(ComputerGroupWire.prepareNearby) as Map;
    final challenge = reply['invite'] as String;
    expect(challenge, isNot(manual));
    final identity = LinkIdentity.fromJson(
      joiner.platform.kept['identity']! as Map<String, Object?>,
    )!;
    final payload = jsonDecode(
      utf8.decode(decodeKey(Uri.parse(challenge).pathSegments.last)),
    ) as List;
    final consent = ComputerGroupConsent.sign(
      payload[0] as String,
      sponsor.host.id,
      payload[2] as String,
      ComputerGroupMember(
        id: identity.id,
        name: 'Synthetic joiner',
        addrs: const [],
        relays: const [],
        direct: true,
      ),
      identity,
    );
    final other = await dial();
    await expectLater(
      other.call(ComputerGroupWire.join, {'consent': consent.toJson()}),
      throwsA(isA<LinkRemoteException>()),
    );
    expect(sponsor.host.pendingGroupApproval, isNull);
    expect(sponsor.host.computerGroup!.active.keys, [sponsor.host.id]);
  });

  test('nearby joins require both approvals over an authenticated LAN connection', () async {
    final (sponsor, joiner) = await machines();
    await sponsor.host.setEnabled(false);
    await sponsor.host.enableGroupConnections();
    await sponsor.host.createComputerGroup();
    final invite = sponsor.host.createGroupInvite(nearby: true);
    expect(invite, startsWith('baocode-group://join/'));
    await sponsor.host.advertising;
    final advert = sponsor.platform.advertised.single;
    expect(advert.attributes.keys, unorderedEquals(['v', 'k', 'p', 'g']));
    expect(advert.attributes['g'], '1');
    expect(advert.pairing, isFalse);
    final found = LinkAdvert.parse(
      name: 'Unauthenticated display name',
      port: advert.port,
      attributes: advert.attributes,
      addresses: const ['192.168.1.5'],
    )!;
    final clientApi = joiner.client;
    await joiner.client.load();
    expect(joiner.adverts.hasListener, isFalse);
    expect(clientApi.nearbyGroupHosts, isEmpty);
    await expectLater(
      clientApi.prepareNearbyGroup(found.id),
      throwsA(isA<LinkRemoteException>()),
    );
    joiner.client.startDiscovery();
    joiner.adverts.add([found]);
    await tick();
    expect(clientApi.nearbyGroupHosts, [found]);
    final ComputerGroupJoinPreview preview = await clientApi.prepareNearbyGroup(
      found.id,
    );
    expect(preview.sponsor.id, sponsor.host.id);
    expect(preview.sponsor.name, sponsor.name);
    expect(joiner.host.computerGroup, isNull);
    expect(sponsor.host.pendingGroupApproval, isNull);
    expect(sponsor.host.computerGroup!.active.keys, [sponsor.host.id]);
    expect(sponsor.host.enabled, isFalse);
    // Discovery's transient lifetime does not own the already verified preview.
    await joiner.client.stopDiscovery();
    expect(clientApi.nearbyGroupHosts, isEmpty);
    final requested = approvalFrom(sponsor.host);
    final joining = joiner.host.confirmGroupJoin(preview);
    final approval = await requested;
    expect(approval.member.id, joiner.host.id);
    expect(approval.code, preview.code);
    expect(sponsor.host.computerGroup!.active.keys, [sponsor.host.id]);
    expect(joiner.host.computerGroup, isNull);
    await sponsor.host.approveGroupJoin(approval);
    await joining;
    for (final (viewer, owner) in [(joiner, sponsor), (sponsor, joiner)]) {
      await viewer.client.selectGroupMember(owner.host.id);
      expect(viewer.client.peer?.remote, owner.host.id);
      expect(await viewer.client.peer!.call(LinkMethods.state), isA<Map>());
      expect(viewer.host.phones, isEmpty);
    }
    await sponsor.host.advertising;
    expect(sponsor.platform.advertised, isEmpty);
    expect(joiner.host.computerGroup!.id, sponsor.host.computerGroup!.id);
    await expectLater(
      joiner.host.prepareGroupJoin(invite),
      throwsA(isA<LinkRemoteException>()),
    );
  });

  test('nearby admission refuses stale, off-LAN and uninvited peers', () async {
    final (sponsor, joiner) = await machines();
    final api = sponsor.host;
    final clientApi = joiner.client;
    const prepare = ComputerGroupWire.prepareNearby;
    await sponsor.host.createComputerGroup();
    sponsor.host.createGroupInvite();
    final node = joiner.platform.node!;
    Future<LinkPeer> dial() async =>
        LinkPeer.connect(await node.connect(LinkAddress(sponsor.host.id)));
    final unsolicited = await dial();
    addTearDown(unsolicited.close);
    await expectLater(
      unsolicited.call(prepare),
      throwsA(isA<LinkRemoteException>()),
    );
    api.createGroupInvite(nearby: true);
    await sponsor.host.advertising;
    final advert = sponsor.platform.advertised.single;
    final found = LinkAdvert.parse(
      name: advert.name,
      port: advert.port,
      attributes: advert.attributes,
      addresses: const ['192.168.1.5'],
    )!;
    joiner.client.startDiscovery();
    joiner.adverts.add([found]);
    await tick();
    sponsor.network.path = const LinkPath(LinkPathKind.relay);
    await expectLater(
      clientApi.prepareNearbyGroup(found.id),
      throwsA(isA<LinkRemoteException>()),
    );
    sponsor.network.path = const LinkPath(LinkPathKind.lan);
    final ComputerGroupJoinPreview preview = await clientApi.prepareNearbyGroup(
      found.id,
    );
    api.cancelGroupInvite();
    await expectLater(joiner.host.confirmGroupJoin(preview), throwsA(anything));
    await expectLater(
      clientApi.prepareNearbyGroup(found.id),
      throwsA(isA<LinkRemoteException>()),
    );
    expect(sponsor.host.pendingGroupApproval, isNull);
    expect(sponsor.host.computerGroup!.active.keys, [sponsor.host.id]);
    expect(joiner.host.computerGroup, isNull);
  });
}

LinkAdvert foundAdvert(LinkAdvert advert) => LinkAdvert.parse(
  name: advert.name,
  port: advert.port,
  attributes: advert.attributes,
  addresses: const ['192.168.1.5'],
)!;

Future<ComputerGroupApproval> approvalFrom(LinkHost host) {
  final result = Completer<ComputerGroupApproval>();
  void changed() {
    if (host.pendingGroupApproval case final request?) {
      host.removeListener(changed);
      if (!result.isCompleted) result.complete(request);
    }
  }

  host.addListener(changed);
  return result.future
      .timeout(const Duration(seconds: 5))
      .whenComplete(() => host.removeListener(changed));
}
