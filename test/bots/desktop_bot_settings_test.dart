import 'dart:convert';

import 'package:bao_link/bao_link.dart';
import 'package:baocode/bots/bot.dart';
import 'package:baocode/bots/bot_files.dart';
import 'package:baocode/bots/bot_folders.dart';
import 'package:baocode/bots/bots.dart';
import 'package:baocode/bots/desktop_bot_memory.dart';
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

  testWidgets('memory settings edit and pin individual host entries', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 800);
    addTearDown(tester.view.reset);
    final fixture = _Fixture();
    addTearDown(fixture.dispose);
    final bot = fixture.bots.save(name: 'Finch', identity: '', abilities: {});
    fixture.bots.setMemory(bot, '- First preference');
    await tester.pumpWidget(fixture.page(bot: bot));

    await _tap(tester, find.text('Memory and review'));
    expect(find.text('First preference'), findsOneWidget);
    await _tap(tester, find.text('Edit'));
    final editor = find.descendant(
      of: find.byType(AlertDialog).last,
      matching: find.byType(TextFormField),
    );
    await tester.enterText(editor, 'Updated preference');
    await _tap(tester, find.widgetWithText(FilledButton, 'Save').last);
    expect(find.text('Updated preference'), findsOneWidget);
    expect(
      fixture.bots.userMemory(bot).entries.single.text,
      'Updated preference',
    );
    await _tap(tester, find.text('Pin'));
    expect(find.text('Unpin'), findsOneWidget);
    expect(fixture.bots.userMemory(bot).entries.single.pinned, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'memory review shows all changes and approves the batch together',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(900, 800);
      addTearDown(tester.view.reset);
      final decisions = <Map<String, Object?>>[];
      const oldEvidence = {
        'role': 'user',
        'source': {'token': 'old'},
      };
      const newEvidence = {
        'role': 'user',
        'source': {'token': 'new'},
      };
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDesktopBotMemory(
                  context,
                  botId: 'finch',
                  name: 'Finch',
                  groups: const {},
                  methods: const [
                    LinkMethods.botMemoryEntries,
                    LinkMethods.botMemoryReview,
                    LinkMethods.decideBotMemory,
                    LinkMethods.refreshBotMemory,
                    LinkMethods.botMemorySource,
                  ],
                  call: (method, args) async => switch (method) {
                    LinkMethods.botMemoryEntries => {'entries': []},
                    LinkMethods.botMemoryReview => {
                      'proposals': [
                        if (decisions.isEmpty)
                          {
                            'id': 'same-batch',
                            'action': 'batch',
                            'status': 'pending',
                            'evidence': [oldEvidence, newEvidence],
                            'changes': [
                              {
                                'action': 'remove',
                                'before': 'Old preference',
                                'evidence': [oldEvidence],
                              },
                              {
                                'action': 'add',
                                'after': 'New preference',
                                'evidence': [newEvidence],
                              },
                            ],
                          },
                      ],
                    },
                    LinkMethods.decideBotMemory => () {
                      decisions.add(args);
                      return {'status': 'applied'};
                    }(),
                    LinkMethods.refreshBotMemory => {'status': 'afterReply'},
                    LinkMethods.botMemorySource => {
                      'anchor': {
                        'role': 'user',
                        'text': (args['source'] as Map)['token'] == 'new'
                            ? 'New preference source'
                            : 'Old preference source',
                      },
                    },
                    _ => throw StateError('Unexpected request: $method'),
                  },
                ),
                child: const Text('Open memory'),
              ),
            ),
          ),
        ),
      );
      await _tap(tester, find.text('Open memory'));
      await _tap(tester, find.text('Refresh chat memory'));
      expect(
        find.text('Memory will refresh after the current reply.'),
        findsOneWidget,
      );
      await _tap(tester, find.text('Review'));
      expect(find.textContaining('Memory changes'), findsOneWidget);
      expect(find.text('Old preference'), findsOneWidget);
      expect(find.text('New preference'), findsOneWidget);
      final sources = find.text('View user source');
      expect(sources, findsNWidgets(2));
      await tester.ensureVisible(sources.last);
      await tester.tap(sources.last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('New preference source'), findsOneWidget);
      await _tap(
        tester,
        find.descendant(
          of: find.byType(AlertDialog).last,
          matching: find.text('Close'),
        ),
      );
      await _tap(tester, find.text('Approve batch'));
      expect(decisions.single, {
        'bot': 'finch',
        'proposal': 'same-batch',
        'approve': true,
        'batch': true,
      });
      expect(find.text('No pending proposals.'), findsOneWidget);
    },
  );

  testWidgets('learned skills select a project and compare revisions', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 800);
    addTearDown(tester.view.reset);
    final requests = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDesktopBotMemory(
                context,
                botId: 'finch',
                name: 'Finch',
                groups: const {},
                methods: const [
                  LinkMethods.botMemoryEntries,
                  LinkMethods.botMemorySkills,
                  LinkMethods.botMemorySkillRevisions,
                ],
                call: (method, args) async {
                  requests.add('$method:${args['project']}');
                  return switch (method) {
                    LinkMethods.botMemoryEntries => {'entries': []},
                    LinkMethods.botMemorySkills => {
                      'project': args['project'] ?? '/first',
                      'projects': [
                        {'id': '/first', 'name': 'First project'},
                        {'id': '/second', 'name': 'Second project'},
                      ],
                      'skills': [
                        if (args['project'] == '/second')
                          {
                            'name': 'release-check',
                            'trigger': 'Before a release',
                            'revision': 2,
                          },
                      ],
                    },
                    LinkMethods.botMemorySkillRevisions => {
                      'revisions': [
                        {
                          'revision': 2,
                          'markdown': 'Read changelog\nVerify signatures\n',
                        },
                        {
                          'revision': 1,
                          'markdown': 'Read changelog\nVerify checksums\n',
                        },
                      ],
                    },
                    _ => throw StateError('Unexpected request: $method'),
                  };
                },
              ),
              child: const Text('Open memory'),
            ),
          ),
        ),
      ),
    );
    await _tap(tester, find.text('Open memory'));
    await _tap(tester, find.text('Skills'));
    expect(find.text('No learned skills in this project.'), findsOneWidget);
    await _tap(tester, find.text('First project'));
    await _tap(tester, find.text('Second project').last);
    expect(find.text('release-check'), findsOneWidget);
    await _tap(tester, find.text('Revision history'));
    expect(find.text('Changes since revision 1'), findsOneWidget);
    expect(find.textContaining('+ signatur'), findsOneWidget);
    expect(
      requests,
      contains('${LinkMethods.botMemorySkillRevisions}:/second'),
    );
  });

  testWidgets('memory separates loaded revisions from next snapshot budget', (
    tester,
  ) async {
    String? snapshotStatus = 'confirmed';
    await _openMemoryDialog(
      tester,
      methods: const [LinkMethods.botMemoryEntries],
      call: (method, args) async {
        expect(method, LinkMethods.botMemoryEntries);
        expect(args, {'bot': 'finch'});
        return {
          'used': 78,
          'budget': 100,
          'injected': 12,
          'snapshotStatus': ?snapshotStatus,
          'entries': [
            {
              'id': 1,
              'revision': 3,
              'text': 'Changed preference',
              'injected': false,
              'activeRevision':
                  snapshotStatus == 'unknown' || snapshotStatus == null
                  ? null
                  : 2,
            },
            {
              'id': 2,
              'revision': 1,
              'text': 'New preference',
              'injected': true,
              'activeRevision': null,
            },
          ],
        };
      },
    );

    expect(find.text('78 / 100 characters saved'), findsOneWidget);
    expect(
      find.text('12 characters fit the next snapshot budget'),
      findsOneWidget,
    );
    expect(find.textContaining('Loaded revision 2'), findsOneWidget);
    expect(find.textContaining('Not in the current snapshot'), findsOneWidget);
    expect(
      find.textContaining('Outside the next snapshot budget'),
      findsOneWidget,
    );
    expect(find.text('Facts'), findsNothing);

    snapshotStatus = 'pending';
    await _tap(tester, find.byTooltip('Reload status'));
    expect(find.text('Snapshot refresh pending'), findsOneWidget);
    expect(find.textContaining('Last confirmed revision 2'), findsOneWidget);
    expect(find.textContaining('Not in the current snapshot'), findsNothing);

    snapshotStatus = 'unknown';
    await _tap(tester, find.byTooltip('Reload status'));
    expect(find.text('Current snapshot unknown'), findsOneWidget);
    expect(find.textContaining('Loaded revision'), findsNothing);

    snapshotStatus = null;
    await _tap(tester, find.byTooltip('Reload status'));
    expect(find.text('Current snapshot unknown'), findsNothing);
    expect(
      find.textContaining('Outside the next snapshot budget'),
      findsOneWidget,
    );
    expect(find.text('Changed preference'), findsOneWidget);
  });

  testWidgets('review shows host limits and measured usage when available', (
    tester,
  ) async {
    var hasOutput = false;
    await _openMemoryDialog(
      tester,
      methods: const [
        LinkMethods.botMemoryEntries,
        LinkMethods.botMemoryReview,
      ],
      call: (method, _) async => switch (method) {
        LinkMethods.botMemoryEntries => {'entries': []},
        LinkMethods.botMemoryReview => {
          'limits': {
            'maxEvidenceMessages': 32,
            'maxEvidenceCharacters': 14500,
            'maxOutputTokens': 2304,
            'maxOutputCharacters': 14000,
            'maxAttempts': 3,
          },
          'lastUsage': {
            'requestCount': 2,
            'inputCharacters': 19812,
            if (hasOutput) 'outputCharacters': 410,
          },
        },
        _ => throw StateError('Unexpected request: $method'),
      },
    );
    await _tap(tester, find.text('Review'));
    expect(find.text('Review limits'), findsOneWidget);
    expect(
      find.textContaining('32 messages · 14,500 characters'),
      findsOneWidget,
    );
    expect(
      find.textContaining('2,304 tokens · 14,000 characters'),
      findsOneWidget,
    );
    expect(find.textContaining('3 attempts per job'), findsOneWidget);
    expect(find.textContaining('Price unknown'), findsOneWidget);
    expect(find.textContaining('2 requests'), findsOneWidget);
    expect(find.textContaining('Input: 19,812 characters'), findsOneWidget);
    expect(find.textContaining('Output: 0 characters'), findsNothing);

    hasOutput = true;
    await _tap(tester, find.byTooltip('Reload status'));
    expect(find.textContaining('Output: 410 characters'), findsOneWidget);
  });

  testWidgets('fact buckets keep project and person IDs on writes', (
    tester,
  ) async {
    final requests = <(String, Map<String, Object?>)>[];
    const existingPeople = [
      {
        'id': 1,
        'revision': 1,
        'kind': 'person',
        'personKey': 'stable-person-a',
        'personName': 'Sam',
        'text': 'First Sam prefers email',
      },
      {
        'id': 2,
        'revision': 1,
        'kind': 'person',
        'personKey': 'stable-person-b',
        'personName': 'Sam',
        'text': 'Second Sam prefers a call',
        'sourceKind': 'migration',
        'needsReview': true,
      },
    ];
    var projectText = 'Ship on Fridays';
    var projectRevision = 4;
    await _openMemoryDialog(
      tester,
      groups: const {'garden': 'Garden group'},
      methods: const [
        LinkMethods.botMemoryEntries,
        LinkMethods.botMemoryFactScopes,
        LinkMethods.changeBotMemory,
      ],
      call: (method, args) async {
        requests.add((method, args));
        if (method == LinkMethods.botMemoryFactScopes) {
          return {
            'private': true,
            'projects': [
              {'id': 'stable-project-id', 'name': 'Release notes'},
            ],
          };
        }
        final factScope = args['factScope'];
        if (factScope == 'private') {
          return {
            'entries': [
              {
                'id': 3,
                'revision': 1,
                'kind': 'self',
                'text': 'Bot convention',
              },
              ...existingPeople,
            ],
          };
        }
        if (factScope == 'project') {
          if (method == LinkMethods.changeBotMemory) {
            final change = (args['changes'] as List).single as Map;
            projectText = change['text'] as String;
            projectRevision++;
          }
          return {
            'snapshotStatus': 'unknown',
            'entries': [
              {
                'id': 1,
                'revision': projectRevision,
                'kind': 'project',
                'text': projectText,
              },
            ],
          };
        }
        expect(method, LinkMethods.botMemoryEntries);
        return {'entries': []};
      },
    );
    await _tap(tester, find.text('Facts'));
    expect(find.text('Bot convention'), findsOneWidget);
    expect(find.textContaining('Needs review'), findsOneWidget);
    await _tap(tester, find.text('Add person fact'));
    await _tap(
      tester,
      find.descendant(
        of: find.byType(AlertDialog).last,
        matching: find.byType(DropdownButton<String>),
      ),
    );
    await _tap(tester, find.text('Sam (2)').last);
    await tester.enterText(_dialogField('Fact'), 'Sam is available on Fridays');
    await _tap(tester, find.widgetWithText(FilledButton, 'Save'));
    expect(requests.last.$1, LinkMethods.changeBotMemory);
    expect(requests.last.$2, {
      'bot': 'finch',
      'factScope': 'private',
      'changes': [
        {
          'action': 'add',
          'kind': 'person',
          'personKey': 'stable-person-b',
          'text': 'Sam is available on Fridays',
        },
      ],
    });

    await tester.drag(
      find.byType(ListView).hitTestable().first,
      const Offset(0, 500),
    );
    await tester.pumpAndSettle();
    await _tap(
      tester,
      find.byType(DropdownButtonFormField<String>).hitTestable(),
    );
    await _tap(tester, find.text('Release notes').last);
    expect(requests.last.$1, LinkMethods.botMemoryEntries);
    expect(requests.last.$2, {
      'bot': 'finch',
      'factScope': 'project',
      'project': 'stable-project-id',
    });
    expect(find.text('Ship on Fridays'), findsOneWidget);
    expect(find.text('Bot convention'), findsNothing);
    await _tap(tester, find.text('Edit'));
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog).last,
        matching: find.byType(TextFormField),
      ),
      'Ship on Mondays',
    );
    await _tap(tester, find.widgetWithText(FilledButton, 'Save'));
    expect(requests.last.$1, LinkMethods.changeBotMemory);
    expect(requests.last.$2, {
      'bot': 'finch',
      'factScope': 'project',
      'project': 'stable-project-id',
      'changes': [
        {'action': 'update', 'id': 1, 'revision': 4, 'text': 'Ship on Mondays'},
      ],
    });
    expect(find.text('Ship on Mondays'), findsOneWidget);
    expect(find.textContaining('Saved revision 5'), findsOneWidget);

    await _tap(tester, find.text('Private chat'));
    await _tap(tester, find.text('Garden group').last);
    expect(requests.last.$1, LinkMethods.botMemoryEntries);
    expect(requests.last.$2, {'bot': 'finch', 'group': 'garden'});
    expect(find.text('Ship on Mondays'), findsNothing);
    expect(find.text('Select Private chat to manage facts.'), findsOneWidget);
  });

  testWidgets('local original deletion requires group scope and confirmation', (
    tester,
  ) async {
    final deletes = <Map<String, Object?>>[];
    final retains = <Map<String, Object?>>[];
    const reference = {'token': 'verified-anchor'};
    await _openMemoryDialog(
      tester,
      localOwner: true,
      groups: const {'garden': 'Garden group'},
      methods: const [
        LinkMethods.botMemoryEntries,
        LinkMethods.botMemorySource,
        LinkMethods.deleteBotMemorySource,
        LinkMethods.changeBotMemory,
      ],
      call: (method, args) async => switch (method) {
        LinkMethods.botMemoryEntries => {
          'entries': [
            {
              'id': 4,
              'revision': 3,
              'text': 'Fact from a source',
              if (deletes.isEmpty) 'source': {'token': 'source-listing'},
              if (deletes.isNotEmpty) 'sourceUnavailable': true,
            },
          ],
        },
        LinkMethods.botMemorySource => {
          'anchor': {'text': 'Original message', 'reference': reference},
          'canDeleteOriginal': true,
        },
        LinkMethods.deleteBotMemorySource => () {
          deletes.add(args);
          return {'deleted': true};
        }(),
        LinkMethods.changeBotMemory => () {
          retains.add(args);
          return {
            'entries': [
              {'id': 4, 'revision': 4, 'text': 'Fact from a source'},
            ],
          };
        }(),
        _ => throw StateError('Unexpected request: $method'),
      },
    );

    Future<void> tapWhileBrowsing(Finder finder) async {
      await tester.tap(finder);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
    }

    await tapWhileBrowsing(find.text('View source'));
    expect(find.text('Original message'), findsOneWidget);
    expect(find.text('Delete original'), findsNothing);
    await _tap(
      tester,
      find.descendant(
        of: find.byType(AlertDialog).last,
        matching: find.text('Close'),
      ),
    );
    await _tap(tester, find.text('Private chat'));
    await _tap(tester, find.text('Garden group').last);
    await tapWhileBrowsing(find.text('View source'));
    await tapWhileBrowsing(find.text('Delete original'));
    expect(find.text('Delete this original message?'), findsOneWidget);
    expect(deletes, isEmpty);
    await tapWhileBrowsing(find.text('Cancel'));
    expect(deletes, isEmpty);
    await tapWhileBrowsing(find.text('Delete original'));
    await _tap(tester, find.widgetWithText(FilledButton, 'Delete original'));

    expect(deletes.single, {
      'bot': 'finch',
      'group': 'garden',
      'source': reference,
      'confirm': true,
    });
    expect(find.text('Original message deleted.'), findsOneWidget);
    expect(find.textContaining('Paused · Source unavailable'), findsOneWidget);
    expect(find.text('View source'), findsNothing);
    await _tap(tester, find.text('Keep fact'));
    expect(retains, isEmpty);
    await _tap(tester, find.widgetWithText(FilledButton, 'Keep fact'));
    expect(retains.single, {
      'bot': 'finch',
      'group': 'garden',
      'changes': [
        {'action': 'retain', 'id': 4, 'revision': 3},
      ],
    });
    expect(find.textContaining('Paused · Source unavailable'), findsNothing);
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

Future<void> _openMemoryDialog(
  WidgetTester tester, {
  Map<String, String> groups = const {},
  bool localOwner = false,
  required Iterable<String> methods,
  required Future<Map<String, Object?>> Function(String, Map<String, Object?>)
  call,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(900, 800);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDesktopBotMemory(
              context,
              botId: 'finch',
              name: 'Finch',
              groups: groups,
              methods: methods,
              call: call,
              localOwner: localOwner,
            ),
            child: const Text('Open memory'),
          ),
        ),
      ),
    ),
  );
  await _tap(tester, find.text('Open memory'));
}

Finder _field(String label) => find.widgetWithText(TextFormField, label);
Finder _dialogField(String label) =>
    find.descendant(of: find.byType(AlertDialog).last, matching: _field(label));

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
