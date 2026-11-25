import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../search/memory_history.dart';
import 'bot.dart';
import 'bot_folders.dart';
import 'bot_life.dart';

/// Reads old Markdown in place. Scope is supplied only by a separate record in
/// host-managed storage, bound to the exact day, line position and line bytes.
/// In legacy text, display names could contain line breaks, so even a literal
/// `[private]` line is insufficient proof of where the words came from.
final class BotLegacyDiary {
  BotLegacyDiary(this.folders, this.bot);

  final BotFolders folders;
  final Bot bot;

  String get _directory => p.join(bot.folder, BotLife.timeline);
  String get _bookmarks => p.join(folders.root!, 'runtime', bot.id, 'diary-v1');

  static final _dayName = RegExp(r'^\d{4}-\d{2}-\d{2}\.md$');
  static final _line = RegExp(r'^- (\d{2}):(\d{2}) \[([^\]]*)\] (.*)$');
  static final _private = RegExp(r'^- \d{2}:\d{2} \[(private|私聊)\] ');
  static const _prefix = 'bot-diary:';

  Iterable<String> get _days sync* {
    for (final path in folders.filesIn(_directory)) {
      if (_dayName.hasMatch(p.basename(path))) yield path;
    }
  }

  String _bookmarkPath(String path) =>
      p.join(_bookmarks, '${p.basenameWithoutExtension(path)}.json');

  static String _digest(List<int> bytes) => sha256.convert(bytes).toString();

  /// A trusted bookmark can attest an exact legacy summary. If it names a
  /// persisted original, index that original alone, including after deletion.
  /// Unattributed text is available only in an owner's dedicated history scope.
  void bookmark(
    String path,
    int position,
    String line,
    MemoryHistoryScope scope, {
    MemoryHistoryRole? role,
    MemoryHistoryReference? original,
  }) {
    if (folders.root == null ||
        p.dirname(path) != _directory ||
        !_dayName.hasMatch(p.basename(path)) ||
        position < 0 ||
        scope.botId != bot.id ||
        (scope.kind != MemoryHistoryScopeKind.dm &&
            scope.kind != MemoryHistoryScopeKind.group) ||
        (original == null &&
            (role == null || role == MemoryHistoryRole.unknown)) ||
        (original != null && original.scope != scope)) {
      throw ArgumentError('Invalid Bot diary bookmark');
    }
    final saved = _readBookmarks(path, strict: true);
    final digest = _digest(utf8.encode(line));
    final key = '$position:$digest';
    // Keep an existing original's suppression if a later append reuses the slot.
    if (saved[key] case {'original': final Object _}) return;
    saved[key] = {
      'digest': digest,
      'scope': scope.toJson(),
      'role': ?role?.name,
      'original': ?original?.toJson(),
    };
    folders.writeFileAtomically(
      _bookmarkPath(path),
      utf8.encode(jsonEncode(saved)),
    );
  }

  Map<String, Object?> _readBookmarks(String dayPath, {bool strict = false}) {
    if (folders.root == null) return {};
    try {
      final bytes = folders.readFile(_bookmarkPath(dayPath), strict: strict);
      if (bytes == null) return {};
      if (jsonDecode(utf8.decode(bytes)) case final Map<String, Object?> data) {
        return data;
      }
      throw const FormatException('Invalid Bot diary bookmarks');
    } on FormatException {
      if (strict) rethrow;
      return {};
    }
  }

  List<MemoryHistoryMessage> messages(
    MemoryHistoryScope scope, {
    Set<String>? sessionIds,
  }) {
    if (scope.botId != bot.id || scope.kind == MemoryHistoryScopeKind.project) {
      return const [];
    }
    final owner = MemoryHistoryScope.bot(bot.id);
    final messages = <MemoryHistoryMessage>[];
    for (final path in _days) {
      final day = p.basenameWithoutExtension(path);
      final sessionId = '$_prefix$day';
      if (sessionIds != null && !sessionIds.contains(sessionId)) continue;
      final bytes = folders.readFile(path);
      if (bytes == null) continue;
      final bookmarks = _readBookmarks(path);
      List<String> rows;
      try {
        rows = const LineSplitter().convert(utf8.decode(bytes));
      } on FormatException {
        // Preserve malformed legacy bytes in place for manual recovery.
        continue;
      }
      for (final (position, line) in rows.indexed) {
        final match = _line.firstMatch(line);
        if (match == null || match[4]!.trim().isEmpty) continue;
        final at = DateTime.tryParse('$day ${match[1]}:${match[2]}');
        if (at == null ||
            BotLife.dayFile(at) != '${BotLife.timeline}/$day.md') {
          continue;
        }
        if (at.hour.toString().padLeft(2, '0') != match[1] ||
            at.minute.toString().padLeft(2, '0') != match[2]) {
          continue;
        }
        final digest = _digest(utf8.encode(line));
        final bookmark = _matchingBookmark(
          bookmarks['$position:$digest'],
          digest,
        );
        final assigned = bookmark == null
            ? null
            : MemoryHistoryScope.fromJson(bookmark['scope']);
        if ((assigned ?? owner) != scope || bookmark?['original'] != null) {
          continue;
        }
        final role = switch (bookmark?['role']) {
          'user' => MemoryHistoryRole.user,
          'assistant' => MemoryHistoryRole.assistant,
          _ => MemoryHistoryRole.unknown,
        };
        if (assigned != null && role == MemoryHistoryRole.unknown) continue;
        String text = match[4]!.trim();
        if (assigned != null) {
          final colon = text.indexOf(': ');
          if (colon < 0) continue;
          text = text.substring(colon + 2).trim();
        } else {
          // Retain the old label for the host owner's manual investigation.
          text = '[${match[3]}] $text';
        }
        if (text.isEmpty) continue;
        messages.add(
          MemoryHistoryMessage(
            reference: MemoryHistoryReference(
              scope: scope,
              sessionId: sessionId,
              messageId: '${position + 1}:$digest',
            ),
            role: role,
            text: text,
            time: at,
            sequence: position,
            kind: MemoryHistoryKind.diarySummary,
          ),
        );
      }
    }
    return messages;
  }

