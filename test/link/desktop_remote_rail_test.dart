import 'dart:async';
import 'dart:io';

import 'package:bao_link/bao_link.dart';
import 'package:baocode/ide/file_service.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/link/desktop_host_chats.dart';
import 'package:baocode/link/desktop_remote_rail.dart';
import 'package:baocode/link/workspace_bridge.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _project = r'D:\fake\remote-project';
const _chat = DesktopHostChat(
  id: 'session-one',
  title: 'Project conversation',
  kind: 'project',
  projectId: _project,
);

void main() {
  testWidgets(
    'remote download asks for a destination before requesting bytes',
    (tester) async {
      final (client, host, calls) = await _pair(
        (method, params) => switch (method) {
          LinkMethods.folder => {
            'folders': [],
            'files': ['example.bin'],
          },
          LinkMethods.read => {'binary': true},
          LinkMethods.download => {'data': 'AQID'},
          _ => throw StateError(method),
        },
      );
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      const channel = MethodChannel('baocode/window');
      final messenger = tester.binding.defaultBinaryMessenger;
      final folder = Directory.systemTemp.createTempSync('bao-rail-test-');
      final target = File('${folder.path}/local.bin');
      final dialogs = <MethodCall>[];
      String? destination;
      messenger.setMockMethodCallHandler(channel, (call) async {
        dialogs.add(call);
        return destination;
      });
      try {
        await _mount(tester, client);
        await _click(
          tester,
          find.byKey(const ValueKey('desktop-remote-files-toggle')),
        );
        await _click(tester, find.text('example.bin'));
        expect(calls.map((call) => call.$1), [
          LinkMethods.folder,
          LinkMethods.read,
        ]);
        final download = find.byKey(const ValueKey('desktop-remote-download'));
        await _click(tester, download);
        expect(dialogs.single.method, 'pickSaveFile');
        expect(dialogs.single.arguments, {'name': 'example.bin'});
        expect(calls.map((call) => call.$1), [
          LinkMethods.folder,
          LinkMethods.read,
        ]);
        destination = target.path;
        await tester.runAsync(() async {
          await tester.tap(download);
          for (
            var i = 0;
            i < 50 && !(target.existsSync() && target.lengthSync() == 3);
            i++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            await tester.pump();
          }
        });
        await tester.pumpAndSettle();
        expect(calls.last.$1, LinkMethods.download);
        expect(calls.last.$2, {'project': _project, 'path': 'example.bin'});
        expect(target.readAsBytesSync(), [1, 2, 3]);
      } finally {
        await tester.pumpWidget(const SizedBox());
        messenger.setMockMethodCallHandler(channel, null);
        debugDefaultTargetPlatformOverride = null;
        folder.deleteSync(recursive: true);
        await client.close();
        await host.close();
      }
    },
  );

  testWidgets('a download reply after a conversation switch writes nothing', (
    tester,
  ) async {
    final reply = Completer<Object?>();
    final (client, host, calls) = await _pair(
      (method, _) => switch (method) {
        LinkMethods.folder => {
          'folders': [],
          'files': ['example.bin'],
        },
        LinkMethods.read => {'binary': true},
        LinkMethods.download => reply.future,
        _ => throw StateError(method),
      },
    );
    final directory = Directory.systemTemp.createTempSync('bao-rail-switch-');
    final destination = File('${directory.path}/local.bin')
      ..writeAsBytesSync([8]);
    const channel = MethodChannel('baocode/window');
    final messenger = tester.binding.defaultBinaryMessenger;
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    messenger.setMockMethodCallHandler(channel, (_) async => destination.path);
    try {
      await _mount(tester, client);
      await _click(
        tester,
        find.byKey(const ValueKey('desktop-remote-files-toggle')),
      );
      await _click(tester, find.text('example.bin'));
      await _click(
        tester,
        find.byKey(const ValueKey('desktop-remote-download')),
      );
      expect(calls.last.$1, LinkMethods.download);
      await _mount(
        tester,
        client,
        chat: const DesktopHostChat(
          id: 'session-two',
          title: 'Other project chat',
          kind: 'project',
          projectId: _project,
        ),
      );
      reply.complete({'data': 'CQ=='});
      await tester.pumpAndSettle();
      expect(destination.readAsBytesSync(), [8]);
      expect(find.text('File saved.'), findsNothing);
    } finally {
      await tester.pumpWidget(const SizedBox());
      messenger.setMockMethodCallHandler(channel, null);
      debugDefaultTargetPlatformOverride = null;
      directory.deleteSync(recursive: true);
      await client.close();
      await host.close();
    }
  });

  testWidgets('remote explorer docks beside a live chat and previews host text', (
    tester,
  ) async {
    const content =
        '[local](file:///no-such-dir/file)\n![external](https://example.invalid/image.png)';
    final (client, host, calls) = await _pair(
      (method, params) => switch ((method, params['path'])) {
        (LinkMethods.files, _) => {
          'paths': ['src/example.md'],
        },
        (LinkMethods.folder, '') => {
          'folders': ['src'],
          'files': ['z.txt'],
        },
        (LinkMethods.folder, 'src') => {
          'folders': <String>[],
          'files': ['example.md'],
        },
        (LinkMethods.read, 'src/example.md') => {'text': content},
        _ => throw const LinkRemoteException('unknown', 'unexpected call'),
      },
    );
    try {
      await _mount(tester, client);
      final input = find.byType(TextField);
      final pane = tester.state<EditableTextState>(find.byType(EditableText));
      await tester.enterText(input, 'unsent draft');
      final originalBounds = tester.getRect(input);
      expect(calls, isEmpty);

      await tester.tap(find.bySemanticsLabel('Files'));
      await tester.pumpAndSettle();
      final explorer = find.byKey(const ValueKey('desktop-remote-explorer'));
      expect(
        tester.getRect(input).right,
        lessThanOrEqualTo(tester.getRect(explorer).left),
      );
      expect(find.text('src'), findsOneWidget);
      expect(find.text('example.md'), findsNothing);
      await tester.tap(find.text('src'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('example.md'));
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (widget) => widget is SelectableText && widget.data == content,
        ),
        findsOneWidget,
      );
      expect(find.byType(Image), findsNothing);
      expect(
        calls.map((call) => [call.$1, call.$2]),
        equals([
          [
            LinkMethods.folder,
            {'project': _project, 'path': ''},
          ],
          [
            LinkMethods.folder,
            {'project': _project, 'path': 'src'},
          ],
          [
            LinkMethods.read,
            {'project': _project, 'path': 'src/example.md'},
          ],
        ]),
      );
      expect(input.hitTestable(), findsOneWidget);
      expect(tester.state(find.byType(EditableText).first), same(pane));
      expect(pane.widget.controller.text, 'unsent draft');
      await tester.tap(
        find.byKey(const ValueKey('desktop-remote-files-toggle')),
      );
      await tester.pumpAndSettle();
      expect(explorer, findsNothing);
      expect(tester.getRect(input), originalBounds);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await client.close();
      await host.close();
    }
  });

  testWidgets('an older host uses its flat project listing once', (
    tester,
  ) async {
    final (client, host, calls) = await _pair(
      (method, _) => switch (method) {
        LinkMethods.folder => throw const LinkRemoteException(
          LinkErrors.unknown,
          'old host',
        ),
        LinkMethods.files => {
          'paths': [
            'src/readme.txt',
            'src/readme.txt',
            '/absolute.txt',
            '../escaped.txt',
            r'C:\bad',
            'src/.. /bad.txt',
          ],
          'truncated': true,
        },
        LinkMethods.read => {'text': 'Remote project content'},
        _ => throw const LinkRemoteException('unknown', 'unexpected call'),
      },
    );
    try {
      await _mount(tester, client);
      await _click(
        tester,
        find.byKey(const ValueKey('desktop-remote-files-toggle')),
      );
      expect(find.text('src'), findsOneWidget);
      expect(find.text('escaped.txt'), findsNothing);
      expect(find.text('absolute.txt'), findsNothing);
      await _click(tester, find.text('src'));
      expect(find.text('.. '), findsNothing);
      await _click(tester, find.text('readme.txt'));
      expect(find.text('Remote project content'), findsOneWidget);
      expect(calls.map((call) => call.$1), [
        LinkMethods.folder,
        LinkMethods.files,
        LinkMethods.read,
      ]);
      expect(calls.last.$2, {'project': _project, 'path': 'src/readme.txt'});
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await client.close();
      await host.close();
    }
  });

  testWidgets('a late read is ignored after a chat or host switch', (
    tester,
  ) async {
    final reply = Completer<Object?>();
    final (client, host, calls) = await _pair(
      (method, _) => switch (method) {
        LinkMethods.folder => {
          'folders': [],
          'files': ['delayed.txt'],
        },
        LinkMethods.read => reply.future,
        _ => throw const LinkRemoteException('unknown', 'unexpected call'),
      },
    );
    final (nextClient, nextHost, nextCalls) = await _pair(
      (method, _) => switch (method) {
        LinkMethods.folder => {
          'folders': [],
          'files': ['other.txt'],
        },
        _ => throw const LinkRemoteException('unknown', 'unexpected call'),
      },
      remote: 'second-test-host',
    );
    const otherChat = DesktopHostChat(
      id: 'session-two',
      kind: 'project',
      title: 'Other conversation',
      projectId: _project,
    );
    final toggle = find.byKey(const ValueKey('desktop-remote-files-toggle'));
    final explorer = find.byKey(const ValueKey('desktop-remote-explorer'));
    try {
      await _mount(tester, client);
      await _click(tester, toggle);
      await _click(tester, find.text('delayed.txt'));
      expect(calls.last.$1, LinkMethods.read);
      await _mount(tester, client, chat: otherChat);
      expect(explorer, findsNothing);
      await _click(tester, toggle);
      expect(calls.last.$1, LinkMethods.folder);
      await _mount(tester, nextClient, chat: otherChat);
      expect(explorer, findsNothing);
      await _click(tester, toggle);
      reply.complete({'text': 'Old host file contents'});
      await tester.pumpAndSettle();
      expect(find.text('other.txt'), findsOneWidget);
      expect(find.text('delayed.txt'), findsNothing);
      expect(find.text('Old host file contents'), findsNothing);
      expect(nextCalls.single.$2, {'project': _project, 'path': ''});
    } finally {
      if (!reply.isCompleted) reply.complete({'text': ''});
      await tester.pumpWidget(const SizedBox.shrink());
      await client.close();
      await host.close();
      await nextClient.close();
      await nextHost.close();
    }
  });

  testWidgets('the real bridge previews only readable Windows project text', (
    tester,
  ) async {
    final workspace = Workspace(
      projects: const [Project('Synthetic', _project)],
    );
    final files = _WindowsFiles({
      p.windows.join(_project, 'lib', 'ruled-out.bin'):
          const IdeBinaryFileException('binary'),
      p.windows.join(_project, 'lib', 'huge.txt'):
          const IdeFileTooLargeException('huge', 999999),
      p.windows.join(_project, 'lib', 'removed.txt'):
          const IdeFileNotFoundException('removed'),
      p.windows.join(_project, 'lib', 'hello.txt'): 'Windows host content only',
      p.windows.join(_project, 'lib', 'empty.txt'): '',
    });
    late final WorkspaceBridge bridge;
    final (client, host, calls) = await _pair(
      (method, params) => bridge.handle(method, params),
    );
    bridge = WorkspaceBridge(
      workspace: workspace,
      peer: host,
      device: () => const DeviceInfo(
        name: 'Synthetic',
        kind: 'windows',
        system: 'Windows',
      ),
      filesOf: (_) => (files: files, paths: p.windows),
      reachHost: (_) async {},
    );
    try {
      await _mount(tester, client);
      await _click(tester, find.bySemanticsLabel('Files'));
      await _click(tester, find.text('lib'));
      for (final (file, message) in [
        ('ruled-out.bin', englishLocalizations.placeholderBinary),
        ('huge.txt', englishLocalizations.placeholderTooLarge('999999')),
        ('removed.txt', englishLocalizations.placeholderNotFound),
      ]) {
        await _click(tester, find.text(file));
        expect(find.text(message), findsOneWidget);
        expect(find.byType(SelectableText), findsNothing);
        expect(find.text('Read-only'), findsOneWidget);
      }
      await _click(tester, find.text('hello.txt'));
      expect(find.text('Windows host content only'), findsOneWidget);
      await _click(tester, find.text('empty.txt'));
      expect(
        tester.widget<SelectableText>(find.byType(SelectableText)).data,
        isEmpty,
      );
      expect(
        calls
            .where((call) => call.$1 == LinkMethods.read)
            .map((call) => call.$2['path']),
        everyElement(startsWith('lib/')),
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      bridge.dispose();
      workspace.dispose();
      await client.close();
      await host.close();
    }
  });

  testWidgets(
    'compact layout docks below the chat and hides the rail for other kinds',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(430, 480);
      addTearDown(tester.view.reset);
      final (client, host, calls) = await _pair(
        (method, _) => switch (method) {
          LinkMethods.folder => {
            'folders': [],
            'files': ['example.md'],
          },
          LinkMethods.read => {'text': 'Compact preview'},
          _ => throw const LinkRemoteException('unknown', 'unexpected call'),
        },
      );
      try {
        await _mount(tester, client);
        final input = find.byType(TextField);
        final editor = tester.state<EditableTextState>(
          find.byType(EditableText),
        );
        await tester.enterText(input, 'compact draft');
        await _click(tester, find.bySemanticsLabel('Files'));
        await _click(tester, find.text('example.md'));
        final explorer = find.byKey(const ValueKey('desktop-remote-explorer'));
        expect(
          tester.getRect(input).bottom,
          lessThanOrEqualTo(tester.getRect(explorer).top),
        );
        expect(find.text('Compact preview'), findsOneWidget);
        expect(input.hitTestable(), findsOneWidget);
        expect(editor.widget.controller.text, 'compact draft');
        for (final kind in ['bot', 'group']) {
          await _mount(
            tester,
            client,
            chat: DesktopHostChat(
              id: kind,
              title: kind,
              kind: kind,
              projectId: _project,
            ),
          );
          expect(
            find.byKey(const ValueKey('desktop-remote-files-toggle')),
            findsNothing,
          );
          expect(explorer, findsNothing);
        }
        expect(calls.map((call) => call.$1), [
          LinkMethods.folder,
          LinkMethods.read,
        ]);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await client.close();
        await host.close();
      }
    },
  );
}

