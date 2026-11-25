import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:bao_agent/bao_agent.dart' show AgentPaths, agentVersion;
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import '../../platform/data_dir.dart';

/// Transcripts the desktop host gives the built-in engine its own place for.
/// A writer must hold the session's lease until it can no longer write.
abstract final class ManagedTranscripts {
  static String get _root =>
      p.join(DataDirectory.current.stateDir, 'managed-transcripts');
  static String get projectsDir => p.join(_root, 'projects');
  static String get _locksDir => p.join(_root, 'locks');
  static List<String> get _projectAncestors => [
    DataDirectory.current.stateDir,
    _root,
    projectsDir,
  ];

  /// Missing directories are allowed. Existing managed ancestors must be
  /// directories without symlinks.
  static bool get isManagedRootSafe {
    try {
      return _projectAncestors.every(
        (dir) => _suitable(dir, FileSystemEntityType.directory, true),
      );
    } on FileSystemException {
      return false;
    }
  }

  static const deletedOriginalKey = 'baocodeDeletedOriginal';

  static String transcriptPath(String cwd, String sessionId) {
    _checkId(sessionId, 'sessionId');
    if (cwd.isEmpty || cwd.contains('\u0000')) {
      throw ArgumentError.value(cwd, 'cwd', 'invalid working directory');
    }
    return p.join(
      projectsDir,
      AgentPaths.projectDirName(p.normalize(cwd)),
      '$sessionId.jsonl',
    );
  }

  static bool exists(String cwd, String sessionId) {
    try {
      final path = transcriptPath(cwd, sessionId);
      return _isOwnedFile(path);
    } on ArgumentError {
      return false;
    } on FileSystemException {
      return false;
    }
  }

  /// Checks the host-owned layout before reading or creating this path.
  /// Missing entries are allowed. The caller still needs the writer's lease.
  static bool isManagedPathSafe(String cwd, String sessionId) {
    try {
      return _safeLayout(transcriptPath(cwd, sessionId), allowMissing: true);
    } on ArgumentError {
      return false;
    } on FileSystemException {
      return false;
    }
  }

  // The UUID is independent of cwd, so resuming or relocating a session uses
  // the same fence. Keep the lock file after releasing it to keep one inode.
  static final _admitted = <String, String>{};

  /// Immediately throws [ManagedTranscriptBusyException] if already leased.
  /// A malformed UUID throws [ArgumentError]. Other I/O errors propagate.
  static ManagedTranscriptLease acquire(String sessionId) {
    _checkId(sessionId, 'sessionId');
    final key = sessionId.toLowerCase();
    if (_admitted.containsKey(key)) {
      throw ManagedTranscriptBusyException(sessionId);
    }
    final locksDir = _locksDir;
    _admitted[key] = locksDir;
    try {
      Directory(DataDirectory.current.path).createSync(recursive: true);
      for (final dir in [DataDirectory.current.stateDir, _root, _locksDir]) {
        _ensureDirectory(dir);
      }
      final path = p.join(_locksDir, '$key.lock');
      if (_type(path) == FileSystemEntityType.notFound) {
        try {
          File(path).createSync(exclusive: true);
        } on FileSystemException {
          // Another desktop may have created the lock file first.
          if (_type(path) != FileSystemEntityType.file) rethrow;
        }
      }
      if (_type(path) != FileSystemEntityType.file) {
        throw FileSystemException('Invalid managed transcript lock', path);
      }
      final release = Platform.isWindows
          ? _lockWindows(path, sessionId)
          : _PosixLock.acquire(path, sessionId);
      return ManagedTranscriptLease._(() {
        try {
          release();
        } finally {
          _admitted.remove(key);
        }
      });
    } catch (_) {
      _admitted.remove(key);
      rethrow;
    }
  }

