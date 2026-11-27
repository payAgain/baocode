import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'conversation_search.dart' show snippetAt;
import 'memory_history_store_stub.dart'
    if (dart.library.io) 'memory_history_store_io.dart';

/// A history owner, derived from host routing rather than message text.
enum MemoryHistoryScopeKind { bot, dm, group, project }

final class MemoryHistoryScope {
  const MemoryHistoryScope.bot(this.botId)
    : kind = MemoryHistoryScopeKind.bot,
      groupId = null,
      projectId = null;
  const MemoryHistoryScope.dm(this.botId)
    : kind = MemoryHistoryScopeKind.dm,
      groupId = null,
      projectId = null;
  const MemoryHistoryScope.group(this.botId, String this.groupId)
    : kind = MemoryHistoryScopeKind.group,
      projectId = null;
  const MemoryHistoryScope.project(this.botId, String this.projectId)
    : kind = MemoryHistoryScopeKind.project,
      groupId = null;

  final MemoryHistoryScopeKind kind;
  final String botId;
  final String? groupId;
  final String? projectId;

  bool get _valid =>
      _isId(botId) &&
      (groupId == null || _isId(groupId)) &&
      (projectId == null || _isId(projectId));

  @override
  bool operator ==(Object other) =>
      other is MemoryHistoryScope &&
      other.kind == kind &&
      other.botId == botId &&
      other.groupId == groupId &&
      other.projectId == projectId;

  @override
  int get hashCode => Object.hash(kind, botId, groupId, projectId);

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'botId': botId,
    'groupId': ?groupId,
    'projectId': ?projectId,
  };

  static MemoryHistoryScope? fromJson(Object? value) {
    if (value is! Map<String, Object?> || value['botId'] is! String) {
      return null;
    }
    final botId = value['botId']! as String;
    final scope = switch ((
      value['kind'],
      value['groupId'],
      value['projectId'],
    )) {
      ('bot', null, null) => MemoryHistoryScope.bot(botId),
      ('dm', null, null) => MemoryHistoryScope.dm(botId),
      ('group', final String groupId, null) => MemoryHistoryScope.group(
        botId,
        groupId,
      ),
      ('project', null, final String projectId) => MemoryHistoryScope.project(
        botId,
        projectId,
      ),
      _ => null,
    };
    return scope != null && scope._valid ? scope : null;
  }
}

/// Validated host grants for the current request. A grant for a second scope
/// still requires an explicit target. A group turn cannot search another scope.
final class MemoryHistoryAccess {
  MemoryHistoryAccess({
    required this.current,
    Iterable<MemoryHistoryScope> allowed = const [],
    required this.isAuthorized,
  }) : allowed = Set.unmodifiable(allowed);

  final MemoryHistoryScope current;
  final Set<MemoryHistoryScope> allowed;

  /// The caller checks current Bot, project or membership authorization here.
  /// This must be live: authorization is checked again after asynchronous I/O.
  final bool Function(MemoryHistoryScope) isAuthorized;

  bool permits(MemoryHistoryScope scope) =>
      current._valid &&
      scope._valid &&
      scope.botId == current.botId &&
      (scope == current ||
          current.kind != MemoryHistoryScopeKind.group &&
              allowed.contains(scope)) &&
      isAuthorized(current) &&
      (scope == current || isAuthorized(scope));
}

/// A source locator, independent of the index generation and query cursor.
final class MemoryHistoryReference {
  const MemoryHistoryReference({
    required this.scope,
    required this.sessionId,
    required this.messageId,
  });

  final MemoryHistoryScope scope;
  final String sessionId;
  final String messageId;

  bool get _valid => scope._valid && _isId(sessionId) && _isId(messageId);

  @override
  bool operator ==(Object other) =>
      other is MemoryHistoryReference &&
      other.scope == scope &&
      other.sessionId == sessionId &&
      other.messageId == messageId;

  @override
  int get hashCode => Object.hash(scope, sessionId, messageId);

  Map<String, Object?> toJson() => {
    'scope': scope.toJson(),
    'sessionId': sessionId,
    'messageId': messageId,
  };

