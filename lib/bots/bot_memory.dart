import 'dart:convert';

import 'package:crypto/crypto.dart';

const botUserMemoryLimit = 1375;

bool botMemoryHasCredential(String text) => _credential.hasMatch(text);

final _credential = RegExp(
  r'''-----BEGIN [^-\r\n]*PRIVATE KEY-----|(?:sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9_]{12,}|github_pat_[A-Za-z0-9_]{12,}|xox[baprs]-[A-Za-z0-9-]{10,}|(?:AKIA|ASIA)[0-9A-Z]{16})|\bBearer\s+\S{8,}|\b(?:api[ _-]?key|client[ _-]?secret|access[ _-]?token|refresh[ _-]?token|password|passwd|authorization)\b["']?\s*[:=]\s*["']?[^\s"']{4,}|https?://[^\s/@:]+:[^\s/@]+@''',
  caseSensitive: false,
);

enum BotMemoryShareSource { preference, privateFact, projectFact }

/// The approval for one immutable copy in a group's memory ledger.
typedef BotMemoryShare = ({
  String id,
  BotMemoryShareSource source,
  String? projectId,
  int sourceId,
  int sourceRevision,
  int sourceGeneration,
  String groupId,
});

BotMemoryShare _decodeShare(Map<String, Object?> json) {
  if (json['role'] != 'user') {
    throw const FormatException('Invalid memory sharing role');
  }
  return (
    id: json['id'] as String,
    source: BotMemoryShareSource.values.byName(json['source'] as String),
    projectId: json['project'] as String?,
    sourceId: json['sourceId'] as int,
    sourceRevision: json['sourceRevision'] as int,
    sourceGeneration: json['sourceGeneration'] as int,
    groupId: json['group'] as String,
  );
}

Map<String, Object?> encodeBotMemoryShare(BotMemoryShare share) => {
  'id': share.id,
  'source': share.source.name,
  'project': ?share.projectId,
  'sourceId': share.sourceId,
  'sourceRevision': share.sourceRevision,
  'sourceGeneration': share.sourceGeneration,
  'group': share.groupId,
  'role': 'user',
};

class BotMemoryEntry {
  const BotMemoryEntry({
    required this.id,
    required this.revision,
    required this.markdown,
    this.content,
    this.key,
    this.session,
    this.sourceMessage,
    this.updatedAt,
    this.pinned = false,
    this.share,
  });

  factory BotMemoryEntry.fromJson(Map<String, Object?> json) => BotMemoryEntry(
    id: json['id'] as int,
    revision: json['revision'] as int,
    markdown: json['markdown'] as String,
    content: json['content'] as String?,
    key: json['key'] as String?,
    session: json['session'] as String?,
    sourceMessage: json['sourceMessage'] as String?,
    updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? ''),
    pinned: json['pinned'] == true,
    share: switch (json['share']) {
      null => null,
      final Map<String, Object?> share => _decodeShare(share),
      _ => throw const FormatException('Invalid memory share'),
    },
  );

  final int id;
  final int revision;
  final String markdown;
  final String? content;
  final String? key;
  final String? session;
  final String? sourceMessage;
  final DateTime? updatedAt;
  final bool pinned;
  final BotMemoryShare? share;

  String get text =>
      content ?? (markdown.startsWith('- ') ? markdown.substring(2) : markdown);

  Map<String, Object?> toJson() => {
    'id': id,
    'revision': revision,
    'markdown': markdown,
    if (content != null) 'content': content,
    if (key != null) 'key': key,
    if (session != null) 'session': session,
    if (sourceMessage != null) 'sourceMessage': sourceMessage,
    if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
    if (pinned) 'pinned': true,
    if (share case final approval?) 'share': encodeBotMemoryShare(approval),
  };
}

enum BotMemoryAction { add, update, remove }

typedef BotMemorySource = ({String sessionId, String messageId});

/// A typed fact supplies its own rendered text and identity partition.
typedef BotMemoryDraft = ({String text, String markdown, String? key});

typedef BotMemoryChange = ({
  BotMemoryAction action,
  int? id,
  int? revision,
  String? text,
});

