import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bao_agent/bao_agent.dart' show AgentPaths, newUuid;
import 'package:baocode/kernel/claude_code/claude_code_transport.dart';
import 'package:baocode/kernel/claude_code/claude_core_setting.dart';
import 'package:baocode/kernel/claude_code/claude_storage_io.dart';
import 'package:baocode/kernel/claude_code/managed_transcripts_io.dart';
import 'package:baocode/platform/data_dir.dart';
import 'package:baocode/remote/remote_claude.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late String cwd;
  late String config;
  late ClaudeCatalog catalog;
  const env = {'ANTHROPIC_BASE_URL': 'https://model.invalid'};

  setUp(() {
    final original = DataDirectory.current;
    addTearDown(() => DataDirectory.current = original);
    root = Directory.systemTemp.createTempSync('baocode-managed-routing-');
    addTearDown(() => root.deleteSync(recursive: true));
    DataDirectory.current = DataDirectory(p.join(root.path, 'baocode'));
    cwd = (Directory(p.join(root.path, 'project'))..createSync()).path;
    config = p.join(root.path, 'claude');
    catalog = ClaudeCatalog(local: ClaudeStorage(configDir: config));
  });

  File transcript(String path, String id, String cwd, String text) => File(path)
    ..createSync(recursive: true)
    ..writeAsStringSync(
      [
        {
          'type': 'user',
          'uuid': newUuid(),
          'sessionId': id,
          'cwd': cwd,
          'message': {'role': 'user', 'content': text},
        },
        {
          'type': 'attachment',
          'sessionId': id,
          'attachment': {'type': 'goal_status', 'goal': text},
        },
      ].map((row) => '${jsonEncode(row)}\n').join(),
    );

  String sharedPath(String cwd, String id) =>
      p.join(config, 'projects', AgentPaths.projectDirName(cwd), '$id.jsonl');

  test(
    'holds the managed lease until runtime exit, including startup',
    () async {
      final entered = Completer<ClaudeLaunch>();
      final started = Completer<ClaudeCodeTransport>();
      final launching = startClaude(
        ClaudeLaunch(cwd: cwd, env: env, preferManagedTranscript: true),
        localCore: () => ClaudeCore.builtin,
        startBuiltin: (launch) {
          entered.complete(launch);
          return started.future;
        },
      );
      final launch = await entered.future;
      final managed = launch.managedTranscript!;
      expect(managed.projectsDir, ManagedTranscripts.projectsDir);
      expect(launch.resume, isNull);
      void busy() => expect(
        () => ManagedTranscripts.acquire(managed.sessionId),
        throwsA(isA<ManagedTranscriptBusyException>()),
      );
      busy();
      final runtime = _Transport();
      started.complete(runtime);
      final transport = await launching;
      transport.close();
      expect(runtime.closed, isTrue);
      busy();
      runtime.exit.complete();
      await transport.exited;
      ManagedTranscripts.acquire(managed.sessionId).close();
    },
  );

  test('a failed start releases the writer lease', () async {
    late String id;
    await expectLater(
      startClaude(
        ClaudeLaunch(cwd: cwd, env: env, preferManagedTranscript: true),
        localCore: () => ClaudeCore.builtin,
        startBuiltin: (launch) async {
          id = launch.managedTranscript!.sessionId;
          throw StateError('start failed');
        },
      ),
      throwsStateError,
    );
    ManagedTranscripts.acquire(id).close();
  });

  test('managed resumes force the built-in core and fail closed', () async {
    final id = newUuid();
    final path = ManagedTranscripts.transcriptPath(cwd, id);
    final source = transcript(path, id, cwd, 'managed');
    final runtime = _Transport();
    final launch = ClaudeLaunch(
      cwd: cwd,
      env: env,
      resume: id,
      resumePath: path,
    );
    Future<ClaudeCodeTransport> noCli(ClaudeLaunch _) async =>
        throw TestFailure('Managed transcript reached the CLI');
    final transport = await startClaude(
      launch,
      localCore: () => ClaudeCore.cli,
      startCli: noCli,
      startBuiltin: (launch) async {
        expect(launch.managedTranscript!.sessionId, id);
        expect(launch.resume, id);
        return runtime;
      },
    );
    transport.close();
    runtime.exit.complete();
    await transport.exited;
    source.deleteSync();
    await expectLater(
      startClaude(launch, localCore: () => ClaudeCore.cli, startCli: noCli),
      throwsA(isA<ClaudeUnavailable>()),
    );
    await expectLater(
      startClaude(
        ClaudeLaunch(
          cwd: cwd,
          env: env,
          resume: id,
          resumePath: path,
          agy: true,
        ),
        localCore: () => ClaudeCore.cli,
        startCli: noCli,
      ),
      throwsA(isA<ClaudeUnavailable>()),
    );
  });

  test(
    'a managed preference preserves CLI and shared resume routing',
    () async {
      final runtime = _Transport();
      Future<ClaudeCodeTransport> cli(ClaudeLaunch launch) async {
        expect(launch.managedTranscript, isNull);
        return runtime;
      }

      for (final resume in [null, newUuid()]) {
        final selected = await startClaude(
          ClaudeLaunch(
            cwd: cwd,
            resume: resume,
            env: env,
            preferManagedTranscript: true,
          ),
          localCore: () => ClaudeCore.cli,
          startCli: cli,
        );
        expect(selected, same(runtime));
      }
    },
  );

  test(
    'catalog discovers both stores and keeps the managed operations private',
    () async {
      final id = newUuid();
      final sibling = newUuid();
      final sharedId = newUuid();
      final managed = transcript(
        ManagedTranscripts.transcriptPath(cwd, id),
        id,
        cwd,
        'managed',
      );
      final shared = transcript(
        sharedPath(cwd, sharedId),
        sharedId,
        cwd,
        'shared',
      );
      final sessions = await catalog.sessionsIn(cwd);
      expect(
        {for (final session in sessions) session.id: session.path},
        {id: managed.path, sharedId: shared.path},
      );
      expect(
        (await catalog.local.goal(id, cwd: cwd)).single['attachment'],
        containsPair('goal', 'managed'),
      );

      final lease = ManagedTranscripts.acquire(id);
      await expectLater(
        catalog.local.fork(id, sibling, cwd: cwd),
        throwsA(isA<ManagedTranscriptBusyException>()),
      );
      final to = (Directory(p.join(root.path, 'moved'))..createSync()).path;
      await expectLater(
        catalog.moveSessions(cwd, to),
        throwsA(isA<ManagedTranscriptBusyException>()),
      );
      await expectLater(
        catalog.delete(id),
        throwsA(isA<ManagedTranscriptBusyException>()),
      );
      expect(shared.existsSync(), isTrue);
      lease.close();

      final fork = await catalog.local.fork(
        id,
        sibling,
        cwd: cwd,
        title: 'Fork',
      );
      expect(fork, ManagedTranscripts.transcriptPath(cwd, sibling));
      expect(File(sharedPath(cwd, sibling)).existsSync(), isFalse);
      expect(await catalog.moveSessions(cwd, to), 3);
      expect(managed.existsSync(), isFalse);
      expect(ManagedTranscripts.exists(to, id), isTrue);
      expect(ManagedTranscripts.exists(to, sibling), isTrue);
      expect(File(sharedPath(to, sharedId)).existsSync(), isTrue);
      await catalog.delete(id);
      expect(ManagedTranscripts.exists(to, id), isFalse);
      expect(ManagedTranscripts.exists(to, sibling), isTrue);
      expect(File(sharedPath(to, sharedId)).existsSync(), isTrue);
    },
  );
}

class _Transport implements ClaudeCodeTransport {
  final exit = Completer<void>();
  var closed = false;

  @override
  Stream<Map<String, Object?>> get messages => const Stream.empty();

  @override
  Future<void> get exited => exit.future;

  @override
  void close() => closed = true;

  @override
  void write(Map<String, Object?> message) {}
}
