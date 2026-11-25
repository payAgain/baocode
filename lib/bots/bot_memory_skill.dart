import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../workspace/preference_store.dart';
import 'bot_folders.dart';
import 'bot_memory.dart' show botMemoryHasCredential;

String botMemoryDigest(String value) =>
    sha256.convert(utf8.encode(value)).toString();

class BotMemorySkillDraft {
  BotMemorySkillDraft({
    required this.name,
    required this.trigger,
    required List<String> steps,
    required this.verification,
    List<String> dependencies = const [],
    this.expectedRevision,
  }) : steps = List.unmodifiable(steps),
       dependencies = List.unmodifiable(dependencies) {
    if (!_name.hasMatch(name) ||
        name.length > 64 ||
        expectedRevision != null && expectedRevision! <= 0 ||
        !_plain(trigger, 240) ||
        !_plain(verification, 600) ||
        steps.length < 2 ||
        steps.length > 12 ||
        steps.any((text) => !_plain(text, 450)) ||
        dependencies.length > 8 ||
        dependencies.any((text) => !_plain(text, 120))) {
      throw const FormatException('Invalid project skill draft');
    }
  }

  factory BotMemorySkillDraft.fromJson(Map<String, Object?> json) =>
      BotMemorySkillDraft(
        name: json['name'] as String,
        trigger: json['trigger'] as String,
        steps: (json['steps'] as List).cast<String>(),
        verification: json['verification'] as String,
        dependencies: (json['dependencies'] as List? ?? []).cast<String>(),
        expectedRevision: json['expectedRevision'] as int?,
      );

  final String name;
  final String trigger;
  final List<String> steps;
  final String verification;
  final List<String> dependencies;
  final int? expectedRevision;

  Map<String, Object?> toJson() => {
    'name': name,
    'trigger': trigger,
    'steps': steps,
    'verification': verification,
    'dependencies': dependencies,
    if (expectedRevision != null) 'expectedRevision': expectedRevision,
  };

  /// Only host-generated, single-line front matter. The model has no
  /// field for allowed-tools, hooks, a model, linked files or a base path.
  String get markdown => [
    '---',
    'name: $name',
    'description: ${jsonEncode(trigger)}',
    '---',
    '',
    '## When to use',
    trigger,
    '',
    '## Steps',
    for (final (index, step) in steps.indexed) '${index + 1}. $step',
    '',
    '## Verification',
    verification,
    if (dependencies.isNotEmpty) ...[
      '',
      '## Dependencies',
      for (final dependency in dependencies) '- $dependency',
    ],
    '',
  ].join('\n');

  static final _name = RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$');
  static final _externalContent = RegExp(
    r'''[\x00-\x1f\x7f\u0085\u2028\u2029]|!\s*`|\]\s*[\(\[]|(?:^|\s)@\S|\bfile:|<[^>]*>|(?:^|[\s"'`])(?:[.~]{1,2}[/\\]|[/\\]|[A-Za-z]:[/\\])''',
    caseSensitive: false,
  );

  static bool _plain(String text, int maximum) =>
      text.trim().isNotEmpty &&
      text.runes.length <= maximum &&
      !_externalContent.hasMatch(text) &&
      !botMemoryHasCredential(text);
}

class BotMemorySkill {
  const BotMemorySkill._({
    required this.botId,
    required this.project,
    required this.revision,
    required this.draft,
    required this.proposalId,
    required this.createdAt,
    required this.updatedAt,
    required this.evidence,
    this.lastUsedAt,
    this.pinned = false,
    this.locked = false,
    this.archived = false,
  });