/// User notes kept by one bot. All changes in a batch are checked before it
/// is written, with ids that survive edits and are never reused.
class BotMemory {
  BotMemory._(
    this._nextId,
    List<BotMemoryEntry> entries, {
    Set<String> operations = const {},
    Set<String> forgotten = const {},
    this.capacity = botUserMemoryLimit,
    this.withdrawalGeneration = 0,
    this.lastWithdrawalAt,
    Set<int> withdrawnEntries = const {},
    Set<String> withdrawnSources = const {},
    this.unavailableEntries = const {},
  }) : entries = List.unmodifiable(entries),
       _operations = Set.unmodifiable(operations),
       _forgotten = Set.unmodifiable(forgotten),
       _withdrawnEntries = Set.unmodifiable(withdrawnEntries),
       _withdrawnSources = Set.unmodifiable(withdrawnSources);

  factory BotMemory.fromMarkdown(
    String markdown, {
    int capacity = botUserMemoryLimit,
  }) => BotMemory._(1, [], capacity: capacity).replaceMarkdown(markdown);

  factory BotMemory.fromJson(
    Map<String, Object?> json, {
    int capacity = botUserMemoryLimit,
  }) => BotMemory._(
    json['nextId'] as int,
    [
      for (final entry in json['entries'] as List)
        BotMemoryEntry.fromJson(entry as Map<String, Object?>),
    ],
    operations: (json['operations'] as List? ?? []).cast<String>().toSet(),
    forgotten: (json['forgotten'] as List? ?? []).cast<String>().toSet(),
    capacity: capacity,
    withdrawalGeneration: json['withdrawalGeneration'] as int? ?? 0,
    lastWithdrawalAt: DateTime.tryParse(
      json['lastWithdrawalAt'] as String? ?? '',
    ),
    withdrawnEntries: (json['withdrawnEntries'] as List? ?? [])
        .cast<int>()
        .toSet(),
    withdrawnSources: (json['withdrawnSources'] as List? ?? [])
        .cast<String>()
        .toSet(),
  );

  final int _nextId;
  final int capacity;
  final List<BotMemoryEntry> entries;
  final Set<String> _operations;
  final Set<String> _forgotten;
  final int withdrawalGeneration;
  final DateTime? lastWithdrawalAt;
  final Set<int> _withdrawnEntries;
  final Set<String> _withdrawnSources;

  // Derived from the host's original-source tombstones on every read.
  final Set<int> unavailableEntries;
  Iterable<BotMemoryEntry> get activeEntries =>
      entries.where((entry) => !unavailableEntries.contains(entry.id));

  BotMemory withUnavailableSources(bool Function(BotMemoryEntry) unavailable) =>
      _withEntries(
        _nextId,
        entries,
        unavailable: Set.unmodifiable({
          for (final entry in entries)
            if (unavailable(entry)) entry.id,
        }),
      );

  BotMemory retainWithoutSource(int id, int revision) {
    if (!unavailableEntries.contains(id) ||
        !entries.any((entry) => entry.id == id && entry.revision == revision)) {
      throw StateError('The source or memory revision changed');
    }
    return _withEntries(
      _nextId,
      [
        for (final entry in entries)
          if (entry.id == id)
            BotMemoryEntry(
              id: entry.id,
              revision: entry.revision + 1,
              markdown: entry.markdown,
              content: entry.content,
              key: entry.key,
              updatedAt: entry.updatedAt,
              pinned: entry.pinned,
            )
          else
            entry,
      ],
      unavailable: Set.unmodifiable(
        unavailableEntries.where((value) => value != id),
      ),
    );
  }

  bool isWithdrawnEntry(int id) => _withdrawnEntries.contains(id);

  bool isWithdrawnSource(String sessionId, String messageId) =>
      _withdrawnSources.contains(_sourceFingerprint(sessionId, messageId));

  static String _sourceFingerprint(String sessionId, String messageId) => sha256
      .convert(utf8.encode(jsonEncode([sessionId, messageId])))
      .toString();

  static String _fingerprint(String text, [String? key]) {
    final normalized = text.trim().toLowerCase().replaceAll(
      RegExp(r'\s+'),
      ' ',
    );
    return sha256
        .convert(
          utf8.encode(key == null ? normalized : jsonEncode([key, normalized])),
        )
        .toString();
  }

