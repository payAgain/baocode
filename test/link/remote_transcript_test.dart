import 'dart:io';

import 'package:bao_link/bao_link.dart';
import 'package:baocode/chat/chat_history_view.dart';
import 'package:baocode/chat/side_panel/file_open.dart';
import 'package:baocode/chat/widgets/code_citation.dart';
import 'package:baocode/chat/widgets/inline_code.dart';
import 'package:baocode/chat/widgets/markdown_view.dart';
import 'package:baocode/chat/widgets/mermaid_code_block.dart';
import 'package:baocode/chat/widgets/turn_footer.dart';
import 'package:baocode/chat/widgets/user_message_bubble.dart';
import 'package:baocode/link/desktop_host_chats.dart';
import 'package:baocode/link/desktop_host_connection.dart';
import 'package:baocode/link/desktop_host_page.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _project = ProjectInfo(
  id: 'project',
  name: 'Host folder',
  path: r'C:\work',
);
const _session = 'host-session';
final _catalog = LinkState(
  device: const DeviceInfo(name: 'Host', kind: 'pc', system: 'Windows'),
  projects: const [_project],
  sessions: [
    SessionSummary(
      id: _session,
      project: _project.id,
      title: 'Project chat',
      updatedAt: DateTime(2026),
    ),
  ],
);

