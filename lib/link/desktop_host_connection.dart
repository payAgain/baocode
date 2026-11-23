import 'dart:async';
import 'dart:convert';

import 'package:bao_link/bao_link.dart';
import 'package:flutter/foundation.dart';

import '../models/secret_store.dart';
import 'desktop_mutual_pairing.dart';
import 'link_host.dart';
import 'desktop_host_connection_stub.dart'
    if (dart.library.io) 'desktop_host_connection_io.dart'
    as platform;
import 'desktop_remote_discovery_stub.dart'
    if (dart.library.io) 'desktop_remote_discovery_io.dart'
    as discovery;

/// A saved desktop's authenticated ID and display name, without its secrets.
typedef DesktopSavedHost = ({String id, String name});

/// Saved BaoCode desktops, with one outgoing Mobile Link connection at a time.
/// Each pairing has its own client key, independent of the local LinkHost.
class DesktopHostConnection extends ChangeNotifier {
  DesktopHostConnection({LinkHost? localHost})
    : this._(
        SecretStore.instance,
        platform.bindDesktopHostClient,
        platform.desktopHostClientDevice,
        discovery.desktopRemoteDiscoverySupported
            ? discovery.discoverDesktopRemoteHosts
            : null,
        localHost,
      );

  @visibleForTesting
  DesktopHostConnection.withDependencies({
    required SecretStore store,
    required Future<LinkNode> Function(LinkIdentity, List<String>) bind,
    required Future<DeviceInfo> Function() device,
    Stream<List<LinkAdvert>> Function()? discover,
    LinkHost? localHost,
  }) : this._(store, bind, device, discover, localHost);

  DesktopHostConnection._(
    this._store,
    this._bind,
    this._device,
    this._discover,
    this.localHost,
  ) {
    localHost?.addListener(_groupChanged);
  }

  static const _legacyStorageId = 'desktop_host_connection.v1';
  static const _storageId = 'desktop_host_connection.v2';
  static const _revoked =
      'This computer removed your access. Pair again to reconnect.';

  final SecretStore _store;
  final Future<LinkNode> Function(LinkIdentity, List<String>) _bind;
  final Future<DeviceInfo> Function() _device;
  final Stream<List<LinkAdvert>> Function()? _discover;
  final LinkHost? localHost;
  _SavedHosts _saved = const _SavedHosts({}, null);
  _SavedHost? get _selected => _saved.hosts[_saved.selectedId];
  bool _loaded = false;
  bool _disposed = false;
  bool _busy = false;
  bool _preparingPair = false;
  String? _pausedHostId;
  String? _error;
  _ClientSession? _session;
  _PendingHost? _pending;
  Timer? _expiry;
  LinkPeer? _authorized;
  String? _groupMemberId;
  Future<void>? _loss;
  StreamSubscription<List<LinkAdvert>>? _discovery;
  List<LinkAdvert> _adverts = const [];
  ({String id, List<String> addresses})? _lastNearbyRetry;
  String? _discoveryError;
  Object? _browse;

  bool get busy => _busy;
  String? get error => _error;
  String? get pendingCode => _pending?.code;
  String? get pendingReverseCode => _pending?.binding?.reverseCode;
  Object? get pendingMutualAttempt => _pending?.binding;
  bool get pendingNeedsApproval => _pending?.needsApproval ?? false;
  bool get waitingForHostApproval => _session?.waitingForHostApproval ?? false;
  String? get hostName =>
      _pending?.host.name ??
      (_groupMemberId == null
          ? _selected?.name
          : localHost?.computerGroup?.known[_groupMemberId]?.name);
  String? get selectedHostId => _groupMemberId ?? _saved.selectedId;
  bool get groupSelected => _groupMemberId != null;
  List<DesktopSavedHost> get savedHosts => List.unmodifiable(
    _saved.hosts.values.map((host) => (id: host.address.id, name: host.name)),
  );

  /// Nearby computers currently accepting new pairings. Treat their labels
  /// as unverified until both users have compared the safety code.
  List<LinkAdvert> get nearbyHosts {
    final byHost = {for (final advert in _adverts) advert.id: advert};
    return List.unmodifiable(
      byHost.values.where(
        (advert) => advert.pairing && advert.addrs.isNotEmpty,
      ),
    );
  }

  bool get discoverySupported => _discover != null;
  bool get discovering => _browse != null;
  String? get discoveryError => _discoveryError;

  /// The visible remote-host UI owns this browse. Loading a saved host does
  /// not start a browse or prompt for local network access.
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
          _maybeReconnectNearby();
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

  /// Stops the visible browse and discards its transient address hints.
  Future<void> stopDiscovery() => _stopDiscovery();

