part of 'bots.dart';

extension BotFacts on Bots {
  Set<String> get _ownerFactNames => {
    userName,
    if (_me.name.isNotEmpty) _me.name,
    '用户',
    'the user',
    'user',
  };

  String _factPath(Bot bot, String? projectId) => projectId == null
      ? p.join(_runtimeRoot(bot), 'private-facts.json')
      : p.join(_runtimeRoot(bot), 'project-facts', '$projectId.json');

  BotFactStore? _readSavedFacts(Bot bot, String? projectId) {
    final bytes = folders.readFile(_factPath(bot, projectId), strict: true);
    if (bytes == null) return null;
    return BotFactStore.fromJson(
      jsonDecode(utf8.decode(bytes)) as Map<String, Object?>,
      isProject: projectId != null,
    ).withUnavailableSources(
      (entry) => _managedSourceDeleted(
        bot,
        projectId,
        entry.session,
        entry.sourceMessage,
      ),
    );
  }

  bool _managedSourceDeleted(
    Bot bot,
    String? projectId,
    String? sessionId,
    String? messageId,
  ) =>
      sessionId != null &&
      messageId != null &&
      isManagedOriginalDeleted(
        BotMemoryScope(botId: bot.id),
        projectId,
        sessionId,
        messageId,
      );

  BotFactStore _privateFacts(Bot bot, {bool persistLegacy = true}) {
    if (_readSavedFacts(bot, null) case final saved?) return saved;
    final selfPath = p.join(bot.folder, BotFiles.self);
    final peoplePath = p.join(bot.folder, BotLife.people);
    final self = folders.readFile(selfPath, strict: true);
    final people = folders.readFile(peoplePath, strict: true);
    if (persistLegacy) {
      if (self != null) {
        _backupLegacyMirror(bot, BotMemoryMirror.self, authorityExists: false);
      }
      if (people != null) {
        _backupLegacyMirror(
          bot,
          BotMemoryMirror.people,
          authorityExists: false,
        );
      }
    }
    final store = BotFactStore.fromLegacy(
      self: self == null
          ? ''
          : decodeBotMemoryMarkdown(self, allowMalformed: true),
      people: people == null
          ? ''
          : decodeBotMemoryMarkdown(people, allowMalformed: true),
      ownerNames: _ownerFactNames,
    );
    if (persistLegacy && (self != null || people != null)) {
      _writeFactStore(
        bot,
        null,
        store,
        digests: {
          'self': botMemoryDigest(self),
          'people': botMemoryDigest(people),
        },
      );
    }
    return store;
  }

  void _writeFactStore(
    Bot bot,
    String? projectId,
    BotFactStore store, {
    Map<String, String> digests = const {},
  }) {
    folders.writeFileAtomically(
      _factPath(bot, projectId),
      utf8.encode(
        jsonEncode({
          ...store.toJson(),
          if (digests.isNotEmpty) botMemoryMirrorDigestsKey: digests,
        }),
      ),
    );
  }

  void _writePrivateFacts(
    Bot bot,
    BotFactStore previous,
    BotFactStore store, {
    BotMemoryMirror? reviewedMirror,
    String? reviewedDigest,
  }) {
    final ledger = _readMemoryLedger(_factPath(bot, null));
    final writes = {
      for (final (source, before, after) in [
        (BotMemoryMirror.self, previous.selfMarkdown, store.selfMarkdown),
        (BotMemoryMirror.people, previous.peopleMarkdown, store.peopleMarkdown),
      ])
        source: _planMirrorWrite(
          bot,
          source,
          ledger: ledger,
          before: before,
          after: after,
          reviewedDigest: source == reviewedMirror ? reviewedDigest : null,
        ),
    };
    _writeFactStore(
      bot,
      null,
      store,
      digests: {
        for (final item in writes.entries)
          item.key.name: ?item.value.knownAfter,
      },
    );
    writes.values.forEach(_publishMemoryMirror);
  }

  BotFactAccess privateFactAccess(
    Bot bot, {
    String? sessionId,
    String? sourceMessage,
  }) {
    final live = byId(bot.id);
    if (live == null ||
        live.folder != bot.folder ||
        live.created != bot.created) {
      throw StateError('The Bot fact scope is unavailable.');
    }
    if (sourceMessage != null && sessionId == null ||
        sessionId != null && threadOf(live)?.id != sessionId) {
      throw StateError('The private conversation is no longer active.');
    }
    return BotFactAccess(
      _factOwners.putIfAbsent(bot.id, Object.new),
      botId: bot.id,
      sessionId: sessionId,
      sourceMessage: sourceMessage,
    );
  }

  BotFactAccess? projectFactAccess(String botId, String projectId) {
    final bot = byId(botId);
    if (bot == null ||
        !bot.can(BotAbility.agents) ||
        workspace.localProjectById(projectId) == null) {
      return null;
    }
    return BotFactAccess(
      _factOwners.putIfAbsent(botId, Object.new),
      botId: botId,
      projectId: projectId,
    );
  }

