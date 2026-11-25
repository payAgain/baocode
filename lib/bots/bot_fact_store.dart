import 'dart:convert';
import 'dart:math';

import 'bot_life.dart';
import 'bot_memory.dart';

const botFactMemoryLimit = 2200;

enum BotFactKind { self, person, project }

enum BotFactSource { migration, user, conversation }

/// A capability issued by the host after resolving the calling context.
/// The owner and current session/project are checked again on every use.
final class BotFactAccess {
  const BotFactAccess(
    this._owner, {
    required this.botId,
    this.projectId,
    this.sessionId,
    this.sourceMessage,
  });

  final Object _owner;
  final String botId;
  final String? projectId;
  final String? sessionId;
  final String? sourceMessage;

  bool belongsTo(Object owner) => identical(_owner, owner);
}

class BotFactChange {
  const BotFactChange({
    required this.action,
    this.id,
    this.revision,
    this.kind,
    this.text,
    this.personKey,
    this.personName,
    this.newPerson = false,
  });

  final BotMemoryAction action;
  final int? id;
  final int? revision;
  final BotFactKind? kind;
  final String? text;
  final String? personKey;
  final String? personName;

  /// A host user's explicit choice to create a distinct person.
  final bool newPerson;
}

class BotFactEntry {
  BotFactEntry._(this.entry) {
    final key = jsonDecode(entry.key!) as List;
    kind = BotFactKind.values.byName(key[0] as String);
    personKey = key[1] as String?;
    personName = key[2] as String?;
  }

  final BotMemoryEntry entry;
  late final BotFactKind kind;
  late final String? personKey;
  late final String? personName;

  int get id => entry.id;
  int get revision => entry.revision;
  String get text => entry.text;
  String get markdown => entry.markdown;
  bool get pinned => entry.pinned;
  DateTime? get updatedAt => entry.updatedAt;
  BotFactSource get source => entry.session != null
      ? BotFactSource.conversation
      : entry.updatedAt != null
      ? BotFactSource.user
      : BotFactSource.migration;

  bool get needsReview =>
      source == BotFactSource.migration &&
      !(personName == null
              ? markdown
              : markdown.substring(markdown.indexOf('\n') + 1))
          .startsWith('- ');
}

/// The self and people categories share a single atomic ledger and budget.
/// A project has its own ledger, addressed by its host identity.
class BotFactStore {
  BotFactStore._(
    this.memory, {
    this.now = '',
    this.isProject = false,
    Map<String, String> people = const {},
  }) : entries = List.unmodifiable(memory.entries.map(BotFactEntry._)) {
    this.people = Map.unmodifiable({
      ...people,
      for (final fact in entries) ?fact.personKey: fact.personName!,
    });
  }

  factory BotFactStore.empty({bool isProject = false}) => BotFactStore._(
    BotMemory.fromMarkdown('', capacity: botFactMemoryLimit),
    isProject: isProject,
  );

  factory BotFactStore.fromJson(
    Map<String, Object?> json, {
    bool isProject = false,
  }) {
    if (json['version'] != 1 || (json['project'] == true) != isProject) {
      throw const FormatException('Unknown fact store format');
    }
    return BotFactStore._(
      BotMemory.fromJson(
        json['memory'] as Map<String, Object?>,
        capacity: botFactMemoryLimit,
      ),
      isProject: isProject,
      now: json['now'] as String? ?? '',
      people: (json['people'] as Map? ?? const {}).cast<String, String>(),
    );
  }

