import 'package:bao_link/bao_link.dart';

import '../bots/bot.dart';
import '../bots/bot_fact_store.dart';
import '../bots/bot_groups.dart';
import '../bots/bot_history.dart';
import '../bots/bot_memory.dart';
import '../bots/bot_memory_review.dart';
import '../bots/bot_memory_skill.dart';
import '../bots/bots.dart';
import '../kernel/claude_code/managed_transcripts_io.dart';
import '../search/memory_history.dart';

/// The host-side management surface shared by the local and paired desktops.
/// Memory scope and reviewer identity are established here on the host.
class BotMemoryManagement {
  BotMemoryManagement(
    this.bots, {
    required this.reviewer,
    this.isActive,
    this.localOwner = false,
  });

  final Bots bots;
  final String reviewer;
  final bool Function()? isActive;

  /// Set only when invoked directly from the managing desktop.
  final bool localOwner;
  final _sources = <String, (MemoryHistoryReference, String?)>{};
  final _cursors = <String, (MemoryHistoryScope, String)>{};

  List<String> get methods => [
    LinkMethods.botMemoryEntries,
    LinkMethods.botMemoryFactScopes,
    LinkMethods.changeBotMemory,
    LinkMethods.botMemorySearch,
    LinkMethods.botMemorySource,
    if (localOwner) ...[
      LinkMethods.deleteBotMemorySource,
      LinkMethods.shareBotMemoryEntry,
      LinkMethods.revokeBotMemoryShare,
    ],
    LinkMethods.newBotConversation,
    LinkMethods.refreshBotMemory,
    if (bots.memoryReview != null) ...[
      LinkMethods.botMemoryReview,
      LinkMethods.configureBotMemoryReview,
      LinkMethods.refineBotMemory,
      LinkMethods.decideBotMemory,
    ],
    if (bots.memoryReview?.skills != null) ...[
      LinkMethods.botMemorySkills,
      LinkMethods.botMemorySkillRevisions,
      LinkMethods.maintainBotMemorySkill,
    ],
  ];

  BotMemoryReview get _review =>
      bots.memoryReview ??
      (throw const LinkRemoteException(
        LinkErrors.unsupported,
        'Memory review is unavailable',
      ));

  static const _bad = LinkRemoteException('bad', 'Invalid memory request');
  static const _missing = LinkRemoteException(
    LinkErrors.notFound,
    'Memory scope is unavailable',
  );

  bool _authorized(MemoryHistoryScope scope) {
    if (isActive?.call() == false || bots.byId(scope.botId) == null) {
      return false;
    }
    return switch (scope.kind) {
      MemoryHistoryScopeKind.dm => true,
      MemoryHistoryScopeKind.group =>
        bots.groups.byId(scope.groupId!)?.members.contains(scope.botId) == true,
      MemoryHistoryScopeKind.bot => localOwner,
      MemoryHistoryScopeKind.project => false,
    };
  }

  bool _canViewProjectHistory(MemoryHistoryScope scope, String projectId) =>
      localOwner &&
      isActive?.call() != false &&
      scope.kind == MemoryHistoryScopeKind.project &&
      bots.workspace.localProjectById(projectId)?.path == scope.projectId &&
      bots.projectFactAccess(scope.botId, projectId) != null;

