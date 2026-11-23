import 'dart:async';

import 'package:bao_link/bao_link.dart';
import 'package:flutter_test/flutter_test.dart';

import 'desktop_computer_groups_test.dart' show join;
import 'desktop_mutual_pairing_test.dart' show Machine, machines, tick;

void main() {
  test(
    'starting a group blocks preparation of a join while storage is pending',
    () async {
      final (sponsor, local) = await machines();
      await sponsor.host.createComputerGroup();
      final invite = sponsor.host.createGroupInvite();
      final writeStarted = Completer<void>();
      final release = Completer<void>();
      local.platform.beforeGroupWrite = () {
        writeStarted.complete();
        return release.future;
      };
      final creation = local.host.createComputerGroup();
      try {
        await writeStarted.future;
        await expectLater(
          local.host.prepareGroupJoin(invite),
          throwsA(isA<LinkRemoteException>()),
        );
      } finally {
        release.complete();
        await creation;
      }
      expect(local.host.computerGroup!.active.keys, [local.host.id]);
      expect(sponsor.host.pendingGroupApproval, isNull);
    },
  );

  test(
    'a group member can retry an offline peer without changing membership',
    () async {
      final (a, b) = await machines();
      await a.host.createComputerGroup();
      await join(a, b);
      a.network.unreachable.add(a.host.id);
      await b.client.selectGroupMember(a.host.id);
      expect(b.client.selectedHostId, a.host.id);
      expect(b.client.peer, isNull);
      expect(b.client.error, isNotNull);
      a.network.unreachable.remove(a.host.id);
      await b.client.reconnect();
      expect(await b.client.peer!.call(LinkMethods.state), isA<Map>());
      expect(b.client.error, isNull);
    },
  );

  test(
    'selecting another group member closes only the previous workspace',
    () async {
      final (a, b) = await machines();
      final c = Machine(a.network, 'Third Mac');
      addTearDown(c.close);
      await c.host.load();
      await a.host.createComputerGroup();
      await join(a, b);
      await join(a, c);
      await a.client.selectGroupMember(b.host.id);
      final previous = a.client.peer!;
      await a.client.selectGroupMember(c.host.id);
      expect(previous.isClosed, isTrue);
      expect(a.client.peer?.remote, c.host.id);
      expect(await a.client.peer!.call(LinkMethods.state), isA<Map>());
      expect(
        a.host.computerGroup!.active.keys,
        unorderedEquals([a.host.id, b.host.id, c.host.id]),
      );
    },
  );

  test(
    'joined installations cannot replace their group using another invite',
    () async {
      final (a, b) = await machines();
      final c = Machine(a.network, 'Other group');
      addTearDown(c.close);
      await c.host.load();
      await a.host.createComputerGroup();
      await join(a, b);
      final history = b.platform.keptComputerGroup;
      await c.host.createComputerGroup();
      final invite = c.host.createGroupInvite(nearby: true);
      await c.host.advertising;
      final advert = c.platform.advertised.single;
      b.client.startDiscovery();
      b.adverts.add([
        LinkAdvert.parse(
          name: advert.name,
          port: advert.port,
          attributes: advert.attributes,
          addresses: const ['192.168.1.5'],
        )!,
      ]);
      await tick();
      await expectLater(
        b.host.prepareGroupJoin(invite),
        throwsA(isA<LinkRemoteException>()),
      );
      await expectLater(
        b.client.prepareNearbyGroup(c.host.id),
        throwsA(isA<LinkRemoteException>()),
      );
      await expectLater(
        b.host.createComputerGroup(),
        throwsA(isA<LinkRemoteException>()),
      );
      expect(b.platform.keptComputerGroup, history);
      expect(b.host.computerGroup!.id, a.host.computerGroup!.id);
      expect(c.host.pendingGroupApproval, isNull);
    },
  );
}
