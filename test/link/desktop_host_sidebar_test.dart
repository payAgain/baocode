import 'dart:convert';

import 'package:bao_link/bao_link.dart';
import 'package:bao_markdown/bao_markdown.dart' show MarkdownEditor;
import 'package:baocode/chat/chat_column.dart';
import 'package:baocode/chat/chat_width.dart';
import 'package:baocode/chat/composer/file_drop.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/link/desktop_host_connection.dart';
import 'package:baocode/link/desktop_host_page.dart';
import 'package:baocode/main.dart';
import 'package:baocode/models/secret_store.dart';
import 'package:baocode/platform/data_dir.dart';
import 'package:baocode/search/search_palette.dart';
import 'package:baocode/settings/app_locale.dart';
import 'package:baocode/settings/app_settings.dart';
import 'package:baocode/settings/user_settings.dart';
import 'package:baocode/sidebar/sidebar.dart';
import 'package:baocode/tips/feature_tips_controller.dart';
import 'package:baocode/window/app_windows.dart';
import 'package:baocode/workbench.dart';
import 'package:baocode/workspace/window_controls.dart';
import 'package:baocode/workspace/window_header/header_menu_bar.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../window/fake_window_host.dart';
import 'desktop_mutual_pairing_test.dart' show Machine, machines;
import 'my_computers_test.dart' show admit, leaveComputers, tap, tapMember;

