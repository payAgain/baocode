import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bao_link/bao_link.dart';
import 'package:bao_markdown/bao_markdown.dart';
import 'package:baocode/bots/desktop_bot_message_row.dart';
import 'package:baocode/chat/widgets/image_thumbnails.dart';
import 'package:baocode/chat/widgets/inline_code.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/link/desktop_host_chats.dart';
import 'package:baocode/link/desktop_host_connection.dart';
import 'package:baocode/link/desktop_host_page.dart';
import 'package:baocode/sidebar/sidebar_rows.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a8uoAAAAASUVORK5CYII=';
const _window = MethodChannel('baocode/window');
const _room = LinkGroup(id: 'group-fixture', name: 'Fixture room', members: []);
const _bot = LinkBot(
  id: 'bot-fixture',
  name: 'Fixture bot',
  session: 'bot-session',
);
const _project = ProjectInfo(
  id: 'project-fixture',
  name: 'Fixture project',
  path: r'C:\fixture',
);

void main() {
  testWidgets(
    'conversation sends a chosen group image and clears it only after confirmation',
    (tester) async {
      var sends = 0;
      final ack = Completer<Object?>();
      final fixture = await _Fixture.open(
        tester,
        (method, _) => switch (method) {
          LinkMethods.openGroup => {'messages': [], 'more': false},
          LinkMethods.sendGroup => sends++ == 0 ? null : ack.future,
          _ => null,
        },
      );
      final folder = Directory.systemTemp.createTempSync('bao-host-media-');
      final source = File('${folder.path}/fixture.png')
        ..writeAsBytesSync(base64Decode(_png));
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        _window,
        (call) async => call.method == 'pickOpenFiles' ? [source.path] : null,
      );
      try {
        await fixture.select(tester, 'Fixture room');
        final attachment = find.byKey(
          const ValueKey('desktop-remote-attach-image'),
        );
        expect(attachment, findsOneWidget);
        await tester.runAsync(() async {
          await tester.tap(attachment);
          for (
            var i = 0;
            i < 40 && _thumbnail('fixture.png').evaluate().isEmpty;
            i++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            await tester.pump();
          }
        });
        await tester.pumpAndSettle();
        expect(_thumbnail('fixture.png'), findsOneWidget);
        expect(fixture.requests(LinkMethods.sendGroup), isEmpty);
        final send = find.byTooltip('Send');
        await tester.tap(send);
        await tester.pumpAndSettle();
        expect(fixture.requests(LinkMethods.sendGroup).single, {
          'group': _room.id,
          'text': '',
          'id': isA<String>(),
          'images': [
            {'type': 'image/png', 'data': _png, 'name': 'fixture.png'},
          ],
        });
        expect(_thumbnail('fixture.png'), findsOneWidget);
        await tester.tap(send);
        await tester.pump();
        expect(fixture.requests(LinkMethods.sendGroup), hasLength(2));
        expect(_thumbnail('fixture.png'), findsOneWidget);
        final editor = find.byType(MarkdownEditor);
        await tester.tap(editor);
        await tester.pump();
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: 'Next message',
            selection: TextSelection.collapsed(offset: 3),
          ),
        );
        ack.complete({'seq': 3});
        await tester.pumpAndSettle();
        expect(_thumbnail('fixture.png'), findsNothing);
        await tester.tap(find.byTooltip('Close chat'));
        await tester.pumpAndSettle();
        await fixture.select(tester, 'Fixture room');
        final draft = tester.widget<MarkdownEditor>(editor).controller;
        expect(draft.text, 'Next message');
        expect(draft.selection, const TextSelection.collapsed(offset: 3));
        expect(_thumbnail('fixture.png'), findsNothing);
      } finally {
        if (!ack.isCompleted) ack.complete(null);
        await fixture.close(tester);
        messenger.setMockMethodCallHandler(_window, null);
        debugDefaultTargetPlatformOverride = null;
        folder.deleteSync(recursive: true);
      }
    },
  );

  testWidgets('an image-only draft stays with its host and conversation', (
    tester,
  ) async {
    final fixture = await _Fixture.open(
      tester,
      (method, _) => switch (method) {
        LinkMethods.openGroup => {'messages': [], 'more': false},
        LinkMethods.sendGroup => {'seq': 1},
        _ => null,
      },
    );
    final messenger = tester.binding.defaultBinaryMessenger;
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    messenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (_) async => null,
    );
    messenger.setMockMethodCallHandler(_window, (call) async {
      expect(call.method, 'readPasteboardImages');
      return [
        {'bytes': base64Decode(_png), 'type': 'image/png', 'name': 'draft.png'},
      ];
    });
    try {
      final editor = find.byType(MarkdownEditor);
      final thumbnail = _thumbnail('draft.png');
      Future<void> pasteImage() async {
        await tester.tap(editor);
        await tester.pump();
        await tester.state<MarkdownEditorState>(editor).paste();
        await tester.pumpAndSettle();
        expect(thumbnail, findsOneWidget);
      }

      Future<void> closeChat() async {
        await tester.tap(find.byTooltip('Close chat'));
        await tester.pumpAndSettle();
      }

      await fixture.select(tester, 'Fixture room');
      await pasteImage();
      expect(tester.widget<MarkdownEditor>(editor).controller.text, isEmpty);
      await closeChat();
      await fixture.select(tester, 'Other room');
      expect(thumbnail, findsNothing);
      await closeChat();
      await fixture.select(tester, 'Fixture room');
      expect(thumbnail, findsOneWidget);

      await fixture.switchHost(tester, 'other-host');
      await fixture.select(tester, 'Fixture room');
      expect(thumbnail, findsNothing);
      await fixture.switchHost(tester, 'media-host');
      await fixture.select(tester, 'Fixture room');
      expect(thumbnail, findsOneWidget);
      await tester.tap(thumbnail);
      await tester.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      final state = tester.state<MarkdownEditorState>(editor);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(thumbnail));
      await tester.pump();
      final remove = find.descendant(
        of: thumbnail,
        matching: find.byIcon(Icons.close_rounded),
      );
      await tester.tap(remove);
      await mouse.removePointer();
      await tester.pumpAndSettle();
      expect(thumbnail, findsNothing);
      expect(tester.state<MarkdownEditorState>(editor), same(state));
      await closeChat();
      await fixture.select(tester, 'Fixture room');
      expect(thumbnail, findsNothing);
      await pasteImage();
      await fixture.switchHost(tester, 'media-host');
      await fixture.select(tester, 'Fixture room');
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
      expect(fixture.requests(LinkMethods.sendGroup).single, {
        'group': _room.id,
        'text': '',
        'id': isA<String>(),
        'images': [
          {'type': 'image/png', 'data': _png, 'name': 'draft.png'},
        ],
      });
      expect(thumbnail, findsNothing);
      await closeChat();
      await fixture.select(tester, 'Fixture room');
      expect(thumbnail, findsNothing);
    } finally {
      await fixture.close(tester);
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      messenger.setMockMethodCallHandler(_window, null);
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
    'paired user text styles inline code without rendering Markdown',
    (tester) async {
      const literal =
          '![secret](file:///private/secret.png) [link](https://example.com)';
      final fixture = await _Fixture.open(
        tester,
        (method, _) => switch (method) {
          LinkMethods.openGroup => {
            'messages': [
              LinkGroupMessage(
                seq: 1,
                at: DateTime(2026),
                from: linkGroupUser,
                text: 'Run `date` next. $literal',
              ).toJson(),
            ],
            'more': false,
          },
          _ => null,
        },
      );
      try {
        await fixture.select(tester, 'Fixture room');
        final row = find.byType(DesktopBotMessageRow);
        final text = tester.widget<InlineCodeText>(
          find.descendant(of: row, matching: find.byType(InlineCodeText)),
        );
        final spans = (text.span as TextSpan).children!;
        expect(spans.whereType<InlineCodeSpan>().single.text?.trim(), 'date');
        expect(text.span.toPlainText(), endsWith(literal));
        expect(
          spans.whereType<TextSpan>().every((span) => span.recognizer == null),
          isTrue,
        );
        expect(
          find.descendant(of: row, matching: find.byType(Image)),
          findsNothing,
        );
        expect(fixture.requests(LinkMethods.groupImage), isEmpty);
      } finally {
        await fixture.close(tester);
      }
    },
  );

  testWidgets('group user attachments show thumbnails for admitted image IDs', (
    tester,
  ) async {
    final fixture = await _Fixture.open(
      tester,
      (method, _) => switch (method) {
        LinkMethods.openGroup => {
          'messages': [
            LinkGroupMessage(
              seq: 1,
              at: DateTime(2026),
              from: linkGroupUser,
              images: const [
                'fixture-group-image',
                'second-group-image',
                '../invalid.png',
              ],
            ).toJson(),
          ],
          'more': false,
        },
        LinkMethods.groupImage => {'type': 'image/png', 'data': _png},
        _ => null,
      },
    );
    try {
      await fixture.select(tester, 'Fixture room');
      final first = _thumbnail('Image 1');
      final second = _thumbnail('Image 2');
      await _waitFor(tester, first);
      await _waitFor(tester, second);
      expect(first, findsOneWidget);
      expect(second, findsOneWidget);
      final row = find.ancestor(
        of: first,
        matching: find.byType(DesktopBotMessageRow),
      );
      expect(tester.widget<DesktopBotMessageRow>(row).sentAt, DateTime(2026));
      expect(find.text('Image 1'), findsNothing);
      expect(find.text('Image 2'), findsNothing);
      expect(_thumbnail('Image 3'), findsNothing);
      expect(
        fixture.requests(LinkMethods.groupImage),
        unorderedEquals([
          {'group': _room.id, 'image': 'fixture-group-image'},
          {'group': _room.id, 'image': 'second-group-image'},
        ]),
      );
      await tester.tap(second);
      await tester.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(find.text('2 / 2'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(find.text('1 / 2'), findsOneWidget);
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(fixture.requests(LinkMethods.groupImage), hasLength(2));
      await fixture.switchHost(tester, 'other-host');
      expect(find.byType(InteractiveViewer), findsNothing);
    } finally {
      await fixture.close(tester);
    }
  });

  testWidgets('private bot previews only figures from admitted private turns', (
    tester,
  ) async {
    final imageReply = Completer<Object?>();
    final fixture = await _Fixture.open(
      tester,
      (method, _) => switch (method) {
        LinkMethods.open => _history('bot-session', [
          _reply('<bot_say>![figure](unattributed.png)</bot_say>'),
          _user('<bao-event>[group team] hidden group prompt</bao-event>'),
          {
            ..._user('queued private words ![figure](queued-group.png)'),
            'queued': true,
          },
          _reply('<bot_say>![figure](group-reply.png)</bot_say>'),
          _imageTool('group-tool.png'),
          {
            't': 'tool',
            'status': 'succeeded',
            'tool': 'bot_send',
            'images': [
              {'name': 'group-delivery.png', 'type': 'image/png', 'data': _png},
            ],
          },
          _user(
            '<bao-event>[group team] merged group prompt</bao-event>\nPrivate words ![figure](merged-group.png)',
          ),
          _reply('<bot_say>![figure](merged-reply.png)</bot_say>'),
          _user('Private question'),
          _reply(
            '![figure](unspoken.png)\n<bot_say>Private response ![figure](private.png) ![figure](https://example.invalid/hidden.png)</bot_say>',
          ),
        ]),
        LinkMethods.image => imageReply.future,
        _ => null,
      },
    );
    try {
      await fixture.select(tester, 'Fixture bot');
      expect(fixture.requests(LinkMethods.image), isEmpty);
      final previews = find.descendant(
        of: find.byType(TextButton),
        matching: find.textContaining('Image:'),
      );
      final privatePreview = find.widgetWithText(
        TextButton,
        'Image: private.png',
      );
      expect(previews, findsOneWidget);
      expect(privatePreview, findsOneWidget);
      await tester.tap(privatePreview);
      await tester.pump();
      expect(fixture.requests(LinkMethods.image).single, {
        'bot': _bot.id,
        'path': 'private.png',
      });
      await tester.tap(find.byTooltip('Close chat'));
      await tester.pumpAndSettle();
      await fixture.select(tester, 'Fixture room');
      imageReply.complete({'type': 'image/png', 'data': _png});
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsNothing);
      expect(find.textContaining('private.png'), findsNothing);
    } finally {
      if (!imageReply.isCompleted) imageReply.complete(null);
      await fixture.close(tester);
    }
  });

  testWidgets(
    'project transcript fetches only the selected figure with its project ID',
    (tester) async {
      final imageReply = Completer<Object?>();
      final fixture = await _Fixture.open(
        tester,
        (method, _) => switch (method) {
          LinkMethods.open => _history('project-session', [
            {
              ..._user('Synthetic project prompt'),
              'images': [
                {'type': 'image/png', 'data': _png, 'name': 'prompt.png'},
              ],
            },
            _reply(
              '![figure](assets/project.png)\n![web](https://example.invalid/web.png)\n![absolute](/fixture/local.png)',
            ),
            _user('Later project prompt'),
          ]),
          LinkMethods.image => imageReply.future,
          _ => null,
        },
      );
      try {
        await fixture.select(tester, 'Fixture session');
        expect(fixture.requests(LinkMethods.image), isEmpty);
        final prompt = find
            .textContaining('Synthetic project prompt')
            .hitTestable();
        final attachment = _thumbnail('prompt.png');
        final figure = find.text('Image: project.png');
        final nextPrompt = find.text('Later project prompt').hitTestable();
        await _waitFor(tester, attachment);
        expect(attachment, findsOneWidget);
        expect(figure, findsOneWidget);
        expect(find.text('Conversation images'), findsNothing);
        expect(
          tester.getTopLeft(attachment).dy,
          greaterThan(tester.getTopLeft(prompt).dy),
        );
        expect(
          tester.getTopLeft(figure).dy,
          lessThan(tester.getTopLeft(nextPrompt).dy),
        );
        expect(find.text('Image: web.png'), findsNothing);
        expect(find.text('Image: local.png'), findsNothing);
        await tester.tap(find.text('Image: project.png'));
        await tester.pump();
        expect(fixture.requests(LinkMethods.image).single, {
          'project': _project.id,
          'path': 'assets/project.png',
        });
      } finally {
        imageReply.complete(null);
        await fixture.close(tester);
      }
    },
  );

  testWidgets('plain text waits for a matching session acknowledgement', (
    tester,
  ) async {
    var sends = 0;
    final fixture = await _Fixture.open(
      tester,
      (method, _) => switch (method) {
        LinkMethods.open => _history('project-session', []),
        LinkMethods.send => {
          'session': sends++ == 0 ? 'wrong-session' : 'project-session',
        },
        _ => null,
      },
    );
    try {
      await fixture.select(tester, 'Fixture session');
      final editor = find.byType(MarkdownEditor);
      await tester.tap(editor);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'Synthetic text',
          selection: TextSelection.collapsed(offset: 14),
        ),
      );
      await tester.pump();
      final draft = tester.widget<MarkdownEditor>(editor).controller;
      final send = find.byTooltip('Send');
      await tester.tap(send);
      await tester.pumpAndSettle();
      expect(
        fixture.requests(LinkMethods.send).single,
        containsPair('session', 'project-session'),
      );
      expect(draft.text, 'Synthetic text');
      await tester.tap(send);
      await tester.pumpAndSettle();
      expect(fixture.requests(LinkMethods.send), hasLength(2));
      expect(draft.text, isEmpty);
    } finally {
      await fixture.close(tester);
    }
  });
}

