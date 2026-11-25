import 'dart:io';

import 'package:bao_agent/bao_agent.dart' show AgentPaths;
import 'package:bao_remote/local.dart';
import 'package:path/path.dart' as p;

import '../../platform/data_dir.dart';
import '../antigravity/agy_transport_io.dart';
import '../agent_kernel.dart';
import 'managed_transcripts_io.dart';

/// Claude Code's own record of its sessions on this machine (see
/// [ClaudeSessions]).
class ClaudeStorage implements SessionCatalog, MovesSessions {
  const ClaudeStorage({this.configDir, this.tempDir, this.cacheFile});

  /// Where Claude Code keeps its state; by default `BAOCODE_CLAUDE_DATA_PATH`
  /// as the login shell has it, else `CLAUDE_CONFIG_DIR`, else
  /// `<home>/.claude`.
  final String? configDir;

  /// Where it keeps what a session's tasks print (`claude-<uid>/`); the
  /// system's temporary folder by default.
  final String? tempDir;

  /// Where what was made of each session file is kept between runs; in the
  /// app's cache folder by default.
  final String? cacheFile;

  ClaudeSessions get _sessions => ClaudeSessions(
    configDir: configDir,
    tempDir: tempDir,
    cacheFile:
        cacheFile ??
        p.join(DataDirectory.current.cacheDir, 'claude-sessions.json'),
  );

  /// Recognizes catalog provenance even if the managed file is now missing.
  static bool isManagedPath(String path) => p.isWithin(
    p.normalize(p.absolute(ManagedTranscripts.projectsDir)),
    p.normalize(p.absolute(path)),
  );

  static String? _managedPath(String cwd, String id) {
    if (ManagedTranscripts.exists(cwd, id)) {
      return ManagedTranscripts.transcriptPath(cwd, id);
    }
    return null;
  }

  @override
  Future<void> delete(String id) async {
    final managed = _managedFiles(id);
    if (managed.isNotEmpty) {
      final lease = ManagedTranscripts.acquire(id);
      try {
        final current = _managedFiles(id);
        if (current.length != 1 ||
            !p.equals(current.single.path, managed.single.path)) {
          throw StateError('The managed transcript location changed');
        }
        current.single.deleteSync();
      } finally {
        lease.close();
      }
      return;
    }
    if (ManagedTranscripts.isManagedSessionId(id)) return;
    // What Antigravity kept of it, if it ran there: its process ended,
    // its files gone with the conversation's.
    try {
      await AgyTransport.forget(
        id,
        configDir ?? await ClaudeEnvironment.configDir(),
      );
    } on Object {
      // The conversation goes all the same.
    }
    await _sessions.delete(id);
  }

  static Iterable<Directory> _managedProjects() {
    if (!ManagedTranscripts.isManagedRootSafe) return const [];
    final root = Directory(ManagedTranscripts.projectsDir);
    if (!root.existsSync()) return const [];
    return root.listSync(followLinks: false).whereType<Directory>();
  }

  static List<File> _managedFiles(String id) {
    if (!ManagedTranscripts.isManagedPathSafe('/', id)) return const [];
    return [
      for (final project in _managedProjects())
        if (FileSystemEntity.typeSync(
              p.join(project.path, '$id.jsonl'),
              followLinks: false,
            ) ==
            FileSystemEntityType.file)
          File(p.join(project.path, '$id.jsonl')),
    ];
  }

  @override
  Future<int> moveSessions(String from, String to) async {
    if (p.equals(from, to)) return 0;
    final project = p.join(
      ManagedTranscripts.projectsDir,
      AgentPaths.projectDirName(p.normalize(from)),
    );
    final leases = <ManagedTranscriptLease>[];
    final moves = <(String, String)>[];
    try {
      for (final source in _managedProjects().where(
        (d) => p.equals(d.path, project),
      )) {
        for (final file
            in source.listSync(followLinks: false).whereType<File>()) {
          if (p.extension(file.path) != '.jsonl') continue;
          final id = p.basenameWithoutExtension(file.path);
          if (!ManagedTranscripts.exists(from, id) ||
              !p.equals(await ClaudeSessions.cwdAt(file.path) ?? '', from)) {
            continue;
          }
          leases.add(ManagedTranscripts.acquire(id));
          final target = ManagedTranscripts.transcriptPath(to, id);
          if (!ManagedTranscripts.exists(from, id) ||
              !ManagedTranscripts.isManagedPathSafe(to, id) ||
              (!p.equals(file.path, target) &&
                  ManagedTranscripts.exists(to, id))) {
            throw StateError('The managed transcript cannot be relocated');
          }
          moves.add((file.path, target));
        }
      }
      for (final (source, target) in moves) {
        await ClaudeSessions.moveAt(source, target, from, to);
      }
      return moves.length + await _sessions.move(from, to);
    } finally {
      for (final lease in leases.reversed) {
        lease.close();
      }
    }
  }

