part of 'link_host.dart';

/// An authenticated preview. Only confirming this exact object signs consent.
class ComputerGroupJoinPreview {
  ComputerGroupJoinPreview._(
    this._history,
    this.sponsor,
    this.code,
    this._invite,
    this._epoch,
  );
  final ComputerGroup? _history;
  String get groupId => _invite.group;
  final ComputerGroupMember sponsor;
  final String code;
  final _GroupInvite _invite;
  final Object _epoch;
}

class ComputerGroupApproval {
  ComputerGroupApproval._(
    this.member,
    this.code,
    this._consent,
    this._peer,
    this._invite,
    this._window,
  );
  final ComputerGroupMember member;
  final String code;
  final ComputerGroupConsent _consent;
  final LinkPeer _peer;
  final _GroupInvite _invite;
  final _GroupInvite? _window;
  final _result = Completer<ComputerGroup?>();
  bool _approving = false;
}

class _GroupInvite {
  _GroupInvite(this.group, this.sponsor, this.token, this.expires);
  final String group, token;
  final ComputerGroupMember sponsor;
  final DateTime expires;
  bool get valid => expires.isAfter(DateTime.now());

  String encode() =>
      'baocode-group://join/${encodeKey(utf8.encode(jsonEncode([group, sponsor.toJson(), token, expires.millisecondsSinceEpoch])))}';

  static _GroupInvite decode(String value) {
    const prefix = 'baocode-group://join/';
    final input = value.trim();
    if (!input.startsWith(prefix) || input.length > 9000) {
      throw ComputerGroupWire.rejected;
    }
    if (jsonDecode(utf8.decode(decodeKey(input.substring(prefix.length))))
        case [
          final String group,
          final Object sponsor,
          final String token,
          final int expires,
        ]
        when DesktopMutualPairing.validId(group) &&
            DesktopMutualPairing.validAttempt(token) &&
            expires > 0 &&
            expires < 8640000000000000) {
      final invite = _GroupInvite(
        group,
        ComputerGroupMember.decode(sponsor),
        token,
        DateTime.fromMillisecondsSinceEpoch(expires),
      );
      if (invite.valid) return invite;
    }
    throw ComputerGroupWire.rejected;
  }
}

class _ComputerGroupHost {
  _ComputerGroupHost(this.host);
  final LinkHost host;
  ComputerGroup? group;
  bool storageError = false;
  bool independent = false;
  bool _paused = false;
  _GroupInvite? _invite;
  Timer? _inviteTimer;
  bool _nearby = false;
  bool _creating = false;
  Object? _preparing;
  Timer? _previewTimer;
  LinkPeer? _previewPeer;
  ComputerGroupJoinPreview? _preview;
  ComputerGroupJoinPreview? confirming;
  bool joinFailed = false;
  ComputerGroupApproval? pending;
  LinkPeer? _joinPeer;
  Future<void> _mutating = Future.value();
  Timer? _periodic;
  bool _syncing = false;
  final _observed = <String, Set<String>>{};
  final _denied = <String>{};

  bool get ready => epoch != null && !storageError;
  bool get invitingNearby =>
      _nearby &&
      !host._unadvertised &&
      _invite?.valid == true &&
      pending == null &&
      ready &&
      group?.canAdmit == true &&
      group?.active.containsKey(host.id) == true;
  Object? get epoch =>
      !host._disposed &&
          !_paused &&
          (host._enabled || independent) &&
          host.status == LinkHostStatus.listening
      ? host._node
      : null;
  bool permits(String remote) =>
      ready &&
      group?.active.containsKey(host.id) == true &&
      group?.active.containsKey(remote) == true &&
      remote != host.id &&
      !_denied.contains(host.id) &&
      !_denied.contains(remote);

  Future<void> load() async {
    try {
      final kept = await host.platform!.readComputerGroup();
      if (kept == null) return;
      if (kept is! Map<String, Object?> ||
          kept['version'] != 1 ||
          kept['enabled'] is! bool) {
        throw ComputerGroupWire.rejected;
      }
      final history = kept['history'];
      if (history == null) {
        independent = kept['enabled'] == true;
        _paused = kept['paused'] == true;
        return;
      }
      final read = ComputerGroup.decode(history);
      if (!read.known.containsKey(host.id)) throw ComputerGroupWire.rejected;
      group = read;
      independent = kept['enabled'] == true;
      _paused = kept['paused'] == true;
    } on Object {
      storageError = true;
    }
  }

