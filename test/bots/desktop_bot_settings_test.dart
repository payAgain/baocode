import 'dart:convert';

import 'package:baocode/bots/bot.dart';
import 'package:baocode/bots/bot_files.dart';
import 'package:baocode/bots/bot_folders.dart';
import 'package:baocode/bots/bots.dart';
import 'package:baocode/bots/desktop_bot_settings.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/workspace/preference_store.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../kernel_test.dart' show FakeCli;

void main() {
  testWidgets('narrow profile keeps Save reachable and reveals invalid name', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(292, 530);
    addTearDown(tester.view.reset);
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    final bot = fixture.bots.save(name: '纸鹤', identity: '整理笔记', abilities: {});
    await tester.pumpWidget(fixture.page(bot: bot, locale: const Locale('zh')));
    expect(find.text('纸鹤').hitTestable(), findsWidgets);
    expect(find.text('基本资料').hitTestable(), findsOneWidget);
    await _enter(tester, '名称', ' ');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.ensureVisible(find.text('删除 Bot'));
    await tester.pumpAndSettle();
    final save = find.widgetWithText(FilledButton, '保存');
    expect(save.hitTestable(), findsOneWidget);
    expect(tester.getTopLeft(save).dy, greaterThan(450));
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(_field('名称').hitTestable(), findsOneWidget);
    final input = find.descendant(
      of: _field('名称'),
      matching: find.byType(EditableText),
    );
    expect(tester.widget<EditableText>(input).focusNode.hasFocus, isTrue);
    expect(find.text('请输入名称。').hitTestable(), findsOneWidget);
    expect(fixture.bots.byId(bot.id)?.name, '纸鹤');
    expect(tester.takeException(), isNull);
  });

  testWidgets('validates the name and persists a new bot', (tester) async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    await tester.pumpWidget(fixture.page());

    await tester.enterText(_field('Name'), '  ');
    await _tap(tester, find.text('Create bot'));
    expect(find.text('Enter a name.'), findsOneWidget);
    expect(fixture.bots.bots, isEmpty);
    expect(fixture.backCount, 0);

    await tester.enterText(_field('Name'), '  Finch  ');
    await tester.enterText(_field('Identity'), 'A quiet notebook keeper.');
    await _tap(tester, find.text('Create bot'));

    expect(fixture.backCount, 1);
    final saved = fixture.bots.bots.single;
    expect(saved.name, 'Finch');
    expect(fixture.read(saved)?.identity, 'A quiet notebook keeper.');
    expect(fixture.read(saved)?.abilities, isEmpty);
  });

  testWidgets('persists edited profile fields and permissions', (tester) async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    final bot = fixture.bots.save(
      name: 'Finch',
      identity: 'Notebook keeper.',
      gender: 'Female',
      signature: 'Mind the margins.',
      style: 'Keep it short.',
      abilities: {BotAbility.agents},
    );
    fixture.bots.setModel(bot, 'custom-model');
    await tester.pumpWidget(fixture.page(bot: fixture.bots.byId(bot.id)));

    await _enter(tester, 'Signature', 'Tea first.');
    await _enter(tester, 'Speaking style', 'Use short sentences.');
    await _enter(tester, 'Identity', 'A friendly librarian.');
    await _tap(tester, find.text('Chat only'));
    await _tap(tester, find.text('Can message you first'));
    await _tap(tester, find.text('Manage agents'));
    await _tap(tester, find.text('Use the browser'));

    // Simulate the phone saving a different edit while this form is open.
    final avatarBytes = Uint8List.fromList([1, 2, 3]);
    const proactive = BotProactive(perDay: 2);
    final fromPhone = fixture.bots.save(
      id: bot.id,
      name: 'Finch II',
      identity: bot.identity,
      gender: 'Unspecified',
      signature: bot.signature,
      style: bot.style,
      avatarImage: (bytes: avatarBytes, type: 'image/png'),
      abilities: {BotAbility.agents, BotAbility.proactive},
      proactive: proactive,
    );
    await tester.pumpWidget(fixture.page(bot: fromPhone));
    await _tap(tester, find.text('Save'));

    expect(fixture.backCount, 1);
    expect(fixture.bots.bots.single.proactive, proactive);
    final saved = fixture.read(bot)!;
    expect(saved.id, bot.id);
    expect(saved.name, 'Finch II');
    expect(saved.gender, 'Unspecified');
    expect(saved.signature, 'Tea first.');
    expect(saved.identity, 'A friendly librarian.');
    expect(saved.style, 'Use short sentences.');
    expect(saved.chatOnly, isTrue);
    expect(saved.writesFirst, isFalse);
    expect(saved.abilities, {BotAbility.browser, BotAbility.proactive});
    expect(saved.model, 'custom-model');
    expect(saved.created, bot.created);
    expect(saved.avatar, fromPhone.avatar);
    expect(fixture.folders.readFile(saved.avatarFile!), avatarBytes);
  });

  testWidgets('deletes only the named bot after confirmation', (tester) async {
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    final target = fixture.bots.save(
      name: 'Finch',
      identity: '',
      abilities: {},
    );
    final other = fixture.bots.save(name: 'Wren', identity: '', abilities: {});
    fixture.bots.setMemory(target, 'Remembers this.');
    await tester.pumpWidget(fixture.page(bot: target));

    final delete = find.widgetWithText(OutlinedButton, 'Delete bot');
    expect(delete, findsOneWidget);
    await _tap(tester, delete);
    expect(find.text('Delete Finch?'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Delete Finch?'), findsNothing);
    expect(fixture.bots.byId(target.id), same(target));
    expect(fixture.read(target), isNotNull);
    expect(fixture.backCount, 0);

    await _tap(tester, delete);
    await _tap(tester, find.widgetWithText(FilledButton, 'Delete'));
    expect(fixture.backCount, 1);
    expect(fixture.bots.byId(target.id), isNull);
    expect(fixture.folders.folders(), [other.folder]);
    expect(fixture.folders.filesIn(target.folder), isEmpty);
    expect(fixture.read(other)?.name, 'Wren');
  });

  testWidgets('unavailable storage keeps the create draft visible', (
    tester,
  ) async {
    final fixture = _Fixture(MemoryBotFolders(null));
    addTearDown(fixture.dispose);
    await tester.pumpWidget(fixture.page());

    await _enter(tester, 'Name', 'Finch');
    await _tap(tester, find.text('Create bot'));

    expect(tester.takeException(), isNull);
    expect(find.text('Could not save the bot.'), findsOneWidget);
    expect(find.text('Finch'), findsOneWidget);
    expect(fixture.backCount, 0);
    expect(fixture.bots.bots, isEmpty);
  });

  testWidgets(
    'edits the built-in assistant in Chinese without a delete action',
    (tester) async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      await fixture.bots.start();
      final bot = fixture.bots.bots.single;
      expect(bot.assistant, isTrue);
      await tester.pumpWidget(
        fixture.page(bot: bot, locale: const Locale('zh')),
      );

      expect(find.text('Bot 设置'), findsOneWidget);
      expect(find.text('删除 Bot'), findsNothing);
      await _tap(tester, find.text('关注智能体动态'));
      await _tap(tester, find.text('保存'));

      expect(fixture.backCount, 1);
      final saved = fixture.read(bot)!;
      expect(saved.assistant, isTrue);
      expect(saved.abilities, {...bot.abilities, BotAbility.proactive});
      await tester.pumpWidget(const SizedBox.shrink());
      fixture.dispose();
      await tester.pump();
    },
  );
}