void main() {
  testWidgets('remote history uses native prompt and rich reply widgets', (
    tester,
  ) async {
    const reply =
        '## Results\n\n'
        '**Passed** with `dart test`.\n\n'
        '```dart\nfinal result = 42;\n```';
    await _withHost(
      tester,
      [
        {'t': 'user', 'text': 'Run the checks'},
        {
          't': 'text',
          'text':
              '$reply\n<reply_suggestion>Legacy suggestion</reply_suggestion>',
        },
      ],
      () async {
        expect(find.byType(ChatHistoryView), findsOneWidget);
        // Native history also builds a sticky copy, outside the hit test.
        final prompt = find.byType(UserMessageBubble).hitTestable();
        expect(prompt, findsOneWidget);
        expect(tester.widget<UserMessageBubble>(prompt).text, 'Run the checks');
        expect(find.byType(MarkdownView), findsOneWidget);
        expect(find.text('Results', findRichText: true), findsOneWidget);
        expect(find.byType(MarkdownCodeBlock), findsOneWidget);
        expect(
          _spans(tester).any(
            (span) =>
                span.style?.fontWeight == FontWeight.w600 &&
                span.toPlainText() == 'Passed',
          ),
          isTrue,
        );
        expect(
          _spans(tester).whereType<InlineCodeSpan>().single.text?.trim(),
          'dart test',
        );
        Set<Color?> codeColors() =>
            _spans(tester)
                .where((span) => span.text == 'final' || span.text == '42')
                .map((span) => span.style?.color)
                .toSet();
        // The bundled grammar is read asynchronously; pumpAndSettle can
        // finish before the platform asset reply schedules another frame.
        final deadline = Stopwatch()..start();
        while (codeColors().length < 2 &&
            deadline.elapsed < const Duration(seconds: 5)) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
        }
        expect(codeColors(), hasLength(2));
        expect(codeColors(), isNot(contains(null)));
        expect(find.text(reply, findRichText: true), findsNothing);
        expect(find.text('Legacy suggestion'), findsNothing);
        final footer = tester.widget<TurnFooter>(find.byType(TurnFooter));
        expect(footer.answer, reply);
        expect(footer.worked, isNull);
        expect(footer.usage, isNull);
        expect(find.byTooltip('Copy reply').hitTestable(), findsOneWidget);
      },
    );
  });

  for (final kind in ['project', 'bot', 'group']) {
    testWidgets('$kind styles and opens web links only on click', (
      tester,
    ) async {
      final destination =
          '${kind == 'bot' ? 'http' : 'https'}://example.invalid'
          '/docs?q=remote%20markdown&mode=full#intro';
      final reply = kind == 'group'
          ? '[documentation]\n\n[documentation]: $destination'
          : '[documentation]($destination)';
      final opened = _mockLinkOpener();
      await _withHost(
        tester,
        [
          if (kind == 'bot') {'t': 'user', 'text': 'Where are the docs?'},
          {
            't': 'text',
            'text': kind == 'bot'
                ? '<bot_say>[softly] $reply</bot_say>'
                : reply,
          },
        ],
        () async {
          final label = find.text('documentation', findRichText: true);
          expect(label, findsOneWidget);
          expect(
            find.textContaining('[softly]', findRichText: true),
            findsNothing,
          );
          expect(
            find.textContaining(destination, findRichText: true),
            findsNothing,
          );
          final span = _spans(tester).singleWhere(
            (span) =>
                span.style?.color == AppColors.accent &&
                span.toPlainText() == 'documentation',
          );
          expect(
            (span.children?.single as TextSpan).recognizer,
            isA<TapGestureRecognizer>(),
          );
          expect(opened, isEmpty);
          await _clickText(tester, 'documentation');
          expect(opened, [destination]);
        },
        kind: kind,
        catalog: kind == 'project'
            ? null
            : LinkState(
                device: _catalog.device,
                bots: const [
                  LinkBot(id: 'helper', name: 'Helper', session: _session),
                ],
                groups: const [LinkGroup(id: 'room', name: 'Team room')],
              ),
        onRequest: (method, _) => switch (method) {
          LinkMethods.openGroup => {
            'messages': [
              {
                'seq': 1,
                'from': 'helper',
                'text': '<bot_say>[softly] $reply</bot_say>',
              },
            ],
            'more': false,
          },
          LinkMethods.closeGroup => null,
          _ => throw StateError('Unexpected host request: $method'),
        },
      );
    });
  }

  testWidgets('peer files, unsafe links and media stay inert', (tester) async {
    final accessed = <String>[];
    final opened = _mockLinkOpener();
    final existence = FileExistence((path) async {
      accessed.add('exists: $path');
      return true;
    });
    addTearDown(existence.dispose);
    final http = HttpOverrides.current!;
    await HttpOverrides.runZoned(
      () => _withHost(
        tester,
        [
          {
            't': 'user',
            'text': 'Check @lib/client.dart and [Session id: client-session]',
            'images': ['file:///client/fixture/local.png'],
          },
          {
            't': 'text',
            'text': '''
[Local document](lib/client.dart) [File URI](file:///client/fixture/local.png)

[Website](https://example.invalid) [Email](mailto:peer@example.invalid) <https://example.invalid/auto>

[Script](javascript:alert%281%29) [Protocol relative](//example.invalid)
[Loopback](http://127.0.0.1:8080) [Private host](https://peer.local.)
[Private IP](http://192.168.1.1) [IPv6](http://[::1]) [Credentials](https://user@example.invalid)

`lib/client.dart` [Image link](local.png)

![Local picture](local.png) [![Network picture](https://example.invalid/image.png)](https://example.invalid)

<img src="https://example.invalid/html.png" alt="HTML picture">

```1:1:lib/client.dart
example();
```

```mermaid
graph TD; a-->b;
```
''',
          },
        ],
        () async {
          final richText = tester.widgetList<RichText>(find.byType(RichText));
          final rendered = richText
              .map((widget) => widget.text.toPlainText())
              .join('\n');
          expect(
            rendered,
            contains('Check @lib/client.dart and [Session id: client-session]'),
          );
          expect(rendered, contains('[Attachment]'));
          expect(rendered, contains('Local document (lib/client.dart)'));
          expect(
            rendered,
            isNot(contains('Website (https://example.invalid)')),
          );
          expect(rendered, contains('Email (mailto:peer@example.invalid)'));
          expect(rendered, contains('Script (javascript:alert%281%29)'));
          expect(rendered, contains('Protocol relative (//example.invalid)'));
          expect(rendered, contains('Loopback (http://127.0.0.1:8080)'));
          expect(rendered, contains('Private host (https://peer.local.)'));
          expect(rendered, contains('Private IP (http://192.168.1.1)'));
          expect(rendered, contains('IPv6 (http://%5B::1%5D)'));
          expect(
            rendered,
            contains('Credentials (https://user@example.invalid)'),
          );
          expect(rendered, contains('https://example.invalid/auto'));
          expect(rendered, contains('[Image: Local picture]'));
          expect(rendered, contains('[Image: Network picture]'));
          expect(rendered, contains('HTML picture'));
          expect(rendered, contains('[Host file: lib/client.dart, Ln 1]'));
          expect(
            _spans(tester)
                .where((span) => span.recognizer != null)
                .map((span) => span.text),
            [
              'Website',
              'https://example.invalid/auto',
              '[Image: Network picture]',
            ],
          );
          expect(find.byType(Image), findsNothing);
          expect(find.byType(CodeCitationCard), findsNothing);
          expect(find.byType(MermaidCodeBlock), findsNothing);
          expect(accessed, isEmpty);
          expect(opened, isEmpty);
          await _clickText(tester, 'Loopback');
          await _clickText(tester, 'Local document');
          expect(opened, isEmpty);

          await tester.tap(find.byType(UserMessageBubble).hitTestable());
          await tester.pumpAndSettle();
          final viewer = find.byType(UserMessageViewer);
          expect(viewer, findsOneWidget);
          expect(
            find.descendant(
              of: viewer,
              matching: find.textContaining(
                '@lib/client.dart',
                findRichText: true,
              ),
            ),
            findsOneWidget,
          );
          expect(accessed, isEmpty);
        },
        wrap: (child) => CodeCitationScope(
          root: '/client/fixture',
          onOpen: (path, _, _) => accessed.add('cite: $path'),
          colorizeBlock: (language, _) async {
            accessed.add('colorize: $language');
            return null;
          },
          child: FileOpenScope(
            root: '/client/fixture',
            onOpen: (request) => accessed.add('open: ${request.path}'),
            existence: existence,
            sizeOf: (path) async {
              accessed.add('size: $path');
              return 8;
            },
            readBytes: (path) async {
              accessed.add('read: $path');
              return Uint8List(0);
            },
            child: child,
          ),
        ),
      ),
      createHttpClient: (context) {
        accessed.add('HTTP client');
        return http.createHttpClient(context);
      },
    );
  });

  testWidgets('peer link definitions do not affect later local markdown', (
    tester,
  ) async {
    const label = '[fixture-remote-reference]';
    await _withHost(
      tester,
      [
        {'t': 'text', 'text': '$label\n\n$label: https://example.invalid'},
      ],
      () async {
        expect(find.text('fixture-remote-reference'), findsOneWidget);
      },
    );
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: MarkdownView(label))),
    );
    expect(find.text(label), findsOneWidget);
  });

  testWidgets('drag selection copies rendered text from a remote reply', (
    tester,
  ) async {
    String? copied;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    const text = 'Copy the rendered reply.';
    await _withHost(
      tester,
      [
        {'t': 'text', 'text': 'Copy the **rendered** reply.'},
      ],
      () async {
        final paragraph = tester.renderObject<RenderParagraph>(
          find.byWidgetPredicate(
            (widget) => widget is RichText && widget.text.toPlainText() == text,
          ),
        );
        final boxes = paragraph.getBoxesForSelection(
          TextSelection(baseOffset: 0, extentOffset: text.length),
        );
        final first = boxes.first.toRect();
        final last = boxes.last.toRect();
        final mouse = await tester.startGesture(
          paragraph.localToGlobal(Offset(first.left + 0.5, first.center.dy)),
          kind: PointerDeviceKind.mouse,
        );
        await mouse.moveTo(
          paragraph.localToGlobal(Offset(last.right - 0.5, last.center.dy)),
        );
        await tester.pump();
        await mouse.up();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
        expect(copied, text);
      },
    );
  });

  testWidgets('paged group replies retain their speaker labels', (
    tester,
  ) async {
    final catalog = LinkState(
      device: _catalog.device,
      projects: const [],
      sessions: const [],
      bots: const [
        LinkBot(id: 'helper', name: 'Helper'),
        LinkBot(id: 'reviewer', name: 'Reviewer'),
      ],
      groups: const [LinkGroup(id: 'room', name: 'Team room')],
    );
    Map<String, Object?>? earlierRequest;
    await _withHost(
      tester,
      const [],
      () async {
        expect(find.text('Helper'), findsOneWidget);
        expect(find.text('You'), findsOneWidget);
        expect(find.text('Current reply'), findsOneWidget);
        await tester.tap(find.text('Load earlier messages'));
        await tester.pumpAndSettle();
        expect(find.text('Reviewer'), findsOneWidget);
        expect(find.text('Earlier reply'), findsOneWidget);
        expect(find.text('Current reply'), findsOneWidget);
        expect(find.text('Load earlier messages'), findsNothing);
      },
      catalog: catalog,
      onRequest: (method, params) {
        switch (method) {
          case LinkMethods.openGroup:
            return {
              'messages': [
                {
                  'seq': 2,
                  'from': 'helper',
                  'text': '<bot_say>**Current reply**</bot_say>',
                },
                {'seq': 3, 'from': linkGroupUser, 'text': 'Group prompt'},
              ],
              'more': true,
            };
          case LinkMethods.earlierGroup:
            earlierRequest = params;
            return {
              'messages': [
                {
                  'seq': 1,
                  'from': 'reviewer',
                  'text': '<bot_say>**Earlier reply**</bot_say>',
                },
              ],
              'more': false,
            };
          case LinkMethods.closeGroup:
            return null;
        }
        throw StateError('Unexpected host request: $method');
      },
    );
    expect(earlierRequest, containsPair('before', 2));
  });

  testWidgets('older Windows project history loads earlier turns on request', (
    tester,
  ) async {
    final requests = <(String, Map<String, Object?>)>[];
    await _withHost(
      tester,
      [
        {'t': 'user', 'text': 'Current prompt'},
        {'t': 'a-future-item-type', 'text': 'Unknown item'},
        {'t': 'text', 'text': 'Current reply'},
      ],
      () async {
        expect(requests, isEmpty);
        final load = find.text('Load earlier messages').hitTestable();
        expect(load, findsOneWidget);
        await tester.tap(load);
        await tester.pumpAndSettle();
        expect(requests.single.$1, LinkMethods.earlier);
        expect(requests.single.$2['session'], _session);
        final older = find.text('Earlier reply');
        final current = find.text('Current reply');
        expect(older, findsOneWidget);
        expect(current, findsOneWidget);
        expect(
          tester.getTopLeft(older).dy,
          lessThan(tester.getTopLeft(current).dy),
        );
        expect(find.byType(TurnFooter), findsNWidgets(2));
        expect(find.text('Unknown item'), findsNothing);
        expect(load, findsNothing);
      },
      earlier: true,
      onRequest: (method, params) {
        requests.add((method, params));
        return {
          'items': [
            {'t': 'user', 'text': 'Earlier prompt'},
            {'t': 'text', 'text': 'Earlier reply'},
          ],
          'earlier': false,
        };
      },
    );
  });
}