  Future<T> _serial<T>(Future<T> Function() run) {
    final result = _mutating.then((_) => run());
    _mutating = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> enableIndependent() async {
    await _serial(() async {
      if (!host._loaded || host._disposed || storageError) {
        throw ComputerGroupWire.rejected;
      }
      if (independent && !_paused) return;
      final storage = host.platform!;
      final record = _record(group, enabled: true, paused: false);
      await storage.writeComputerGroup(record);
      if (jsonEncode(await storage.readComputerGroup()) != jsonEncode(record)) {
        throw const FormatException('Could not verify computer group settings');
      }
      independent = true;
      _paused = false;
    });
    await host._start();
    if (!ready) throw ComputerGroupWire.rejected;
    startSync();
    host.notifyListeners();
  }

  Future<void> pause() => _serial(() async {
    if (!ready) throw ComputerGroupWire.rejected;
    independent = false;
    _paused = true;
    stopSync();
    for (final connection in [...host._connections]) {
      if (connection.groupControl) _closeWorkspace(connection);
    }
    host.notifyListeners();
    if (!host._enabled) await host._stop();
    await _writeRecord(_record(group, enabled: false, paused: true));
  });

  Map<String, Object?> _record(
    ComputerGroup? next, {
    required bool enabled,
    required bool paused,
  }) => {
    'version': 1,
    'enabled': enabled,
    'paused': paused,
    'history': next?.toJson(),
  };

  Future<void> _writeRecord(Map<String, Object?> record) async {
    final storage = host.platform!;
    await storage.writeComputerGroup(record);
    if (jsonEncode(await storage.readComputerGroup()) != jsonEncode(record)) {
      throw const FormatException('Could not verify computer group storage');
    }
  }

  void _closeWorkspace(_Connection connection) {
    connection.groupWorkspace = false;
    connection.bridge?.dispose();
    connection.bridge = null;
    unawaited(connection.peer.close());
  }

  Future<void> _persist(ComputerGroup next) async {
    if (identical(group, next)) return;
    if (storageError) throw ComputerGroupWire.rejected;
    final json = _record(next, enabled: independent, paused: _paused);
    final storage = host.platform!;
    final lost = <String>{
      ...next.removed,
      for (final id in group?.active.keys ?? const <String>[])
        if (!next.active.containsKey(id)) id,
    };
    if (!_denied.containsAll(lost)) {
      _denied.addAll(lost);
      for (final connection in [...host._connections]) {
        if (connection.groupWorkspace && !permits(connection.id)) {
          _closeWorkspace(connection);
        }
      }
      host.notifyListeners();
    }
    try {
      if (group == null) {
        // Group certificates are useless after a restart unless the listener
        // identity they reference was also kept successfully.
        final local = (await storage.read())['identity'];
        if (local is! Map<String, Object?> ||
            LinkIdentity.fromJson(local)?.id != host.id) {
          throw const FormatException('Could not verify local link identity');
        }
      }
      await _writeRecord(json);
    } on Object {
      storageError = true;
      for (final connection in [...host._connections]) {
        if (!connection.groupWorkspace) continue;
        _closeWorkspace(connection);
      }
      host.notifyListeners();
      rethrow;
    }
    group = next;
    _denied.clear();
    host.notifyListeners();
  }

  Future<void> remove(String id) async {
    await _serial(() async {
      if (!permits(id)) throw ComputerGroupWire.rejected;
      await _persist(group!.remove(id, host._identity));
    });
    await sync([group!.known[id]!, ...group!.active.values]);
  }

  Set<String> pendingRemoval(String target) {
    final current = group;
    if (current == null || !current.removed.contains(target)) return {};
    final ids = current.removalsOf(target);
    return {
      for (final member in {...current.active.keys, target})
        if (member != host.id && _observed[member]?.containsAll(ids) != true)
          member,
    };
  }

  void _observe(String remote, Object? wire, ComputerGroup current) {
    final ids = ComputerGroup.reportedEvents(wire)
      ..retainAll(current.eventIds.toSet());
    final observed = _observed.putIfAbsent(remote, () => {});
    if (!observed.containsAll(ids)) {
      observed.addAll(ids);
      host.notifyListeners();
    }
  }

  ComputerGroupMember get _self {
    final device = host._deviceInfo();
    return ComputerGroupMember(
      id: host.id,
      name: String.fromCharCodes(device.name.runes.take(60)),
      addrs: host._tellAddrs.where((address) => address.length <= 80),
      relays: host._tellRelays.where((relay) => relay.length <= 256).take(16),
      direct: host._relayMode == LinkRelayMode.direct,
    );
  }

  Future<void> create() async {
    if (!ready ||
        group != null ||
        _preview != null ||
        _preparing != null ||
        _creating) {
      throw ComputerGroupWire.rejected;
    }
    _creating = true;
    try {
      await _serial(() async {
        if (!ready || group != null) throw ComputerGroupWire.rejected;
        await _persist(ComputerGroup.create(_self, host._identity));
        startSync();
      });
    } finally {
      _creating = false;
    }
  }

  String invite(bool nearby) {
    final current = group;
    if (!ready ||
        current == null ||
        !current.canAdmit ||
        !current.active.containsKey(host.id) ||
        pending != null) {
      throw ComputerGroupWire.rejected;
    }
    final invite = _invite = _GroupInvite(
      current.id,
      _self,
      encodeKey(randomBytes(16)),
      DateTime.now().add(host.offerLifetime),
    );
    _nearby = nearby;
    _inviteTimer?.cancel();
    _inviteTimer = Timer(host.offerLifetime, cancelInvite);
    host.notifyListeners();
    return invite.encode();
  }

  void _clearInvite() {
    _inviteTimer?.cancel();
    _inviteTimer = null;
    _invite = null;
    _nearby = false;
  }

  void cancelInvite() {
    if (_invite == null) return;
    _clearInvite();
    if (pending case final request? when !request._approving) {
      _clearPending(request);
    }
    host.notifyListeners();
  }

  bool _validInvite(_GroupInvite invite, String remote) =>
      ready &&
      remote != host.id &&
      identical(invite, _invite) &&
      invite.valid &&
      group?.id == invite.group &&
      group?.canAdmit == true &&
      group?.active.containsKey(host.id) == true &&
      group?.known.containsKey(remote) == false;

  Future<LinkPeer> dial(
    ComputerGroupMember member, {
    Iterable<String> nearby = const [],
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final node = host._node;
    if (!ready || node == null || node.id != host.id || member.id == host.id) {
      throw ComputerGroupWire.rejected;
    }
    final connection = await node.connect(
      member.address(host.relays, nearby: nearby),
      timeout: timeout,
    );
    try {
      if (!ready || host._node != node || connection.remote != member.id) {
        throw ComputerGroupWire.rejected;
      }
      return await LinkPeer.connect(
        connection,
        mirror: LinkSessionMirror(),
      ).timeout(timeout);
    } on Object {
      connection.close();
      rethrow;
    }
  }

  Future<ComputerGroupJoinPreview> prepare(String link) async {
    final invite = _GroupInvite.decode(link);
    return _prepare(invite.sponsor, (peer) async {
      final history = await peer.call(ComputerGroupWire.prepare, {
        'group': invite.group,
        'token': invite.token,
      });
      return (invite, history);
    });
  }

  Future<ComputerGroupJoinPreview> prepareNearby(
    LinkAdvert advert,
    bool Function() stillVisible,
  ) async {
    if (!advert.groupInviting ||
        advert.addrs.isEmpty ||
        !DesktopMutualPairing.validId(advert.id) ||
        !stillVisible()) {
      throw ComputerGroupWire.rejected;
    }
    // The advert supplies a key to prove and temporary direct routes.
    final hint = ComputerGroupMember(
      id: advert.id,
      name: '',
      addrs: const [],
      relays: const [],
      direct: true,
    );
    return _prepare(hint, (peer) async {
      if (!stillVisible() || !await _onLan(peer)) {
        throw ComputerGroupWire.rejected;
      }
      final answer = await peer.call(ComputerGroupWire.prepareNearby);
      if (!stillVisible() || answer is! Map || answer['invite'] is! String) {
        throw ComputerGroupWire.rejected;
      }
      return (_GroupInvite.decode(answer['invite'] as String), null);
    }, nearby: advert.addrs);
  }

  static Future<bool> _onLan(LinkPeer peer) async =>
      (await peer.connection.path()).kind == LinkPathKind.lan && !peer.isClosed;

  Future<ComputerGroupJoinPreview> _prepare(
    ComputerGroupMember sponsor,
    Future<(_GroupInvite, Object?)> Function(LinkPeer) preview, {
    List<String>? nearby,
  }) async {
    if (!ready ||
        group != null ||
        confirming != null ||
        _preparing != null ||
        _creating) {
      throw ComputerGroupWire.rejected;
    }
    final epoch = this.epoch!;
    final attempt = _preparing = Object();
    _clearPreview();
    joinFailed = false;
    LinkPeer? peer;
    try {
      peer = await dial(sponsor, nearby: nearby ?? const []);
      final (invite, history) = await preview(peer);
      final proposed = nearby == null ? ComputerGroup.decode(history) : null;
      if (!ready ||
          this.epoch != epoch ||
          _preparing != attempt ||
          peer.isClosed ||
          !invite.valid ||
          group != null ||
          invite.sponsor.id != peer.remote ||
          (proposed != null &&
              (proposed.id != invite.group ||
                  !proposed.active.containsKey(peer.remote) ||
                  proposed.known.containsKey(host.id)))) {
        throw ComputerGroupWire.rejected;
      }
      final result = _preview = ComputerGroupJoinPreview._(
        proposed,
        invite.sponsor,
        invite.sponsor.codeWith(host.id),
        invite,
        epoch,
      );
      if (nearby != null) {
        _previewPeer = peer;
        _previewTimer = Timer(
          invite.expires.difference(DateTime.now()),
          () => cancel(result),
        );
        unawaited(
          peer.done.then((_) {
            if (_preview == result && confirming != result) _clearPreview();
          }),
        );
      }
      return result;
    } finally {
      if (_preparing == attempt) _preparing = null;
      if (_previewPeer != peer) await peer?.close();
    }
  }

  void _clearPreview() {
    _previewTimer?.cancel();
    _previewTimer = null;
    _preview = null;
    final peer = _previewPeer;
    _previewPeer = null;
    unawaited(peer?.close());
  }

  void cancel(ComputerGroupJoinPreview preview) {
    if (_preview != preview) return;
    _clearPreview();
    unawaited(_joinPeer?.close());
  }

  Future<void> confirm(ComputerGroupJoinPreview preview) async {
    bool current() =>
        ready &&
        group == null &&
        _preview == preview &&
        epoch == preview._epoch;
    if (!current() || !preview._invite.valid || confirming != null) {
      throw ComputerGroupWire.rejected;
    }
    _previewTimer?.cancel();
    _previewTimer = null;
    confirming = preview;
    joinFailed = false;
    host.notifyListeners();
    LinkPeer? peer;
    try {
      peer = _previewPeer ?? await dial(preview._invite.sponsor);
      if (!current() || !preview._invite.valid || _joinPeer != null) {
        throw ComputerGroupWire.rejected;
      }
      _joinPeer = peer;
      final consent = ComputerGroupConsent.sign(
        preview.groupId,
        preview.sponsor.id,
        preview._invite.token,
        _self,
        host._identity,
      );
      final answer = await peer.call(ComputerGroupWire.join, {
        'consent': consent.toJson(),
      }, const Duration(minutes: 2));
      await _serial(() async {
        if (!current() || _joinPeer != peer) throw ComputerGroupWire.rejected;
        final verified =
            preview._history?.merge(answer) ?? ComputerGroup.decode(answer);
        if (verified.id != preview.groupId ||
            !verified.includesConsent(consent) ||
            !verified.active.containsKey(host.id) ||
            !verified.active.containsKey(peer!.remote)) {
          throw ComputerGroupWire.rejected;
        }
        await _persist(verified);
        startSync();
      });
    } on Object {
      joinFailed = _preview == preview;
      rethrow;
    } finally {
      if (_joinPeer == peer) _joinPeer = null;
      if (_preview == preview) _clearPreview();
      if (confirming == preview) confirming = null;
      host.notifyListeners();
      await peer?.close();
    }
    await sync();
  }

  void deny(ComputerGroupApproval request) {
    if (pending != request || request._approving) return;
    _clearPending(request);
  }

  void _clearPending(ComputerGroupApproval request) {
    if (pending == request) {
      pending = null;
      host.notifyListeners();
    }
    if (!request._result.isCompleted) request._result.complete(null);
  }

  Future<void> approve(ComputerGroupApproval request) async {
    if (pending != request || request._approving) {
      throw ComputerGroupWire.rejected;
    }
    request._approving = true;
    try {
      final others = await _serial(() async {
        final remote = request._peer.remote;
        final window = request._window;
        if (window != null && !await _onLan(request._peer)) {
          throw ComputerGroupWire.rejected;
        }
        if (pending != request ||
            request._peer.isClosed ||
            !request._invite.valid ||
            !_validInvite(window ?? request._invite, remote)) {
          throw ComputerGroupWire.rejected;
        }
        final prior = group!;
        await _persist(prior.admit(request._consent, host._identity));
        _clearInvite();
        return prior.active.values
            .where((member) => member.id != host.id)
            .toList();
      });
      // Share verified introductions with currently reachable members before
      // acknowledging. The next workspace connection never goes via the sponsor.
      await sync(others);
      if (!request._result.isCompleted &&
          group?.active.containsKey(request.member.id) == true) {
        request._result.complete(group);
      }
    } finally {
      _clearPending(request);
    }
  }

  Future<ComputerGroup> _mergeFrom(
    String remote,
    Object? wire,
  ) => _serial(() async {
    final prior = group;
    if (!ready || prior == null || remote == host.id) {
      throw ComputerGroupWire.rejected;
    }
    if (prior.removed.contains(remote)) {
      // A removed device may receive its own removal proof, but cannot
      // advance our log or receive future membership changes.
      if (!ComputerGroup.reportedEvents(wire).contains(prior.id)) {
        throw ComputerGroupWire.rejected;
      }
      _observe(remote, wire, prior);
      return prior;
    }
    if (prior.known.containsKey(remote) && !prior.active.containsKey(remote)) {
      throw ComputerGroupWire.rejected;
    }
    final next = prior.merge(wire);
    if (!prior.active.containsKey(remote) && !next.active.containsKey(remote)) {
      throw ComputerGroupWire.rejected;
    }
    await _persist(next);
    _observe(remote, wire, next);
    return next;
  });

  Future<ComputerGroup> syncPeer(LinkPeer peer) async {
    final current = group;
    if (current == null ||
        !ready ||
        !current.active.containsKey(host.id) ||
        _denied.contains(host.id) ||
        !current.known.containsKey(peer.remote)) {
      throw ComputerGroupWire.rejected;
    }
    final history = current.removed.contains(peer.remote)
        ? current.removalProof(peer.remote)
        : current.toJson();
    final reply = await peer.call(ComputerGroupWire.sync, {
      'history': history,
    }, const Duration(seconds: 8));
    return _mergeFrom(peer.remote, reply);
  }

  Future<LinkPeer> open(String id, {required Iterable<String> nearby}) async {
    final member = group?.active[id];
    if (member == null || !permits(id)) throw ComputerGroupWire.rejected;
    final peer = await dial(member, nearby: nearby);
    try {
      await syncPeer(peer);
      if (!permits(id)) throw ComputerGroupWire.rejected;
      await peer.call(ComputerGroupWire.open, {'group': group!.id});
      if (!permits(id) || peer.isClosed) throw ComputerGroupWire.rejected;
      return peer;
    } on Object {
      await peer.close();
      rethrow;
    }
  }

  void startSync() {
    if (!ready || group == null || _periodic != null) return;
    _periodic = Timer.periodic(
      const Duration(seconds: 45),
      (_) => unawaited(sync()),
    );
  }

  void stopSync() {
    _periodic?.cancel();
    _periodic = null;
    _clearInvite();
    _preparing = null;
    _clearPreview();
    unawaited(_joinPeer?.close());
    if (pending case final request?) _clearPending(request);
  }

  Future<void> sync([Iterable<ComputerGroupMember>? targets]) async {
    if (!ready ||
        group?.active.containsKey(host.id) != true ||
        (targets == null && _syncing)) {
      return;
    }
    if (targets == null) _syncing = true;
    try {
      final members = targets ?? group!.known.values;
      final list = members
          .where(
            (member) =>
                member.id != host.id &&
                (permits(member.id) ||
                    (group!.removed.contains(member.id) &&
                        pendingRemoval(member.id).contains(member.id))),
          )
          .toList();
      // Bound concurrent maintenance links. None opens a workspace.
      for (var start = 0; start < list.length && ready; start += 4) {
        await Future.wait(
          list.skip(start).take(4).map((member) async {
            LinkPeer? peer;
            try {
              peer = await dial(member, timeout: const Duration(seconds: 5));
              await syncPeer(peer);
            } on Object {
              // Offline is normal. A later connection or sync will retry.
            } finally {
              await peer?.close();
            }
          }),
        );
      }
    } finally {
      if (targets == null) _syncing = false;
    }
  }

  Future<Object?> handle(
    _Connection connection,
    String method,
    Map<String, Object?> params,
  ) async {
    if (!ready ||
        connection.peer.isClosed ||
        connection.phone != null ||
        host._pending?._connection == connection) {
      throw ComputerGroupWire.rejected;
    }
    connection.groupControl = true;
    final remote = connection.id;
    switch (method) {
      case ComputerGroupWire.prepare:
        final invite = _invite;
        if (invite == null ||
            !_validInvite(invite, remote) ||
            params['group'] != invite.group ||
            params['token'] is! String ||
            !LinkHost._same(
              utf8.encode(params['token']! as String),
              utf8.encode(invite.token),
            )) {
          throw ComputerGroupWire.rejected;
        }
        return group!.toJson();
      case ComputerGroupWire.prepareNearby:
        final window = _invite;
        if (window == null ||
            !invitingNearby ||
            !_validInvite(window, remote) ||
            !await _onLan(connection.peer) ||
            !invitingNearby ||
            !_validInvite(window, remote) ||
            connection.nearbyInvite != null) {
          throw ComputerGroupWire.rejected;
        }
        final invite = _GroupInvite(
          window.group,
          _self,
          encodeKey(randomBytes(16)),
          window.expires,
        );
        connection.nearbyInvite = (window: window, invite: invite);
        return {'invite': invite.encode()};
      case ComputerGroupWire.join:
        final nearby = connection.nearbyInvite;
        final invite = nearby?.invite ?? _invite;
        final window = nearby?.window ?? invite;
        if (nearby != null && !await _onLan(connection.peer)) {
          throw ComputerGroupWire.rejected;
        }
        if (invite == null ||
            window == null ||
            !_validInvite(window, remote) ||
            !invite.valid ||
            connection.peer.isClosed ||
            pending != null) {
          throw ComputerGroupWire.rejected;
        }
        final consent = ComputerGroupConsent.decode(params['consent']);
        if (consent.member.id != remote ||
            consent.group != invite.group ||
            consent.sponsor != host.id ||
            !LinkHost._same(
              utf8.encode(consent.nonce),
              utf8.encode(invite.token),
            ) ||
            !consent.verifies) {
          throw ComputerGroupWire.rejected;
        }
        final request = pending = ComputerGroupApproval._(
          consent.member,
          invite.sponsor.codeWith(remote),
          consent,
          connection.peer,
          invite,
          nearby?.window,
        );
        unawaited(connection.peer.done.then((_) => _clearPending(request)));
        host.notifyListeners();
        try {
          final joined = await request._result.future.timeout(
            const Duration(minutes: 2),
          );
          if (joined == null) throw ComputerGroupWire.rejected;
          return joined.toJson();
        } finally {
          _clearPending(request);
        }
      case ComputerGroupWire.sync:
        final next = await _mergeFrom(remote, params['history']);
        connection.groupSynced = true;
        if (next.removed.contains(remote)) return next.removalProof(remote);
        if (next.removed.contains(host.id)) return next.removalProof(host.id);
        return next.toJson();
      case ComputerGroupWire.open:
        if (!connection.groupSynced ||
            !permits(remote) ||
            params['group'] != group?.id ||
            connection.peer.isClosed) {
          throw ComputerGroupWire.rejected;
        }
        if (!connection.groupWorkspace) {
          for (final other in [...host._connections]) {
            if (other != connection &&
                other.id == remote &&
                other.groupWorkspace) {
              other.groupWorkspace = false;
              other.bridge?.dispose();
              other.bridge = null;
              unawaited(other.peer.close());
            }
          }
          connection.groupWorkspace = true;
          host._startBridge(connection);
        }
        return {'device': host._deviceInfo().toJson()};
      default:
        throw ComputerGroupWire.rejected;
    }
  }
}
