import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:baocode/chat/chat_screen.dart';
import 'package:baocode/chat/composer/file_drop.dart';
import 'package:baocode/ide/ide_chat_title.dart';
import 'package:baocode/ide/ide_welcome.dart';
import 'package:baocode/ide/ide_workbench.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/main.dart';
import 'package:baocode/search/search_palette.dart';
import 'package:baocode/sidebar/sidebar.dart';
import 'package:baocode/theme/codicons.dart';
import 'package:baocode/window/app_windows.dart';
import 'package:baocode/window/window_settings.dart';
import 'package:baocode/workbench.dart';
import 'package:baocode/workspace/open_in_editor_button.dart';
import 'package:baocode/workspace/preference_store.dart';
import 'package:baocode/workspace/workspace.dart';

import 'fake_window_host.dart';

/// The app with windows of its own, each a view of the test's engine: the
/// chat's (the test's view) and those the IDE opens.
Future<(AppWindows, FakeWindowHost, Workspace)> _pumpApp(
  WidgetTester tester, {
  WindowSettings Function()? settings,
  Workspace? withWorkspace,
}) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final messenger = tester.binding.defaultBinaryMessenger;
  for (final name in [
    'baocode/window',
    for (var id = 1; id < 6; id++) 'baocode/window.$id',
  ]) {
    messenger.setMockMethodCallHandler(
      MethodChannel(name),
      (call) async => null,
    );
    addTearDown(
      () => messenger.setMockMethodCallHandler(MethodChannel(name), null),
    );
  }
  final host = FakeWindowHost(tester.view);
  final workspace = withWorkspace ?? Workspace.mock();
  final windows = AppWindows(
    host: host,
    workspace: workspace,
    l10n: () => englishLocalizations,
    settings:
        settings ?? () => const WindowSettings(ideWindows: IdeWindows.separate),
    isDirectory: (path) async => true,
    nextFrame: () => tester.binding.endOfFrame,
  );
  await windows.start();
  await tester.pumpWidget(
    BaoCodeApp(workspace: workspace, windows: windows),
    wrapWithView: false,
  );
  await tester.pump();
  return (windows, host, workspace);
}

/// Opens [folder]'s window, the frames it takes drawn.
Future<AppWindow> _open(
  WidgetTester tester,
  AppWindows windows,
  String folder, {
  AgentThread? thread,
}) async {
  final opening = windows.showFolder(folder, thread: thread);
  for (var i = 0; i < 4; i++) {
    await tester.pump();
  }
  return (await opening)!;
}

Finder _inView(int viewId, Finder finder) => find.descendant(
  of: find.byWidgetPredicate(
    (widget) => widget is View && widget.view.viewId == viewId,
  ),
  matching: finder,
);

/// The desktop semantics check (test/semantics_tree.dart) keeps one tree
/// for all views; the windows' own (their accessibility) are left out.
void _testWindows(
  String description,
  WidgetTesterCallback callback, {
  TestVariant<Object?> variant = const DefaultTestVariant(),
}) => testWidgets(
  description,
  callback,
  semanticsEnabled: false,
  variant: variant,
);

final _desktop = TargetPlatformVariant({
  TargetPlatform.macOS,
  TargetPlatform.windows,
});

Future<Object?> _dropAt(
  Offset at,
  List<Map<String, Object>> files, {
  String method = 'drop',
}) => FileDrops.handle(
  MethodCall(method, {'x': at.dx, 'y': at.dy, 'files': files}),
);

Finder _sidebarLabel(String label) =>
    find.descendant(of: find.byType(Sidebar), matching: find.text(label));