  Future<Map<String, Object?>> call(
    String method,
    Map<String, Object?> args,
  ) async {
    final botId = args['bot'];
    final group = args['group'];
    if (botId is! String || group != null && group is! String) throw _bad;
    final legacyDiary = _field<bool>(args, 'legacyDiary') == true;
    if (legacyDiary &&
        (group != null ||
            (method != LinkMethods.botMemorySearch &&
                method != LinkMethods.botMemorySource))) {
      throw _bad;
    }
    final bot = bots.byId(botId);
    final historyProject = _field<String>(args, 'historyProject');
    if (historyProject != null &&
        (group != null ||
            legacyDiary ||
            method != LinkMethods.botMemorySearch &&
                method != LinkMethods.botMemorySource &&
                method != LinkMethods.deleteBotMemorySource)) {
      throw _bad;
    }
    final project = historyProject == null
        ? null
        : bots.workspace.localProjectById(historyProject);
    if (historyProject != null && project == null) throw _missing;
    final target = project != null
        ? MemoryHistoryScope.project(botId, project.path)
        : legacyDiary
        ? MemoryHistoryScope.bot(botId)
        : group is String
        ? MemoryHistoryScope.group(botId, group)
        : MemoryHistoryScope.dm(botId);
    bool authorized(MemoryHistoryScope scope) => historyProject == null
        ? _authorized(scope)
        : scope == target && _canViewProjectHistory(scope, historyProject);
    if (bot == null || !authorized(target)) throw _missing;
    final scope = BotMemoryScope(botId: botId, groupId: target.groupId);
    final access = MemoryHistoryAccess(
      current: target,
      isAuthorized: authorized,
    );
    final Map<String, Object?> result;
    try {
      final factScope = _field<String>(args, 'factScope');
      if (method == LinkMethods.shareBotMemoryEntry ||
          method == LinkMethods.revokeBotMemoryShare) {
        if (!localOwner) {
          throw const LinkRemoteException(
            LinkErrors.unsupported,
            'Memory sharing is managed on the host desktop',
          );
        }
        final groupId = target.groupId ?? (throw _bad);
        final id = _field<int>(args, 'id') ?? (throw _bad);
        final revision = _field<int>(args, 'revision') ?? (throw _bad);
        final projectId = _field<String>(args, 'project');
        if (method == LinkMethods.shareBotMemoryEntry) {
          final source = switch ((factScope, projectId)) {
            (null, null) => BotMemoryShareSource.preference,
            ('private', null) => BotMemoryShareSource.privateFact,
            ('project', String()) => BotMemoryShareSource.projectFact,
            _ => throw _bad,
          };
          bots.shareMemoryEntry(
            bot,
            group: groupId,
            source: source,
            projectId: projectId,
            id: id,
            revision: revision,
          );
        } else {
          if (factScope != null || projectId != null) throw _bad;
          bots.revokeMemoryShare(
            bot,
            group: groupId,
            id: id,
            revision: revision,
            shareId: _field<String>(args, 'shareId') ?? (throw _bad),
          );
        }
        return _entries(bot, target);
      }
      if (factScope != null || method == LinkMethods.botMemoryFactScopes) {
        if (group != null) throw _bad;
        return _factRequest(method, bot, args, factScope);
      }
      result = switch (method) {
        LinkMethods.botMemoryEntries => _entries(bot, target),
        LinkMethods.changeBotMemory => _change(bot, target, args),
        LinkMethods.botMemorySearch => await _search(
          access,
          args,
          historyProject,
        ),
        LinkMethods.botMemorySource => await _source(
          access,
          args,
          historyProject,
        ),
        LinkMethods.deleteBotMemorySource when localOwner =>
          await _deleteSource(access, args, historyProject),
        LinkMethods.botMemoryReview => await _reviewState(scope, target, args),
        LinkMethods.configureBotMemoryReview => (await _review.configure(
          scope,
          automatic: _field<bool>(args, 'automatic'),
          memoryApproval: _field<bool>(args, 'memoryApproval'),
          skillApproval: _field<bool>(args, 'skillApproval'),
          model: _field<String>(args, 'model'),
        )).toJson(),
        LinkMethods.refineBotMemory => {
          'job': await _review.refine(
            scope: scope,
            sessionId: scope.groupId == null
                ? bots.threadOf(bot)?.id
                : BotGroups.reviewSessionId(scope.groupId!),
            focus: _field<String>(args, 'focus'),
          ),
        },
        LinkMethods.decideBotMemory => _proposal(
          target,
          await _review.decide(
            scope: scope,
            proposalId: _field<String>(args, 'proposal') ?? (throw _bad),
            approve: _field<bool>(args, 'approve') ?? (throw _bad),
            reviewer: reviewer,
            allowBatch: _field<bool>(args, 'batch') ?? false,
          ),
        ),
        LinkMethods.botMemorySkills ||
        LinkMethods.botMemorySkillRevisions ||
        LinkMethods.maintainBotMemorySkill when target.groupId == null =>
          await _skillRequest(method, bot, args),
        LinkMethods.newBotConversation when target.groupId == null =>
          _newConversation(bot),
        LinkMethods.refreshBotMemory => _refresh(bot, target.groupId),
        _ => throw const LinkRemoteException(
          LinkErrors.unsupported,
          'Memory request is unavailable',
        ),
      };
    } on ArgumentError catch (error) {
      throw LinkRemoteException(
        'bad',
        error.message?.toString() ?? 'Invalid memory request',
      );
    } on StateError catch (error) {
      throw LinkRemoteException('stale', error.message);
    }
    if (!authorized(target)) throw _missing;
    return result;
  }