  static Map<String, Object?>? _matchingBookmark(
    Object? value,
    String digest,
  ) =>
      value is Map<String, Object?> && value['digest'] == digest ? value : null;

  /// Includes both the diary and its routing metadata in cache freshness.
  List<Object?> revisions() => [
    for (final path in _days)
      [
        p.basename(path),
        if (folders.readFile(path) case final bytes?) _digest(bytes),
        if (folders.root != null)
          if (folders.readFile(_bookmarkPath(path)) case final bytes?)
            _digest(bytes),
      ],
  ];

  /// Keep the line positions of other scopes stable across private history clear.
  void forgetPrivate() => _redact((line, bookmark) {
    final scope = MemoryHistoryScope.fromJson(bookmark?['scope']);
    return scope == MemoryHistoryScope.dm(bot.id) ||
        (scope == null && _private.hasMatch(line));
  });

  /// Erases only byte-matching diary lines pinned to this exact original. Keep
  /// the bookmarks so a restored legacy Markdown copy remains suppressed.
  void redactOriginal(MemoryHistoryReference original) {
    if (original.scope.botId != bot.id) return;
    _redact(
      (_, bookmark) =>
          MemoryHistoryReference.fromJson(bookmark?['original']) == original,
    );
  }

  void _redact(bool Function(String, Map<String, Object?>?) drop) {
    for (final path in _days) {
      final bytes = folders.readFile(path, strict: true);
      if (bytes == null) continue;
      List<String> rows;
      try {
        rows = const LineSplitter().convert(utf8.decode(bytes));
      } on FormatException {
        // Preserve malformed legacy bytes in place for manual recovery.
        continue;
      }
      final bookmarks = _readBookmarks(path);
      var changed = false;
      for (final (position, line) in rows.indexed) {
        final digest = _digest(utf8.encode(line));
        final bookmark = _matchingBookmark(
          bookmarks['$position:$digest'],
          digest,
        );
        if (drop(line, bookmark)) {
          rows[position] = '';
          changed = true;
        }
      }
      if (changed) {
        final heading = '# ${p.basenameWithoutExtension(path)}';
        if (rows.any((line) => line.trim().isNotEmpty && line != heading)) {
          folders.writeFileAtomically(
            path,
            utf8.encode('${rows.join('\n')}\n'),
          );
        } else {
          folders.deleteFile(path);
          if (folders.readFile(path, strict: true) != null) {
            throw FileSystemException(
              'Could not clear the private diary',
              path,
            );
          }
        }
      }
    }
  }

  /// A diary summary is derived data. A write failure leaves the authoritative
  /// message untouched and does not make this unbookmarked line searchable by a bot.
  void append(DateTime at, String line, {MemoryHistoryReference? original}) {
    final path = p.join(bot.folder, BotLife.dayFile(at));
    try {
      final bytes = folders.readFile(path, strict: true);
      final old = bytes == null ? '' : utf8.decode(bytes);
      final prefix = old.trim().isEmpty
          ? '# ${p.basenameWithoutExtension(path)}\n\n'
          : old.endsWith('\n') || old.endsWith('\r')
          ? old
          : '$old\n';
      final position = const LineSplitter().convert(prefix).length;
      // Store metadata first. Until the diary append commits, the bookmark's
      // exact line hash cannot match a visible entry at the new position.
      if (original != null) {
        bookmark(path, position, line, original.scope, original: original);
      }
      folders.writeFileAtomically(path, utf8.encode('$prefix$line\n'));
    } on FileSystemException {
      // A message already committed to its transcript is still available.
    } on FormatException {
      // Corrupt routing metadata must not be silently replaced.
    }
  }
}
