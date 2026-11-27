import 'dart:io';

import 'package:path/path.dart' as p;

/// Where things are kept: Claude Code's own places, so that what one
/// writes the other reads (sessions, plans, settings, memory).
class AgentPaths {
  AgentPaths({
    required this.home,
    required this.configDir,
    this.transcriptProjectsDir,
    String? tempDir,
    this._uid,
  }) : tempDir =
           tempDir ?? (Platform.isWindows ? Directory.systemTemp.path : '/tmp');

  /// From [environment]: `CLAUDE_CONFIG_DIR` (or BaoCode's own variable for
  /// it), else `~/.claude`.
  factory AgentPaths.from(
    Map<String, String> environment, {
    String? configDir,
    String? transcriptProjectsDir,
    String? tempDir,
  }) {
    final home = homeOf(environment);
    final config =
        configDir ??
        [
          environment['BAOCODE_CLAUDE_DATA_PATH'],
          environment['CLAUDE_CONFIG_DIR'],
        ].whereType<String>().where((dir) => dir.isNotEmpty).firstOrNull ??
        p.join(home, '.claude');
    return AgentPaths(
      home: home,
      configDir: config,
      transcriptProjectsDir: transcriptProjectsDir,
      tempDir: tempDir,
    );
  }

  /// The user's home directory as [environment] says.
  static String homeOf(Map<String, String> environment) {
    for (final name
        in Platform.isWindows
            ? const ['USERPROFILE', 'HOME']
            : const ['HOME', 'USERPROFILE']) {
      if (environment[name] case final dir? when dir.isNotEmpty) return dir;
    }
    return Platform.environment['HOME'] ?? Directory.current.path;
  }

  final String home;

  /// `~/.claude`, unless moved.
  final String configDir;

  /// A host's separate root for persisted transcripts, when provided.
  final String? transcriptProjectsDir;

  /// Where tasks' output goes.
  final String tempDir;
  final String? _uid;

  /// `~/.claude.json`: the user's MCP servers and per-project state. Beside
  /// the config folder when that is moved.
  String get claudeJson => p.equals(configDir, p.join(home, '.claude'))
      ? p.join(home, '.claude.json')
      : p.join(configDir, '.claude.json');

  String get userSettings => p.join(configDir, 'settings.json');

  String get userMemory => p.join(configDir, 'CLAUDE.md');

  String get projectsDir => p.join(configDir, 'projects');

  String get pluginsDir => p.join(configDir, 'plugins');

  String get defaultPlansDir => p.join(configDir, 'plans');

  String fileHistoryDir(String sessionId) =>
      p.join(configDir, 'file-history', sessionId);

  /// The folder [cwd]'s sessions are kept in: its path with every character
  /// but letters and digits made a dash, as Claude Code names it.
  String projectDir(String cwd) => p.join(projectsDir, projectDirName(cwd));

  static String projectDirName(String cwd) {
    final dashed = cwd.replaceAll(RegExp('[^a-zA-Z0-9]'), '-');
    if (dashed.length <= 200) return dashed;
    // Long paths: cut, with a hash of the whole to tell them apart.
    var hash = 0;
    for (final unit in cwd.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return '${dashed.substring(0, 200)}-${hash.toRadixString(36)}';
  }

  String sessionFile(String cwd, String sessionId) => p.join(
    transcriptProjectsDir ?? projectsDir,
    projectDirName(cwd),
    _sessionFilename(sessionId),
  );

  /// Finds [sessionId]'s transcript, restricted to its project when [cwd]
  /// is given. A host's transcript root never falls back to config projects.
  String? findSession(String sessionId, {String? cwd}) {
    final managed = transcriptProjectsDir != null;
    final name = _sessionFilename(sessionId);
    final projects = Directory(transcriptProjectsDir ?? projectsDir);
    if (managed ? !_isDirectory(projects.path) : !projects.existsSync()) {
      return null;
    }
    final dirs = cwd == null
        ? projects.listSync(followLinks: !managed).whereType<Directory>()
        : [Directory(p.join(projects.path, projectDirName(cwd)))];
    for (final project in dirs) {
      final file = File(p.join(project.path, name));
      if (managed) {
        if (_isDirectory(project.path) &&
            FileSystemEntity.typeSync(file.path, followLinks: false) ==
                FileSystemEntityType.file) {
          return file.path;
        }
      } else if (file.existsSync()) {
        return file.path;
      }
    }
    return null;
  }

  static bool _isDirectory(String path) =>
      FileSystemEntity.typeSync(path, followLinks: false) ==
      FileSystemEntityType.directory;

  String _sessionFilename(String sessionId) {
    if (transcriptProjectsDir != null &&
        (sessionId.isEmpty ||
            sessionId == '.' ||
            sessionId == '..' ||
            sessionId.contains(RegExp(r'[/\\:\x00]')))) {
      throw ArgumentError.value(sessionId, 'sessionId', 'Invalid session ID');
    }
    return '$sessionId.jsonl';
  }

  /// Where the tasks of [sessionId], run in [cwd], write what they print.
  String tasksDir(String cwd, String sessionId) => p.join(
    tempDir,
    Platform.isWindows ? 'claude' : 'claude-${uid()}',
    projectDirName(cwd),
    sessionId,
    'tasks',
  );

  String? _resolvedUid;

  /// The user's numeric id, as the task folders are named.
  String uid() {
    if (_uid != null) return _uid;
    if (_resolvedUid != null) return _resolvedUid!;
    try {
      final result = Process.runSync('id', ['-u']);
      _resolvedUid = '${result.stdout}'.trim();
    } on Object {
      _resolvedUid = '';
    }
    if (_resolvedUid!.isEmpty) _resolvedUid = '0';
    return _resolvedUid!;
  }

  /// Where the organisation's settings and memory are, if it set any.
  static String get managedDir {
    if (Platform.isMacOS) return '/Library/Application Support/ClaudeCode';
    if (Platform.isWindows) return r'C:\Program Files\ClaudeCode';
    return '/etc/claude-code';
  }

  /// `~` spelled out.
  String expandHome(String path) {
    if (path == '~') return home;
    if (path.startsWith('~/') || path.startsWith(r'~\')) {
      return p.join(home, path.substring(2));
    }
    return path;
  }
}
