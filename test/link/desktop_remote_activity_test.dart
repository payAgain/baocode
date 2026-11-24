import 'dart:async';

import 'package:bao_editor/monaco/vs/workbench/services/themes/common/color_theme_data.dart';
import 'package:bao_link/bao_link.dart';
import 'package:baocode/ide/ide_code_diff.dart';
import 'package:baocode/ide/ide_list.dart';
import 'package:baocode/l10n/app_localizations.dart';
import 'package:baocode/link/desktop_host_chats.dart';
import 'package:baocode/link/desktop_remote_activity.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:baocode/theme/workbench_theme.dart' as workbench;
import 'package:baocode/theme/workbench_theme_initial_colors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('activity uses the workbench light sidebar palette', (
    tester,
  ) async {
    final original = workbench.WorkbenchThemeService.instance;
    final light = workbench.WorkbenchThemeService(
      initial: ColorThemeData.createUnloadedThemeForThemeType(
        workbench.ColorScheme.light,
        colorThemeLightInitialColors,
      ),
    );
    workbench.WorkbenchThemeService.instance = light;
    addTearDown(() {
      workbench.WorkbenchThemeService.instance = original;
      light.dispose();
    });
    final theme = buildAppTheme();
    expect(theme.brightness, Brightness.light);
    final host = await _Host.show(tester, theme: theme);
    await _tap(tester, find.byTooltip('Host activity'));

    final title = find.text('Host activity');
    final surface = tester
        .element(title)
        .findAncestorWidgetOfExactType<Material>();
    expect(surface?.color, AppColors.background);
    expect(tester.widget<Text>(title).style?.color, AppColors.textPrimary);

    TextButton tab(String label) =>
        tester.widget<TextButton>(find.widgetWithText(TextButton, label));
    expect(
      tab('Tasks').style?.backgroundColor?.resolve({}),
      IdeListColors.inactiveSelection,
    );
    expect(
      tab('Changes').style?.foregroundColor?.resolve({}),
      AppColors.textMuted,
    );
    expect(
      tester.widget<Text>(find.text('No tasks in this session.')).style?.color,
      AppColors.textMuted,
    );

    await _tap(tester, find.text('Changes'));
    expect(
      tab('Tasks').style?.foregroundColor?.resolve({}),
      AppColors.textMuted,
    );
    expect(
      tab('Changes').style?.backgroundColor?.resolve({}),
      IdeListColors.inactiveSelection,
    );
    expect(find.text('No pending changes in this session.'), findsOneWidget);
    await _tap(tester, find.byTooltip('Close host activity'));
    expect(title, findsNothing);
    expect(host.methods, [LinkMethods.open]);
    await host.close(tester);
  });

  testWidgets('header launch docks host tasks alongside the live chat', (
    tester,
  ) async {
    final host = await _Host.show(tester);
    host.push('session-a', tasks: [_task('one')]);
    await tester.pumpAndSettle();
    expect(find.text('Fixture task one'), findsNothing);
    final chat = find.byType(TextField);
    final editable = find.descendant(
      of: chat,
      matching: find.byType(EditableText),
    );
    final editor = tester.state(editable);
    await tester.enterText(chat, 'unsent draft');
    await _tap(tester, find.byTooltip('Host activity'));
    expect(find.text('Fixture task one'), findsOneWidget);
    expect(find.text('Command task · Running'), findsOneWidget);
    expect(find.text('synthetic command'), findsOneWidget);
    expect(chat.hitTestable(), findsOneWidget);
    expect(
      tester.getRect(chat).right,
      lessThan(tester.getRect(find.text('Fixture task one')).left),
    );
    expect(tester.state(editable), same(editor));
    expect(find.text('unsent draft'), findsOneWidget);
    host.push('session-b', tasks: [_task('other')]);
    host.push('session-a', tasks: [_task('one', status: 'succeeded')]);
    await tester.pumpAndSettle();
    expect(find.text('Fixture task other'), findsNothing);
    expect(find.text('Command task · Succeeded'), findsOneWidget);
    expect(host.methods, [LinkMethods.open]);
    await host.close(tester);
  });

  testWidgets(
    'running output follows offsets and cleans up on session switch',
    (tester) async {
      final host = await _Host.show(tester);
      final watched = Completer<Object?>();
      host.reply = (method, _) =>
          method == LinkMethods.watchOutput ? watched.future : null;
      host.push('session-a', tasks: [_task('one')]);
      await tester.pumpAndSettle();
      await _tap(tester, find.byTooltip('Host activity'));
      await _tap(tester, find.text('View output'));
      host.expectLast(LinkMethods.watchOutput, {
        'session': 'session-a',
        'task': 'one',
      });
      host.output('session-a', 'one', 'def', 6);
      watched.complete({'text': 'abc', 'offset': 3});
      await tester.pumpAndSettle();
      expect(find.text('abcdef'), findsOneWidget);
      host.output('elsewhere', 'one', 'bad', 9);
      host.output('session-a', 'elsewhere', 'bad', 9);
      host.output('session-a', 'one', 'dup', 6);
      await tester.pumpAndSettle();
      expect(find.text('abcdef'), findsOneWidget);
      host.output('session-a', 'one', 'reset', 5, reset: true);
      await tester.pumpAndSettle();
      expect(find.text('reset'), findsOneWidget);
      await host.select('session-b', 'project-b');
      await tester.pumpAndSettle();
      host.expectLast(LinkMethods.unwatchOutput, {
        'session': 'session-a',
        'task': 'one',
      });
      expect(find.text('reset'), findsNothing);
      await host.close(tester);
    },
  );

  testWidgets('a removed task closes its watch within the same session', (
    tester,
  ) async {
    final host = await _Host.show(tester);
    host.reply = (method, _) => method == LinkMethods.watchOutput
        ? {'text': 'fixture output', 'offset': 14}
        : null;
    host.push('session-a', tasks: [_task('one')]);
    await tester.pumpAndSettle();
    await _tap(tester, find.byTooltip('Host activity'));
    await _tap(tester, find.text('View output'));
    expect(find.text('fixture output'), findsOneWidget);
    host.push('session-a');
    await tester.pumpAndSettle();
    host.expectLast(LinkMethods.unwatchOutput, {
      'session': 'session-a',
      'task': 'one',
    });
    expect(find.text('fixture output'), findsNothing);
    await host.close(tester);
  });

  testWidgets(
    'running output falls back to a snapshot if watch is unsupported',
    (tester) async {
      final host = await _Host.show(tester);
      host.reply = (method, _) => switch (method) {
        LinkMethods.watchOutput => throw const LinkRemoteException(
          LinkErrors.unknown,
          'old host',
        ),
        LinkMethods.output => {'text': 'read-only snapshot'},
        _ => null,
      };
      host.push('session-a', tasks: [_task('one')]);
      await tester.pumpAndSettle();
      await _tap(tester, find.byTooltip('Host activity'));
      await _tap(tester, find.text('View output'));
      expect(find.text('read-only snapshot'), findsOneWidget);
      expect(host.methods, [
        LinkMethods.open,
        LinkMethods.watchOutput,
        LinkMethods.output,
      ]);
      await host.close(tester);
      expect(host.methods, [
        LinkMethods.open,
        LinkMethods.watchOutput,
        LinkMethods.output,
      ]);
    },
  );

  testWidgets('a late watch is unwatched after the panel is disposed', (
    tester,
  ) async {
    final host = await _Host.show(tester);
    final watched = Completer<Object?>();
    host.reply = (method, _) =>
        method == LinkMethods.watchOutput ? watched.future : null;
    host.push('session-a', tasks: [_task('one')]);
    await tester.pumpAndSettle();
    await _tap(tester, find.byTooltip('Host activity'));
    await _tap(tester, find.text('View output'));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(host.methods, [LinkMethods.open, LinkMethods.watchOutput]);
    watched.complete({'text': 'late', 'offset': 4});
    await tester.pumpAndSettle();
    host.expectLast(LinkMethods.unwatchOutput, {
      'session': 'session-a',
      'task': 'one',
    });
    expect(tester.takeException(), isNull);
    await host.close(tester);
  });

  testWidgets(
    'completed output is read once and running tasks stop after confirmation',
    (tester) async {
      final host = await _Host.show(tester);
      host.reply = (method, _) => switch (method) {
        LinkMethods.output => {'text': 'completed output'},
        _ => null,
      };
      host.push(
        'session-a',
        tasks: [
          _task('running'),
          _task('done', status: 'succeeded'),
        ],
      );
      await tester.pumpAndSettle();
      await _tap(tester, find.byTooltip('Host activity'));
      await _tap(tester, find.text('View output').last);
      expect(find.text('completed output'), findsOneWidget);
      host.expectLast(LinkMethods.output, {
        'session': 'session-a',
        'task': 'done',
      });
      await _tap(tester, find.byTooltip('Back to tasks'));
      await _tap(tester, find.text('Stop task'));
      expect(host.methods, [LinkMethods.open, LinkMethods.output]);
      expect(find.textContaining('Fixture host'), findsOneWidget);
      await _tap(tester, find.text('Cancel'));
      expect(host.methods, [LinkMethods.open, LinkMethods.output]);
      await _tap(tester, find.text('Stop task'));
      await _tap(
        tester,
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(TextButton, 'Stop task'),
        ),
      );
      host.expectLast(LinkMethods.stopTask, {
        'session': 'session-a',
        'task': 'running',
      });
      expect(find.text('Command task · Running'), findsOneWidget);
      expect(host.methods, [
        LinkMethods.open,
        LinkMethods.output,
        LinkMethods.stopTask,
      ]);
      await host.close(tester);
    },
  );
  testWidgets(
    'change review confirms one advertised path and waits for host state',
    (tester) async {
      final host = await _Host.show(tester);
      const first = {
        'path': 'src/First.dart',
        'added': 4,
        'removed': 2,
        'revision': 'kept-revision',
      };
      const second = {
        'path': 'bin/Second',
        'kind': 'added',
        'binary': true,
        'tracked': false,
      };
      host.push('session-a', changes: [first, second]);
      await tester.pumpAndSettle();
      await _tap(tester, find.byTooltip('Host activity'));
      await _tap(tester, find.text('Changes'));
      expect(find.text('src/First.dart'), findsOneWidget);
      expect(find.text('Modified · +4 −2'), findsOneWidget);
      expect(find.text('Added · Binary · Untracked'), findsOneWidget);
      await _tap(tester, find.text('Keep').first);
      expect(host.methods, [LinkMethods.open]);
      expect(find.text('src/First.dart'), findsNWidgets(2));
      await _tap(tester, find.text('Cancel'));
      expect(host.methods, [LinkMethods.open]);
      await _tap(tester, find.text('Keep').first);
      await _tap(tester, _confirmButton('Keep'));
      host.expectLast(LinkMethods.keep, {
        'session': 'session-a',
        'paths': ['src/First.dart'],
        'expectedChange': 'kept-revision',
      });
      expect(find.text('src/First.dart'), findsOneWidget);
      expect(find.text('Waiting for host'), findsOneWidget);
      expect(find.text('bin/Second'), findsOneWidget);
      host.push('session-a', changes: [second]);
      await tester.pumpAndSettle();
      expect(find.text('src/First.dart'), findsNothing);
      await _tap(tester, find.text('Undo'));
      await _tap(tester, _confirmButton('Undo'));
      host.expectLast(LinkMethods.undo, {
        'session': 'session-a',
        'paths': ['bin/Second'],
      });
      expect(find.text('bin/Second'), findsOneWidget);
      await host.close(tester);
    },
  );

  testWidgets('a legacy no-op times out without claiming success', (
    tester,
  ) async {
    final host = await _Host.show(tester);
    const change = {'path': 'src/First.dart', 'added': 1};
    host.push('session-a', changes: [change]);
    await tester.pumpAndSettle();
    await _tap(tester, find.byTooltip('Host activity'));
    await _tap(tester, find.text('Changes'));
    expect(find.text('Preview diff'), findsNothing);
    await _tap(tester, find.text('Undo'));
    await _tap(tester, _confirmButton('Undo'));
    expect(find.text('Waiting for host'), findsOneWidget);
    host.push('session-a', changes: [change], tasks: [_task('unrelated')]);
    await tester.pump(const Duration(seconds: 12));
    await tester.pumpAndSettle();
    expect(find.text('Waiting for host'), findsNothing);
    expect(
      find.text('The host did not confirm that this change was resolved.'),
      findsOneWidget,
    );
    expect(find.text('src/First.dart'), findsOneWidget);
    expect(find.text('Undo').hitTestable(), findsOneWidget);
    await host.close(tester);
  });

  testWidgets('an undo conflict leaves the pending row and explains why', (
    tester,
  ) async {
    final host = await _Host.show(tester);
    host.reply = (method, _) => throw const LinkRemoteException(
      'conflict',
      'The change is still pending.',
    );
    host.push(
      'session-a',
      changes: const [
        {'path': 'shared/note.txt', 'revision': 'review-1', 'undoable': true},
      ],
    );
    await tester.pumpAndSettle();
    await _tap(tester, find.byTooltip('Host activity'));
    await _tap(tester, find.text('Changes'));
    await _tap(tester, find.text('Undo'));
    await _tap(tester, _confirmButton('Undo'));
    expect(
      find.text('Undo conflicted. The change is still pending.'),
      findsOneWidget,
    );
    expect(find.text('shared/note.txt'), findsOneWidget);
    expect(find.text('Waiting for host'), findsNothing);
    await host.close(tester);
  });

  testWidgets('a confirmed diff reads only the advertised review revision', (
    tester,
  ) async {
    final host = await _Host.show(tester);
    const path = 'shared (2)/note.txt';
    final response = Completer<Object?>();
    host.reply = (method, _) =>
        method == LinkMethods.read ? response.future : null;
    host.push(
      'session-a',
      changes: const [
        {'path': path, 'revision': 'review-1', 'preview': true},
      ],
    );
    await tester.pumpAndSettle();
    await _tap(tester, find.byTooltip('Host activity'));
    await _tap(tester, find.text('Changes'));
    await _tap(tester, find.text('Preview diff'));
    expect(find.textContaining('Fixture host'), findsOneWidget);
    expect(host.methods, [LinkMethods.open]);
    await _tap(tester, find.text('Cancel'));
    expect(host.methods, [LinkMethods.open]);
    await _tap(tester, find.text('Preview diff'));
    await _tap(tester, _confirmButton('Preview diff'));
    host.expectLast(LinkMethods.read, {
      'session': 'session-a',
      'path': path,
      'expectedChange': 'review-1',
    });
    response.complete({'original': 'before\n', 'text': 'after\n'});
    await tester.pumpAndSettle();
    final diff = tester.widget<IdeCodeDiff>(find.byType(IdeCodeDiff));
    expect(diff.original, 'before\n');
    expect(diff.modified, 'after\n');
    expect(diff.onEdit, isNull);
    host.push(
      'session-a',
      changes: const [
        {'path': path, 'revision': 'review-2', 'preview': true},
      ],
    );
    await tester.pumpAndSettle();
    expect(find.byType(IdeCodeDiff), findsNothing);
    await host.close(tester);
  });

  testWidgets('an old confirmation cannot undo a changed record or session', (
    tester,
  ) async {
    final host = await _Host.show(tester);
    host.push(
      'session-a',
      changes: const [
        {'path': 'src/shared.dart', 'added': 1},
      ],
    );
    await tester.pumpAndSettle();
    await _tap(tester, find.byTooltip('Host activity'));
    await _tap(tester, find.text('Changes'));
    await _tap(tester, find.text('Undo'));
    host.push(
      'session-a',
      changes: const [
        {'path': 'src/shared.dart', 'added': 2},
      ],
    );
    await tester.pumpAndSettle();
    await _tap(tester, _confirmButton('Undo'));
    expect(host.methods, [LinkMethods.open]);
    expect(
      find.text('This change has changed on the host. Review it again.'),
      findsOneWidget,
    );
    await _tap(tester, find.text('Undo'));
    await host.select('session-b', 'project-b');
    await tester.pumpAndSettle();
    await _tap(tester, _confirmButton('Undo'));
    expect(host.methods, [LinkMethods.open, LinkMethods.open]);
    await host.close(tester);
  });

  testWidgets(
    'Chinese project view lists out-of-project paths without mutation controls',
    (tester) async {
      final host = await _Host.show(tester, locale: const Locale('zh'));
      host.push(
        'session-a',
        changes: const [
          {'path': '/remote/outside.txt', 'added': 1},
          {'path': 'C:/outside.txt', 'added': 1},
          {'path': 'sub/../../outside.txt', 'added': 1},
        ],
      );
      await tester.pumpAndSettle();
      await _tap(tester, find.byTooltip('主机活动'));
      await _tap(tester, find.text('更改'));
      expect(find.text('所选项目之外'), findsNWidgets(3));
      expect(find.text('保留'), findsNothing);
      expect(find.text('撤销'), findsNothing);
      expect(host.methods, [LinkMethods.open]);
      await host.close(tester);
    },
  );

  testWidgets(
    'extension inventory shows host details only for the selected project',
    (tester) async {
      final host = await _Host.show(tester);
      host.reply = (method, _) => method == LinkMethods.extensions
          ? {
              'items': [
                const LinkExtension(
                  kind: 'mcp',
                  scope: 'user',
                  name: 'Host service',
                  description: 'https://example.invalid/endpoint',
                  enabled: false,
                ).toJson(),
                const LinkExtension(
                  kind: 'skill',
                  scope: 'project',
                  name: 'First skill',
                  project: 'project-a',
                ).toJson(),
                const LinkExtension(
                  kind: 'agent',
                  scope: 'local',
                  name: 'Other project agent',
                  project: 'project-b',
                ).toJson(),
                const LinkExtension(
                  kind: 'plugin',
                  scope: 'plugin',
                  name: 'Host plugin',
                  enabled: true,
                ).toJson(),
                const LinkExtension(
                  kind: 'skill',
                  scope: 'project',
                  name: 'Unscoped project skill',
                ).toJson(),
              ],
            }
          : null;
      await _tap(tester, find.byTooltip('Host activity'));
      expect(host.methods, [LinkMethods.open]);
      await _tap(tester, find.text('Extensions'));
      host.expectLast(LinkMethods.extensions, {});
      expect(find.text('MCP server · User · Disabled'), findsOneWidget);
      expect(find.text('Skill · Project'), findsOneWidget);
      expect(find.text('Plugin · Plugin · Enabled'), findsOneWidget);
      expect(
        find.widgetWithText(SelectableText, 'https://example.invalid/endpoint'),
        findsOneWidget,
      );
      expect(find.text('Other project agent'), findsNothing);
      expect(find.text('Unscoped project skill'), findsNothing);
      expect(host.methods, [LinkMethods.open, LinkMethods.extensions]);
      await host.close(tester);
    },
  );

  testWidgets(
    'a late extension request does not populate the newly selected project',
    (tester) async {
      final host = await _Host.show(tester);
      final pending = Completer<Object?>();
      host.reply = (method, _) =>
          method == LinkMethods.extensions ? pending.future : null;
      await _tap(tester, find.byTooltip('Host activity'));
      await _tap(tester, find.text('Extensions'));
      await host.select('session-b', 'project-b');
      await tester.pumpAndSettle();
      host.reply = (method, _) =>
          throw const LinkRemoteException(LinkErrors.unknown, 'old host');
      await _tap(tester, find.byTooltip('Host activity'));
      await _tap(tester, find.text('Extensions'));
      pending.complete({
        'items': [
          const LinkExtension(
            kind: 'skill',
            scope: 'user',
            name: 'Stale skill',
          ).toJson(),
        ],
      });
      await tester.pumpAndSettle();
      expect(
        find.text('This host does not provide its extension inventory.'),
        findsOneWidget,
      );
      expect(find.text('Stale skill'), findsNothing);
      await host.close(tester);
    },
  );

  testWidgets('refresh replaces the extension inventory in the open tab', (
    tester,
  ) async {
    final host = await _Host.show(tester);
    host.reply = (_, _) => {'items': []};
    await _tap(tester, find.byTooltip('Host activity'));
    await _tap(tester, find.text('Extensions'));
    expect(
      find.text('No host extensions reported for this project.'),
      findsOneWidget,
    );

    host.reply = (_, _) => {
      'items': [
        const LinkExtension(
          kind: 'skill',
          scope: 'user',
          name: 'New skill',
        ).toJson(),
      ],
    };
    await _tap(tester, find.text('Refresh'));
    expect(find.text('New skill'), findsOneWidget);
    expect(host.methods, [
      LinkMethods.open,
      LinkMethods.extensions,
      LinkMethods.extensions,
    ]);
    await host.close(tester);
  });
}