List<String> _mockLinkOpener() {
  final original = MarkdownView.openLink;
  final opened = <String>[];
  MarkdownView.openLink = (url) async {
    opened.add(url);
    return true;
  };
  addTearDown(() => MarkdownView.openLink = original);
  return opened;
}

Future<void> _clickText(WidgetTester tester, String text) async {
  final paragraph = tester.renderObject<RenderParagraph>(
    find.byWidgetPredicate(
      (widget) =>
          widget is RichText && widget.text.toPlainText().contains(text),
    ),
  );
  final start = paragraph.text.toPlainText().indexOf(text);
  final box = paragraph
      .getBoxesForSelection(
        TextSelection(baseOffset: start, extentOffset: start + text.length),
      )
      .first;
  await tester.tapAt(
    paragraph.localToGlobal(box.toRect().center),
    kind: PointerDeviceKind.mouse,
  );
  await tester.pumpAndSettle();
}

Iterable<TextSpan> _spans(WidgetTester tester) sync* {
  for (final widget in tester.widgetList<RichText>(find.byType(RichText))) {
    Iterable<TextSpan> walk(InlineSpan span) sync* {
      if (span is! TextSpan) return;
      yield span;
      for (final child in span.children ?? const <InlineSpan>[]) {
        yield* walk(child);
      }
    }

    yield* walk(widget.text);
  }
}