  /// Identifies an ID previously admitted by the desktop, even if its
  /// project and transcript have since been removed.
  static bool isManagedSessionId(String sessionId) {
    if (!_isId(sessionId)) return false;
    try {
      return _markerLayoutSafe(_locksDir) &&
          _type(p.join(_locksDir, '${sessionId.toLowerCase()}.lock')) ==
              FileSystemEntityType.file;
    } on FileSystemException {
      return false;
    }
  }

  static String _forkMarker(String sessionId) =>
      p.join(_locksDir, '${sessionId.toLowerCase()}.forked');

  /// Records that this session may have copied originals. Call under its
  /// lease before making a fork. The marker remains even if the copy fails.
  static void markForked(String sessionId) {
    _checkId(sessionId, 'sessionId');
    if (_admitted[sessionId.toLowerCase()] != _locksDir) {
      throw StateError('Marking a managed fork requires the session lease');
    }
    _publishMarker(_forkMarker(sessionId));
  }

  // Encode uppercase hex explicitly so a case-insensitive host filesystem
  // still gives exact transcript IDs separate marker names.
  static String _markerId(String id) => id.replaceAllMapped(
    RegExp('[A-F]'),
    (match) => '_${match[0]!.toLowerCase()}',
  );

  static String _revocationsDir(String sessionId) =>
      p.join(_locksDir, '${_markerId(sessionId)}.revocations');

  static bool _markerLayoutSafe(String dir) => [
    DataDirectory.current.stateDir,
    _root,
    _locksDir,
    dir,
  ].every((path) => _suitable(path, FileSystemEntityType.directory, true));

  static void _publishRevocation(String sessionId, String messageId) {
    final dir = _revocationsDir(sessionId);
    if (!_markerLayoutSafe(dir)) {
      throw FileSystemException('Invalid managed revocation directory', dir);
    }
    _ensureDirectory(dir);
    _publishMarker(p.join(dir, _markerId(messageId)));
    if (!Platform.isWindows) {
      for (final path in [dir, _locksDir, _root]) {
        _PosixLock.flushDirectory(path);
      }
    }
  }

  static void _publishMarker(String path) {
    final type = _type(path);
    if (type != FileSystemEntityType.file) {
      if (type != FileSystemEntityType.notFound) {
        throw FileSystemException('Invalid managed fork marker', path);
      }
      File(path).createSync(exclusive: true);
    }
    final marker = File(path).openSync(mode: FileMode.append);
    try {
      marker.flushSync();
    } finally {
      marker.closeSync();
    }
  }

  /// Checks a read-only snapshot. A writer may still be active, so callers
  /// must arrange for it to close before requesting the edit.
  static bool canDeleteOriginal(
    String cwd,
    String sessionId,
    String messageId,
  ) => _editOriginal(cwd, sessionId, messageId, write: false);

  /// Rechecks the exact original and its artifacts under the writer's lease.
  /// Returns true only after replacing the transcript with its redacted form.
  static bool deleteOriginal(
    String cwd,
    String sessionId,
    String messageId, {
    void Function()? redactCopies,
  }) => _editOriginal(
    cwd,
    sessionId,
    messageId,
    write: true,
    redactCopies: redactCopies,
  );

  /// Reads the permanent revocation independently of the transcript path.
  /// An unreadable marker layout is treated as revoked to keep reads private.
  static bool isOriginalRevoked(String sessionId, String messageId) {
    if (!_isId(sessionId) || !_isId(messageId)) return false;
    try {
      final dir = _revocationsDir(sessionId);
      return !_markerLayoutSafe(dir) ||
          _type(p.join(dir, _markerId(messageId))) !=
              FileSystemEntityType.notFound;
    } on FileSystemException {
      return true;
    }
  }

