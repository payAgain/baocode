import 'dart:async';
import 'dart:io';

import 'package:bao_link/bao_link.dart';
import 'package:bonsoir/bonsoir.dart';

bool get desktopRemoteDiscoverySupported =>
    Platform.isMacOS || Platform.isWindows || Platform.isLinux;

/// Browses the host's existing Bonjour service only while subscribed.
Stream<List<LinkAdvert>> discoverDesktopRemoteHosts() {
  late StreamController<List<LinkAdvert>> snapshots;
  BonsoirDiscovery? discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? events;
  Future<void>? opening;
  var ending = false;
  final found = <String>{};
  final adverts = <String, LinkAdvert>{};

  void publish() => snapshots.add(List.unmodifiable(adverts.values));

  void end([Object? error, StackTrace? stack]) {
    if (ending) return;
    ending = true;
    if (error != null) snapshots.addError(error, stack);
    unawaited(snapshots.close());
  }

  Future<void> resolve(
    BonsoirService service,
    BonsoirDiscovery discovery,
  ) async {
    try {
      await service.resolve(discovery.serviceResolver);
    } on Object {
      // One service can disappear mid-resolution; other hosts still work.
    }
  }

  void handle(BonsoirDiscoveryEvent event, BonsoirDiscovery discovery) {
    if (ending) return;
    if (event is BonsoirDiscoveryStoppedEvent) {
      end();
      return;
    }
    final service = event.service;
    if (service == null ||
        service.type.toLowerCase().replaceFirst(RegExp(r'\.$'), '') !=
            LinkDiscovery.type) {
      return;
    }
    final name = service.name;
    if (event is BonsoirDiscoveryServiceLostEvent) {
      found.remove(name);
      if (adverts.remove(name) != null) publish();
      return;
    }
    if (event is BonsoirDiscoveryServiceFoundEvent) {
      // The platform already has a resolution in flight on repeated browse
      // updates. Resolve a new service instance once, not on every TXT event.
      if (found.add(name) && service.hostAddresses.isEmpty) {
        unawaited(resolve(service, discovery));
      }
    } else if (!found.contains(name) ||
        (event is! BonsoirDiscoveryServiceResolvedEvent &&
            event is! BonsoirDiscoveryServiceUpdatedEvent)) {
      return;
    }
    final advert = LinkAdvert.parse(
      name: name,
      port: service.port,
      attributes: service.attributes,
      addresses: List.unmodifiable({
        for (final address in service.hostAddresses)
          if (!address.contains('%') &&
              InternetAddress.tryParse(address) != null)
            address,
      }),
    );
    if (advert == null || advert.addrs.isEmpty) {
      if (adverts.remove(name) != null) publish();
      return;
    }
    adverts[name] = advert;
    publish();
  }

  Future<void> open() async {
    try {
      final browser = discovery = BonsoirDiscovery(
        type: LinkDiscovery.type,
        printLogs: false,
      );
      await browser.initialize();
      if (ending) return;
      events = browser.eventStream!.listen(
        (event) => handle(event, browser),
        onError: end,
        onDone: end,
      );
      await browser.start();
    } on Object catch (error, stack) {
      end(error, stack);
    }
  }

  Future<void> cancel() async {
    ending = true;
    await opening;
    try {
      await events?.cancel();
    } finally {
      if (discovery case final browser? when browser.isReady) {
        await browser.stop();
      }
    }
  }

  snapshots = StreamController(
    onListen: () => opening = open(),
    onCancel: cancel,
  );
  return snapshots.stream;
}
