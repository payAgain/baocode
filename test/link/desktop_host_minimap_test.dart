import 'dart:ui' as ui;

import 'package:bao_link/bao_link.dart';
import 'package:baocode/chat/chat_feed.dart';
import 'package:baocode/chat/chat_history_view.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/chat_session.dart' show ComposerMessage, UserPlace;
import 'package:baocode/chat/chat_width.dart';
import 'package:baocode/chat/composer/composer_draft.dart';
import 'package:baocode/chat/panels/reply_suggestion_bar.dart';
import 'package:baocode/chat/widgets/assistant_text.dart';
import 'package:baocode/chat/widgets/chat_minimap.dart';
import 'package:baocode/chat/widgets/conversation_card_header.dart';
import 'package:baocode/chat/widgets/turn_footer.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/link/chat_codec.dart';
import 'package:baocode/link/desktop_host_composer.dart';
import 'package:baocode/link/desktop_host_connection.dart';
import 'package:baocode/link/desktop_host_page.dart';
import 'package:baocode/link/desktop_remote_rail.dart';
import 'package:baocode/settings/app_locale.dart';
import 'package:baocode/settings/app_settings.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:baocode/workbench.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _project = ProjectInfo(
  id: r'C:\fixture',
  name: 'Synthetic Windows project',
  path: r'C:\fixture',
);
const _title = 'Inspect fixture report';
const _suggestion = 'Summarize the findings';
const _long = 'report';
const _short = 'brief';
final _history = <ChatItem>[
  const UserMessageItem(
    text: 'What did the integration checks find?',
    worked: Duration(seconds: 12),
    usage: TurnUsage(inputTokens: 1200, outputTokens: 680),
  ),
  AssistantTextItem(
    [
      '## Integration report',
      '',
      'The fixture passed on both supported platforms. Here are the checks.',
      '',
      '| Check | Result | Notes |',
      '| --- | --- | --- |',
      for (var i = 1; i <= 21; i++) '| Check $i | Passed | Synthetic input |',
      '',
      'Review the recorded output before the next scheduled run.',
      '',
      '<reply_suggestion>$_suggestion</reply_suggestion>',
    ].join('\n'),
  ),
];

