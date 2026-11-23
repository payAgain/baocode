import 'dart:convert';

import 'package:bao_link/bao_link.dart';
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
    final workspace = Workspace.mock();
    await tester.pumpWidget(BaoCodeApp(workspace: workspace));
    await tester.pump();
    final entry = find.descendant(
      of: find.byType(Sidebar),
      matching: find.text('Switch to remote workspace'),
    );
    expect(entry, findsOneWidget);
    final selected = workspace.current;
    final threads = workspace.threads.toList();
    await tester.tap(entry);
    await tester.pump();
    final page = find.byType(DesktopHostPage);
    expect(page, findsOneWidget);
    expect(tester.getSize(page).width, 1440);
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
    await tester.tap(find.text('Switch to local'));
    await tester.pump();
    expect(page, findsNothing);
    expect(find.byType(Sidebar), findsOneWidget);
    expect(workspace.current, same(selected));
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('the main window restores the last workspace across restarts', (
    tester,
  ) async {
    _sizeWindow(tester);
    final kept = <String, Object?>{};
    final page = find.byType(DesktopHostPage);

    Future<void> start() async {
      final files = _SettingsFiles(kept);
      addTearDown(files.dispose);
      await tester.pumpWidget(
        BaoCodeApp(workspace: Workspace.mock(), settings: _Settings(files)),
      );
      await tester.pump();
    }

    await start();
    expect(page, findsNothing);
    await tester.tap(find.text('Switch to remote workspace'));
    await tester.pump();
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
    await tester.tap(find.text('Switch to local'));
    await tester.pump();
    expect(page, findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());

    await start();
    expect(page, findsNothing);
    expect(find.byType(Sidebar), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('a legacy pairing restores the remote workspace even offline', (
    tester,
  ) async {
    _sizeWindow(tester);
    final windowCalls = _windowCalls(tester);
    final files = _SettingsFiles({});
    addTearDown(files.dispose);
    final workspace = Workspace.mock();
    addTearDown(workspace.dispose);
    final identity = LinkIdentity.generate();
    final host = LinkIdentity.generate();
    await SecretStore.instance.write(
      'desktop_host_connection.v1',
      jsonEncode({
        'identity': identity.toJson(),
        'name': 'Synthetic host',
        'address': LinkAddress(host.id).toJson(),
        'direct': true,
      }),
    );
    var dials = 0;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [AppLocalizations.delegate],
        home: Workbench(
          workspace: workspace,
          settings: _Settings(files),
          createDesktopHostConnection: () =>
              DesktopHostConnection.withDependencies(
                store: SecretStore.instance,
                bind: (_, _) async {
                  dials++;
                  throw const LinkClosedException();
                },
                device: () async => throw StateError('Host is offline'),
              ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(DesktopHostPage), findsOneWidget);
    expect(find.text('Synthetic host'), findsWidgets);
    expect(dials, 1);
    expect(files.storage.get<String>('workbench.desktopWorkspace'), 'remote');
    expect(
      windowCalls.any(
        (call) => call.method == 'setRemoteWorkspace' && call.arguments == true,
      ),
      isTrue,
    );
    final gesture = await tester.startGesture(const Offset(600, 15));
    await gesture.moveBy(const Offset(60, 0));
    await gesture.up();
    await tester.pump();
    expect(windowCalls.any((call) => call.method == 'dragWindow'), isTrue);
    WindowControls.menuCommandsOf(0)!.call('workbench.action.files.openFolder');
    await tester.pump();
    expect(windowCalls.any((call) => call.method == 'pickDirectory'), isFalse);
    await tester.tap(find.text('Switch to local'));
    await tester.pump();
    expect(
      windowCalls
          .lastWhere((call) => call.method == 'setRemoteWorkspace')
          .arguments,
      isFalse,
    );
    expect(find.text('Switch to Synthetic host'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets(
    'a secondary agent window keeps its own workspace and keys',
    (tester) async {
      _sizeWindow(tester);
      final files = _SettingsFiles({'workbench.desktopWorkspace': 'remote'});
      addTearDown(files.dispose);
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
          settings: _Settings(files),
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
      expect(find.text('Switch to remote workspace'), findsNothing);

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
        find.descendant(of: page, matching: find.byType(TextField)).first,
      );
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(find.byType(SearchPalette), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    semanticsEnabled: false,
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}

class _Settings extends AppSettings {
  _Settings(SettingsFiles files) : super(locale: AppLocale(), files: files);

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