  static MemoryHistoryReference? fromJson(Object? value) {
    if (value is! Map<String, Object?>) return null;
    final scope = MemoryHistoryScope.fromJson(value['scope']);
    final sessionId = value['sessionId'];
    final messageId = value['messageId'];
    if (scope == null || sessionId is! String || messageId is! String) {
      return null;
    }
    final ref = MemoryHistoryReference(
      scope: scope,
      sessionId: sessionId,
      messageId: messageId,
    );
    return ref._valid ? ref : null;
  }
}

enum MemoryHistoryRole { user, assistant, unknown }

enum MemoryHistoryKind { original, diarySummary }

/// A visible original message or a separately identified diary summary.
final class MemoryHistoryMessage {
  const MemoryHistoryMessage({
    required this.reference,
    required this.role,
    required this.text,
    required this.time,
    required this.sequence,
    this.projectId,
    this.senderId,
    this.kind = MemoryHistoryKind.original,
  });

  final MemoryHistoryReference reference;
  final MemoryHistoryRole role;
  final String text;
  final DateTime time;

  /// Order in the conversation, for browsing original context.
  final int sequence;

  /// Optional project classification inside the message's owning scope.
  final String? projectId;

  /// The persisted sender ID when the source records individual participants.
  final String? senderId;
  final MemoryHistoryKind kind;

  Map<String, Object?> toJson() => {
    'reference': reference.toJson(),
    'role': role.name,
    if (kind != MemoryHistoryKind.original) 'kind': kind.name,
    'text': text,
    'time': time.toUtc().toIso8601String(),
    'sequence': sequence,
    'projectId': ?_projectOf(reference.scope, projectId),
    'senderId': ?senderId,
  };
}

/// Host callbacks see typed, authorized targets when used by a query. Lifecycle
/// calls are trusted host operations. Only committed visible messages belong in
/// these callbacks. The index never scans arbitrary runtime files or transcripts.
final class MemoryHistorySource {
  const MemoryHistorySource({
    required this.load,
    required this.read,
    this.loadSession,
    this.readMany,
    this.checkpoint,
  });

  /// Authoritative complete set for one scope, including all retained sessions.
  final Future<List<MemoryHistoryMessage>> Function(MemoryHistoryScope) load;

  /// Loads one session's visible messages for an original conversation window.
  final Future<List<MemoryHistoryMessage>> Function(MemoryHistoryScope, String)?
  loadSession;

  /// Reads an exact visible message again, or null if removed or undisclosed.
  final Future<MemoryHistoryMessage?> Function(MemoryHistoryReference) read;

  /// Optional batch equivalent of [read], for sources read as a single snapshot.
  final Future<List<MemoryHistoryMessage>> Function(
    MemoryHistoryScope,
    List<MemoryHistoryReference>,
  )?
  readMany;

  /// Optional cheap freshness check. A non-null checkpoint must change whenever
  /// the persisted messages or their scope change, including across restarts.
  /// Returning null rebuilds from the authoritative set on each search.
  final Future<String?> Function(MemoryHistoryScope)? checkpoint;
}

final class MemoryHistoryQuery {
  const MemoryHistoryQuery({
    this.text = '',
    this.scope,
    this.since,
    this.before,
    this.projectId,
    this.sessionId,
    this.cursor,
    this.limit = 12,
  });

  /// A literal search term. Empty or whitespace-only text lists recent messages.
  final String text;
  final MemoryHistoryScope? scope;

  /// Inclusive lower / exclusive upper bound.
  final DateTime? since;
  final DateTime? before;
  final String? projectId;
  final String? sessionId;
  final String? cursor;
  final int limit;
}

final class MemoryHistoryHit {
  const MemoryHistoryHit({
    required this.reference,
    required this.role,
    required this.time,
    required this.snippet,
    required this.matchStart,
    required this.matchLength,
    this.projectId,
    this.senderId,
    this.kind = MemoryHistoryKind.original,
  });

  final MemoryHistoryReference reference;
  final MemoryHistoryRole role;
  final DateTime time;
  final String snippet;
  final int matchStart;
  final int matchLength;
  final String? projectId;
  final String? senderId;
  final MemoryHistoryKind kind;