void main() {
  testWidgets(
    'paired workbench paints and scrubs a one-turn report',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const windowChannel = MethodChannel('baocode/window');
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(windowChannel, (_) async => null);
      addTearDown(
        () => messenger.setMockMethodCallHandler(windowChannel, null),
      );
      final appearance = ValueNotifier<Map<String, Object?>>(const {});
      final before = (
        ChatMinimap.enabled.value,
        ChatMinimap.side.value,
        ChatMinimap.glass.value,
        ChatMinimap.elasticity.value,
        ChatWidth.current.value,
      );
      ChatMinimap.follow(appearance, (key) => appearance.value[key]);
      ChatWidth.follow(
        appearance,
        () => appearance.value[ChatWidth.settingKey],
      );
      addTearDown(() {
        appearance.dispose();
        ChatMinimap.enabled.value = before.$1;
        ChatMinimap.side.value = before.$2;
        ChatMinimap.glass.value = before.$3;
        ChatMinimap.elasticity.value = before.$4;
        ChatWidth.current.value = before.$5;
      });
      expect(ChatMinimap.enabled.value, isTrue);
      expect(ChatMinimap.side.value, ChatMinimapSide.left);

      final (client, remote) = MemoryLinkConnection.pair(
        a: 'synthetic-client',
        b: 'synthetic-windows-host',
      );
      final opened = <Object?>[];
      final accepting = LinkPeer.accept(
        remote,
        onRequest: (method, params) {
          switch (method) {
            case LinkMethods.state:
              return LinkState(
                device: const DeviceInfo(
                  name: 'Windows fixture',
                  kind: 'windows',
                  system: 'Windows',
                ),
                projects: const [_project],
                sessions: [
                  SessionSummary(
                    id: _long,
                    project: _project.id,
                    title: _title,
                    updatedAt: DateTime(2026, 11, 23),
                  ),
                  SessionSummary(
                    id: _short,
                    project: _project.id,
                    title: 'Short fixture',
                    updatedAt: DateTime(2026, 11, 22),
                  ),
                ],
              ).toJson();
            case LinkMethods.open:
              final id = params['session'] as String;
              opened.add(id);
              final items =
                  (id == _long
                          ? _history
                          : const <ChatItem>[
                              UserMessageItem(text: 'Short prompt'),
                              AssistantTextItem('Short response'),
                            ])
                      .map(ChatCodec.encode)
                      .toList();
              return LinkSessionSlimmer().encode(
                LinkSessionUpdate(
                  session: id,
                  start: 0,
                  count: items.length,
                  items: items,
                ),
                full: true,
              );
            case LinkMethods.folder:
              return {'entries': []};
            default:
              return null;
          }
        },
      );
      final peer = await LinkPeer.connect(client, mirror: LinkSessionMirror());
      final host = await accepting;
      final workspace = Workspace.mock();
      final settings = AppSettings(locale: AppLocale());
      final surface = GlobalKey();
      addTearDown(workspace.dispose);

      try {
        await tester.pumpWidget(
          RepaintBoundary(
            key: surface,
            child: MaterialApp(
              localizationsDelegates: const [AppLocalizations.delegate],
              theme: buildAppTheme(),
              home: Workbench(
                workspace: workspace,
                settings: settings,
                createDesktopHostConnection: () => _FixtureConnection(peer),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Switch to remote workspace'));
        await tester.pumpAndSettle();
        final page = find.byType(DesktopHostPage);
        expect(page, findsOneWidget);
        await tester.tap(find.text(_title));
        await tester.pumpAndSettle();
        expect(opened, [_long]);

        final history = find.byType(ChatHistoryView);
        final header = find.byType(ConversationCardHeader);
        final composer = find.byType(DesktopHostComposer);
        final suggestions = find.byType(ReplySuggestionBar);
        expect(find.byType(DesktopRemoteRail), findsOneWidget);
        expect(
          find.byKey(const ValueKey('desktop-remote-files-toggle')),
          findsOneWidget,
        );
        expect(header, findsOneWidget);
        expect(composer, findsOneWidget);
        expect(suggestions, findsOneWidget);
        expect(find.byType(TurnFooter).hitTestable(), findsOneWidget);
        final viewport = tester.getRect(history);
        final position = _position(tester);
        expect(position.maxScrollExtent, greaterThan(0));
        expect(
          position.maxScrollExtent,
          lessThan(position.viewportDimension * ChatMinimap.longAfter),
        );
        final strip = _strip();
        final track = tester.getRect(strip);
        final frame = await _capture(tester, surface);
        expect(
          _ink(frame, track),
          greaterThan(40),
          reason:
              'The left gutter must contain visibly painted preview strokes. '
              'Viewport $viewport, strip $track, '
              'scroll extent ${position.maxScrollExtent} for ${position.viewportDimension}.',
        );
        expect(track.left, greaterThan(viewport.left));
        expect(
          track.right,
          lessThan(tester.getRect(find.byType(AssistantText)).left),
        );
        expect(track.top, greaterThan(tester.getRect(header).bottom));
        expect(track.bottom, lessThan(tester.getRect(suggestions).top));
        expect(position.pixels, position.maxScrollExtent);
        await tester.tapAt(
          track.topCenter + const Offset(0, 4),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pumpAndSettle();
        expect(position.pixels, lessThan(position.maxScrollExtent * .05));
        final drag = await tester.startGesture(
          track.topCenter + const Offset(0, 6),
          kind: PointerDeviceKind.mouse,
        );
        for (var i = 1; i <= 10; i++) {
          await drag.moveTo(track.topCenter + Offset(0, track.height * i / 10));
          await tester.pump();
        }
        await drag.up();
        await tester.pumpAndSettle();
        expect(position.pixels, closeTo(position.maxScrollExtent, 1));

        appearance.value = const {ChatMinimap.settingKey: false};
        await tester.pumpAndSettle();
        expect(find.byType(ChatMinimap), findsNothing);
        expect(_scrollbar(tester).interactive, isTrue);
        expect(_ink(await _capture(tester, surface), track), 0);
        appearance.value = const {};
        await tester.pumpAndSettle();
        expect(_ink(await _capture(tester, surface), track), greaterThan(40));

        // Exercise the same open conversation with both navigation panes.
        tester.view.physicalSize = const Size(1024, 850);
        await tester.pumpAndSettle();
        final files = find.byKey(const ValueKey('desktop-remote-files-toggle'));
        await tester.tap(files);
        await tester.pumpAndSettle();
        final explorer = find.byKey(const ValueKey('desktop-remote-explorer'));
        expect(explorer.hitTestable(), findsOneWidget);
        final dockedTrack = tester.getRect(strip);
        expect(dockedTrack.left, greaterThan(tester.getRect(history).left));
        expect(
          dockedTrack.right,
          lessThan(tester.getRect(find.byType(AssistantText)).left),
        );
        expect(
          _ink(await _capture(tester, surface), dockedTrack),
          greaterThan(40),
        );
        tester.view.physicalSize = const Size(900, 850);
        await tester.pumpAndSettle();
        expect(explorer.hitTestable(), findsOneWidget);
        expect(_position(tester).maxScrollExtent, greaterThan(0));
        expect(_scrollbar(tester).interactive, isTrue);

        // Below the navigation breakpoint the catalog undocks, making room
        // in the conversation again even with the right explorer still open.
        tester.view.physicalSize = const Size(860, 850);
        await tester.pumpAndSettle();
        expect(explorer.hitTestable(), findsOneWidget);
        expect(
          _ink(await _capture(tester, surface), tester.getRect(strip)),
          greaterThan(40),
        );

        await tester.tap(files);
        tester.view.physicalSize = const Size(1280, 1350);
        await tester.pumpAndSettle();
        expect(_position(tester).maxScrollExtent, 0);
        expect(_scrollbar(tester).interactive, isTrue);
        expect(_ink(await _capture(tester, surface), tester.getRect(strip)), 0);

        tester.view.physicalSize = const Size(1280, 850);
        await tester.pumpAndSettle();
        expect(
          _ink(await _capture(tester, surface), tester.getRect(strip)),
          greaterThan(40),
        );
        await tester.tap(find.text('Short fixture'));
        await tester.pumpAndSettle();
        expect(opened, [_long, _short]);
        expect(_position(tester).maxScrollExtent, 0);
        expect(_scrollbar(tester).interactive, isTrue);
        expect(_ink(await _capture(tester, surface), track), 0);

        // Compare the local history at exactly the same viewport and width.
        final localFeed = _LocalFeed();
        addTearDown(localFeed.dispose);
        await tester.pumpWidget(
          RepaintBoundary(
            key: surface,
            child: MaterialApp(
              theme: buildAppTheme(),
              home: Scaffold(
                backgroundColor: AppColors.background,
                body: Stack(
                  children: [
                    Positioned.fromRect(
                      rect: viewport,
                      child: ChatHistoryView(
                        feed: localFeed,
                        maxContentWidth: ChatWidth.current.value,
                        underTitle: true,
                        minimap: ChatMinimap.enabled.value,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.getRect(history), viewport);
        final local = _position(tester);
        expect(local.maxScrollExtent, greaterThan(0));
        expect(
          local.maxScrollExtent,
          lessThan(local.viewportDimension * ChatMinimap.longAfter),
        );
        expect(_scrollbar(tester).interactive, isTrue);
        expect(_ink(await _capture(tester, surface), track), 0);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await peer.close();
        await host.close();
      }
    },
    variant: const TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.windows,
    }),
  );
}

Finder _inHistory(Type type) => find.descendant(
  of: find.byType(ChatHistoryView),
  matching: find.byType(type),
);

ScrollPosition _position(WidgetTester tester) =>
    tester.state<ScrollableState>(_inHistory(Scrollable).first).position;

Scrollbar _scrollbar(WidgetTester tester) =>
    tester.widget<Scrollbar>(_inHistory(Scrollbar).first);

Finder _strip() => find
    .descendant(
      of: find.byType(ChatMinimap),
      matching: find.byType(CustomPaint),
    )
    .first;

Future<({int width, ByteData pixels})> _capture(
  WidgetTester tester,
  GlobalKey surface,
) async {
  final boundary =
      surface.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  return (await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      return (
        width: image.width,
        pixels: (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!,
      );
    } finally {
      image.dispose();
    }
  }))!;
}

// Check the composited workbench, including opacity, clipping and other panes.
// The strip's strokes have more contrast than its extremely faint track.
int _ink(({int width, ByteData pixels}) frame, Rect track) {
  var count = 0;
  final reference = track.right.ceil() + 4;
  for (var y = track.top.ceil(); y < track.bottom.floor(); y++) {
    final row = y * frame.width;
    for (var x = track.left.ceil(); x < track.right.floor(); x++) {
      final offset = (row + x) * 4;
      final background = (row + reference) * 4;
      if ((frame.pixels.getUint8(offset) - frame.pixels.getUint8(background))
              .abs() >
          15) {
        count++;
      }
    }
  }
  return count;
}

class _LocalFeed extends ChangeNotifier implements ChatFeed {
  @override
  int get itemCount => _history.length;
  @override
  ChatItem itemAt(int index) => _history[index];
  @override
  bool get isStreaming => false;
  @override
  bool get isUnprompted => false;
  @override
  bool get canEditMessages => false;
  @override
  ({int index, ComposerDraft draft})? editing;
  @override
  void editMessage(int index, ComposerMessage message, {UserPlace? from}) {}
  @override
  VoidCallback? moveToBackgroundAt(int index) => null;
  @override
  VoidCallback? stopAt(int index) => null;
}

class _FixtureConnection extends ChangeNotifier
    implements DesktopHostConnection {
  _FixtureConnection(this.peer);

  @override
  final LinkPeer peer;
  @override
  Future<void> load() async => notifyListeners();
  @override
  String? get pendingCode => null;
  @override
  String? get hostName => 'Windows fixture';
  @override
  String? get error => null;
  @override
  bool get busy => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
