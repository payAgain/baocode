import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'turn_stats.dart';

/// The turns' records in [directory], one file per session
/// (`<session id>.jsonl`), a line per turn.
///
/// Only ever appended to, never read back and written over, and each line
/// under the file's lock: sessions ending turns at once cannot lose one
/// another's lines. Dart's append mode alone does not do: it seeks to the
/// end and writes there, and two writers at once write over each other.
/// The lock keeps another app out; within this one, every session writes
/// from the one isolate, a line at a time, in one go.
class TurnStatsFiles implements TurnStats, TurnCompletionStore {
  TurnStatsFiles(this.directory);

  final String directory;

  /// A session's file; null for an id that is no file name (Claude Code's
  /// are uuids).
  File? _fileOf(String sessionId) =>
      RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(sessionId)
      ? File(p.join(directory, '$sessionId.jsonl'))
      : null;

  @override
  void write(String sessionId, String turnId, TurnRecord record) =>
      _append(sessionId, TurnStats.encode(turnId, record));

  @override
  void writeCompletion(
    String sessionId,
    String turnId,
    TurnRecord? timing,
    TurnCompletion completion,
  ) => _append(
    sessionId,
    jsonEncode({
      if (timing != null)
        ...jsonDecode(TurnStats.encode(turnId, timing)) as Map<String, Object?>,
      'turn': turnId,
      'succeeded': completion.succeeded,
      'toolIterations': completion.toolIterations,
      'itemIds': completion.itemIds,
      'successfulCommands': completion.successfulCommands,
      if (completion.noteDigests.isNotEmpty)
        'noteDigests': completion.noteDigests.toList(),
    }),
  );

  void _append(String sessionId, String line) {
    final file = _fileOf(sessionId);
    if (file == null) return;
    try {
      file.parent.createSync(recursive: true);
      final open = file.openSync(mode: FileMode.append);
      try {
        open.lockSync(FileLock.blockingExclusive);
        // The end as it is now, another's line written meanwhile.
        open
          ..setPositionSync(open.lengthSync())
          ..writeStringSync('$line\n')
          ..flushSync();
      } finally {
        // Unlocks it too.
        open.closeSync();
      }
    } on FileSystemException catch (error) {
      debugPrint('Turn not kept: $error');
    }
  }

  @override
  Future<Map<String, TurnRecord>> read(String sessionId) async =>
      TurnStats.decode(await _lines(sessionId));

  @override
  Future<Map<String, TurnCompletion>> readCompletions(String sessionId) async {
    final records = <String, TurnCompletion>{};
    for (final line in await _lines(sessionId)) {
      try {
        final value = jsonDecode(line);
        if (value
            case final Map<String, Object?> row &&
                {
                  'turn': final String turn,
                  'succeeded': final bool succeeded,
                  'toolIterations': final int toolIterations,
                  'itemIds': final List<Object?> itemIds,
                  'successfulCommands':
                      final Map<String, Object?> successfulCommands,
                }) {
          records[turn] = (
            succeeded: succeeded,
            toolIterations: toolIterations,
            itemIds: itemIds.whereType<String>().toList(),
            successfulCommands: {
              for (final entry in successfulCommands.entries)
                if (entry.value case final String digest) entry.key: digest,
            },
            noteDigests: switch (row['noteDigests']) {
              final List<Object?> notes => notes.whereType<String>().toSet(),
              _ => const {},
            },
          );
        }
      } on FormatException {
        // A process can stop with a partial final line.
      }
    }
    return records;
  }

  Future<List<String>> _lines(String sessionId) async {
    final file = _fileOf(sessionId);
    if (file == null) return const [];
    try {
      return await file.readAsLines();
    } on FileSystemException {
      return const [];
    } on FormatException {
      return const [];
    }
  }
}

/// The records kept in [directory].
TurnStats? turnStatsIn(String directory) => TurnStatsFiles(directory);