Finder _field(String label) => find.widgetWithText(TextFormField, label);

Future<void> _enter(WidgetTester tester, String label, String text) async {
  final field = _field(label);
  await tester.ensureVisible(field);
  await tester.enterText(field, text);
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

class _Fixture {
  _Fixture([MemoryBotFolders? folders])
    : folders = folders ?? MemoryBotFolders();

  final MemoryBotFolders folders;
  static final KernelDescriptor _kernel = KernelDescriptor(
    id: 'claude-code',
    label: 'Claude Code',
    icon: Icons.auto_awesome_rounded,
    description: '',
    create: (context) =>
        ClaudeCodeKernel(_kernel, context, start: (_) async => FakeCli()),
  );
  final workspace = Workspace(
    kernels: [_kernel],
    preferences: MemoryPreferenceStore(),
    drafts: MemoryPreferenceStore(),
  );
  late final bots = Bots(
    workspace: workspace,
    folders: folders,
    store: MemoryPreferenceStore(),
    clock: () => DateTime(2026, 11, 22),
    computer: () async => 'Test desktop',
  );
  var backCount = 0;

  Widget page({Bot? bot, Locale locale = const Locale('en')}) => MaterialApp(
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: DesktopBotSettings(bots: bots, bot: bot, onBack: () => backCount++),
    ),
  );

  Bot? read(Bot bot) {
    String? text(String name) {
      final bytes = folders.readFile(p.join(bot.folder, name));
      return bytes == null ? null : utf8.decode(bytes);
    }

    final card = text(BotFiles.card);
    return card == null
        ? null
        : BotFiles.read(bot.folder, card, style: text(BotFiles.style) ?? '');
  }

  bool _disposed = false;

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    bots.dispose();
    workspace.dispose();
  }
}