  factory BotFactStore.fromLegacy({
    required String self,
    required String people,
    Set<String> ownerNames = const {},
  }) {
    final sections = BotLife.peopleFacts(people);
    final owners = sections.where(
      (section) => ownerNames.contains(section.person),
    );
    return BotFactStore._(
      BotFactStore.empty().memory.replaceDrafts([
        for (final fragment in BotLife.selfFacts(self))
          _legacy(BotFactKind.self, fragment),
        for (final (index, section) in sections.indexed)
          for (final fragment
              in section.fragments.isEmpty ? const [''] : section.fragments)
            _legacy(
              BotFactKind.person,
              fragment,
              personName: section.person,
              personKey: section.person == null
                  ? null
                  : owners.length == 1 && ownerNames.contains(section.person)
                  ? ownerKey
                  : 'legacy-${index + 1}',
            ),
      ]),
      now: BotLife.nowOf(self),
    );
  }

  static const ownerKey = 'owner';
  final BotMemory memory;
  final bool isProject;
  final String now;
  final List<BotFactEntry> entries;

  /// Keys survive the removal of a person's last note so a stale note cannot
  /// be re-added through a fresh identity inferred from the same name.
  late final Map<String, String> people;

  Map<String, Object?> toJson() => {
    'version': 1,
    if (isProject) 'project': true,
    if (now.isNotEmpty) 'now': now,
    if (people.isNotEmpty) 'people': people,
    'memory': memory.toJson(),
  };

  BotFactStore withUnavailableSources(
    bool Function(BotMemoryEntry entry) unavailable,
  ) => _with(memory.withUnavailableSources(unavailable));

  BotFactStore retainWithoutSource(int id, int revision) =>
      _with(memory.retainWithoutSource(id, revision));

  Iterable<BotFactEntry> get activeEntries =>
      entries.where((fact) => !memory.unavailableEntries.contains(fact.id));

  String get selfMarkdown => [
    if (now.isNotEmpty) now,
    for (final fact in activeEntries)
      if (fact.kind == BotFactKind.self) fact.markdown,
  ].join('\n');

  String get peopleMarkdown {
    final lines = <String>[];
    String? lastKey;
    for (final fact in activeEntries.where(
      (fact) => fact.kind == BotFactKind.person,
    )) {
      if (fact.personName == null) {
        lines.add(fact.markdown);
        lastKey = null;
        continue;
      }
      if (fact.personKey != lastKey) {
        if (lines.isNotEmpty) lines.add('');
        lines.add('## ${fact.personName}');
      }
      final newline = fact.markdown.indexOf('\n');
      if (newline >= 0) lines.add(fact.markdown.substring(newline + 1));
      lastKey = fact.personKey;
    }
    return lines.join('\n');
  }

  BotFactStore replaceSelf(String markdown, {required DateTime at}) {
    final facts = BotLife.selfFacts(markdown);
    return _with(
      memory.replaceDrafts([
        for (final fragment in facts) _legacy(BotFactKind.self, fragment),
        for (final fact in entries)
          if (fact.kind != BotFactKind.self) _existing(fact),
      ], at: at),
      now: BotLife.nowOf(markdown),
    );
  }

