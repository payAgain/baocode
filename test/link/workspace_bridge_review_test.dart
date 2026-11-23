import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bao_link/bao_link.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/chat_session.dart';
import 'package:baocode/chat/review/change_review.dart';
import 'package:baocode/chat/review/review_store.dart'
    show ReviewBlob, ReviewStore;
import 'package:baocode/chat/review/review_store_io.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/kernel_types.dart' show KernelHealth;
import 'package:baocode/link/workspace_bridge.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'a published revision cannot undo a newer edit queued for review',
    () async {
      late final _GatedStore store;
      final host = await _Fixture.open(
        wrapStore: (base) => store = _GatedStore(base),
      );
      await host.edit(host.second, 'first edit\n');
      final change = (await host.changes()).values.single;
      await host.review.before(host.second.path);
      host.second.writeAsStringSync('other edit\n');
      final release = store.gate = Completer<void>();
      final edit = host.review.after(host.second.path);
      await store.entered.future;

      final undo = host.bridge.handle(LinkMethods.undo, {
        'session': 'review-session',
        'paths': [change['path']],
        'expectedChange': change['revision'],
      });
      release.complete();
      await expectLater(
        undo,
        throwsA(
          isA<LinkRemoteException>().having((e) => e.code, 'code', 'stale'),
        ),
      );
      await edit;
      expect(host.second.readAsStringSync(), 'other edit\n');
    },
  );

  test(
    'a second review write cannot succeed against the same revision',
    () async {
      final host = await _Fixture.open();
      await host.edit(host.second, 'second edit\n');
      final change = (await host.changes()).values.single;
      final params = {
        'paths': [change['path']],
        'expectedChange': change['revision'],
      };
      final first = host.call(LinkMethods.keep, params);
      final second = host.call(LinkMethods.keep, params);
      await Future.wait([
        expectLater(first, completion(isNull)),
        expectLater(
          second,
          throwsA(
            isA<LinkRemoteException>().having(
              (e) => e.code,
              'code',
              anyOf(LinkErrors.busy, 'stale'),
            ),
          ),
        ),
      ]);
      expect(host.second.readAsStringSync(), 'second edit\n');
    },
  );

  test(
    'undo reports conflict when the current file cannot be restored',
    () async {
      final host = await _Fixture.open();
      await host.edit(host.second, 'second edit\n');
      final change = (await host.changes()).values.single;
      host.second.writeAsStringSync('different external edit\n');
      await expectLater(
        host.call(LinkMethods.undo, {
          'paths': [change['path']],
          'expectedChange': change['revision'],
        }),
        throwsA(
          isA<LinkRemoteException>().having((e) => e.code, 'code', 'conflict'),
        ),
      );
      expect(host.second.readAsStringSync(), 'different external edit\n');
      expect(host.session.fileChanges.single.conflict, isTrue);
    },
  );

  test('a same-count replacement rejects a stale review revision', () async {
    final host = await _Fixture.open();
    await host.edit(host.second, 'first edit\n');
    final revision = (await host.changes()).values.single['revision'];
    await host.edit(host.second, 'other edit\n');
    await expectLater(
      host.call(LinkMethods.undo, {
        'paths': ['shared (2)/note.txt'],
        'expectedChange': revision,
      }),
      throwsA(
        isA<LinkRemoteException>().having((e) => e.code, 'code', 'stale'),
      ),
    );
    expect(host.second.readAsStringSync(), 'other edit\n');
  });

  test(
    'read returns both text sides for the selected named-root change',
    () async {
      final host = await _Fixture.open();
      await host.edit(host.second, 'second edit\n');
      final change = (await host.changes()).values.single;
      expect(change['preview'], isTrue);
      expect(
        await host.call(LinkMethods.read, {
          'path': change['path'],
          'expectedChange': change['revision'],
        }),
        {'original': 'original\n', 'text': 'second edit\n'},
      );
    },
  );

  test('undo reports unsupported for an untracked pending file', () async {
    final host = await _Fixture.open();
    host.review.report(
      FileChange(path: host.second.path, added: 1, removed: 0),
    );
    await host.review.look();
    final change = (await host.changes()).values.single;
    expect(change['undoable'], isFalse);
    await expectLater(
      host.call(LinkMethods.undo, {
        'paths': [change['path']],
      }),
      throwsA(
        isA<LinkRemoteException>().having(
          (e) => e.code,
          'code',
          LinkErrors.unsupported,
        ),
      ),
    );
    expect(host.second.readAsStringSync(), 'original\n');
  });

  test(
    'keep and undo resolve the advertised same-named workspace roots',
    () async {
      final host = await _Fixture.open();
      await host.edit(host.first, 'first edit\n');
      await host.edit(host.second, 'second edit\n');
      final changes = await host.changes();
      expect(
        changes.keys,
        unorderedEquals(['shared/note.txt', 'shared (2)/note.txt']),
      );

      await host.call(LinkMethods.keep, {
        'paths': ['shared (2)/note.txt'],
      });
      expect(host.session.fileChanges.map((change) => change.path), [
        host.first.path,
      ]);
      expect(host.second.readAsStringSync(), 'second edit\n');

      await host.call(LinkMethods.undo, {
        'paths': ['shared/note.txt'],
      });
      expect(host.session.fileChanges, isEmpty);
      expect(host.first.readAsStringSync(), 'original\n');
    },
  );
}