  static T? _field<T>(Map<String, Object?> args, String name) =>
      switch (args[name]) {
        final T value => value,
        null => null,
        _ => throw _bad,
      };

  Map<String, Object?> _factRequest(
    String method,
    Bot bot,
    Map<String, Object?> args,
    String? factScope,
  ) {
    final projectId = _field<String>(args, 'project');
    if (method == LinkMethods.botMemoryFactScopes) {
      if (factScope != null || projectId != null) throw _bad;
      return {
        'private': true,
        'projects': [
          if (bot.can(BotAbility.agents))
            for (final project in bots.workspace.sidebarProjects)
              if (bots.workspace.localProjectId(project) case final id?)
                if (bots.projectFactAccess(bot.id, id) != null)
                  {'id': id, 'name': project.name},
        ],
      };
    }
    final access = switch ((factScope, projectId)) {
      ('private', null) => bots.privateFactAccess(bot),
      ('project', final id?) =>
        bots.projectFactAccess(bot.id, id) ?? (throw _missing),
      _ => throw _bad,
    };
    final store = switch (method) {
      LinkMethods.botMemoryEntries => bots.factMemory(access),
      LinkMethods.changeBotMemory => _changeFacts(access, args),
      _ => throw _bad,
    };
    final scope = {'bot': bot.id, 'kind': factScope, 'project': ?projectId};
    final next = {for (final entry in store.memory.promptEntries) entry.id};
    final snapshot = projectId == null ? bots.loadedMemorySnapshot(bot) : null;
    final loaded = snapshot?.legacyNotes == null ? snapshot?.facts : null;
    final revisions = {
      for (final entry in loaded ?? <BotMemoryEntry>[])
        entry.id: entry.revision,
    };
    return {
      'scope': scope,
      'entries': [
        for (final fact in store.entries)
          {
            'id': fact.id,
            'revision': fact.revision,
            'text': fact.text,
            'markdown': fact.markdown,
            'kind': fact.kind.name,
            'scope': scope,
            'personKey': ?fact.personKey,
            'personName': ?fact.personName,
            'sourceKind': fact.source.name,
            'needsReview': fact.needsReview,
            'pinned': fact.pinned,
            'injected': next.contains(fact.id),
            'activeRevision': ?revisions[fact.id],
            'updatedAt': ?fact.updatedAt?.toIso8601String(),
            if (store.memory.unavailableEntries.contains(fact.id))
              'sourceUnavailable': true
            else if (projectId == null)
              if (fact.entry.session case final session?)
                if (fact.entry.sourceMessage case final message?)
                  'source': _rememberSource(
                    MemoryHistoryReference(
                      scope: MemoryHistoryScope.dm(bot.id),
                      sessionId: session,
                      messageId: message,
                    ),
                  ),
          },
      ],
      'used': store.memory.markdown.runes.length,
      'budget': store.memory.capacity,
      'injected': store.memory.prompt.runes.length,
      'snapshotStatus': projectId == null
          ? bots.memorySnapshotStatus(bot)
          : 'unknown',
      if (projectId == null)
        'people': [
          for (final person in store.people.entries)
            {'key': person.key, 'name': person.value},
        ],
    };
  }

  BotFactStore _changeFacts(BotFactAccess access, Map<String, Object?> args) {
    final rows = _field<List<Object?>>(args, 'changes');
    if (rows == null || rows.isEmpty || rows.length > 40) throw _bad;
    final changes = <BotFactChange>[];
    for (final row in rows) {
      if (row is! Map<String, Object?>) throw _bad;
      final action = _field<String>(row, 'action');
      final id = _field<int>(row, 'id');
      final revision = _field<int>(row, 'revision');
      final pinned = _field<bool>(row, 'pinned');
      if (action == 'retain') {
        if (!localOwner || rows.length != 1 || id == null || revision == null) {
          throw _bad;
        }
        return bots.retainFact(access, id, revision);
      }
      if (action == 'pin') {
        if (rows.length != 1 ||
            id == null ||
            revision == null ||
            id <= 0 ||
            revision <= 0 ||
            pinned == null) {
          throw _bad;
        }
        return bots.pinFact(access, id, revision, pinned);
      }
      final op = BotMemoryAction.values.asNameMap()[action];
      final kindName = _field<String>(row, 'kind');
      final kind = BotFactKind.values.asNameMap()[kindName];
      if (op == null ||
          pinned != null ||
          kindName != null && kind == null ||
          op != BotMemoryAction.add &&
              (id == null || id <= 0 || revision == null || revision <= 0)) {
        throw _bad;
      }
      changes.add(
        BotFactChange(
          action: op,
          id: id,
          revision: revision,
          kind: kind,
          text: _field<String>(row, 'text'),
          personKey: _field<String>(row, 'personKey'),
          personName: _field<String>(row, 'personName'),
          newPerson: _field<bool>(row, 'newPerson') ?? false,
        ),
      );
    }
    return bots.changeFacts(access, changes);
  }

