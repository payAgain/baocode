import 'dart:convert';

import 'package:bao_link/bao_link.dart';
import 'package:baocode/link/computer_group.dart';
import 'package:flutter_test/flutter_test.dart';

import 'desktop_mutual_pairing_test.dart' show machines;

void main() {
  for (final system in ['macOS 26.1', 'Ubuntu 24.04 LTS', 'Windows 11 Pro']) {
    test('$system legacy desktop authority is dormant and preserved', () async {
      final (host, _) = await machines();
      final desktop = LinkIdentity.generate();
      final mutual = LinkIdentity.generate();
      final phone = LinkIdentity.generate();
      Map<String, Object?> paired(LinkIdentity key, String os) => {
        'key': encodeKey(key.publicKey),
        'name': 'Synthetic device',
        'system': os,
        'pairedAt': 1,
      };
      final desktopRecord = paired(desktop, system);
      final grants = [
        {
          'client': mutual.id,
          'host': LinkIdentity.generate().id,
          'name': 'Old desktop',
        },
      ];
      host.platform.kept = {
        ...host.platform.kept,
        'phones': [desktopRecord, paired(phone, 'iOS 26.2')],
        'desktopGrants': grants,
      };
      await host.restart();
      for (final old in [desktop, mutual]) {
        final node = host.network.node(old.id);
        addTearDown(node.close);
        final peer = await LinkPeer.connect(
          await node.connect(LinkAddress(host.host.id)),
        );
        addTearDown(peer.close);
        await expectLater(
          peer.call(LinkMethods.hello, {
            'name': 'iPhone',
            'system': 'iOS 26.2',
          }),
          throwsA(isA<LinkRemoteException>()),
        );
        await expectLater(
          peer.call(LinkMethods.state),
          throwsA(isA<LinkRemoteException>()),
        );
        await expectLater(
          peer.call(ComputerGroupWire.open),
          throwsA(isA<LinkRemoteException>()),
        );
      }
      final node = host.network.node(phone.id);
      addTearDown(node.close);
      final peer = await LinkPeer.connect(
        await node.connect(LinkAddress(host.host.id)),
      );
      addTearDown(peer.close);
      expect(await peer.call(LinkMethods.hello), isA<Map>());
      expect(await peer.call(LinkMethods.state), isA<Map>());
      await expectLater(
        peer.call(ComputerGroupWire.open),
        throwsA(isA<LinkRemoteException>()),
      );
      await host.host.setEnabled(false);
      expect(host.platform.kept['desktopGrants'], grants);
      expect(host.platform.kept['phones'], contains(desktopRecord));
      expect(host.host.computerGroup, isNull);
    });
  }

  test(
    'both old outgoing stores survive without dialing or migration',
    () async {
      final (owner, viewer) = await machines();
      final offer = (await owner.host.beginPairing())!;
      final saved = {
        'identity': LinkIdentity.generate().toJson(),
        'name': offer.name,
        'address': offer.address.toJson(),
        'direct': true,
      };
      final v1 = jsonEncode(saved);
      final v2 = jsonEncode({
        'hosts': [saved],
        'selected': owner.host.id,
      });
      await viewer.store.write('desktop_host_connection.v1', v1);
      await viewer.store.write('desktop_host_connection.v2', v2);
      await viewer.restart();
      await viewer.client.reconnect();
      await viewer.client.selectHost(owner.host.id);
      await viewer.client.pair(offer.uri);
      await viewer.client.pairMutually(offer.uri);
      await viewer.client.forget();
      expect(viewer.clientIds, isEmpty);
      expect(viewer.client.peer, isNull);
      expect(viewer.client.savedHosts, isEmpty);
      expect(owner.host.pending, isNull);
      expect(viewer.host.computerGroup, isNull);
      expect(await viewer.store.read('desktop_host_connection.v1'), v1);
      expect(await viewer.store.read('desktop_host_connection.v2'), v2);
    },
  );
}