  factory BotMemorySkill._fromJson(Map<String, Object?> json) =>
      BotMemorySkill._(
        botId: json['botId'] as String,
        project: json['project'] as String,
        revision: json['revision'] as int,
        draft: BotMemorySkillDraft.fromJson(
          json['draft'] as Map<String, Object?>,
        ),
        proposalId: json['proposalId'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
        updatedAt: DateTime.parse(json['updatedAt'] as String),
        evidence: (json['evidence'] as List).cast<Map<String, Object?>>(),
        lastUsedAt: DateTime.tryParse('${json['lastUsedAt']}'),
        pinned: json['pinned'] == true,
        locked: json['locked'] == true,
        archived: json['archived'] == true,
      );

  final String botId;
  final String project;
  final int revision;
  final BotMemorySkillDraft draft;
  String get name => draft.name;
  final String proposalId;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<Map<String, Object?>> evidence;
  final DateTime? lastUsedAt;
  final bool pinned;
  final bool locked;
  final bool archived;

  bool isStale(DateTime now) =>
      now.difference(_lastActivity) >= const Duration(days: 14);

  DateTime get _lastActivity =>
      lastUsedAt?.isAfter(updatedAt) == true ? lastUsedAt! : updatedAt;

  Map<String, Object?> toJson() => {
    'botId': botId,
    'project': project,
    'revision': revision,
    'draft': draft.toJson(),
    'proposalId': proposalId,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'evidence': evidence,
    if (lastUsedAt != null) 'lastUsedAt': lastUsedAt!.toIso8601String(),
    'pinned': pinned,
    'locked': locked,
    'archived': archived,
  };
}

/// Host-managed skills are discovered only by an authorized Bot for the
/// exact project. No file is installed in `.claude/skills`, where another
/// Bot or the CLI could load it without these scope/revision checks.
typedef BotMemorySkillLoad = ({String name, int revision, String markdown});

String botMemorySkillNote(BotMemorySkillLoad skill) =>
    '<system-reminder>Saved project procedure ${skill.name} '
    '(revision ${skill.revision}). Apply only when it fits the task and use '
    'the normal project permissions.\n${skill.markdown}</system-reminder>';

class BotMemorySkills {
  BotMemorySkills({
    required this.store,
    required this.folders,
    required this.root,
    required bool Function(String botId, String project) canUseProject,
    String? Function(String project)? resolveProject,
    this.evidenceAvailable,
    DateTime Function()? clock,
  }) : _authorized = canUseProject,
       _resolveProject = resolveProject ?? ((project) => project),
       _clock = clock ?? DateTime.now;

  final PreferenceStore store;
  final BotFolders folders;
  final String root;
  final bool Function(String botId, String project) _authorized;
  final String? Function(String project) _resolveProject;
  final Future<bool> Function(BotMemorySkill skill)? evidenceAvailable;

  bool canUseProject(String botId, String project) =>
      _project(botId, project) != null;

  String? _project(String botId, String? project) {
    final id = project == null ? null : _resolveProject(project);
    return id != null && _authorized(botId, id) ? id : null;
  }

  final DateTime Function() _clock;
  Future<void> _tail = Future.value();

  Future<T> _serialized<T>(Future<T> Function() work) {
    final future = _tail.then((_) => work());
    _tail = future.then((_) {}, onError: (Object _, StackTrace _) {});
    return future;
  }

  Future<Map<String, List<BotMemorySkill>>> _read() async {
    final data = await store.read();
    return {
      for (final entry in data.entries)
        entry.key: [
          for (final value in entry.value as List)
            BotMemorySkill._fromJson(value as Map<String, Object?>),
        ],
    };
  }

  Future<void> _write(Map<String, List<BotMemorySkill>> skills) => store.write({
    for (final entry in skills.entries)
      entry.key: [for (final skill in entry.value) skill.toJson()],
  });

  static String _key(String bot, String project, String name) =>
      botMemoryDigest(jsonEncode([bot, project, name]));

  String _path(BotMemorySkill skill) => p.join(
    root,
    _key(skill.botId, skill.project, skill.name),
    '${skill.revision}',
    'SKILL.md',
  );

  String? _readSkill(BotMemorySkill skill) {
    final bytes = folders.readFile(_path(skill), strict: true);
    if (bytes == null || bytes.length > 24000) return null;
    final text = utf8.decode(bytes, allowMalformed: true);
    return text == skill.draft.markdown ? text : null;
  }

  Future<List<BotMemorySkill>> list({
    required String botId,
    String? project,
    bool includeArchived = false,
  }) => _serialized(
    () async => [
      for (final history in (await _read()).values)
        if (history.last case final skill
            when skill.botId == botId &&
                (project == null ||
                    skill.project == _project(botId, project)) &&
                canUseProject(botId, skill.project) &&
                (includeArchived || !skill.archived))
          skill,
    ]..sort((a, b) => a.name.compareTo(b.name)),
  );

  Future<List<BotMemorySkill>> revisions({
    required String botId,
    required String project,
    required String name,
  }) => _serialized(() async {
    final data = await _read();
    final id = _project(botId, project);
    return id == null ? [] : data[_key(botId, id, name)] ?? [];
  });

