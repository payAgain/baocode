import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bao_link/bao_link.dart';
import 'package:bao_markdown/bao_markdown.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/link/desktop_host_chats.dart';
import 'package:baocode/link/desktop_host_connection.dart';
import 'package:baocode/link/desktop_host_page.dart';
import 'package:flutter/foundation.dart';
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
            i < 40 && find.text('fixture.png').evaluate().isEmpty;
            i++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            await tester.pump();
          }
        });
        await tester.pumpAndSettle();
        expect(find.text('fixture.png'), findsOneWidget);
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
        expect(find.text('fixture.png'), findsOneWidget);
        await tester.tap(send);
        await tester.pump();
        expect(fixture.requests(LinkMethods.sendGroup), hasLength(2));
        expect(find.text('fixture.png'), findsOneWidget);
        ack.complete({'seq': 3});
        await tester.pumpAndSettle();
        expect(find.text('fixture.png'), findsNothing);
      } finally {
        if (!ack.isCompleted) ack.complete(null);
        await fixture.close(tester);
        messenger.setMockMethodCallHandler(_window, null);
        debugDefaultTargetPlatformOverride = null;
        folder.deleteSync(recursive: true);
      }
    },
  );

  testWidgets('group image lookup uses the selected group and image ID', (
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
              images: const ['fixture-group-image', '../invalid.png'],
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
      expect(fixture.requests(LinkMethods.groupImage), isEmpty);
      expect(find.text('Image 2'), findsNothing);
      await tester.runAsync(() async {
        await tester.tap(find.text('Image 1'));
        for (var i = 0; i < 40 && find.byType(Image).evaluate().isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          await tester.pump();
        }
      });
      await tester.pumpAndSettle();
      expect(fixture.requests(LinkMethods.groupImage).single, {
        'group': _room.id,
        'image': 'fixture-group-image',
      });
      expect(
        tester.widget<Image>(find.byType(Image)).image,
        isA<ResizeImage>(),
      );
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
      expect(find.text('Image: private.png'), findsOneWidget);
      expect(find.textContaining('Image:'), findsOneWidget);
      await tester.tap(find.text('Image: private.png'));
      await tester.pump();
      expect(fixture.requests(LinkMethods.image).single, {
        'bot': _bot.id,
        'path': 'private.png',
      });
      await tester.tap(find.byTooltip('Back to host chats'));
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
            _user('Synthetic project prompt'),
            _reply(
              '![figure](assets/project.png)\n![web](https://example.invalid/web.png)\n![absolute](/fixture/local.png)',
            ),
          ]),
          LinkMethods.image => imageReply.future,
          _ => null,
        },
      );
      try {
        await fixture.select(tester, 'Fixture session');
        expect(
          find.text('Synthetic project prompt').hitTestable(),
          findsOneWidget,
        );
        expect(fixture.requests(LinkMethods.image), isEmpty);
        expect(find.text('Image: project.png'), findsOneWidget);
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
Map<String, Object?> _imageTool(String path) => {
  't': 'tool',
  'status': 'succeeded',
  'tool': 'bot_send_image',
  'url': path,
};

class _Fixture {
  _Fixture(this.connection, this.chats, this.host, this.calls);

  final _Connection connection;
  final DesktopHostChats chats;
  final LinkPeer host;
  final List<(String, Map<String, Object?>)> calls;

  static Future<_Fixture> open(
    WidgetTester tester,
    LinkRequestHandler handler,
  ) async {
    final calls = <(String, Map<String, Object?>)>[];
    final (clientWire, hostWire) = MemoryLinkConnection.pair(
      a: 'media-client',
      b: 'media-host',
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
            groups: const [_room],
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
    final client = await LinkPeer.connect(clientWire);
    final fixture = _Fixture(
      _Connection(client),
      DesktopHostChats()..bind(client),
      await accepting,
      calls,
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
    await tester.tap(find.text(title));
    await tester.pumpAndSettle();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    chats.dispose();
    await connection.peer.close();
    await host.close();
    connection.dispose();
  }
}

class _Connection extends ChangeNotifier implements DesktopHostConnection {
  _Connection(this.peer);
  @override
  final LinkPeer peer;
  @override
  bool get groupSelected => true;
  @override
  String get selectedHostId => peer.remote;
  @override
  String get hostName => 'Fixture host';
  @override
  String? get error => null;
  @override
  bool get busy => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