  Future<void> _stopDiscovery({String? error}) async {
    final discovery = _discovery;
    final changed = discovering || _discoveryError != error;
    _discovery = null;
    _browse = null;
    _adverts = const [];
    _lastNearbyRetry = null;
    _discoveryError = error;
    if (changed) _notify();
    await discovery?.cancel().catchError((Object _) {});
  }

  void _discoveryFailed() => unawaited(
    _stopDiscovery(
      error: 'Could not search the local network for nearby computers.',
    ),
  );

  /// Available only after the host has authorized this connection.
  LinkPeer? get peer {
    final peer = _authorized;
    final session = _session;
    return peer != null &&
            session != null &&
            session.hostId == selectedHostId &&
            !session.ended
        ? peer
        : null;
  }

  /// Restores the selected computer and attempts to reconnect if one is saved.
  Future<void> load() => _run('Could not load the saved computer.', () async {
    if (_loaded) return;
    await _readSaved();
    await _reconnect();
  });

  /// Dials the computer that issued the literal invite and shows the safety
  /// code. Only [confirm] can complete a new pairing.
  Future<void> pair(String invite) => _pairInvite(invite, mutual: false);

  Future<void> pairMutually(String invite) => _pairInvite(invite, mutual: true);

  Future<void> _pairInvite(String invite, {required bool mutual}) =>
      _startPairing('Could not open the invite.', () async {
        final offer = _parseOffer(invite);
        await _beginPairing(
          offer.name,
          offer.address,
          direct: offer.direct,
          token: encodeKey(offer.token),
          expires: offer.expires,
          mutual: mutual,
        );
      });

  /// Dials only a currently visible, explicitly selected pairing advert.
  Future<void> pairNearby(String id) => _pairNearby(id, mutual: false);

  Future<void> pairNearbyMutually(String id) => _pairNearby(id, mutual: true);

  Future<void> _pairNearby(String id, {required bool mutual}) {
    final browse = _browse;
    LinkAdvert currentAdvert() {
      final advert = nearbyHosts.where((advert) => advert.id == id).firstOrNull;
      if (_browse != browse || advert == null) {
        throw const _HostError('This computer is no longer available to pair.');
      }
      return advert;
    }

    return _startPairing('Could not pair with the nearby computer.', () async {
      final advert = currentAdvert();
      await _beginPairing(
        advert.name,
        LinkAddress(advert.id),
        // Discover the route for this dial only. Learn saved addresses and
        // relay policy from the authenticated host.
        direct: true,
        pairingAddresses: () => currentAdvert().addrs,
        mutual: mutual,
      );
    });
  }

  Future<void> _startPairing(String fallback, Future<void> Function() begin) =>
      _run(fallback, () async {
        _preparingPair = true;
        try {
          await _readSaved();
          if (_preparingPair && _session?.pairing != true) await begin();
        } finally {
          _preparingPair = false;
        }
      });

  Future<void> _beginPairing(
    String name,
    LinkAddress address, {
    required bool direct,
    String? token,
    DateTime? expires,
    List<String> Function()? pairingAddresses,
    required bool mutual,
  }) async {
    final local = localHost;
    final shareEpoch = local?.desktopShareEpoch;
    if (mutual && (shareEpoch == null || local!.id == address.id)) {
      throw const _HostError(
        'Enable sharing in Settings → Mobile before pairing mutually.',
      );
    }
    final needsApproval = token == null || mutual;
    if (_saved.hosts.containsKey(address.id)) {
      throw const _HostError('This computer is already saved.');
    }
    if (_session case final session?) {
      await _settle(session);
      if (!_preparingPair) return;
      if (peer != null) _pausedHostId = session.hostId;
      await _drop(session);
      if (!_preparingPair) return;
    }
    final host = _SavedHost(
      LinkIdentity.generate(),
      name.isEmpty ? 'BaoCode' : name,
      address,
      direct: direct,
    );
    await _connect(host, pairing: true, pairingAddresses: pairingAddresses, (
      session,
      peer,
    ) async {
      final answer = await _hello(
        session,
        peer,
        token: token,
        request: token == null,
        mutual: mutual,
      );
      if (mutual &&
          !DesktopMutualPairing.offered(switch (answer) {
            {'capabilities': {DesktopMutualPairing.capability: final value}} =>
              value,
            _ => null,
          })) {
        throw const _HostError(
          'Mutual pairing is unavailable on the other computer. Turn off mutual access to try one-way pairing.',
        );
      }
      if (answer is! Map ||
          answer['pairing'] != true ||
          (answer['approval'] == true) != needsApproval) {
        throw _HostError(
          needsApproval
              ? 'The computer did not accept the nearby pairing request.'
              : 'The computer did not accept the invite.',
        );
      }
      final details = host.updated(_deviceFrom(answer));
      _checkSession(session);
      DesktopPairBinding? binding;
      if (mutual) {
        final attempt = encodeKey(randomBytes(16));
        final preparation = await peer.call(DesktopMutualPairing.prepare, {
          'attempt': attempt,
          'reverseHost': local!.id,
        });
        _checkSession(session);
        if (preparation case {'reverseClient': final String reverseClient}) {
          binding = DesktopPairBinding(
            attempt: attempt,
            forwardHost: peer.remote,
            forwardClient: host.identity.id,
            reverseHost: local.id,
            reverseClient: reverseClient,
          );
        }
        if (binding == null ||
            !binding.valid ||
            !binding.matches(preparation)) {
          throw const _HostError(
            'The return connection did not match the expected identities.',
          );
        }
      }
      if (expires != null) {
        final timeLeft = expires.difference(DateTime.now());
        if (timeLeft <= Duration.zero) {
          throw const _HostError('This invite has expired.');
        }
        _expiry = Timer(
          timeLeft,
          () => unawaited(_endPending(session, expired: true)),
        );
      }
      _pending = _PendingHost(
        details,
        safetyCode(
          keyOfDeviceId(address.id)!,
          host.identity.publicKey,
        ).join('  '),
        expires,
        needsApproval: needsApproval,
        binding: binding,
        shareEpoch: shareEpoch,
      );
    });
  }

