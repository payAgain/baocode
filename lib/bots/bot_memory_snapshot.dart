import 'dart:convert';

import 'bot_memory.dart';

/// The notes and revisions actually prepared for one worker prompt.
class BotMemorySnapshot {
  const BotMemorySnapshot({
    required this.user,
    required this.facts,
    required this.userGeneration,
    required this.factGeneration,
    this.now = '',
    this.legacyNotes,
  });

  factory BotMemorySnapshot.decode(String value) {
    if (!value.startsWith('{"version":2,')) {
      return BotMemorySnapshot(
        user: const [],
        facts: const [],
        userGeneration: 0,
        factGeneration: 0,
        legacyNotes: value,
      );
    }
    final json = jsonDecode(value) as Map<String, Object?>;
    List<BotMemoryEntry> entries(String key) => [
      for (final entry in json[key] as List)
        BotMemoryEntry.fromJson(entry as Map<String, Object?>),
    ];
    return BotMemorySnapshot(
      user: entries('user'),
      facts: entries('facts'),
      userGeneration: json['userGeneration'] as int,
      factGeneration: json['factGeneration'] as int,
      now: json['now'] as String,
    );
  }

  final List<BotMemoryEntry> user;
  final List<BotMemoryEntry> facts;
  final String now;
  final int userGeneration;
  final int factGeneration;
  final String? legacyNotes;

  String encode() =>
      legacyNotes ??
      jsonEncode({
        'version': 2,
        'user': [for (final entry in user) entry.toJson()],
        'facts': [for (final entry in facts) entry.toJson()],
        'userGeneration': userGeneration,
        'factGeneration': factGeneration,
        'now': now,
      });

  bool isCurrent(BotMemory user, BotMemory? facts) =>
      userGeneration == user.withdrawalGeneration &&
      factGeneration == (facts?.withdrawalGeneration ?? 0) &&
      this.user.every((entry) => _validEntry(entry, user)) &&
      this.facts.every((entry) => facts != null && _validEntry(entry, facts));

  static bool _validEntry(BotMemoryEntry entry, BotMemory memory) =>
      !memory.isWithdrawnEntry(entry.id) &&
      !memory.unavailableEntries.contains(entry.id) &&
      (entry.share == null ||
          memory.activeEntries.any(
            (current) =>
                current.id == entry.id &&
                current.revision == entry.revision &&
                current.share == entry.share &&
                current.markdown == entry.markdown,
          ));

  BotMemorySnapshot withoutWithdrawn(BotMemory user, BotMemory? facts) =>
      BotMemorySnapshot(
        user: this.user.where((entry) => _validEntry(entry, user)).toList(),
        facts: [
          if (facts != null)
            for (final entry in this.facts)
              if (_validEntry(entry, facts)) entry,
        ],
        userGeneration: user.withdrawalGeneration,
        factGeneration: facts?.withdrawalGeneration ?? 0,
        now: now,
      );
}
