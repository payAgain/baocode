part of 'bots.dart';

/// A diff bound to the owner's open Bot and the exact revisions reviewed.
final class BotMemoryMigrationPreview {
  const BotMemoryMigrationPreview._({
    required this.before,
    required this.after,
    required this.removed,
    required this.added,
    required this.restoring,
    required this._owner,
    required this._bot,
    required this._source,
    required this._ledgerDigest,
    required this._mirrorDigest,
    required this._inputDigest,
  });

  final String before;
  final String after;
  final int removed;
  final int added;
  final bool restoring;
  final Bots _owner;
  final Bot _bot;
  final BotMemoryMirror _source;
  final String _ledgerDigest;
  final String _mirrorDigest;
  final String _inputDigest;

  bool get hasChanges => before != after || added != 0 || removed != 0;
}

extension BotOwnerMemoryMigration on Bots {
  Bot _migrationBot(Bot bot) {
    final live = byId(bot.id);
    if (_disposed ||
        live == null ||
        live.created != bot.created ||
        live.folder != bot.folder ||
        folders.root == null) {
      throw StateError('This Bot memory is no longer available.');
    }
    return live;
  }

  String _migrationFolder(Bot bot) =>
      p.join(_runtimeRoot(bot), 'memory-migration');

  String _mirrorPath(Bot bot, BotMemoryMirror source) =>
      p.join(bot.folder, source.fileName);

  BotLegacyMarkdownBackup? _backupLegacyMirror(
    Bot bot,
    BotMemoryMirror source, {
    required bool authorityExists,
  }) => backupBotLegacyMarkdown(
    folders,
    backupFolder: _migrationFolder(bot),
    sourcePath: _mirrorPath(bot, source),
    sourceKind: source.name,
    authorityExists: authorityExists,
  );

  Map<String, Object?>? _readMemoryLedger(String path) {
    final bytes = folders.readFile(path, strict: true);
    return bytes == null
        ? null
        : jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
  }

  BotMemoryMirrorWrite _planMirrorWrite(
    Bot bot,
    BotMemoryMirror source, {
    required Map<String, Object?>? ledger,
    required String before,
    required String after,
    String? reviewedDigest,
  }) {
    final path = _mirrorPath(bot, source);
    final observed = botMemoryDigest(folders.readFile(path, strict: true));
    final known = botMemoryKnownMirror(ledger, source);
    if (known == null) {
      _backupLegacyMirror(bot, source, authorityExists: ledger != null);
    }
    if (reviewedDigest != null && reviewedDigest != observed) {
      throw StateError('The Markdown changed. Review it again.');
    }
    return BotMemoryMirrorWrite(
      path: path,
      observed: observed,
      known: known,
      canPublish:
          reviewedDigest != null ||
          ledger == null ||
          observed == known ||
          observed == botMemoryDigest(botMemoryMirrorBytes(before)),
      markdown: after,
    );
  }

  void _publishMemoryMirror(BotMemoryMirrorWrite write) {
    try {
      write.publish(folders);
    } on FileSystemException {
      // The authority already committed. Leave the mirror for owner review.
      debugPrint('Bot memory mirror could not be updated.');
    }
  }

  BotLegacyMarkdownBackup? ownerMemoryBackup(Bot bot, BotMemoryMirror source) {
    bot = _migrationBot(bot);
    return readBotLegacyMarkdownBackup(
      folders,
      backupFolder: _migrationFolder(bot),
      sourcePath: _mirrorPath(bot, source),
      sourceKind: source.name,
    );
  }

  ({
    BotMemory memory,
    BotFactStore? facts,
    String markdown,
    List<BotMemoryEntry> entries,
  })
  _migrationCurrent(Bot bot, BotMemoryMirror source) {
    if (source == BotMemoryMirror.memory) {
      final memory = userMemory(bot);
      return (
        memory: memory,
        facts: null,
        markdown: memory.markdown,
        entries: memory.activeEntries.toList(),
      );
    }
    final facts = _privateFacts(bot);
    final kind = source == BotMemoryMirror.self
        ? BotFactKind.self
        : BotFactKind.person;
    return (
      memory: facts.memory,
      facts: facts,
      markdown: source == BotMemoryMirror.self
          ? facts.selfMarkdown
          : facts.peopleMarkdown,
      entries: [
        for (final fact in facts.entries)
          if (fact.kind == kind &&
              !facts.memory.unavailableEntries.contains(fact.id))
            fact.entry,
      ],
    );
  }