  /// Used by the review service after validating its evidence. An intent
  /// replay has the same proposal ID and can only reuse its own revision.
  Future<BotMemorySkill> apply({
    required String botId,
    required String project,
    required BotMemorySkillDraft draft,
    required String proposalId,
    required List<Map<String, Object?>> evidence,
  }) => _serialized(() async {
    final data = await _read();
    final id = _project(botId, project);
    if (id == null) throw StateError('Project is unavailable');
    final history = data.putIfAbsent(_key(botId, id, draft.name), () => []);
    final prior = history
        .where((skill) => skill.proposalId == proposalId)
        .firstOrNull;
    if (prior != null) return prior;
    final current = history.lastOrNull;
    if (current?.revision != draft.expectedRevision ||
        (current != null &&
            (current.locked ||
                current.archived ||
                _readSkill(current) == null))) {
      throw StateError('Skill changed, is locked, or is archived');
    }
    final now = _clock();
    final skill = BotMemorySkill._(
      botId: botId,
      project: id,
      revision: (current?.revision ?? 0) + 1,
      draft: draft,
      proposalId: proposalId,
      evidence: evidence,
      createdAt: current?.createdAt ?? now,
      updatedAt: now,
      pinned: current?.pinned ?? false,
      lastUsedAt: current?.lastUsedAt,
    );
    if (!await _hasEvidence(skill)) {
      throw StateError('Skill does not have current verification evidence');
    }
    if (_project(botId, project) != id) {
      throw StateError('Project is unavailable');
    }
    _saveRevision(history, skill);
    await _write(data);
    return skill;
  });

  void _saveRevision(List<BotMemorySkill> history, BotMemorySkill skill) {
    final path = _path(skill);
    final markdown = skill.draft.markdown;
    final found = folders.readFile(path, strict: true);
    // A crash can leave a file ahead of the registry. Reuse only exact bytes.
    if (found != null && utf8.decode(found, allowMalformed: true) != markdown) {
      throw StateError('Skill revision file already exists');
    }
    if (found == null) {
      folders.writeFileAtomically(
        path,
        Uint8List.fromList(utf8.encode(markdown)),
      );
    }
    history.add(skill);
  }

  Future<BotMemorySkill> maintain({
    required String botId,
    required String project,
    required String name,
    required int revision,
    bool? pinned,
    bool? locked,
    bool? archived,
  }) => _serialized(() async {
    final data = await _read();
    final id = _project(botId, project);
    if (id == null) throw StateError('Project is unavailable');
    final history = data[_key(botId, id, name)];
    final skill = history?.lastOrNull;
    if (skill == null || skill.revision != revision) {
      throw StateError('Skill changed or is missing');
    }
    final changingArchive = archived != null && archived != skill.archived;
    if (changingArchive && skill.locked) {
      throw StateError('Unlock the skill before changing its archive state');
    }
    if ((pinned ?? skill.pinned) == skill.pinned &&
        (locked ?? skill.locked) == skill.locked &&
        !changingArchive) {
      return skill;
    }
    if (_readSkill(skill) == null) {
      throw StateError('Skill file changed or is missing');
    }
    if (changingArchive &&
        archived == false &&
        evidenceAvailable != null &&
        !await evidenceAvailable!(skill)) {
      throw StateError('Skill evidence is unavailable');
    }
    if (_project(botId, project) != id) {
      throw StateError('Project is unavailable');
    }
    final adjusted = BotMemorySkill._fromJson({
      ...skill.toJson(),
      'revision': skill.revision + 1,
      'pinned': ?pinned,
      'locked': ?locked,
      'archived': ?archived,
      if (changingArchive && archived == false)
        'updatedAt': _clock().toIso8601String(),
    });
    _saveRevision(history!, adjusted);
    await _write(data);
    return adjusted;
  });

  Future<void> archiveStale() => _serialized(() async {
    final data = await _read();
    final now = _clock();
    var changed = false;
    for (final history in data.values) {
      final skill = history.last;
      if (skill.archived ||
          skill.pinned ||
          skill.locked ||
          now.difference(skill._lastActivity) < const Duration(days: 30) ||
          !canUseProject(skill.botId, skill.project) ||
          _readSkill(skill) == null) {
        continue;
      }
      _saveRevision(
        history,
        BotMemorySkill._fromJson({
          ...skill.toJson(),
          'revision': skill.revision + 1,
          'archived': true,
        }),
      );
      changed = true;
    }
    if (changed) await _write(data);
  });