  /// The user has compared the code with the host's and says they match.
  Future<void> confirm() => _run('Could not confirm pairing.', () async {
    final pending = _pending;
    final session = _session;
    if (pending == null || session == null) return;
    session.confirming = true;
    _expiry?.cancel();
    _expiry = null;
    try {
      if (pending.expires case final expires?
          when !DateTime.now().isBefore(expires)) {
        throw const _HostError('This invite has expired.');
      }
      final peer = session.peer!;
      if (pending.binding != null) {
        await _confirmMutual(session, peer, pending);
        return;
      }
      session.waitingForHostApproval = pending.needsApproval;
      final confirmation = peer.call(
        LinkMethods.confirm,
        const {},
        pending.needsApproval
            ? const Duration(minutes: 2)
            : const Duration(seconds: 30),
      );
      if (session.waitingForHostApproval) _notify();
      final reply = await confirmation;
      _checkSession(session);
      if (reply case {'pairing': true}) {
        throw const _HostError('The computer did not confirm pairing.');
      }
      try {
        final host = pending.host.updated(_deviceFrom(reply));
        await _save(
          _saved.withHost(host, select: true),
          validate: () => _checkSession(session),
          onCommit: () {
            session.pairing = false;
            session.confirming = false;
            session.waitingForHostApproval = false;
            _pausedHostId = null;
            _groupMemberId = null;
            _clearPending();
            _authorized = peer;
          },
        );
      } on LinkClosedException {
        rethrow;
      } on Object {
        if (!session.cancelled) await _unpair(peer);
        throw const _HostError('Could not save the computer securely.');
      }
    } on Object {
      if (session.cancelled) {
        await session.cancellation;
        return;
      }
      if (_session != session || session.revoked) return;
      await _drop(session);
      rethrow;
    }
  });

  Future<void> _confirmMutual(
    _ClientSession session,
    LinkPeer peer,
    _PendingHost pending,
  ) async {
    final binding = pending.binding!;
    final local = localHost!;
    DesktopReverseReservation? reservation;
    bool kept = false;
    bool contacted = false;
    bool current() =>
        _session == session &&
        !session.cancelled &&
        !session.revoked &&
        !peer.isClosed &&
        local.desktopShareEpoch == pending.shareEpoch;
    void check() {
      _checkSession(session);
      if (!current()) throw DesktopMutualPairing.rejected;
    }

    session.waitingForHostApproval = true;
    _notify();
    void sharingChanged() {
      if (local.desktopShareEpoch != pending.shareEpoch) {
        unawaited(peer.close());
      }
    }

    local.addListener(sharingChanged);
    try {
      check();
      final consent = await peer.call(
        DesktopMutualPairing.consent,
        binding.toJson(),
        DesktopMutualPairing.consentTimeout,
      );
      check();
      if (!binding.matches(consent)) throw DesktopMutualPairing.rejected;
      reservation = local.armDesktopReverse(
        binding,
        pending.host.name,
        current,
      );
      await _save(
        _saved.withHost(pending.host, select: true),
        validate: check,
        beforeCommit: () async {
          // Check the protected store before either inbound grant. This
          // candidate is not published and its key alone has no access.
          contacted = true;
          final linked = await peer.call(DesktopMutualPairing.link, {
            'binding': binding.toJson(),
            'route': local.desktopReturnRoute,
          }, DesktopMutualPairing.connectTimeout);
          check();
          if (!binding.matches(linked) ||
              !local.desktopReverseGranted(reservation!)) {
            throw DesktopMutualPairing.rejected;
          }
          _deviceFrom(await _hello(session, peer));
        },
        onCommit: () {
          kept = true;
          unawaited(local.endDesktopReverse(reservation!, keep: true));
          _publishPairing(session, peer);
        },
      );
    } on Object {
      if (contacted && !session.cancelled) await _abortMutual(peer, binding);
      if (session.cancelled) return;
      throw const _HostError(
        'Mutual pairing was not completed. Check sharing on both computers, then try again or choose one-way pairing.',
      );
    } finally {
      local.removeListener(sharingChanged);
      if (!kept && reservation != null) {
        await local.endDesktopReverse(reservation, keep: false);
      }
    }
  }