  Future<Map<String, Object?>> _skillRequest(
    String method,
    Bot bot,
    Map<String, Object?> args,
  ) async {
    final skills =
        _review.skills ??
        (throw const LinkRemoteException(
          LinkErrors.unsupported,
          'Learned skills are unavailable',
        ));
    final projects = {
      for (final project in bots.workspace.sidebarProjects)
        if (project.host == null &&
            !bots.workspace.isAppFolder(project.path) &&
            skills.canUseProject(bot.id, project.path))
          project.path: project.name,
    };
    final requested = _field<String>(args, 'project');
    if (requested != null && !projects.containsKey(requested)) throw _missing;
    if (method == LinkMethods.botMemorySkills) {
      final project = requested ?? projects.keys.firstOrNull;
      final includeArchived = _field<bool>(args, 'includeArchived') ?? false;
      final result = project == null
          ? const <BotMemorySkill>[]
          : await skills.list(
              botId: bot.id,
              project: project,
              includeArchived: includeArchived,
            );
      if (project != null) _checkSkillProject(skills, bot, project);
      return {
        'projects': [
          for (final entry in projects.entries)
            if (_canUseSkillProject(skills, bot, entry.key))
              {'id': entry.key, 'name': entry.value},
        ],
        'project': ?project,
        'skills': [for (final skill in result) _skill(skill)],
      };
    }
    final name = _field<String>(args, 'name');
    if (requested == null || name == null || name.isEmpty || name.length > 64) {
      throw _bad;
    }
    if (method == LinkMethods.botMemorySkillRevisions) {
      final before = _field<int>(args, 'beforeRevision');
      if (before != null && before <= 0) throw _bad;
      final versions = await skills.revisions(
        botId: bot.id,
        project: requested,
        name: name,
      );
      _checkSkillProject(skills, bot, requested);
      if (versions.isEmpty) throw _missing;
      final page = versions.reversed
          .where((skill) => before == null || skill.revision < before)
          .take(51)
          .toList();
      return {
        'revisions': [
          for (final skill in page.take(50)) _skill(skill, content: true),
        ],
        if (page.length > 50) 'beforeRevision': page[49].revision,
      };
    }
    final revision = _field<int>(args, 'revision');
    final pinned = _field<bool>(args, 'pinned');
    final locked = _field<bool>(args, 'locked');
    final archived = _field<bool>(args, 'archived');
    if (revision == null ||
        revision <= 0 ||
        pinned == null && locked == null && archived == null) {
      throw _bad;
    }
    final result = await skills.maintain(
      botId: bot.id,
      project: requested,
      name: name,
      revision: revision,
      pinned: pinned,
      locked: locked,
      archived: archived,
    );
    _checkSkillProject(skills, bot, requested);
    return {'skill': _skill(result)};
  }

  bool _canUseSkillProject(BotMemorySkills skills, Bot bot, String project) =>
      isActive?.call() != false &&
      bots.byId(bot.id) != null &&
      !bots.workspace.isAppFolder(project) &&
      bots.workspace.sidebarProjects.any(
        (p) => p.host == null && p.path == project,
      ) &&
      skills.canUseProject(bot.id, project);

  void _checkSkillProject(BotMemorySkills skills, Bot bot, String project) {
    if (!_canUseSkillProject(skills, bot, project)) throw _missing;
  }