class _Fixture {
  _Fixture(
    this.session,
    this.bridge,
    this.peer,
    this.review,
    this.first,
    this.second,
  );

  final ChatSession session;
  final WorkspaceBridge bridge;
  final LinkPeer peer;
  final ChangeReview review;
  final File first;
  final File second;

  static Future<_Fixture> open({
    ReviewStore Function(ReviewStore)? wrapStore,
  }) async {
    final temp = await Directory.systemTemp.createTemp('baocode-link-review-');
    addTearDown(() => temp.delete(recursive: true));
    final root = await temp.resolveSymbolicLinks();
    final first = File('$root/first/shared/note.txt')
      ..createSync(recursive: true);
    final second = File('$root/second/shared/note.txt')
      ..createSync(recursive: true);
    first.writeAsStringSync('original\n');
    second.writeAsStringSync('original\n');
    final store = BlobReviewStore.open('$root/review');
    final review = ChangeReview(
      wrapStore?.call(store) ?? store,
      root: first.parent.path,
    );
    late final KernelDescriptor descriptor;
    descriptor = KernelDescriptor(
      id: 'fixture-review',
      label: 'Fixture review',
      icon: Icons.edit,
      description: '',
      create: (_) => _Kernel(descriptor),
    );
    final project = Project('Review fixture', first.parent.path);
    final session = ChatSession(
      kernel: descriptor,
      kernels: [descriptor],
      kernelContext: KernelContext(cwd: project.path),
      historyCount: 0,
      openReview: (_, {session}) async => review,
    )..attach();
    final workspace = _Workspace(project, _Thread(project, session));
    workspace.setAddedFolders(project.path, [second.parent.path]);
    final (clientWire, hostWire) = MemoryLinkConnection.pair(
      a: 'client',
      b: 'host',
    );
    final accepted = LinkPeer.accept(hostWire);
    final peer = await LinkPeer.connect(clientWire);
    final hostPeer = await accepted;
    final bridge = WorkspaceBridge(
      workspace: workspace,
      peer: hostPeer,
      device: () => const DeviceInfo(
        name: 'Fixture host',
        kind: 'desktop',
        system: 'test',
      ),
    );
    hostPeer.onRequest = bridge.handle;
    addTearDown(() async {
      peer.close();
      await hostPeer.done;
      bridge.dispose();
      workspace.dispose();
      session.dispose();
    });
    expect(session.changeReview, same(review));
    return _Fixture(session, bridge, peer, review, first, second);
  }

  Future<void> edit(File file, String text) async {
    await review.before(file.path);
    file.writeAsStringSync(text);
    await review.after(file.path);
  }

  Future<Object?> call(
    String method, [
    Map<String, Object?> params = const {},
  ]) => peer.call(method, {'session': 'review-session', ...params});

  Future<Map<String, Map<String, Object?>>> changes() async {
    final update = LinkSessionUpdate.fromJson(
      (await call(LinkMethods.open))! as Map<String, Object?>,
    );
    return {
      for (final change in update.changes) change['path']! as String: change,
    };
  }
}

class _Workspace extends Workspace {
  _Workspace(Project project, this.thread) : super(projects: [project]);

  final AgentThread thread;

  @override
  List<AgentThread> get threads => [thread];
}

class _Thread implements AgentThread {
  _Thread(this.project, this.session);

  @override
  Project project;
  @override
  final ChatSession session;
  @override
  String get id => 'review-session';
  @override
  bool get isOpen => true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Kernel with KernelEventSource implements AgentKernel {
  _Kernel(this.descriptor);

  @override
  final KernelDescriptor descriptor;
  @override
  String? get sessionId => null;
  @override
  KernelHealth get health => KernelHealth.ready;
  @override
  Future<void> get stopped async {}
  @override
  void prepare() {}
  @override
  void dispose() => closeEvents();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _GatedStore implements ReviewStore {
  _GatedStore(this.base);

  final ReviewStore base;
  final entered = Completer<void>();
  Completer<void>? gate;

  @override
  Future<ReviewBlob?> take(String path) async {
    if (gate case final locked?) {
      gate = null;
      entered.complete();
      await locked.future;
    }
    return base.take(path);
  }

  @override
  Future<ReviewBlob?> current(String path) => base.current(path);
  @override
  Future<Uint8List> read(ReviewBlob blob) => base.read(blob);
  @override
  Future<({int added, int removed})?> lineCounts(
    ReviewBlob? from,
    ReviewBlob? to,
  ) => base.lineCounts(from, to);
  @override
  Future<void> restore(String path, ReviewBlob? blob, {String? root}) =>
      base.restore(path, blob, root: root);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
