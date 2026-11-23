import 'package:bao_link/bao_link.dart';
import 'package:bao_markdown/bao_markdown.dart';
import 'package:baocode/chat/chat_feed.dart';
import 'package:baocode/chat/chat_history_view.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/chat_session.dart' show ComposerMessage, UserPlace;
import 'package:baocode/chat/composer/composer_draft.dart';
import 'package:baocode/chat/widgets/fold_line.dart';
import 'package:baocode/chat/widgets/turn_footer.dart';
import 'package:baocode/chat/widgets/user_message_bubble.dart';
import 'package:baocode/link/chat_codec.dart';
import 'package:baocode/link/desktop_host_chats.dart';
import 'package:baocode/link/desktop_host_composer.dart';
import 'package:baocode/link/desktop_host_connection.dart';
import 'package:baocode/link/desktop_host_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _project = ProjectInfo(
  id: r'C:\fixture',
  name: 'Fixture project',
  path: r'C:\fixture',
);
const _first = 'First synthetic prompt';
const _second = 'Second synthetic prompt';
const _answerA = 'First synthetic answer';
const _answerB = 'Second synthetic answer';
const _answerTail = 'Another paragraph';
final _items = <ChatItem>[
  const UserMessageItem(
    text: _first,
    worked: Duration(seconds: 3),
    usage: TurnUsage(inputTokens: 1200, outputTokens: 200),
  ),
  const ThinkingItem(text: 'Synthetic thought', tokens: 10, seconds: 1),
  const ToolCallItem(
    kind: ToolKind.read,
    status: ToolStatus.succeeded,
    target: 'fixture.dart',
  ),
  const ToolCallItem(
    kind: ToolKind.read,
    status: ToolStatus.succeeded,
    target: 'other_fixture.dart',
  ),
  const AssistantTextItem(_answerA),
  const UserMessageItem(text: _second, worked: Duration(seconds: 6)),
  const AssistantTextItem(_answerB),
  const AssistantTextItem(
    '$_answerTail\n<reply_suggestion>Draft the next step</reply_suggestion>',
  ),
];