  void _publishPairing(_ClientSession session, LinkPeer peer) {
    session.pairing = false;
    session.confirming = false;
    session.waitingForHostApproval = false;
    _pausedHostId = null;
    _groupMemberId = null;
    _clearPending();
    _authorized = peer;
  }

  /// The responding desktop uses this same single outbound slot. If it
  /// already has a selection, save the new workspace without switching it.
  Future<bool> completeDesktopReverse(
    DesktopPairBinding binding,
    LinkIdentity identity,
    DesktopReturnRoute route,
    String name,
    bool Function() valid,
    Future<void> Function() keepForward,
  ) async {
    if (_busy ||
        _disposed ||
        !valid() ||
        localHost?.id != binding.forwardHost ||
        route.address.id != binding.reverseHost ||
        identity.id != binding.reverseClient) {
      return false;
    }
    bool kept = false;
    await _run('Could not finish the return connection.', () async {
      await _readSaved();
      if (!valid() ||
          _saved.hosts.containsKey(route.address.id) ||
          _session?.pairing == true) {
        return;
      }
      final restore = selectedHostId;
      if (_session case final previous?) {
        _pausedHostId = previous.hostId;
        await _drop(previous);
      } else if (restore != null) {
        _pausedHostId = restore;
      }
      if (!valid()) return;
      final host = _SavedHost(
        identity,
        name.isEmpty ? 'BaoCode' : name,
        route.address,
        direct: route.direct,
        restrictRelays: true,
      );
      await _connect(host, pairing: true, (session, peer) async {
        void check() {
          _checkSession(session);
          if (!valid()) throw DesktopMutualPairing.rejected;
        }

        try {
          check();
          final proof = await peer.call(
            DesktopMutualPairing.reverse,
            binding.toJson(),
          );
          check();
          if (!binding.matches(proof)) throw DesktopMutualPairing.rejected;
          await _save(
            _saved.withHost(host, select: restore == null),
            validate: check,
            beforeCommit: () async {
              // Both owners consented, the exact reverse transport proved
              // its key, and both outgoing stores have verified their writes.
              await keepForward();
              check();
              final grant = await peer.call(
                DesktopMutualPairing.grant,
                binding.toJson(),
              );
              check();
              if (!binding.matches(grant)) throw DesktopMutualPairing.rejected;
              _deviceFrom(await _hello(session, peer));
            },
            onCommit: () {
              kept = true;
              if (restore == null) _publishPairing(session, peer);
            },
          );
          if (restore != null) await _drop(session);
        } on Object {
          await _abortMutual(peer, binding);
          rethrow;
        }
      });
    });
    return kept;
  }

  static Future<void> _abortMutual(
    LinkPeer peer,
    DesktopPairBinding binding,
  ) async {
    try {
      await peer.call(
        DesktopMutualPairing.abort,
        binding.toJson(),
        const Duration(seconds: 2),
      );
    } on Object {
      // The other host can already be offline. The local reservation is
      // invalidated separately; do not imply rollback across an outage.
    }
  }

  Future<void> cancelMutualAttempt(Object attempt) async {
    if (identical(pendingMutualAttempt, attempt)) await cancelPairing();
  }

  Future<void> cancelPairing() async {
    _preparingPair = false;
    final session = _session;
    if (session == null || !session.pairing) return;
    if (session.confirming) {
      final binding = _pending?.binding;
      session.cancelled = true;
      session.waitingForHostApproval = false;
      _clearPending();
      final cancellation = session.cancellation ??= _cancelConfirmation(
        session,
        binding,
      );
      _notify();
      await cancellation;
    } else {
      await _endPending(session);
    }
  }

  Future<void> _cancelConfirmation(
    _ClientSession session,
    DesktopPairBinding? binding,
  ) async {
    // The host may already have accepted the confirmation. Clear that
    // authorization before closing the still-private pending peer.
    if (binding == null) {
      await _unpair(session.peer!);
    } else {
      await _abortMutual(session.peer!, binding);
    }
    await _endPending(session);
  }

  Future<void> _endPending(
    _ClientSession session, {
    bool expired = false,
  }) async {
    Future<void> end() async {
      if (_session != session || _disposed) return;
      _error = expired ? 'This invite has expired.' : null;
      await _drop(session);
    }

    if (_busy) {
      await end();
    } else {
      await _run('Could not cancel pairing.', end);
    }
  }

