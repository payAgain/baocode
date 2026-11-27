import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:bao_agent/bao_agent.dart';
import 'package:baocode/kernel/claude_code/managed_transcripts_io.dart';
import 'package:baocode/platform/data_dir.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _session = 'dcaab80f-725a-4219-9ae1-56033d166455';
const _other = '09a3cbd1-830b-43c0-ab81-60a20abe19b8';
const _first = 'd4b3c471-e776-4121-8d38-b1bd0e3dde01';
const _reply = '0b3a0082-5b40-4c44-ae35-82e641f7c9f1';
const _last = 'dbbb78e0-bb15-4bb1-b542-61d43af0308b';
const _secret = 'Private value "red pill"\nsecond line';

void main() {
  late DataDirectory saved;
  late Directory data;
  late String cwd;
  late File transcript;
  late SessionStore store;

  Map<String, Object?> user(String words, {String id = _first}) =>
      store.append({
        'type': 'user',
        'uuid': id,
        'message': {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': words},
          ],
        },
      });

  Map<String, Object?> assistant(String words) => store.append({
    'type': 'assistant',
    'uuid': _reply,
    'requestId': 'req_synthetic',
    'message': {
      'type': 'message',
      'role': 'assistant',
      'id': 'msg_synthetic',
      'model': 'synthetic-model',
      'stop_reason': null,
      'stop_sequence': null,
      'usage': {
        'input_tokens': 2,
        'output_tokens': 2,
        'cache_creation': {'ephemeral_5m_input_tokens': 0},
        'service_tier': 'standard',
      },
      'content': [
        {'type': 'text', 'text': words},
      ],
    },
  });

  setUp(() {
    saved = DataDirectory.current;
    data = Directory.systemTemp.createTempSync('managed-transcripts-test-');
    DataDirectory.current = DataDirectory(p.join(data.path, 'app-data'));
    cwd = p.join(data.path, 'project-name');
    transcript = File(ManagedTranscripts.transcriptPath(cwd, _session));
    store = SessionStore(
      sessionId: _session,
      cwd: cwd,
      file: transcript.path,
      gitBranch: 'example-main',
    );
  });

  tearDown(() {
    DataDirectory.current = saved;
    data.deleteSync(recursive: true);
  });

  test('uses the host state and the built-in project path convention', () {
    expect(
      ManagedTranscripts.projectsDir,
      p.join(DataDirectory.current.stateDir, 'managed-transcripts', 'projects'),
    );
    expect(
      ManagedTranscripts.transcriptPath(p.join(cwd, 'child', '..'), _session),
      p.join(
        ManagedTranscripts.projectsDir,
        AgentPaths.projectDirName(cwd),
        '$_session.jsonl',
      ),
    );
    final long = p.join(cwd, 'a' * 210);
    expect(
      ManagedTranscripts.transcriptPath(long, _session),
      p.join(
        ManagedTranscripts.projectsDir,
        AgentPaths.projectDirName(long),
        '$_session.jsonl',
      ),
    );
    expect(ManagedTranscripts.isManagedPathSafe(cwd, _session), isTrue);
    expect(ManagedTranscripts.exists(cwd, _session), isFalse);
    for (final bad in [
      '../escape',
      'not-a-uuid',
      '$_session\n',
      '$_session/',
    ]) {
      expect(() => ManagedTranscripts.acquire(bad), throwsArgumentError);
      expect(
        () => ManagedTranscripts.transcriptPath(cwd, bad),
        throwsArgumentError,
      );
      expect(ManagedTranscripts.exists(cwd, bad), isFalse);
      expect(ManagedTranscripts.isManagedPathSafe(cwd, bad), isFalse);
    }
  });

  test('leases fence this isolate and other isolates until close', () async {
    user(_secret);
    final lease = ManagedTranscripts.acquire(_session);
    addTearDown(lease.close);
    expect(
      () => ManagedTranscripts.acquire(_session.toUpperCase()),
      throwsA(isA<ManagedTranscriptBusyException>()),
    );
    final otherLease = ManagedTranscripts.acquire(_other);
    otherLease.close();
    expect(ManagedTranscripts.canDeleteOriginal(cwd, _session, _first), isTrue);
    expect(ManagedTranscripts.deleteOriginal(cwd, _session, _first), isFalse);
    expect(transcript.readAsStringSync(), contains('red pill'));

    final root = DataDirectory.current.path;
    expect(await Isolate.run(() => _tryLease(root)), isFalse);
    lease.close();
    lease.close();
    expect(await Isolate.run(() => _tryLease(root)), isTrue);
    expect(ManagedTranscripts.canDeleteOriginal(cwd, _session, _first), isTrue);
  });

  test('leases fence a separate desktop process', () async {
    final dart = _dartSdk();
    if (dart == null) {
      markTestSkipped(
        'The runner has no Dart executable beside its Flutter SDK',
      );
      return;
    }
    final worker = File(p.join(data.path, 'try_lease.dart'))
      ..writeAsStringSync('''
import 'dart:io';
import 'package:baocode/kernel/claude_code/managed_transcripts_io.dart';
import 'package:baocode/platform/data_dir.dart';
void main(List<String> args) {
  DataDirectory.current = DataDirectory(args.single);
  try {
    ManagedTranscripts.acquire('$_session').close();
  } on ManagedTranscriptBusyException {
    exitCode = 3;
  }
}
''');
    Future<ProcessResult> tryLease() => Process.run(dart, [
      '--packages=${p.absolute('.dart_tool', 'package_config.json')}',
      worker.path,
      DataDirectory.current.path,
    ]);
    final lease = ManagedTranscripts.acquire(_session);
    try {
      final busy = await tryLease();
      expect(busy.exitCode, 3, reason: '${busy.stderr}');
    } finally {
      lease.close();
    }
    final free = await tryLease();
    expect(free.exitCode, 0, reason: '${free.stderr}');
  });

  test('the fork marker fences original edits after the lease closes', () {
    user(_secret);
    final before = transcript.readAsStringSync();
    expect(ManagedTranscripts.canDeleteOriginal(cwd, _session, _first), isTrue);
    expect(
      Directory(p.join(p.dirname(ManagedTranscripts.projectsDir), 'locks'))
          .existsSync(),
      isFalse,
    );
    expect(() => ManagedTranscripts.markForked(_session), throwsStateError);
    final lease = ManagedTranscripts.acquire(_session);
    try {
      ManagedTranscripts.markForked(_session);
      ManagedTranscripts.markForked(_session);
    } finally {
      lease.close();
    }
    expect(
      ManagedTranscripts.canDeleteOriginal(cwd, _session, _first),
      isFalse,
    );
    expect(ManagedTranscripts.deleteOriginal(cwd, _session, _first), isFalse);
    expect(transcript.readAsStringSync(), before);
  });

  test('removes an original and its exact generated title from disk', () {
    final original = user(_secret);
    store.note({'type': 'ai-title', 'aiTitle': _secret});
    assistant('Independent reply');
    user('Unrelated later turn', id: _last);
    final before = transcript.readAsLinesSync();

    expect(ManagedTranscripts.exists(cwd, _session), isTrue);
    expect(ManagedTranscripts.canDeleteOriginal(cwd, _session, _first), isTrue);
    expect(transcript.readAsLinesSync(), before);
    expect(ManagedTranscripts.deleteOriginal(cwd, _session, _first), isTrue);
    final after = transcript.readAsLinesSync();
    expect(after.skip(1), before.skip(2));
    expect(transcript.readAsStringSync(), isNot(contains('red pill')));
    final deleted = jsonDecode(after.first) as Map<String, Object?>;
    for (final key in ['uuid', 'parentUuid', 'sessionId', 'timestamp', 'cwd']) {
      expect(deleted[key], original[key], reason: key);
    }
    expect(deleted['type'], 'user');
    expect(deleted[ManagedTranscripts.deletedOriginalKey], isTrue);
    expect(deleted['message'], {
      'role': 'user',
      'content': '[Original message deleted]',
    });
    expect(ManagedTranscripts.isOriginalDeleted(cwd, _session, _first), isTrue);
    expect(
      ManagedTranscripts.canDeleteOriginal(cwd, _session, _first),
      isFalse,
    );
    expect(ManagedTranscripts.deleteOriginal(cwd, _session, _first), isFalse);
    expect(transcript.readAsLinesSync(), after);

    final resumed = SessionStore.resume(
      sessionId: _session,
      cwd: cwd,
      file: transcript.path,
    );
    expect(resumed.chain.map((row) => row['uuid']), [_first, _reply, _last]);
    expect(jsonEncode(resumed.apiMessages()), isNot(contains('red pill')));
    expect(resumed.apiMessages().map((message) => message['role']), [
      'user',
      'assistant',
      'user',
    ]);
  });

  test('removes a generated title attributable to its only preceding user', () {
    user(_secret);
    store.note({'type': 'ai-title', 'aiTitle': 'A derived title'});
    store.note({'type': 'custom-title', 'customTitle': 'An independent title'});
    assistant('Independent reply');
    expect(ManagedTranscripts.deleteOriginal(cwd, _session, _first), isTrue);
    final text = transcript.readAsStringSync();
    expect(text, isNot(contains('derived title')));
    expect(text, contains('An independent title'));
  });

  test('deletes by the exact assistant UUID and retains adjacent turns', () {
    user('A first prompt');
    final original = assistant(_secret);
    user('Unrelated later turn', id: _last);
    final before = transcript.readAsLinesSync();
    expect(ManagedTranscripts.deleteOriginal(cwd, _session, _reply), isTrue);
    final after = transcript.readAsLinesSync();
    expect(after.first, before.first);
    expect(after.last, before.last);
    final deleted = jsonDecode(after[1]) as Map<String, Object?>;
    expect(deleted['uuid'], _reply);
    expect(deleted['parentUuid'], _first);
    expect(deleted['timestamp'], original['timestamp']);
    expect(deleted['message'], {'role': 'assistant', 'content': []});
    expect(deleted.containsKey('requestId'), isFalse);
    expect(transcript.readAsStringSync(), isNot(contains('red pill')));
  });

  test(
    'reports a tombstone even with a subsequently appended unsupported turn',
    () {
      user(_secret);
      expect(ManagedTranscripts.deleteOriginal(cwd, _session, _first), isTrue);
      final lease = ManagedTranscripts.acquire(_session);
      try {
        store.append({
          'type': 'attachment',
          'attachment': {'type': 'unrelated'},
        });
        expect(
          ManagedTranscripts.isOriginalDeleted(cwd, _session, _first),
          isTrue,
        );
        expect(
          ManagedTranscripts.isOriginalDeleted(cwd, _session, _last),
          isFalse,
        );
      } finally {
        lease.close();
      }
    },
  );

  test('revocation survives transcript removal, restore, and relocation', () {
    final original = user(_secret);
    assistant('Independent reply');
    final backup = transcript.readAsStringSync();
    expect(ManagedTranscripts.isManagedSessionId(_session), isFalse);
    expect(ManagedTranscripts.isOriginalRevoked(_session, _first), isFalse);
    expect(ManagedTranscripts.deleteOriginal(cwd, _session, _first), isTrue);

    final erased = transcript.readAsStringSync();
    expect(ManagedTranscripts.isManagedSessionId(_session), isTrue);
    expect(ManagedTranscripts.isOriginalRevoked(_session, _first), isTrue);
    expect(
      ManagedTranscripts.isOriginalRevoked(_session, _first.toUpperCase()),
      isFalse,
    );
    expect(ManagedTranscripts.hasUnappliedRedactions(cwd, _session), isFalse);
    transcript.deleteSync();
    expect(ManagedTranscripts.isManagedSessionId(_session), isTrue);
    expect(ManagedTranscripts.isOriginalDeleted(cwd, _session, _first), isTrue);
    expect(
      ManagedTranscripts.isOriginalDeleted(cwd, _session, _reply),
      isFalse,
    );
    expect(ManagedTranscripts.hasUnappliedRedactions(cwd, _session), isTrue);

    transcript.writeAsStringSync(backup);
    expect(ManagedTranscripts.isOriginalDeleted(cwd, _session, _first), isTrue);
    expect(ManagedTranscripts.hasUnappliedRedactions(cwd, _session), isTrue);
    expect(ManagedTranscripts.deleteOriginal(cwd, _session, _first), isTrue);
    expect(ManagedTranscripts.hasUnappliedRedactions(cwd, _session), isFalse);
    transcript.writeAsStringSync(jsonEncode(original), mode: FileMode.append);
    expect(ManagedTranscripts.hasUnappliedRedactions(cwd, _session), isTrue);

    final moved = p.join(data.path, 'moved');
    final movedPath = File(ManagedTranscripts.transcriptPath(moved, _session));
    movedPath.parent.createSync(recursive: true);
    movedPath.writeAsStringSync(
      erased.replaceAll(jsonEncode(cwd), jsonEncode(moved)),
    );
    transcript.deleteSync();
    expect(
      ManagedTranscripts.isOriginalDeleted(moved, _session, _first),
      isTrue,
    );
    expect(
      ManagedTranscripts.isOriginalDeleted(moved, _session, _reply),
      isFalse,
    );
    expect(ManagedTranscripts.hasUnappliedRedactions(moved, _session), isFalse);
  });

  test('legacy tombstones survive a large transcript and a partial append', () {
    user('x' * (64 * 1024 - 380));
    assistant(_secret);
    expect(ManagedTranscripts.deleteOriginal(cwd, _session, _reply), isTrue);
    // Model a transcript redacted before revocations were persisted separately.
    final revocations = Directory(
      p.join(
        p.dirname(ManagedTranscripts.projectsDir),
        'locks',
        '$_session.revocations',
      ),
    );
    revocations.deleteSync(recursive: true);
    expect(ManagedTranscripts.isOriginalRevoked(_session, _reply), isFalse);

    final added =
        '${jsonEncode({'type': 'attachment', 'text': 'y' * (1024 * 1024)})}\n';
    for (var row = 0; row < 9; row++) {
      transcript.writeAsStringSync(added, mode: FileMode.append);
    }
    expect(ManagedTranscripts.isOriginalDeleted(cwd, _session, _reply), isTrue);
    transcript.writeAsStringSync('{"uuid":"$_reply",', mode: FileMode.append);
    expect(ManagedTranscripts.isOriginalDeleted(cwd, _session, _reply), isTrue);
    expect(
      ManagedTranscripts.isOriginalDeleted(cwd, _session, _first),
      isFalse,
    );
  });

  test('rejects ambiguous copies, branches, and unsupported artifact shapes', () {
    final original = user(_secret);
    final unrelated = assistant('Independent reply');
    final originalLine = jsonEncode(original);
    final prohibited = <String, String>{
      'unknown row': jsonEncode({'type': 'unknown', 'sessionId': _session}),
      'matching custom title': jsonEncode({
        'type': 'custom-title',
        'sessionId': _session,
        'customTitle': _secret,
      }),
      'second user with copied text': jsonEncode({
        ...original,
        'uuid': _last,
        'parentUuid': _reply,
        'message': {'role': 'user', 'content': 'Unexpected quote $_secret'},
      }),
      'branched turn': jsonEncode({
        ...unrelated,
        'uuid': _last,
        'parentUuid': _first,
      }),
      'duplicate UUID': jsonEncode(unrelated),
      'unknown message payload': jsonEncode({
        ...unrelated,
        'uuid': _last,
        'parentUuid': _reply,
        'message': {
          'role': 'assistant',
          'content': 'Extra',
          'unknown': _secret,
        },
      }),
      'sidechain': jsonEncode({
        ...unrelated,
        'uuid': _last,
        'parentUuid': _reply,
        'isSidechain': true,
      }),
      'tool turn': jsonEncode({
        ...unrelated,
        'uuid': _last,
        'parentUuid': _reply,
        'message': {
          'role': 'assistant',
          'content': [
            {'type': 'tool_use', 'input': _secret},
          ],
        },
      }),
      'attachment row': jsonEncode({...unrelated, 'type': 'attachment'}),
      'compaction row': jsonEncode({
        ...unrelated,
        'type': 'system',
        'subtype': 'compact_boundary',
      }),
      'rewrite row': jsonEncode({...unrelated, 'type': 'content-replacement'}),
      'duplicate key':
          '{"type":"rewrite",${jsonEncode({...original, 'uuid': _last, 'parentUuid': _reply}).substring(1)}',
      'malformed JSON': '{',
    };
    for (final entry in prohibited.entries) {
      final contents =
          '$originalLine\n${jsonEncode(unrelated)}\n${entry.value}\n';
      transcript.writeAsStringSync(contents);
      expect(
        ManagedTranscripts.canDeleteOriginal(cwd, _session, _first),
        isFalse,
        reason: entry.key,
      );
      expect(
        ManagedTranscripts.deleteOriginal(cwd, _session, _first),
        isFalse,
        reason: entry.key,
      );
      expect(transcript.readAsStringSync(), contents, reason: entry.key);
    }
  });

  test(
    'rejects a non-text original, an alias cwd, or a per-session sidecar',
    () {
      final original = user(_secret);
      final attached = {
        ...original,
        'message': {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': _secret},
            {
              'type': 'image',
              'source': {'type': 'base64', 'data': 'example'},
            },
          ],
        },
      };
      transcript.writeAsStringSync('${jsonEncode(attached)}\n');
      expect(ManagedTranscripts.deleteOriginal(cwd, _session, _first), isFalse);
      transcript.writeAsStringSync('${jsonEncode(original)}\n');
      expect(
        ManagedTranscripts.deleteOriginal(cwd, _session, _first.toUpperCase()),
        isFalse,
      );
      final alias = p.join(data.path, 'project', 'name');
      expect(
        ManagedTranscripts.transcriptPath(alias, _session),
        transcript.path,
      );
      expect(
        ManagedTranscripts.deleteOriginal(alias, _session, _first),
        isFalse,
      );
      Directory(p.join(transcript.parent.path, _session)).createSync();
      expect(ManagedTranscripts.deleteOriginal(cwd, _session, _first), isFalse);
      expect(transcript.readAsStringSync(), contains('red pill'));
    },
  );

  test('does not follow a redirected project or transcript', () {
    if (Platform.isWindows) {
      markTestSkipped('Creating links on Windows can require elevation');
      return;
    }
    final original = user(_secret);
    final outside = Directory(p.join(data.path, 'outside'))..createSync();
    final target = transcript.renameSync(
      p.join(outside.path, p.basename(transcript.path)),
    );
    transcript.parent.deleteSync();
    final link = Link(transcript.parent.path)..createSync(outside.path);
    expect(ManagedTranscripts.exists(cwd, _session), isFalse);
    expect(ManagedTranscripts.isManagedPathSafe(cwd, _session), isFalse);
    expect(ManagedTranscripts.deleteOriginal(cwd, _session, _first), isFalse);
    link.deleteSync();
    transcript.parent.createSync();
    Link(transcript.path).createSync(target.path);
    expect(ManagedTranscripts.exists(cwd, _session), isFalse);
    expect(ManagedTranscripts.isManagedPathSafe(cwd, _session), isFalse);
    expect(ManagedTranscripts.deleteOriginal(cwd, _session, _first), isFalse);
    expect(target.readAsStringSync(), '${jsonEncode(original)}\n');
  });
}

bool _tryLease(String root) {
  DataDirectory.current = DataDirectory(root);
  try {
    ManagedTranscripts.acquire(_session).close();
    return true;
  } on ManagedTranscriptBusyException {
    return false;
  }
}

String? _dartSdk() {
  final dart = Platform.isWindows ? 'dart.exe' : 'dart';
  var directory = p.dirname(Platform.resolvedExecutable);
  while (true) {
    final path = p.join(directory, 'dart-sdk', 'bin', dart);
    if (File(path).existsSync()) return path;
    final parent = p.dirname(directory);
    if (parent == directory) return null;
    directory = parent;
  }
}
