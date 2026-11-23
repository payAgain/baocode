import 'dart:convert';

import 'package:bao_link/bao_link.dart';
import 'package:crypto/crypto.dart';

import 'desktop_mutual_pairing.dart';

/// Group grants cover the entire BaoCode workspace and membership management.
/// Changing that scope requires a new domain and new explicit consent.
const _domain = 'baocode/computer-group/v1/full-workspace-and-membership';

abstract final class ComputerGroupWire {
  static const prepare = 'computerGroup.prepare';
  static const prepareNearby = 'computerGroup.prepareNearby';
  static const join = 'computerGroup.join';
  static const sync = 'computerGroup.sync';
  static const open = 'computerGroup.open';

  static const prefix = 'computerGroup.';
  static const rejected = LinkRemoteException(
    LinkErrors.rejected,
    'Computer group request rejected',
  );
}

bool _validId(Object? value) =>
    value is String && DesktopMutualPairing.validId(value);
bool _validNonce(String value) => DesktopMutualPairing.validAttempt(value);
Never _invalid() =>
    throw const FormatException('Invalid computer group history');

class ComputerGroupMember {
  ComputerGroupMember({
    required this.id,
    required this.name,
    required Iterable<String> addrs,
    required Iterable<String> relays,
    required this.direct,
  }) : addrs = List.unmodifiable(addrs),
       relays = List.unmodifiable(relays);

  final String id, name;
  final List<String> addrs, relays;
  final bool direct;

  List<Object?> toJson() => [id, name, addrs, relays, direct];

  static ComputerGroupMember decode(Object? value) {
    if (value
        case [
          final String id,
          final String name,
          final List<Object?> addrs,
          final List<Object?> relays,
          final bool direct,
        ]
        when _validId(id) &&
            name.length <= 120 &&
            addrs.length <= 8 &&
            addrs.every((it) => it is String && it.length <= 80) &&
            relays.length <= 16 &&
            relays.every((it) => it is String && it.length <= 256) &&
            (!direct || relays.isEmpty)) {
      return ComputerGroupMember(
        id: id,
        name: name,
        addrs: addrs.cast(),
        relays: relays.cast(),
        direct: direct,
      );
    }
    _invalid();
  }

  LinkAddress address(
    List<String> allowedRelays, {
    Iterable<String> nearby = const [],
  }) {
    final route = DesktopReturnRoute.decode({
      'id': id,
      'direct': direct,
      'addrs': addrs,
      'relays': relays,
    }, allowedRelays: allowedRelays)!.address;
    // Nearby addresses came through BaoCode's existing discovery parser.
    return route.copyWith(addrs: {...nearby, ...route.addrs}.toList());
  }

  String codeWith(String joiner) =>
      safetyCode(keyOfDeviceId(id)!, keyOfDeviceId(joiner)!).join('  ');
}

/// Signed by the prospective member only after their local scope confirmation.
class ComputerGroupConsent {
  ComputerGroupConsent._(
    this.group,
    this.sponsor,
    this.nonce,
    this.member,
    this.signature,
  );
  final String group, sponsor, nonce, signature;
  final ComputerGroupMember member;

  static List<Object?> _body(
    String group,
    String sponsor,
    String nonce,
    ComputerGroupMember member,
  ) => [_domain, 'consent', group, sponsor, nonce, member.toJson()];

  factory ComputerGroupConsent.sign(
    String group,
    String sponsor,
    String nonce,
    ComputerGroupMember member,
    LinkIdentity identity,
  ) {
    if (member.id != identity.id) _invalid();
    return ComputerGroupConsent._(
      group,
      sponsor,
      nonce,
      member,
      identity.sign(
        utf8.encode(jsonEncode(_body(group, sponsor, nonce, member))),
      ),
    );
  }

  List<Object?> toJson() => [group, sponsor, nonce, member.toJson(), signature];

  static ComputerGroupConsent decode(Object? value) {
    if (value
        case [
          final String group,
          final String sponsor,
          final String nonce,
          final Object memberWire,
          final String signature,
        ]
        when _validId(group) && _validId(sponsor) && _validNonce(nonce)) {
      final member = ComputerGroupMember.decode(memberWire);
      return ComputerGroupConsent._(group, sponsor, nonce, member, signature);
    }
    _invalid();
  }

  bool get verifies => LinkIdentity.verifies(
    member.id,
    utf8.encode(jsonEncode(_body(group, sponsor, nonce, member))),
    signature,
  );
}

class _GroupEvent {
  _GroupEvent(
    this.kind,
    this.group,
    this.author,
    Iterable<String> parents,
    Object payload,
    this.signature,
  ) : parents = List.unmodifiable(parents),
      payload = _freeze(payload)!;
  static Object? _freeze(Object? value) => value is List<Object?>
      ? List<Object?>.unmodifiable(value.map(_freeze))
      : value;
  final String kind, group, author, signature;
  final List<String> parents;
  final Object payload;

