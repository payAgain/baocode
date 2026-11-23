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

  testWidgets('switch to local remains available while opening an invite', (
    tester,
  ) async {
    final pending = Completer<void>();
    final connection = _Connection()..pairResult = pending.future;
    var back = 0;
    await _pumpPage(tester, connection, onBack: () => back++);
    await tester.enterText(find.byType(TextField), 'Development invite');
    await tester.pump();
    await tester.tap(find.text('Pair'));
    await tester.pump();
    await tester.tap(find.text('Switch to local'));
    await tester.pump();
    expect(back, 1);
    expect(connection.cancellations, 1);
    pending.complete();
    await tester.pump();
    expect(connection.pendingCode, isNull);
    expect(connection.confirmations, 0);
  });

  testWidgets('keeps pairing hidden while looking for a saved host', (
    tester,
  ) async {
    final connection = _Connection()..busy = true;
    await _pumpPage(tester, connection);
    expect(find.text('Working…'), findsOneWidget);
    expect(find.text('Pairing link'), findsNothing);
    connection.disconnect();
    await tester.pump();
    expect(find.text('Pairing link'), findsOneWidget);
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

  testWidgets('wide workspace keeps chat navigation beside the composer', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final connection = _Connection()..peer = _Peer();
    final chats = _Chats()
      ..chats = [
        _Chat('project', 'Project chat', 'project'),
        _Chat('bot', 'Helper bot', 'bot'),
      ];
    var back = 0;
    final switcher = find.ancestor(
      of: find.text('Switch to local'),
      matching: find.byWidgetPredicate((widget) => widget is FilledButton),
    );
    await _pumpPage(tester, connection, chats: chats, onBack: () => back++);
    expect(chats.opens, isEmpty);
    final switcherBounds = tester.getRect(switcher);

    await tester.tap(find.text('Project chat'));
    await tester.pump();
    final bot = find.text('Helper bot');
    expect(bot.hitTestable(), findsOneWidget);
    expect(
      tester.getRect(bot).right,
      lessThan(tester.getRect(find.byType(TextField)).left),
    );
    expect(tester.getRect(switcher), switcherBounds);
    expect(find.text('Pairing link'), findsNothing);

    await tester.tap(bot);
    await tester.pump();
    expect(chats.opens, ['project', 'bot']);
    expect(chats.selected?.id, 'bot');
    expect(back, 0);

    await tester.tap(switcher);
    await tester.pump();
    expect(chats.selected, isNull);
    expect(back, 1);
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
    await tester.tap(find.text('Switch to local'));
    await tester.pump();
    expect(chats.closes, 2);
    expect(back, 1);
  });

  testWidgets('resizing a live chat keeps its selection and draft', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final connection = _Connection()..peer = _Peer();
    final chats = _Chats()
      ..chats = [
        _Chat('project', 'Project chat', 'project'),
        _Chat('bot', 'Helper bot', 'bot'),
      ];
    await _pumpPage(tester, connection, chats: chats, scale: 2);
    await tester.tap(find.text('Project chat'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Unsent');
    final composer = tester.state<EditableTextState>(find.byType(EditableText));

    tester.view.physicalSize = const Size(300, 640);
    await tester.pump();
    expect(find.text('Helper bot'), findsNothing);
    expect(find.byTooltip('Back to host chats').hitTestable(), findsOneWidget);
    expect(find.text('Switch to local').hitTestable(), findsOneWidget);
    expect(find.text('Unsent'), findsOneWidget);
    expect(
      tester.state<EditableTextState>(find.byType(EditableText)),
      same(composer),
    );
    expect(chats.opens, ['project']);
    expect(chats.closes, 0);
    expect(tester.takeException(), isNull);
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

  testWidgets('catalog navigation retains independent chat drafts', (
    tester,
  ) async {
    final connection = _Connection()..peer = _Peer();
    final chats = _Chats()
      ..chats = [
        _Chat('same-id', 'Project chat', 'project'),
        _Chat('same-id', 'Helper bot', 'bot'),
      ];
    await _pumpPage(tester, connection, chats: chats);
    await tester.tap(find.text('Project chat'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Unsent project notes');
    await tester.tap(find.byTooltip('Back to host chats'));
    await tester.pump();

    await tester.tap(find.text('Helper bot'));
    await tester.pump();
    expect(find.text('Unsent project notes'), findsNothing);
    await tester.enterText(find.byType(TextField), 'Unsent bot notes');
    await tester.tap(find.byTooltip('Back to host chats'));
    await tester.pump();

    await tester.tap(find.text('Project chat'));
    await tester.pump();
    expect(find.text('Unsent project notes'), findsOneWidget);
    expect(chats.sends, isEmpty);
  });

  testWidgets('narrow Chinese pairing view fits enlarged text', (tester) async {
    tester.view.physicalSize = const Size(300, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final connection = _Connection()..pendingCode = '123 456 789 012';
    await _pumpPage(tester, connection, locale: const Locale('zh'), scale: 1.8);
    expect(find.text('核对安全码'), findsOneWidget);
    expect(find.text('安全码一致，完成配对'), findsOneWidget);
    expect(find.text('切回本地').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('local workspace switch preserves an unsent remote draft', (
    tester,
  ) async {
    final connection = _Connection()..peer = _Peer();
    final chats = _Chats()
      ..chats = [_Chat('project', 'Project chat', 'project')];
    var back = 0;
    await _pumpPage(tester, connection, chats: chats, onBack: () => back++);
    await tester.tap(find.text('Project chat'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Draft kept in memory');
    await tester.tap(find.text('Switch to local'));
    await tester.pump();
    expect(chats.selected, isNull);
    expect(back, 1);
    await tester.pumpWidget(const SizedBox.shrink());

    await _pumpPage(tester, connection, chats: chats, disposeModels: false);
    expect(chats.selected, isNull);
    await tester.tap(find.text('Project chat'));
    await tester.pump();
    expect(find.text('Draft kept in memory'), findsOneWidget);
    expect(chats.sends, isEmpty);
  });

  testWidgets('reconnect does not resubmit a draft with a pending reply', (
    tester,
  ) async {
    final reply = Completer<void>();
    final connection = _Connection()
      ..hostName = 'Development Host'
      ..peer = _Peer();
    final chats = _Chats()
      ..chats = [_Chat('project', 'Project chat', 'project')]
      ..sendResult = reply.future;
    await _pumpPage(tester, connection, chats: chats);
    await tester.tap(find.text('Project chat'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Check before retrying');
    await tester.pump();
    await tester.tap(find.text('Send'));
    connection.disconnect();
    await tester.pump();
    await tester.tap(find.text('Reconnect'));
    await tester.pump();
    reply.complete();
    await tester.pumpAndSettle();
    expect(find.text('Check before retrying'), findsOneWidget);
    expect(chats.sends, ['Check before retrying']);
  });

  testWidgets('restores last opened chat from this host after a page restart', (
    tester,
  ) async {
    final storage = _LastChats();
    final project = _Chat('same-id', 'Project chat', 'project');
    final bot = _Chat('same-id', 'Helper bot', 'bot');
    final connection = _Connection()..peer = _Peer('first-host');
    final chats = _Chats()..chats = [project, bot];
    await _pumpPage(tester, connection, chats: chats, lastChatStore: storage);
    await tester.pumpAndSettle();
    expect(chats.opens, isEmpty);
    await tester.tap(find.text('Helper bot'));
    await tester.pumpAndSettle();
    expect(storage.saved, {'first-host': (kind: 'bot', id: 'same-id')});
    await tester.pumpWidget(const SizedBox.shrink());

    final different = _Connection()..peer = _Peer('second-host');
    final otherChats = _Chats()..chats = [project, bot];
    await _pumpPage(
      tester,
      different,
      chats: otherChats,
      lastChatStore: storage,
    );
    await tester.pumpAndSettle();
    expect(otherChats.opens, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());

    final restarted = _Connection()..peer = _Peer('first-host');
    final restoredChats = _Chats()..busy = true;
    await _pumpPage(
      tester,
      restarted,
      chats: restoredChats,
      lastChatStore: storage,
    );
    expect(restoredChats.opens, isEmpty);
    restoredChats.catalog([project, bot]);
    await tester.pumpAndSettle();
    expect(restoredChats.selected?.kind, 'bot');
    expect(restoredChats.opens, ['same-id']);
    expect(restoredChats.sends, isEmpty);

    await tester.tap(find.byTooltip('Back to host chats'));
    await tester.pumpAndSettle();
    expect(restoredChats.selected, isNull);
    expect(restoredChats.opens, ['same-id']);
  });

  testWidgets('a late last chat read cannot override manual selection', (
    tester,
  ) async {
    final read = Completer<DesktopHostChatKey?>();
    final storage = _LastChats()..pendingRead = read.future;
    final connection = _Connection()..peer = _Peer();
    final chats = _Chats()
      ..chats = [
        _Chat('project', 'Project chat', 'project'),
        _Chat('bot', 'Helper bot', 'bot'),
      ];
    await _pumpPage(tester, connection, chats: chats, lastChatStore: storage);
    await tester.tap(find.text('Project chat'));
    await tester.pump();
    await tester.tap(find.byTooltip('Back to host chats'));
    await tester.pump();
    read.complete((kind: 'bot', id: 'bot'));
    await tester.pumpAndSettle();
    expect(chats.opens, ['project']);
    expect(chats.selected, isNull);
  });
}

Future<void> _pumpPage(
  WidgetTester tester,
  _Connection connection, {
  _Chats? chats,
  VoidCallback? onBack,
  DesktopHostLastChatStore? lastChatStore,
  Locale locale = const Locale('en'),
  double scale = 1,
  bool disposeModels = true,
}) async {
  final model = chats ?? _Chats();
  if (disposeModels) {
    addTearDown(connection.dispose);
    addTearDown(model.dispose);
  }
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
          lastChatStore: lastChatStore,
        ),
      ),
    ),
  );
}

class _LastChats implements DesktopHostLastChatStore {
  final saved = <String, ({String kind, String id})>{};
  Future<DesktopHostChatKey?>? pendingRead;

  @override
  Future<DesktopHostChatKey?> read(String host) async =>
      pendingRead == null ? saved[host] : await pendingRead;

  @override
  Future<void> write(String host, ({String kind, String id}) chat) async {
    saved[host] = chat;
  }
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
  bool _pairCancelled = false;

  @override
  Future<void> pair(String invite) async {
    _pairCancelled = false;
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
    if (_pairCancelled) return;
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
    _pairCancelled = true;
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
    busy = false;
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

class _Peer extends Fake implements LinkPeer {
  _Peer([this.remote = 'development-host-key']);

  @override
  final String remote;
}

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

  void catalog(List<DesktopHostChat> entries) {
    chats = entries;
    busy = false;
    notifyListeners();
  }

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
