import 'dart:async';
import 'dart:convert';

import 'package:bao_link/bao_link.dart';
import 'package:flutter/foundation.dart';

import '../models/secret_store.dart';
import 'desktop_host_connection_stub.dart'
    if (dart.library.io) 'desktop_host_connection_io.dart'
    as platform;

/// An outgoing connection to one BaoCode desktop, using its Mobile Link invite.
/// The client has its own key and never reads or changes the local LinkHost.
class DesktopHostConnection extends ChangeNotifier {
  DesktopHostConnection()
    : this._(
        SecretStore.instance,
        platform.bindDesktopHostClient,
        platform.desktopHostClientDevice,
      );

  @visibleForTesting
  DesktopHostConnection.withDependencies({
    required SecretStore store,
    required Future<LinkNode> Function(LinkIdentity, List<String>) bind,
    required Future<DeviceInfo> Function() device,
  }) : this._(store, bind, device);

  DesktopHostConnection._(this._store, this._bind, this._device);

  static const _storageId = 'desktop_host_connection.v1';
  static const _revoked =
      'This computer removed your access. Pair again to reconnect.';

  final SecretStore _store;
  final Future<LinkNode> Function(LinkIdentity, List<String>) _bind;
  final Future<DeviceInfo> Function() _device;
  _SavedHost? _saved;
  bool _loaded = false;
  bool _disposed = false;
  bool _busy = false;
  bool _readingForPair = false;
  String? _error;
  _ClientSession? _session;
  _PendingHost? _pending;
  Timer? _expiry;
  LinkPeer? _authorized;
  Future<void>? _loss;

  bool get busy => _busy;
  String? get error => _error;
  String? get pendingCode => _pending?.code;
  String? get hostName => _pending?.host.name ?? _saved?.name;