  @override
  Future<List<ProjectRecord>> projects() async {
    final byCwd = <String, List<SessionRecord>>{};
    if (ManagedTranscripts.isManagedRootSafe &&
        Directory(ManagedTranscripts.projectsDir).existsSync()) {
      for (final project in await _sessions.projectsAt(
        ManagedTranscripts.projectsDir,
      )) {
        final sessions = projectRecord(project).sessions.where((session) {
          final path = _managedPath(session.cwd, session.id);
          return path != null &&
              p.equals(path, session.path!) &&
              !ManagedTranscripts.hasUnappliedRedactions(
                session.cwd,
                session.id,
              );
        });
        if (sessions.isNotEmpty) (byCwd[project.path] ??= []).addAll(sessions);
      }
    }
    for (final project in await _sessions.projects()) {
      final sessions = byCwd[project.path] ??= [];
      final managedIds = {for (final session in sessions) session.id};
      sessions.addAll(
        projectRecord(project).sessions.where(
          (session) =>
              !managedIds.contains(session.id) &&
              !ManagedTranscripts.isManagedSessionId(session.id) &&
              !isManagedPath(session.path!),
        ),
      );
    }
    return [
      for (final MapEntry(key: cwd, value: sessions) in byCwd.entries)
        if (sessions.isNotEmpty)
          ProjectRecord(
            path: cwd,
            sessions: sessions
              ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)),
          ),
    ]..sort((a, b) => b.updatedAt!.compareTo(a.updatedAt!));
  }

  @override
  Future<List<SessionRecord>> sessionsIn(String cwd) async {
    final all = await projects();
    return all.where((p) => p.path == cwd).firstOrNull?.sessions ?? const [];
  }

  /// What the session [id] kept of its goal (see [ClaudeSessions.goal]).
  Future<List<Map<String, Object?>>> goal(String id, {String? cwd}) async {
    final path = _managedSource(id, cwd);
    if (path == null) {
      return ManagedTranscripts.isManagedSessionId(id)
          ? const []
          : _sessions.goal(id);
    }
    final recordedCwd = cwd ?? await ClaudeSessions.cwdAt(path);
    if (recordedCwd == null ||
        ManagedTranscripts.hasUnappliedRedactions(recordedCwd, id)) {
      return const [];
    }
    return ClaudeSessions.goalAt(path);
  }

  static String? _managedSource(String id, String? cwd) {
    if (cwd != null) return _managedPath(cwd, id);
    final managed = _managedFiles(id);
    if (managed.length > 1) {
      throw StateError('More than one managed transcript has session ID $id');
    }
    return managed.singleOrNull?.path;
  }

  /// Copies the session [id] into a new one, [into], in its original store.
  Future<String> fork(
    String id,
    String into, {
    String? cwd,
    String? before,
    String? title,
  }) async {
    final source = _managedSource(id, cwd);
    if (source == null) {
      if (ManagedTranscripts.isManagedSessionId(id)) {
        throw StateError('The managed transcript is unavailable');
      }
      return _sessions.fork(id, into, before: before, title: title);
    }
    final lease = ManagedTranscripts.acquire(id);
    try {
      final destination = ManagedTranscripts.acquire(into);
      try {
        final recordedCwd = cwd ?? await ClaudeSessions.cwdAt(source);
        if (recordedCwd == null ||
            _managedSource(id, recordedCwd) != source ||
            ManagedTranscripts.hasUnappliedRedactions(recordedCwd, id)) {
          throw StateError('The managed transcript is unavailable');
        }
        final target = p.join(p.dirname(source), '$into.jsonl');
        if (_managedFiles(into).isNotEmpty ||
            FileSystemEntity.typeSync(target, followLinks: false) !=
                FileSystemEntityType.notFound) {
          throw StateError('The managed fork destination is occupied');
        }
        // A copy can retain historical messages under another session ID.
        // Fence single-original deletion for both histories before copying.
        ManagedTranscripts.markForked(id);
        ManagedTranscripts.markForked(into);
        return await ClaudeSessions.forkAt(
          source,
          target,
          into,
          before: before,
          title: title,
        );
      } finally {
        destination.close();
      }
    } finally {
      lease.close();
    }
  }

  /// The session's conversation along the branch it ended on.
  static Future<List<Map<String, Object?>>> read(SessionRecord session) {
    final path = session.path;
    if (path == null || !_readablePath(session, path)) {
      return Future.value(const []);
    }
    return ClaudeSessions.read(path);
  }

  /// Some of it (see [ClaudeSessions.readPage]).
  static Future<ClaudeHistoryPage> readPage(
    SessionRecord session, {
    required int turns,
    String? before,
  }) {
    final path = session.path;
    if (path == null || !_readablePath(session, path)) {
      return Future.value(const ClaudeHistoryPage([]));
    }
    return ClaudeSessions.readPage(path, turns: turns, before: before);
  }

  static bool _readablePath(SessionRecord session, String path) {
    if (!isManagedPath(path)) {
      return !ManagedTranscripts.isManagedSessionId(session.id);
    }
    return p.equals(_managedPath(session.cwd, session.id) ?? '', path) &&
        !ManagedTranscripts.hasUnappliedRedactions(session.cwd, session.id);
  }

  /// [project] as the kernels list it, its folder and sessions' given by
  /// [location] (on another machine, see host.dart).
  static ProjectRecord projectRecord(
    ClaudeProjectSummary project, {
    String Function(String path)? location,
  }) => ProjectRecord(
    path: location?.call(project.path) ?? project.path,
    sessions: [
      for (final session in project.sessions)
        SessionRecord(
          id: session.id,
          title: session.title,
          updatedAt: session.updatedAt,
          cwd: location?.call(session.cwd) ?? session.cwd,
          path: session.path,
        ),
    ],
  );
}
