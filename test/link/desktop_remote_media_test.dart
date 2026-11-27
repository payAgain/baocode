import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bao_link/bao_link.dart';
import 'package:bao_markdown/bao_markdown.dart';
import 'package:baocode/chat/composer/suggestion_menu.dart';
import 'package:baocode/chat/widgets/image_thumbnails.dart';
import 'package:baocode/link/desktop_host_chats.dart';
import 'package:baocode/link/desktop_host_composer.dart';
import 'package:baocode/link/desktop_remote_media.dart';
import 'package:baocode/link/desktop_remote_media_preview.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a8uoAAAAASUVORK5CYII=';
const _project = DesktopHostChat(
  id: 's1',
  title: 'Project chat',
  kind: 'project',
  projectId: '/host-project',
);
const _group = DesktopHostChat(id: 'g1', title: 'Group', kind: 'group');
const _dm = DesktopHostChat(id: 'bot1', title: 'Bot', kind: 'bot');
const _window = MethodChannel('baocode/window');

void main() {
  testWidgets('DM upload sends only the picked file and names the host copy', (
    tester,
  ) async {
    final (client, host, calls) = (await tester.runAsync(
      () => _pair((method, params) async {
        expect(method, LinkMethods.uploadPieces);
        final pieces = LinkPeer.piecesOf(params)!;
        expect(pieces.size, 3);
        expect(await pieces.bytes.expand((piece) => piece).toList(), [1, 2, 3]);
        return {'path': r'D:\bot-store\uploads\remote report.txt'};
      }),
    ))!;
    final sent = <DesktopRemoteAttachments>[];
    final folder = Directory.systemTemp.createTempSync('bao-upload-test-');
    final source = File('${folder.path}/local report.txt')
      ..writeAsBytesSync([1, 2, 3]);
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final messenger = tester.binding.defaultBinaryMessenger;
    List<String>? answer;
    messenger.setMockMethodCallHandler(_window, (call) async {
      expect(call.method, 'pickOpenFiles');
      expect(call.arguments, {'multiple': false});
      return answer;
    });
    try {
      await _mountComposer(tester, client, _dm, (text, attachments) async {
        expect(text.trim(), r'@"D:\bot-store\uploads\remote report.txt"');
        sent.add(attachments);
        return false;
      });
      await _tap(tester, 'desktop-remote-upload');
      expect(calls, isEmpty);
      answer = [source.path];
      final controller = tester
          .widget<MarkdownEditor>(find.byType(MarkdownEditor))
          .controller;
      // The picker and disk reads use the real clock. Pump the widget clock
      // separately so the in-memory peer can deliver the chunked requests.
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('desktop-remote-upload')));
      });
      for (var i = 0; i < 50 && controller.text.isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(
        controller.text.trim(),
        r'@"D:\bot-store\uploads\remote report.txt"',
      );
      expect(calls.single.$1, LinkMethods.uploadPieces);
      expect(calls.single.$2, {
        'bot': 'bot1',
        'name': 'local report.txt',
        'size': 3,
        r'$pieces': isA<LinkPieces>(),
      });
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
      expect(
        sent.single.mentions.single.path,
        r'D:\bot-store\uploads\remote report.txt',
      );
    } finally {
      await tester.pumpWidget(const SizedBox());
      messenger.setMockMethodCallHandler(_window, null);
      debugDefaultTargetPlatformOverride = null;
      folder.deleteSync(recursive: true);
      await client.close();
      await host.close();
    }
  });

  test('upload falls back only for a small file on an older host', () async {
    final folder = Directory.systemTemp.createTempSync('bao-upload-compat-');
    addTearDown(() => folder.deleteSync(recursive: true));
    final source = File('${folder.path}/report.bin')
      ..writeAsBytesSync([1, 2, 3]);
    _mockFilePicker((_) async => [source.path]);
    var code = LinkErrors.unknown;
    const uploaded = '/host/uploads/report.bin';
    final (client, host, calls) = await _pair((method, _) {
      if (method == LinkMethods.uploadPieces) {
        throw LinkRemoteException(code, 'Upload rejected');
      }
      expect(method, LinkMethods.upload);
      return {'path': uploaded};
    });
    addTearDown(client.close);
    addTearDown(host.close);
    Future<DesktopRemoteMention?> upload() => uploadRemoteFile(
      target: (client, 'project', _project.id, _project.projectId),
      isCurrent: () => true,
    );
    expect((await upload())!.path, uploaded);
    expect(calls.map((call) => call.$1), [
      LinkMethods.uploadPieces,
      LinkMethods.upload,
    ]);
    expect(calls.last.$2, {
      'project': _project.projectId,
      'name': 'report.bin',
      'data': 'AQID',
    });

    calls.clear();
    code = 'failed';
    await expectLater(upload(), throwsA(isA<LinkRemoteException>()));
    expect(calls.single.$1, LinkMethods.uploadPieces);

    calls.clear();
    code = LinkErrors.unknown;
    final handle = source.openSync(mode: FileMode.append);
    handle.truncateSync(LinkLimits.upload + 1);
    handle.closeSync();
    await expectLater(upload(), throwsA(isA<RemoteMediaTooLarge>()));
    expect(calls.single.$1, LinkMethods.uploadPieces);
  });

  test(
    'download accepts legacy bytes and only commits complete pieces',
    () async {
      final folder = Directory.systemTemp.createTempSync(
        'bao-download-pieces-',
      );
      addTearDown(() => folder.deleteSync(recursive: true));
      final destination = File('${folder.path}/local.bin')
        ..writeAsBytesSync([0]);
      _mockFilePicker((call) async {
        expect(call.method, 'pickSaveFile');
        expect(call.arguments, {'name': 'report.bin'});
        return destination.path;
      });
      var current = true;
      Object? response = {'data': 'AQID'};
      final (client, host, calls) = await _pair((method, _) => response);
      addTearDown(client.close);
      addTearDown(host.close);
      Future<bool> download() => downloadRemoteFile(
        peer: client,
        project: _project.projectId!,
        path: 'files/report.bin',
        isCurrent: () => current,
      );
      expect(await download(), isTrue);
      expect(calls.single.$1, LinkMethods.download);
      expect(calls.single.$2, {
        'project': _project.projectId,
        'path': 'files/report.bin',
        'pieces': true,
      });
      expect(destination.readAsBytesSync(), [1, 2, 3]);

      final first = Uint8List(LinkLimits.download)..[0] = 4;
      response = LinkPieces(
        first.length + 1,
        Stream.fromIterable([
          first,
          Uint8List.fromList([5]),
        ]),
      );
      expect(await download(), isTrue);
      final saved = destination.readAsBytesSync();
      expect(saved.length, first.length + 1);
      expect([saved.first, saved.last], [4, 5]);

      response = LinkPieces(2, Stream.value(Uint8List.fromList([6])));
      await expectLater(download(), throwsA(anything));
      expect(destination.lengthSync(), saved.length);
      expect(folder.listSync().map((entry) => entry.path), [destination.path]);

      Stream<Uint8List> stale() async* {
        current = false;
        yield Uint8List.fromList([7]);
      }

      response = LinkPieces(1, stale());
      expect(await download(), isFalse);
      expect(destination.lengthSync(), saved.length);
      expect(folder.listSync().map((entry) => entry.path), [destination.path]);
    },
  );

  testWidgets(
    'only a clicked relative Markdown image is fetched from the host',
    (tester) async {
      final (client, host, calls) = await _pair(
        (method, _) => {'type': 'image/png', 'data': _png},
      );
      try {
        final images = DesktopRemoteImage.message(
          markdown: '''
![relative](assets/example.png)
![web](https://host.invalid/secret.png)
![absolute](/private/local.png)
![traversal](../other.png)
`![literal](lit.png)`
''',
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: DesktopRemoteMessageImages(
                peer: client,
                chat: _project,
                images: images,
                child: const Text('message'),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(calls, isEmpty);
        expect(find.byType(TextButton), findsOneWidget);
        await tester.runAsync(() async {
          await tester.tap(find.byType(TextButton));
          for (var i = 0; i < 40 && !find.byType(Image).tryEvaluate(); i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            await tester.pump();
          }
        });
        await tester.pumpAndSettle();
        expect(calls.single.$1, LinkMethods.image);
        expect(calls.single.$2, {
          'project': _project.projectId,
          'path': 'assets/example.png',
        });
        expect(find.byType(Image), findsOneWidget);
        expect(
          tester.widget<Image>(find.byType(Image)).image,
          isA<ResizeImage>(),
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        await client.close();
        await host.close();
      }
    },
  );

  testWidgets('project listing inserts only an explicitly selected mention', (
    tester,
  ) async {
    final (client, host, calls) = await _pair(
      (method, _) => switch (method) {
        LinkMethods.files => {
          'paths': [
            'src/hello.dart',
            'My Docs/notes.md',
            '../escape.png',
            '/secret.txt',
          ],
        },
        _ => throw StateError(method),
      },
    );
    final sent = <(String, DesktopRemoteAttachments)>[];
    try {
      await _mountComposer(tester, client, _project, (text, attachments) async {
        sent.add((text, attachments));
        return false;
      });
      expect(calls, isEmpty);
      await _tap(tester, 'desktop-remote-mention');
      expect(calls.single.$1, LinkMethods.files);
      expect(calls.single.$2, {'project': _project.projectId});
      expect(find.text('../escape.png'), findsNothing);
      expect(find.text('/secret.txt'), findsNothing);
      await tester.tap(find.text('My Docs/notes.md'));
      await tester.pumpAndSettle();
      final editor = tester.widget<MarkdownEditor>(find.byType(MarkdownEditor));
      expect(editor.controller.text.trim(), '@"My Docs/notes.md"');
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
      expect(sent.single.$2.mentions.map((m) => m.path), ['My Docs/notes.md']);
      expect(editor.controller.text.trim(), '@"My Docs/notes.md"');
      editor.controller.replace(0, editor.controller.length, '@../escape.png');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
      expect(sent, hasLength(1)); // no attachment-qualified send for plain text
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await client.close();
      await host.close();
    }
  });

  testWidgets(
    'typed project mentions use the caret and send an approved reference',
    (tester) async {
      final (client, host, calls) = await _pair(
        (method, _) => switch (method) {
          LinkMethods.files => {
            'paths': ['src/hello.dart', 'My Docs/notes.md', '../notes.md'],
          },
          _ => throw StateError(method),
        },
      );
      final sent = <(String, DesktopRemoteAttachments)>[];
      try {
        await _mountComposer(tester, client, _project, (
          text,
          attachments,
        ) async {
          sent.add((text, attachments));
          return true;
        });
        await tester.tap(_composerEditor);
        await tester.pump();
        await _typeDraft(tester, 'user@notes');
        expect(calls, isEmpty);
        await _typeDraft(tester, 'Read @ with context', caret: 'Read @'.length);
        expect(_suggestion('src/hello.dart'), findsOneWidget);
        await _typeDraft(
          tester,
          'Read @notes with context',
          caret: 'Read @notes'.length,
        );
        expect(calls.single.$1, LinkMethods.files);
        expect(calls.single.$2, {'project': _project.projectId});
        expect(_suggestion('src/hello.dart'), findsNothing);
        expect(_suggestion('../notes.md'), findsNothing);
        expect(
          tester.getBottomLeft(_suggestion('My Docs/notes.md')).dy,
          lessThan(tester.getTopLeft(_composerEditor).dy),
        );
        await tester.tap(_suggestion('My Docs/notes.md'));
        await tester.pumpAndSettle();
        const expected = 'Read @"My Docs/notes.md" with context';
        expect(_composerDraft(tester).text, expected);
        expect(
          _composerDraft(tester).selection.baseOffset,
          'Read @"My Docs/notes.md" '.length,
        );
        expect(sent, isEmpty);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(sent.single.$1, expected);
        expect(sent.single.$2.mentions.single.path, 'My Docs/notes.md');
      } finally {
        await tester.pumpWidget(const SizedBox());
        await client.close();
        await host.close();
      }
    },
  );

  testWidgets('typed commands are session-scoped and send as ordinary text', (
    tester,
  ) async {
    final (client, host, calls) = await _pair(
      (method, _) => switch (method) {
        LinkMethods.sessionCommands => {
          'commands': [
            {
              'name': 'review',
              'description': 'Review changes',
              'argumentHint': '[path]',
            },
            {'name': 'rewind', 'description': 'Rewind changes'},
            {'name': 'help'},
            {'name': 'btw'},
            {'name': 'fork'},
          ],
        },
        _ => throw StateError(method),
      },
    );
    final sent = <String>[];
    try {
      await tester.binding.setSurfaceSize(const Size(640, 300));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _mountComposer(
        tester,
        client,
        _project,
        (_, _) async => throw StateError('Expected an ordinary send'),
        plainSend: (text) async {
          sent.add(text);
          return true;
        },
      );
      await tester.tap(_composerEditor);
      await tester.pump();
      await _typeDraft(tester, 'Path /re');
      expect(calls, isEmpty);
      await _typeDraft(tester, '/');
      expect(_suggestion('/help'), findsOneWidget);
      expect(_suggestion('/btw'), findsNothing);
      expect(_suggestion('/fork'), findsNothing);
      await _typeDraft(tester, '/re');
      expect(_suggestion('/help'), findsNothing);
      expect(_suggestion('[path]  Review changes'), findsOneWidget);
      expect(calls.single.$1, LinkMethods.sessionCommands);
      expect(calls.single.$2, {'session': _project.id});
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(sent, isEmpty);
      expect(_composerDraft(tester).text, '/rewind ');
      expect(find.byType(SuggestionMenu), findsNothing);
      await _typeDraft(tester, '/rewind src');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(sent, ['/rewind src']);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await client.close();
      await host.close();
    }
  });

  testWidgets('commands stay plain on old hosts and non-project chats', (
    tester,
  ) async {
    final (client, host, calls) = await _pair((_, _) {
      throw const LinkRemoteException('unknown', 'Unknown request');
    });
    final sent = <String>[];
    try {
      for (final chat in [_project, _dm, _group]) {
        await _mountComposer(
          tester,
          client,
          chat,
          (_, _) async => throw StateError('Expected an ordinary send'),
          plainSend: (text) async {
            sent.add(text);
            return true;
          },
        );
        await tester.tap(_composerEditor);
        await tester.pump();
        if (chat != _project) await _typeDraft(tester, '@');
        await _typeDraft(tester, '/custom');
        expect(find.byType(SuggestionMenu), findsNothing);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
      }
      expect(calls.single.$1, LinkMethods.sessionCommands);
      expect(calls.single.$2, {'session': _project.id});
      expect(sent, List.filled(3, '/custom'));
    } finally {
      await tester.pumpWidget(const SizedBox());
      await client.close();
      await host.close();
    }
  });

  testWidgets('IME, Escape, and a target switch guard pending completion', (
    tester,
  ) async {
    const other = DesktopHostChat(
      id: 's2',
      title: 'Another chat',
      kind: 'project',
      projectId: '/other',
    );
    final files = Completer<Object?>();
    final commands = Completer<Object?>();
    final (client, host, calls) = await _pair(
      (method, params) => switch (method) {
        LinkMethods.files => files.future,
        LinkMethods.sessionCommands when params['session'] == _project.id =>
          commands.future,
        LinkMethods.sessionCommands => {
          'commands': [
            {'name': 'help'},
          ],
        },
        _ => throw StateError(method),
      },
    );
    Future<bool> send(String _, DesktopRemoteAttachments _) async => false;
    try {
      await _mountComposer(tester, client, _project, send);
      await tester.tap(_composerEditor);
      await tester.pump();
      const composing = TextRange(start: 1, end: 2);
      await _typeDraft(tester, '@n', composing: composing);
      expect(calls, isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(_composerDraft(tester).text, '@n');
      await _typeDraft(
        tester,
        '@n',
      ); // IME commit with no text or caret change.
      expect(calls.single.$1, LinkMethods.files);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _typeDraft(tester, '@notes');
      files.complete({
        'paths': ['notes.md'],
      });
      await tester.pumpAndSettle();
      expect(calls, hasLength(1));
      expect(find.byType(SuggestionMenu), findsNothing);
      expect(_composerDraft(tester).text, '@notes');

      await _typeDraft(tester, '/');
      expect(calls.last.$2, {'session': _project.id});
      await _mountComposer(tester, client, other, send);
      await _typeDraft(tester, '/h');
      expect(calls.last.$2, {'session': other.id});
      expect(_suggestion('/help'), findsOneWidget);
      commands.complete({
        'commands': [
          {'name': 'history'},
        ],
      });
      await tester.pumpAndSettle();
      expect(_suggestion('/history'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(_composerDraft(tester).text, '/help ');
    } finally {
      await tester.pumpWidget(const SizedBox());
      await client.close();
      await host.close();
    }
  });

  testWidgets('remote composer pastes images and falls back to plain text', (
    tester,
  ) async {
    final (client, host, _) = await _pair(
      (method, _) => throw StateError(method),
    );
    final messenger = tester.binding.defaultBinaryMessenger;
    final sent = <(String, DesktopRemoteAttachments)>[];
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    var hasImage = true;
    messenger.setMockMethodCallHandler(_window, (call) async {
      expect(call.method, 'readPasteboardImages');
      return hasImage
          ? [
              {'bytes': base64Decode(_png), 'type': 'image/png'},
            ]
          : [];
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      return call.method == 'Clipboard.getData' && !hasImage
          ? {'text': 'plain paste'}
          : null;
    });
    try {
      await _mountComposer(tester, client, _group, (text, attachments) async {
        sent.add((text, attachments));
        return true;
      });
      final finder = find.byType(MarkdownEditor);
      await tester.tap(finder);
      await tester.pump();
      final editor = tester.state<MarkdownEditorState>(finder);
      const selection = TextSelection(baseOffset: 5, extentOffset: 1);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(text: 'before', selection: selection),
      );
      await tester.pump();
      tester.testTextInput.log.clear();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
      expect(
        tester.widget<ImageThumbnail>(find.byType(ImageThumbnail)).image.name,
        'image.png',
      );
      expect(find.byType(InputChip), findsNothing);
      expect(tester.state<MarkdownEditorState>(finder), same(editor));
      expect(editor.controller.selection, selection);
      expect(tester.widget<MarkdownEditor>(finder).focusNode!.hasFocus, isTrue);
      expect(tester.testTextInput.hasAnyClients, isTrue);
      expect(
        tester.testTextInput.log.map((call) => call.method),
        isNot(contains('TextInput.clearClient')),
      );
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'typed after paste',
          selection: TextSelection.collapsed(offset: 17),
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(sent.single.$1, 'typed after paste');
      expect(sent.single.$2.images.single.toWire(), {
        'name': 'image.png',
        'type': 'image/png',
        'data': _png,
      });
      expect(find.byType(ImageThumbnail), findsNothing);

      expect(tester.state<MarkdownEditorState>(finder), same(editor));
      expect(tester.testTextInput.hasAnyClients, isTrue);
      hasImage = false;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
      expect(
        tester.widget<MarkdownEditor>(finder).controller.text,
        'plain paste',
      );
    } finally {
      await tester.pumpWidget(const SizedBox());
      messenger.setMockMethodCallHandler(_window, null);
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      debugDefaultTargetPlatformOverride = null;
      await client.close();
      await host.close();
    }
  });

  testWidgets('chooser-bound group image can be sent without text', (
    tester,
  ) async {
    final (client, host, calls) = await _pair(
      (method, params) => switch (method) {
        LinkMethods.state => const LinkState(
          device: DeviceInfo(name: 'Host', kind: 'mac', system: 'macOS'),
          groups: [LinkGroup(id: 'g1', name: 'Group', members: [])],
        ).toJson(),
        LinkMethods.openGroup => {'messages': [], 'more': false},
        LinkMethods.sendGroup => {'seq': 1},
        LinkMethods.closeGroup => null,
        _ => throw StateError(method),
      },
    );
    final chats = DesktopHostChats()..bind(client);
    final folder = Directory.systemTemp.createTempSync('bao-media-test-');
    final source = File('${folder.path}/fixture.png')
      ..writeAsBytesSync(base64Decode(_png));
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_window, (call) async {
      expect(call.method, 'pickOpenFiles');
      return [source.path];
    });
    try {
      await tester.pump();
      await chats.open(chats.chats.single);
      await _mountComposer(
        tester,
        client,
        _group,
        (text, attachments) => chats.sendWithAttachments(text, attachments),
      );
      expect(find.byKey(const ValueKey('desktop-remote-upload')), findsNothing);
      await tester.runAsync(() async {
        await tester.tap(
          find.byKey(const ValueKey('desktop-remote-attach-image')),
        );
        for (
          var i = 0;
          i < 30 && !find.byType(ImageThumbnail).tryEvaluate();
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          await tester.pump();
        }
      });
      await tester.pumpAndSettle();
      expect(find.byType(ImageThumbnail), findsOneWidget);
      expect(calls.map((c) => c.$1), [
        LinkMethods.state,
        LinkMethods.openGroup,
      ]);
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
      expect(calls.last.$1, LinkMethods.sendGroup);
      expect(calls.last.$2, {
        'group': 'g1',
        'text': '',
        'id': isA<String>(),
        'images': [
          {'type': 'image/png', 'data': _png, 'name': 'fixture.png'},
        ],
      });
      expect(find.byType(ImageThumbnail), findsNothing);
    } finally {
      await tester.pumpWidget(const SizedBox());
      chats.dispose();
      messenger.setMockMethodCallHandler(_window, null);
      debugDefaultTargetPlatformOverride = null;
      folder.deleteSync(recursive: true);
      await client.close();
      await host.close();
    }
  });

  testWidgets('group thumbnail loading discards a late response on switch', (
    tester,
  ) async {
    final delayed = Completer<Object?>();
    final (client, host, calls) = await _pair(
      (method, params) => delayed.future,
    );
    Future<void> mount(DesktopHostChat chat, List<DesktopRemoteImage> images) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: DesktopRemoteMessageImages(
                peer: client,
                chat: chat,
                images: images,
                child: const Text('message'),
              ),
            ),
          ),
        );
    try {
      await mount(
        _group,
        DesktopRemoteImage.group(['7-0.png', '../other.png']),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsNothing);
      expect(find.byType(TextButton), findsNothing);
      expect(calls.single.$1, LinkMethods.groupImage);
      expect(calls.single.$2, {'group': 'g1', 'image': '7-0.png'});
      await mount(_dm, const []);
      delayed.complete({'type': 'image/png', 'data': _png});
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsNothing);
      expect(find.byType(TextButton), findsNothing);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await client.close();
      await host.close();
    }
  });
}