  /// Owner-confirmed Markdown edits use the same ledger as structured facts.
  /// An archive restore only adds notes and never changes the bot's current state.
  BotFactStore importLegacyMarkdown(
    String markdown, {
    required bool peopleMirror,
    required bool appendOnly,
    required Set<String> ownerNames,
    required DateTime at,
  }) {
    assert(!isProject);
    final kind = peopleMirror ? BotFactKind.person : BotFactKind.self;
    final currentMarkdown = peopleMirror ? peopleMarkdown : selfMarkdown;
    if (!appendOnly && markdown.trimRight() == currentMarkdown.trimRight()) {
      return this;
    }
    final selected = <BotMemoryDraft>[];
    if (peopleMirror) {
      final newNames = <String>{};
      for (final section in BotLife.peopleFacts(markdown)) {
        final name = section.person;
        String? key;
        if (name != null) {
          final matches = {
            for (final entry in people.entries)
              if (entry.value == name ||
                  entry.key == ownerKey && ownerNames.contains(name))
                entry.key,
          };
          if (matches.length > 1 || matches.isEmpty && !newNames.add(name)) {
            throw StateError(
              'Several people have that name. Edit their facts individually.',
            );
          }
          key =
              matches.singleOrNull ??
              (ownerNames.contains(name) ? ownerKey : _newPersonKey());
        }
        for (final fragment
            in section.fragments.isEmpty ? const [''] : section.fragments) {
          selected.add(
            _legacy(
              kind,
              fragment,
              personKey: key,
              personName: people[key] ?? name,
            ),
          );
        }
      }
    } else {
      for (final fragment in BotLife.selfFacts(markdown)) {
        selected.add(_legacy(kind, fragment));
      }
    }
    final currentState = peopleMirror || appendOnly
        ? now
        : BotLife.nowOf(markdown);
    if (currentState != now &&
        (botMemoryHasCredential(currentState) ||
            currentState.runes.length > botFactMemoryLimit)) {
      throw ArgumentError(
        'The current state exceeds its budget or contains credentials.',
      );
    }
    final imported = [
      for (final draft in selected)
        (
          text: draft.text.replaceAll('\n  ', '\n'),
          markdown: draft.markdown,
          key: draft.key,
        ),
    ];
    final drafts = <BotMemoryDraft>[];
    if (appendOnly) {
      drafts.addAll(entries.map(_existing));
      for (final draft in imported) {
        if (drafts.any(
          (existing) =>
              existing.key == draft.key &&
              (existing.text == draft.text ||
                  existing.markdown == draft.markdown),
        )) {
          continue;
        }
        drafts.add(draft);
      }
    } else {
      var next = 0;
      for (final fact in entries) {
        if (fact.kind != kind) {
          drafts.add(_existing(fact));
        } else if (next < imported.length) {
          drafts.add(imported[next++]);
        }
      }
      drafts.addAll(imported.skip(next));
    }
    return _with(
      memory.replaceDrafts(drafts, at: at, verifyImport: true),
      now: currentState,
    );
  }

  BotFactStore withoutOwner({required DateTime at}) => _with(
    memory.replaceDrafts([
      for (final fact in entries)
        if (fact.personKey != ownerKey) _existing(fact),
    ], at: at),
  );

  BotFactStore withNow(String now) => _with(memory, now: now);

