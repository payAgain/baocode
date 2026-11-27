import 'package:baocode/bots/bot.dart';
import 'package:baocode/bots/bot_fact_store.dart';
import 'package:baocode/bots/bot_folders.dart';
import 'package:baocode/bots/bot_memory.dart';
import 'package:baocode/bots/bots.dart';
import 'package:baocode/kernel/mock/mock_kernels.dart';
import 'package:baocode/link/bot_memory_management.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:bao_link/bao_link.dart';
import 'package:flutter_test/flutter_test.dart';

const _project = Project('Release', '/code/release');
const _context = 'recipient-context';

void main() {
  late Workspace workspace;
  late Bots bots;
  late Bot bot;
  late BotMemoryManagement owner;
  late String home;
  late String other;

  setUp(() async {
    workspace = Workspace(
      projects: const [_project],
      kernels: [MockKernels.claudeCode],
    );
    addTearDown(workspace.dispose);
    bots = Bots(workspace: workspace, folders: MemoryBotFolders());
    addTearDown(bots.dispose);
    await bots.start();
    bot = bots.save(
      name: 'Memory Bot',
      identity: '',
      abilities: {BotAbility.agents},
    );
    owner = BotMemoryManagement(bots, reviewer: 'desktop', localOwner: true);
    home = bots.groups.save(name: 'Home', members: [bot.id]).id;
    other = bots.groups.save(name: 'Other', members: [bot.id]).id;
  });

  Future<Map<String, Object?>> share(
    BotMemoryEntry entry, {
    String? group,
    String? factScope,
    String? project,
    BotMemoryManagement? manager,
  }) => (manager ?? owner).call(LinkMethods.shareBotMemoryEntry, {
    'bot': bot.id,
    'group': group ?? home,
    'id': entry.id,
    'revision': entry.revision,
    'factScope': ?factScope,
    'project': ?project,
  });

  Future<Map<String, Object?>> revoke(
    Map<String, Object?> entry, {
    BotMemoryManagement? manager,
  }) => (manager ?? owner).call(LinkMethods.revokeBotMemoryShare, {
    'bot': bot.id,
    'group': home,
    'id': entry['id'],
    'revision': entry['revision'],
    'shareId': (entry['share'] as Map)['id'],
  });

  Map<String, Object?> onlyEntry(Map<String, Object?> result) =>
      (result['entries'] as List).single as Map<String, Object?>;

  test(
    'group sharing requires the owner, membership, source revision and budget',
    () async {
      final remote = BotMemoryManagement(bots, reviewer: 'paired');
      final outsider = bots.groups.save(name: 'No membership', members: []).id;
      final entry = bots
          .changeUserMemory(bot, [
            (
              action: BotMemoryAction.add,
              id: null,
              revision: null,
              text: 'Have tea',
            ),
          ])
          .entries
          .single;
      expect(remote.methods, isNot(contains(LinkMethods.shareBotMemoryEntry)));
      expect(remote.methods, isNot(contains(LinkMethods.revokeBotMemoryShare)));
      await expectLater(
        share(entry, manager: remote),
        throwsA(isA<LinkRemoteException>()),
      );
      await expectLater(
        share(entry, group: outsider),
        throwsA(isA<LinkRemoteException>()),
      );
      bots.changeUserMemory(bot, [
        (
          action: BotMemoryAction.add,
          id: null,
          revision: null,
          text: '茶' * 1373,
        ),
      ], group: other);
      await expectLater(
        share(entry, group: other),
        throwsA(isA<LinkRemoteException>()),
      );
      expect(bots.userMemory(bot, group: other).entries.single.share, isNull);

      final recipient = onlyEntry(await share(entry));
      final approval = recipient['share'] as Map;
      expect(approval, containsPair('sourceId', entry.id));
      expect(approval, containsPair('sourceRevision', entry.revision));
      expect(approval, containsPair('role', 'user'));
      expect(recipient['kind'], 'sharedFact');
      expect(onlyEntry(await share(entry)), recipient);
      final remoteView = onlyEntry(
        await remote.call(LinkMethods.botMemoryEntries, {
          'bot': bot.id,
          'group': home,
        }),
      );
      expect(remoteView, isNot(contains('share')));
      await expectLater(
        revoke(recipient, manager: remote),
        throwsA(isA<LinkRemoteException>()),
      );
      expect(
        () => bots.changeUserMemory(bot, [
          (
            action: BotMemoryAction.remove,
            id: recipient['id'] as int,
            revision: recipient['revision'] as int,
            text: null,
          ),
        ], group: home),
        throwsStateError,
      );
      expect((await revoke(recipient))['entries'], isEmpty);
      expect(bots.userMemory(bot).entries.single.id, entry.id);
      final reapproved = onlyEntry(await share(entry));
      expect((reapproved['share'] as Map)['id'], isNot(approval['id']));
      await expectLater(revoke(recipient), throwsA(isA<LinkRemoteException>()));
    },
  );

  test('recipient snapshots revalidate shares while preserving approved text until replaced', () async {
    final privateAccess = bots.privateFactAccess(bot);
    final fact = bots
        .changeFacts(privateAccess, [
          const BotFactChange(
            action: BotMemoryAction.add,
            kind: BotFactKind.self,
            text: 'Keep notes in pencil',
          ),
        ])
        .entries
        .single;
    await share(fact.entry, factScope: 'private');
    final prompt = workspace.agentSetup!(bots.runtimeFolder(bot, group: home))!
        .workspace()
        .sessionPrompt!;
    final original = prompt(_context, refresh: false);
    expect(original.text, contains('Keep notes in pencil'));
    original.save!(_context);
    final revised = bots
        .changeFacts(privateAccess, [
          BotFactChange(
            action: BotMemoryAction.update,
            id: fact.id,
            revision: fact.revision,
            text: 'Keep notes in ink',
          ),
        ])
        .entries
        .single;
    expect(original.withdrawn(), isFalse);
    final frozen = prompt(_context, refresh: false);
    expect(frozen.text, contains('Keep notes in pencil'));
    expect(frozen.text, isNot(contains('Keep notes in ink')));
    await expectLater(
      share(fact.entry, factScope: 'private'),
      throwsA(isA<LinkRemoteException>()),
    );
    await share(revised.entry, factScope: 'private');
    expect(original.withdrawn(), isTrue);
    expect(() => original.save!(_context), throwsStateError);
    expect(
      prompt(_context, refresh: false).text,
      isNot(contains('Keep notes in pencil')),
    );
    final refreshed = prompt(_context, refresh: true);
    expect(refreshed.text, contains('Keep notes in ink'));
    refreshed.save!(_context);

    bots.changeFacts(privateAccess, [
      BotFactChange(
        action: BotMemoryAction.remove,
        id: revised.id,
        revision: revised.revision,
      ),
    ]);
    expect(refreshed.withdrawn(), isTrue);
    expect(
      prompt(_context, refresh: false).text,
      isNot(contains('Keep notes in ink')),
    );
    expect(bots.userMemory(bot, group: home).entries, isEmpty);
    expect(bots.userMemory(bot, group: other).entries, isEmpty);
  });

  test(
    'project ability loss revokes group shares across reauthorization',
    () async {
      final id = workspace.localProjectId(_project)!;
      final access = bots.projectFactAccess(bot.id, id)!;
      final fact = bots
          .changeFacts(access, [
            const BotFactChange(
              action: BotMemoryAction.add,
              kind: BotFactKind.project,
              text: 'Run release check',
            ),
          ])
          .entries
          .single;
      await share(fact.entry, factScope: 'project', project: id);
      expect(
        bots.userMemory(bot, group: home).prompt,
        contains('Run release check'),
      );
      bots.save(id: bot.id, name: bot.name, identity: '', abilities: {});
      await expectLater(
        share(fact.entry, factScope: 'project', project: id),
        throwsA(isA<LinkRemoteException>()),
      );
      bot = bots.save(
        id: bot.id,
        name: bot.name,
        identity: '',
        abilities: {BotAbility.agents},
      );
      expect(bots.userMemory(bot, group: home).entries, isEmpty);
      await share(fact.entry, factScope: 'project', project: id);
      final name = bots.groups.byId(home)!.name;
      bots.groups.save(id: home, name: name, members: []);
      await expectLater(
        share(fact.entry, factScope: 'project', project: id),
        throwsA(isA<LinkRemoteException>()),
      );
      bots.groups.save(id: home, name: name, members: [bot.id]);
      expect(bots.userMemory(bot, group: home).entries, isEmpty);
    },
  );
}