  static String _entryFingerprint(BotMemoryEntry entry) =>
      _fingerprint(entry.text, entry.key);

  bool hasOperation(String id) => _operations.contains(id);
  bool isForgotten(String text) => _forgotten.contains(_fingerprint(text));

  String get markdown => entries.map((entry) => entry.markdown).join('\n');

  Map<String, Object?> toJson() => {
    'nextId': _nextId,
    'entries': [for (final entry in entries) entry.toJson()],
    if (_operations.isNotEmpty) 'operations': _operations.toList(),
    if (_forgotten.isNotEmpty) 'forgotten': _forgotten.toList(),
    if (withdrawalGeneration != 0) 'withdrawalGeneration': withdrawalGeneration,
    'lastWithdrawalAt': ?lastWithdrawalAt?.toIso8601String(),
    if (_withdrawnEntries.isNotEmpty)
      'withdrawnEntries': _withdrawnEntries.toList(),
    if (_withdrawnSources.isNotEmpty)
      'withdrawnSources': _withdrawnSources.toList(),
  };

  /// Older notes are retained on disk. They can be inspected and shortened
  /// even when they do not fit in the prompt.
  String get prompt => promptEntries.map((entry) => entry.markdown).join('\n');

  List<BotMemoryEntry> get promptEntries {
    final included = <BotMemoryEntry>[];
    var remaining = capacity;
    for (final entry in [
      ...activeEntries.where((entry) => entry.pinned),
      ...activeEntries.where((entry) => !entry.pinned),
    ]) {
      final size = entry.markdown.runes.length + (included.isEmpty ? 0 : 1);
      if (size > remaining || botMemoryHasCredential(entry.markdown)) continue;
      included.add(entry);
      remaining -= size;
    }
    return included;
  }

  BotMemory _withEntries(
    int nextId,
    List<BotMemoryEntry> entries, {
    Set<String>? operations,
    Set<String>? forgotten,
    List<BotMemoryEntry> withdrawn = const [],
    Set<int>? unavailable,
    DateTime? at,
  }) => BotMemory._(
    nextId,
    entries,
    operations: operations ?? _operations,
    forgotten: forgotten ?? _forgotten,
    capacity: capacity,
    unavailableEntries: unavailable ?? unavailableEntries,
    withdrawalGeneration: withdrawalGeneration + (withdrawn.isEmpty ? 0 : 1),
    lastWithdrawalAt: withdrawn.isEmpty
        ? lastWithdrawalAt
        : at ?? DateTime.now(),
    withdrawnEntries: {
      ..._withdrawnEntries,
      ...withdrawn.map((entry) => entry.id),
    },
    withdrawnSources: {
      ..._withdrawnSources,
      for (final entry in withdrawn)
        if ((entry.session, entry.sourceMessage) case (
          final session?,
          final message?,
        ))
          _sourceFingerprint(session, message),
    },
  );

  BotMemory shareEntry(
    BotMemoryShare approval,
    BotMemoryEntry source, {
    required DateTime at,
  }) {
    if (source.text.trim().isEmpty || botMemoryHasCredential(source.markdown)) {
      throw ArgumentError('This memory cannot be shared.');
    }
    final previous = entries.where((entry) {
      final share = entry.share;
      return share != null &&
          share.source == approval.source &&
          share.projectId == approval.projectId &&
          share.sourceId == approval.sourceId;
    }).firstOrNull;
    if (previous?.share?.sourceRevision == approval.sourceRevision) return this;
    final published = _withEntries(
      _nextId + 1,
      [
        ...entries.where((entry) => entry.id != previous?.id),
        BotMemoryEntry(
          id: _nextId,
          revision: 1,
          markdown: source.markdown,
          content: source.text,
          share: approval,
          updatedAt: at,
        ),
      ],
      withdrawn: [?previous],
      at: at,
    );
    published._checkCapacity();
    return published;
  }