  Future<void> reconnect() async {
    await _loss;
    if (_loaded && _selected == null && _groupMemberId == null) return;
    await _run('Could not connect to the saved computer.', () async {
      await _readSaved();
      if (_session case final session?) await _settle(session);
      await _reconnect();
    });
  }

  Future<void> _reconnect() async {
    if (_groupMemberId case final id?) {
      if (_session == null) await _connectGroup(id);
      return;
    }
    final host = _selected;
    if (host == null || _session != null || _disposed) return;
    try {
      await _connect(host, (session, peer) async {
        final answer = await _hello(session, peer);
        if (answer case {'pairing': true}) {
          throw const _HostError(
            'The computer did not authorize the connection.',
          );
        }
        final updated = host.updated(_deviceFrom(answer));
        _checkSession(session);
        if (updated.name != host.name ||
            updated.address != host.address ||
            updated.direct != host.direct) {
          await _save(_saved.withHost(updated));
        }
        if (_session == session && !session.revoked) {
          _authorized = peer;
          _lastNearbyRetry = null;
          _error = null;
        }
      });
    } on LinkRemoteException catch (error) {
      if (error.code != LinkErrors.unpaired) rethrow;
      await _removeSaved(host.address.id);
      throw const _HostError(_revoked);
    } on LinkClosedException {
      throw const _HostError('Could not reach the saved computer.');
    }
  }

  List<String> _nearbyAddresses(String id) => {
    for (final advert in _adverts)
      if (advert.id == id) ...advert.addrs,
  }.toList();

  void _maybeReconnectNearby() {
    final host = _selected;
    if (_disposed ||
        !discovering ||
        host == null ||
        peer != null ||
        groupSelected) {
      return;
    }
    final nearby = _nearbyAddresses(host.address.id);
    if (nearby.isEmpty) {
      _lastNearbyRetry = null;
    } else if (!_busy &&
        _session == null &&
        (_lastNearbyRetry?.id != host.address.id ||
            !listEquals(nearby, _lastNearbyRetry?.addresses))) {
      // Bursts of unchanged Bonjour updates must not spin a retry loop.
      unawaited(_run('Could not connect to the saved computer.', _reconnect));
    }
  }

  /// Selects a saved computer by authenticated ID, even if it is offline.
  Future<void> selectHost(String id) async {
    if (_loss case final loss?) await loss;
    await _run('Could not select the saved computer.', () async {
      await _readSaved();
      if (!_saved.hosts.containsKey(id)) return;
      if (_session case final session?) {
        if (!session.pairing) await _settle(session);
        if (_session == session &&
            id == selectedHostId &&
            !session.pairing &&
            !session.group) {
          return;
        }
        await _drop(session);
      }
      if (!_saved.hosts.containsKey(id)) return;
      _groupMemberId = null;
      if (id != selectedHostId) {
        await _save(_SavedHosts(_saved.hosts, id));
      }
      await _reconnect();
    });
  }

  /// Group authorization does not install a legacy saved-host record.
  Future<void> selectGroupMember(String id) async {
    await _loss;
    await _run('Could not reach the group computer.', () async {
      await _readSaved();
      if (localHost?.permitsGroupWorkspace(id) != true) return;
      if (_groupMemberId == id && peer != null) return;
      if (_session case final previous?) await _drop(previous);
      _groupMemberId = id;
      await _connectGroup(id);
    });
  }

  Future<void> _connectGroup(String id) async {
    final host = localHost;
    if (_disposed || host == null || !host.permitsGroupWorkspace(id)) return;
    final session = _session = _ClientSession(id)..group = true;
    try {
      final connected = await host.openGroupWorkspace(
        id,
        nearby: _nearbyAddresses(id),
      );
      session.peer = connected;
      if (_session != session || !host.permitsGroupWorkspace(id)) {
        await connected.close();
        return;
      }
      session.events = connected.events.listen(
        (_) {},
        onDone: () {
          session.finishEvents();
          _connectionEnded(session);
        },
      );
      _authorized = connected;
    } on Object {
      await _drop(session);
      throw const _HostError('Could not reach the group computer.');
    }
  }

  void _groupChanged() {
    if (_session case final session?
        when session.group &&
            localHost?.permitsGroupWorkspace(session.hostId) != true) {
      unawaited(_drop(session));
    }
  }

  /// Compatibility shortcut for forgetting the selected computer.
  Future<void> forget() => _forget();

  /// Removes only [id] and its key. An active peer is also asked to unpair.
  /// Inactive hosts are removed locally without dialing or switching to them.
  Future<void> forgetHost(String id) => _forget(id);