  /// Recognizes permanent revocations and older exact transcript tombstones.
  /// A later partial append cannot hide a complete tombstone.
  static bool isOriginalDeleted(
    String cwd,
    String sessionId,
    String messageId,
  ) {
    if (!_isId(messageId)) return false;
    if (isOriginalRevoked(sessionId, messageId)) return true;
    try {
      final path = transcriptPath(cwd, sessionId);
      if (!_isOwnedFile(path)) return false;
      final normalized = p.normalize(cwd);
      return _scanLines(path, (line, complete) {
        if (!complete ||
            line == null ||
            !line.contains(messageId) ||
            !line.contains(deletedOriginalKey)) {
          return false;
        }
        final row = _decodeSnapshotRow(line);
        return row != null &&
            row['uuid'] == messageId &&
            _exactTombstone(line, row, normalized, sessionId);
      });
    } on FileSystemException {
      return false;
    } on ArgumentError {
      return false;
    }
  }

  /// Whether the current bytes are missing a required tombstone or still
  /// contain a revoked original. Hold the lease across this check and any
  /// subsequent resume or copy. An unreadable snapshot blocks the operation.
  static bool hasUnappliedRedactions(String cwd, String sessionId) {
    if (!_isId(sessionId)) return true;
    try {
      final dir = _revocationsDir(sessionId);
      if (!_markerLayoutSafe(dir)) return true;
      if (_type(dir) == FileSystemEntityType.notFound) return false;
      final expected = <String>{};
      for (final marker in Directory(dir).listSync(followLinks: false)) {
        if (marker is! File) return true;
        expected.add(p.basename(marker.path));
      }
      if (expected.isEmpty) return false;

      final path = transcriptPath(cwd, sessionId);
      if (!_isOwnedFile(path)) return true;
      final normalized = p.normalize(cwd);
      final verified = <String>{};
      final invalid = _scanLines(path, (line, complete) {
        if (line == null) return true;
        final row = _decodeSnapshotRow(line);
        final id = row?['uuid'];
        if (row == null || id is! String || !_isId(id)) return false;
        final marker = _markerId(id);
        if (!expected.contains(marker)) return false;
        return !complete ||
            !_exactTombstone(line, row, normalized, sessionId) ||
            !verified.add(marker);
      });
      return invalid || verified.length != expected.length;
    } on FileSystemException {
      return true;
    } on ArgumentError {
      return true;
    }
  }

  static Map<String, Object?>? _decodeSnapshotRow(String line) {
    try {
      return _decode(line);
    } on FormatException {
      return null;
    }
  }

  static bool _exactTombstone(
    String line,
    Map<String, Object?> row,
    String cwd,
    String sessionId,
  ) =>
      _origin(row, cwd, sessionId) &&
      _isTombstone(row) &&
      _canonical(line, row);

  static bool _editOriginal(
    String cwd,
    String sessionId,
    String messageId, {
    required bool write,
    void Function()? redactCopies,
  }) {
    if (!_isId(messageId)) return false;
    try {
      final path = transcriptPath(cwd, sessionId);
      if (!_isOwnedFile(path)) return false;
      final lease = write ? acquire(sessionId) : null;
      try {
        if (!_suitable(_locksDir, FileSystemEntityType.directory, true) ||
            _type(_forkMarker(sessionId)) != FileSystemEntityType.notFound) {
          return false;
        }
        final lines = _readLines(path);
        if (lines == null || _hasSidecars(path, sessionId)) return false;
        if (!_redact(lines, p.normalize(cwd), sessionId, messageId)) {
          return false;
        }
        if (write) {
          redactCopies?.call();
          // Publish intent before replacing the raw bytes. An interrupted
          // rewrite still revokes the source and blocks resume until retried.
          _publishRevocation(sessionId, messageId);
          _replace(path, lines);
        }
        return true;
      } finally {
        lease?.close();
      }
    } on ManagedTranscriptBusyException {
      return false;
    } on FileSystemException {
      return false;
    } on ArgumentError {
      return false;
    } on FormatException {
      return false;
    }
  }

  static bool _isOwnedFile(String path) =>
      _safeLayout(path, allowMissing: false);

  static bool _safeLayout(String path, {required bool allowMissing}) =>
      [..._projectAncestors, p.dirname(path)].every(
        (dir) => _suitable(dir, FileSystemEntityType.directory, allowMissing),
      ) &&
      _suitable(path, FileSystemEntityType.file, allowMissing);