void _mockFilePicker(Future<Object?> Function(MethodCall) handler) {
  debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
  final messenger =
      TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_window, handler);
  addTearDown(() {
    messenger.setMockMethodCallHandler(_window, null);
    debugDefaultTargetPlatformOverride = null;
  });
}

Future<void> _tap(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
}

final _composerEditor = find.byType(MarkdownEditor);

Finder _suggestion(String text) => find.descendant(
  of: find.byType(SuggestionMenu),
  matching: find.text(text, findRichText: true),
);

MarkdownController _composerDraft(WidgetTester tester) =>
    tester.widget<MarkdownEditor>(_composerEditor).controller;

Future<void> _typeDraft(
  WidgetTester tester,
  String text, {
  int? caret,
  TextRange composing = TextRange.empty,
}) async {
  tester.testTextInput.updateEditingValue(
    TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: caret ?? text.length),
      composing: composing,
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _mountComposer(
  WidgetTester tester,
  LinkPeer peer,
  DesktopHostChat chat,
  Future<bool> Function(String, DesktopRemoteAttachments) send, {
  Future<bool> Function(String)? plainSend,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: DesktopHostComposer(
          initialDraft: DesktopHostDraft(''),
          busy: false,
          placeholder: 'Message',
          sendLabel: 'Send',
          onChanged: (_) {},
          onSend: plainSend ?? (_) async => false,
          peer: peer,
          chat: chat,
          onSendWithAttachments: send,
        ),
      ),
    ),
  ),
);

Future<(LinkPeer, LinkPeer, List<(String, Map<String, Object?>)>)> _pair(
  LinkRequestHandler handler,
) async {
  final calls = <(String, Map<String, Object?>)>[];
  final (a, b) = MemoryLinkConnection.pair(a: 'media-client', b: 'media-host');
  final accept = LinkPeer.accept(
    b,
    onRequest: (method, params) {
      calls.add((method, params));
      return handler(method, params);
    },
  );
  return (await LinkPeer.connect(a), await accept, calls);
}