  BotFactStore apply(
    List<BotFactChange> changes, {
    required DateTime at,
    String? session,
    String? sourceMessage,
    Set<String> ownerNames = const {},
    bool allowRememberingWithdrawn = false,
    String? operationId,
    List<BotMemorySource>? changeSources,
  }) {
    // Replays must also succeed after a committed update or removal makes the
    // original expected revisions stale.
    if (operationId != null && memory.hasOperation(operationId)) return this;
    if (changeSources != null &&
        (changeSources.length != changes.length ||
            changeSources.any(
              (source) => source.sessionId.isEmpty || source.messageId.isEmpty,
            ))) {
      throw ArgumentError('Each reviewed change requires a source.');
    }
    if (changeSources?.any(
          (source) =>
              memory.isWithdrawnSource(source.sessionId, source.messageId),
        ) ==
        true) {
      throw StateError('A reviewed fact source was withdrawn.');
    }
    final prev = {for (final fact in entries) fact.id: fact};
    final people = {...this.people};
    if (ownerNames.isNotEmpty) {
      people.putIfAbsent(ownerKey, () => ownerNames.first);
    }
    final drafts = <BotMemoryDraft?>[];
    final edits = <BotMemoryChange>[];
    for (final change in changes) {
      final text = change.text?.trim();
      final existing = prev[change.id];
      if (change.action != BotMemoryAction.add &&
          (existing == null || existing.revision != change.revision)) {
        throw StateError(
          'Fact ${change.id} changed or is missing. List it again.',
        );
      }
      if (change.action == BotMemoryAction.add &&
          (change.id != null || change.revision != null)) {
        throw ArgumentError('A new fact has no entry ID or revision.');
      }
      final kind =
          change.kind ??
          existing?.kind ??
          (isProject ? BotFactKind.project : null);
      if (kind == null ||
          (kind == BotFactKind.project) != isProject ||
          existing != null && kind != existing.kind) {
        throw ArgumentError(
          'The fact kind does not match this store or entry.',
        );
      }
      if (change.action == BotMemoryAction.remove) {
        if (text != null ||
            change.personKey != null ||
            change.personName != null ||
            change.newPerson) {
          throw ArgumentError('A removal only takes an entry ID and revision.');
        }
        drafts.add(null);
      } else {
        if (text == null || text.isEmpty) {
          throw ArgumentError('Fact text is empty.');
        }
        String? personKey = existing?.personKey;
        String? personName = existing?.personName;
        if (kind != BotFactKind.person || existing != null) {
          if (change.personKey != null ||
              change.personName != null ||
              change.newPerson) {
            throw ArgumentError(
              'A person is selected when a person fact is added.',
            );
          }
        } else {
          final name = change.personName?.trim();
          if (name != null &&
              (name.isEmpty ||
                  name.runes.length > 128 ||
                  name.contains(RegExp(r'[\r\n]')))) {
            throw ArgumentError('Invalid person name.');
          }
          if (change.newPerson) {
            if (session != null || change.personKey != null || name == null) {
              throw ArgumentError('A host user must choose the new person.');
            }
            personKey = _newPersonKey();
            personName = name;
          } else if (change.personKey case final requested?) {
            personKey = requested;
            personName = people[requested];
            if (personName == null || name != null && name != personName) {
              throw ArgumentError('Choose a known person key.');
            }
          } else if (name != null) {
            final selected = {
              for (final person in people.entries)
                if (person.value == name ||
                    person.key == ownerKey && ownerNames.contains(name))
                  person.key,
            };
            if (selected.length > 1) {
              throw StateError(
                'Several people have that name. Choose a person key.',
              );
            }
            personKey = selected.singleOrNull ?? _newPersonKey();
            personName = people[personKey] ?? name;
          } else {
            throw ArgumentError('Choose a person by key or name.');
          }
          people[personKey] = personName;
        }
        final bullet = '- ${text.replaceAll('\n', '\n  ')}';
        drafts.add((
          text: text,
          markdown: personName == null ? bullet : '## $personName\n$bullet',
          key: _key(kind, personKey, personName),
        ));
      }
      edits.add((
        action: change.action,
        id: change.id,
        revision: change.revision,
        text: text,
      ));
    }
    return _with(
      memory.apply(
        edits,
        at: at,
        session: session,
        sourceMessage: sourceMessage,
        operationId: operationId,
        changeSources: changeSources,
        drafts: drafts,
        allowRememberingWithdrawn: allowRememberingWithdrawn,
      ),
    );
  }

  BotFactStore withPin(int id, int revision, bool pinned) =>
      _with(memory.withPin(id, revision, pinned));

  BotFactStore _with(BotMemory memory, {String? now}) {
    if (identical(memory, this.memory) && (now == null || now == this.now)) {
      return this;
    }
    return BotFactStore._(
      memory,
      now: now ?? this.now,
      isProject: isProject,
      people: people,
    );
  }

  static String _key(BotFactKind kind, String? key, String? name) =>
      jsonEncode([kind.name, key, name]);

  static String _newPersonKey() {
    final random = Random.secure();
    return base64Url.encode(List.generate(12, (_) => random.nextInt(256)));
  }

  static BotMemoryDraft _existing(BotFactEntry fact) =>
      (text: fact.text, markdown: fact.markdown, key: fact.entry.key!);

  static BotMemoryDraft _legacy(
    BotFactKind kind,
    String fragment, {
    String? personKey,
    String? personName,
  }) => (
    text: fragment.startsWith('- ') ? fragment.substring(2) : fragment,
    markdown: [
      if (personName != null) '## $personName',
      if (fragment.isNotEmpty) fragment,
    ].join('\n'),
    key: _key(kind, personKey, personName),
  );
}
