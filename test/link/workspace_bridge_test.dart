import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bao_link/bao_link.dart';
import 'package:bao_remote/claude.dart' show ClaudeHistoryPage;
import 'package:baocode/chat/chat_session.dart' show ComposerMessage, UserPlace;
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/reply_suggestions.dart';
import 'package:baocode/bots/bot_folders.dart';
import 'package:baocode/bots/bot_groups.dart';
import 'package:baocode/bots/bot_memory.dart';
import 'package:baocode/bots/bot_memory_review.dart';
import 'package:baocode/bots/bot_memory_skill.dart';
import 'package:baocode/bots/bots.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/models/codex/codex_service.dart';
import 'package:baocode/models/model_providers.dart';
import 'package:baocode/link/chat_codec.dart';
import 'package:baocode/link/desktop_remote_git_client.dart';
import 'package:baocode/link/link_quota.dart';
import 'package:baocode/link/link_platform_io.dart';
import 'package:baocode/link/workspace_bridge.dart';
import 'package:baocode/platform/data_dir.dart';
import 'package:baocode/workspace/preference_store.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../kernel_test.dart' show FakeCli;

/// A conversation of six turns (a prompt and an answer each), read three
/// at a time from its end: u4..u6, then u1..u3.
void main() {
  Map<String, Object?> prompt(String id) => {
    'type': 'user',
    'uuid': id,
    'message': {'role': 'user', 'content': id},
  };

  Map<String, Object?> answer(String id) => {
    'type': 'assistant',
    'uuid': 'a-$id',
    'message': {
      'id': 'm-$id',
      'role': 'assistant',
      'model': 'claude-opus-5-5',
      'content': [
        {'type': 'text', 'text': 'answer $id'},
      ],
    },
  };

  ClaudeHistoryPage page(List<String> ids, {String? earlier}) =>
      ClaudeHistoryPage([
        for (final id in ids) ...[prompt(id), answer(id)],
      ], earlier: earlier);

  final asked = <String?>[];

  late Workspace workspace;
  late FakeCli cli;
  Completer<void>? startGate;
  late WorkspaceBridge bridge;
  late LinkPeer phone;
  late String id;
  final updates = <LinkSessionUpdate>[];

  setUp(() async {
    asked.clear();
    updates.clear();
    startGate = null;
    late final KernelDescriptor descriptor;
    descriptor = KernelDescriptor(
      id: 'claude-code',
      label: 'Claude Code',
      icon: Icons.auto_awesome_rounded,
      description: '',
      catalog: _KeptCatalog(),
      create: (context) => ClaudeCodeKernel(
        descriptor,
        KernelContext(
          cwd: '/p',
          resume: SessionRecord(
            id: 's',
            title: 't',
            updatedAt: DateTime(2026),
            cwd: '/p',
          ),
        ),
        start: (_) async {
          if (startGate case final gate?) await gate.future;
          return cli = FakeCli();
        },
        readHistoryPage: (session, {required turns, before}) async {
          asked.add(before);
          return switch (before) {
            null => page(['u4', 'u5', 'u6'], earlier: 'u4'),
            'u4' => page(['u1', 'u2', 'u3']),
            _ => page(const []),
          };
        },
      ),
    );
    workspace = Workspace(
      projects: const [Project('p', '/p')],
      kernels: [descriptor],
    );
    final thread = workspace.startAgent(workspace.projects.first);
    thread.session.attach();
    await pumpEventQueue();
    id = WorkspaceBridge.idOf(thread);

    final LinkPeer desktop;
    (phone, desktop) = await peers();
    bridge = WorkspaceBridge(
      workspace: workspace,
      peer: desktop,
      device: () => const DeviceInfo(name: 'Mac', kind: 'mac', system: 'macOS'),
      quota: LinkQuota(
        providers: ModelProviders.memory(),
        codex: CodexUnavailable(),
      ),
      throttle: const Duration(milliseconds: 10),
    )..start();
    desktop.onRequest = bridge.handle;
    addTearDown(phone.close);
    final sub = phone.events
        .where((e) => e.name == LinkEvents.session)
        .listen(
          (e) => updates.add(
            LinkSessionUpdate.fromJson(e.data! as Map<String, Object?>),
          ),
        );
    addTearDown(sub.cancel);
  });

  tearDown(() {
    bridge.dispose();
    workspace.dispose();
  });

  Future<LinkSessionUpdate> open([int? window]) async =>
      LinkSessionUpdate.fromJson(
        (await bridge.handle(LinkMethods.open, {
              'session': id,
              'window': ?window,
            }))!
            as Map<String, Object?>,
      );

  List<String> texts(List<Object?> items) => [
    for (final json in items)
      switch (ChatCodec.decode(json)) {
        UserMessageItem(:final text) => text,
        _ => '-',
      },
  ];

  Future<void> settle() async {
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await pumpEventQueue();
  }

  group('remote local branch switching', () {
    late Directory folder;
    late String root;
    late Workspace gitWorkspace;
    late WorkspaceBridge gitBridge;
    late LinkPeer client;
    late IoLinkPlatform platform;
    late bool permitsGit;

    String git(List<String> args) {
      final result = Process.runSync('git', args, workingDirectory: root);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      return (result.stdout as String).trim();
    }

    Future<Map<String, Object?>> branches() async =>
        (await client.call(LinkMethods.projectBranches, {'project': root}))
            as Map<String, Object?>;

    Future<Object?> change(String target, Map<String, Object?> baseline) =>
        client.call(LinkMethods.switchProjectBranch, {
          'project': root,
          'branch': target,
          'expectedHead': baseline['head'],
          'expectedBranch': baseline['branch'],
        });

    Matcher rejected(String code) => throwsA(
      isA<LinkRemoteException>().having((error) => error.code, 'code', code),
    );

    setUp(() async {
      folder = Directory.systemTemp.createTempSync('paired-branch-');
      addTearDown(() => folder.deleteSync(recursive: true));
      final repo = Directory('${folder.path}/repo')..createSync();
      root = repo.resolveSymbolicLinksSync();
      git(['init', '-q', '-b', 'main']);
      git(['config', 'user.name', 'Branch test']);
      git(['config', 'user.email', 'branch-test@example.invalid']);
      git(['config', 'commit.gpgsign', 'false']);
      git(['config', 'core.autocrlf', 'false']);
      File('$root/file').writeAsStringSync('main\n');
      git(['add', 'file']);
      git(['commit', '-qm', 'main']);
      git(['switch', '-qc', 'feature/topic']);
      File('$root/file').writeAsStringSync('feature\n');
      git(['commit', '-qam', 'feature']);
      git(['switch', '-q', 'main']);
      git(['tag', 'feature/topic']);
      git(['tag', 'tag-only']);
      git(['update-ref', 'refs/remotes/origin/remote-only', 'HEAD']);
      platform = IoLinkPlatform();
      permitsGit = true;
      gitWorkspace = Workspace(
        projects: [Project('repo', root)],
        kernels: workspace.kernels,
      );
      addTearDown(gitWorkspace.dispose);
      final LinkPeer host;
      (client, host) = await peers();
      addTearDown(host.close);
      addTearDown(client.close);
      gitBridge = WorkspaceBridge(
        workspace: gitWorkspace,
        peer: host,
        device: () =>
            const DeviceInfo(name: 'Mac', kind: 'mac', system: 'macOS'),
        branchOf: (project) => platform.branchOf(project.root),
        permitsProjectGit: () => permitsGit,
        onBranchChanged: (project) =>
            platform.branchOf(project.root, refresh: true),
      )..start();
      host.onRequest = gitBridge.handle;
      addTearDown(gitBridge.dispose);
    });

    test('marks Git history truncated only when a commit is omitted', () async {
      final api = DesktopRemoteGitClient(client);
      final initial = git(['rev-parse', 'HEAD']);
      git(['commit', '--allow-empty', '--allow-empty-message', '-qm', '']);
      final head = git(['rev-parse', 'HEAD']);

      final exact = (await api.history(root, limit: 2))!;
      expect(exact.truncated, isFalse);
      expect(exact.commits.map((commit) => commit.hash), [head, initial]);
      expect(exact.commits.last.parentIds, isEmpty);

      final bounded = (await api.history(root, limit: 1))!;
      expect(bounded.truncated, isTrue);
      expect(bounded.commits.single.hash, head);
      expect(bounded.commits.single.subject, isEmpty);
    });

    test('reads project Git status, bounded history and patches', () async {
      final api = DesktopRemoteGitClient(client);
      final initial = git(['rev-parse', 'HEAD']);
      File('$root/file').writeAsStringSync('committed\n');
      git(['commit', '-qam', 'second']);
      final head = git(['rev-parse', 'HEAD']);
      File('$root/file').writeAsStringSync('staged\n');
      git(['add', 'file']);
      File('$root/file').writeAsStringSync('working\n');
      File('$root/untracked [x]').writeAsStringSync('new file\n');
      final indexBefore = File('$root/.git/index').readAsBytesSync();

      final status = (await api.status(root))!;
      expect(status.branch, 'main');
      expect(status.head, head);
      expect(status.truncated, isFalse);
      expect(
        [for (final file in status.files) (file.path, file.status, file.group)],
        [
          ('file', 'M', 'index'),
          ('file', 'M', 'workingTree'),
          ('untracked [x]', 'U', 'untracked'),
        ],
      );
      final history = (await api.history(root, limit: 1))!;
      expect(history.truncated, isTrue);
      expect(history.commits.single.hash, head);
      expect(history.commits.single.parentIds, [initial]);
      expect(history.commits.single.subject, 'second');
      expect(history.commits.single.refs, contains('HEAD -> refs/heads/main'));
      expect((await api.history(root))!.commits.length, 2);

      final files = (await api.commitFiles(root, head))!;
      expect(files.files.single.path, 'file');
      expect(files.files.single.status, 'M');
      expect(
        (await api.commitDiff(root, head, 'file'))!.text,
        contains('+committed'),
      );
      expect(
        (await api.commitDiff(root, initial, 'file'))!.text,
        contains('+main'),
      );
      expect(
        (await api.workingDiff(root, 'file', staged: true))!.text,
        contains('+staged'),
      );
      expect((await api.workingDiff(root, 'file'))!.text, contains('+working'));
      expect(
        (await api.workingDiff(root, 'untracked [x]'))!.text,
        contains('+new file'),
      );
      expect(File('$root/.git/index').readAsBytesSync(), indexBefore);
      expect(File('$root/file').readAsStringSync(), 'working\n');
    });

    test(
      'scopes project Git requests and rejects path and revision syntax',
      () async {
        final api = DesktopRemoteGitClient(client);
        final head = git(['rev-parse', 'HEAD']);
        final otherBranch = git(['rev-parse', 'refs/heads/feature/topic']);
        await expectLater(
          api.status(folder.path),
          rejected(LinkErrors.notFound),
        );
        await expectLater(
          api.commitFiles(root, otherBranch),
          rejected(LinkErrors.notFound),
        );
        for (final revision in [
          'HEAD',
          '--all',
          '$head^',
          head.substring(0, 7),
        ]) {
          await expectLater(api.commitFiles(root, revision), rejected('bad'));
        }
        for (final path in [
          '../file',
          '/file',
          'C:/file',
          r'dir\file',
          ':(glob)*',
          '.git/config',
          'dir//file',
          'file\n',
        ]) {
          await expectLater(api.commitDiff(root, head, path), rejected('bad'));
        }
        await expectLater(
          api.commitDiff(root, head, 'f*'),
          rejected(LinkErrors.notFound),
        );
        final inFlight = api.status(root);
        await Future<void>.delayed(Duration.zero);
        permitsGit = false;
        expect(await inFlight, isNull);
        expect(await api.status(root), isNull);
      },
    );

    test(
      'filters and pages local branch Git history and scopes its details',
      () async {
        final api = DesktopRemoteGitClient(client);
        final tip = git(['rev-parse', 'refs/heads/feature/topic']);
        final base = git(['rev-parse', 'HEAD']);
        expect((await api.capabilities(root))!.branches, [
          'feature/topic',
          'main',
        ]);
        final first = (await api.history(
          root,
          limit: 1,
          branch: 'feature/topic',
          path: 'file',
        ))!;
        expect(first.commits.single.hash, tip);
        expect(first.nextOffset, 1);
        final second = (await api.history(
          root,
          limit: 1,
          offset: first.nextOffset!,
          branch: 'feature/topic',
          path: 'file',
        ))!;
        expect(second.commits.single.hash, base);
        expect(second.nextOffset, isNull);
        final filtered = (await api.history(
          root,
          branch: 'feature/topic',
          author: 'branch test',
          search: 'FEATURE',
          since: DateTime.utc(2000),
          until: DateTime.utc(2099),
        ))!;
        expect(filtered.commits.single.hash, tip);
        expect((await api.history(root, search: '.*'))!.commits, isEmpty);
        expect(
          (await api.history(root, since: DateTime.utc(2099)))!.commits,
          isEmpty,
        );
        expect((await api.history(root, path: 'f*'))!.commits, isEmpty);
        await expectLater(
          api.history(root, branch: 'tag-only'),
          rejected(LinkErrors.notFound),
        );
        await expectLater(api.history(root, offset: -1), rejected('bad'));
        await expectLater(
          api.commitFiles(root, tip),
          rejected(LinkErrors.notFound),
        );
        expect(
          (await api.commitFiles(
            root,
            tip,
            branch: 'feature/topic',
          ))!.files.single.path,
          'file',
        );
        expect(
          (await api.commitDiff(
            root,
            tip,
            'file',
            branch: 'feature/topic',
          ))!.text,
          contains('+feature'),
        );
      },
    );

    test('stages and unstages Git rows and rejects stale content and unauthorized writes', () async {
      final api = DesktopRemoteGitClient(client);
      final file = File('$root/file')..writeAsStringSync('one\n');
      final old = (await api.status(root))!;
      file.writeAsStringSync('two\n');
      await expectLater(
        api.stage(root, old.files, expectedState: old.state!),
        rejected('stale'),
      );
      final fresh = (await api.status(root))!;
      await expectLater(
        api.stage(root, [
          const RemoteGitFile(
            path: '../file',
            status: 'M',
            group: 'workingTree',
          ),
        ], expectedState: fresh.state!),
        rejected('bad'),
      );
      permitsGit = false;
      expect(
        await api.stage(root, fresh.files, expectedState: fresh.state!),
        isNull,
      );
      permitsGit = true;
      final staged = (await api.stage(
        root,
        fresh.files,
        expectedState: fresh.state!,
      ))!;
      expect(staged.files.single.group, 'index');
      expect(git(['show', ':file']), 'two');
      final unstaged = (await api.unstage(
        root,
        staged.files,
        expectedState: staged.state!,
      ))!;
      expect(unstaged.files.single.group, 'workingTree');
      expect(git(['show', ':file']), 'main');
    });

    test('browses and changes Git stashes by stable ID', () async {
      final api = DesktopRemoteGitClient(client);
      final file = File('$root/file')..writeAsStringSync('first change\n');
      final added = File('$root/new file')..writeAsStringSync('untracked\n');
      final before = (await api.status(root))!;
      final clean = (await api.createStash(
        root,
        expectedState: before.state!,
        message: 'first',
        includeUntracked: true,
      ))!;
      expect(clean.files, isEmpty);
      expect(added.existsSync(), isFalse);
      final first = (await api.stashes(root))!.entries.single;
      expect(first.message, contains('first'));
      expect(
        (await api.stashFiles(root, first.id))!.files.map((file) => file.path),
        ['file', 'new file'],
      );
      expect(
        (await api.stashDiff(root, first.id, 'new file'))!.text,
        contains('+untracked'),
      );
      file.writeAsStringSync('second change\n');
      final second = (await api.status(root))!;
      final cleanAgain = (await api.createStash(
        root,
        expectedState: second.state!,
        message: 'second',
      ))!;
      final entries = (await api.stashes(root))!.entries;
      expect(entries.last.id, first.id);
      await expectLater(
        api.dropStash(root, first.id, expectedState: clean.state!),
        rejected('stale'),
      );
      final applied = (await api.applyStash(
        root,
        first.id,
        expectedState: cleanAgain.state!,
      ))!;
      expect(applied.files.length, 2);
      expect((await api.stashes(root))!.entries.length, 2);
      git(['restore', 'file']);
      added.deleteSync();
      final reset = (await api.status(root))!;
      final popped = (await api.popStash(
        root,
        first.id,
        expectedState: reset.state!,
      ))!;
      expect(file.readAsStringSync(), 'first change\n');
      expect((await api.stashes(root))!.entries.single.id, entries.first.id);
      await api.dropStash(root, entries.first.id, expectedState: popped.state!);
      expect((await api.stashes(root))!.entries, isEmpty);
      await expectLater(
        api.stashFiles(root, first.id),
        rejected(LinkErrors.notFound),
      );
    });

    test('commits selected Git working paths, preserves unrelated stage, and reports push failure separately', () async {
      final api = DesktopRemoteGitClient(client);
      final bare = '${folder.path}/remote.git';
      git(['init', '--bare', '--quiet', bare]);
      git(['remote', 'add', 'origin', bare]);
      git(['push', '-qu', 'origin', 'main']);
      expect((await api.capabilities(root))!.canPush, isTrue);
      final receiverMarker = File('$bare/receiver-marker');
      if (!Platform.isWindows) {
        final receiver = File('$bare/hooks/pre-receive')
          ..writeAsStringSync(
            '#!/bin/sh\ntouch "${receiverMarker.path}"\nexit 1\n',
          );
        expect(Process.runSync('chmod', ['+x', receiver.path]).exitCode, 0);
      }
      File('$root/other').writeAsStringSync('unrelated stage\n');
      File('$root/file').writeAsStringSync('staged\n');
      git(['add', 'file', 'other']);
      File('$root/file').writeAsStringSync('working\n');
      File('$root/-added').writeAsStringSync('new path\n');
      final status = (await api.status(root))!;
      final result = (await api.commit(
        root,
        expectedState: status.state!,
        message: 'selected',
        push: true,
        files: status.files.where((file) => file.path != 'other').toList(),
      ))!;
      expect(result.pushed, isTrue, reason: result.pushError);
      expect(receiverMarker.existsSync(), isFalse);
      expect(
        git(['--git-dir=$bare', 'rev-parse', 'refs/heads/main']),
        result.head,
      );
      expect(git(['show', 'HEAD:file']), 'working');
      expect(git(['show', 'HEAD:-added']), 'new path');
      expect(git(['diff', '--cached', '--name-only']), 'other');

      git(['mv', '--', 'file', '-moved']);
      final rename = (await api.status(root))!;
      final renameCommit = (await api.commit(
        root,
        expectedState: rename.state!,
        message: 'renamed',
        files: [rename.files.singleWhere((file) => file.path == '-moved')],
      ))!;
      expect(git(['show', '${renameCommit.head}:-moved']), 'working');
      expect(git(['ls-tree', '--name-only', 'HEAD']), '-added\n-moved');

      // Move the receiver back along a divergent path without running its
      // hooks. Push remains available, but a non-fast-forward must fail.
      if (!Platform.isWindows) File('$bare/hooks/pre-receive').deleteSync();
      git([
        'push',
        '-q',
        'origin',
        'refs/heads/feature/topic:refs/heads/diverged',
      ]);
      git([
        '--git-dir=$bare',
        'update-ref',
        'refs/heads/main',
        'refs/heads/diverged',
      ]);
      final remoteHead = git([
        '--git-dir=$bare',
        'rev-parse',
        'refs/heads/main',
      ]);
      final remaining = (await api.status(root))!;
      final local = (await api.commit(
        root,
        expectedState: remaining.state!,
        message: 'local only',
        files: remaining.files,
        push: true,
      ))!;
      expect(local.pushed, isFalse);
      expect(local.pushError, isNotNull);
      expect(git(['rev-parse', 'HEAD']), local.head);
      expect(
        git(['--git-dir=$bare', 'rev-parse', 'refs/heads/main']),
        remoteHead,
      );

      File('$root/other').writeAsStringSync('next change\n');
      final next = (await api.status(root))!;
      git(['config', 'remote.origin.pushurl', 'ext::disabled']);
      expect((await api.capabilities(root))!.canPush, isFalse);
      await expectLater(
        api.commit(
          root,
          expectedState: next.state!,
          message: 'stale upstream',
          files: next.files,
          push: true,
        ),
        rejected('stale'),
      );
    });

    test('serializes Git writes and suppresses repository hooks', () async {
      final api = DesktopRemoteGitClient(client);
      File('$root/file').writeAsStringSync('updated\n');
      final hookMarker = File('$root/.git/baocode-hook-marker');
      final hookDir = Directory('$root/.git/host-hooks')..createSync();
      if (!Platform.isWindows) {
        final hook = File(
          '${hookDir.path}/pre-commit',
        )..writeAsStringSync('#!/bin/sh\ntouch "${hookMarker.path}"\nexit 1\n');
        expect(Process.runSync('chmod', ['+x', hook.path]).exitCode, 0);
      }
      git(['config', 'core.hooksPath', hookDir.path]);
      final status = (await api.status(root))!;
      Future<Object?> stage() async {
        try {
          return await api.stage(
            root,
            status.files,
            expectedState: status.state!,
          );
        } on LinkRemoteException catch (error) {
          return error.code;
        }
      }

      final results = await Future.wait([stage(), stage()]);
      expect(results.whereType<RemoteGitStatus>(), hasLength(1));
      expect(
        results.whereType<String>().single,
        anyOf(LinkErrors.busy, 'stale'),
      );
      final staged = (await api.status(root))!;
      final commit = await api.commit(
        root,
        expectedState: staged.state!,
        message: 'safe',
        files: staged.files,
      );
      expect(commit, isNotNull);
      expect(hookMarker.existsSync(), isFalse);
      git(['config', 'filter.external.clean', 'false']);
      expect((await api.capabilities(root))!.canWrite, isFalse);
      File('$root/file').writeAsStringSync('another update\n');
      final changed = (await api.status(root))!;
      await expectLater(
        api.stage(root, changed.files, expectedState: changed.state!),
        rejected(LinkErrors.gitRejected),
      );
    });

    test('caps large patches and retains a truncated marker', () async {
      final api = DesktopRemoteGitClient(client);
      File('$root/file').writeAsStringSync('long line of patch text\n' * 32000);
      final patch = (await api.workingDiff(root, 'file'))!;
      expect(patch.truncated, isTrue);
      expect(utf8.encode(patch.text).length, lessThanOrEqualTo(256 * 1024));
      expect(patch.text, contains('+long line of patch text'));
    });

    test('preserves rename paths in staged and committed diffs', () async {
      final api = DesktopRemoteGitClient(client);
      git(['mv', '--', 'file', '-file']);
      final staged = (await api.status(root))!.files.single;
      expect(
        (staged.path, staged.originalPath, staged.status),
        ('-file', 'file', 'R'),
      );
      expect(
        (await api.workingDiff(root, '-file', staged: true))!.text,
        contains('rename to -file'),
      );
      git(['commit', '-qm', 'rename']);
      final head = git(['rev-parse', 'HEAD']);
      final committed = (await api.commitFiles(root, head))!.files.single;
      expect(
        (committed.path, committed.originalPath, committed.status),
        ('-file', 'file', 'R'),
      );
      expect(
        (await api.commitDiff(root, head, '-file'))!.text,
        contains('rename to -file'),
      );
    });

    test(
      'suppresses configured worktree filters and external diff drivers',
      () async {
        final api = DesktopRemoteGitClient(client);
        File('$root/.gitattributes')
            .writeAsStringSync('file filter=probe diff=probe\n');
        git(['config', 'filter.probe.clean', 'echo filtered']);
        git(['config', 'filter.probe.process', 'echo filtered']);
        git(['config', 'filter.probe.required', 'true']);
        git(['config', 'diff.probe.command', 'echo external-diff']);
        git(['config', 'diff.probe.textconv', 'echo external-textconv']);
        File('$root/file').writeAsStringSync('actual working content\n');
        final patch = (await api.workingDiff(root, 'file'))!.text;
        expect(patch, contains('+actual working content'));
        expect(patch, isNot(contains('filtered')));
        expect(patch, isNot(contains('external-')));
      },
    );

    test(
      'reports an unknown outcome when the Git mutation loses its connection',
      () async {
        final (otherClient, otherHost) = await peers();
        addTearDown(otherClient.close);
        addTearDown(otherHost.close);
        otherHost.onRequest = (method, params) async {
          expect(method, LinkMethods.projectGitCommit);
          await otherHost.close();
          return null;
        };
        await expectLater(
          DesktopRemoteGitClient(otherClient).commit(
            root,
            expectedState: 'example',
            message: 'commit',
            files: const [],
          ),
          rejected(LinkErrors.gitOutcomeUnknown),
        );
      },
    );

    test('treats an unknown older-host Git method as unavailable', () async {
      final (oldClient, oldHost) = await peers();
      addTearDown(oldHost.close);
      addTearDown(oldClient.close);
      oldHost.onRequest = (_, _) async =>
          throw const LinkRemoteException(LinkErrors.unknown, 'Unknown method');
      expect(await DesktopRemoteGitClient(oldClient).status(root), isNull);
    });

    test(
      'lists local branches and immediately broadcasts the switched HEAD',
      () async {
        final state = LinkState.fromJson(
          (await client.call(LinkMethods.state)) as Map<String, Object?>,
        );
        expect(state.projects.single.canSwitchBranch, isTrue);
        expect(state.projects.single.branch, 'main');
        final list = await branches();
        expect(list, {
          'branches': ['feature/topic', 'main'],
          'head': git(['rev-parse', 'HEAD']),
          'branch': 'main',
        });
        final updated = client.events.firstWhere(
          (event) => event.name == LinkEvents.state,
        );
        await change('feature/topic', list);
        final fresh = LinkState.fromJson(
          (await updated).data as Map<String, Object?>,
        );
        expect(fresh.projects.single.branch, 'feature/topic');
        expect(git(['symbolic-ref', 'HEAD']), 'refs/heads/feature/topic');
        expect(File('$root/file').readAsStringSync(), 'feature\n');
      },
    );

    test(
      'refuses stale HEAD, stale symbolic branch, tags and remote-only refs',
      () async {
        final list = await branches();
        await expectLater(
          change('feature/topic', {...list, 'head': 'stale'}),
          rejected('stale'),
        );
        git(['switch', '-qc', 'other']);
        await expectLater(change('feature/topic', list), rejected('stale'));
        final fresh = await branches();
        for (final name in ['tag-only', 'remote-only', '@{-1}', '-f']) {
          await expectLater(
            change(name, fresh),
            rejected(LinkErrors.gitRejected),
          );
        }
        expect(git(['symbolic-ref', 'HEAD']), 'refs/heads/other');
      },
    );

    test('leaves conflicting edits and occupied worktrees to Git', () async {
      final list = await branches();
      final file = File('$root/file')..writeAsStringSync('unsaved changes\n');
      await expectLater(
        change('feature/topic', list),
        rejected(LinkErrors.gitRejected),
      );
      expect(file.readAsStringSync(), 'unsaved changes\n');
      expect(git(['symbolic-ref', 'HEAD']), 'refs/heads/main');
      git(['restore', 'file']);
      git(['worktree', 'add', '-q', '${folder.path}/second', 'feature/topic']);
      await expectLater(
        change('feature/topic', list),
        rejected(LinkErrors.gitRejected),
      );
      expect(git(['symbolic-ref', 'HEAD']), 'refs/heads/main');
    });

    test('refuses to switch while a project session is running', () async {
      final session = gitWorkspace
          .startAgent(gitWorkspace.projects.first)
          .session;
      session.attach();
      await pumpEventQueue();
      session.send(const ComposerMessage(text: 'Keep using this checkout'));
      expect(session.isStreaming, isTrue);
      await expectLater(
        change('feature/topic', await branches()),
        rejected(LinkErrors.busy),
      );
      expect(git(['symbolic-ref', 'HEAD']), 'refs/heads/main');
    });

    test(
      'keeps multi-root projects and unlisted paths outside the operation',
      () async {
        gitWorkspace.addFolder(root, folder.path);
        expect(gitBridge.state().projects.single.canSwitchBranch, isFalse);
        await expectLater(branches(), rejected(LinkErrors.unsupported));
        await expectLater(
          client.call(LinkMethods.projectBranches, {'project': folder.path}),
          rejected(LinkErrors.notFound),
        );
        expect(bridge.state().projects.single.canSwitchBranch, isFalse);
      },
    );
  });

  group('without a window', () {
    test('gives everything, and says nothing of earlier', () async {
      final opened = await open();
      expect(opened.start, 0);
      expect(opened.count, 6);
      expect(opened.earlier, isNull);
      expect(opened.toJson().containsKey('earlier'), isFalse);
    });

    test('an earlier call is refused', () async {
      await open();
      expect(
        bridge.handle(LinkMethods.earlier, {'session': id}),
        throwsA(isA<LinkRemoteException>()),
      );
    });

    test(
      'is sent all again from the start once the desktop prepends',
      () async {
        await open();
        final session = workspace.threads.first.session;
        await session.loadEarlier();
        await settle();
        final update = updates.last;
        expect(update.start, 0);
        expect(update.count, 12);
        expect(update.earlier, isNull);
      },
    );
  });

  group('with a window', () {
    test('gives the last items, counted from the first of them', () async {
      final opened = await open(4);
      expect(opened.start, 0);
      expect(opened.count, 4);
      expect(texts(opened.items), ['u5', '-', 'u6', '-']);
      expect(opened.earlier, isTrue);
    });

    test(
      'opened again with what the phone has: only what is new comes',
      () async {
        final first = await open(4);
        final have = [for (final item in first.items) linkDigest(item)];
        final session = workspace.threads.first.session;
        session.send(const ComposerMessage(text: 'more'));
        await settle();
        final again = LinkSessionUpdate.fromJson(
          (await bridge.handle(LinkMethods.open, {
                'session': id,
                'window': 4,
                'have': have,
              }))!
              as Map<String, Object?>,
        );
        // From where the phone's first item is: its four left out.
        expect(again.start, 4);
        expect(again.count, greaterThan(4));
        expect(texts(again.items).first, 'more');
        expect(again.earlier, isTrue);
        // What the desktop does not have (another conversation's): all of it.
        final other = LinkSessionUpdate.fromJson(
          (await bridge.handle(LinkMethods.open, {
                'session': id,
                'window': 4,
                'have': [linkDigest('elsewhere')],
              }))!
              as Map<String, Object?>,
        );
        expect(other.start, 0);
        expect(other.count, 4);
      },
    );

    test('a window beyond the items has all, and no earlier', () async {
      final opened = await open(100);
      expect(opened.count, 6);
      // u3's history is not read yet.
      expect(opened.earlier, isTrue);
    });

    test('a new item is a delta counted from the first', () async {
      await open(4);
      final session = workspace.threads.first.session;
      session.send(const ComposerMessage(text: 'more'));
      await settle();
      final update = updates.last;
      expect(update.start, 4);
      expect(update.count, greaterThan(4));
      expect(texts(update.items).first, 'more');
    });

    test(
      'the desktop reading earlier changes nothing but what is known',
      () async {
        await open(4);
        final session = workspace.threads.first.session;
        await session.loadEarlier();
        await settle();
        // Nothing of the phone's items changed: no update, or one of nothing.
        for (final update in updates) {
          expect(update.items, isEmpty);
          expect(update.count, 4);
        }
        // Its next item lands after the window, not at the shifted index.
        session.send(const ComposerMessage(text: 'more'));
        await settle();
        expect(updates.last.start, 4);
      },
    );

    test('earlier gives the items before, oldest first', () async {
      await open(4);
      final reply =
          (await bridge.handle(LinkMethods.earlier, {
                'session': id,
                'count': 2,
              }))!
              as Map<String, Object?>;
      expect(texts(reply['items']! as List), ['u4', '-']);
      expect(reply['earlier'], isTrue);
      final more =
          (await bridge.handle(LinkMethods.earlier, {'session': id}))!
              as Map<String, Object?>;
      // The window reached the start: the desktop read earlier ones.
      expect(asked, [null, 'u4']);
      expect(texts(more['items']! as List), [
        'u1', '-', 'u2', '-', 'u3', '-', //
      ]);
      expect(more['earlier'], isFalse);
    });

    test('deltas stay right after earlier', () async {
      await open(2);
      await bridge.handle(LinkMethods.earlier, {'session': id, 'count': 4});
      updates.clear();
      final session = workspace.threads.first.session;
      session.send(const ComposerMessage(text: 'more'));
      await settle();
      // 2 + 4 items now; the new one comes right after them.
      expect(updates.last.start, 6);
      expect(texts(updates.last.items).first, 'more');
    });

    test(
      'earlier reads the history when the window reaches the first',
      () async {
        await open(6);
        expect(asked, [null]);
        final reply =
            (await bridge.handle(LinkMethods.earlier, {
                  'session': id,
                  'count': 4,
                }))!
                as Map<String, Object?>;
        expect(asked, [null, 'u4']);
        expect(texts(reply['items']! as List), ['u2', '-', 'u3', '-']);
        expect(reply['earlier'], isTrue);
      },
    );

    test('earlier of a session not followed is refused', () async {
      expect(
        bridge.handle(LinkMethods.earlier, {'session': id}),
        throwsA(isA<LinkRemoteException>()),
      );
    });
  });

  test('a new agent keeps its id here, its session\'s as its alias', () async {
    late final KernelDescriptor descriptor;
    late FakeCli fake;
    descriptor = KernelDescriptor(
      id: 'claude-code',
      label: 'Claude Code',
      icon: Icons.auto_awesome_rounded,
      description: '',
      create: (context) => ClaudeCodeKernel(
        descriptor,
        context,
        start: (_) async => fake = FakeCli(),
      ),
    );
    final fresh = Workspace(
      projects: const [Project('p', '/p')],
      kernels: [descriptor],
    );
    addTearDown(fresh.dispose);
    final thread = fresh.startAgent(fresh.projects.first);
    thread.session.attach();
    // Given work, as session_new does: listed from then on.
    thread.session.send(ComposerMessage(text: 'go'));
    await pumpEventQueue();
    final (_, desktop) = await peers();
    final newBridge = WorkspaceBridge(
      workspace: fresh,
      peer: desktop,
      device: () => const DeviceInfo(name: 'Mac', kind: 'mac', system: 'macOS'),
    );
    addTearDown(newBridge.dispose);
    // Nothing said in it yet: the phone is told of it by an id given here.
    final phoneId = WorkspaceBridge.idOf(thread);
    expect(thread.id, isNull);
    expect(phoneId, startsWith('new-'));
    expect(newBridge.state().sessions.single.alias, isNull);

    // Its session's own id, once its process gives one: what the agents'
    // tools call it, and so what a bot's card names it by. The phone's id
    // does not change under it.
    fake.push({'type': 'system', 'subtype': 'init', 'session_id': 'k1'});
    await pumpEventQueue();
    expect(thread.id, 'k1');
    expect(WorkspaceBridge.idOf(thread), phoneId);
    final summary = newBridge.state().sessions.single;
    expect(summary.id, phoneId);
    expect(summary.alias, 'k1');
    expect(SessionSummary.fromJson(summary.toJson()).alias, 'k1');
  });

  test('a conversation read anew is followed anew, all of it sent', () async {
    await workspace.refresh();
    final kept = workspace.threads.firstWhere(
      (thread) => thread.record?.id == 'k',
    );
    final keptId = WorkspaceBridge.idOf(kept);
    await bridge.handle(LinkMethods.open, {'session': keptId, 'window': 2});
    await settle();
    final was = kept.session;
    updates.clear();

    workspace.reload(kept);
    await settle();
    expect(identical(kept.session, was), isFalse);
    // All of it again, of the conversation read anew: as it opened, its
    // history as it is read.
    expect(updates, isNotEmpty);
    expect(updates.map((update) => update.session), everyElement(keptId));
    expect(updates.first.start, 0);
    expect(texts(updates.last.items), ['u4', '-', 'u5', '-', 'u6', '-']);
    // Earlier ones from the conversation read anew.
    final earlier = await bridge.handle(LinkMethods.earlier, {
      'session': keptId,
      'count': 2,
    });
    expect(earlier, isNotNull);
  });

  test(
    'session commands reflect the kernel and use the existing send',
    () async {
      final session = {'session': id};
      cli.push({
        'type': 'system',
        'subtype': 'commands_changed',
        'commands': [
          {
            'name': 'compact',
            'description': 'Compact the conversation',
            'argumentHint': '[instructions]',
          },
          {'name': 'status', 'description': 'Show status'},
        ],
      });
      await pumpEventQueue();

      expect(await phone.call(LinkMethods.sessionCommands, session), {
        'commands': [
          {
            'name': 'compact',
            'description': 'Compact the conversation',
            'argumentHint': '[instructions]',
          },
          {'name': 'status', 'description': 'Show status', 'argumentHint': ''},
        ],
      });
      expect(cli.users, isEmpty);

      const text = '/compact keep the summary';
      expect(await phone.call(LinkMethods.send, {...session, 'text': text}), {
        'session': id,
      });
      await pumpEventQueue();
      final content = (cli.users.single['message']! as Map)['content']! as List;
      expect(content.last, {'type': 'text', 'text': text});

      cli.push({
        'type': 'system',
        'subtype': 'commands_changed',
        'commands': [],
      });
      await pumpEventQueue();
      expect(await phone.call(LinkMethods.sessionCommands, session), {
        'commands': <Object?>[],
      });
    },
  );

  test('a message from the phone tells the agent so, unseen', () async {
    await bridge.handle(LinkMethods.send, {'session': id, 'text': 'go'});
    await settle();
    final content = (cli.users.last['message']! as Map)['content']! as List;
    expect(
      [for (final block in content) (block as Map)['text']],
      // The user's, as one written at the computer is: suggestions asked
      // for too.
      [UserPlace.phone.note, ReplySuggestions.on, 'go'],
    );
  });

  test(
    'in-turn delivery uses the host turn advertised by the follow',
    () async {
      await open();
      final session = workspace.threads.first.session;
      session.send(const ComposerMessage(text: 'synthetic active turn'));
      await settle();
      final capabilities = updates.last.actions;
      expect(capabilities, containsPair('queue', true));
      final turn = capabilities!['turn'] as int;
      await expectLater(
        bridge.handle(LinkMethods.send, {
          'session': id,
          'text': 'stale interruption',
          'duringTurn': true,
          'now': true,
          'expectedTurn': turn - 1,
        }),
        throwsA(
          isA<LinkRemoteException>().having(
            (error) => error.code,
            'code',
            'stale',
          ),
        ),
      );
      expect(
        await bridge.handle(LinkMethods.send, {
          'session': id,
          'text': 'next synthetic turn',
          'duringTurn': true,
          'now': false,
        }),
        {'session': id},
      );
      await settle();
      expect(session.queued.map((entry) => entry.$2.text), [
        'next synthetic turn',
      ]);
    },
  );

  test(
    'remote stop interrupts the advertised turn and rejects a stale stop',
    () async {
      await phone.call(LinkMethods.open, {'session': id});
      final session = workspace.threads.first.session;
      session.send(const ComposerMessage(text: 'first turn'));
      await settle();
      final first = updates.last.actions!['turn'];
      expect(first, isA<int>());
      expect(updates.last.live, isTrue);

      await phone.call(LinkMethods.stop, {
        'session': id,
        'expectedTurn': first,
      });
      expect(cli.requests('interrupt'), hasLength(1));
      expect(session.lastTurnInterrupted, isTrue);
      await settle();
      expect(updates.last.live, isFalse);

      // Repeating a stop after the target ends has no further effect.
      await phone.call(LinkMethods.stop, {
        'session': id,
        'expectedTurn': first,
      });
      expect(cli.requests('interrupt'), hasLength(1));
      session.send(const ComposerMessage(text: 'next turn'));
      await settle();
      final next = updates.last.actions!['turn'];
      expect(next, isA<int>());
      expect(next, isNot(first));
      await expectLater(
        phone.call(LinkMethods.stop, {'session': id, 'expectedTurn': first}),
        throwsA(
          isA<LinkRemoteException>().having((e) => e.code, 'code', 'stale'),
        ),
      );
      expect(session.isStreaming, isTrue);
      expect(cli.requests('interrupt'), hasLength(1));

      // Older clients can still stop the session without a turn token.
      await phone.call(LinkMethods.stop, {'session': id});
      expect(cli.requests('interrupt'), hasLength(2));
      expect(session.isStreaming, isFalse);
    },
  );

  test(
    'remote stop during startup keeps the prompt from reaching the CLI',
    () async {
      await phone.call(LinkMethods.open, {'session': id});
      final session = workspace.threads.first.session;
      final oldCli = cli;
      final gate = startGate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      session.restart();
      session.send(const ComposerMessage(text: 'cancel before the CLI starts'));
      await settle();
      final turn = updates.last.actions!['turn'];
      expect(turn, isA<int>());
      await phone.call(LinkMethods.stop, {'session': id, 'expectedTurn': turn});
      expect(session.lastTurnInterrupted, isTrue);
      await settle();
      expect(updates.last.live, isFalse);

      gate.complete();
      await settle();
      expect(cli, isNot(same(oldCli)));
      expect(cli.users, isEmpty);
      session.send(const ComposerMessage(text: 'send after restart'));
      await settle();
      expect(cli.users, hasLength(1));
      expect(cli.users.single.toString(), contains('send after restart'));
    },
  );

  test('streamed text goes as what was added, and adds up the same', () async {
    final mirror = LinkSessionMirror()
      ..opened(
        jsonDecode(
          jsonEncode(await bridge.handle(LinkMethods.open, {'session': id})),
        ) as Map<String, Object?>,
      );
    final wire = <Map<String, Object?>>[];
    final sub = phone.events
        .where((e) => e.name == LinkEvents.session)
        .listen((e) => wire.add(e.data! as Map<String, Object?>));
    addTearDown(sub.cancel);
    await bridge.handle(LinkMethods.send, {'session': id, 'text': 'go'});
    await settle();
    Future<void> stream(Map<String, Object?> event) async {
      cli.push({'type': 'stream_event', 'event': event});
      await settle();
    }

    await stream({
      'type': 'message_start',
      'message': {
        'id': 'm-live',
        'usage': {'input_tokens': 1},
      },
    });
    await stream({
      'type': 'content_block_start',
      'index': 0,
      'content_block': {'type': 'text', 'text': ''},
    });
    for (final words in ['Once ', 'upon ', 'a ', 'time']) {
      await stream({
        'type': 'content_block_delta',
        'index': 0,
        'delta': {'type': 'text_delta', 'text': words},
      });
    }
    final whole = [for (final update in wire) mirror.apply(update)];
    expect(whole, everyElement(isNotNull));
    expect(wire.where((w) => w['append'] != null), isNotEmpty);
    expect(wire.skip(1).where((w) => w['partial'] != true), isEmpty);

    final fresh = await open();
    final last = whole.last!;
    expect(last['count'], fresh.count);
    final items = last['items']! as List;
    expect(
      jsonEncode(items),
      jsonEncode(fresh.items.sublist(fresh.count - items.length)),
    );
    expect(jsonEncode(fresh.items), contains('Once upon a time'));
  });

  test('nested agent progress updates tasks outside the item window', () async {
    Map<String, Object?> call(
      String id,
      String name,
      Map<String, Object?> input, {
      String? parent,
    }) => {
      'type': 'assistant',
      'uuid': 'm-$id',
      'parent_tool_use_id': parent,
      'message': {
        'id': 'msg-$id',
        'role': 'assistant',
        'content': [
          {'type': 'tool_use', 'id': id, 'name': name, 'input': input},
        ],
      },
    };

    await bridge.handle(LinkMethods.send, {'session': id, 'text': 'go'});
    await pumpEventQueue();
    cli
      ..push(call('outer', 'Agent', {'description': 'Outer agent'}))
      ..push(
        call('inner', 'Agent', {'description': 'Inner agent'}, parent: 'outer'),
      )
      ..push({
        'type': 'system',
        'subtype': 'task_started',
        'task_id': 'nested-task',
        'task_type': 'local_agent',
        'tool_use_id': 'inner',
        'description': 'Inner agent',
        'is_backgrounded': true,
      })
      ..push({
        'type': 'system',
        'subtype': 'task_progress',
        'task_id': 'nested-task',
        'summary': 'Kernel progress',
      })
      ..push(call('unrelated', 'Read', {'file_path': '/p/other.dart'}));
    await pumpEventQueue();

    final wire = await bridge.handle(LinkMethods.open, {
      'session': id,
      'window': 1,
    }) as Map<String, Object?>;
    final mirror = LinkSessionMirror();
    final opened = LinkSessionUpdate.fromJson(mirror.opened(wire)!);
    expect(opened.earlier, isTrue);
    expect(jsonEncode(opened.items), isNot(contains('Outer agent')));
    final task = opened.tasks.single;
    expect(task.id, 'nested-task');
    expect(task.summary, 'Kernel progress');

    final changed = phone.events
        .where(
          (e) =>
              e.name == LinkEvents.session && (e.data! as Map)['tasks'] != null,
        )
        .timeout(const Duration(seconds: 2))
        .first;
    cli.push(
      call('read', 'Read', {'file_path': '/p/details.dart'}, parent: 'inner'),
    );
    final delta = (await changed).data! as Map<String, Object?>;
    expect(delta['partial'], isTrue);
    expect(delta['items'], isEmpty);
    expect(delta['start'], opened.count);
    final updated = LinkSessionUpdate.fromJson(mirror.apply(delta)!);
    expect(updated.tasks.single.toJson(), {
      ...task.toJson(),
      'summary': 'Reading details.dart',
    });
  });

  test('a task\'s output is watched: what was added, then all again', () async {
    var text = 'one\n';
    final sent = <LinkOutput>[];
    final watch = OutputWatch(
      session: 's',
      task: 't',
      text: text,
      read: () async => text,
      emit: sent.add,
      every: const Duration(milliseconds: 5),
    );
    addTearDown(watch.dispose);
    text += 'two\n';
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(sent.single.text, 'two\n');
    expect(sent.single.offset, text.length);
    expect(sent.single.reset, isFalse);

    // Cut and written again: the phone is sent its tail whole.
    text = 'fresh\n';
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(sent.last.reset, isTrue);
    expect(sent.last.text, 'fresh\n');

    // More at once than the phone keeps: its tail, whole.
    text += 'x' * (LinkLimits.output + 10);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(sent.last.reset, isTrue);
    expect(sent.last.text.length, LinkLimits.output);
    final count = sent.length;
    watch.dispose();
    text += 'more';
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(sent, hasLength(count));
  });

  test('a plan is not started while none awaits', () async {
    await open();
    expect(
      bridge.handle(LinkMethods.startPlan, {'session': id}),
      throwsA(
        isA<LinkRemoteException>().having(
          (e) => e.code,
          'code',
          LinkErrors.notFound,
        ),
      ),
    );
  });

  group('edit', () {
    test(
      'guarded rewinds reject a transcript that changed before submission',
      () async {
        final first = await open(3);
        expect(first.actions, containsPair('edit', true));
        expect(first.actions, containsPair('queue', true));
        final guard = linkDigest(first.items);
        expect(
          await bridge.handle(LinkMethods.rewindPlan, {
            'session': id,
            'index': 1,
            'expectedWindow': guard,
          }),
          containsPair('files', isEmpty),
        );
        await bridge.handle(LinkMethods.earlier, {'session': id, 'count': 2});
        await expectLater(
          bridge.handle(LinkMethods.edit, {
            'session': id,
            'index': 1,
            'expectedWindow': guard,
            'text': 'do not send',
          }),
          throwsA(
            isA<LinkRemoteException>().having(
              (error) => error.code,
              'code',
              'stale',
            ),
          ),
        );
      },
    );

    test('an answer is not a message to edit', () async {
      await open();
      expect(
        bridge.handle(LinkMethods.edit, {
          'session': id,
          'index': 1,
          'text': 'again',
        }),
        throwsA(
          isA<LinkRemoteException>().having(
            (e) => e.code,
            'code',
            LinkErrors.notFound,
          ),
        ),
      );
    });

    test('the index is counted from the phone\'s first item', () async {
      // a5, u6, a6: the phone's 1 is the session's u6.
      final first = await open(3);
      expect(texts(first.items), ['-', 'u6', '-']);
      await bridge.handle(LinkMethods.edit, {
        'session': id,
        'index': 1,
        'text': 'u6 again',
      });
      // Counted from the session's first, its 1 would be an answer.
      expect(
        bridge.handle(LinkMethods.edit, {
          'session': id,
          'index': 0,
          'text': 'a5 is no message',
        }),
        throwsA(isA<LinkRemoteException>()),
      );
    });

    test('what sending a message again would put back of the files is '
        'asked by the same index', () async {
      await open(3);
      // Nothing the agent changed is known: nothing to ask.
      expect(
        await bridge.handle(LinkMethods.rewindPlan, {
          'session': id,
          'index': 1,
        }),
        {'files': <Object?>[], 'setting': 'ask'},
      );
      expect(
        bridge.handle(LinkMethods.rewindPlan, {'session': id, 'index': 0}),
        throwsA(isA<LinkRemoteException>()),
      );
    });
  });

  group('image', () {
    test('a file that is not a picture is refused', () async {
      expect(
        bridge.handle(LinkMethods.image, {'project': '/p', 'path': 'a.txt'}),
        throwsA(isA<LinkRemoteException>()),
      );
    });

    test('a picture not there is not found', () async {
      expect(
        bridge.handle(LinkMethods.image, {'project': '/p', 'path': 'x.png'}),
        throwsA(
          isA<LinkRemoteException>().having(
            (e) => e.code,
            'code',
            LinkErrors.notFound,
          ),
        ),
      );
    });
  });

  test('a bot\'s agent: its model the user picks, not how it asks', () async {
    late final KernelDescriptor descriptor;
    descriptor = KernelDescriptor(
      id: 'claude-code',
      label: 'Claude Code',
      icon: Icons.auto_awesome_rounded,
      description: '',
      create: (context) =>
          ClaudeCodeKernel(descriptor, context, start: (_) async => FakeCli()),
    );
    final workspace = Workspace(kernels: [descriptor]);
    addTearDown(workspace.dispose);
    final bots = Bots(workspace: workspace, folders: MemoryBotFolders());
    await bots.start();
    addTearDown(bots.dispose);
    final (_, desktop) = await peers();
    final withBots = WorkspaceBridge(
      workspace: workspace,
      peer: desktop,
      device: () => const DeviceInfo(name: 'Mac', kind: 'mac', system: 'macOS'),
      bots: bots,
    );
    addTearDown(withBots.dispose);
    final assistant = bots.bots.single;
    final thread = bots.threadFor(assistant);
    final session = bots.privateSessionId(assistant);
    expect(
      withBots.handle(LinkMethods.choose, {
        'session': session,
        'kind': 'permission',
        'option': 'bypassPermissions',
      }),
      throwsA(
        isA<LinkRemoteException>().having(
          (e) => e.code,
          'code',
          LinkErrors.unsupported,
        ),
      ),
    );
    final models = thread.session.models!;
    final other = models.options.firstWhere((o) => o != models.selected);
    await withBots.handle(LinkMethods.choose, {
      'session': session,
      'kind': 'model',
      'option': other.id,
    });
    expect(bots.byId('assistant')!.model, other.id);
    expect(
      withBots.state().bots.single,
      isA<LinkBot>().having((b) => b.model, 'model', other.label),
    );
  });

  test(
    'bot chat aliases expose the DM projection and hide all workers',
    () async {
      final workspace = Workspace();
      addTearDown(workspace.dispose);
      final bots = Bots(workspace: workspace, folders: MemoryBotFolders());
      await bots.start();
      addTearDown(bots.dispose);
      final (_, desktop) = await peers();
      final withBots = WorkspaceBridge(
        workspace: workspace,
        peer: desktop,
        device: () =>
            const DeviceInfo(name: 'Mac', kind: 'mac', system: 'macOS'),
        bots: bots,
      );
      addTearDown(withBots.dispose);
      final bot = bots.bots.single;
      final first = bots.groups.save(name: 'First', members: [bot.id]);
      final second = bots.groups.save(name: 'Second', members: [bot.id]);
      final workers = [
        bots.threadFor(bot),
        bots.threadFor(bot, group: first.id),
        bots.threadFor(bot, group: second.id),
      ];
      final state = withBots.state();
      final alias = state.bots.single.session!;
      expect(state.sessions, isEmpty);
      expect(state.botMemoryOptions, contains(LinkMethods.botMemoryEntries));
      final forbidden = throwsA(
        isA<LinkRemoteException>().having(
          (e) => e.code,
          'code',
          LinkErrors.notFound,
        ),
      );
      for (final worker in workers) {
        final id = WorkspaceBridge.idOf(worker);
        expect(id, isNot(alias));
        for (final method in [
          LinkMethods.open,
          LinkMethods.sessionCommands,
          LinkMethods.stop,
          LinkMethods.archive,
          LinkMethods.delete,
          LinkMethods.output,
        ]) {
          await expectLater(
            withBots.handle(method, {'session': id}),
            forbidden,
          );
        }
      }
      await expectLater(
        withBots.handle(LinkMethods.sessionCommands, {'session': alias}),
        forbidden,
      );
      final opened = await withBots.handle(LinkMethods.open, {
        'session': alias,
        'window': 1,
      }) as Map;
      expect(opened['session'], alias);
      expect(opened['items'], isEmpty);
      bots.groups.tell = (_, _, _) {};
      await withBots.handle(LinkMethods.sendGroup, {
        'group': first.id,
        'text': 'group turn',
      });
      expect(bots.groups.answering(bot.id), first.id);
      expect(
        await withBots.handle(LinkMethods.send, {
          'bot': bot.id,
          'text': 'pending direct message',
        }),
        {'session': alias},
      );
      final pending = await withBots.handle(LinkMethods.open, {
        'session': alias,
        'window': 1,
      }) as Map;
      expect(
        (pending['items'] as List).single,
        allOf(
          containsPair('text', 'pending direct message'),
          containsPair('queued', true),
          containsPair('privateQueued', true),
        ),
      );
      await expectLater(
        withBots.handle(LinkMethods.delete, {'session': alias}),
        forbidden,
      );
      await withBots.handle(LinkMethods.clearBotChat, {'bot': bot.id});
      expect(withBots.state().bots.single.session, isNot(alias));
      expect(withBots.state().groups.map((group) => group.id).toSet(), {
        first.id,
        second.id,
      });
      await expectLater(
        withBots.handle(LinkMethods.open, {'session': alias}),
        forbidden,
      );
    },
  );

  test('old DM windows stay read-only after A to B to restored A', () async {
    const folder = '/bots/runtime/assistant/private';
    const internal = 'private-worker-a';
    final runners = <FakeCli>[];
    final record = SessionRecord(
      id: internal,
      title: 'Archive A',
      updatedAt: DateTime(2026),
      cwd: folder,
    );
    late final KernelDescriptor descriptor;
    descriptor = KernelDescriptor(
      id: 'claude-code',
      label: 'Claude Code',
      icon: Icons.auto_awesome_rounded,
      description: '',
      catalog: _KeptCatalog([
        ProjectRecord(path: folder, sessions: [record]),
      ]),
      create: (context) => ClaudeCodeKernel(
        descriptor,
        context,
        start: (_) async {
          final cli = FakeCli();
          runners.add(cli);
          return cli;
        },
        readHistoryPage: (_, {required turns, before}) async =>
            page(['a1', 'a2']),
      ),
    );
    final workspace = Workspace(kernels: [descriptor]);
    final folders = MemoryBotFolders();
    final bots = Bots(workspace: workspace, folders: folders);
    addTearDown(workspace.dispose);
    addTearDown(bots.dispose);
    await workspace.refresh();
    await bots.start();
    final bot = bots.bots.single;
    final a = bots.threadOf(bot)!;
    expect(a.id, internal);

    late final WorkspaceBridge host;
    final (phone, desktop) = await peers(
      onRequest: (m, p) => host.handle(m, p),
    );
    host = WorkspaceBridge(
      workspace: workspace,
      peer: desktop,
      device: () => const DeviceInfo(name: 'Mac', kind: 'mac', system: 'macOS'),
      bots: bots,
      throttle: const Duration(milliseconds: 5),
    )..start();
    addTearDown(host.dispose);
    addTearDown(phone.close);
    Future<LinkSessionUpdate> openDm(
      String alias, [
      List<String> have = const [],
    ]) async => LinkSessionUpdate.fromJson(
      await phone.call(LinkMethods.open, {
        'session': alias,
        'window': 1,
        'have': have,
      }) as Map<String, Object?>,
    );

    final first = host.state().bots.single.session!;
    final openedA = await openDm(first);
    expect(texts(openedA.items), ['a2']);
    final have = [for (final item in openedA.items) linkDigest(item)];
    final changed = phone.events.firstWhere(
      (event) => event.name == LinkEvents.state,
    );
    final made = await phone.call(LinkMethods.newBotConversation, {
      'bot': bot.id,
    }) as Map;
    final second = made['session'] as String;
    expect(second, isNot(first));
    final stateEvent =
        (await changed.timeout(const Duration(seconds: 5))).data as Map;
    expect(
      (stateEvent['bots'] as List).single,
      containsPair('session', second),
    );
    expect(bots.threadOf(bot), isNot(same(a)));
    expect((await openDm(first)).items, openedA.items);
    expect(
      await phone.call(LinkMethods.earlier, {'session': first}),
      containsPair('items', hasLength(1)),
    );
    expect((await openDm(second)).actions?['edit'], isNotNull);

    expect(bots.activateConversation(bot, a), same(a));
    final restored = host.state().bots.single.session!;
    expect(restored, isNot(isIn([first, second, internal])));
    expect(bots.threadOf(bot)?.id, internal);
    final openedAgain = await openDm(restored, have);
    expect(openedAgain.start, 0);
    expect(openedAgain.items, openedA.items);
    expect((await openDm(first)).actions, isNull);
    final stale = throwsA(
      isA<LinkRemoteException>().having((e) => e.code, 'code', 'stale'),
    );
    for (final alias in [first, second]) {
      for (final method in [
        LinkMethods.edit,
        LinkMethods.stop,
        LinkMethods.send,
      ]) {
        await expectLater(
          phone.call(method, {
            'session': alias,
            'text': 'must not run',
            'index': 0,
            'expectedWindow': linkDigest(openedAgain.items),
          }),
          stale,
        );
      }
    }
    await phone.call(LinkMethods.stop, {'session': restored});
    expect(bots.privateSessionId(bot), restored);
    await phone.call(LinkMethods.refreshBotMemory, {'bot': bot.id});
    expect(bots.privateSessionId(bot), restored);
    final reloadedWorkspace = Workspace(kernels: [descriptor]);
    final reloaded = Bots(workspace: reloadedWorkspace, folders: folders);
    await reloadedWorkspace.refresh();
    // Read the persisted alias state with a fresh host, independently of
    // workspace archive metadata. The original alias stays historical.
    addTearDown(reloadedWorkspace.dispose);
    addTearDown(reloaded.dispose);
    expect(reloaded.privateSessionId(bot), restored);
    expect(reloaded.threadOf(bot)?.id, internal);

    await phone.call(LinkMethods.close, {'session': restored});
    Future<Object?> edit({int index = 0, String? digest}) =>
        phone.call(LinkMethods.edit, {
          'session': restored,
          'index': index,
          'expectedWindow': ?digest,
          'text': '', // Exercise address resolution without starting a turn.
        });
    await expectLater(edit(), stale);
    final legacy = await openDm(restored);
    expect(legacy.actions, containsPair('editRequiresWindow', false));
    expect(await edit(), isNull);
    final earlier = await phone.call(LinkMethods.earlier, {
      'session': restored,
      'count': 1,
    }) as Map;
    final window = [...earlier['items'] as List, ...legacy.items];
    await expectLater(edit(index: 1), stale);
    expect(await edit(index: 1, digest: linkDigest(window)), isNull);

    await openDm(restored);
    await phone.call(LinkMethods.edit, {
      'session': restored,
      'index': 0,
      'text': 'a2 revised',
    });
    await settle();
    expect(
      runners.expand((cli) => cli.requests('rewind_conversation')).single,
      containsPair('target_message_uuid', 'a2'),
    );
  });

  test(
    'private and group stable send receipts survive a host restart',
    () async {
      final folders = MemoryBotFolders();
      final phoneId = LinkIdentity.generate().id;
      final stale = throwsA(
        isA<LinkRemoteException>().having((e) => e.code, 'code', 'stale'),
      );
      final conflict = throwsA(
        isA<LinkRemoteException>().having((e) => e.code, 'code', 'conflict'),
      );
      Future<
        ({Workspace workspace, Bots bots, WorkspaceBridge host, LinkPeer phone})
      >
      startHost() async {
        final workspace = Workspace();
        final bots = Bots(workspace: workspace, folders: folders);
        await bots.start();
        bots.groups.tell = (_, _, _) {};
        late final WorkspaceBridge host;
        final (phone, desktop) = await peers(
          phoneId: phoneId,
          onRequest: (m, p) => host.handle(m, p),
        );
        host = WorkspaceBridge(
          workspace: workspace,
          peer: desktop,
          device: () =>
              const DeviceInfo(name: 'Mac', kind: 'mac', system: 'macOS'),
          bots: bots,
        )..start();
        return (workspace: workspace, bots: bots, host: host, phone: phone);
      }

      final first = await startHost();
      final bot = first.bots.bots.single;
      final other = first.bots.save(name: 'Other', identity: '', abilities: {});
      final group = first.bots.groups.save(name: 'Room', members: [bot.id]);
      final otherGroup = first.bots.groups.save(
        name: 'Other room',
        members: [other.id],
      );
      final alias = first.bots.privateSessionId(bot);
      final groupSend = {
        'group': group.id,
        'id': 'same-id',
        'text': 'group message',
      };
      final directSend = {
        'bot': bot.id,
        'id': 'same-id',
        'text': 'private message',
      };
      expect(await first.phone.call(LinkMethods.sendGroup, groupSend), {
        'seq': 1,
      });
      await settle();
      expect(await first.phone.call(LinkMethods.send, directSend), {
        'session': alias,
      });
      expect(first.bots.pendingPrivateItems(bot).map((item) => item.text), [
        'private message',
      ]);

      final cancelledSend = {
        ...directSend,
        'id': 'cancel-me',
        'text': 'withdraw this',
      };
      await first.phone.call(LinkMethods.send, cancelledSend);
      final queue =
          await first.phone.call(LinkMethods.open, {'session': alias}) as Map;
      expect(queue['actions'], containsPair('cancelQueued', true));
      final item = (queue['items'] as List).cast<Map>().singleWhere(
        (item) => item['text'] == 'withdraw this',
      );
      final cancel = {'session': alias, 'queueId': item['queueId']};
      await expectLater(
        first.phone.call(LinkMethods.cancelQueued, {
          ...cancel,
          'session': 'retired-window',
        }),
        stale,
      );
      await first.phone.call(LinkMethods.cancelQueued, cancel);
      await expectLater(
        first.phone.call(LinkMethods.cancelQueued, cancel),
        stale,
      );
      expect(first.bots.pendingPrivateItems(bot).map((item) => item.text), [
        'private message',
      ]);

      await first.phone.close();
      first.host.dispose();
      first.bots.dispose();
      first.workspace.dispose();
      final next = await startHost();
      addTearDown(next.workspace.dispose);
      addTearDown(next.bots.dispose);
      addTearDown(next.host.dispose);
      addTearDown(next.phone.close);
      expect(next.bots.privateSessionId(bot), alias);
      expect(await next.phone.call(LinkMethods.sendGroup, groupSend), {
        'seq': 1,
      });
      expect(next.bots.groups.messages(group.id), hasLength(1));
      await expectLater(
        next.phone.call(LinkMethods.send, cancelledSend),
        stale,
      );
      expect(await next.phone.call(LinkMethods.send, directSend), {
        'session': alias,
      });
      await expectLater(
        next.phone.call(LinkMethods.send, {...directSend, 'bot': other.id}),
        conflict,
      );
      await expectLater(
        next.phone.call(LinkMethods.send, {...directSend, 'text': 'changed'}),
        conflict,
      );
      await expectLater(
        next.phone.call(LinkMethods.sendGroup, {
          ...groupSend,
          'group': otherGroup.id,
        }),
        conflict,
      );
      await expectLater(
        next.phone.call(LinkMethods.sendGroup, {
          ...groupSend,
          'text': 'changed',
        }),
        conflict,
      );
      await next.phone.call(LinkMethods.clearBotChat, {'bot': bot.id});
      await expectLater(next.phone.call(LinkMethods.send, directSend), stale);
      await next.phone.call(LinkMethods.deleteGroup, {'group': group.id});
      await expectLater(
        next.phone.call(LinkMethods.sendGroup, {
          ...groupSend,
          'group': otherGroup.id,
        }),
        stale,
      );
    },
  );

  test('structured bot memory is revision checked and group scoped', () async {
    final workspace = Workspace();
    addTearDown(workspace.dispose);
    final bots = Bots(workspace: workspace, folders: MemoryBotFolders());
    await bots.start();
    addTearDown(bots.dispose);
    final (_, desktop) = await peers();
    final withBots = WorkspaceBridge(
      workspace: workspace,
      peer: desktop,
      device: () => const DeviceInfo(name: 'Mac', kind: 'mac', system: 'macOS'),
      bots: bots,
    );
    addTearDown(withBots.dispose);
    final bot = bots.bots.single;
    final group = bots.groups.save(name: 'Group', members: [bot.id]);
    expect(
      await withBots.handle(LinkMethods.refreshBotMemory, {'bot': bot.id}),
      {'refreshed': false, 'status': 'onOpen'},
    );
    final snapshot = await withBots.handle(LinkMethods.changeBotMemory, {
      'bot': bot.id,
      'changes': [
        {'action': 'add', 'text': '红茶'},
      ],
    }) as Map;
    final entry = (snapshot['entries'] as List).single as Map;
    expect(entry['text'], '红茶');
    expect(entry['injected'], true);
    final groupMemory = await withBots.handle(LinkMethods.botMemoryEntries, {
      'bot': bot.id,
      'group': group.id,
    }) as Map;
    expect(groupMemory['entries'], isEmpty);
    await expectLater(
      withBots.handle(LinkMethods.changeBotMemory, {
        'bot': bot.id,
        'changes': [
          {'action': 'remove', 'id': entry['id'], 'revision': 0},
        ],
      }),
      throwsA(
        isA<LinkRemoteException>().having((e) => e.code, 'code', 'stale'),
      ),
    );
  });

  test('bot memory review batches require RPC opt-in', () async {
    final workspace = Workspace();
    addTearDown(workspace.dispose);
    final bots = Bots(workspace: workspace, folders: MemoryBotFolders());
    await bots.start();
    addTearDown(bots.dispose);
    final bot = bots.bots.single;
    final scope = BotMemoryScope(botId: bot.id);
    const sessionId = 'internal-review-session';
    const firstMessageId = 'internal-release-notes-message';
    const secondMessageId = 'internal-smoke-tests-message';
    const first = 'Prefers concise release notes';
    const second = 'Runs smoke tests before tagging a release';
    const evidence = {firstMessageId: '$first.', secondMessageId: '$second.'};
    final review = bots.memoryReview = BotMemoryReview(
      store: MemoryPreferenceStore(),
      scopeExists: bots.reviewScopeExists,
      readEvidence: (_, _, source) async => evidence[source.messageId],
      readMemory: (_) => bots.userMemory(bot),
      applyMemory:
          (
            _,
            changes, {
            required sessionId,
            required messageId,
            required operationId,
            required changeSources,
          }) {
            bots.changeUserMemory(
              bot,
              changes,
              session: sessionId,
              sourceMessage: messageId,
              operationId: operationId,
              changeSources: changeSources,
            );
          },
      ask: (_) async => jsonEncode({
        'proposals': [
          // Review references are numbered from the newest turn.
          for (final (text, ref) in [(first, 'e2'), (second, 'e1')])
            {
              'action': 'add',
              'text': text,
              'evidence': [ref],
            },
        ],
      }),
      foregroundBusy: () => false,
      threshold: evidence.length,
    );
    await review.configure(scope, memoryApproval: true);
    for (final messageId in evidence.keys) {
      await review.recordTurn(
        scope: scope,
        sessionId: sessionId,
        turnId: messageId,
        evidence: [
          BotMemoryReviewEvidence(
            messageId: messageId,
            role: BotMemoryReviewRole.user,
          ),
        ],
      );
    }
    expect(await review.runNext(), isTrue);

    final (_, desktop) = await peers();
    final bridge = WorkspaceBridge(
      workspace: workspace,
      peer: desktop,
      device: () => const DeviceInfo(name: 'Mac', kind: 'mac', system: 'macOS'),
      bots: bots,
    );
    addTearDown(bridge.dispose);
    Future<Map<String, Object?>> call(
      String method, [
      Map<String, Object?> args = const {},
    ]) async =>
        await bridge.handle(method, {'bot': bot.id, ...args})
            as Map<String, Object?>;

    expect((await call(LinkMethods.botMemoryReview))['proposals'], isEmpty);
    final listed = await call(LinkMethods.botMemoryReview, {'batch': true});
    final batch = (listed['proposals'] as List).single as Map;
    expect(batch['action'], 'batch');
    expect(batch['status'], 'pending');
    expect(
      (batch['changes'] as List).cast<Map>().map(
        (row) => (row['action'], row['before'], row['after']),
      ),
      [('add', null, first), ('add', null, second)],
    );

    final decision = {'proposal': batch['id'], 'approve': true};
    await expectLater(
      call(LinkMethods.decideBotMemory, decision),
      throwsA(
        isA<LinkRemoteException>().having(
          (error) => error.code,
          'code',
          'stale',
        ),
      ),
    );
    expect(bots.userMemory(bot).entries, isEmpty);
    final applied = await call(LinkMethods.decideBotMemory, {
      ...decision,
      'batch': true,
    });
    expect(applied['status'], 'applied');
    expect(
      bots
          .userMemory(bot)
          .entries
          .map((entry) => (entry.text, entry.sourceMessage)),
      [(first, firstMessageId), (second, secondMessageId)],
    );
    for (final proposal in [batch, applied]) {
      final sources = (proposal['evidence'] as List).cast<Map>();
      expect(sources.map((source) => source['role']), ['user', 'user']);
      final tokens = [
        for (final source in sources) (source['source'] as Map)['token'],
      ];
      expect(tokens, everyElement(isA<String>()));
      expect(tokens.toSet(), hasLength(2));
      expect(
        (proposal['changes'] as List).cast<Map>().map((row) => row['evidence']),
        [
          [sources.first],
          [sources.last],
        ],
      );

      final wire = jsonEncode(proposal);
      expect(wire, isNot(contains(sessionId)));
      for (final source in evidence.entries) {
        expect(wire, isNot(contains(source.key)));
        expect(wire, isNot(contains(botMemoryDigest(source.value))));
      }
    }
  });

  test('learned skill RPCs authorize project and revision', () async {
    final workspace = Workspace();
    addTearDown(workspace.dispose);
    final folders = MemoryBotFolders();
    final bots = Bots(workspace: workspace, folders: folders);
    await bots.start();
    addTearDown(bots.dispose);
    workspace.importFolders(['/release', '/other']);
    final bot = bots.bots.single;
    final skills = BotMemorySkills(
      store: MemoryPreferenceStore(),
      folders: folders,
      root: '/bots/skills',
      canUseProject: (id, project) => id == bot.id && project == '/release',
    );
    bots.memoryReview = BotMemoryReview(
      store: MemoryPreferenceStore(),
      scopeExists: bots.reviewScopeExists,
      readEvidence: (_, _, _) async => null,
      readMemory: (_) => BotMemory.fromMarkdown(''),
      applyMemory: (
        _,
        _, {
        required sessionId,
        required messageId,
        required operationId,
        required changeSources,
      }) {},
      ask: (_) async => '',
      foregroundBusy: () => false,
      skills: skills,
    );
    for (var revision = 1; revision <= 2; revision++) {
      await skills.apply(
        botId: bot.id,
        project: '/release',
        draft: BotMemorySkillDraft(
          name: 'release-preflight',
          trigger: 'When cutting a release',
          steps: ['Check the version $revision', 'Check the release notes'],
          verification: 'Both checks passed',
          expectedRevision: revision == 1 ? null : revision - 1,
        ),
        proposalId: 'proposal-$revision',
        evidence: [
          {'sessionId': 'internal-worker'},
        ],
      );
    }
    final (_, desktop) = await peers();
    final bridge = WorkspaceBridge(
      workspace: workspace,
      peer: desktop,
      device: () => const DeviceInfo(name: 'Mac', kind: 'mac', system: 'macOS'),
      bots: bots,
    );
    addTearDown(bridge.dispose);
    Future<Map<String, Object?>> call(
      String method, [
      Map<String, Object?> args = const {},
    ]) async =>
        await bridge.handle(method, {'bot': bot.id, ...args})
            as Map<String, Object?>;
    expect(
      bridge.state().botMemoryOptions,
      contains(LinkMethods.maintainBotMemorySkill),
    );
    final listed = await call(LinkMethods.botMemorySkills);
    expect(listed['project'], '/release');
    expect((listed['projects'] as List).single, containsPair('id', '/release'));
    final address = {'project': '/release', 'name': 'release-preflight'};
    final history = await call(LinkMethods.botMemorySkillRevisions, address);
    final versions = (history['revisions'] as List).cast<Map>();
    expect(versions.map((version) => version['revision']), [2, 1]);
    expect(versions.first['markdown'], contains('Check the version 2'));
    expect(jsonEncode(history), isNot(contains('internal-worker')));
    await expectLater(
      call(LinkMethods.maintainBotMemorySkill, {
        ...address,
        'revision': 1,
        'archived': true,
      }),
      throwsA(
        isA<LinkRemoteException>().having(
          (error) => error.code,
          'code',
          'stale',
        ),
      ),
    );
    await call(LinkMethods.maintainBotMemorySkill, {
      ...address,
      'revision': 2,
      'archived': true,
      'locked': true,
      'pinned': true,
    });
    expect((await call(LinkMethods.botMemorySkills))['skills'], isEmpty);
    final archived = await call(LinkMethods.botMemorySkills, {
      'includeArchived': true,
    });
    expect(
      (archived['skills'] as List).single,
      allOf(
        containsPair('revision', 3),
        containsPair('archived', true),
        containsPair('locked', true),
        containsPair('pinned', true),
      ),
    );
    await expectLater(
      call(LinkMethods.maintainBotMemorySkill, {
        ...address,
        'revision': 3,
        'archived': false,
      }),
      throwsA(isA<LinkRemoteException>()),
    );
    await call(LinkMethods.maintainBotMemorySkill, {
      ...address,
      'revision': 3,
      'locked': false,
    });
    await call(LinkMethods.maintainBotMemorySkill, {
      ...address,
      'revision': 4,
      'archived': false,
    });
    expect(
      ((await call(LinkMethods.botMemorySkills))['skills'] as List).single,
      containsPair('archived', false),
    );
    final group = bots.groups.save(name: 'Team', members: [bot.id]);
    await expectLater(
      call(LinkMethods.botMemorySkills, {'group': group.id}),
      throwsA(isA<LinkRemoteException>()),
    );
    await expectLater(
      call(LinkMethods.botMemorySkillRevisions, {
        ...address,
        'project': '/other',
      }),
      throwsA(isA<LinkRemoteException>()),
    );
    workspace.hideProject(workspace.projectAt('/release'));
    await expectLater(
      call(LinkMethods.botMemorySkills, {'project': '/release'}),
      throwsA(isA<LinkRemoteException>()),
    );
  });

  test('a bot\'s picture: sent with it, asked for, kept', () async {
    final workspace = Workspace();
    addTearDown(workspace.dispose);
    final bots = Bots(workspace: workspace, folders: MemoryBotFolders());
    await bots.start();
    addTearDown(bots.dispose);
    final (_, desktop) = await peers();
    final withBots = WorkspaceBridge(
      workspace: workspace,
      peer: desktop,
      device: () => const DeviceInfo(name: 'Mac', kind: 'mac', system: 'macOS'),
      bots: bots,
    );
    addTearDown(withBots.dispose);
    final jpeg = base64.encode([255, 216, 255, 1, 2, 3]);
    final made = (await withBots.handle(LinkMethods.saveBot, {
      'name': 'Mia',
      'identity': '',
      'abilities': <String>[],
      'avatarImage': {'data': jpeg, 'type': 'image/jpeg'},
    }) as Map)['bot'];
    final mia = LinkBot.fromJson(made as Map<String, Object?>);
    expect(mia.hasAvatarImage, isTrue);
    expect(mia.avatar, endsWith('.jpg'));
    expect(await withBots.handle(LinkMethods.botAvatar, {'bot': mia.id}), {
      'type': 'image/jpeg',
      'data': jpeg,
    });
    // Kept by its name as other things change.
    await withBots.handle(LinkMethods.saveBot, {
      'bot': mia.id,
      'name': 'Mia B.',
      'avatar': mia.avatar,
      'identity': '',
      'abilities': <String>[],
    });
    expect(bots.byId(mia.id)!.avatar, mia.avatar);
    // What is not a picture, or too large, is refused.
    for (final image in [
      {'data': jpeg, 'type': 'text/html'},
      {
        'data': base64.encode(List.filled(LinkLimits.avatar + 1, 0)),
        'type': 'image/png',
      },
    ]) {
      expect(
        withBots.handle(LinkMethods.saveBot, {
          'bot': mia.id,
          'name': 'Mia',
          'identity': '',
          'abilities': <String>[],
          'avatarImage': image,
        }),
        throwsA(isA<LinkRemoteException>()),
      );
    }
    // None for one with an emoji.
    expect(
      withBots.handle(LinkMethods.botAvatar, {'bot': 'assistant'}),
      throwsA(
        isA<LinkRemoteException>().having(
          (e) => e.code,
          'code',
          LinkErrors.notFound,
        ),
      ),
    );
  });

  test('a group: made, its messages sent and read, its new ones as they '
      'come to a phone that has it open', () async {
    final workspace = Workspace();
    addTearDown(workspace.dispose);
    final bots = Bots(workspace: workspace, folders: MemoryBotFolders());
    await bots.start();
    addTearDown(bots.dispose);
    bots.groups.tell = (_, _, _) {};
    final mia = bots.save(name: 'Mia', identity: '', abilities: {});
    final (phone, desktop) = await peers();
    final withBots = WorkspaceBridge(
      workspace: workspace,
      peer: desktop,
      device: () => const DeviceInfo(name: 'Mac', kind: 'mac', system: 'macOS'),
      bots: bots,
    )..start();
    addTearDown(withBots.dispose);
    final made = LinkGroup.fromJson(
      ((await withBots.handle(LinkMethods.saveGroup, {
                'name': '江湖',
                'members': ['assistant', mia.id],
                'gap': 30,
              }))!
              as Map)['group']
          as Map<String, Object?>,
    );
    expect(made.members, ['assistant', mia.id]);
    expect(made.gap, 30);
    expect(withBots.state().groups.single.name, '江湖');
    final png = base64.encode([137, 80, 78, 71]);
    final send = {
      'group': made.id,
      'text': ' 你们好 ',
      'images': [
        {'data': png, 'type': 'image/png'},
      ],
      'id': 'm1',
    };
    expect(await withBots.handle(LinkMethods.sendGroup, send), {'seq': 1});
    // Sent again, as when the link dropped: once.
    expect(await withBots.handle(LinkMethods.sendGroup, send), {'seq': 1});
    expect(withBots.state().groups.single.unread, 0);
    // The reply to Send follows the durable log write. Dispatch runs next.
    await settle();
    final room = withBots.state().groups.single;
    expect(['assistant', mia.id], contains(room.holder));
    expect(room.passesLeft, BotGroups.passes);
    final opened =
        (await withBots.handle(LinkMethods.openGroup, {'group': made.id}))!
            as Map;
    expect(opened['more'], isFalse);
    final first = LinkGroupMessage.fromJson(
      (opened['messages'] as List).single as Map<String, Object?>,
    );
    expect((first.text, first.mine), ('你们好', true));
    expect(
      await withBots.handle(LinkMethods.groupImage, {
        'group': made.id,
        'image': first.images.single,
      }),
      {'type': 'image/png', 'data': png},
    );
    // Mia told of it, and answers.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final came = phone.events
        .firstWhere((e) => e.name == LinkEvents.group)
        .timeout(const Duration(seconds: 5));
    bots.groups.turnEnded(made.id, mia.id, '<bot_say>嗨</bot_say>');
    final event = (await came).data! as Map;
    expect(event['group'], made.id);
    expect(
      [
        for (final m in event['messages'] as List)
          LinkGroupMessage.fromJson(m as Map<String, Object?>).from,
      ],
      [mia.id],
    );
    await withBots.handle(LinkMethods.deleteGroup, {'group': made.id});
    expect(withBots.state().groups, isEmpty);
  });

  test('a bot\'s files open from its chat: by their full path', () async {
    final workspace = Workspace();
    addTearDown(workspace.dispose);
    final bots = Bots(workspace: workspace, folders: MemoryBotFolders());
    await bots.start();
    addTearDown(bots.dispose);
    final (_, desktop) = await peers();
    final withBots = WorkspaceBridge(
      workspace: workspace,
      peer: desktop,
      device: () => const DeviceInfo(name: 'PC', kind: 'pc', system: 'Win'),
      bots: bots,
    );
    addTearDown(withBots.dispose);
    final folder = Directory.systemTemp.createTempSync('bot_files');
    addTearDown(() => folder.deleteSync(recursive: true));
    final pdf = File('${folder.path}/简历.pdf')
      ..writeAsBytesSync([37, 80, 68, 70, 0, 1, 2]);
    final notes = File('${folder.path}/notes.md')..writeAsStringSync('# Hi');
    // As its reply links them, though the bot is in no project.
    expect(
      await withBots.handle(LinkMethods.read, {
        'bot': 'assistant',
        'path': notes.path,
      }),
      containsPair('text', '# Hi'),
    );
    expect(
      await withBots.handle(LinkMethods.read, {
        'bot': 'assistant',
        'path': pdf.path,
      }),
      {'binary': true},
    );
    final download = await withBots.handle(LinkMethods.download, {
      'bot': 'assistant',
      'path': pdf.path,
    }) as Map;
    expect(base64.decode(download['data'] as String), pdf.readAsBytesSync());
    // In pieces, of any size: a stretch at a time from the disk.
    final video = File('${folder.path}/clip.mp4')
      ..writeAsBytesSync([
        for (var i = 0; i < LinkLimits.download + 3; i++) i % 256,
      ]);
    final inPieces = await withBots.handle(LinkMethods.download, {
      'bot': 'assistant',
      'path': video.path,
      'pieces': true,
    }) as LinkPieces;
    expect(inPieces.size, video.lengthSync());
    final parts = await inPieces.bytes.toList();
    expect(parts.every((p) => p.length <= LinkLimits.piece), isTrue);
    expect([for (final p in parts) ...p], video.readAsBytesSync());
    expect(
      withBots.handle(LinkMethods.download, {
        'bot': 'assistant',
        'path': '${folder.path}/none.mp4',
        'pieces': true,
      }),
      throwsA(isA<LinkRemoteException>()),
    );
    expect(
      withBots.handle(LinkMethods.read, {'bot': 'nobody', 'path': pdf.path}),
      throwsA(
        isA<LinkRemoteException>().having(
          (e) => e.code,
          'code',
          LinkErrors.notFound,
        ),
      ),
    );
  });

  test('the history index is private even without bot RPCs', () async {
    final root = Directory.systemTemp.createTempSync('bridge_data');
    final previous = DataDirectory.current;
    final data = DataDirectory(root.path);
    DataDirectory.current = data;
    addTearDown(() {
      DataDirectory.current = previous;
      root.deleteSync(recursive: true);
    });
    Directory(data.botHistoryIndexDir).createSync(recursive: true);
    File('${data.botHistoryIndexDir}/shard.json').writeAsStringSync('{}');
    File('${data.cacheDir}/ordinary.json').writeAsStringSync('{}');
    final workspace = Workspace(
      projects: [
        Project('Cache', data.cacheDir),
        Project('Private data', data.botHistoryIndexDir),
      ],
    );
    addTearDown(workspace.dispose);
    final (phone, desktop) = await peers();
    addTearDown(phone.close);
    final host = WorkspaceBridge(
      workspace: workspace,
      peer: desktop,
      device: () => const DeviceInfo(name: 'Mac', kind: 'mac', system: 'macOS'),
    );
    addTearDown(host.dispose);

    expect(host.state().projects.map((p) => p.id), [data.cacheDir]);
    final thread = workspace.startAgent(
      workspace.projectAt(data.botHistoryIndexDir),
    );
    await expectLater(
      host.handle(LinkMethods.sessionCommands, {
        'session': WorkspaceBridge.idOf(thread),
      }),
      throwsA(
        isA<LinkRemoteException>().having(
          (error) => error.code,
          'code',
          LinkErrors.notFound,
        ),
      ),
    );
    final folder = await host.handle(LinkMethods.folder, {
      'project': data.cacheDir,
    });
    expect(folder, {
      'folders': <Object?>[],
      'files': ['ordinary.json'],
    });
    expect(
      await host.handle(LinkMethods.files, {'project': data.cacheDir}),
      containsPair('paths', ['ordinary.json']),
    );
    expect(
      await host.handle(LinkMethods.read, {
        'project': data.cacheDir,
        'path': 'ordinary.json',
      }),
      containsPair('text', '{}'),
    );
    final shard = '${data.botHistoryIndexDir}/shard.json';
    if (!Platform.isWindows) {
      Link('${data.cacheDir}/alias.json').createSync(shard);
    }
    for (final path in [shard, if (!Platform.isWindows) 'alias.json']) {
      for (final pieces in [false, true]) {
        await expectLater(
          host.handle(LinkMethods.download, {
            'project': data.cacheDir,
            'path': path,
            'pieces': pieces,
          }),
          throwsA(
            isA<LinkRemoteException>().having(
              (error) => error.code,
              'code',
              LinkErrors.notFound,
            ),
          ),
        );
      }
    }
  });

  test('a file from the phone: kept for the agent, by its name', () async {
    final workspace = Workspace();
    addTearDown(workspace.dispose);
    final bots = Bots(workspace: workspace, folders: MemoryBotFolders());
    await bots.start();
    addTearDown(bots.dispose);
    final (_, desktop) = await peers();
    final uploads = Directory.systemTemp.createTempSync('phone_uploads');
    addTearDown(() => uploads.deleteSync(recursive: true));
    final withBots = WorkspaceBridge(
      workspace: workspace,
      peer: desktop,
      device: () => const DeviceInfo(name: 'PC', kind: 'pc', system: 'Win'),
      bots: bots,
      uploadsOf: (_, _) => '${uploads.path}/phone',
    );
    addTearDown(withBots.dispose);
    final bytes = [80, 75, 3, 4, 0, 1, 2];
    Future<Map> upload(String name) async => await withBots.handle(
      LinkMethods.upload,
      {'bot': 'assistant', 'name': name, 'data': base64.encode(bytes)},
    ) as Map;
    final first = (await upload('报价单.xlsx'))['path'] as String;
    expect(first, startsWith('${uploads.path}/phone/'));
    expect(first, endsWith('/报价单.xlsx'));
    expect(File(first).readAsBytesSync(), bytes);
    // The same name again: a folder of its own, the first one kept.
    final second = (await upload('报价单.xlsx'))['path'] as String;
    expect(second, isNot(first));
    expect(File(first).existsSync(), isTrue);
    expect(
      await withBots.handle(LinkMethods.upload, {
        'bot': 'assistant',
        'name': 'big.bin',
        'data': base64.encode(Uint8List(LinkLimits.upload + 1)),
      }),
      containsPair('tooLarge', true),
    );
  });

  test('a file from the phone in pieces: of any size', () async {
    final workspace = Workspace();
    addTearDown(workspace.dispose);
    final bots = Bots(workspace: workspace, folders: MemoryBotFolders());
    await bots.start();
    addTearDown(bots.dispose);
    final (phone, desktop) = await peers();
    final uploads = Directory.systemTemp.createTempSync('phone_uploads');
    addTearDown(() => uploads.deleteSync(recursive: true));
    final withBots = WorkspaceBridge(
      workspace: workspace,
      peer: desktop,
      device: () => const DeviceInfo(name: 'PC', kind: 'pc', system: 'Win'),
      bots: bots,
      uploadsOf: (_, _) => '${uploads.path}/phone',
    );
    addTearDown(withBots.dispose);
    desktop.onRequest = withBots.handle;
    final bytes = Uint8List.fromList([
      for (var i = 0; i < LinkLimits.upload + 5; i++) i % 253,
    ]);
    final answer = await phone.callWithPieces(
      LinkMethods.uploadPieces,
      {'bot': 'assistant', 'name': '录屏.mov'},
      bytes.length,
      Stream.fromIterable([
        Uint8List.sublistView(bytes, 0, 1000),
        Uint8List.sublistView(bytes, 1000),
      ]),
    ) as Map;
    final path = answer['path'] as String;
    expect(path, startsWith('${uploads.path}/phone/'));
    expect(path, endsWith('/录屏.mov'));
    expect(File(path).readAsBytesSync(), bytes);
    // Cut short: nothing of it left.
    final folders = uploads.listSync(recursive: true).whereType<File>().length;
    Stream<Uint8List> half() async* {
      yield Uint8List(10);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      throw const FileSystemException('gone');
    }

    await expectLater(
      phone.callWithPieces(
        LinkMethods.uploadPieces,
        {'bot': 'assistant', 'name': 'half.bin'},
        100,
        half(),
      ),
      throwsA(anything),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(
      uploads.listSync(recursive: true).whereType<File>(),
      hasLength(folders),
    );
  });

  test('a file from the phone keeps its name, not its folders', () {
    expect(WorkspaceBridge.uploadName('../../etc/passwd'), 'passwd');
    expect(WorkspaceBridge.uploadName(r'C:\x\a:b?.txt'), 'a_b_.txt');
    expect(WorkspaceBridge.uploadName('..'), 'file');
    expect(WorkspaceBridge.uploadName(null), 'file');
    expect(WorkspaceBridge.uploadName('合同 v2.docx'), '合同 v2.docx');
  });

  test('the plan\'s limits, as the phone reads them', () async {
    ClaudeCodeKernel.forgetAccount();
    addTearDown(ClaudeCodeKernel.forgetAccount);
    final opened = await open();
    expect(opened.quota, isNull);
    workspace.threads.first.session.send(const ComposerMessage(text: 'hi'));
    await settle();
    cli.push({
      'type': 'rate_limit_event',
      'rate_limit_info': {
        'status': 'allowed',
        'unifiedWindows': {
          'five_hour': {'utilization': 0.4, 'resetsAt': 4102444800},
          'seven_day': {'utilization': 1.0, 'resetsAt': 4102531200},
          'seven_day_opus': {'utilization': 0.25, 'resetsAt': 4102531200},
        },
      },
    });
    await settle();
    final quota = updates.last.quota!;
    expect(quota['provider'], isA<String>());
    expect(quota['back'], 4102531200000);
    expect((quota['accounts']! as List).single, {
      'windows': [
        {'minutes': 300, 'left': 60, 'resets': 4102444800000},
        {'minutes': 10080, 'left': 0, 'resets': 4102531200000},
        {'minutes': 10080, 'name': 'Opus', 'left': 75, 'resets': 4102531200000},
      ],
    });
  });
}

/// A phone's end and a desktop's, connected.
Future<(LinkPeer, LinkPeer)> peers({
  String? phoneId,
  LinkRequestHandler? onRequest,
}) async {
  final (a, b) = MemoryLinkConnection.pair(
    a: phoneId ?? LinkIdentity.generate().id,
    b: LinkIdentity.generate().id,
  );
  final accepted = LinkPeer.accept(b, onRequest: onRequest);
  final connected = await LinkPeer.connect(a);
  return (connected, await accepted);
}

/// Lists one kept session in the project.
class _KeptCatalog implements SessionCatalog {
  _KeptCatalog([this.kept]);

  final List<ProjectRecord>? kept;

  @override
  Future<List<ProjectRecord>> projects() async =>
      kept ??
      [
        ProjectRecord(
          path: '/p',
          sessions: [
            SessionRecord(
              id: 'k',
              title: 'kept',
              updatedAt: DateTime(2026),
              cwd: '/p',
            ),
          ],
        ),
      ];

  @override
  Future<List<SessionRecord>> sessionsIn(String cwd) async => const [];

  @override
  Future<void> delete(String id) async {}
}