  Map<String, Object?> toJson() => {
    'reference': reference.toJson(),
    'role': role.name,
    if (kind != MemoryHistoryKind.original) 'kind': kind.name,
    'time': time.toUtc().toIso8601String(),
    'snippet': snippet,
    'matchStart': matchStart,
    'matchLength': matchLength,
    'projectId': ?projectId,
    'senderId': ?senderId,
  };
}

final class MemoryHistoryPage {
  const MemoryHistoryPage({this.hits = const [], this.cursor});

  final List<MemoryHistoryHit> hits;
  final String? cursor;

  Map<String, Object?> toJson() => {
    'hits': [for (final hit in hits) hit.toJson()],
    'cursor': ?cursor,
  };
}

final class MemoryHistoryWindow {
  const MemoryHistoryWindow({
    required this.anchor,
    required this.before,
    required this.after,
  });

  final MemoryHistoryMessage anchor;
  final List<MemoryHistoryMessage> before;
  final List<MemoryHistoryMessage> after;

  Map<String, Object?> toJson() => {
    'anchor': anchor.toJson(),
    'before': [for (final message in before) message.toJson()],
    'after': [for (final message in after) message.toJson()],
  };
}

/// A host-local, rebuildable index of visible history. Unicode uni-, bi- and
/// trigrams are indexed separately in each exact scope. They only identify
/// candidates: the literal match and the snippet are checked against source.
/// [path], when supplied, is a private host cache directory for index shards.
final class MemoryHistoryIndex {
  MemoryHistoryIndex({required this.source, String? path})
    : _store = MemoryHistoryStore(path);

  final MemoryHistorySource source;
  final MemoryHistoryStore _store;
  final _shards = <MemoryHistoryScope, _HistoryShard>{};
  final _scopeEpochs = <MemoryHistoryScope, int>{};
  final _botEpochs = <String, int>{};
  Future<void> _pending = Future.value();

  static const _cacheVersion = 2;
  static const _keptShards = 8;
  static const _maxQuery = 256;
  static const _maxHits = 50;
  static const _maxNeighbors = 20;
  static const _readBatchSize = 32;

  Future<MemoryHistoryPage> search(
    MemoryHistoryAccess access,
    MemoryHistoryQuery query,
  ) async {
    final scope = query.scope ?? access.current;
    final needle = query.text.trim();
    if (needle.length > _maxQuery ||
        query.limit < 1 ||
        (query.projectId != null && !_isId(query.projectId)) ||
        (query.sessionId != null && !_isId(query.sessionId)) ||
        (query.since != null &&
            query.before != null &&
            !query.since!.isBefore(query.before!)) ||
        !access.permits(scope)) {
      return const MemoryHistoryPage();
    }

    final folded = needle.toLowerCase();
    final signature = _digest([
      scope.toJson(),
      folded,
      query.since?.microsecondsSinceEpoch,
      query.before?.microsecondsSinceEpoch,
      query.projectId,
      query.sessionId,
    ]);
    final cursor = _HistoryOrder.decode(query.cursor, signature);
    if (query.cursor != null && cursor == null) {
      return const MemoryHistoryPage();
    }
    final stillCurrent = _guard(access, scope);
    final shard = await _enqueue(() => _refresh(scope, stillCurrent));
    if (shard == null || !stillCurrent()) return const MemoryHistoryPage();

    final matching = folded.isEmpty
        ? shard.rows.values
        : await shard.candidates(folded);
    if (!stillCurrent()) return const MemoryHistoryPage();
    final candidates = matching.where((row) {
      return (cursor == null || row.order.compareTo(cursor) > 0) &&
          (query.since == null ||
              row.order.time >= query.since!.microsecondsSinceEpoch) &&
          (query.before == null ||
              row.order.time < query.before!.microsecondsSinceEpoch) &&
          (query.sessionId == null ||
              row.reference.sessionId == query.sessionId) &&
          (query.projectId == null || row.projectId == query.projectId) &&
          row.folded.contains(folded);
    }).toList()..sort((a, b) => a.order.compareTo(b.order));

    final hits = <MemoryHistoryHit>[];
    final limit = query.limit.clamp(1, _maxHits);
    _HistoryOrder? last;
    for (var start = 0; start < candidates.length; start += _readBatchSize) {
      final end = (start + _readBatchSize).clamp(0, candidates.length);
      final batch = candidates.sublist(start, end);
      final live = await _read(scope, batch.map((row) => row.reference));
      if (!stillCurrent()) return const MemoryHistoryPage();
      for (final row in batch) {
        final message = live[row.reference];
        if (message == null || !row.matches(message)) continue;
        final hit = _hit(message, folded);
        if (hit == null) continue;
        if (hits.length == limit) {
          return MemoryHistoryPage(
            hits: List.unmodifiable(hits),
            cursor: last!.encode(signature),
          );
        }
        hits.add(hit);
        last = row.order;
      }
    }
    return MemoryHistoryPage(hits: List.unmodifiable(hits));
  }