  Future<void> _forget([String? id]) =>
      _run('Could not remove the saved computer.', () async {
        await _readSaved();
        final target = id ?? selectedHostId;
        if (target == null || !_saved.hosts.containsKey(target)) return;
        if (_session case final session? when session.hostId == target) {
          final connected = peer;
          _authorized = null;
          _notify();
          if (connected != null) await _unpair(connected);
          await _drop(session);
        }
        await _removeSaved(target);
      });

  Future<void> _connect(
    _SavedHost host,
    Future<void> Function(_ClientSession, LinkPeer) authenticate, {
    bool pairing = false,
    List<String> Function()? pairingAddresses,
  }) async {
    if (_disposed) return;
    final session = _session = _ClientSession(host.address.id)
      ..pairing = pairing;
    try {
      if (!pairing) {
        // A bind can fail before the available addresses are used.
        _lastNearbyRetry = (
          id: session.hostId,
          addresses: _nearbyAddresses(session.hostId),
        );
      }
      final node = await _bind(host.identity, host.address.relays);
      if (_session != session) {
        await node.close();
        return;
      }
      session.node = node;
      final nearby = pairing
          ? const <String>[]
          : _nearbyAddresses(session.hostId);
      if (!pairing) _lastNearbyRetry = (id: session.hostId, addresses: nearby);
      final link = await node.connect(
        host.address.copyWith(
          relays: host.direct
              ? const []
              : host.restrictRelays
              ? host.address.relays
              : {...host.address.relays, ...defaultLinkRelays}.toList(),
          addrs:
              pairingAddresses?.call() ??
              {...nearby, ...host.address.addrs}.toList(),
        ),
      );
      session.link = link;
      if (_session != session) {
        link.close();
        return;
      }
      if (link.remote != host.address.id) {
        throw const _HostError(
          'The computer did not prove the expected identity.',
        );
      }
      if (node.id != host.identity.id) {
        throw const _HostError(
          'The local connection did not use the expected identity.',
        );
      }
      final peer = await LinkPeer.connect(link, mirror: LinkSessionMirror());
      session.peer = peer;
      if (_session != session) {
        await peer.close();
        return;
      }
      session.events = peer.events.listen(
        (event) {
          if (_session != session || event.name != LinkEvents.unpaired) return;
          session.revoked = true;
          _connectionEnded(session);
        },
        onDone: () {
          session.finishEvents();
          _connectionEnded(session);
        },
      );
      await authenticate(session, peer);
    } on Object {
      if (_session != session) return;
      if (session.revoked) return; // _run removes the record on revocation.
      await _drop(session);
      rethrow;
    }
  }

  Future<Object?> _hello(
    _ClientSession session,
    LinkPeer peer, {
    String? token,
    bool request = false,
    bool mutual = false,
  }) async {
    final device = await _device();
    _checkSession(session);
    return peer.call(LinkMethods.hello, {
      'name': device.name,
      'system': device.system,
      'token': ?token,
      if (request) 'request': true,
      if (mutual)
        'capabilities': {
          DesktopMutualPairing.capability: DesktopMutualPairing.version,
        },
    });
  }

  static DeviceInfo _deviceFrom(Object? answer) {
    if (answer case {'device': final Map<String, Object?> device}) {
      return DeviceInfo.fromJson(device);
    }
    throw const _HostError('The computer sent an invalid reply.');
  }

  static PairingOffer _parseOffer(String invite) {
    final PairingOffer offer;
    try {
      final literal = invite.trim();
      final uri = Uri.parse(literal);
      if (!literal.startsWith('baocode://pair?d=') ||
          uri.authority != 'pair' ||
          uri.path.isNotEmpty ||
          uri.hasFragment ||
          uri.queryParametersAll.length != 1 ||
          uri.queryParametersAll['d']?.length != 1) {
        throw const FormatException();
      }
      offer = PairingOffer.parse(literal);
      if (offer.token.length != 16) throw const FormatException();
    } on PairingVersionException {
      throw const _HostError(
        'This invite uses an incompatible version of BaoCode.',
      );
    } on Object {
      throw const _HostError('Paste a valid BaoCode pairing invite.');
    }
    if (offer.expiredAt(DateTime.now())) {
      throw const _HostError('This invite has expired.');
    }
    return offer;
  }

  void _checkSession(_ClientSession session) {
    if (_session != session ||
        session.cancelled ||
        session.revoked ||
        session.peer?.isClosed == true) {
      throw const LinkClosedException();
    }
  }

  Future<void> _readSaved() async {
    if (_loaded) return;
    final text = await _store.read(_storageId);
    final legacy = text == null ? await _store.read(_legacyStorageId) : null;
    if (_disposed) return;
    if (text != null) {
      _saved = _SavedHosts.decode(text);
    } else if (legacy != null) {
      final host = _SavedHost.decode(jsonDecode(legacy));
      _saved = _saved.withHost(host, select: true);
    }
    if (text != null || legacy != null) {
      try {
        // A readable v2 snapshot is authoritative even if an earlier
        // migration could not delete the legacy copy.
        if (text == null) await _save(_saved);
        await _deleteLegacy();
      } on Object {
        // The legacy copy is left untouched if writing v2 failed.
      }
    }
    _loaded = true;
  }

