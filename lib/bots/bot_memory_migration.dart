import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'bot_folders.dart';

/// The first available version of a Markdown source, preserved byte for byte.
/// A completed archive is immutable, including across migration retries.
final class BotLegacyMarkdownBackup {
  BotLegacyMarkdownBackup._(
    this.source,
    this.digest,
    this.possiblyMirrored,
    Uint8List bytes,
  ) : bytes = bytes.asUnmodifiableView();

  static const version = 1;

  final String source;
  final String digest;
  final bool possiblyMirrored;
  final Uint8List bytes;

  Map<String, Object?> _toJson() => {
    'version': version,
    'source': source,
    'sha256': digest,
    'possiblyMirrored': possiblyMirrored,
    'bytes': base64Encode(bytes),
  };

  static BotLegacyMarkdownBackup _decode(Uint8List record, String source) {
    final Object? decoded = jsonDecode(utf8.decode(record));
    if (decoded
        case {
          'version': version,
          'source': final String savedSource,
          'sha256': final String digest,
          'possiblyMirrored': final bool possiblyMirrored,
          'bytes': final String encoded,
        }
        when savedSource == source) {
      final bytes = base64Decode(encoded);
      if (sha256.convert(bytes).toString() == digest) {
        return BotLegacyMarkdownBackup._(
          source,
          digest,
          possiblyMirrored,
          bytes,
        );
      }
    }
    throw const FormatException('Invalid Bot memory migration backup');
  }
}

String _archivePath(String folder, String kind) {
  if (!RegExp(r'^[a-z][a-z0-9_-]*$').hasMatch(kind)) {
    throw ArgumentError.value(kind, 'sourceKind');
  }
  return p.join(folder, '$kind.json');
}

/// The manifest and original bytes live in one atomic file so either the whole
/// archive exists or the next attempt can start again. Call this before writing
/// the authoritative store or replacing a Markdown mirror. An invalid archive
/// is retained for recovery and is never silently overwritten.
BotLegacyMarkdownBackup? backupBotLegacyMarkdown(
  BotFolders folders, {
  required String backupFolder,
  required String sourcePath,
  required String sourceKind,
  required bool authorityExists,
}) {
  final path = _archivePath(backupFolder, sourceKind);
  final source = p.basename(sourcePath);
  final saved = folders.readFile(path, strict: true);
  if (saved != null) return BotLegacyMarkdownBackup._decode(saved, source);
  final original = folders.readFile(sourcePath, strict: true);
  if (original == null) return null;
  final archive = BotLegacyMarkdownBackup._(
    source,
    sha256.convert(original).toString(),
    authorityExists,
    original,
  );
  final encoded = utf8.encode(jsonEncode(archive._toJson()));
  folders.writeFileAtomically(path, encoded);
  final written = folders.readFile(path, strict: true);
  if (written == null) {
    throw StateError('Bot memory migration backup was not saved');
  }
  final verified = BotLegacyMarkdownBackup._decode(written, source);
  if (verified.digest != archive.digest ||
      verified.possiblyMirrored != archive.possiblyMirrored) {
    throw StateError('Bot memory migration backup changed during capture');
  }
  return verified;
}

/// Reads the original bytes for owner recovery without backing up a new file.
BotLegacyMarkdownBackup? readBotLegacyMarkdownBackup(
  BotFolders folders, {
  required String backupFolder,
  required String sourcePath,
  required String sourceKind,
}) {
  final saved = folders.readFile(
    _archivePath(backupFolder, sourceKind),
    strict: true,
  );
  return saved == null
      ? null
      : BotLegacyMarkdownBackup._decode(saved, p.basename(sourcePath));
}

enum BotMemoryMirror {
  memory('MEMORY.md'),
  self('SELF.md'),
  people('PEOPLE.md');

  const BotMemoryMirror(this.fileName);

  final String fileName;
}

String decodeBotMemoryMarkdown(
  Uint8List bytes, {
  bool allowMalformed = false,
}) => normalizeBotMemoryMarkdown(
  utf8.decode(bytes, allowMalformed: allowMalformed),
);

String normalizeBotMemoryMarkdown(String markdown) =>
    markdown.replaceAll(RegExp(r'\r\n?'), '\n');

List<String> _normalizedHermesLines(String markdown) =>
    normalizeBotMemoryMarkdown(
      markdown.startsWith('\uFEFF') ? markdown.substring(1) : markdown,
    ).split('\n');

/// Hermes stores independent Markdown notes separated by a standalone section
/// delimiter. A leading BOM is transport metadata, not part of the first note.
List<String> splitHermesMemoryNotes(String markdown) {
  final notes = <String>[];
  final current = <String>[];
  void finish() {
    final section = current.join('\n').trim();
    if (section.isNotEmpty) notes.add(section);
    current.clear();
  }

  for (final line in _normalizedHermesLines(markdown)) {
    if (line.trim() == '§') {
      finish();
    } else {
      current.add(line);
    }
  }
  finish();
  return notes;
}

/// Whether [markdown] looks like a plain multi-bullet Markdown list rather
/// than Hermes `§`-delimited notes.
bool looksLikeNonHermesBulletList(String markdown) {
  final lines = _normalizedHermesLines(markdown);
  if (lines.any((line) => line.trim() == '§')) return false;
  var bullets = 0;
  for (final line in lines) {
    if (line.startsWith('- ') && ++bullets >= 2) return true;
  }
  return false;
}

/// Default BaoCode target for a standard Hermes memory filename.
BotMemoryMirror? defaultHermesImportTarget(String fileName) =>
    switch (fileName.trim().toLowerCase()) {
      'memory.md' => BotMemoryMirror.self,
      'user.md' => BotMemoryMirror.memory,
      _ => null,
    };

String botMemoryDigest(Uint8List? bytes) =>
    bytes == null ? 'missing' : sha256.convert(bytes).toString();

Uint8List? botMemoryMirrorBytes(String markdown) =>
    markdown.trim().isEmpty ? null : utf8.encode('${markdown.trimRight()}\n');

/// Kept alongside the entry ledger. A normal write may update a mirror only
/// if it is still at the last known version or already matches the ledger.
const botMemoryMirrorDigestsKey = 'mirrorDigests';

String? botMemoryKnownMirror(
  Map<String, Object?>? ledger,
  BotMemoryMirror kind,
) => switch (ledger?[botMemoryMirrorDigestsKey]) {
  final Map<String, Object?> digests => digests[kind.name] as String?,
  _ => null,
};

final class BotMemoryMirrorWrite {
  BotMemoryMirrorWrite({
    required this.path,
    required this.observed,
    required this.canPublish,
    required String markdown,
    required this._known,
  }) : bytes = botMemoryMirrorBytes(markdown);

  final String path;
  final String observed;
  final bool canPublish;
  final Uint8List? bytes;
  final String? _known;

  String? get knownAfter => canPublish ? botMemoryDigest(bytes) : _known;

  /// Call after the authoritative ledger commits. A newer external edit is
  /// left for the owner to review, even if it arrived during the ledger write.
  void publish(BotFolders folders) {
    if (!canPublish || observed == knownAfter) return;
    if (botMemoryDigest(folders.readFile(path, strict: true)) != observed) {
      return;
    }
    if (bytes case final data?) {
      folders.writeFileAtomically(path, data);
    } else {
      folders.deleteFile(path);
    }
  }
}