Future<void> _withHost(
  WidgetTester tester,
  List<Object?> history,
  Future<void> Function() exercise, {
  Widget Function(Widget child)? wrap,
  LinkState? catalog,
  bool? earlier,
  String? kind,
  LinkRequestHandler? onRequest,
}) async {
  tester.view.physicalSize = const Size(800, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final (clientWire, hostWire) = MemoryLinkConnection.pair(
    a: 'mac-client',
    b: 'windows-host',
  );
  final accepting = LinkPeer.accept(
    hostWire,
    onRequest: (method, params) => switch (method) {
      LinkMethods.state => (catalog ?? _catalog).toJson(),
      // Older Windows shape: no live flag, choices or context metadata.
      LinkMethods.open => {
        'session': _session,
        'start': 0,
        'count': history.length,
        'items': history,
        'earlier': ?earlier,
      },
      LinkMethods.close => null,
      _ when onRequest != null => onRequest(method, params),
      _ => throw StateError('Unexpected host request: $method'),
    },
  );
  final client = await LinkPeer.connect(clientWire);
  final host = await accepting;
  final chats = DesktopHostChats()..bind(client);
  final connection = _Connection(client);
  try {
    await tester.pump();
    await chats.open(
      chats.chats.singleWhere(
        (chat) => kind == null ? chat.kind != 'bot' : chat.kind == kind,
      ),
    );
    final page = DesktopHostPage(
      connection: connection,
      chats: chats,
      onBack: () {},
    );
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: wrap?.call(page) ?? page)),
    );
    await tester.pumpAndSettle();
    await exercise();
  } finally {
    await tester.pumpWidget(const SizedBox.shrink());
    chats.dispose();
    connection.dispose();
    await client.close();
    await host.close();
    await tester.pump();
  }
}

class _Connection extends ChangeNotifier implements DesktopHostConnection {
  _Connection(this.peer);

  @override
  final LinkPeer peer;

  @override
  bool get busy => false;
  @override
  String? get error => null;
  @override
  bool get groupSelected => true;
  @override
  String get selectedHostId => peer.remote;
  @override
  String get hostName => 'Host';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
