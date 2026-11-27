import 'dart:io';

import 'package:baocode/bots/bot.dart';
import 'package:baocode/bots/bot_folders.dart';
import 'package:baocode/bots/bot_memory.dart';
import 'package:baocode/bots/bot_memory_migration.dart';
import 'package:baocode/bots/bots.dart';
import 'package:baocode/bots/desktop_bot_memory_migration.dart';
import 'package:baocode/kernel/mock/mock_kernels.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _windowChannel = MethodChannel('baocode/window');
const _macVariant = TargetPlatformVariant({TargetPlatform.macOS});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory tempDir;
  late MemoryBotFolders folders;
  late Workspace workspace;
  late Bots bots;
  late Bot bot;
  late List<String> pickedPaths;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('hermes-migration-ui-');
    addTearDown(() => tempDir.deleteSync(recursive: true));

    pickedPaths = const [];
    messenger.setMockMethodCallHandler(_windowChannel, (call) async {
      if (call.method == 'pickOpenFiles') return pickedPaths;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(_windowChannel, null));

    folders = MemoryBotFolders(p.join(tempDir.path, 'bots'));
    workspace = Workspace(kernels: [MockKernels.claudeCode]);
    addTearDown(workspace.dispose);
    bots = Bots(workspace: workspace, folders: folders);
    addTearDown(bots.dispose);
    await bots.start();
    bot = bots.save(name: 'Hermes UI fixture', identity: '', abilities: {});
  });

  Future<void> openMigrationDialog(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showDesktopBotMemoryMigration(context, bots, bot),
              child: const Text('Open migration'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open migration'));
    await tester.pumpAndSettle();
  }

  Future<void> importHermesAndWait(WidgetTester tester, Finder waitFor) async {
    await tester.tap(find.text('Import Hermes file'));
    await tester.pump();
    for (var i = 0; i < 60 && waitFor.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  testWidgets('rejects selecting a file inside the Bot memory folder', (
    tester,
  ) async {
    final ownMemoryFile = File(p.join(bot.folder, 'MEMORY.md'))
      ..createSync(recursive: true)
      ..writeAsStringSync('- Own memory\n');
    pickedPaths = [ownMemoryFile.path];

    await openMigrationDialog(tester);
    await tester.tap(find.text('Import Hermes file'));
    await tester.pumpAndSettle();

    expect(
      find.text('Cannot import a file from BaoCode’s own Bot memory folder.'),
      findsOneWidget,
    );
    expect(bots.userMemory(bot).entries, isEmpty);
    expect(bots.privateFactMemory(bot).entries, isEmpty);
  }, variant: _macVariant);

  testWidgets(
    'reviews USER.md additions, duplicates, and blocked items without leaking secrets',
    (tester) async {
      bots.setMemory(bot, '- Kept pref\n- Forgotten pref');
      final forgotten = bots.userMemory(bot).entries.last;
      bots.changeUserMemory(bot, [
        (
          action: BotMemoryAction.remove,
          id: forgotten.id,
          revision: forgotten.revision,
          text: null,
        ),
      ]);

      final hermesUser = File(p.join(tempDir.path, 'USER.md'))
        ..writeAsStringSync(
          [
            'Kept pref',
            'Forgotten pref',
            'password: super-secret-example',
            'Prefers green tea',
          ].join('\n§\n'),
        );
      pickedPaths = [hermesUser.path];

      await openMigrationDialog(tester);
      await importHermesAndWait(tester, find.text('Review Hermes import'));

      expect(find.text('Review Hermes import'), findsOneWidget);
      expect(
        find.text('Parsed 4 · 1 new · 1 duplicates skipped · 2 blocked'),
        findsOneWidget,
      );
      expect(find.text('Prefers green tea'), findsOneWidget);
      expect(find.text('#2 · Previously forgotten'), findsOneWidget);
      expect(find.text('Forgotten pref'), findsOneWidget);
      expect(
        find.text('#3 · Contains credentials or keys (hidden)'),
        findsOneWidget,
      );
      expect(find.textContaining('super-secret-example'), findsNothing);

      // Cancel writes nothing.
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog).last,
          matching: find.text('Cancel'),
        ),
      );
      await tester.pumpAndSettle();
      expect(bots.userMemory(bot).entries.map((e) => e.text), ['Kept pref']);

      // Reopen and confirm import.
      await importHermesAndWait(tester, find.text('Review Hermes import'));
      await tester.tap(find.text('Import notes'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Imported 1 Hermes notes into Private preferences (MEMORY.md).',
        ),
        findsOneWidget,
      );
      expect(bots.userMemory(bot).entries.map((e) => e.text), [
        'Kept pref',
        'Prefers green tea',
      ]);
    },
    variant: _macVariant,
  );

  testWidgets(
    'requires explicit target choice for renamed file and switches target preview',
    (tester) async {
      bots.setMemory(bot, '- Shared note');
      final renamed = File(p.join(tempDir.path, 'hermes-notes.md'))
        ..writeAsStringSync('Shared note\n§\nUses Dart');
      pickedPaths = [renamed.path];

      await openMigrationDialog(tester);
      await importHermesAndWait(tester, find.text('Review Hermes import'));

      expect(find.text('Choose target memory'), findsOneWidget);
      expect(find.text('Import notes'), findsNothing);

      await tester.tap(find.byType(DropdownButton<BotMemoryMirror>).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Private preferences (MEMORY.md)').last);
      await tester.pumpAndSettle();
      expect(
        find.text('Parsed 2 · 1 new · 1 duplicates skipped'),
        findsOneWidget,
      );

      await tester.tap(find.byType(DropdownButton<BotMemoryMirror>).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Private self facts (SELF.md)').last);
      await tester.pumpAndSettle();
      expect(find.text('Parsed 2 · 2 new'), findsOneWidget);

      await tester.tap(find.text('Import notes'));
      await tester.pumpAndSettle();

      expect(
        find.text('Imported 2 Hermes notes into Private self facts (SELF.md).'),
        findsOneWidget,
      );
      expect(bots.privateFactMemory(bot).entries.map((e) => e.text), [
        'Shared note',
        'Uses Dart',
      ]);
      expect(bots.userMemory(bot).entries.map((e) => e.text), ['Shared note']);
    },
    variant: _macVariant,
  );

  testWidgets('warns when file contains plain bullets without § delimiter', (
    tester,
  ) async {
    final plain = File(p.join(tempDir.path, 'USER.md'))
      ..writeAsStringSync('- First bullet\n- Second bullet\n');
    pickedPaths = [plain.path];

    await openMigrationDialog(tester);
    await importHermesAndWait(tester, find.text('Review Hermes import'));

    expect(
      find.textContaining('No Hermes § separator was found'),
      findsOneWidget,
    );
    expect(find.text('Parsed 1 · 1 new'), findsOneWidget);
  }, variant: _macVariant);
}