  /// Return the original visible message. The supplied locator cannot select
  /// another scope unless the host granted one and the request explicitly asks.
  Future<MemoryHistoryMessage?> locate(
    MemoryHistoryAccess access,
    MemoryHistoryReference reference, {
    MemoryHistoryScope? scope,
  }) async {
    final target = scope ?? access.current;
    if (!_canOpen(access, target, reference)) return null;
    final stillCurrent = _guard(access, target);
    final message = await source.read(reference);
    return stillCurrent() && message?.reference == reference ? message : null;
  }

  /// Original visible messages on either side of an exact reference. A window
  /// never crosses a scope or session boundary.
  Future<MemoryHistoryWindow?> browse(
    MemoryHistoryAccess access,
    MemoryHistoryReference reference, {
    MemoryHistoryScope? scope,
    int before = 5,
    int after = 5,
  }) async {
    final target = scope ?? access.current;
    if (!_canOpen(access, target, reference)) return null;
    final stillCurrent = _guard(access, target);
    final loadSession = source.loadSession;
    final messages = await (loadSession == null
        ? source.load(target)
        : loadSession(target, reference.sessionId));
    if (!stillCurrent()) return null;
    final sameSession = {
      for (final message in messages)
        if (message.reference._valid &&
            message.reference.scope == target &&
            message.reference.sessionId == reference.sessionId)
          message.reference: message,
    }.values.toList()..sort(_conversationOrder);
    final at = sameSession.indexWhere(
      (message) => message.reference == reference,
    );
    if (at < 0) return null;
    final start = (at - before.clamp(0, _maxNeighbors)).clamp(0, at);
    final end = (at + after.clamp(0, _maxNeighbors) + 1).clamp(
      at + 1,
      sameSession.length,
    );
    final live = await _read(
      target,
      sameSession.sublist(start, end).map((message) => message.reference),
    );
    if (!stillCurrent()) return null;
    final anchor = live[reference];
    if (anchor == null || anchor.sequence != sameSession[at].sequence) {
      return null;
    }
    List<MemoryHistoryMessage> around(int from, int to) => List.unmodifiable([
      for (final message in sameSession.getRange(from, to))
        if (live[message.reference] case final original?
            when original.sequence == message.sequence)
          original,
    ]);
    return MemoryHistoryWindow(
      anchor: anchor,
      before: around(start, at),
      after: around(at + 1, end),
    );
  }

  /// Drop derived data after clearing or removing this scope. A query already
  /// awaiting a source read cannot publish its pre-invalidation results.
  Future<void> invalidate(MemoryHistoryScope scope) {
    _scopeEpochs.update(scope, (value) => value + 1, ifAbsent: () => 1);
    return _enqueue(() async {
      _shards.remove(scope);
      await _store.remove(_shardKey(scope));
    });
  }

  /// Delete the index for all scopes of a removed Bot. The original messages
  /// are governed by the caller's separate retention and removal rules.
  Future<void> invalidateBot(String botId) {
    _botEpochs.update(botId, (value) => value + 1, ifAbsent: () => 1);
    return _enqueue(() async {
      _shards.removeWhere((scope, _) => scope.botId == botId);
      await _store.removeBot(_botKey(botId));
    });
  }