  BotMemory withdrawShares(
    bool Function(BotMemoryEntry) shouldWithdraw, {
    required DateTime at,
  }) {
    final removed = [
      for (final entry in entries)
        if (entry.share != null && shouldWithdraw(entry)) entry,
    ];
    if (removed.isEmpty) return this;
    return _withEntries(
      _nextId,
      entries.where((entry) => !removed.contains(entry)).toList(),
      withdrawn: removed,
      forgotten: {..._forgotten, ...removed.map(_entryFingerprint)},
      at: at,
    );
  }

  BotMemory withPin(int id, int revision, bool pinned) {
    final entry = entries.where((item) => item.id == id).firstOrNull;
    if (entry == null || entry.revision != revision) {
      throw StateError(
        'Memory entry $id changed or is missing. List it again.',
      );
    }
    if (entry.share != null) throw StateError('Shared memory is read-only.');
    if (entry.pinned == pinned) return this;
    return _withEntries(_nextId, [
      for (final item in entries)
        if (item.id != id)
          item
        else
          BotMemoryEntry(
            id: id,
            revision: revision + 1,
            markdown: item.markdown,
            content: item.content,
            key: item.key,
            session: item.session,
            sourceMessage: item.sourceMessage,
            updatedAt: item.updatedAt,
            pinned: pinned,
          ),
    ]);
  }

  BotMemory replaceMarkdown(String updatedMarkdown, {DateTime? at}) {
    final text = updatedMarkdown.trim();
    if (text == markdown) return this;
    final lines = text.split('\n');
    final items = text.isEmpty
        ? const <String>[]
        : lines.every((line) => line.startsWith('- '))
        ? lines
        : [text];
    final left = entries.toList();
    var nextId = _nextId;
    final replacement = [
      for (final item in items)
        switch (left.indexWhere((entry) => entry.markdown == item)) {
          -1 => BotMemoryEntry(id: nextId++, revision: 1, markdown: item),
          final index => left.removeAt(index),
        },
    ];
    return _withEntries(
      nextId,
      replacement,
      forgotten: {
        ..._forgotten,
        for (final entry in left) _fingerprint(entry.text),
      }..removeAll(replacement.map((entry) => _fingerprint(entry.text))),
      withdrawn: left,
      at: at,
    );
  }

  /// Imports legacy fragments with their full rendered content intact. An
  /// unchanged fragment keeps its existing ID, source, and revision.
  BotMemory replaceDrafts(
    List<BotMemoryDraft> drafts, {
    DateTime? at,
    bool verifyImport = false,
  }) {
    final left = entries.toList();
    var nextId = _nextId;
    final replacement = <BotMemoryEntry>[];
    for (final draft in drafts) {
      final index = left.indexWhere(
        (entry) =>
            entry.key == draft.key &&
            entry.markdown == draft.markdown &&
            (verifyImport || entry.text == draft.text),
      );
      if (index >= 0) {
        replacement.add(left.removeAt(index));
        continue;
      }
      if (verifyImport) {
        if (botMemoryHasCredential(draft.markdown)) {
          throw ArgumentError('Credentials cannot be imported as memory.');
        }
        if (_forgotten.contains(_fingerprint(draft.text, draft.key))) {
          throw StateError('This import would bring back a forgotten entry.');
        }
      }
      replacement.add(
        BotMemoryEntry(
          id: nextId++,
          revision: 1,
          markdown: draft.markdown,
          content: draft.text,
          key: draft.key,
          updatedAt: at,
        ),
      );
    }
    if (verifyImport &&
        left.any(
          (entry) =>
              entry.share != null || unavailableEntries.contains(entry.id),
        )) {
      throw StateError('This import would replace a protected entry.');
    }
    if (replacement.length == entries.length &&
        replacement.indexed.every(
          (pair) => identical(pair.$2, entries[pair.$1]),
        )) {
      return this;
    }
    final memory = _withEntries(
      nextId,
      replacement,
      forgotten: {
        ..._forgotten,
        for (final entry in left) _entryFingerprint(entry),
      }..removeAll(replacement.map(_entryFingerprint)),
      withdrawn: left,
      at: at,
    );
    if (verifyImport && nextId != _nextId) memory._checkCapacity();
    return memory;
  }

