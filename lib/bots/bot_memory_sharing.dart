part of 'bots.dart';

/// Local owner actions. Model tools have no entry point for these grants.
extension BotMemorySharing on Bots {
  BotMemory shareMemoryEntry(
    Bot bot, {
    required String group,
    required BotMemoryShareSource source,
    String? projectId,
    required int id,
    required int revision,
  }) {
    final owner = _sharingBot(bot, group);
    final origin = _sharingSource(owner, source, projectId);
    final entry = origin?.activeEntries
        .where((entry) => entry.id == id)
        .firstOrNull;
    if (origin == null || entry == null || entry.revision != revision) {
      throw StateError(
        'The source memory changed or is unavailable. List it again.',
      );
    }
    final previous = userMemory(owner, group: group);
    final random = math.Random.secure();
    final current = previous.shareEntry(
      (
        id: base64Url.encode(List.generate(18, (_) => random.nextInt(256))),
        source: source,
        projectId: projectId,
        sourceId: id,
        sourceRevision: revision,
        sourceGeneration: origin.withdrawalGeneration,
        groupId: group,
      ),
      entry,
      at: _clock(),
    );
    _commitMemoryShares(owner, group, previous, current);
    return current;
  }

  BotMemory revokeMemoryShare(
    Bot bot, {
    required String group,
    required int id,
    required int revision,
    required String shareId,
  }) {
    final owner = _sharingBot(bot, group);
    final previous = userMemory(owner, group: group);
    final entry = previous.entries.where((entry) => entry.id == id).firstOrNull;
    if (entry?.share?.id != shareId || entry?.revision != revision) {
      throw StateError(
        'The shared memory changed or is unavailable. List it again.',
      );
    }
    final current = previous.withdrawShares(
      (item) => item.id == id,
      at: _clock(),
    );
    _commitMemoryShares(owner, group, previous, current);
    return current;
  }

  Bot _sharingBot(Bot requested, String group) {
    final bot = byId(requested.id);
    if (_disposed ||
        bot == null ||
        bot.folder != requested.folder ||
        bot.created != requested.created ||
        groups.byId(group)?.members.contains(bot.id) != true) {
      throw StateError('The destination group is unavailable.');
    }
    return bot;
  }

  BotMemory? _sharingSource(
    Bot bot,
    BotMemoryShareSource source,
    String? projectId,
  ) {
    switch ((source, projectId)) {
      case (BotMemoryShareSource.preference, null):
        return userMemory(bot, keepLegacyIds: true);
      case (BotMemoryShareSource.privateFact, null):
        return factMemory(privateFactAccess(bot)).memory;
      case (BotMemoryShareSource.projectFact, final String id):
        final access = projectFactAccess(bot.id, id);
        return access == null ? null : factMemory(access).memory;
      default:
        return null;
    }
  }

  /// Called on group reads, including snapshot reuse and its request guard.
  /// An invalid grant is tombstoned so eligibility cannot restore the copy.
  BotMemory _checkMemoryShares(Bot bot, String group, BotMemory memory) {
    if (!memory.entries.any((entry) => entry.share != null)) return memory;
    final live = _sharingBot(bot, group);
    final origins = <(BotMemoryShareSource, String?), BotMemory?>{};
    final checked = memory.withdrawShares((entry) {
      final grant = entry.share!;
      if (grant.groupId != group) return true;
      final origin = origins.putIfAbsent((
        grant.source,
        grant.projectId,
      ), () => _sharingSource(live, grant.source, grant.projectId));
      if (origin == null ||
          origin.withdrawalGeneration < grant.sourceGeneration ||
          origin.isWithdrawnEntry(grant.sourceId)) {
        return true;
      }
      // Updates do not change what the user approved. Only explicit approval
      // can publish a new revision. An absent or suspended source revokes it.
      return !origin.activeEntries.any(
        (source) =>
            source.id == grant.sourceId &&
            (source.revision > grant.sourceRevision ||
                source.revision == grant.sourceRevision &&
                    source.markdown == entry.markdown),
      );
    }, at: _clock());
    if (!identical(memory, checked)) {
      _writeUserMemory(live, checked, group: group);
      _forgetRemovedMemory(live, memory, checked, group: group);
    }
    return checked;
  }

  /// Prompt creation also checks cold group workers, which need no restart.
  void _checkLiveMemoryShares(Bot bot) {
    for (final group in groups.groups) {
      if (!group.members.contains(bot.id)) continue;
      final loaded = loadedMemorySnapshot(bot, group: group.id);
      final memory = userMemory(bot, group: group.id);
      if (loaded?.isCurrent(memory, null) == false) {
        memoryWithdrawn(bot, group: group.id);
      }
    }
  }

  /// Re-enabling the Bot's project ability requires new approvals.
  void _withdrawProjectMemoryShares(Bot bot) {
    for (final group in groups.groups) {
      if (!group.members.contains(bot.id)) continue;
      final previous = userMemory(bot, group: group.id);
      final current = previous.withdrawShares(
        (entry) => entry.share?.source == BotMemoryShareSource.projectFact,
        at: _clock(),
      );
      if (identical(previous, current)) continue;
      _writeUserMemory(bot, current, group: group.id);
      _forgetRemovedMemory(bot, previous, current, group: group.id);
    }
  }

  void _commitMemoryShares(
    Bot bot,
    String group,
    BotMemory previous,
    BotMemory current,
  ) {
    if (identical(previous, current)) return;
    _writeUserMemory(bot, current, group: group);
    if (previous.withdrawalGeneration != current.withdrawalGeneration) {
      memoryWithdrawn(bot, group: group);
      _forgetRemovedMemory(bot, previous, current, group: group);
    }
    _factsChanged();
  }
}
