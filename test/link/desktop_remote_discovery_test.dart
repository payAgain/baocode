import 'dart:async';

import 'package:bao_link/bao_link.dart';
import 'package:baocode/link/desktop_remote_discovery_io.dart';
import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final messenger =
      TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;
  const channel = MethodChannel('fr.skyost.bonsoir');
  const codec = StandardMethodCodec();
  late MethodChannel events;
  final calls = <MethodCall>[];
  Future<void> Function()? onInitialize;

  setUp(() {
    calls.clear();
    onInitialize = null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'discovery.initialize') {
        final id = call.arguments['id'];
        events = MethodChannel('${channel.name}.discovery.$id');
        messenger.setMockMethodCallHandler(events, (_) async => null);
        await onInitialize?.call();
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(events, null);
  });

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  Future<void> send(String id, BonsoirService service) async {
    await messenger.handlePlatformMessage(
      events.name,
      codec.encodeSuccessEnvelope({'id': id, 'service': service.toJson()}),
      null,
    );
    await flush();
  }

  test(
    'browse resolves BaoCode services and drops lost or invalid records',
    () async {
      final browse = discoverDesktopRemoteHosts();
      expect(calls, isEmpty);
      final snapshots = <List<LinkAdvert>>[];
      final sub = browse.listen(snapshots.add);
      addTearDown(sub.cancel);
      await flush();
      expect(calls.map((call) => call.method), [
        'discovery.initialize',
        'discovery.start',
      ]);
      expect(calls.first.arguments['type'], LinkDiscovery.type);

      final key = LinkIdentity.generate().publicKey;
      final advert = LinkAdvert(
        name: 'My Mac',
        key: key,
        port: 47100,
        pairing: true,
      );
      final unresolved = BonsoirService(
        name: advert.name,
        type: LinkDiscovery.type,
        port: 0,
      );
      await send('discoveryServiceFound', unresolved);
      expect(calls.last.method, 'discovery.resolveService');
      expect(snapshots, isEmpty);
      await send('discoveryServiceUpdated', unresolved);
      expect(
        calls.where((call) => call.method == 'discovery.resolveService'),
        hasLength(1),
      );
      final resolved = BonsoirService(
        name: advert.name,
        type: LinkDiscovery.type,
        port: advert.port,
        attributes: advert.attributes,
        hostAddresses: const [
          '2001:db8::1',
          '192.0.2.10',
          'fe80::1%en0',
          'fe80::2',
          'bad.local',
        ],
      );
      await send('discoveryServiceResolved', resolved);
      expect(snapshots.last.single.id, advert.id);
      expect(snapshots.last.single.pairing, isTrue);
      expect(snapshots.last.single.addrs, [
        '192.0.2.10:47100',
        '[2001:db8::1]:47100',
      ]);

      final updated = resolved.copyWith(
        attributes: {...advert.attributes, 'p': '0'},
        hostAddresses: const ['192.0.2.42'],
      );
      await send('discoveryServiceUpdated', updated);
      expect(snapshots.last.single.pairing, isFalse);
      expect(snapshots.last.single.addrs, ['192.0.2.42:47100']);
      await send(
        'discoveryServiceUpdated',
        updated.copyWith(attributes: {...advert.attributes, 'v': '1'}),
      );
      expect(snapshots.last, isEmpty);

      await send('discoveryServiceUpdated', updated);
      expect(snapshots.last.single.id, advert.id);
      await send('discoveryServiceLost', unresolved);
      expect(snapshots.last, isEmpty);
      await send('discoveryServiceResolved', resolved);
      expect(snapshots.last, isEmpty);

      await sub.cancel();
      expect(calls.last.method, 'discovery.stop');
    },
  );

  test(
    'stopping during initialization never starts the native browse',
    () async {
      final release = Completer<void>();
      onInitialize = () => release.future;
      final sub = discoverDesktopRemoteHosts().listen((_) {});
      await flush();
      final stopping = sub.cancel();
      release.complete();
      await stopping;
      expect(calls.map((call) => call.method), [
        'discovery.initialize',
        'discovery.stop',
      ]);
    },
  );
}