  List<Object?> get body => [_domain, kind, group, author, parents, payload];
  late final bytes = utf8.encode(jsonEncode(body));
  // Hash the canonical signed body. Alternate encodings of a signature do not
  // create new events, break references, or change the group's fingerprint.
  late final id = sha256.convert(bytes).toString();
  List<Object?> toJson() => [kind, group, author, parents, payload, signature];

  static _GroupEvent sign(
    String kind,
    String group,
    Iterable<String> parents,
    Object payload,
    LinkIdentity identity,
  ) {
    final unsigned = _GroupEvent(
      kind,
      group,
      identity.id,
      parents,
      payload,
      '',
    );
    return _GroupEvent(
      kind,
      group,
      identity.id,
      unsigned.parents,
      payload,
      identity.sign(unsigned.bytes),
    );
  }

  static _GroupEvent decode(Object? value) {
    if (value
        case [
          final String kind,
          final String group,
          final String author,
          final List<Object?> parents,
          final Object payload,
          final String signature,
        ]
        when _validId(author) &&
            signature.length == 86 &&
            parents.length <= ComputerGroup.maxEvents &&
            parents.every(_validId)) {
      final sorted = (parents.cast<String>().toSet().toList()..sort());
      if (sorted.length != parents.length ||
          !Iterable<int>.generate(sorted.length)
              .every((i) => sorted[i] == parents[i])) {
        _invalid();
      }
      final Object canonical;
      switch (kind) {
        case 'create':
          if (group.isNotEmpty || parents.isNotEmpty) _invalid();
          if (payload case [final String nonce, final Object member]
              when _validNonce(nonce)) {
            canonical = [nonce, ComputerGroupMember.decode(member).toJson()];
          } else {
            _invalid();
          }
        case 'add':
          canonical = ComputerGroupConsent.decode(payload).toJson();
        case 'remove':
          if (!_validId(payload)) _invalid();
          canonical = payload;
        default:
          _invalid();
      }
      if (kind != 'create' && (!_validId(group) || parents.isEmpty)) _invalid();
      return _GroupEvent(kind, group, author, sorted, canonical, signature);
    }
    _invalid();
  }
}

/// A pinned genesis and a verified, append-only DAG. An event is authorized
/// against its signed causal past. Concurrent removals are irrevocable, and a
/// removal of an identity dominates every grant for that identity.
class ComputerGroup {
  ComputerGroup._(
    this.id,
    this._events,
    this._history,
    Map<String, ComputerGroupMember> known,
    Set<String> removed,
    Set<String> admitted,
  ) : known = Map.unmodifiable(known),
      removed = Set.unmodifiable(removed),
      active = Map.unmodifiable({
        for (final member in known.entries)
          if (admitted.contains(member.key) && !removed.contains(member.key))
            member.key: member.value,
      });
  static const maxEvents = 256;
  static const _admissionLimit = 64;
  final String id;
  final Map<String, _GroupEvent> _events;
  final Map<String, Set<String>> _history;
  final Map<String, ComputerGroupMember> active, known;
  final Set<String> removed;
  bool get canAdmit => _events.length < _admissionLimit;

  List<Object?> toJson() => [
    for (final id in (_events.keys.toList()..sort())) _events[id]!.toJson(),
  ];
  List<String> get eventIds => _events.keys.toList()..sort();

  bool includesConsent(ComputerGroupConsent consent) {
    final expected = jsonEncode(consent.toJson());
    return _events.values.any(
      (event) =>
          event.kind == 'add' &&
          event.author == consent.sponsor &&
          jsonEncode(event.payload) == expected,
    );
  }

  List<String> get _heads {
    final past = {for (final e in _events.values) ...e.parents};
    return _events.keys.where((id) => !past.contains(id)).toList()..sort();
  }

  List<String> removalsOf(String target) => [
    for (final e in _events.values)
      if (e.kind == 'remove' && e.payload == target) e.id,
  ];
  List<Object?> removalProof(String target) {
    final removals = removalsOf(target);
    final proof = {
      for (final id in removals) ...{id, ..._history[id]!},
    };
    return [for (final id in (proof.toList()..sort())) _events[id]!.toJson()];
  }

  /// Only count exact events sent by the authenticated contact.
  static Set<String> reportedEvents(Object? wire) {
    if (wire is! List<Object?> || wire.isEmpty || wire.length > maxEvents) {
      _invalid();
    }
    return {for (final event in wire) _GroupEvent.decode(event).id};
  }

  static ComputerGroup create(
    ComputerGroupMember founder,
    LinkIdentity identity,
  ) => decode([
    _GroupEvent.sign('create', '', const [], [
      encodeKey(randomBytes(16)),
      founder.toJson(),
    ], identity).toJson(),
  ]);