Finder _confirmButton(String label) => find.descendant(
  of: find.byType(AlertDialog),
  matching: find.widgetWithText(TextButton, label),
);

LinkTask _task(String id, {String status = 'running'}) => LinkTask(
  id: id,
  kind: 'command',
  description: 'Fixture task $id',
  status: status,
  startedAt: DateTime.fromMillisecondsSinceEpoch(1),
  command: 'synthetic command',
  output: true,
);

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.tap(finder.hitTestable());
  await tester.pumpAndSettle();
}

class _Host {
  _Host(this.client, this.host);

  final LinkPeer client;
  final LinkPeer host;
  final chats = DesktopHostChats();
  final _slimmers = <String, LinkSessionSlimmer>{};
  final requests = <(String, Map<String, Object?>)>[];
  List<String> get methods => requests.map((call) => call.$1).toList();
  void expectLast(String method, Map<String, Object?> params) {
    expect(requests.last.$1, method);
    expect(requests.last.$2, params);
  }

  FutureOr<Object?> Function(String, Map<String, Object?>)? reply;

  static Future<_Host> show(
    WidgetTester tester, {
    Locale locale = const Locale('en'),
    ThemeData? theme,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1000, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final (clientWire, hostWire) = MemoryLinkConnection.pair(
      a: 'desktop',
      b: 'host',
    );
    final accepted = LinkPeer.accept(hostWire);
    final client = await LinkPeer.connect(clientWire);
    final fixture = _Host(client, await accepted);
    fixture.host.onRequest = (method, params) {
      if (method == LinkMethods.state) return fixture._catalog();
      if (method == LinkMethods.close) return null;
      fixture.requests.add((method, params));
      if (method == LinkMethods.open) {
        final id = params['session']! as String;
        return (fixture._slimmers[id] = LinkSessionSlimmer()).encode(
          fixture._update(id),
          full: true,
        );
      }
      return fixture.reply?.call(method, params);
    };
    fixture.chats.bind(client);
    await tester.idle();
    await fixture.select('session-a', 'project-a');
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        theme: theme,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ListenableBuilder(
            listenable: fixture.chats,
            builder: (context, _) => DesktopRemoteActivity(
              session: DesktopRemoteActivitySession.fromChats(
                fixture.chats,
                client,
                fixture.chats.selected,
              ),
              hostName: 'Fixture host',
              builder: (context, activityButton) => Column(
                children: [
                  if (activityButton != null)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [activityButton],
                    ),
                  const Expanded(child: Center(child: Text('Shared chat'))),
                  const TextField(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return fixture;
  }

  Future<void> select(String id, String project) async {
    await chats.open(
      chats.chats.singleWhere(
        (chat) => chat.id == id && chat.projectId == project,
      ),
    );
  }

  Map<String, Object?> _catalog() => LinkState(
    device: const DeviceInfo(
      name: 'Fixture host',
      kind: 'desktop',
      system: 'macos',
    ),
    projects: const [
      ProjectInfo(id: 'project-a', name: 'A', path: '/host/a'),
      ProjectInfo(id: 'project-b', name: 'B', path: '/host/b'),
    ],
    sessions: [
      SessionSummary(
        id: 'session-a',
        project: 'project-a',
        title: 'A',
        updatedAt: DateTime(2026),
      ),
      SessionSummary(
        id: 'session-b',
        project: 'project-b',
        title: 'B',
        updatedAt: DateTime(2026),
      ),
    ],
  ).toJson();

  LinkSessionUpdate _update(
    String session, {
    List<LinkTask> tasks = const [],
    List<Map<String, Object?>> changes = const [],
  }) => LinkSessionUpdate(
    session: session,
    start: 0,
    items: const [],
    count: 0,
    tasks: tasks,
    changes: changes,
  );

  void push(
    String session, {
    List<LinkTask> tasks = const [],
    List<Map<String, Object?>> changes = const [],
  }) {
    final update = _update(session, tasks: tasks, changes: changes);
    host.emit(
      LinkEvents.session,
      _slimmers[session]?.encode(update) ?? update.toJson(),
    );
  }

  void output(
    String session,
    String task,
    String text,
    int offset, {
    bool reset = false,
  }) {
    host.emit(
      LinkEvents.output,
      LinkOutput(
        session: session,
        task: task,
        offset: offset,
        text: text,
        reset: reset,
      ).toJson(),
    );
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    chats.dispose();
    client.close();
    await host.done;
  }
}
