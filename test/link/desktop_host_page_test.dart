import 'dart:async';

import 'package:bao_link/bao_link.dart';
import 'package:baocode/link/desktop_host_chats.dart';
import 'package:baocode/link/desktop_host_connection.dart';
import 'package:baocode/link/desktop_host_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('paste invite, compare codes, then explicitly pair', (
    tester,
  ) async {
    final connection = _Connection();
    await _pumpPage(tester, connection);

    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => call.method == 'Clipboard.getData'
          ? {'text': ' baocode://pair?d=example '}
          : null,
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Pair'), findsOneWidget);
    await tester.tap(find.text('Paste'));
    await tester.pump();
    expect(connection.invites, isEmpty);
    await tester.tap(find.text('Pair'));
    await tester.pump();

    expect(connection.invites, ['baocode://pair?d=example']);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('123 456 789 012'), findsOneWidget);
    expect(connection.confirmations, 0);
    expect(find.text('Connected'), findsNothing);

    await tester.tap(find.text('Codes match, pair'));
    await tester.pump();
    expect(connection.confirmations, 1);
    expect(find.text('Development Host'), findsOneWidget);
    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('123 456 789 012'), findsNothing);
  });

  testWidgets(
    'failed pairing keeps the invite and prevents duplicate submits',
    (tester) async {
      final result = Completer<void>();
      final connection = _Connection()..pairResult = result.future;
      await _pumpPage(tester, connection);
      await tester.enterText(find.byType(TextField), ' retry this invite ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.tap(find.text('Pair'));
      await tester.pump();
      expect(connection.invites, ['retry this invite']);
      expect(find.text('Working…'), findsOneWidget);
      result.completeError(const FormatException('The invite expired.'));
      await tester.pump();

      expect(find.text('The invite expired.'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        ' retry this invite ',
      );
      await tester.tap(find.text('Pair'));
      await tester.pump();
      expect(connection.invites, ['retry this invite', 'retry this invite']);
    },
  );

  testWidgets('a mismatched safety code cancels without pairing', (
    tester,
  ) async {
    final connection = _Connection()..pendingCode = '123 456 789 012';
    await _pumpPage(tester, connection);

    await tester.tap(find.text('Cancel pairing'));
    await tester.pump();

    expect(connection.cancellations, 1);
    expect(connection.confirmations, 0);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('reconnects an offline host and confirms before forgetting it', (
    tester,
  ) async {
    final connection = _Connection()..hostName = 'Development Host';
    final chats = _Chats()
      ..chats = [_Chat('project', 'Project chat', 'project')];
    await _pumpPage(tester, connection, chats: chats);
    expect(find.text('Host offline'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Project chat'), findsNothing);
    await tester.tap(find.text('Reconnect'));
    await tester.pump();
    expect(connection.reconnections, 1);
    expect(find.text('Project chat'), findsOneWidget);

    await tester.tap(find.text('Forget host'));
    await tester.pumpAndSettle();
    expect(connection.forgets, 0);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(connection.forgets, 0);
    await tester.tap(find.text('Forget host'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Forget host'),
      ),
    );
    await tester.pumpAndSettle();
    expect(connection.forgets, 1);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Project chat'), findsNothing);
  });

  testWidgets('opens only the selected chat, renders updates, and closes it', (
    tester,
  ) async {
    final connection = _Connection()..peer = _Peer();
    final chats = _Chats()
      ..chats = [
        _Chat('bot-1', 'Helper bot', 'bot'),
        _Chat('group-1', 'Team chat', 'group'),
        _Chat('project-1', 'Project chat', 'project'),
      ];
    var back = 0;
    await _pumpPage(tester, connection, chats: chats, onBack: () => back++);
    expect(chats.opens, isEmpty);
    expect(find.text('Projects'), findsOneWidget);
    expect(find.text('Bots'), findsOneWidget);
    expect(find.text('Groups'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Project chat')).dy,
      lessThan(tester.getTopLeft(find.text('Helper bot')).dy),
    );

    await tester.tap(find.text('Team chat'));
    await tester.pump();
    expect(chats.opens, ['group-1']);
    expect(find.text('Helper bot'), findsNothing);
    expect(find.text('New host message'), findsNothing);
    chats.append(_Message('New host message', 'Teammate', false));
    await tester.pump();
    expect(find.text('New host message'), findsOneWidget);
    await tester.tap(find.text('Load earlier messages'));
    await tester.pump();
    expect(find.text('From earlier'), findsOneWidget);

    await tester.tap(find.byTooltip('Back to host chats'));
    await tester.pump();
    expect(chats.closes, 1);
    expect(back, 0);
    expect(find.text('Helper bot'), findsOneWidget);
    await tester.tap(find.text('Helper bot'));
    await tester.pump();
    await tester.tap(find.byTooltip('Back'));
    await tester.pump();
    expect(chats.closes, 2);
    expect(back, 1);
  });

  testWidgets('removing the page closes the chat subscription', (tester) async {
    final connection = _Connection()..peer = _Peer();
    final chats = _Chats()
      ..chats = [_Chat('project', 'Project chat', 'project')];
    await _pumpPage(tester, connection, chats: chats);
    await tester.tap(find.text('Project chat'));
    await tester.pump();
    expect(chats.selected, isNotNull);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(chats.closes, 1);
    expect(chats.selected, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed send keeps the draft and prevents duplicate sends', (
    tester,
  ) async {
    final connection = _Connection()..peer = _Peer();
    final result = Completer<void>();
    final chats = _Chats()
      ..chats = [_Chat('project', 'Project chat', 'project')]
      ..sendResult = result.future;
    await _pumpPage(tester, connection, chats: chats);
    await tester.tap(find.text('Project chat'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '  My message  ');
    await tester.pump();
    await tester.tap(find.text('Send'));
    await tester.tap(find.text('Send'));
    await tester.pump();
    expect(chats.sends, ['My message']);
    result.completeError(const FormatException('Could not send.'));
    await tester.pump();
    expect(find.text('Could not send.'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '  My message  ',
    );

    await tester.tap(find.text('Send'));
    await tester.pump();
    expect(chats.sends, ['My message', 'My message']);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
  });

  testWidgets('restores an offline draft only within the same host chat', (
    tester,
  ) async {
    final connection = _Connection()
      ..hostName = 'Development Host'
      ..peer = _Peer();
    final chats = _Chats()
      ..chats = [_Chat('project', 'Project chat', 'project')];
    await _pumpPage(tester, connection, chats: chats);
    await tester.tap(find.text('Project chat'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'A private draft');

    connection.disconnect();
    await tester.pump();
    expect(find.text('Host offline'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.text('Reconnect'));
    await tester.pump();
    expect(find.text('A private draft'), findsOneWidget);

    connection.disconnect(revoked: true);
    // The workbench resets the chat catalog on revocation.
    chats.closeChat();
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'new host invite');
    await tester.pump();
    await tester.tap(find.text('Pair'));
    await tester.pump();
    await tester.tap(find.text('Codes match, pair'));
    await tester.pump();
    // Another host may have a chat with the same public ID.
    await tester.tap(find.text('Project chat'));
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
  });

  testWidgets('narrow Chinese pairing view fits enlarged text', (tester) async {
    tester.view.physicalSize = const Size(300, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final connection = _Connection()..pendingCode = '123 456 789 012';
    await _pumpPage(tester, connection, locale: const Locale('zh'), scale: 1.8);
    expect(find.text('核对安全码'), findsOneWidget);
    expect(find.text('安全码一致，完成配对'), findsOneWidget);
    expect(find.byTooltip('返回'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpPage(
  WidgetTester tester,
  _Connection connection, {
  _Chats? chats,
  VoidCallback? onBack,
  Locale locale = const Locale('en'),
  double scale = 1,
}) async {
  final model = chats ?? _Chats();
  addTearDown(connection.dispose);
  addTearDown(model.dispose);
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      supportedLocales: const [Locale('en'), Locale('zh')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
        body: DesktopHostPage(
          connection: connection,
          chats: model,
          onBack: onBack ?? () {},
        ),
      ),
    ),
  );
}

class _Connection extends ChangeNotifier implements DesktopHostConnection {
  @override
  String? pendingCode;
  @override
  String? hostName;
  @override
  String? error;
  @override
  bool busy = false;
  @override
  LinkPeer? peer;

  final invites = <String>[];
  int confirmations = 0;
  int cancellations = 0;
  int reconnections = 0;
  int forgets = 0;
  Future<void>? pairResult;

  @override
  Future<void> pair(String invite) async {
    invites.add(invite);
    error = null;
    final result = pairResult;
    pairResult = null;
    try {
      if (result != null) await result;
    } on FormatException catch (failure) {
      error = failure.message;
      notifyListeners();
      return;
    }
    pendingCode = '123 456 789 012';
    notifyListeners();
  }

  @override
  Future<void> confirm() async {
    confirmations++;
    pendingCode = null;
    hostName = 'Development Host';
    peer = _Peer();
    notifyListeners();
  }

  @override
  Future<void> cancelPairing() async {
    cancellations++;
    pendingCode = null;
    notifyListeners();
  }

  @override
  Future<void> reconnect() async {
    reconnections++;
    peer = _Peer();
    notifyListeners();
  }

  void disconnect({bool revoked = false}) {
    peer = null;
    if (revoked) hostName = null;
    notifyListeners();
  }

  @override
  Future<void> forget() async {
    forgets++;
    hostName = null;
    peer = null;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Peer extends Fake implements LinkPeer {}

class _Chat extends Fake implements DesktopHostChat {
  _Chat(this.id, this.title, this.kind);

  @override
  final String id;
  @override
  final String title;
  @override
  final String kind;
}

class _Message extends Fake implements DesktopHostMessage {
  _Message(this.text, this.sender, this.mine);

  @override
  final String text;
  @override
  final String sender;
  @override
  final bool mine;
}

class _Chats extends ChangeNotifier implements DesktopHostChats {
  @override
  List<DesktopHostChat> chats = [];
  @override
  DesktopHostChat? selected;
  @override
  List<DesktopHostMessage> messages = [];
  @override
  bool busy = false;
  @override
  bool hasEarlier = false;
  @override
  String? error;

  final opens = <String>[];
  final sends = <String>[];
  int closes = 0;
  Future<void>? sendResult;

  @override
  Future<void> open(DesktopHostChat chat) async {
    opens.add(chat.id);
    selected = chat;
    hasEarlier = true;
    notifyListeners();
  }

  @override
  Future<void> earlier() async {
    messages.insert(0, _Message('From earlier', 'Teammate', false));
    hasEarlier = false;
    notifyListeners();
  }

  @override
  Future<void> send(String text) async {
    sends.add(text);
    error = null;
    final result = sendResult;
    sendResult = null;
    try {
      if (result != null) await result;
    } on FormatException catch (failure) {
      error = failure.message;
    }
    notifyListeners();
  }

  void append(DesktopHostMessage message) {
    messages.add(message);
    notifyListeners();
  }

  @override
  void closeChat() {
    closes++;
    selected = null;
    messages.clear();
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
