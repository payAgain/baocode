import 'dart:io';
import 'dart:typed_data';

import '../platform/data_dir.dart';
import 'bot_folders.dart';

class DataBotFolders implements BotFolders {
  @override
  String? get root => DataDirectory.current.botsDir;

  @override
  List<String> folders() {
    final root = this.root;
    if (root == null) return const [];
    try {
      return [
        for (final entry in Directory(root).listSync())
          if (entry is Directory) entry.path,
      ]..sort();
    } on FileSystemException {
      return const [];
    }
  }

  @override
  void make(String folder) {
    try {
      Directory(folder).createSync(recursive: true);
    } on FileSystemException {
      // Its agent says so, when it cannot start there.
    }
  }

  @override
  void delete(String folder) {
    try {
      Directory(folder).deleteSync(recursive: true);
    } on FileSystemException {
      // Gone already.
    }
  }

  @override
  List<String> filesIn(String folder) {
    try {
      return [
        for (final entry in Directory(folder).listSync())
          if (entry is File) entry.path,
      ]..sort();
    } on FileSystemException {
      return const [];
    }
  }

  @override
  Uint8List? readFile(String path, {bool strict = false}) {
    try {
      return File(path).readAsBytesSync();
    } on PathNotFoundException {
      return null;
    } on FileSystemException {
      if (strict) rethrow;
      return null;
    }
  }

  @override
  void writeFile(String path, Uint8List bytes) {
    try {
      final file = File(path);
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(bytes, flush: true);
    } on FileSystemException {
      // Left as it was.
    }
  }

  static int _writes = 0;

  @override
  void writeFileAtomically(String path, Uint8List bytes) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    final temp = File('$path.$pid.${_writes++}.tmp');
    try {
      temp.writeAsBytesSync(bytes, flush: true);
      temp.renameSync(path);
    } finally {
      try {
        if (temp.existsSync()) temp.deleteSync();
      } on FileSystemException {
        // Keep the original write error if cleanup failed too.
      }
    }
  }

  @override
  void deleteFile(String path) {
    try {
      File(path).deleteSync();
    } on FileSystemException {
      // Gone already.
    }
  }
}