void main() {
  _testWindows('a folder dropped in the empty sidebar project list is imported '
      'at its original path', (tester) async {
    final preferences = MemoryPreferenceStore();
    final (windows, host, workspace) = await _pumpApp(
      tester,
      withWorkspace: Workspace(preferences: preferences),
    );
    const folder = '/work/sidebar-drop';
    final emptyList = _sidebarLabel('No agents yet');
    expect(
      await _dropAt(tester.getCenter(emptyList), [
        {'path': folder, 'directory': true},
      ]),
      isTrue,
    );
    await tester.pumpAndSettle();
    expect(workspace.sidebarProjectsHere.map((project) => project.path), [
      folder,
    ]);
    final stored = await preferences.read();
    expect(stored['sidebar'], containsPair('folders', [folder]));
    expect(workspace.threads, isEmpty);
    expect(host.created, isEmpty);
    expect(windows.ideWindows, isEmpty);
  }, variant: _desktop);

  _testWindows('a mixed project-list drop routes ordinary files to the IDE', (
    tester,
  ) async {
    final (windows, _, workspace) = await _pumpApp(tester);
    final window = await _open(tester, windows, '/work');
    final delegate = FakeDelegate();
    window.attach(delegate);
    const folder = '/work/sidebar-drop';
    const file = '/work/readme.txt';
    await _dropAt(tester.getCenter(_sidebarLabel('baocode')), [
      {'path': folder, 'directory': true},
      {'path': file, 'directory': false},
    ]);
    await tester.pumpAndSettle();
    expect(
      workspace.sidebarProjectsHere.map((project) => project.path),
      contains(folder),
    );
    expect(delegate.opened.single.map((target) => target.path), [file]);
    expect(windows.ideWindows, [window]);
  }, variant: _desktop);

  _testWindows('a file-only drop on Open Project goes to the IDE', (
    tester,
  ) async {
    final (windows, _, workspace) = await _pumpApp(tester);
    final window = await _open(tester, windows, '/work');
    final delegate = FakeDelegate();
    window.attach(delegate);
    const file = '/work/readme.txt';
    await _dropAt(tester.getCenter(_sidebarLabel('Open Project')), [
      {'path': file, 'directory': false},
    ]);
    await tester.pumpAndSettle();
    expect(delegate.opened.single.map((target) => target.path), [file]);
    expect(
      workspace.projects.map((project) => project.path),
      isNot(contains(file)),
    );
  }, variant: _desktop);

  _testWindows('the Open Project row imports multiple distinct folders once', (
    tester,
  ) async {
    final (windows, host, workspace) = await _pumpApp(tester);
    final current = workspace.current;
    final threads = workspace.threads.toList();
    final existing = workspace.sidebarProjectsHere
        .map((project) => project.path)
        .toList();
    final at = tester.getCenter(_sidebarLabel('Open Project'));
    const first = '/work/sidebar-first';
    const second = '/work/sidebar-second';
    await _dropAt(at, [
      {'path': first, 'directory': true},
      {'path': second, 'directory': true},
      {'path': first, 'directory': true},
    ]);
    await tester.pump();
    await _dropAt(at, [
      {'path': '$first/', 'directory': true},
    ]);
    await tester.pumpAndSettle();
    expect(
      workspace.sidebarProjectsHere.map((project) => project.path),
      unorderedEquals([...existing, first, second]),
    );
    expect(workspace.current, same(current));
    expect(workspace.threads, threads);
    expect(host.created, isEmpty);
    expect(windows.ideWindows, isEmpty);
  }, variant: _desktop);

  _testWindows('a folder released over Search follows the window drop after '
      'hovering over a project', (tester) async {
    final (windows, _, workspace) = await _pumpApp(tester);
    const folder = '/work/outside-project-list';
    const files = [
      {'path': folder, 'directory': true},
    ];
    final atProject = tester.getCenter(_sidebarLabel('baocode'));
    expect(await _dropAt(atProject, files, method: 'dragUpdate'), isTrue);
    await _dropAt(tester.getCenter(_sidebarLabel('Search')), files);
    await tester.pumpAndSettle();
    expect(windows.ideWindows.single.folder, folder);
    expect(
      workspace.sidebarProjectsHere.map((project) => project.path),
      isNot(contains(folder)),
    );
  }, variant: _desktop);

  _testWindows('an IDE window is a view of its own: its workbench the IDE, '
      'the chat\'s window without it', (tester) async {
    final (windows, host, workspace) = await _pumpApp(tester);
    expect(find.byType(Workbench), findsOneWidget);
    expect(find.byType(IdeWorkbench), findsNothing);

    final window = await _open(tester, windows, '~/code/baocode');
    expect(find.byType(Workbench), findsNWidgets(2));
    expect(_inView(window.viewId, find.byType(IdeWorkbench)), findsOneWidget);
    expect(_inView(0, find.byType(IdeWorkbench)), findsNothing);
    expect(window.delegate, isNotNull);
    expect(window.delegate!.ideSpace, isNotNull);
    expect(host.titles[window.viewId], 'baocode — BaoCode');

    // Asking the IDE in the chat's window goes to the IDE's.
    workspace.layout = WorkspaceLayout.ide;
    await tester.pump();
    await tester.pump();
    expect(_inView(0, find.byType(IdeWorkbench)), findsNothing);
    expect(host.created, hasLength(1));
  });

  _testWindows('the same agent in both windows is the same, its tab the '
      'IDE\'s chat', (tester) async {
    final (windows, _, workspace) = await _pumpApp(tester);
    final thread = workspace.threads.first;
    final window = await _open(
      tester,
      windows,
      thread.project.path,
      thread: thread,
    );
    workspace.openInIde(thread);
    await tester.pump();
    await tester.pump();
    final title = tester.widget<IdeChatTitle>(
      _inView(window.viewId, find.byType(IdeChatTitle)),
    );
    expect(title.tabs, contains(same(thread)));
    expect(title.current, same(thread));
  });

  _testWindows('an agent\'s window (Open with BaoCode): its agent\'s '
      'conversation, a view of its own; closed, it goes', (tester) async {
    final (windows, host, workspace) = await _pumpApp(tester);
    final opening = windows.openAgent(['~/code/baocode']);
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    final thread = (await opening)!;
    final window = windows.agentWindows.single;
    expect(find.byType(Workbench), findsNWidgets(2));
    final chat = _inView(window.viewId, find.byType(ChatScreen));
    expect(chat, findsOneWidget);
    expect(tester.widget<ChatScreen>(chat).session, same(thread.session));
    // Wide, its sidebar is docked, as the chat's window's.
    expect(_inView(window.viewId, find.byType(Sidebar)), findsOneWidget);
    expect(_inView(window.viewId, find.byType(IdeWorkbench)), findsNothing);
    // The chat's window keeps its own.
    expect(_inView(0, find.byType(Sidebar)), findsOneWidget);
    expect(workspace.current, isNot(same(thread)));

    final closing = windows.requestClose(window);
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }
    expect(await closing, isTrue);
    expect(find.byType(Workbench), findsOneWidget);
    expect(host.views, isEmpty);
    expect(workspace.threads, isNot(contains(thread)));
  });

  testWidgets(
    'an agent\'s window has the sidebar, as the chat\'s: '
    'its toggle slides it out while narrow; an agent picked there shows in '
    'the window in place of its own',
    (tester) async {
      final (windows, host, workspace) = await _pumpApp(tester);
      final opening = windows.openAgent(['~/code/baocode']);
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      final thread = (await opening)!;
      final window = windows.agentWindows.single;
      host.views[window.viewId]!.physicalSize = const Size(520, 760);
      await tester.pump();
      await tester.pump();
      final sidebar = _inView(window.viewId, find.byType(Sidebar));
      expect(sidebar, findsNothing);

      final current = workspace.current;
      await tester.tap(
        _inView(
          window.viewId,
          find.widgetWithIcon(SidebarIconButton, Codicons.layoutSidebarLeftOff),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(sidebar, findsOneWidget);
      expect(tester.widget<Sidebar>(sidebar).current, same(thread));

      final other = workspace.threads.firstWhere(
        (t) => !identical(t, thread) && !t.untouched,
      );
      await tester.tap(
        find.descendant(of: sidebar, matching: find.text(other.title)).first,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(window.thread, same(other));
      expect(
        tester
            .widget<ChatScreen>(_inView(window.viewId, find.byType(ChatScreen)))
            .session,
        same(other.session),
      );
      expect(host.titles[window.viewId], contains(other.title));
      // The chat's window keeps its own; the new agent nothing was sent to
      // goes, as with its window closed.
      expect(workspace.current, same(current));
      expect(workspace.threads, isNot(contains(thread)));
    },
    semanticsEnabled: false,
    // Its toggle is the header's on Windows, by the traffic lights on macOS.
    variant: TargetPlatformVariant({
      TargetPlatform.windows,
      TargetPlatform.macOS,
    }),
  );

  for (final ideWindows in IdeWindows.values) {
    _testWindows('an agent\'s window\'s Open in Fast Ide shows its project\'s '
        'IDE there, the agent its chat, the window behind left alone '
        '(${ideWindows.name})', (tester) async {
      final (windows, host, workspace) = await _pumpApp(
        tester,
        settings: () => WindowSettings(ideWindows: ideWindows),
      );
      final opening = windows.openAgent(['~/code/baocode']);
      for (var i = 0; i < 4; i++) {
        await tester.pump();
      }
      final thread = (await opening)!;
      final window = windows.agentWindows.single;
      final layout = workspace.layout;

      await tester.tap(
        find
            .descendant(
              of: _inView(window.viewId, find.byType(OpenInEditorButton)),
              matching: find.text('Fast Ide'),
            )
            .first,
      );
      for (var i = 0; i < 3; i++) {
        await tester.pump();
      }
      final ide = _inView(window.viewId, find.byType(IdeWorkbench));
      expect(ide, findsOneWidget);
      expect(window.delegate!.ideSpace!.root, '~/code/baocode');
      final title = tester.widget<IdeChatTitle>(
        _inView(window.viewId, find.byType(IdeChatTitle)),
      );
      expect(title.current, same(thread));
      // No other window opens or comes up for it.
      expect(host.created, hasLength(1));
      expect(windows.active, same(window));
      expect(workspace.layout, layout);
      expect(_inView(0, find.byType(IdeWorkbench)), findsNothing);

      tester.widget<IdeWorkbench>(ide).onBack();
      await tester.pump();
      await tester.pump();
      expect(ide, findsNothing);
      expect(_inView(window.viewId, find.byType(ChatScreen)), findsOneWidget);
    });
  }

  _testWindows('a window closed goes, its view and its workbench', (
    tester,
  ) async {
    final (windows, host, _) = await _pumpApp(tester);
    final window = await _open(tester, windows, '~/code/baocode');
    final closing = windows.requestClose(window);
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }
    expect(await closing, isTrue);
    expect(find.byType(Workbench), findsOneWidget);
    expect(host.views, isEmpty);
    expect(window.delegate, isNull);
  });

  _testWindows('Open Folder in a window builds it anew for the folder', (
    tester,
  ) async {
    final (windows, _, _) = await _pumpApp(tester);
    final window = await _open(tester, windows, '~/code/baocode');
    final before = window.delegate;
    final replacing = windows.replaceFolder(window, '~/code/cursor-docs');
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }
    await replacing;
    expect(window.folder, '~/code/cursor-docs');
    expect(window.delegate, isNotNull);
    expect(window.delegate, isNot(same(before)));
    expect(find.byType(Workbench), findsNWidgets(2));
  });

  _testWindows('Switch Window shows in the window it was asked in', (
    tester,
  ) async {
    final (windows, _, _) = await _pumpApp(tester);
    final window = await _open(tester, windows, '~/code/baocode');
    windows.switchWindow(window);
    await tester.pump();
    await tester.pump();
    expect(
      _inView(window.viewId, find.text('Select a window to switch to')),
      findsOneWidget,
    );
    expect(_inView(0, find.text('Select a window to switch to')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
  });

  _testWindows('window.ideWindows switched: the IDE moves into the main '
      'window, and back to a window of its own', (tester) async {
    var settings = const WindowSettings(ideWindows: IdeWindows.separate);
    final (windows, host, _) = await _pumpApp(tester, settings: () => settings);
    final window = await _open(tester, windows, '~/code/baocode');

    settings = const WindowSettings(ideWindows: IdeWindows.mainWindow);
    windows.settingsChanged();
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    expect(windows.multi, isFalse);
    expect(host.views, isEmpty);
    expect(window.delegate, isNull);
    expect(find.byType(Workbench), findsOneWidget);
    expect(_inView(0, find.byType(IdeWorkbench)), findsOneWidget);
    expect(windows.chat.delegate!.ideSpace!.root, '~/code/baocode');

    settings = const WindowSettings(ideWindows: IdeWindows.separate);
    windows.settingsChanged();
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }
    expect(windows.multi, isTrue);
    expect(host.created, hasLength(2));
    final moved = windows.ideWindows.single;
    expect(moved.folder, '~/code/baocode');
    expect(_inView(moved.viewId, find.byType(IdeWorkbench)), findsOneWidget);
    // The main window's IDE is gone, not only hidden.
    expect(
      _inView(0, find.byType(IdeWorkbench, skipOffstage: false)),
      findsNothing,
    );
  });

  _testWindows('the IDE in the main window: New Window (⇧⌘N) from the chat '
      'shows its start page there', (tester) async {
    final (windows, host, _) = await _pumpApp(
      tester,
      settings: () => const WindowSettings(ideWindows: IdeWindows.mainWindow),
    );
    expect(windows.started, isTrue);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }
    expect(host.created, isEmpty);
    expect(_inView(0, find.byType(IdeStartPage)), findsOneWidget);
  });

  _testWindows('an agent\'s window has the search palette (Ctrl+Shift+P), '
      'its commands the window\'s, Preferences: Color Theme among them', (
    tester,
  ) async {
    final (windows, _, _) = await _pumpApp(tester);
    final opening = windows.openAgent(['~/code/baocode']);
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    await opening;
    final window = windows.agentWindows.single;
    // The keyboard is the agent's window's (its composer has the focus).
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<View>()
          ?.view
          .viewId,
      window.viewId,
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }
    expect(_inView(window.viewId, find.byType(SearchPalette)), findsOneWidget);
    expect(_inView(0, find.byType(SearchPalette)), findsNothing);
    final palette = tester.widget<SearchPalette>(
      _inView(window.viewId, find.byType(SearchPalette)),
    );
    expect(
      palette.actions.map((action) => action.id),
      contains('workbench.action.selectTheme'),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 200));
  });
}