  Map<String, Object?> _skill(BotMemorySkill skill, {bool content = false}) => {
    'name': skill.name,
    'trigger': skill.draft.trigger,
    'revision': skill.revision,
    'pinned': skill.pinned,
    'locked': skill.locked,
    'archived': skill.archived,
    'stale': skill.isStale(bots.now),
    'updatedAt': skill.updatedAt.toIso8601String(),
    'lastUsedAt': ?skill.lastUsedAt?.toIso8601String(),
    if (content) 'markdown': skill.draft.markdown,
  };

  Map<String, Object?> _newConversation(Bot bot) {
    bots.newConversation(bot);
    return {'session': bots.privateSessionId(bot)};
  }

  Map<String, Object?> _refresh(Bot bot, String? group) {
    final status = bots.refreshMemory(bot, group: group);
    return {
      'refreshed': status == BotMemoryRefresh.restarting,
      'status': status.name,
    };
  }

  Map<String, Object?> _entries(Bot bot, MemoryHistoryScope scope) {
    final memory = bots.userMemory(
      bot,
      keepLegacyIds: true,
      group: scope.groupId,
    );
    final injected = {for (final entry in memory.promptEntries) entry.id};
    final snapshot = bots.loadedMemorySnapshot(bot, group: scope.groupId);
    final active = {
      for (final entry in snapshot?.user ?? const <BotMemoryEntry>[])
        entry.id: entry.revision,
    };
    return {
      'snapshotStatus': bots.memorySnapshotStatus(bot, group: scope.groupId),
      'entries': [
        for (final entry in memory.entries)
          {
            'id': entry.id,
            'revision': entry.revision,
            'text': entry.text,
            'markdown': entry.markdown,
            'kind': entry.share != null
                ? 'sharedFact'
                : scope.groupId == null
                ? 'preference'
                : 'groupFact',
            if (localOwner && entry.share != null)
              'share': encodeBotMemoryShare(entry.share!),
            'scope': scope.toJson(),
            'pinned': entry.pinned,
            'injected': injected.contains(entry.id),
            'activeRevision': ?active[entry.id],
            'updatedAt': ?entry.updatedAt?.toIso8601String(),
            if (memory.unavailableEntries.contains(entry.id))
              'sourceUnavailable': true
            else if (entry.session case final session?)
              if (entry.sourceMessage case final message?)
                'source': _rememberSource(
                  MemoryHistoryReference(
                    scope: scope,
                    sessionId: scope.groupId ?? session,
                    messageId: message,
                  ),
                ),
          },
      ],
      'scope': scope.toJson(),
      'used': memory.markdown.runes.length,
      'budget': botUserMemoryLimit,
      'injected': memory.prompt.runes.length,
    };
  }

  Map<String, Object?> _change(
    Bot bot,
    MemoryHistoryScope scope,
    Map<String, Object?> args,
  ) {
    final rows = _field<List<Object?>>(args, 'changes');
    if (rows == null || rows.isEmpty || rows.length > 40) throw _bad;
    final changes = <BotMemoryChange>[];
    for (final row in rows) {
      if (row is! Map<String, Object?>) throw _bad;
      final name = _field<String>(row, 'action');
      final id = _field<int>(row, 'id');
      final revision = _field<int>(row, 'revision');
      final text = _field<String>(row, 'text');
      if (name == 'retain') {
        final group = scope.groupId;
        if (!localOwner || rows.length != 1 || id == null || revision == null) {
          throw _bad;
        }
        bots.retainUserMemory(bot, group, id, revision);
        return _entries(bot, scope);
      }
      if (name == 'pin') {
        final pinned = _field<bool>(row, 'pinned');
        if (rows.length != 1 ||
            id == null ||
            revision == null ||
            pinned == null) {
          throw _bad;
        }
        bots.pinUserMemory(bot, id, revision, pinned, group: scope.groupId);
        return _entries(bot, scope);
      }
      final action = BotMemoryAction.values.asNameMap()[name];
      if (action == null ||
          action != BotMemoryAction.add && (id == null || revision == null)) {
        throw _bad;
      }
      changes.add((action: action, id: id, revision: revision, text: text));
    }
    bots.changeUserMemory(
      bot,
      changes,
      group: scope.groupId,
      allowRememberingWithdrawn: changes.every(
        (change) => change.action == BotMemoryAction.add,
      ),
    );
    return _entries(bot, scope);
  }