void main() {
  setUp(() {
    final previous = SecretStore.instance;
    SecretStore.instance = MemorySecretStore();
    addTearDown(() => SecretStore.instance = previous);
  });

  testWidgets('remote workspace replaces local navigation and shortcuts', (
    tester,
  ) async {
    _sizeWindow(tester);
    final windowCalls = _windowCalls(tester);
    final (viewer, owner) = await linkedComputers();
    final workspace = viewer.workspace;
    await openWorkbench(tester, viewer);
    await tester.pump();
    final entry = find.descendant(
      of: find.byType(Sidebar),
      matching: find.text('My computers'),
    );
    expect(entry, findsOneWidget);
    final selected = workspace.current;
    final threads = workspace.threads.toList();
    await tester.tap(entry);
    await tester.pumpAndSettle();
    await tapMember(tester, owner);
    final page = find.byType(DesktopHostPage);
    expect(page, findsOneWidget);
    expect(tester.getSize(page).width, 1440);
    final column = find.descendant(of: page, matching: find.byType(ChatColumn));
    expect(column, findsOneWidget);
    final previous = ChatWidth.current.value;
    addTearDown(() => ChatWidth.current.value = previous);
    ChatWidth.current.value = 1040;
    await tester.pump();
    expect(tester.widget<ChatColumn>(column).maxWidth, 1040);
    expect(find.byType(Sidebar), findsNothing);
    expect(find.byType(HeaderMenuBar), findsNothing);
    final caption = windowCalls.lastWhere(
      (call) => call.method == 'setHitTestAreas',
    );
    expect(caption.arguments['controls'], isEmpty);
    expect(
      caption.arguments['buttons'].keys,
      unorderedEquals(['minimize', 'maximize', 'close']),
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(workspace.current, same(selected));
    expect(workspace.threads, threads);
    expect(find.byType(SearchPalette), findsNothing);
    expect(page, findsOneWidget);
    await leaveComputers(tester);
    await tester.pump();
    expect(page, findsNothing);
    expect(find.byType(Sidebar), findsOneWidget);
    expect(workspace.current, same(selected));
    await tester.pumpWidget(const SizedBox.shrink());
    await viewer.host.pauseGroupConnections();
    await owner.host.pauseGroupConnections();
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('the main window restores the last workspace across restarts', (
    tester,
  ) async {
    _sizeWindow(tester);
    final kept = <String, Object?>{};
    final page = find.byType(DesktopHostPage);

    final (viewer, owner) = await linkedComputers();
    Future<void> start() async {
      // Workbench owns/disposes its connection. Keep signed state on its host.
      final files = _SettingsFiles(kept);
      addTearDown(files.dispose);
      await openWorkbench(tester, viewer, files: files, reuseClient: false);
    }

    await start();
    expect(page, findsNothing);
    await tap(tester, 'My computers');
    await tapMember(tester, owner);
    expect(page, findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());

    await start();
    expect(page, findsOneWidget);
    final store = tester.widget<DesktopHostPage>(page).lastChatStore;
    expect(store, isNotNull);
    await store!.write('host-A', (kind: 'project', id: 'chat-1'));
    await tester.pumpWidget(const SizedBox.shrink());
    await start();
    final restored = tester.widget<DesktopHostPage>(page).lastChatStore!;
    expect(await restored.read('host-A'), (kind: 'project', id: 'chat-1'));
    expect(await restored.read('host-B'), isNull);
    await leaveComputers(tester);
    await tester.pump();
    expect(page, findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());

    await start();
    expect(page, findsNothing);
    expect(find.byType(Sidebar), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await viewer.host.pauseGroupConnections();
    await owner.host.pauseGroupConnections();
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('a stale legacy mode stays local without dialing', (
    tester,
  ) async {
    _sizeWindow(tester);
    final windowCalls = _windowCalls(tester);
    final files = _SettingsFiles({'workbench.desktopWorkspace': 'remote'});
    addTearDown(files.dispose);
    final workspace = Workspace.mock();
    addTearDown(workspace.dispose);
    final identity = LinkIdentity.generate();
    final host = LinkIdentity.generate();
    final stored = jsonEncode({
      'identity': identity.toJson(),
      'name': 'Synthetic host',
      'address': LinkAddress(host.id).toJson(),
      'direct': true,
    });
    await SecretStore.instance.write('desktop_host_connection.v1', stored);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Workbench(workspace: workspace, settings: _Settings(files)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(DesktopHostPage), findsNothing);
    await tap(tester, 'My computers');
    expect(find.byType(DesktopHostPage), findsOneWidget);
    expect(find.text('Synthetic host'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(
      find.text('Computer connections are unavailable on this installation.'),
      findsOneWidget,
    );
    expect(
      await SecretStore.instance.read('desktop_host_connection.v1'),
      stored,
    );
    expect(
      windowCalls.any(
        (call) => call.method == 'setRemoteWorkspace' && call.arguments == true,
      ),
      isTrue,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets(
    'a secondary agent window keeps its own workspace and keys',
    (tester) async {
      _sizeWindow(tester);
      final (viewer, owner) = await linkedComputers();
      final files = _SettingsFiles({
        'workbench.desktopWorkspace': 'group:${owner.host.id}',
      });
      addTearDown(files.dispose);
      // BaoCodeApp owns this local workspace. Machine owns its host workspace.
      final workspace = Workspace.mock();
      final windows = AppWindows(
        host: FakeWindowHost(tester.view),
        workspace: workspace,
        l10n: () => englishLocalizations,
        isDirectory: (_) async => true,
        nextFrame: () => tester.binding.endOfFrame,
      );
      await windows.start();
      await tester.pumpWidget(
        BaoCodeApp(
          workspace: workspace,
          windows: windows,
          settings: _Settings(files, machine: viewer),
        ),
        wrapWithView: false,
      );
      await tester.pump();
      final opening = windows.openAgent(['/synthetic']);
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      expect(await opening, isNotNull);
      final agentView = windows.agentWindows.single.viewId;
      final inAgent = find.byWidgetPredicate(
        (w) => w is View && w.view.viewId == agentView,
      );
      final page = find.byType(DesktopHostPage);
      expect(page, findsOneWidget);
      expect(find.descendant(of: inAgent, matching: page), findsNothing);
      expect(
        find.descendant(of: inAgent, matching: find.byType(Sidebar)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: inAgent, matching: find.text('My computers')),
        findsNothing,
      );

      const drop = {
        'x': 600,
        'y': 150,
        'files': [
          {'path': '/synthetic-folder', 'directory': true},
        ],
      };
      expect(
        await FileDrops.handle(const MethodCall('dragUpdate', drop)),
        isFalse,
      );
      expect(await FileDrops.handle(const MethodCall('drop', drop)), isFalse);

      WindowControls.activeViewId = windows.chat.viewId;
      await tester.tap(
        find
            .descendant(of: page, matching: find.text(owner.name))
            .hitTestable(),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find
            .descendant(
              of: page,
              matching: find.text('Optimize virtual list scrolling'),
            )
            .hitTestable(),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find
            .descendant(of: page, matching: find.byType(MarkdownEditor))
            .hitTestable(),
      );
      await tester.pump();
      WindowControls.activeViewId = windows.chat.viewId;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(find.byType(SearchPalette), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await viewer.host.pauseGroupConnections();
      await owner.host.pauseGroupConnections();
    },
    semanticsEnabled: false,
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}

Future<(Machine, Machine)> linkedComputers() async {
  final (viewer, owner) = await machines();
  await owner.host.createComputerGroup();
  await admit(owner, viewer);
  return (viewer, owner);
}

Future<void> openWorkbench(
  WidgetTester tester,
  Machine viewer, {
  SettingsFiles? files,
  bool reuseClient = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Workbench(
        workspace: viewer.workspace,
        settings: _Settings(files, machine: viewer),
        createDesktopHostConnection: () {
          if (!reuseClient) {
            return DesktopHostConnection.withDependencies(
              localHost: viewer.host,
            );
          }
          viewer.workbenchOwnsClient = true;
          return viewer.client;
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _Settings extends AppSettings {
  _Settings(SettingsFiles? files, {Machine? machine})
    : super(locale: AppLocale(), files: files, link: machine?.host);

  @override
  FeatureTipsController? get tips => null;
}

class _SettingsFiles extends SettingsFiles {
  _SettingsFiles(Map<String, Object?> kept)
    : _storage = _Storage(kept),
      super(const DataDirectory('/unused'));

  final GlobalStorage _storage;

  @override
  GlobalStorage get storage => _storage;
}

class _Storage extends GlobalStorage {
  _Storage(this.kept) : super('/unused/storage.json');
  final Map<String, Object?> kept;

  @override
  bool get loaded => true;

  @override
  Object get value => kept;

  @override
  Future<void> set(String key, Object? value) async => kept[key] = value;
}

void _sizeWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

List<MethodCall> _windowCalls(WidgetTester tester) {
  const channel = MethodChannel('baocode/window');
  final messenger = tester.binding.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  messenger.setMockMethodCallHandler(channel, (call) async {
    calls.add(call);
    return null;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  return calls;
}