  static bool _suitable(
    String path,
    FileSystemEntityType expected,
    bool allowMissing,
  ) {
    final type = _type(path);
    return type == expected ||
        (allowMissing && type == FileSystemEntityType.notFound);
  }

  static FileSystemEntityType _type(String path) =>
      FileSystemEntity.typeSync(path, followLinks: false);

  static void _ensureDirectory(String path) {
    if (_type(path) == FileSystemEntityType.notFound) {
      Directory(path).createSync();
    }
    if (_type(path) != FileSystemEntityType.directory) {
      throw FileSystemException('Invalid managed transcript directory', path);
    }
  }

  // All editing and validation here are synchronous. Bound both work and memory.
  static const _maxBytes = 8 * 1024 * 1024;

  // Reads the opened file's initial size in chunks. Oversized or invalid
  // UTF-8 rows reach the visitor as null. A trailing partial row is flagged.
  static bool _scanLines(
    String path,
    bool Function(String? line, bool complete) visit,
  ) {
    final file = File(path).openSync();
    try {
      final line = BytesBuilder(copy: false);
      var oversized = false;
      var remaining = file.lengthSync();
      const chunkSize = 64 * 1024;
      const maxLineBytes = _maxBytes + 256;
      String? takeLine() {
        if (oversized) return null;
        try {
          return utf8.decode(line.takeBytes());
        } on FormatException {
          return null;
        }
      }

      while (remaining > 0) {
        final chunk = file.readSync(
          remaining < chunkSize ? remaining : chunkSize,
        );
        if (chunk.isEmpty) {
          throw FileSystemException(
            'Managed transcript shrank while reading',
            path,
          );
        }
        remaining -= chunk.length;
        for (var start = 0; start < chunk.length;) {
          final newline = chunk.indexOf(0x0a, start);
          final end = newline < 0 ? chunk.length : newline;
          if (!oversized) {
            if (line.length + end - start > maxLineBytes) {
              oversized = true;
              line.clear();
            } else {
              line.add(Uint8List.sublistView(chunk, start, end));
            }
          }
          if (newline < 0) break;
          if (visit(takeLine(), true)) return true;
          oversized = false;
          start = newline + 1;
        }
      }
      return (oversized || line.isNotEmpty) && visit(takeLine(), false);
    } finally {
      file.closeSync();
    }
  }

  static List<String>? _readLines(String path) {
    if (!_isOwnedFile(path)) return null;
    final file = File(path).openSync();
    try {
      final bytes = file.readSync(_maxBytes + 1);
      if (bytes.length > _maxBytes) return null;
      final text = utf8.decode(bytes);
      if (!text.endsWith('\n')) return null;
      return text.split('\n');
    } finally {
      file.closeSync();
    }
  }

  static bool _hasSidecars(String path, String sessionId) {
    final lowerId = sessionId.toLowerCase();
    return Directory(p.dirname(path)).listSync(followLinks: false).any((entry) {
      if (entry.path == path) return false;
      final name = p.basename(entry.path).toLowerCase();
      return name == lowerId || name.startsWith('$lowerId.');
    });
  }

  static void _replace(String path, List<String> lines) {
    final temp = Directory(p.dirname(path)).createTempSync('.redact-');
    try {
      final output = File(p.join(temp.path, 'transcript'));
      output.writeAsStringSync(lines.join('\n'), flush: true);
      output.renameSync(path);
    } finally {
      try {
        temp.deleteSync(recursive: true);
      } on FileSystemException {
        // An empty temp directory after rename does not undo the edit.
      }
    }
  }

  static final _uuid = RegExp(
    r'^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$',
  );

  static bool _isId(Object? value) =>
      value is String && value.length == 36 && _uuid.hasMatch(value);

  static void _checkId(String value, String name) {
    if (!_isId(value)) throw ArgumentError.value(value, name, 'expected UUID');
  }

