import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'bot_folders_stub.dart'
    if (dart.library.io) 'bot_folders_io.dart'
    as platform;

/// Where the bots' folders are, each a bot's files (see bot_files.dart).
/// Replaceable under test.
abstract interface class BotFolders {
  /// The data folder's `bots/` (none on the web).
  factory BotFolders.data() = platform.DataBotFolders;

  /// The folder holding the bots' own, and the user's profile; null where
  /// there is none.
  String? get root;

  /// The folders in [root], each a bot's if it has a card.
  List<String> folders();

  void make(String folder);
  void delete(String folder);

  /// The files right in [folder]; none when there is no such folder.
  List<String> filesIn(String folder);

  /// The file at [path], or null when it does not exist. Strict reads
  /// propagate other filesystem errors.
  Uint8List? readFile(String path, {bool strict = false});

  /// [bytes] at [path], over what is there.
  void writeFile(String path, Uint8List bytes);

  /// Replaces a file in one step; throws if the new contents could not be kept.
  void writeFileAtomically(String path, Uint8List bytes);
  void deleteFile(String path);
}

/// Kept only while it lives, under test.
class MemoryBotFolders implements BotFolders {
  MemoryBotFolders([this.root = '/bots']);

  @override
  final String? root;

  final Set<String> made = {};
  final Map<String, Uint8List> files = {};

  @override
  List<String> folders() => [
    for (final folder in made)
      if (p.dirname(folder) == root) folder,
  ]..sort();

  @override
  void make(String folder) => made.add(folder);

  @override
  void delete(String folder) {
    made.remove(folder);
    files.removeWhere((path, _) => p.isWithin(folder, path));
  }

  @override
  List<String> filesIn(String folder) => [
    for (final path in files.keys)
      if (p.dirname(path) == folder) path,
  ]..sort();

  @override
  Uint8List? readFile(String path, {bool strict = false}) => files[path];

  @override
  void writeFile(String path, Uint8List bytes) {
    made.add(p.dirname(path));
    files[path] = bytes;
  }

  @override
  void writeFileAtomically(String path, Uint8List bytes) =>
      writeFile(path, bytes);

  @override
  void deleteFile(String path) => files.remove(path);
}