  ComputerGroup admit(ComputerGroupConsent consent, LinkIdentity identity) {
    if (!canAdmit ||
        !active.containsKey(identity.id) ||
        known.containsKey(consent.member.id)) {
      _invalid();
    }
    return merge([
      _GroupEvent.sign('add', id, _heads, consent.toJson(), identity).toJson(),
    ]);
  }

  ComputerGroup remove(String member, LinkIdentity identity) {
    if (!active.containsKey(identity.id) ||
        !active.containsKey(member) ||
        member == identity.id) {
      _invalid();
    }
    return merge([
      _GroupEvent.sign('remove', id, _heads, member, identity).toJson(),
    ]);
  }

  ComputerGroup merge(Object? wire) => _decode(wire, this);
  static ComputerGroup decode(Object? wire) => _decode(wire, null);

  static ComputerGroup _decode(Object? wire, ComputerGroup? current) {
    if (wire is! List<Object?> || wire.isEmpty || wire.length > maxEvents) {
      _invalid();
    }
    final events = {...?current?._events};
    final checked = {...?current?._history};
    final added = <String, _GroupEvent>{};
    var group = current?.id;
    for (final item in wire) {
      final event = _GroupEvent.decode(item);
      if (events.containsKey(event.id)) continue;
      if (!LinkIdentity.verifies(event.author, event.bytes, event.signature)) {
        _invalid();
      }
      if (event.kind == 'create') {
        if (group != null) _invalid();
        group = event.id;
      }
      events[event.id] = added[event.id] = event;
    }
    if (group == null || events.length > maxEvents) _invalid();
    if (current != null && added.isEmpty) return current;
    final founder = events[group]!;
    final foundingMember = ComputerGroupMember.decode(
      (founder.payload as List)[1],
    );
    if (foundingMember.id != founder.author) _invalid();
    final memberByEvent = <String, ComputerGroupMember>{group: foundingMember};
    for (final event in events.values) {
      if (event.kind == 'add') {
        memberByEvent[event.id] = ComputerGroupConsent.decode(event.payload)
            .member;
      }
    }
    final verifying = <String>{};
    Set<String> verify(String eventId) {
      if (checked[eventId] case final past?) return past;
      final event = events[eventId];
      if (event == null) _invalid();
      if (event.kind == 'create') return checked[eventId] = {};
      if (event.group != group || !verifying.add(eventId)) _invalid();
      try {
        final past = {
          for (final parent in event.parents) ...{parent, ...verify(parent)},
        };
        if (!past.contains(group)) _invalid();
        bool wasKnown(String member) =>
            past.any((e) => memberByEvent[e]?.id == member);
        bool wasActive(String member) =>
            wasKnown(member) &&
            !past.any(
              (e) =>
                  events[e]!.kind == 'remove' && events[e]!.payload == member,
            );
        if (!wasActive(event.author)) _invalid();
        if (event.kind == 'add') {
          final consent = ComputerGroupConsent.decode(event.payload);
          if (consent.group != group ||
              consent.sponsor != event.author ||
              wasKnown(consent.member.id) ||
              !consent.verifies) {
            _invalid();
          }
        } else if (event.payload == event.author ||
            !wasActive(event.payload as String)) {
          _invalid();
        }
        return checked[eventId] = past;
      } finally {
        verifying.remove(eventId);
      }
    }

    for (final event in added.keys) {
      verify(event);
    }
    final known = <String, ComputerGroupMember>{};
    // Deterministic display data if two members concurrently admit the same
    // identity. Authorization always uses the transport key, never its name.
    for (final eventId in (memberByEvent.keys.toList()..sort())) {
      final member = memberByEvent[eventId]!;
      known[member.id] = member;
    }
    final removals = <String, List<String>>{};
    for (final event in events.values) {
      if (event.kind == 'remove') {
        removals.putIfAbsent(event.payload as String, () => []).add(event.id);
      }
    }
    // If a sponsor's removal did not include an admission in its causal
    // history, the two operations have no proven order. Prefer the removal.
    // Admissions already known when that sponsor was removed remain valid.
    final eligible = <String, bool>{group: true};
    bool admittedBy(String grant) => eligible.putIfAbsent(grant, () {
      final author = events[grant]!.author;
      if (removals[author]?.any((id) => !checked[id]!.contains(grant)) ==
          true) {
        return false;
      }
      return checked[grant]!.any(
        (id) => memberByEvent[id]?.id == author && admittedBy(id),
      );
    });
    final admitted = {
      for (final entry in memberByEvent.entries)
        if (admittedBy(entry.key)) entry.value.id,
    };
    return ComputerGroup._(
      group,
      events,
      checked,
      known,
      removals.keys.toSet(),
      admitted,
    );
  }
}
