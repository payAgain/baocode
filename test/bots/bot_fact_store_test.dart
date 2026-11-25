import 'dart:convert';
import 'dart:typed_data';

import 'package:baocode/bots/bot_fact_store.dart';
import 'package:baocode/bots/bot_folders.dart';
import 'package:baocode/bots/bot_memory.dart';
import 'package:baocode/bots/bots.dart';
import 'package:baocode/kernel/mock/mock_kernels.dart';
import 'package:baocode/link/bot_memory_management.dart';
import 'package:baocode/workspace/preference_store.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:bao_link/bao_link.dart';
import 'package:flutter_test/flutter_test.dart';

class _InterruptMigration extends MemoryBotFolders {
  bool intercept = true;

  @override
  void writeFileAtomically(String path, Uint8List bytes) {
    if (intercept && path.endsWith('/private-facts.json')) {
      throw StateError('Interrupted before publishing the facts');
    }
    super.writeFileAtomically(path, bytes);
  }
}

const project = Project('Release', '/code/release');
final at = DateTime.utc(2026, 11, 25);

BotFactChange _add(String text, {BotFactKind kind = BotFactKind.self}) =>
    BotFactChange(action: BotMemoryAction.add, kind: kind, text: text);

BotFactChange _remove(BotFactEntry fact) => BotFactChange(
  action: BotMemoryAction.remove,
  id: fact.id,
  revision: fact.revision,
);

Future<Bots> _start(Workspace workspace, BotFolders folders) async {
  final bots = Bots(workspace: workspace, folders: folders, clock: () => at);
  addTearDown(bots.dispose);
  await bots.start();
  return bots;
}

Workspace _workspace({PreferenceStore? preferences}) {
  final workspace = Workspace(
    projects: const [project],
    kernels: [MockKernels.claudeCode],
    preferences: preferences,
  );
  addTearDown(workspace.dispose);
  return workspace;
}