void main() {
  testWidgets(
    'project open renders the same native turn rows and copy as local history',
    (tester) async {
      final messages = _items.map(ChatCodec.encode).toList();
      final slimmer = LinkSessionSlimmer();
      final sends = <Object?>[];
      final (local, remote) = MemoryLinkConnection.pair(
        a: 'synthetic-client',
        b: 'synthetic-host',
      );
      final accepting = LinkPeer.accept(
        remote,
        onRequest: (method, params) => switch (method) {
          LinkMethods.state => LinkState(
            device: const DeviceInfo(
              name: 'Fixture Windows host',
              kind: 'windows',
              system: 'Windows',
            ),
            projects: const [_project],
            sessions: [
              SessionSummary(
                id: 'fixture',
                project: _project.id,
                title: 'Fixture session',
                updatedAt: DateTime(2026),
              ),
            ],
          ).toJson(),
          LinkMethods.open => slimmer.encode(
            LinkSessionUpdate(
              session: 'fixture',
              start: 0,
              count: messages.length,
              items: messages,
            ),
            full: true,
          ),
          LinkMethods.send => sends.add(params['text']),
          _ => null,
        },
      );
      final peer = await LinkPeer.connect(local, mirror: LinkSessionMirror());
      final host = await accepting;
      final chats = DesktopHostChats()..bind(peer);
      final connection = _Connection(peer);
      final localFeed = _FixtureFeed();
      addTearDown(localFeed.dispose);
      addTearDown(connection.dispose);
      addTearDown(chats.dispose);
      addTearDown(peer.close);
      addTearDown(host.close);
      tester.view.physicalSize = const Size(1024, 1040);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final placement = <List<Offset>>[];
      final copy = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copy.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      Future<void> assertHistory() async {
        final history = find.byType(ChatHistoryView);
        expect(history, findsOneWidget);
        Finder row(String value) => find.descendant(
          of: history,
          matching: find.text(value, findRichText: true),
        );
        final prompts = find.byType(UserMessageBubble).hitTestable();
        expect(prompts, findsNWidgets(2));
        final work = find.byType(WorkFoldLine);
        expect(work, findsOneWidget);
        final footer = find.byType(TurnFooter);
        expect(footer, findsNWidgets(2));
        expect(
          tester.widget<TurnFooter>(footer.first).usage?.totalTokens,
          1400,
        );
        expect(
          tester.widget<TurnFooter>(footer.last).worked,
          const Duration(seconds: 6),
        );
        expect(tester.widget<TurnFooter>(footer.last).onFork, isNull);
        final firstPrompt = tester.getTopLeft(prompts.first);
        placement.add([
          for (final finder in [
            prompts.first,
            work,
            row(_answerA),
            footer.first,
            prompts.last,
            row(_answerB),
            row(_answerTail),
            footer.last,
          ])
            tester.getTopLeft(finder) - firstPrompt,
        ]);
        await tester.tap(find.byTooltip('Copy reply').last);
        await tester.pumpAndSettle();
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatHistoryView(
              feed: localFeed,
              maxContentWidth: 640,
              underTitle: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await assertHistory();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DesktopHostPage(
              connection: connection,
              chats: chats,
              onBack: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fixture session'));
      await tester.pumpAndSettle();
      await assertHistory();
      final (localPositions, remotePositions) = (
        placement.first,
        placement.last,
      );
      for (var i = 0; i < localPositions.length; i++) {
        expect(remotePositions[i].dy, closeTo(localPositions[i].dy, 0.01));
      }
      expect(copy, ['$_answerB\n\n$_answerTail', '$_answerB\n\n$_answerTail']);

      final editor = find.descendant(
        of: find.byType(DesktopHostComposer),
        matching: find.byType(MarkdownEditor),
      );
      final draft = tester.state<MarkdownEditorState>(editor).controller;
      final pick = find.text('Draft the next step');
      expect(pick, findsOneWidget);
      await tester.tap(pick);
      await tester.pumpAndSettle();
      expect(draft.text, 'Draft the next step');
      draft.replace(0, draft.length, 'Keep my draft');
      await tester.pumpAndSettle();
      await tester.tap(pick);
      await tester.pumpAndSettle();
      expect(draft.text, 'Keep my draft');
      expect(sends, isEmpty);

      final started = DateTime.now().subtract(const Duration(seconds: 8));
      final liveStart = messages.length;
      final liveReply = ChatCodec.encode(const AssistantTextItem('Live reply'));
      final liveStatus = ChatCodec.encode(
        LiveStatusItem(
          'Thinking',
          startedAt: started,
          output: const TurnOutput(tokens: 42, tokensPerSecond: 3),
        ),
      );
      void publish(int start, List<Object?> items, {Object? before}) {
        host.emit(
          LinkEvents.session,
          slimmer.encode(
            LinkSessionUpdate(
              session: 'fixture',
              start: start,
              count: start + items.length,
              items: items,
              live: true,
            ),
            before: before,
          ),
        );
      }

      publish(liveStart, [
        ChatCodec.encode(const UserMessageItem(text: 'Active prompt')),
        liveReply,
        liveStatus,
      ]);
      await tester.pumpAndSettle();
      final liveFooter = find.byWidgetPredicate(
        (widget) => widget is TurnFooter && widget.live != null,
      );
      expect(tester.widget<TurnFooter>(liveFooter).live?.tokens, 42);
      expect(
        tester.widget<TurnFooter>(liveFooter).since?.millisecondsSinceEpoch,
        started.millisecondsSinceEpoch,
      );
      expect(find.text('Live reply'), findsOneWidget);
      expect(pick, findsNothing);

      publish(liveStart + 1, [
        ChatCodec.encode(const AssistantTextItem('Live reply appended')),
        liveStatus,
      ], before: liveReply);
      await tester.pumpAndSettle();
      expect(find.text('Live reply appended'), findsOneWidget);
      expect(find.text('Live reply'), findsNothing);
      expect(draft.text, 'Keep my draft');
      await tester.pumpWidget(const SizedBox.shrink());
      await peer.close();
      await host.close();
    },
  );
}

class _FixtureFeed extends ChangeNotifier implements ChatFeed {
  @override
  int get itemCount => _items.length;
  @override
  ChatItem itemAt(int index) => _items[index];
  @override
  bool get isStreaming => false;
  @override
  bool get isUnprompted => false;
  @override
  bool get canEditMessages => false;
  @override
  ({int index, ComposerDraft draft})? editing;
  @override
  VoidCallback? moveToBackgroundAt(int index) => null;
  @override
  VoidCallback? stopAt(int index) => null;
  @override
  void editMessage(int index, ComposerMessage message, {UserPlace? from}) {}
}

class _Connection extends ChangeNotifier implements DesktopHostConnection {
  _Connection(this.peer);
  @override
  final LinkPeer peer;
  @override
  String? get pendingCode => null;
  @override
  String? get hostName => 'Fixture Windows host';
  @override
  String? get error => null;
  @override
  bool get busy => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
