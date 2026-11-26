import 'dart:async';

import 'package:bao_editor/monaco/vs/workbench/services/themes/common/color_theme_data.dart';
import 'package:bao_link/bao_link.dart';
import 'package:baocode/ide/ide_code_diff.dart';
import 'package:baocode/l10n/app_localizations.dart';
import 'package:baocode/link/desktop_host_chats.dart';
import 'package:baocode/link/desktop_remote_activity.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:baocode/theme/workbench_theme.dart' as workbench;
import 'package:baocode/theme/workbench_theme_initial_colors.dart';
import 'package:baocode/workspace/islands.dart' show IslandTab;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

    void expectTab(String section, {required bool active}) {
      final tab = _tab(section);
      final widget = tester.widget<IslandTab>(tab);
      expect(widget.active, active);
      expect(widget.color, AppColors.background);
      final icon = tester.widget<Icon>(
        find.descendant(of: tab, matching: find.byType(Icon)),
      );
      expect(
        icon.color,
        light.colors[active
            ? 'tab.activeForeground'
            : 'tab.inactiveForeground'],
      );
    }

    expectTab('tasks', active: true);
    expectTab('changes', active: false);
    expect(
      tester.widget<Text>(find.text('No tasks in this session.')).style?.color,
      AppColors.textMuted,
    );

    await _tap(tester, _tab('changes'));
    expectTab('tasks', active: false);
    expectTab('changes', active: true);
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
      await _tap(tester, _tab('changes'));
      expect(find.text('src/First.dart'), findsOneWidget);
      expect(find.text('Modified'), findsOneWidget);
      expect(find.text('+4 −2'), findsOneWidget);
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
    await _tap(tester, _tab('changes'));
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
    await _tap(tester, _tab('changes'));
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

  testWidgets('a changed file opens the read-only workbench diff directly', (
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
    await _tap(tester, _tab('changes'));
    final row = find.byKey(const ValueKey(('remote-change', path)));
    final editor = find.byKey(const ValueKey('desktop-remote-diff-editor'));
    final chat = tester.state(find.byType(EditableText));
    await tester.enterText(find.byType(TextField), 'unsent draft');
    await _tap(tester, row);
    expect(find.byType(AlertDialog), findsNothing);
    expect(host.methods, [LinkMethods.open, LinkMethods.read]);
    expect(find.text('Loading…'), findsOneWidget);
    expect(tester.getRect(editor).right, lessThan(tester.getRect(row).left));
    expect(find.byType(TextField).hitTestable(), findsNothing);
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
    expect(diff.embedded, isFalse);
    expect(find.text('Read-only'), findsOneWidget);
    await tester.binding.setSurfaceSize(const Size(520, 720));
    await tester.pumpAndSettle();
    expect(row.hitTestable(), findsNothing);
    expect(tester.getSize(editor).width, 520);
    expect(
      tester.widget<IdeCodeDiff>(find.byType(IdeCodeDiff)).sideBySide,
      isFalse,
    );
    await _tap(tester, find.byTooltip('Back to changes'));
    expect(editor, findsNothing);
    expect(row.hitTestable(), findsOneWidget);
    await _tap(tester, row);
    expect(find.byType(IdeCodeDiff), findsOneWidget);
    await tester.binding.setSurfaceSize(const Size(1000, 760));
    await tester.pumpAndSettle();
    host.push(
      'session-a',
      changes: const [
        {'path': path, 'revision': 'review-2', 'preview': true},
      ],
    );
    await tester.pumpAndSettle();
    expect(find.byType(IdeCodeDiff), findsNothing);
    expect(tester.state(find.byType(EditableText)), same(chat));
    expect(find.text('unsent draft'), findsOneWidget);
    await host.close(tester);
  });

  testWidgets('composer strip opens and reviews individual host changes', (
    tester,
  ) async {
    final host = await _Host.show(tester, showFiles: true, showStrip: true);
    const first = 'src/First.txt';
    const second = 'src/Second.txt';
    const firstChange = {
      'path': first,
      'revision': 'first-rev',
      'preview': true,
      'undoable': true,
    };
    const secondChange = {
      'path': second,
      'revision': 'second-rev',
      'undoable': true,
    };
    host.reply = (method, _) => switch (method) {
      LinkMethods.read => {'original': 'before\n', 'text': 'after\n'},
      LinkMethods.keep || LinkMethods.undo => null,
      _ => throw StateError(method),
    };
    host.push('session-a', changes: [firstChange, secondChange]);
    await tester.pumpAndSettle();

    final chat = tester.state(find.byType(EditableText));
    await tester.enterText(find.byType(TextField), 'unsent draft');
    await _tap(tester, find.text('2 files changed'));
    await _tap(tester, find.text('First.txt'));
    expect(find.byType(AlertDialog), findsNothing);
    expect(host.methods, [LinkMethods.open, LinkMethods.read]);
    host.expectLast(LinkMethods.read, {
      'session': 'session-a',
      'path': first,
      'expectedChange': 'first-rev',
    });
    final diff = tester.widget<IdeCodeDiff>(find.byType(IdeCodeDiff));
    expect(diff.modified, 'after\n');
    expect(diff.onEdit, isNull);
    await _tap(tester, find.byTooltip('Close diff'));
    expect(tester.state(find.byType(EditableText)), same(chat));
    expect(find.text('unsent draft'), findsOneWidget);

    final keep = _fileReviewAction(first, 'Keep');
    final undo = _fileReviewAction(second, 'Undo');
    expect(keep.hitTestable(), findsOneWidget);
    expect(undo.hitTestable(), findsOneWidget);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(keep));
    await mouse.down(tester.getCenter(keep));
    await mouse.up();
    await mouse.removePointer();
    await tester.pumpAndSettle();
    expect(find.byType(IdeCodeDiff), findsNothing);
    await _tap(tester, _confirmButton('Keep'));
    host.expectLast(LinkMethods.keep, {
      'session': 'session-a',
      'paths': [first],
      'expectedChange': 'first-rev',
    });
    expect(find.text('First.txt'), findsOneWidget);
    expect(find.text('Waiting for host'), findsOneWidget);
    host.push('session-a', changes: [secondChange]);
    await tester.pumpAndSettle();
    expect(find.text('First.txt'), findsNothing);
    await _tap(tester, undo);
    await _tap(tester, _confirmButton('Undo'));
    host.expectLast(LinkMethods.undo, {
      'session': 'session-a',
      'paths': [second],
      'expectedChange': 'second-rev',
    });
    await host.close(tester);
  });

  testWidgets(
    'composer file and diff review work with keyboard and reject stale confirmation',
    (tester) async {
      final host = await _Host.show(tester, showStrip: true);
      const path = 'review.txt';
      const change = {
        'path': path,
        'revision': 'old',
        'preview': true,
        'undoable': true,
      };
      host.reply = (method, _) => method == LinkMethods.read
          ? {'original': 'before\n', 'text': 'after\n'}
          : null;
      host.push('session-a', changes: [change]);
      await tester.pumpAndSettle();

      Future<void> key(LogicalKeyboardKey key) async {
        await tester.sendKeyEvent(key);
        await tester.pumpAndSettle();
      }

      // Tab past the activity launcher, then expand the changes without a pointer.
      await key(LogicalKeyboardKey.tab);
      await key(LogicalKeyboardKey.tab);
      await key(LogicalKeyboardKey.enter);
      expect(_fileReviewAction(path, 'Undo').hitTestable(), findsOneWidget);
      await key(LogicalKeyboardKey.tab);
      await key(LogicalKeyboardKey.enter);
      expect(find.byType(IdeCodeDiff), findsOneWidget);

      final editor = find.byKey(const ValueKey('desktop-remote-diff-editor'));
      Finder diffAction(String label) => find.descendant(
        of: editor,
        matching: find.widgetWithText(TextButton, label),
      );
      expect(diffAction('Undo').hitTestable(), findsOneWidget);
      Focus.of(tester.element(find.text('Undo'))).requestFocus();
      await tester.pump();
      await key(LogicalKeyboardKey.space);
      expect(find.byType(AlertDialog), findsOneWidget);
      host.push(
        'session-a',
        changes: [
          {...change, 'revision': 'new'},
        ],
      );
      await tester.pumpAndSettle();
      await _tap(tester, _confirmButton('Undo'));
      expect(host.methods, [LinkMethods.open, LinkMethods.read]);
      expect(find.textContaining('Review it again.'), findsOneWidget);

      await _tap(tester, find.text(path));
      await _tap(tester, diffAction('Keep'));
      await _tap(tester, _confirmButton('Keep'));
      host.expectLast(LinkMethods.keep, {
        'session': 'session-a',
        'paths': [path],
        'expectedChange': 'new',
      });
      expect(
        find.descendant(of: editor, matching: find.text('Waiting for host')),
        findsOneWidget,
      );
      expect(find.byType(IdeCodeDiff), findsOneWidget);
      host.push('session-a');
      await tester.pumpAndSettle();
      expect(editor, findsNothing);
      expect(find.text(path), findsNothing);
      await host.close(tester);
    },
  );

  testWidgets('composer review blocks mutation while the host is generating', (
    tester,
  ) async {
    final host = await _Host.show(tester, showStrip: true);
    const path = 'live.txt';
    const change = {'path': path, 'revision': 'rev', 'undoable': true};
    host.push('session-a', changes: [change]);
    await tester.pumpAndSettle();
    await _tap(tester, find.text('1 file changed'));
    await _tap(tester, _fileReviewAction(path, 'Keep'));
    host.push('session-a', changes: [change], live: true);
    await tester.pumpAndSettle();
    await _tap(tester, _confirmButton('Keep'));
    expect(host.methods, [LinkMethods.open]);
    expect(_fileReviewAction(path, 'Keep'), findsNothing);
    expect(find.textContaining('Wait for the agent to finish'), findsOneWidget);
    host.push('session-a', changes: [change]);
    await tester.pumpAndSettle();
    expect(_fileReviewAction(path, 'Keep').hitTestable(), findsOneWidget);
    await host.close(tester);
  });

  testWidgets('composer strip only offers scoped revision-safe reviews', (
    tester,
  ) async {
    final host = await _Host.show(tester, showStrip: true);
    const guarded = {
      'path': 'guarded.txt',
      'revision': 'rev-1',
      'undoable': true,
    };
    const otherChanges = [
      {'path': '/outside.txt', 'revision': 'out', 'undoable': true},
      {'path': 'legacy.txt'},
      {'path': 'untracked.txt', 'revision': 'new', 'tracked': false},
    ];
    host.push('session-a', changes: [guarded, ...otherChanges]);
    await tester.pumpAndSettle();
    expect(find.text('Keep all'), findsNothing);
    expect(find.text('Undo all'), findsNothing);
    await _tap(tester, find.text('4 files changed'));
    await _tap(tester, find.text('outside.txt'));
    expect(find.byType(IdeCodeDiff), findsNothing);
    expect(find.text('Outside the selected project'), findsOneWidget);
    expect(host.methods, [LinkMethods.open]);
    await _tap(tester, find.byTooltip('Close diff'));
    expect(_fileReviewAction('/outside.txt', 'Undo'), findsNothing);
    expect(_fileReviewAction('/outside.txt', 'Keep'), findsNothing);
    expect(_fileReviewAction('legacy.txt', 'Keep'), findsNothing);
    expect(_fileReviewAction('untracked.txt', 'Undo'), findsNothing);
    expect(_fileReviewAction('untracked.txt', 'Keep'), findsOneWidget);
    await _tap(tester, find.text('legacy.txt'));
    expect(
      find.text('This host version does not support guarded file actions.'),
      findsOneWidget,
    );
    await _tap(tester, find.byTooltip('Close diff'));

    for (final file in ['outside.txt', 'legacy.txt', 'untracked.txt']) {
      await _openChangeMenu(tester, file);
      expect(find.text('Undo'), findsNothing);
      expect(
        find.text('Keep'),
        file == 'untracked.txt' ? findsOneWidget : findsNothing,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
    }
    await _openChangeMenu(tester, 'guarded.txt');
    await _tap(tester, find.text('Undo'));
    host.push(
      'session-a',
      changes: [
        {...guarded, 'revision': 'rev-2'},
        ...otherChanges,
      ],
    );
    await tester.pumpAndSettle();
    await _tap(tester, _confirmButton('Undo'));
    expect(host.methods, [LinkMethods.open]);
    expect(find.textContaining('Review it again.'), findsOneWidget);
    await host.close(tester);
  });

  testWidgets('composer header reviews a single file with its revision', (
    tester,
  ) async {
    final host = await _Host.show(tester, showStrip: true);
    const change = {'path': 'a.txt', 'revision': 'a', 'undoable': true};
    final multiple = [
      change,
      const {'path': 'b.txt', 'revision': 'b'},
    ];
    host.reply = (method, _) => method == LinkMethods.undo
        ? throw const LinkRemoteException('conflict', 'Change still pending')
        : null;

    host.push('session-a', changes: [change]);
    await tester.pumpAndSettle();
    await _tap(tester, find.text('Undo all'));
    expect(host.methods, [LinkMethods.open]);
    host.push('session-a', changes: multiple);
    await tester.pumpAndSettle();
    await _tap(tester, _confirmButton('Undo all'));
    expect(host.methods, [LinkMethods.open]);
    expect(find.text('Keep all'), findsNothing);
    expect(find.text('Undo all'), findsNothing);

    host.push('session-a', changes: [change]);
    await tester.pumpAndSettle();
    await _tap(tester, find.text('Undo all'));
    await _tap(tester, _confirmButton('Undo all'));
    host.expectLast(LinkMethods.undo, {
      'session': 'session-a',
      'paths': ['a.txt'],
      'expectedChange': 'a',
    });
    expect(find.textContaining('a.txt · Undo conflicted'), findsOneWidget);
    await _tap(tester, find.text('Keep all'));
    await _tap(tester, _confirmButton('Keep all'));
    host.expectLast(LinkMethods.keep, {
      'session': 'session-a',
      'paths': ['a.txt'],
      'expectedChange': 'a',
    });
    expect(find.text('Waiting for host'), findsOneWidget);
    await host.close(tester);
  });

  testWidgets('switching change rows ignores a late diff reply', (
    tester,
  ) async {
    final host = await _Host.show(tester);
    final first = Completer<Object?>();
    host.reply = (method, args) => switch (args['path']) {
      'first.txt' => first.future,
      'second.txt' => {'original': '', 'text': 'second\n'},
      _ => throw StateError(method),
    };
    host.push(
      'session-a',
      changes: const [
        {'path': 'first.txt', 'revision': 'a', 'preview': true},
        {'path': 'second.txt', 'revision': 'b', 'preview': true},
      ],
    );
    await tester.pumpAndSettle();
    await _tap(tester, find.byTooltip('Host activity'));
    await _tap(tester, _tab('changes'));
    await _tap(
      tester,
      find.byKey(const ValueKey(('remote-change', 'first.txt'))),
    );
    await _tap(
      tester,
      find.byKey(const ValueKey(('remote-change', 'second.txt'))),
    );
    first.complete({'original': '', 'text': 'late\n'});
    await tester.pumpAndSettle();
    expect(
      tester.widget<IdeCodeDiff>(find.byType(IdeCodeDiff)).modified,
      'second\n',
    );
    await host.close(tester);
  });

  testWidgets('unsupported text preview offers an explicit file download', (
    tester,
  ) async {
    final host = await _Host.show(tester);
    const channel = MethodChannel('baocode/window');
    final messenger = tester.binding.defaultBinaryMessenger;
    final dialogs = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      dialogs.add(call);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    host.push(
      'session-a',
      changes: const [
        {
          'path': 'binary.bin',
          'revision': 'a',
          'preview': true,
          'binary': true,
        },
      ],
    );
    await tester.pumpAndSettle();
    await _tap(tester, find.byTooltip('Host activity'));
    await _tap(tester, _tab('changes'));
    await _tap(tester, find.text('binary.bin'));
    expect(
      find.text('Binary files cannot be shown as a text diff.'),
      findsOneWidget,
    );
    expect(find.byType(IdeCodeDiff), findsNothing);
    expect(host.methods, [LinkMethods.open]);
    expect(dialogs, isEmpty);
    await _tap(tester, find.byTooltip('Download current file…'));
    expect(dialogs.single.method, 'pickSaveFile');
    expect(dialogs.single.arguments, {'name': 'binary.bin'});
    expect(host.methods, [LinkMethods.open]);
    await host.close(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

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
    await _tap(tester, _tab('changes'));
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
      await _tap(tester, _tab('changes'));
      expect(find.text('所选项目之外'), findsNWidgets(3));
      expect(find.text('保留'), findsNothing);
      expect(find.text('撤销'), findsNothing);
      expect(host.methods, [LinkMethods.open]);
      await host.close(tester);
    },
  );

  testWidgets('project Git previews staged and working tree changes', (
    tester,
  ) async {
    final host = await _Host.show(tester, showFiles: true);
    const stagedPatch = '+staged line\n';
    const unstagedPatch = '+working tree line\n';
    host.reply = (method, args) => switch (method) {
      LinkMethods.projectGitStatus => _gitStatus(),
      LinkMethods.projectGitHistory => _gitHistory,
      LinkMethods.projectGitCapabilities => null,
      LinkMethods.projectGitWorkingDiff => _gitDiff(
        args['staged'] == true ? stagedPatch : unstagedPatch,
      ),
      _ => throw StateError(method),
    };

    await _tap(tester, find.byTooltip('Project sidebar'));
    expect(host.methods, [LinkMethods.open]);
    await _tap(tester, _tab('changes'));
    expect(find.text('main'), findsOneWidget);
    expect(find.text('Staged'), findsOneWidget);
    expect(find.text('Working tree'), findsOneWidget);
    expect(find.text('Untracked'), findsOneWidget);

    await _tap(tester, find.text('staged.txt'));
    expect(_gitPatch(stagedPatch), findsOneWidget);
    host.expectLast(LinkMethods.projectGitWorkingDiff, {
      'project': 'project-a',
      'path': 'staged.txt',
      'staged': true,
    });
    await _tap(tester, find.byTooltip('Back from diff'));
    await _tap(tester, find.text('working.txt'));
    expect(_gitPatch(unstagedPatch), findsOneWidget);
    host.expectLast(LinkMethods.projectGitWorkingDiff, {
      'project': 'project-a',
      'path': 'working.txt',
      'staged': false,
    });
    expect(host.methods, [
      LinkMethods.open,
      LinkMethods.projectGitStatus,
      LinkMethods.projectGitHistory,
      LinkMethods.projectGitCapabilities,
      LinkMethods.projectGitWorkingDiff,
      LinkMethods.projectGitWorkingDiff,
    ]);
    await host.close(tester);
  });

  testWidgets('project Git keeps working tree changes when history fails', (
    tester,
  ) async {
    final host = await _Host.show(tester, showFiles: true);
    host.reply = (method, _) => switch (method) {
      LinkMethods.projectGitStatus => _gitStatus(),
      LinkMethods.projectGitHistory => throw StateError('history failed'),
      _ => throw StateError(method),
    };

    await _tap(tester, find.byTooltip('Project sidebar'));
    await _tap(tester, _tab('changes'));
    expect(find.text('working.txt'), findsOneWidget);
    expect(find.text('Working tree'), findsOneWidget);
    expect(find.text('Could not load Git'), findsNothing);
    await host.close(tester);
  });

  testWidgets('project Git history opens commit files and a read-only patch', (
    tester,
  ) async {
    final host = await _Host.show(tester, showFiles: true);
    const patch = '-prior line\n+committed line\n';
    host.reply = (method, _) => switch (method) {
      LinkMethods.projectGitStatus => _gitStatus(),
      LinkMethods.projectGitHistory => _gitHistory,
      LinkMethods.projectGitCommitFiles => {
        'files': [_gitFile('committed.txt', 'commit')],
        'truncated': false,
      },
      LinkMethods.projectGitCommitDiff => _gitDiff(patch),
      _ => throw StateError(method),
    };

    await _tap(tester, find.byTooltip('Project sidebar'));
    await _tap(tester, _tab('changes'));
    expect(find.textContaining('Fixture Author'), findsOneWidget);
    expect(
      tester.getCenter(find.text('Fixture commit')).dy,
      lessThan(tester.getCenter(find.text('working.txt')).dy),
    );
    await _tap(tester, find.text('Fixture commit'));
    host.expectLast(LinkMethods.projectGitCommitFiles, {
      'project': 'project-a',
      'revision': _gitRevision,
    });
    await _tap(tester, find.text('committed.txt'));
    host.expectLast(LinkMethods.projectGitCommitDiff, {
      'project': 'project-a',
      'revision': _gitRevision,
      'path': 'committed.txt',
    });
    expect(_gitPatch(patch), findsOneWidget);
    await _tap(tester, find.byTooltip('Back from diff'));
    expect(find.text('committed.txt'), findsOneWidget);
    await _tap(tester, find.byTooltip('Back'));
    expect(find.text('Fixture commit'), findsOneWidget);
    await host.close(tester);
  });

  testWidgets(
    'project Git stages, browses stashes and keeps a failed commit draft',
    (tester) async {
      final host = await _Host.show(tester, showFiles: true);
      host.reply = (method, _) => switch (method) {
        LinkMethods.projectGitStatus ||
        LinkMethods.projectGitStage => {..._gitStatus(), 'state': 'repo-state'},
        LinkMethods.projectGitHistory => _gitHistory,
        LinkMethods.projectGitCapabilities => {
          'branches': ['main', 'topic'],
          'canWrite': true,
          'canPush': true,
        },
        LinkMethods.projectGitStashes => {
          'entries': <Object>[],
          'truncated': false,
        },
        LinkMethods.projectGitCommit => throw StateError('Commit rejected'),
        _ => throw StateError(method),
      };

      await _tap(tester, find.byTooltip('Project sidebar'));
      await _tap(tester, _tab('changes'));
      await _tap(tester, find.byTooltip('Stage').first);
      expect(host.methods, contains(LinkMethods.projectGitStage));
      await _tap(tester, find.text('Stash'));
      expect(find.text('No stashes'), findsOneWidget);
      await _tap(tester, find.widgetWithText(TextButton, 'Commit'));
      final input = find.widgetWithText(TextField, 'Commit message');
      await tester.enterText(input, 'Draft commit message');
      await tester.pump();
      await _tap(tester, find.widgetWithText(FilledButton, 'Commit'));
      expect(host.methods, contains(LinkMethods.projectGitCommit));
      expect(find.text('Draft commit message'), findsOneWidget);
      expect(find.textContaining('Git operation failed'), findsOneWidget);
      await host.close(tester);
    },
  );

  testWidgets('an old host keeps its session change review available', (
    tester,
  ) async {
    final host = await _Host.show(tester, showFiles: true);
    host.reply = (_, _) =>
        throw const LinkRemoteException(LinkErrors.unknown, 'Unknown method');
    host.push(
      'session-a',
      changes: const [
        {'path': 'pending.txt'},
      ],
    );
    await tester.pumpAndSettle();

    await _tap(tester, find.byTooltip('Project sidebar'));
    await _tap(tester, _tab('changes'));
    expect(find.text('pending.txt'), findsOneWidget);
    expect(find.text('History'), findsNothing);
    host.expectLast(LinkMethods.projectGitStatus, {'project': 'project-a'});
    expect(host.methods, [LinkMethods.open, LinkMethods.projectGitStatus]);
    await host.close(tester);
  });

  testWidgets('a late Git patch cannot replace the new project patch', (
    tester,
  ) async {
    final host = await _Host.show(tester, showFiles: true);
    final pending = Completer<Object?>();
    const currentPatch = '+project B line\n';
    const stalePatch = '+project A line\n';
    host.reply = (method, args) => switch (method) {
      LinkMethods.projectGitStatus => _gitStatus(),
      LinkMethods.projectGitHistory => _gitHistory,
      LinkMethods.projectGitWorkingDiff when args['project'] == 'project-a' =>
        pending.future,
      LinkMethods.projectGitWorkingDiff => _gitDiff(currentPatch),
      _ => throw StateError(method),
    };

    await _tap(tester, find.byTooltip('Project sidebar'));
    await _tap(tester, _tab('changes'));
    await tester.tap(find.text('working.txt').hitTestable());
    await tester.pump();
    host.expectLast(LinkMethods.projectGitWorkingDiff, {
      'project': 'project-a',
      'path': 'working.txt',
      'staged': false,
    });

    await host.select('session-b', 'project-b');
    await tester.pumpAndSettle();
    await _tap(tester, _tab('changes'));
    await _tap(tester, find.text('working.txt'));
    host.expectLast(LinkMethods.projectGitWorkingDiff, {
      'project': 'project-b',
      'path': 'working.txt',
      'staged': false,
    });
    expect(_gitPatch(currentPatch), findsOneWidget);
    pending.complete(_gitDiff(stalePatch));
    await tester.pumpAndSettle();
    expect(_gitPatch(currentPatch), findsOneWidget);
    expect(_gitPatch(stalePatch), findsNothing);
    expect(tester.takeException(), isNull);
    await host.close(tester);
  });

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
      await _tap(tester, _tab('extensions'));
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
      await _tap(tester, _tab('extensions'));
      await host.select('session-b', 'project-b');
      await tester.pumpAndSettle();
      host.reply = (method, _) =>
          throw const LinkRemoteException(LinkErrors.unknown, 'old host');
      await _tap(tester, find.byTooltip('Host activity'));
      await _tap(tester, _tab('extensions'));
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
    await _tap(tester, _tab('extensions'));
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

Finder _tab(String section) =>
    find.byKey(ValueKey('desktop-remote-tab-$section'));

Finder _gitPatch(String patch) => find.widgetWithText(SelectableText, patch);

const _gitRevision = '0123456789abcdef0123456789abcdef01234567';
const _gitHistory = {
  'commits': [
    {
      'hash': _gitRevision,
      'shortHash': '0123456',
      'subject': 'Fixture commit',
      'authorName': 'Fixture Author',
      'parentIds': <String>[],
      'refs': ['HEAD -> main'],
    },
  ],
  'truncated': false,
};

Map<String, Object?> _gitStatus() => {
  'branch': 'main',
  'head': _gitRevision,
  'files': [
    _gitFile('staged.txt', 'index'),
    _gitFile('working.txt', 'workingTree'),
    _gitFile('new.txt', 'untracked', status: '?'),
  ],
  'truncated': false,
};

Map<String, Object?> _gitFile(
  String path,
  String group, {
  String status = 'M',
}) => {'path': path, 'status': status, 'group': group};

Map<String, Object?> _gitDiff(String text) => {
  'text': text,
  'truncated': false,
};

Finder _fileReviewAction(String path, String label) => find.descendant(
  of: find.byKey(ValueKey(path)),
  matching: find.byTooltip(label),
);

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

Future<void> _openChangeMenu(WidgetTester tester, String name) async {
  await tester.tap(find.text(name).hitTestable(), buttons: kSecondaryButton);
  await tester.pumpAndSettle();
}

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
    bool showFiles = false,
    bool showStrip = false,
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
              files: showFiles ? const Text('Shared files') : null,
              builder: (context, activityButton, activityStrip) => Column(
                children: [
                  if (activityButton != null)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [activityButton],
                    ),
                  const Expanded(child: Center(child: Text('Shared chat'))),
                  if (showStrip) ?activityStrip,
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
    bool live = false,
  }) => LinkSessionUpdate(
    session: session,
    start: 0,
    items: const [],
    count: 0,
    tasks: tasks,
    changes: changes,
    live: live,
  );

  void push(
    String session, {
    List<LinkTask> tasks = const [],
    List<Map<String, Object?>> changes = const [],
    bool live = false,
  }) {
    final update = _update(session, tasks: tasks, changes: changes, live: live);
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