  /// Available only after the host has authorized this connection.
  LinkPeer? get peer {
    final peer = _authorized;
    return peer != null && !peer.isClosed && _session?.revoked == false
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
  Future<void> pair(String invite) =>
      _run('Could not open the invite.', () async {
        _readingForPair = true;
        try {
          await _readSaved();
          if (!_readingForPair) return;
        } finally {
          _readingForPair = false;
        }
        if (_saved != null) {
          throw const _HostError(
            'Forget the saved computer before pairing another.',
          );
        }
        if (_session != null) return;
        final offer = _parseOffer(invite);
        final host = _SavedHost(
          LinkIdentity.generate(),
          offer.name.isEmpty ? 'BaoCode' : offer.name,
          offer.address,
          direct: offer.direct,
        );
        await _connect(host, pairing: true, (session, peer) async {
          final answer = await _hello(
            session,
            peer,
            token: encodeKey(offer.token),
          );
          if (answer is! Map ||
              answer['pairing'] != true ||
              answer['approval'] == true) {
            throw const _HostError('The computer did not accept the invite.');
          }
          final details = host.updated(_deviceFrom(answer));
          _checkSession(session);
          final timeLeft = offer.expires.difference(DateTime.now());
          if (timeLeft <= Duration.zero) {
            throw const _HostError('This invite has expired.');
          }
          _pending = _PendingHost(
            details,
            safetyCode(offer.key, host.identity.publicKey).join('  '),
            offer.expires,
          );
          _expiry = Timer(
            timeLeft,
            () => unawaited(_endPending(session, expired: true)),
          );
        });
      });

  /// The user has compared the code with the host's and says they match.
  Future<void> confirm() => _run('Could not confirm pairing.', () async {
    final pending = _pending;
    final session = _session;
    if (pending == null || session == null) return;
    session.pairing = false;
    _expiry?.cancel();
    _expiry = null;
    try {
      if (!DateTime.now().isBefore(pending.expires)) {
        throw const _HostError('This invite has expired.');
      }
      final peer = session.peer!;
      final reply = await peer.call(LinkMethods.confirm);
      if (reply case {'pairing': true}) {
        throw const _HostError('The computer did not confirm pairing.');
      }
      final host = pending.host.updated(_deviceFrom(reply));
      _checkSession(session);
      try {
        await _save(host);
      } on Object {
        await _unpair(peer);
        // A failing backend may have written an entry before reporting failure.
        try {
          await _removeSaved();
        } on Object {
          // Still fail closed and report the storage error below.
        }
        throw const _HostError('Could not save the computer securely.');
      }
      if (_session == session && !session.revoked) {
        _clearPending();
        _authorized = peer;
      }
    } on Object {
      if (session.revoked) return; // _run removes the record on revocation.
      await _drop(session);
      rethrow;
    }
  });

  Future<void> cancelPairing() async {
    _readingForPair = false;
    final session = _session;
    if (session == null || !session.pairing) return;
    await _endPending(session);
  }

  Future<void> _endPending(
    _ClientSession session, {
    bool expired = false,
  }) async {
    if (_session != session || _disposed) return;
    _error = expired ? 'This invite has expired.' : null;
    await _drop(session);
    _notify();
  }

  Future<void> reconnect() async {
    await _loss;
    if (_loaded && _saved == null) return;
    await _run('Could not connect to the saved computer.', () async {
      await _readSaved();
      if (_session case final session?) await _settle(session);
      await _reconnect();
    });
  }

  Future<void> _reconnect() async {
    final host = _saved;
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
          await _save(updated);
        }
        if (_session == session && !session.revoked) {
          _authorized = peer;
          _error = null;
        }
      });
    } on LinkRemoteException catch (error) {
      if (error.code != LinkErrors.unpaired) rethrow;
      await _removeSaved();
      throw const _HostError(_revoked);
    } on LinkClosedException {
      throw const _HostError('Could not reach the saved computer.');
    }
  }

  /// Removes the saved computer and key, asking the host to unpair when online.
  Future<void> forget() =>
      _run('Could not remove the saved computer.', () async {
        final session = _session;
        final connected = peer;
        _authorized = null;
        if (connected != null) await _unpair(connected);
        if (session != null) await _drop(session);
        await _removeSaved();
        _loaded = true;
      });

  Future<void> _connect(
    _SavedHost host,
    Future<void> Function(_ClientSession, LinkPeer) authenticate, {
    bool pairing = false,
  }) async {
    if (_disposed) return;
    final session = _session = _ClientSession()..pairing = pairing;
    try {
      final node = await _bind(host.identity, host.address.relays);
      if (_session != session) {
        await node.close();
        return;
      }
      session.node = node;
      final link = await node.connect(host.address);
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
      final peer = await LinkPeer.connect(link, mirror: LinkSessionMirror());
      session.peer = peer;
      if (_session != session) {
        await peer.close();
        return;
      }
      session.events = peer.events.listen(
        (event) {
          if (event.name != LinkEvents.unpaired) return;
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
  }) async {
    final device = await _device();
    _checkSession(session);
    return peer.call(LinkMethods.hello, {
      'name': device.name,
      'system': device.system,
      'token': ?token,
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
        session.revoked ||
        session.peer?.isClosed == true) {
      throw const LinkClosedException();
    }
  }

  Future<void> _readSaved() async {
    if (_loaded) return;
    final text = await _store.read(_storageId);
    if (_disposed) return;
    _saved = text == null ? null : _SavedHost.decode(text);
    _loaded = true;
  }

  Future<void> _save(_SavedHost host) async {
    final text = jsonEncode(host.toJson());
    await _store.write(_storageId, text);
    if (await _store.read(_storageId) != text) {
      throw const _HostError('Could not save the computer securely.');
    }
    if (!_disposed) _saved = host;
  }

  Future<void> _removeSaved() async {
    await _store.delete(_storageId);
    // The existing store can fall back if its primary is unavailable.
    if (await _store.read(_storageId) != null) {
      throw const _HostError('Could not remove the saved computer.');
    }
    _saved = null;
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
        LinkErrors.badToken || LinkErrors.notPairing =>
          'The invite is no longer valid. Ask the computer for a new one.',
        LinkErrors.busy => 'The computer is pairing with another device.',
        LinkErrors.rejected => 'The computer rejected the pairing.',
        _ => fallback,
      };
    } on Object {
      // Exceptions can contain an invite, a key, or arbitrary remote text.
      _error = fallback;
    } finally {
      final session = _session;
      if (session != null &&
          (session.revoked || session.peer?.isClosed == true)) {
        await _settle(session);
      }
      _busy = false;
      _notify();
    }
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
    if (_session != session) return;
    if (!session.revoked) {
      if (session.peer?.isClosed != true) return;
      // LinkPeer can already be closed while its last event is still queued.
      await session.eventsFinished.future;
      if (_session != session) return;
    }
    await _drop(session);
    if (session.revoked) {
      try {
        await _removeSaved();
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
    await session.events?.cancel().catchError((Object _) {});
    await session.peer?.close().catchError((Object _) {});
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
  }) : address = address.copyWith(
         relays: direct
             ? const []
             : (address.relays.isEmpty ? linkRelays() : address.relays),
       );

  static _SavedHost decode(String text) {
    final json = jsonDecode(text);
    if (json case {
      'identity': final Map<String, Object?> identityJson,
      'name': final String name,
      'address': final Map<String, Object?> addressJson,
      'direct': final bool direct,
    }) {
      final identity = LinkIdentity.fromJson(identityJson);
      final address = LinkAddress.fromJson(addressJson);
      if (identity != null && address != null && address.id != identity.id) {
        return _SavedHost(identity, name, address, direct: direct);
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

  _SavedHost updated(DeviceInfo device) => _SavedHost(
    identity,
    device.name.isEmpty ? name : device.name,
    address.copyWith(
      relays: device.relays.isEmpty ? address.relays : device.relays,
      addrs: device.addrs.isEmpty ? address.addrs : device.addrs,
    ),
    direct: device.direct,
  );

  Map<String, Object?> toJson() => {
    'identity': identity.toJson(),
    'name': name,
    'address': address.toJson(),
    'direct': direct,
  };
}

class _PendingHost {
  const _PendingHost(this.host, this.code, this.expires);

  final _SavedHost host;
  final String code;
  final DateTime expires;
}

class _ClientSession {
  LinkNode? node;
  LinkConnection? link;
  LinkPeer? peer;
  StreamSubscription<LinkEvent>? events;
  final eventsFinished = Completer<void>();
  bool pairing = false;
  bool revoked = false;

  void finishEvents() {
    if (!eventsFinished.isCompleted) eventsFinished.complete();
  }
}

class _HostError implements Exception {
  const _HostError(this.message);

  final String message;
}