  /// Matches trigger words to the project's task, then verifies the exact
  /// approved file. The returned text is plain task context that confers
  /// no tools, hooks, model, or executable capability.
  Future<List<BotMemorySkillLoad>> loadForTask({
    required String botId,
    required String project,
    required String task,
  }) => _serialized(() async {
    final data = await _read();
    final id = _project(botId, project);
    if (id == null) return [];
    final terms = _terms(task);
    final matches = <({BotMemorySkill skill, int score})>[];
    for (final history in data.values) {
      final skill = history.last;
      if (skill.botId != botId || skill.project != id || !_active(skill)) {
        continue;
      }
      final score = terms
          .intersection(_terms('${skill.name} ${skill.draft.trigger}'))
          .length;
      if (score >= 2 || score == 1 && task.toLowerCase().contains(skill.name)) {
        matches.add((skill: skill, score: score));
      }
    }
    matches.sort((a, b) {
      final relevance = b.score.compareTo(a.score);
      return relevance != 0 ? relevance : a.skill.name.compareTo(b.skill.name);
    });
    final loaded = <BotMemorySkillLoad>[];
    for (final (:skill, score: _) in matches) {
      final markdown = _readSkill(skill);
      if (markdown == null || !await _hasEvidence(skill)) continue;
      loaded.add((
        name: skill.name,
        revision: skill.revision,
        markdown: markdown,
      ));
      if (loaded.length == 2) break;
    }
    return _project(botId, project) == id ? loaded : [];
  });

  bool _active(BotMemorySkill skill) =>
      !skill.archived &&
      (skill.pinned ||
          skill.locked ||
          _clock().difference(skill._lastActivity) < const Duration(days: 30));

  Future<bool> _hasEvidence(BotMemorySkill skill) async =>
      await evidenceAvailable?.call(skill) ?? true;

  Future<List<BotMemorySkillLoad>> confirmForDispatch({
    required String botId,
    required String project,
    required List<BotMemorySkillLoad> candidates,
  }) => _serialized(() async {
    final data = await _read();
    final id = _project(botId, project);
    if (id == null) return [];
    final current = <BotMemorySkillLoad>[];
    for (final load in candidates) {
      final skill = data[_key(botId, id, load.name)]?.lastOrNull;
      if (skill != null &&
          skill.revision == load.revision &&
          _active(skill) &&
          _readSkill(skill) == load.markdown &&
          await _hasEvidence(skill)) {
        current.add(load);
      }
    }
    return _project(botId, project) == id ? current : [];
  });

  /// A matched runtime turn completed with these notes attached. Candidate
  /// lookup and dispatch alone do not refresh the skill's lifetime.
  Future<void> markUsed({
    required String botId,
    required String project,
    required Set<String> noteDigests,
    DateTime? usedAt,
  }) => _serialized(() async {
    if (noteDigests.isEmpty) return;
    final data = await _read();
    final id = _project(botId, project);
    if (id == null) return;
    final now = usedAt ?? _clock();
    var changed = false;
    for (final history in data.values) {
      final skill = history.last;
      if (skill.botId != botId ||
          skill.project != id ||
          skill.archived ||
          (skill.lastUsedAt?.compareTo(now) ?? -1) >= 0) {
        continue;
      }
      final markdown = _readSkill(skill);
      if (markdown == null) continue;
      final note = botMemorySkillNote((
        name: skill.name,
        revision: skill.revision,
        markdown: markdown,
      ));
      if (!noteDigests.contains(botMemoryDigest(note))) continue;
      history[history.length - 1] = BotMemorySkill._fromJson({
        ...skill.toJson(),
        'lastUsedAt': now.toIso8601String(),
      });
      changed = true;
    }
    if (changed) await _write(data);
  });

  static Set<String> _terms(String text) => {
    for (final match in RegExp(
      r'[a-z0-9]{3,}|[\u3400-\u9fff]{2,}',
    ).allMatches(text.toLowerCase()))
      if (match[0] case final String term when !_stopWords.contains(term))
        ..._termParts(term),
  };

  static Iterable<String> _termParts(String term) sync* {
    if (RegExp(r'^[a-z0-9]').hasMatch(term)) {
      yield term;
    } else {
      for (var i = 0; i < term.length - 1; i++) {
        yield term.substring(i, i + 2);
      }
    }
  }

  static const _stopWords = {
    'the',
    'and',
    'for',
    'use',
    'using',
    'when',
    'with',
    'run',
    'this',
    'from',
    'that',
  };
}