  static Map<String, Object?>? _decode(String line) {
    final row = jsonDecode(line);
    return row is Map<String, Object?> ? row : null;
  }

  // The engine writes jsonEncode(row). A round trip rules out duplicate keys
  // that the JSON decoder would silently discard and accept as a simpler row.
  static bool _canonical(String line, Map<String, Object?> row) =>
      jsonEncode(row) == line.trim();

  static const _identity = {
    'type',
    'uuid',
    'parentUuid',
    'sessionId',
    'timestamp',
    'cwd',
    'version',
    'isSidechain',
    'userType',
  };

  static bool _origin(Map<String, Object?> row, String cwd, String sessionId) =>
      (row['type'] == 'user' || row['type'] == 'assistant') &&
      _isId(row['uuid']) &&
      row.containsKey('parentUuid') &&
      (row['parentUuid'] == null || _isId(row['parentUuid'])) &&
      row['sessionId'] == sessionId &&
      row['cwd'] == cwd &&
      row['version'] == agentVersion &&
      row['isSidechain'] == false &&
      row['userType'] == 'external' &&
      row['timestamp'] is String &&
      DateTime.tryParse(row['timestamp']! as String) != null;

  // The engine drops assistant turns at the head of an API conversation.
  // A fixed replacement user turn keeps the first following answer in context.
  static const _deletedUserText = '[Original message deleted]';

  static bool _isTombstone(Map<String, Object?> row) =>
      row[deletedOriginalKey] == true &&
      row.keys.every(
        (key) =>
            _identity.contains(key) ||
            key == 'message' ||
            key == deletedOriginalKey,
      ) &&
      switch (row['message']) {
        final Map<String, Object?> body =>
          body.length == 2 &&
              body['role'] == row['type'] &&
              (row['type'] == 'user'
                  ? body['content'] == _deletedUserText
                  : body['content'] is List<Object?> &&
                        (body['content']! as List<Object?>).isEmpty),
        _ => false,
      };

  static Map<String, Object?> _tombstone(Map<String, Object?> row) => {
    for (final key in _identity) key: row[key],
    'message': {
      'role': row['type'],
      'content': row['type'] == 'user' ? _deletedUserText : <Object?>[],
    },
    deletedOriginalKey: true,
  };

  static const _messageKeys = {
    'role',
    'content',
    'id',
    'type',
    'model',
    'stop_reason',
    'stop_sequence',
    'usage',
  };

  static const _usageKeys = {
    'input_tokens',
    'output_tokens',
    'cache_read_input_tokens',
    'cache_creation_input_tokens',
    'ephemeral_5m_input_tokens',
    'ephemeral_1h_input_tokens',
  };

  static bool _validUsage(Object? value) =>
      value is Map<String, Object?> &&
      value.entries.every(
        (entry) => switch (entry.key) {
          'cache_creation' =>
            entry.value is Map<String, Object?> &&
                (entry.value! as Map<String, Object?>).entries.every(
                  (part) =>
                      (part.key == 'ephemeral_5m_input_tokens' ||
                          part.key == 'ephemeral_1h_input_tokens') &&
                      part.value is int,
                ),
          'service_tier' => const {
            'standard',
            'priority',
            'batch',
          }.contains(entry.value),
          'inference_geo' => const {
            'global',
            'us',
            'not_available',
          }.contains(entry.value),
          _ => _usageKeys.contains(entry.key) && entry.value is int,
        },
      );