  /// Force the next shard to be derived entirely from persisted source records.
  Future<void> rebuild(MemoryHistoryScope scope) async {
    final clear = invalidate(scope);
    final epoch = _epoch(scope);
    await clear;
    await _enqueue(() => _refresh(scope, () => _epoch(scope) == epoch));
  }

  bool _canOpen(
    MemoryHistoryAccess access,
    MemoryHistoryScope target,
    MemoryHistoryReference reference,
  ) => reference._valid && target == reference.scope && access.permits(target);

  (int, int) _epoch(MemoryHistoryScope scope) =>
      (_botEpochs[scope.botId] ?? 0, _scopeEpochs[scope] ?? 0);

  bool Function() _guard(MemoryHistoryAccess access, MemoryHistoryScope scope) {
    final epoch = _epoch(scope);
    return () => _epoch(scope) == epoch && access.permits(scope);
  }

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final next = _pending.then((_) => action());
    _pending = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<Map<MemoryHistoryReference, MemoryHistoryMessage>> _read(
    MemoryHistoryScope scope,
    Iterable<MemoryHistoryReference> references,
  ) async {
    final requests = references.toSet();
    final readMany = source.readMany;
    final originals = readMany == null
        ? (await Future.wait(requests.map(source.read))).nonNulls
        : await readMany(scope, requests.toList(growable: false));
    return {
      for (final original in originals)
        if (requests.contains(original.reference)) original.reference: original,
    };
  }

  Future<_HistoryShard?> _refresh(
    MemoryHistoryScope scope,
    bool Function() stillCurrent,
  ) async {
    if (!stillCurrent()) return null;
    final key = _shardKey(scope);
    final checkpoint = await source.checkpoint?.call(scope);
    if (!stillCurrent()) return null;
    var previous = _shards[scope];
    if (previous == null && checkpoint != null) {
      previous = _decodeShard(await _store.read(key), scope, checkpoint);
    }
    if (!stillCurrent()) return null;
    if (checkpoint != null && previous?.checkpoint == checkpoint) {
      return _remember(scope, previous!);
    }
    final messages = await source.load(scope);
    if (!stillCurrent()) return null;
    final checked = await source.checkpoint?.call(scope);
    if (!stillCurrent()) return null;
    // If records changed during the scan, never mark them as a current snapshot.
    final rows = {
      for (final message in messages)
        if (message.reference._valid &&
            message.reference.scope == scope &&
            message.text.trim().isNotEmpty)
          message.reference: _IndexedRow.fromMessage(message),
    };
    final next = _HistoryShard(checked == checkpoint ? checked : null, rows);
    final shard = previous != null && next.sameRows(previous)
        ? previous.withCheckpoint(next.checkpoint)
        : next;
    if (shard.checkpoint != null && shard.checkpoint != previous?.checkpoint) {
      await _store.write(key, _encodeShard(shard));
    } else if (shard.checkpoint == null && _store.enabled) {
      await _store.remove(key);
    }
    if (!stillCurrent()) return null;
    return _remember(scope, shard);
  }

  _HistoryShard _remember(MemoryHistoryScope scope, _HistoryShard shard) {
    _shards.remove(scope);
    _shards[scope] = shard;
    if (_shards.length > _keptShards) _shards.remove(_shards.keys.first);
    return shard;
  }

  static String _botKey(String botId) => _digest(botId);
  static String _shardKey(MemoryHistoryScope scope) =>
      '${_botKey(scope.botId)}-${_digest(scope.toJson())}';

  static String _encodeShard(_HistoryShard shard) => jsonEncode({
    'version': _cacheVersion,
    'checkpoint': shard.checkpoint,
    'rows': [for (final row in shard.rows.values) row.toJson()],
  });

  static _HistoryShard? _decodeShard(
    String? text,
    MemoryHistoryScope scope,
    String checkpoint,
  ) {
    if (text == null) return null;
    try {
      final data = jsonDecode(text);
      if (data is! Map<String, Object?> ||
          data['version'] != _cacheVersion ||
          data['checkpoint'] != checkpoint ||
          data['rows'] is! List<Object?>) {
        return null;
      }
      final rows = <MemoryHistoryReference, _IndexedRow>{};
      for (final value in data['rows']! as List<Object?>) {
        final row = _IndexedRow.fromJson(value, scope);
        if (row == null || rows.containsKey(row.reference)) return null;
        rows[row.reference] = row;
      }
      return _HistoryShard(checkpoint, rows);
    } on FormatException {
      return null;
    }
  }
}

