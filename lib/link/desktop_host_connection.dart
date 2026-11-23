import 'dart:async';

import 'package:bao_link/bao_link.dart';
import 'package:flutter/foundation.dart';

import '../models/secret_store.dart';
import 'computer_group.dart';
import 'link_host.dart';
import 'desktop_remote_discovery_stub.dart'
    if (dart.library.io) 'desktop_remote_discovery_io.dart'
    as discovery;

/// Compatibility type for callers removing the retired 1:1 UI.
typedef DesktopSavedHost = ({String id, String name});

/// One outgoing workspace connection, authorized by local group membership.
class DesktopHostConnection extends ChangeNotifier {
  DesktopHostConnection({LinkHost? localHost})
    : this._(
        discovery.desktopRemoteDiscoverySupported
            ? discovery.discoverDesktopRemoteHosts
            : null,
        localHost,
      );

  @visibleForTesting
  DesktopHostConnection.withDependencies({
    SecretStore? store,
    Future<LinkNode> Function(LinkIdentity, List<String>)? bind,
    Future<DeviceInfo> Function()? device,
    Stream<List<LinkAdvert>> Function()? discover,
    LinkHost? localHost,
  }) : this._(discover, localHost);

  DesktopHostConnection._(this._discover, this.localHost) {
    localHost?.addListener(_groupChanged);
  }

  final Stream<List<LinkAdvert>> Function()? _discover;
  final LinkHost? localHost;
  bool _disposed = false;
  bool _busy = false;
  String? _error;
  String? _member;
  LinkPeer? _peer;
  Object? _dial;
  StreamSubscription<List<LinkAdvert>>? _discovery;
  List<LinkAdvert> _adverts = const [];
  String? _discoveryError;
  Object? _browse;

  bool get busy => _busy;
  String? get error => _error;
  String? get hostName => localHost?.computerGroup?.known[_member]?.name;
  String? get selectedHostId => _member;
  bool get groupSelected => _member != null;

  // Legacy desktop calls never read, migrate, modify, or use their old keys.
  List<DesktopSavedHost> get savedHosts => const [];
  List<LinkAdvert> get nearbyHosts => const [];
  String? get pendingCode => null;
  String? get pendingReverseCode => null;
  Object? get pendingMutualAttempt => null;
  bool get pendingNeedsApproval => false;
  bool get waitingForHostApproval => false;
  Future<void> selectHost(String _) async {}
  Future<void> pair(String _) async => _retired();
  Future<void> pairMutually(String _) async => _retired();
  Future<void> pairNearby(String _) async => _retired();
  Future<void> pairNearbyMutually(String _) async => _retired();
  Future<void> confirm() async {}
  Future<void> cancelMutualAttempt(Object _) async {}
  Future<void> cancelPairing() async {}
  Future<void> forget() async {}
  Future<void> forgetHost(String _) async {}

  void _retired() {
    if (_disposed) return;
    _error = 'Use My computers to connect to this computer.';
    _notify();
  }

  bool get discoverySupported => _discover != null;
  bool get discovering => _browse != null;
  String? get discoveryError => _discoveryError;

  /// Only advertised group invitations. Names and routes are unverified hints.
  List<LinkAdvert> get nearbyGroupHosts {
    final hosts = <String, LinkAdvert>{};
    for (final advert in _adverts) {
      if (advert.groupInviting &&
          advert.id != localHost?.id &&
          advert.addrs.isNotEmpty) {
        hosts[advert.id] = advert;
      }
    }
    return List.unmodifiable(hosts.values);
  }

  /// Dials only a selected, currently visible group invitation.
  /// The returned preview must be confirmed through [LinkHost.confirmGroupJoin].
  Future<ComputerGroupJoinPreview> prepareNearbyGroup(String id) async {
    final host = localHost;
    final browse = _browse;
    LinkAdvert? current() => _browse == browse
        ? nearbyGroupHosts.where((advert) => advert.id == id).firstOrNull
        : null;
    final advert = current();
    if (_disposed || browse == null || advert == null || host == null) {
      throw ComputerGroupWire.rejected;
    }
    return host.prepareNearbyGroupJoin(
      advert,
      stillVisible: () => current() != null,
    );
  }

  /// A visible view owns the browse and stops it when leaving. Opening the
  /// app, loading membership and receiving network requests never start it.
  void startDiscovery() {
    final discover = _discover;
    if (_disposed || discovering || discover == null) return;
    final browse = _browse = Object();
    _discoveryError = null;
    try {
      _discovery = discover().listen(
        (adverts) {
          if (_browse != browse) return;
          _adverts = adverts;
          _notify();
        },
        onError: (Object _) {
          if (_browse == browse) _discoveryFailed();
        },
        onDone: () {
          if (_browse == browse) _discoveryFailed();
        },
      );
    } on Object {
      _discoveryFailed();
      return;
    }
    _notify();
  }

  Future<void> stopDiscovery() => _stopDiscovery();

  Future<void> _stopDiscovery({String? error}) async {
    final subscription = _discovery;
    final changed = discovering || _discoveryError != error;
    _discovery = null;
    _browse = null;
    _adverts = const [];
    _discoveryError = error;
    if (changed) _notify();
    await subscription?.cancel().catchError((Object _) {});
  }

  void _discoveryFailed() => unawaited(
    _stopDiscovery(
      error: 'Could not search the local network for nearby computers.',
    ),
  );

  /// Available only while its signed membership still authorizes a workspace.
  LinkPeer? get peer {
    final peer = _peer;
    return peer != null &&
            !peer.isClosed &&
            localHost?.permitsGroupWorkspace(peer.remote) == true
        ? peer
        : null;
  }

  Future<void> load() async {}

  Future<void> reconnect() async {
    if (_member case final id?) await selectGroupMember(id);
  }

  Future<void> selectGroupMember(String id) async {
    final host = localHost;
    if (_disposed ||
        _dial != null ||
        host == null ||
        !host.permitsGroupWorkspace(id) ||
        (_member == id && peer != null)) {
      return;
    }
    final dial = _dial = Object();
    _member = id;
    _busy = true;
    _error = null;
    final previous = _peer;
    _peer = null;
    _notify();
    try {
      await previous?.close();
      if (_dial != dial) return;
      final connected = await host.openGroupWorkspace(
        id,
        nearby: {
          for (final advert in _adverts)
            if (advert.id == id) ...advert.addrs,
        },
      );
      if (_dial != dial || !host.permitsGroupWorkspace(id)) {
        await connected.close();
        return;
      }
      _peer = connected;
      unawaited(
        connected.done.then((_) {
          if (_peer != connected) return;
          _peer = null;
          _error = 'The connection to the computer ended.';
          _notify();
        }),
      );
    } on Object {
      if (_dial == dial) _error = 'Could not reach the group computer.';
    } finally {
      if (_dial == dial) {
        _dial = null;
        _busy = false;
        _notify();
      }
    }
  }

  void _groupChanged() {
    if (_member case final id?
        when localHost?.permitsGroupWorkspace(id) != true) {
      _dial = null;
      _busy = false;
      final old = _peer;
      _peer = null;
      unawaited(old?.close());
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _dial = null;
    localHost?.removeListener(_groupChanged);
    unawaited(stopDiscovery());
    unawaited(_peer?.close());
    _peer = null;
    super.dispose();
  }
}