  static List<String>? _text(Map<String, Object?> row) {
    if (!row.keys.every(
          (key) =>
              _identity.contains(key) ||
              key == 'message' ||
              key == 'gitBranch' ||
              key == 'requestId',
        ) ||
        (row['gitBranch'] != null && row['gitBranch'] is! String) ||
        (row['requestId'] != null && row['requestId'] is! String)) {
      return null;
    }
    final body = row['message'];
    if (body is! Map<String, Object?> || body['role'] != row['type']) {
      return null;
    }
    if (row['type'] == 'user') {
      if (body.length != 2 || row.containsKey('requestId')) return null;
    } else if (!body.keys.every(_messageKeys.contains) ||
        (body.containsKey('type') && body['type'] != 'message') ||
        (body['id'] != null && body['id'] is! String) ||
        (body['model'] != null && body['model'] is! String) ||
        body['model'] == '<synthetic>' ||
        (body['stop_reason'] != null && body['stop_reason'] != 'end_turn') ||
        body['stop_sequence'] != null ||
        (body.containsKey('usage') && !_validUsage(body['usage']))) {
      return null;
    }
    final text = <String>[];
    switch (body['content']) {
      case final String words:
        text.add(words);
      case final List<Object?> blocks:
        for (final block in blocks) {
          if (block is! Map<String, Object?> ||
              block.length != 2 ||
              block['type'] != 'text' ||
              block['text'] is! String) {
            return null;
          }
          text.add(block['text']! as String);
        }
      default:
        return null;
    }
    // Marked hook context, command output, or an interrupted turn can carry
    // material whose relation to an original isn't represented by its UUID.
    if (text.any(
      (part) =>
          part.trimLeft().startsWith('<') ||
          part.startsWith('[Request interrupted by user'),
    )) {
      return null;
    }
    return text;
  }

  static bool _redact(
    List<String> lines,
    String cwd,
    String sessionId,
    String messageId,
  ) {
    final rows =
        <({int index, Map<String, Object?> row, List<String> payload})>[];
    final titles = <({int index, String text, bool generated, int users})>[];
    final seen = <String>{};
    String? parent;
    var users = 0;
    var generatedTitle = false;
    for (final (index, line) in lines.indexed) {
      if (index == lines.length - 1 && line.isEmpty) break;
      final row = _decode(line);
      if (row == null || row['sessionId'] != sessionId) return false;
      if (row['type'] case 'custom-title' || 'ai-title') {
        final generated = row['type'] == 'ai-title';
        final text = row[generated ? 'aiTitle' : 'customTitle'];
        if (row.length != 3 ||
            text is! String ||
            (generated && (generatedTitle || users == 0)) ||
            !_canonical(line, row)) {
          return false;
        }
        generatedTitle |= generated;
        titles.add((
          index: index,
          text: text,
          generated: generated,
          users: users,
        ));
        continue;
      }
      if (!_origin(row, cwd, sessionId) || row['parentUuid'] != parent) {
        return false;
      }
      final id = row['uuid']! as String;
      if (!seen.add(id.toLowerCase())) return false;
      parent = id;
      if (row['type'] == 'user') users++;
      final payload = _isTombstone(row) ? const <String>[] : _text(row);
      if (payload == null || !_canonical(line, row)) return false;
      rows.add((index: index, row: row, payload: payload));
    }

    final target = rows
        .where((entry) => entry.row['uuid'] == messageId)
        .firstOrNull;
    if (target == null) return false;
    final copies = {
      for (final part in target.payload) part.trim(),
      target.payload.join().trim(),
      target.payload.join('\n').trim(),
    }..remove('');
    if (copies.isEmpty ||
        (target.row['type'] == 'user' && copies.contains(_deletedUserText))) {
      return false;
    }

    bool containsOriginal(String text) => copies.any(text.contains);
    for (final entry in rows) {
      final isTarget = entry.index == target.index;
      final body = entry.row['message']! as Map<String, Object?>;
      // Identity stays in the target's row. These are the free-form fields
      // that could carry a second copy in a different conversation row.
      if (!isTarget &&
          [
            ...entry.payload,
            entry.payload.join(),
            entry.payload.join('\n'),
            entry.row['gitBranch'],
            entry.row['requestId'],
            body['id'],
            body['model'],
          ].whereType<String>().any(containsOriginal)) {
        return false;
      }
    }

    final dropTitles = <int>{};
    for (final title in titles) {
      if (title.generated &&
          title.index > target.index &&
          target.row['type'] == 'user') {
        // The built-in engine derives its auto-title from the user prompt
        // (possibly a batch), and can do so again on a title-less resume. A
        // single preceding user or an exact copy establishes attribution.
        if (title.users == 1 || copies.contains(title.text.trim())) {
          dropTitles.add(title.index);
          continue;
        }
        return false;
      }
      if (containsOriginal(title.text)) return false;
    }

    final tombstone = jsonEncode(_tombstone(target.row));
    lines[target.index] = lines[target.index].endsWith('\r')
        ? '$tombstone\r'
        : tombstone;
    for (final index in dropTitles.toList().reversed) {
      lines.removeAt(index);
    }
    return true;
  }
}