  Bot _checkFactAccess(BotFactAccess access) {
    final bot = byId(access.botId);
    final owner = _factOwners[access.botId];
    final projectId = access.projectId;
    if (bot == null ||
        owner == null ||
        !access.belongsTo(owner) ||
        access.sessionId != null && threadOf(bot)?.id != access.sessionId ||
        projectId != null &&
            (!bot.can(BotAbility.agents) ||
                workspace.localProjectById(projectId) == null)) {
      throw StateError('The Bot fact scope is unavailable.');
    }
    return bot;
  }

  BotFactStore factMemory(BotFactAccess access) {
    final bot = _checkFactAccess(access);
    final project = access.projectId;
    if (project == null) return _privateFacts(bot);
    return _readSavedFacts(bot, project) ?? BotFactStore.empty(isProject: true);
  }

  /// The caller has already bound a local task to this bot and project.
  String projectFactPrompt(String botId, String projectId) {
    final access = projectFactAccess(botId, projectId);
    return access == null ? '' : factMemory(access).memory.prompt;
  }

  BotFactStore changeFacts(
    BotFactAccess access,
    List<BotFactChange> changes, {
    bool allowRememberingWithdrawn = false,
  }) {
    final bot = _checkFactAccess(access);
    final previous = factMemory(access);
    if (_managedSourceDeleted(
          bot,
          access.projectId,
          access.sessionId,
          access.sourceMessage,
        ) ||
        access.sessionId != null &&
            changes.any(
              (change) =>
                  previous.memory.unavailableEntries.contains(change.id),
            )) {
      throw StateError('The fact source was deleted');
    }
    final current = previous.apply(
      changes,
      at: _clock(),
      session: access.sessionId,
      sourceMessage: access.sourceMessage,
      ownerNames: _ownerFactNames,
      allowRememberingWithdrawn:
          access.sessionId == null || allowRememberingWithdrawn,
    );
    return _commitFacts(bot, access.projectId, previous, current);
  }

  /// Commits a batch whose primary sources the review service has verified.
  BotFactStore applyReviewedProjectFacts(
    String botId,
    String projectId,
    List<BotMemoryChange> changes, {
    required String operationId,
    required List<BotMemorySource> changeSources,
  }) {
    final access = projectFactAccess(botId, projectId);
    if (access == null) {
      throw StateError('The project fact scope is unavailable.');
    }
    if (operationId.trim().isEmpty || changes.isEmpty) {
      throw ArgumentError(
        'A reviewed fact batch requires an operation ID and changes.',
      );
    }
    final bot = _checkFactAccess(access);
    final previous = factMemory(access);
    if (changeSources.any(
          (source) => _managedSourceDeleted(
            bot,
            projectId,
            source.sessionId,
            source.messageId,
          ),
        ) ||
        changes.any(
          (change) => previous.memory.unavailableEntries.contains(change.id),
        )) {
      throw StateError('The fact source was deleted');
    }
    final current = previous.apply(
      [
        for (final change in changes)
          BotFactChange(
            action: change.action,
            id: change.id,
            revision: change.revision,
            text: change.text,
          ),
      ],
      at: _clock(),
      operationId: operationId,
      changeSources: changeSources,
    );
    return _commitFacts(bot, projectId, previous, current);
  }

  BotFactStore retainFact(BotFactAccess access, int id, int revision) {
    final bot = _checkFactAccess(access);
    final previous = factMemory(access);
    return _commitFacts(
      bot,
      access.projectId,
      previous,
      previous.retainWithoutSource(id, revision),
    );
  }

  BotFactStore pinFact(
    BotFactAccess access,
    int id,
    int revision,
    bool pinned,
  ) {
    final bot = _checkFactAccess(access);
    final previous = factMemory(access);
    return _commitFacts(
      bot,
      access.projectId,
      previous,
      previous.withPin(id, revision, pinned),
    );
  }

  BotFactStore _commitFacts(
    Bot bot,
    String? projectId,
    BotFactStore previous,
    BotFactStore current, {
    BotMemoryMirror? reviewedMirror,
    String? reviewedDigest,
  }) {
    if (identical(current, previous)) return current;
    if (projectId == null) {
      _writePrivateFacts(
        bot,
        previous,
        current,
        reviewedMirror: reviewedMirror,
        reviewedDigest: reviewedDigest,
      );

      if (current.memory.withdrawalGeneration !=
          previous.memory.withdrawalGeneration) {
        memoryWithdrawn(bot);
      }
    } else {
      _writeFactStore(bot, projectId, current);
      if (current.memory.withdrawalGeneration !=
          previous.memory.withdrawalGeneration) {
        _checkLiveMemoryShares(bot);
      }
    }
    // The fact ledger has committed. UI readers can safely reload it.
    // Ignore the analyzer's protected warning by notifying through the owner.
    _factsChanged();
    return current;
  }
}