  Uint8List ownerMemoryExport(Bot bot, BotMemoryMirror source) {
    final current = _migrationCurrent(_migrationBot(bot), source);
    return utf8.encode(
      '${const JsonEncoder.withIndent('  ').convert({
        'version': 1,
        'scope': 'private',
        'source': source.fileName,
        'now': ?(source == BotMemoryMirror.self ? current.facts!.now : null),
        'entries': [for (final entry in current.entries) entry.toJson()],
      })}\n',
    );
  }

  bool ownerMemoryMirrorChanged(Bot bot, BotMemoryMirror source) {
    bot = _migrationBot(bot);
    final current = _migrationCurrent(bot, source);
    final ledger = _readMemoryLedger(
      source == BotMemoryMirror.memory
          ? _memoryDataPath(bot, null)
          : _factPath(bot, null),
    );
    if (ledger == null) return false;
    final bytes = folders.readFile(_mirrorPath(bot, source), strict: true);
    final digest = botMemoryDigest(bytes);
    return digest != botMemoryKnownMirror(ledger, source) &&
        digest != botMemoryDigest(botMemoryMirrorBytes(current.markdown));
  }

  BotMemoryMigrationPreview previewOwnerMemoryMigration(
    Bot bot,
    BotMemoryMirror source, {
    bool restore = false,
  }) => _ownerMemoryPlan(bot, source, restore: restore).preview;

  ({
    BotMemoryMigrationPreview preview,
    BotMemory previous,
    BotMemory candidate,
    BotFactStore? previousFacts,
    BotFactStore? facts,
  })
  _ownerMemoryPlan(Bot bot, BotMemoryMirror source, {required bool restore}) {
    bot = _migrationBot(bot);
    final current = _migrationCurrent(bot, source);
    final mirror = folders.readFile(_mirrorPath(bot, source), strict: true);
    final bytes = restore ? ownerMemoryBackup(bot, source)?.bytes : mirror;
    if (bytes == null) {
      throw StateError(
        restore ? 'The original backup is unavailable.' : 'The Markdown file is missing. A missing file cannot be imported.',
      );
    }
    final ledgerPath = source == BotMemoryMirror.memory
        ? _memoryDataPath(bot, null)
        : _factPath(bot, null);
    final ledger = folders.readFile(ledgerPath, strict: true);
    if (!restore &&
        botMemoryKnownMirror(
              ledger == null
                  ? null
                  : jsonDecode(utf8.decode(ledger)) as Map<String, Object?>,
              source,
            ) ==
            null) {
      _backupLegacyMirror(bot, source, authorityExists: ledger != null);
    }
    final markdown = decodeBotMemoryMarkdown(bytes);
    final ledgerDigest = botMemoryDigest(ledger);
    final previous = current.memory;
    final previousFacts = current.facts;
    final now = _clock();
    final facts = previousFacts?.importLegacyMarkdown(
      markdown,
      peopleMirror: source == BotMemoryMirror.people,
      appendOnly: restore,
      ownerNames: _ownerFactNames,
      at: now,
    );
    final candidate =
        facts?.memory ??
        _importPreferenceMarkdown(
          previous,
          markdown,
          restore: restore,
          at: now,
        );
    final after = switch (source) {
      BotMemoryMirror.memory => candidate.markdown,
      BotMemoryMirror.self => facts!.selfMarkdown,
      BotMemoryMirror.people => facts!.peopleMarkdown,
    };
    final oldIds = {for (final entry in previous.entries) entry.id};
    final newIds = {for (final entry in candidate.entries) entry.id};
    return (
      preview: BotMemoryMigrationPreview._(
        before: current.markdown,
        after: after,
        removed: oldIds.difference(newIds).length,
        added: newIds.difference(oldIds).length,
        restoring: restore,
        owner: this,
        bot: bot,
        source: source,
        ledgerDigest: ledgerDigest,
        mirrorDigest: botMemoryDigest(mirror),
        inputDigest: botMemoryDigest(bytes),
      ),
      previous: previous,
      candidate: candidate,
      previousFacts: previousFacts,
      facts: facts,
    );
  }

  BotMemory _importPreferenceMarkdown(
    BotMemory previous,
    String markdown, {
    required bool restore,
    required DateTime at,
  }) {
    final originalEntries = previous.entries;
    if (!restore && markdown.trim() == previous.markdown) return previous;
    if (!restore &&
        BotMemory.fromMarkdown(previous.markdown).entries.length !=
            originalEntries.length) {
      throw StateError(
        'These notes contain mixed Markdown. Edit them in Memory to preserve individual entries.',
      );
    }
    final drafts = [
      if (restore)
        for (final entry in originalEntries)
          (text: entry.text, markdown: entry.markdown, key: entry.key),
    ];
    for (final entry in BotMemory.fromMarkdown(markdown).entries) {
      if (restore &&
          drafts.any(
            (draft) =>
                normalizeBotMemoryMarkdown(draft.text).trimRight() ==
                entry.text.trimRight(),
          )) {
        continue;
      }
      drafts.add((text: entry.text, markdown: entry.markdown, key: null));
    }
    return previous.replaceDrafts(drafts, at: at, verifyImport: true);
  }

  void applyOwnerMemoryMigration(BotMemoryMigrationPreview reviewed) {
    if (!identical(reviewed._owner, this)) {
      throw StateError('This Bot memory is no longer available.');
    }
    final bot = _migrationBot(reviewed._bot);
    final source = reviewed._source;
    final plan = _ownerMemoryPlan(bot, source, restore: reviewed.restoring);
    if (plan.preview._ledgerDigest != reviewed._ledgerDigest ||
        plan.preview._mirrorDigest != reviewed._mirrorDigest ||
        plan.preview._inputDigest != reviewed._inputDigest ||
        plan.preview.after != reviewed.after) {
      throw StateError(
        'The saved memory or Markdown changed. Review the differences again.',
      );
    }
    if (!plan.preview.hasChanges) return;
    final reviewedDigest = reviewed.restoring ? null : reviewed._mirrorDigest;
    if (plan.facts case final facts?) {
      _commitFacts(
        bot,
        null,
        plan.previousFacts!,
        facts,
        reviewedMirror: source,
        reviewedDigest: reviewedDigest,
      );
      return;
    }
    _writeUserMemory(bot, plan.candidate, reviewedDigest: reviewedDigest);
    if (plan.candidate.withdrawalGeneration !=
        plan.previous.withdrawalGeneration) {
      memoryWithdrawn(bot);
    }
    _forgetRemovedMemory(bot, plan.previous, plan.candidate);
    _factsChanged();
  }
}