void main() {
  test(
    'imports both private fact kinds and keeps same-name people distinct',
    () {
      var facts = BotFactStore.fromLegacy(
        self: 'Now: waiting\n- likes rain\n- likes snow',
        people: 'Unassigned name\n\n## Qiu\n- met today\n\n## Qiu\n- met today',
      );
      final first = facts.entries[3];
      final second = facts.entries[4];
      expect(facts.now, 'Now: waiting');
      expect(facts.memory.markdown, isNot(contains('Now:')));
      expect(facts.entries[2].needsReview, isTrue);
      expect(first.personName, second.personName);
      expect(first.personKey, isNot(second.personKey));
      expect(first.source, BotFactSource.migration);
      expect(facts.peopleMarkdown, contains('## Qiu\n- met today\n\n## Qiu'));
      expect(
        () => facts.apply([
          const BotFactChange(
            action: BotMemoryAction.add,
            kind: BotFactKind.person,
            personName: 'Qiu',
            text: 'ambiguous',
          ),
        ], at: at),
        throwsStateError,
      );
      facts = facts.apply(
        [
          BotFactChange(
            action: BotMemoryAction.add,
            kind: BotFactKind.person,
            personKey: second.personKey,
            text: 'different note',
          ),
        ],
        at: at,
        session: 'private',
        sourceMessage: 'message',
      );
      final restored = BotFactStore.fromJson(facts.toJson());
      final added = restored.entries.last;
      expect(added.personKey, second.personKey);
      expect(added.source, BotFactSource.conversation);
      expect(added.entry.sourceMessage, 'message');
      expect(
        restored.entries.map((fact) => fact.id),
        facts.entries.map((fact) => fact.id),
      );
    },
  );

  test('withdrawing the last note keeps an established person key', () {
    const change = BotFactChange(
      action: BotMemoryAction.add,
      kind: BotFactKind.person,
      personName: 'Sam',
      text: 'Collects records',
    );
    final store = BotFactStore.empty().apply([change], at: at);
    final person = store.entries.single;
    final removed = store.apply([_remove(person)], at: at);
    final restored = BotFactStore.fromJson(removed.toJson());
    expect(restored.people[person.personKey], 'Sam');
    expect(() => restored.apply([change], at: at), throwsStateError);
    final kept = restored.apply(
      [change],
      at: at,
      allowRememberingWithdrawn: true,
    );
    expect(kept.entries.single.personKey, person.personKey);
    expect(kept.entries.single.id, greaterThan(person.id));
  });

  test('budgets rendered Unicode and rejects the entire stale batch', () {
    final maximum = '茶' * (botFactMemoryLimit - 2);
    final original = BotFactStore.empty().apply([_add(maximum)], at: at);
    final old = original.entries.single;
    expect(original.memory.markdown.runes.length, botFactMemoryLimit);
    expect(
      () => original.apply([
        const BotFactChange(
          action: BotMemoryAction.add,
          kind: BotFactKind.person,
          personName: 'A',
          text: 'new',
        ),
      ], at: at),
      throwsStateError,
    );
    expect(
      () => original.apply([
        _add('this must not be kept'),
        BotFactChange(action: BotMemoryAction.remove, id: old.id, revision: 99),
      ], at: at),
      throwsStateError,
    );
    expect(original.entries.single.id, old.id);
    final changed = original.apply([_remove(old), _add('replacement')], at: at);
    expect(changed.entries.single.id, greaterThan(old.id));
    expect(changed.memory.isWithdrawnEntry(old.id), isTrue);
    expect(
      changed.memory.withdrawalGeneration,
      original.memory.withdrawalGeneration + 1,
    );
    expect(
      BotFactStore.fromJson(changed.toJson()).memory.isWithdrawnEntry(old.id),
      isTrue,
    );
    expect(() => changed.apply([_add(maximum)], at: at), throwsStateError);
  });

  test(
    'legacy over-capacity facts stay saved and pinning orders the projection',
    () {
      final full = '🙂' * (botFactMemoryLimit - 2);
      final original = BotFactStore.fromLegacy(
        self: '- $full\n- short',
        people: '',
      );
      expect(original.memory.promptEntries.single.text, full);
      final short = original.entries.last;
      final pinned = original.withPin(short.id, short.revision, true);
      expect(pinned.memory.promptEntries.single.text, 'short');
      expect(pinned.entries, hasLength(2));
      expect(pinned.entries.last.revision, short.revision + 1);
    },
  );

  test(
    'preserves original Markdown on a failed migration and reloads stable IDs',
    () async {
      final workspace = _workspace();
      final folders = _InterruptMigration();
      final bots = await _start(workspace, folders);
      final bot = bots.save(name: 'Facts', identity: '', abilities: {});
      const self = 'Now: ready\n\n- likes tea\r\n';
      const people = '## Sam\n- collects records\n';
      folders.writeFile('${bot.folder}/SELF.md', utf8.encode(self));
      folders.writeFile('${bot.folder}/PEOPLE.md', utf8.encode(people));
      expect(() => bots.selfNotes(bot), throwsStateError);
      expect(utf8.decode(folders.files['${bot.folder}/SELF.md']!), self);
      final backup = folders.files.entries.singleWhere(
        (entry) => entry.key.endsWith('/memory-migration/self.json'),
      );
      final manifest =
          jsonDecode(utf8.decode(backup.value)) as Map<String, Object?>;
      expect(utf8.decode(base64Decode(manifest['bytes']! as String)), self);
      folders.intercept = false;
      final saved = bots.factMemory(bots.privateFactAccess(bot));
      expect(saved.entries.map((entry) => entry.text), [
        'likes tea',
        'collects records',
      ]);
      expect(saved.now, 'Now: ready');
      bots.setNow(bot, 'resting');
      final changed = bots.factMemory(bots.privateFactAccess(bot));
      expect(changed.now, 'Now: resting');
      expect(
        changed.entries.map((entry) => entry.id),
        saved.entries.map((entry) => entry.id),
      );
      bots.setSelfNotes(bot, 'Now: busy\n- likes tea\n- learned today');
      final edited = bots.factMemory(bots.privateFactAccess(bot));
      expect(edited.entries.first.id, saved.entries.first.id);
      expect(edited.entries.last.id, saved.entries.last.id);
      expect(edited.entries[1].source, BotFactSource.user);
      expect(folders.files[backup.key], backup.value);
    },
  );

  test(
    'project review replays atomically and keeps each primary source',
    () async {
      final workspace = _workspace();
      final bots = await _start(workspace, MemoryBotFolders());
      final bot = bots.save(
        name: 'Review Bot',
        identity: '',
        abilities: {BotAbility.agents},
      );
      final projectId = workspace.localProjectId(project)!;
      final access = bots.projectFactAccess(bot.id, projectId)!;
      const initial = <BotMemoryChange>[
        (
          action: BotMemoryAction.add,
          id: null,
          revision: null,
          text: 'Release needs a check',
        ),
        (
          action: BotMemoryAction.add,
          id: null,
          revision: null,
          text: 'Release needs a tag',
        ),
      ];
      const originalSources = <BotMemorySource>[
        (sessionId: 'project-session', messageId: 'check-source'),
        (sessionId: 'project-session', messageId: 'tag-source'),
      ];
      final created = bots.applyReviewedProjectFacts(
        bot.id,
        projectId,
        initial,
        operationId: 'add',
        changeSources: originalSources,
      );
      final check = created.entries.first;
      final pinned = bots
          .pinFact(access, check.id, check.revision, true)
          .entries
          .first;
      final changes = <BotMemoryChange>[
        (
          action: BotMemoryAction.update,
          id: pinned.id,
          revision: pinned.revision,
          text: 'Use release check',
        ),
      ];
      const newSources = <BotMemorySource>[
        (sessionId: 'project-session', messageId: 'new-source'),
      ];
      final updated = bots.applyReviewedProjectFacts(
        bot.id,
        projectId,
        changes,
        operationId: 'replace',
        changeSources: newSources,
      );
      expect(updated.entries.first.kind, BotFactKind.project);
      expect(updated.entries.first.pinned, isTrue);
      expect(updated.entries.first.entry.sourceMessage, 'new-source');
      expect(updated.entries.last.entry.sourceMessage, 'tag-source');
      final replay = bots.applyReviewedProjectFacts(
        bot.id,
        projectId,
        changes,
        operationId: 'replace',
        changeSources: newSources,
      );
      expect(replay.toJson(), updated.toJson());
      expect(
        () => bots.applyReviewedProjectFacts(
          bot.id,
          projectId,
          [
            (
              action: BotMemoryAction.add,
              id: null,
              revision: null,
              text: '茶' * botFactMemoryLimit,
            ),
          ],
          operationId: 'oversize',
          changeSources: newSources,
        ),
        throwsStateError,
      );
      expect(bots.factMemory(access).toJson(), updated.toJson());
      bots.changeFacts(access, [_remove(updated.entries.first)]);
      expect(
        () => bots.applyReviewedProjectFacts(
          bot.id,
          projectId,
          [
            (
              action: BotMemoryAction.add,
              id: null,
              revision: null,
              text: 'Run the release check',
            ),
          ],
          operationId: 'withdrawn-source',
          changeSources: newSources,
        ),
        throwsStateError,
      );
      expect(
        () => bots.applyReviewedProjectFacts(
          bot.id,
          projectId,
          [
            (
              action: BotMemoryAction.add,
              id: null,
              revision: null,
              text: 'use  release check',
            ),
          ],
          operationId: 'withdrawn-text',
          changeSources: originalSources.take(1).toList(),
        ),
        throwsStateError,
      );
      expect(
        bots.factMemory(access).entries.single.text,
        'Release needs a tag',
      );
      workspace.hideProject(project);
      expect(
        () => bots.applyReviewedProjectFacts(
          bot.id,
          projectId,
          changes,
          operationId: 'replace',
          changeSources: newSources,
        ),
        throwsStateError,
      );
    },
  );

  test('Link authorizes typed project facts by stable identity and rejects mixed scopes', () async {
    final preferences = MemoryPreferenceStore();
    final workspace = _workspace(preferences: preferences);
    final bots = await _start(workspace, MemoryBotFolders());
    final bot = bots.save(
      name: 'Release Bot',
      identity: '',
      abilities: {BotAbility.agents},
    );
    final other = bots.save(
      name: 'Other',
      identity: '',
      abilities: {BotAbility.agents},
    );
    var active = true;
    final manager = BotMemoryManagement(
      bots,
      reviewer: 'test',
      isActive: () => active,
    );
    final scopes = await manager.call(LinkMethods.botMemoryFactScopes, {
      'bot': bot.id,
    });
    final listed = (scopes['projects'] as List).single as Map;
    final id = listed['id'] as String;
    final args = {'bot': bot.id, 'factScope': 'project', 'project': id};
    final saved = await manager.call(LinkMethods.changeBotMemory, {
      ...args,
      'changes': [
        {'action': 'add', 'text': 'run release check'},
      ],
    });
    final fact = (saved['entries'] as List).single as Map;
    expect(fact['kind'], 'project');
    expect(fact['sourceKind'], 'user');
    expect(bots.projectFactPrompt(bot.id, id), '- run release check');
    expect(bots.projectFactPrompt(other.id, id), isEmpty);
    expect(
      (await manager.call(LinkMethods.botMemoryEntries, {
        'bot': bot.id,
      }))['entries'],
      isEmpty,
    );
    await expectLater(
      manager.call(LinkMethods.botMemoryEntries, {...args, 'group': 'a-room'}),
      throwsA(isA<LinkRemoteException>()),
    );
    await expectLater(
      manager.call(LinkMethods.botMemoryEntries, {
        ...args,
        'project': project.path,
      }),
      throwsA(isA<LinkRemoteException>()),
    );
    expect(
      await workspace.relocateProject(project, '/code/moved'),
      ProjectRelocation.moved,
    );
    expect(workspace.localProjectById(id)?.path, '/code/moved');
    expect(bots.projectFactPrompt(bot.id, id), '- run release check');
    workspace.importFolders([project.path]);
    final reusedId = workspace.localProjectId(
      workspace.projectAt(project.path),
    );
    expect(reusedId, isNot(id));
    expect(bots.projectFactPrompt(bot.id, reusedId!), isEmpty);
    final reopened = _workspace(preferences: preferences);
    await reopened.load();
    expect(reopened.localProjectById(id)?.path, '/code/moved');
    final granted = bots.projectFactAccess(bot.id, id)!;
    bots.save(id: bot.id, name: bot.name, identity: '', abilities: {});
    expect(() => bots.factMemory(granted), throwsStateError);
    expect(bots.projectFactPrompt(bot.id, id), isEmpty);
    active = false;
    await expectLater(
      manager.call(LinkMethods.botMemoryFactScopes, {'bot': bot.id}),
      throwsA(isA<LinkRemoteException>()),
    );
  });
}