  Future<void> _save(
    _SavedHosts next, {
    void Function()? validate,
    Future<void> Function()? beforeCommit,
    void Function()? onCommit,
  }) async {
    final previous = await _store.read(_storageId);
    final text = next.hosts.isEmpty ? null : jsonEncode(next.toJson());
    try {
      if (text == null) await _deleteLegacy();
      validate?.call();
      await _writeSaved(text);
      validate?.call();
      if (beforeCommit != null) {
        await beforeCommit();
        validate?.call();
      }
    } on Object {
      // A backend may have written before throwing or failing verification.
      // Restore the previous snapshot, never delete other saved pairings.
      try {
        if (await _store.read(_storageId) != previous) {
          await _writeSaved(previous);
        }
      } on Object {
        // Report the original failure; do not publish the new selection.
      }
      rethrow;
    }
    if (!_disposed) {
      _saved = next;
      onCommit?.call();
    }
  }

  Future<void> _writeSaved(String? text) async {
    if (text == null) {
      await _store.delete(_storageId);
    } else {
      await _store.write(_storageId, text);
    }
    if (await _store.read(_storageId) != text) {
      throw const _HostError('Could not save the computer securely.');
    }
  }

  Future<void> _deleteLegacy() async {
    if (await _store.read(_legacyStorageId) == null) return;
    await _store.delete(_legacyStorageId);
    if (await _store.read(_legacyStorageId) != null) {
      throw const _HostError('Could not remove the saved computer.');
    }
  }

  Future<void> _removeSaved(String id) async {
    if (_saved.hosts.containsKey(id)) await _save(_saved.withoutHost(id));
  }

  static Future<void> _unpair(LinkPeer peer) async {
    try {
      await peer.call(LinkMethods.unpair, const {}, const Duration(seconds: 2));
    } on Object {
      // The host can be unavailable. Local removal must still work.
    }
  }

  Future<void> _run(String fallback, Future<void> Function() action) async {
    if (_busy || _disposed) return;
    _busy = true;
    _error = null;
    _notify();
    try {
      await action();
    } on _HostError catch (error) {
      _error = error.message;
    } on LinkRemoteException catch (error) {
      _error = switch (error.code) {
        LinkErrors.badToken =>
          'The invite is no longer valid. Ask the computer for a new one.',
        LinkErrors.notPairing =>
          'The computer is no longer accepting nearby pairing requests.',
        LinkErrors.busy => 'The computer is pairing with another device.',
        LinkErrors.rejected => 'The computer rejected the pairing.',
        _ => fallback,
      };
    } on Object {
      // Exceptions can contain an invite, a key, or arbitrary remote text.
      _error = fallback;
    } finally {
      if (_session case final session? when session.ended) {
        await _settle(session);
      }
      if (_pausedHostId != null && _session == null) {
        await _resumePausedHost();
        if (_session case final session? when session.ended) {
          await _settle(session);
        }
      }
      _busy = false;
      _notify();
      _maybeReconnectNearby();
    }
  }

  Future<void> _resumePausedHost() async {
    final id = _pausedHostId;
    _pausedHostId = null;
    if (id != selectedHostId || _disposed) return;
    final pairingError = _error;
    try {
      await _reconnect();
    } on _HostError catch (error) {
      _error = error.message;
    } on Object {
      _error = 'Could not reconnect to the saved computer.';
    }
    _error = pairingError ?? _error;
  }

  void _connectionEnded(_ClientSession session) {
    if (_session != session || _busy) return;
    final loss = _loss = _run('The connection ended.', () => _settle(session));
    unawaited(
      loss.whenComplete(() {
        if (_loss == loss) _loss = null;
      }),
    );
  }

  Future<void> _settle(_ClientSession session) async {
    if (_session != session || !session.ended) return;
    if (!session.revoked) {
      // LinkPeer can already be closed while its last event is still queued.
      await session.eventsFinished.future;
      if (_session != session) return;
    }
    await _drop(session);
    if (session.revoked) {
      try {
        await _removeSaved(session.hostId);
        _error = _revoked;
      } on Object {
        _error = 'The computer removed your access. Could not remove the saved computer.';
      }
    } else {
      _error ??= 'The connection to the computer ended.';
    }
  }

  void _clearPending() {
    _expiry?.cancel();
    _expiry = null;
    _pending = null;
  }