bool _isId(String? value) =>
    value != null &&
    value.isNotEmpty &&
    value.length <= 4096 &&
    !value.contains('\u0000');

String? _projectOf(MemoryHistoryScope scope, String? classification) =>
    scope.projectId ?? classification;

String _digest(Object value) =>
    sha256.convert(utf8.encode(jsonEncode(value))).toString();

int _conversationOrder(MemoryHistoryMessage a, MemoryHistoryMessage b) {
  final bySequence = a.sequence.compareTo(b.sequence);
  return bySequence == 0
      ? a.reference.messageId.compareTo(b.reference.messageId)
      : bySequence;
}

MemoryHistoryHit? _hit(MemoryHistoryMessage message, String needle) {
  final original = message.text;
  final lower = original.toLowerCase();
  final at = lower.indexOf(needle);
  if (at < 0) return null;
  final end = at + needle.length;
  var from = at;
  var to = end;
  if (original.length != lower.length) {
    // A lowercase expansion can make normalized offsets differ from source.
    var foldedOffset = 0;
    var originalOffset = 0;
    for (final rune in original.runes) {
      final char = String.fromCharCode(rune);
      final next = foldedOffset + char.toLowerCase().length;
      if (foldedOffset <= at && at < next) from = originalOffset;
      if (foldedOffset < end && end <= next) {
        to = originalOffset + char.length;
        break;
      }
      foldedOffset = next;
      originalOffset += char.length;
    }
  }
  final contextStart = (from - 32).clamp(0, from);
  final contextEnd = (to + 96).clamp(to, original.length);
  bool splitsRune(int index) =>
      index > 0 &&
      index < original.length &&
      (original.codeUnitAt(index) & 0xfc00) == 0xdc00 &&
      (original.codeUnitAt(index - 1) & 0xfc00) == 0xd800;
  final result = snippetAt(
    message.reference.sessionId,
    original,
    from,
    to - from,
    before: splitsRune(contextStart) ? 33 : 32,
    after: splitsRune(contextEnd) ? 97 : 96,
  );
  return MemoryHistoryHit(
    reference: message.reference,
    role: message.role,
    time: message.time,
    snippet: result.snippet,
    matchStart: result.matchStart,
    matchLength: result.matchLength,
    projectId: _projectOf(message.reference.scope, message.projectId),
    senderId: message.senderId,
    kind: message.kind,
  );
}

final class _HistoryOrder implements Comparable<_HistoryOrder> {
  const _HistoryOrder(this.time, this.sessionId, this.sequence, this.messageId);

  final int time;
  final String sessionId;
  final int sequence;
  final String messageId;

  @override
  int compareTo(_HistoryOrder other) {
    var compared = other.time.compareTo(time);
    if (compared != 0) return compared;
    compared = sessionId.compareTo(other.sessionId);
    if (compared != 0) return compared;
    compared = other.sequence.compareTo(sequence);
    return compared == 0 ? messageId.compareTo(other.messageId) : compared;
  }

  String encode(String signature) => base64Url.encode(
    utf8.encode(jsonEncode([signature, time, sessionId, sequence, messageId])),
  );

  static _HistoryOrder? decode(String? value, String signature) {
    if (value == null || value.length > 65536) return null;
    try {
      final decoded = jsonDecode(utf8.decode(base64Url.decode(value)));
      return switch (decoded) {
        [
          final String key,
          final int at,
          final String session,
          final int seq,
          final String message,
        ]
            when key == signature && _isId(session) && _isId(message) =>
          _HistoryOrder(at, session, seq, message),
        _ => null,
      };
    } on FormatException {
      return null;
    }
  }
}

final class _IndexedRow {
  const _IndexedRow(
    this.reference,
    this.role,
    this.folded,
    this.order,
    this.projectId,
    this.kind,
  );