Map<String, Object?> _history(String session, List<Object?> items) =>
    LinkSessionUpdate(
      session: session,
      start: 0,
      count: items.length,
      items: items,
    ).toJson();
Map<String, Object?> _user(String text) => {'t': 'user', 'text': text};
Map<String, Object?> _reply(String text) => {'t': 'text', 'text': text};
Finder _thumbnail(String name) => find.byWidgetPredicate(
  (widget) => widget is ImageThumbnail && widget.image.name == name,
);

Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  await tester.runAsync(() async {
    for (var i = 0; i < 40 && finder.evaluate().isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await tester.pump();
    }
  });
  await tester.pumpAndSettle();
}

Map<String, Object?> _imageTool(String path) => {
  't': 'tool',
  'status': 'succeeded',
  'tool': 'bot_send_image',
  'url': path,
};

class _Fixture {
  _Fixture(this.connection, this.chats, this.host, this.calls, this.handler);

  final _Connection connection;
  final DesktopHostChats chats;
  LinkPeer host;
  final List<(String, Map<String, Object?>)> calls;
  final LinkRequestHandler handler;

  static Future<(LinkPeer, LinkPeer)> _connect(
    String id,
    LinkRequestHandler handler,
    List<(String, Map<String, Object?>)> calls,
  ) async {
    final (clientWire, hostWire) = MemoryLinkConnection.pair(
      a: 'media-client',
      b: id,
    );
    final accepting = LinkPeer.accept(
      hostWire,
      onRequest: (method, params) {
        calls.add((method, params));
        if (method == LinkMethods.state) {
          return LinkState(
            device: const DeviceInfo(
              name: 'Fixture host',
              kind: 'windows',
              system: 'Windows',
            ),
            bots: const [_bot],
            groups: const [
              _room,
              LinkGroup(id: 'other-room', name: 'Other room', members: []),
            ],
            projects: const [_project],
            sessions: [
              SessionSummary(
                id: 'project-session',
                project: _project.id,
                title: 'Fixture session',
                updatedAt: DateTime(2026),
              ),
            ],
          ).toJson();
        }
        return handler(method, params);
      },
    );
    return (await LinkPeer.connect(clientWire), await accepting);
  }