  Future<Map<String, Object?>> _search(
    MemoryHistoryAccess access,
    Map<String, Object?> args,
    String? historyProject,
  ) async {
    final token = _field<String>(args, 'cursor');
    final cursor = token == null ? null : _cursors[token];
    if (token != null && cursor?.$1 != access.current) throw _bad;
    final page = await botHistoryIndex(bots).search(
      access,
      MemoryHistoryQuery(
        text: _field<String>(args, 'query') ?? (throw _bad),
        cursor: cursor?.$2,
        limit: _field<int>(args, 'limit') ?? 12,
        since: _date(args, 'since'),
        before: _date(args, 'before'),
      ),
    );
    return {
      'hits': [
        for (final hit in page.hits)
          {
            ...hit.toJson(),
            'reference': _rememberSource(hit.reference, historyProject),
          },
      ],
      if (page.cursor case final next?)
        'cursor': _store(_cursors, (access.current, next), 128),
    };
  }

  static DateTime? _date(Map<String, Object?> args, String name) {
    final value = _field<String>(args, name);
    return value == null ? null : DateTime.tryParse(value) ?? (throw _bad);
  }

  Future<Map<String, Object?>> _source(
    MemoryHistoryAccess access,
    Map<String, Object?> args,
    String? historyProject,
  ) async {
    final ref = _sourceRef(access.current, args, historyProject);
    final window = await botHistoryIndex(bots).browse(
      access,
      ref,
      before: _field<int>(args, 'before') ?? 5,
      after: _field<int>(args, 'after') ?? 5,
    );
    if (window == null) throw _missing;
    Map<String, Object?> wire(MemoryHistoryMessage message) => {
      ...message.toJson(),
      'reference': _rememberSource(message.reference, historyProject),
    };
    return {
      'anchor': wire(window.anchor),
      'before': [for (final item in window.before) wire(item)],
      'after': [for (final item in window.after) wire(item)],
      if (_deletableGroupSeq(window.anchor) != null ||
          _deletablePrivateDelivery(window.anchor) ||
          _deletableManagedOriginal(window.anchor, historyProject))
        'canDeleteOriginal': true,
    };
  }

  int? _deletableGroupSeq(MemoryHistoryMessage message) {
    final ref = message.reference;
    final group = ref.scope.groupId;
    if (!localOwner ||
        group == null ||
        ref.sessionId != group ||
        message.kind != MemoryHistoryKind.original) {
      return null;
    }
    final seq = int.tryParse(ref.messageId);
    return seq != null && bots.groups.canDeleteOriginal(group, seq)
        ? seq
        : null;
  }

  bool _deletablePrivateDelivery(MemoryHistoryMessage message) =>
      localOwner &&
      message.kind == MemoryHistoryKind.original &&
      bots.canDeletePrivateDelivery(message.reference);

  bool _deletableManagedOriginal(
    MemoryHistoryMessage message,
    String? project,
  ) =>
      localOwner &&
      message.kind == MemoryHistoryKind.original &&
      bots.canDeleteManagedOriginal(message.reference, project: project);

  Future<Map<String, Object?>> _deleteSource(
    MemoryHistoryAccess access,
    Map<String, Object?> args,
    String? historyProject,
  ) async {
    if (_field<bool>(args, 'confirm') != true) throw _bad;
    final ref = _sourceRef(access.current, args, historyProject);
    final original = await botHistoryIndex(bots).locate(access, ref);
    if (!access.permits(ref.scope)) throw _missing;
    if (original == null) {
      // A published revocation hides the original even if its physical
      // deletion still needs to be retried using the exact remembered ref.
      if (!localOwner ||
          !ManagedTranscripts.isOriginalRevoked(ref.sessionId, ref.messageId) ||
          !bots.canDeleteManagedOriginal(ref, project: historyProject)) {
        throw _missing;
      }
      await bots.deleteManagedOriginal(ref, project: historyProject);
      return {'deleted': true};
    }
    final seq = _deletableGroupSeq(original);
    if (seq != null) {
      await bots.groups.deleteOriginal(ref.scope.groupId!, seq);
    } else if (_deletablePrivateDelivery(original)) {
      await bots.deletePrivateDelivery(ref);
    } else if (_deletableManagedOriginal(original, historyProject)) {
      await bots.deleteManagedOriginal(ref, project: historyProject);
    } else {
      throw const LinkRemoteException(
        LinkErrors.unsupported,
        'This original cannot be deleted here',
      );
    }
    return {'deleted': true};
  }