  BotMemory apply(
    List<BotMemoryChange> changes, {
    String? session,
    String? sourceMessage,
    DateTime? at,
    String? operationId,
    List<BotMemorySource>? changeSources,
    bool allowRememberingWithdrawn = false,
    List<BotMemoryDraft?>? drafts,
  }) {
    if (operationId != null && hasOperation(operationId)) return this;
    assert(changeSources == null || changeSources.length == changes.length);
    assert(drafts == null || drafts.length == changes.length);
    final forgotten = _forgotten.toSet();
    final updated = entries.toList();
    final withdrawn = <BotMemoryEntry>[];
    var nextId = _nextId;
    for (final (changeIndex, change) in changes.indexed) {
      final source = changeSources?[changeIndex];
      final entrySession = source?.sessionId ?? session;
      final entryMessage = source?.messageId ?? sourceMessage;
      final draft = drafts?[changeIndex];
      final text = draft?.text ?? change.text?.trim();
      if (change.action != BotMemoryAction.remove &&
          (text == null || text.isEmpty)) {
        throw ArgumentError('text is empty');
      }
      if (text != null && change.action != BotMemoryAction.remove) {
        if (botMemoryHasCredential(draft?.markdown ?? text)) {
          throw ArgumentError('Credentials cannot be saved as memory.');
        }
        final signature = _fingerprint(text, draft?.key);
        if (!allowRememberingWithdrawn && forgotten.contains(signature)) {
          throw StateError('The user chose to forget this memory.');
        }
        forgotten.remove(signature);
      }
      if (change.action == BotMemoryAction.add) {
        if (!updated.any(
          (entry) => draft == null
              ? entry.text == text
              : _entryFingerprint(entry) == _fingerprint(draft.text, draft.key),
        )) {
          updated.add(
            BotMemoryEntry(
              id: nextId++,
              revision: 1,
              markdown: draft?.markdown ?? '- $text',
              content: draft?.text,
              key: draft?.key,
              session: entrySession,
              sourceMessage: entryMessage,
              updatedAt: at,
            ),
          );
        }
        continue;
      }
      final index = updated.indexWhere((entry) => entry.id == change.id);
      if (index < 0 || updated[index].revision != change.revision) {
        throw StateError(
          'Memory entry ${change.id} changed or is missing. List it again.',
        );
      }
      final entry = updated[index];
      if (entry.share != null) throw StateError('Shared memory is read-only.');
      if (change.action == BotMemoryAction.remove) {
        forgotten.add(_entryFingerprint(entry));
        if (operationId == null) withdrawn.add(entry);
        updated.removeAt(index);
      } else if (entry.text != text ||
          (draft != null && entry.markdown != draft.markdown)) {
        forgotten.add(_entryFingerprint(entry));
        forgotten.remove(_fingerprint(text!, draft?.key));
        updated[index] = BotMemoryEntry(
          id: entry.id,
          revision: entry.revision + 1,
          markdown:
              draft?.markdown ??
              (entry.markdown.startsWith('- ') ? '- $text' : text),
          content: draft?.text,
          key: draft?.key,
          session: draft == null ? entrySession ?? entry.session : entrySession,
          sourceMessage: draft == null
              ? entryMessage ?? entry.sourceMessage
              : entryMessage,
          updatedAt: at ?? entry.updatedAt,
          pinned: entry.pinned,
        );
      }
    }
    final removeOnly = changes.every(
      (change) => change.action == BotMemoryAction.remove,
    );
    if (entries.isNotEmpty && updated.isEmpty && changes.length > 1) {
      throw StateError(
        'This batch would empty user memory. Remove the last entry separately.',
      );
    }
    final identicalEntries =
        updated.length == entries.length &&
        updated.indexed.every((pair) => identical(pair.$2, entries[pair.$1]));
    if (identicalEntries && operationId == null) return this;
    final memory = _withEntries(
      nextId,
      updated,
      operations: {..._operations, ?operationId},
      forgotten: forgotten,
      withdrawn: withdrawn,
      at: at,
    );
    if (!removeOnly && !identicalEntries) memory._checkCapacity();
    return memory;
  }

  void _checkCapacity() {
    final size = markdown.runes.length;
    if (size > capacity) {
      throw StateError(
        'User memory would use $size/$capacity characters. '
        'Free ${size - capacity} characters in the same batch. '
        'List the entries to see what can be shortened.',
      );
    }
  }
}