  Future<void> _drop(_ClientSession session) async {
    if (_session != session) return;
    _session = null;
    _authorized = null;
    _clearPending();
    session.finishEvents();
    // Session callbacks are already invalidated. Broadcast subscription
    // cleanup does not own the transport and need not delay the next dial.
    unawaited(session.events?.cancel().catchError((Object _) {}));
    final peerClosed = session.peer?.close().catchError((Object _) {});
    _notify();
    await peerClosed;
    try {
      session.link?.close();
    } on Object {
      // Already closed; the node can still be released.
    }
    await session.node?.close().catchError((Object _) {});
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    localHost?.removeListener(_groupChanged);
    unawaited(stopDiscovery());
    if (_session case final session?) unawaited(_drop(session));
    super.dispose();
  }
}

class _SavedHost {
  _SavedHost(
    this.identity,
    this.name,
    LinkAddress address, {
    required this.direct,
    this.restrictRelays = false,
  }) : address = address.copyWith(
         relays: direct
             ? const []
             : (address.relays.isEmpty && !restrictRelays
                   ? linkRelays()
                   : address.relays),
       );

  static _SavedHost decode(Object? json) {
    if (json case {
      'identity': final Map<String, Object?> identityJson,
      'name': final String name,
      'address': final Map<String, Object?> addressJson,
      'direct': final bool direct,
    }) {
      final identity = LinkIdentity.fromJson(identityJson);
      final address = LinkAddress.fromJson(addressJson);
      if (identity != null && address != null && address.id != identity.id) {
        return _SavedHost(
          identity,
          name,
          address,
          direct: direct,
          restrictRelays: json['restrictRelays'] == true,
        );
      }
    }
    throw const _HostError(
      'The saved computer is invalid. Forget it and pair again.',
    );
  }

  final LinkIdentity identity;
  final String name;
  final LinkAddress address;
  final bool direct;
  final bool restrictRelays;

  _SavedHost updated(DeviceInfo device) => _SavedHost(
    identity,
    device.name.isEmpty ? name : device.name,
    address.copyWith(
      relays: restrictRelays || device.relays.isEmpty
          ? address.relays
          : device.relays,
      addrs: restrictRelays || device.addrs.isEmpty
          ? address.addrs
          : device.addrs,
    ),
    direct: restrictRelays ? direct : device.direct,
    restrictRelays: restrictRelays,
  );

  Map<String, Object?> toJson() => {
    'identity': identity.toJson(),
    'name': name,
    'address': address.toJson(),
    'direct': direct,
    if (restrictRelays) 'restrictRelays': true,
  };
}

class _SavedHosts {
  const _SavedHosts(this.hosts, this.selectedId);

  final Map<String, _SavedHost> hosts;
  final String? selectedId;

  static _SavedHosts decode(String text) {
    if (jsonDecode(text) case {
      'hosts': final List<Object?> entries,
      'selected': final String selected,
    }) {
      final hosts = <String, _SavedHost>{};
      for (final entry in entries) {
        final host = _SavedHost.decode(entry);
        if (hosts.containsKey(host.address.id)) break;
        hosts[host.address.id] = host;
      }
      if (hosts.length == entries.length && hosts.containsKey(selected)) {
        return _SavedHosts(hosts, selected);
      }
    }
    throw const _HostError('The saved computers are invalid.');
  }

  _SavedHosts withHost(_SavedHost host, {bool select = false}) => _SavedHosts({
    ...hosts,
    host.address.id: host,
  }, select ? host.address.id : selectedId);

  _SavedHosts withoutHost(String id) {
    final remaining = {...hosts}..remove(id);
    return _SavedHosts(
      remaining,
      selectedId == id ? remaining.keys.firstOrNull : selectedId,
    );
  }

  Map<String, Object?> toJson() => {
    'hosts': [for (final host in hosts.values) host.toJson()],
    'selected': selectedId,
  };
}

class _PendingHost {
  const _PendingHost(
    this.host,
    this.code,
    this.expires, {
    required this.needsApproval,
    this.binding,
    this.shareEpoch,
  });

  final _SavedHost host;
  final String code;
  final DateTime? expires;
  final bool needsApproval;
  final DesktopPairBinding? binding;
  final Object? shareEpoch;
}

class _ClientSession {
  _ClientSession(this.hostId);

  final String hostId;
  LinkNode? node;
  LinkConnection? link;
  LinkPeer? peer;
  StreamSubscription<LinkEvent>? events;
  final eventsFinished = Completer<void>();
  bool pairing = false;
  bool group = false;
  bool confirming = false;
  bool waitingForHostApproval = false;
  bool cancelled = false;
  Future<void>? cancellation;
  bool revoked = false;

  bool get ended => revoked || peer?.isClosed == true;

  void finishEvents() {
    if (!eventsFinished.isCompleted) eventsFinished.complete();
  }
}

class _HostError implements Exception {
  const _HostError(this.message);

  final String message;
}