final class ManagedTranscriptBusyException implements Exception {
  const ManagedTranscriptBusyException(this.sessionId);

  final String sessionId;

  @override
  String toString() => 'Managed transcript is in use: $sessionId';
}

final class ManagedTranscriptLease {
  ManagedTranscriptLease._(this._release);

  void Function()? _release;

  void close() {
    final release = _release;
    _release = null;
    release?.call();
  }
}

void Function() _lockWindows(String path, String sessionId) {
  final file = File(path).openSync(mode: FileMode.append);
  try {
    file.lockSync(FileLock.exclusive, 0, 1);
    return file.closeSync;
  } on FileSystemException catch (error) {
    file.closeSync();
    if (error.osError?.errorCode == 33) {
      throw ManagedTranscriptBusyException(sessionId);
    }
    rethrow;
  }
}

// RandomAccessFile locks on macOS/Linux are process-scoped. flock ties the
// lock to this handle, including when another Dart isolate opens the file.
abstract final class _PosixLock {
  static final _lib = DynamicLibrary.process();
  static final _open = _lib
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Int32),
        int Function(Pointer<Utf8>, int)
      >('open', isLeaf: true);
  static final _flock = _lib
      .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
        'flock',
        isLeaf: true,
      );
  static final _close = _lib
      .lookupFunction<Int32 Function(Int32), int Function(int)>(
        'close',
        isLeaf: true,
      );
  static final _errno = _lib
      .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
        Platform.isMacOS ? '__error' : '__errno_location',
        isLeaf: true,
      );

  static final _fsync = _lib
      .lookupFunction<Int32 Function(Int32), int Function(int)>('fsync');

  static void flushDirectory(String path) {
    final fd = _openPath(path, 0);
    try {
      if (_fsync(fd) != 0) {
        throw FileSystemException(
          'Cannot flush managed transcript directory',
          path,
          OSError('', _errno().value),
        );
      }
    } finally {
      _close(fd);
    }
  }

  static void Function() acquire(String path, String sessionId) {
    if (!Platform.isMacOS && !Platform.isLinux) {
      throw FileSystemException(
        'Managed transcript locking is unavailable',
        path,
      );
    }
    const readWrite = 2;
    final fd = _openPath(path, readWrite);
    const exclusiveNonblocking = 2 | 4;
    if (_flock(fd, exclusiveNonblocking) == 0) return () => _close(fd);
    final error = _errno().value;
    _close(fd);
    if (error == (Platform.isMacOS ? 35 : 11)) {
      throw ManagedTranscriptBusyException(sessionId);
    }
    throw FileSystemException(
      'Cannot lock managed transcript',
      path,
      OSError('', error),
    );
  }

  static int _openPath(String path, int mode) {
    final noFollow = Platform.isMacOS ? 0x100 : 0x20000;
    final closeOnExec = Platform.isMacOS ? 0x1000000 : 0x80000;
    final nativePath = path.toNativeUtf8();
    try {
      final fd = _open(nativePath, mode | noFollow | closeOnExec);
      if (fd >= 0) return fd;
      throw FileSystemException(
        'Cannot open managed transcript state',
        path,
        OSError('', _errno().value),
      );
    } finally {
      malloc.free(nativePath);
    }
  }
}
