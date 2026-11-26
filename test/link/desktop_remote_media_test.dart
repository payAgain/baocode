import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bao_link/bao_link.dart';
import 'package:bao_markdown/bao_markdown.dart';
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
    final (client, host, calls) = await _pair(
      (method, _) => switch (method) {
        LinkMethods.upload => {
          'path': r'D:\bot-store\uploads\remote report.txt',
        },
        _ => throw StateError(method),
      },
    );
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
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('desktop-remote-upload')));
        for (var i = 0; i < 40 && controller.text.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          await tester.pump();
        }
      });
      await tester.pumpAndSettle();
      expect(calls.single.$1, LinkMethods.upload);
      expect(calls.single.$2, {
        'bot': 'bot1',
        'name': 'local report.txt',
        'data': 'AQID',
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

Future<void> _tap(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
}

Future<void> _mountComposer(
  WidgetTester tester,
  LinkPeer peer,
  DesktopHostChat chat,
  Future<bool> Function(String, DesktopRemoteAttachments) send,
) => tester.pumpWidget(
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
          onSend: (_) async => false,
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