  static Future<_Fixture> open(
    WidgetTester tester,
    LinkRequestHandler handler,
  ) async {
    final calls = <(String, Map<String, Object?>)>[];
    final (client, host) = await _connect('media-host', handler, calls);
    final fixture = _Fixture(
      _Connection(client),
      DesktopHostChats()..bind(client),
      host,
      calls,
      handler,
    );
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: DesktopHostPage(
            connection: fixture.connection,
            chats: fixture.chats,
            onBack: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return fixture;
  }

  List<Map<String, Object?>> requests(String method) => [
    for (final call in calls)
      if (call.$1 == method) call.$2,
  ];

  Future<void> select(WidgetTester tester, String title) async {
    await tester.tap(find.widgetWithText(SidebarSessionRow, title));
    await tester.pumpAndSettle();
  }

  Future<void> switchHost(WidgetTester tester, String id) async {
    final previous = connection.peer;
    chats.bind(null);
    connection.replacePeer(null);
    await previous?.close();
    await host.close();
    await tester.pumpAndSettle();
    final (client, nextHost) = await _connect(id, handler, calls);
    host = nextHost;
    chats.bind(client);
    connection.replacePeer(client);
    await tester.pumpAndSettle();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    chats.dispose();
    await connection.peer?.close();
    await host.close();
    connection.dispose();
  }
}

class _Connection extends ChangeNotifier implements DesktopHostConnection {
  _Connection(this.peer);
  @override
  LinkPeer? peer;

  void replacePeer(LinkPeer? next) {
    peer = next;
    notifyListeners();
  }

  @override
  bool get groupSelected => true;
  @override
  String? get selectedHostId => peer?.remote;
  @override
  String get hostName => 'Fixture host';
  @override
  String? get error => null;
  @override
  bool get busy => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