Future<void> _click(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _mount(
  WidgetTester tester,
  LinkPeer peer, {
  DesktopHostChat chat = _chat,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: DesktopRemoteRail(
        peer: peer,
        chat: chat,
        child: const Align(
          alignment: Alignment.bottomCenter,
          child: TextField(),
        ),
      ),
    ),
  ),
);

typedef _Call = (String, Map<String, Object?>);

Future<(LinkPeer, LinkPeer, List<_Call>)> _pair(
  LinkRequestHandler handle, {
  String remote = 'test-windows-host',
}) async {
  final calls = <_Call>[];
  final (localConnection, hostConnection) = MemoryLinkConnection.pair(
    a: 'test-desktop',
    b: remote,
  );
  final accepting = LinkPeer.accept(
    hostConnection,
    onRequest: (method, params) {
      calls.add((method, params));
      return handle(method, params);
    },
  );
  final client = await LinkPeer.connect(localConnection);
  return (client, await accepting, calls);
}

class _WindowsFiles implements IdeFileService {
  _WindowsFiles(this.contents);

  final Map<String, Object> contents;

  @override
  Future<List<IdeFile>> list(String directory) async {
    final entries = <String, bool>{};
    for (final fullPath in contents.keys) {
      if (!p.windows.isWithin(directory, fullPath)) continue;
      final parts = p.windows.split(
        p.windows.relative(fullPath, from: directory),
      );
      entries[parts.first] = parts.length > 1;
    }
    return [
      for (final MapEntry(key: name, value: folder) in entries.entries)
        IdeFile(p.windows.join(directory, name), name, isDirectory: folder),
    ];
  }

  @override
  Future<String> read(String path, {bool force = false}) async =>
      switch (contents[path]) {
        final String text => text,
        final Exception error => throw error,
        _ => throw IdeFileNotFoundException(path),
      };

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}