  Future<Map<String, Object?>> _reviewState(
    BotMemoryScope scope,
    MemoryHistoryScope target,
    Map<String, Object?> args,
  ) async {
    final review = _review;
    final status = await review.status(scope);
    final pendingOnly = _field<bool>(args, 'pendingOnly') ?? true;
    final supportsBatch = _field<bool>(args, 'batch') ?? false;
    final proposals = (await review.proposals(
      scope,
      pendingOnly: pendingOnly,
    )).where(review.canViewProposal).toList();
    return {
      ...status.toJson(),
      'pending': proposals
          .where(
            (proposal) =>
                proposal.status == BotMemoryReviewProposalStatus.pending,
          )
          .length,
      'proposals': [
        for (final proposal
            in proposals
                .where(
                  (proposal) =>
                      supportsBatch ||
                      proposal.action != BotMemoryReviewAction.batch,
                )
                .take(100))
          _proposal(target, proposal),
      ],
    };
  }

  Map<String, Object?> _proposal(
    MemoryHistoryScope scope,
    BotMemoryReviewProposal proposal,
  ) {
    if (!_review.canViewProposal(proposal)) throw _missing;
    final json = proposal.toJson();
    final projectId = proposal.project;
    final project = projectId == null
        ? null
        : bots.workspace.localProjectById(projectId);
    final sourceScope = projectId == null
        ? scope
        : project == null
        ? null
        : MemoryHistoryScope.project(scope.botId, project.path);
    final sources = <(String, String), Map<String, Object?>>{};
    Map<String, Object?>? evidenceSource(Map<String, Object?> row) {
      if (sourceScope == null ||
          row['role'] == 'task' ||
          row['sessionId'] is! String ||
          row['messageId'] is! String) {
        return null;
      }
      final session = sourceScope.groupId ?? row['sessionId'] as String;
      var message = row['messageId'] as String;
      if (projectId != null) {
        if (!_canViewProjectHistory(sourceScope, projectId) ||
            row['role'] == 'verification') {
          return null;
        }
        // Project evidence IDs are namespaced by the recorded task; the
        // transcript uses the original item ID. Verification is derived
        // from a terminal event and has no browseable text anchor.
        final separator = message.indexOf('/');
        if (separator > 0) message = message.substring(separator + 1);
        if (message.isEmpty) return null;
      }
      return sources.putIfAbsent(
        (session, message),
        () => _rememberSource(
          MemoryHistoryReference(
            scope: sourceScope,
            sessionId: session,
            messageId: message,
          ),
          projectId,
        ),
      );
    }

    List<Map<String, Object?>> wireEvidence(
      List<Map<String, Object?>> evidence,
    ) => [
      for (final row in evidence)
        {'role': row['role'], 'source': ?evidenceSource(row)},
    ];
    return {
      ...json,
      if (json['changes'] case final List<Map<String, Object?>> changes)
        'changes': [
          for (final change in changes)
            {
              ...change,
              'evidence': wireEvidence(
                change['evidence'] as List<Map<String, Object?>>,
              ),
            },
        ],
      'evidence': wireEvidence(proposal.evidence),
    };
  }

  MemoryHistoryReference _sourceRef(
    MemoryHistoryScope scope,
    Map<String, Object?> args,
    String? project,
  ) {
    final source = _field<Map<String, Object?>>(args, 'source');
    final stored = _sources[source?['token']];
    if (stored == null || stored.$1.scope != scope || stored.$2 != project) {
      throw _missing;
    }
    return stored.$1;
  }

  Map<String, Object?> _rememberSource(
    MemoryHistoryReference ref, [
    String? project,
  ]) => {
    'scope': ref.scope.toJson(),
    'historyProject': ?project,
    'token': _store(_sources, (ref, project), 3000),
  };

  int _nextToken = 0;
  String _store<T>(Map<String, T> store, T value, int limit) {
    if (store.length >= limit) store.remove(store.keys.first);
    final token = (++_nextToken).toRadixString(36);
    store[token] = value;
    return token;
  }
}

/// Null for ordinary conversation, empty for a refinement with no focus.
String? refineBotFocus(String text) =>
    RegExp(r'^/refine(?:\s+([\s\S]*))?$').firstMatch(text.trim())?.group(0) ==
        null
    ? null
    : text.trim().substring('/refine'.length).trim();