  factory _IndexedRow.fromMessage(MemoryHistoryMessage message) => _IndexedRow(
    message.reference,
    message.role,
    message.text.toLowerCase(),
    _HistoryOrder(
      message.time.microsecondsSinceEpoch,
      message.reference.sessionId,
      message.sequence,
      message.reference.messageId,
    ),
    _projectOf(message.reference.scope, message.projectId),
    message.kind,
  );

  final MemoryHistoryReference reference;
  final MemoryHistoryRole role;
  final String folded;
  final _HistoryOrder order;
  final String? projectId;
  final MemoryHistoryKind kind;

  bool matches(MemoryHistoryMessage current) =>
      current.reference == reference &&
      current.role == role &&
      current.kind == kind &&
      current.time.microsecondsSinceEpoch == order.time &&
      current.sequence == order.sequence &&
      _projectOf(current.reference.scope, current.projectId) == projectId &&
      current.text.toLowerCase() == folded;

  bool sameRow(_IndexedRow? other) =>
      other != null &&
      role == other.role &&
      kind == other.kind &&
      folded == other.folded &&
      projectId == other.projectId &&
      order.compareTo(other.order) == 0;

  List<Object?> toJson() => [
    reference.sessionId,
    reference.messageId,
    role.name,
    order.time,
    order.sequence,
    projectId,
    folded,
    kind.name,
  ];

  static _IndexedRow? fromJson(Object? json, MemoryHistoryScope scope) {
    if (json
        case [
          final String session,
          final String message,
          final String roleName,
          final int time,
          final int order,
          final String? project,
          final String folded,
          final String kindName,
        ]
        when _isId(session) && _isId(message)) {
      final role = MemoryHistoryRole.values.asNameMap()[roleName];
      final kind = MemoryHistoryKind.values.asNameMap()[kindName];
      if (role == null || kind == null) return null;
      return _IndexedRow(
        MemoryHistoryReference(
          scope: scope,
          sessionId: session,
          messageId: message,
        ),
        role,
        folded,
        _HistoryOrder(time, session, order, message),
        _projectOf(scope, project),
        kind,
      );
    }
    return null;
  }
}

final class _HistoryShard {
  _HistoryShard(this.checkpoint, this.rows);
  _HistoryShard._(this.checkpoint, this.rows, this._postings);

  final String? checkpoint;
  final Map<MemoryHistoryReference, _IndexedRow> rows;
  late final _rowsByOffset = rows.values.toList(growable: false);
  Future<Map<String, Set<int>>>? _postings;

  _HistoryShard withCheckpoint(String? value) =>
      value == checkpoint ? this : _HistoryShard._(value, rows, _postings);

  bool sameRows(_HistoryShard other) =>
      rows.length == other.rows.length &&
      rows.entries.every((entry) => entry.value.sameRow(other.rows[entry.key]));

  Future<Iterable<_IndexedRow>> candidates(String needle) async {
    if (rows.isEmpty) return const [];
    final scalars = needle.runes.toList(growable: false);
    final grams = _grams(scalars, scalars.length.clamp(1, 3)).toSet();
    final postings = await (_postings ??= _preparePostings([
      for (final row in _rowsByOffset) row.folded,
    ]));
    final lists = <Set<int>>[];
    for (final gram in grams) {
      final offsets = postings[gram];
      if (offsets == null) return const [];
      lists.add(offsets);
    }
    lists.sort((a, b) => a.length.compareTo(b.length));
    final smallest = lists.first;
    final others = lists.skip(1);
    return smallest
        .where((offset) => others.every((list) => list.contains(offset)))
        .map((offset) => _rowsByOffset[offset]);
  }
}

Future<Map<String, Set<int>>> _preparePostings(List<String> texts) =>
    runHistoryIndexBuild(() {
      final postings = <String, Set<int>>{};
      for (final (offset, text) in texts.indexed) {
        final runes = text.runes.toList(growable: false);
        for (var size = 1; size <= 3; size++) {
          for (final gram in _grams(runes, size)) {
            (postings[gram] ??= {}).add(offset);
          }
        }
      }
      return postings;
    });

Iterable<String> _grams(List<int> runes, int size) sync* {
  for (var i = 0; i + size <= runes.length; i++) {
    yield String.fromCharCodes(runes, i, i + size);
  }
}
