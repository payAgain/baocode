import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

Future<T> runHistoryIndexBuild<T>(T Function() build) => Isolate.run(build);

/// Versioned index shards are disposable and only accelerate source reads.
final class MemoryHistoryStore {
  MemoryHistoryStore(this.path);

  final String? path;
  static int _writes = 0;

  bool get enabled => path != null;

  File _file(String key) => File(p.join(path!, '$key.json'));

  Future<String?> read(String key) async {
    if (!enabled) return null;
    try {
      return await _file(key).readAsString();
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<void> write(String key, String data) async {
    if (!enabled) return;
    final file = _file(key);
    final temp = File('${file.path}.$pid.${_writes++}.tmp');
    try {
      await file.parent.create(recursive: true);
      await temp.writeAsString(data, flush: true);
      await temp.rename(file.path);
    } on FileSystemException {
      // A missing cache is rebuilt from the source.
    } finally {
      try {
        await temp.delete();
      } on FileSystemException {
        // Renaming normally removed it.
      }
    }
  }

  Future<void> remove(String key) => _removeMatching(key, bot: false);

  Future<void> removeBot(String key) => _removeMatching(key, bot: true);

  Future<void> _removeMatching(String key, {required bool bot}) async {
    if (!enabled) return;
    final dir = Directory(path!);
    if (!await dir.exists()) return;
    final prefix = '$key${bot ? '-' : '.json'}';
    try {
      await for (final entry in dir.list(followLinks: false)) {
        if (p.basename(entry.path).startsWith(prefix)) await entry.delete();
      }
    } on PathNotFoundException {
      // An index file may already have been removed.
    }
  }
}
