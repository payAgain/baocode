import 'dart:convert';
import 'dart:math';
import 'dart:io';
import 'dart:typed_data';

import 'package:bao_link/bao_link.dart' show LinkMethods, linkGroupUser;
import 'package:baocode/bots/bot.dart';
import 'package:baocode/bots/bot_folders.dart';
import 'package:baocode/bots/bot_group_prompt.dart';
import 'package:baocode/bots/bot_groups.dart';
import 'package:baocode/bots/bot_history.dart';
import 'package:baocode/bots/bot_memory.dart' show BotMemoryAction;
import 'package:baocode/bots/bot_memory_review.dart';
import 'package:baocode/bots/bot_prompt.dart' show botEventMessage;
import 'package:baocode/bots/bots.dart';
import 'package:baocode/link/bot_memory_management.dart';
import 'package:baocode/link/chat_codec.dart';
import 'package:baocode/search/memory_history.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/chat_session.dart' show ComposerMessage;
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_code_transport.dart';
import 'package:baocode/kernel/claude_code/mock_claude_code_transport.dart';
import 'package:baocode/workspace/preference_store.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../kernel_test.dart' show FakeCli;

void main() {
  late ClaudeTransportFactory startCli;
  late KernelDescriptor kernel;
  kernel = KernelDescriptor(
    id: 'claude-code',
    label: 'Claude Code',
    icon: Icons.auto_awesome_rounded,
    description: '',
    create: (context) =>
        ClaudeCodeKernel(kernel, context, start: (launch) => startCli(launch)),
  );
  late Workspace workspace;
  late Bots bots;
  late BotGroups groups;
  late MemoryBotFolders folders;
  late DateTime now;
  late Bot mia, leo, ann;

  /// What each bot was told, in turn.
  late List<(String, String)> told;

  setUp(() async {
    startCli = MockClaudeCodeTransport.start;
    final app = Directory.systemTemp.createTempSync('groups-app').path;
    addTearDown(() => Directory(app).deleteSync(recursive: true));
    workspace = Workspace(kernels: [kernel], projects: [Project('app', app)]);
    folders = MemoryBotFolders();
    now = DateTime(2026, 11, 12, 14);
    bots = Bots(
      workspace: workspace,
      folders: folders,
      store: MemoryPreferenceStore(),
      chinese: true,
      clock: () => now,
      computer: () async => 'Leo 的 MacBook',
    );
    await bots.start();
    mia = bots.save(name: 'Mia', identity: '', abilities: {}, chatOnly: true);
    leo = bots.save(name: 'Leo', identity: '', abilities: {});
    ann = bots.save(name: 'Ann', identity: '', abilities: {});
    told = [];
    groups = bots.groups
      ..random = Random(1)
      ..tell = (group, member, note) => told.add((member, note));
  });

  tearDown(() {
    bots.dispose();
    workspace.dispose();
  });

  String name(String id) => bots.byId(id)!.name;
  List<String> toldNames() => [for (final (who, _) in told) name(who)];
  Future<void> wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

  test(
    'original group deletion survives history rebuild and review replay',
    () async {
      final group = groups.save(
        name: 'Source deletion',
        members: [mia.id, leo.id],
        lead: mia.id,
      );
      final scope = MemoryHistoryScope.group(mia.id, group.id);
      final reviewScope = BotMemoryScope(botId: mia.id, groupId: group.id);
      final reviewStore = MemoryPreferenceStore();
      final reviewSession = BotGroups.reviewSessionId(group.id);
      var applications = 0;
      BotMemoryReview makeReview() => BotMemoryReview(
        store: reviewStore,
        scopeExists: bots.reviewScopeExists,
        sourceGeneration: (scope) => groups.sourceGeneration(scope.groupId!),
        readEvidence: bots.reviewEvidence,
        readMemory: (scope) =>
            bots.userMemory(bots.byId(scope.botId)!, group: scope.groupId),
        applyMemory:
            (
              _,
              _, {
              required sessionId,
              required messageId,
              required operationId,
              required changeSources,
            }) {
              applications++;
            },
        ask: (_) async => jsonEncode({
          'proposals': [
            {
              'action': 'add',
              'text': 'Synthetic proposal',
              'evidence': ['e1'],
            },
          ],
        }),
        foregroundBusy: () => false,
        threshold: 1,
      );
      final review = makeReview();
      await review.configure(reviewScope, memoryApproval: true);
      final seq = groups.send(
        group.id,
        text: 'synthetic deleted words',
        linkRequest: (
          key: 'fixture-request',
          fingerprint: 'fixture-fingerprint',
        ),
      );
      await wait(0);
      groups.turnEnded(
        group.id,
        mia.id,
        '<bot_say>Surviving neighbor</bot_say>',
      );
      final evidence = BotMemoryReviewEvidence(
        messageId: '$seq',
        role: BotMemoryReviewRole.user,
      );
      await review.recordTurn(
        scope: reviewScope,
        sessionId: reviewSession,
        turnId: '$seq',
        evidence: [evidence],
      );
      await review.runNext();
      final proposal = (await review.proposals(reviewScope)).single;
      bots.changeUserMemory(
        mia,
        [
          (
            action: BotMemoryAction.add,
            id: null,
            revision: null,
            text: 'Source-backed fact',
          ),
        ],
        group: group.id,
        session: reviewSession,
        sourceMessage: '$seq',
      );
      bots.changeUserMemory(mia, [
        (
          action: BotMemoryAction.add,
          id: null,
          revision: null,
          text: 'Independent fact',
        ),
      ], group: group.id);

      final ref = MemoryHistoryReference(
        scope: scope,
        sessionId: group.id,
        messageId: '$seq',
      );
      final access = MemoryHistoryAccess(
        current: scope,
        isAuthorized: (_) => true,
      );
      final management = BotMemoryManagement(
        bots,
        reviewer: 'local owner',
        localOwner: true,
      );
      const needle = 'synthetic deleted words';
      final args = {'bot': mia.id, 'group': group.id};
      final search = await management.call(LinkMethods.botMemorySearch, {
        ...args,
        'query': needle,
      });
      final hit = (search['hits'] as List).single as Map;
      final before = await management.call(LinkMethods.botMemorySource, {
        ...args,
        'source': hit['reference'],
      });
      expect(before['canDeleteOriginal'], isTrue);
      final anchor = (before['anchor'] as Map)['reference'];
      await expectLater(
        management.call(LinkMethods.deleteBotMemorySource, {
          ...args,
          'source': anchor,
        }),
        throwsA(anything),
      );
      expect(await botHistoryIndex(bots).locate(access, ref), isNotNull);
      expect(
        await management.call(LinkMethods.deleteBotMemorySource, {
          ...args,
          'source': anchor,
          'confirm': true,
        }),
        {'deleted': true},
      );
      await expectLater(
        management.call(LinkMethods.botMemorySource, {
          ...args,
          'source': anchor,
        }),
        throwsA(anything),
      );
      expect(groups.isDeletedLinkRequest('fixture-request'), isTrue);
      expect(
        groups.messages(group.id).map((message) => message.seq),
        isNot(contains(seq)),
      );
      final canonical = p.join(
        p.dirname(groups.chatFile(group.id)),
        'messages.jsonl',
      );
      expect(
        utf8.decode(folders.readFile(canonical)!),
        isNot(contains(needle)),
      );
      expect(
        utf8.decode(folders.readFile(groups.chatFile(group.id))!),
        isNot(contains(needle)),
      );
      expect(
        bots.userMemory(mia, group: group.id).prompt,
        '- Independent fact',
      );

      // Construct a fresh index and journal viewer over persisted host state.
      bots.dispose();
      workspace.dispose();
      workspace = Workspace(kernels: [kernel]);
      bots = Bots(
        workspace: workspace,
        folders: folders,
        clock: () => now,
        computer: () async => 'Mac',
      );
      await bots.start();
      groups = bots.groups;
      expect(groups.isDeletedLinkRequest('fixture-request'), isTrue);
      final index = botHistoryIndex(bots);
      await index.rebuild(scope);
      expect(await index.locate(access, ref), isNull);
      expect(await index.browse(access, ref), isNull);
      expect(
        (await index.search(
          access,
          const MemoryHistoryQuery(text: needle),
        )).hits,
        isEmpty,
      );
      expect(
        (await index.search(
          access,
          const MemoryHistoryQuery(text: 'Surviving neighbor'),
        )).hits,
        hasLength(1),
      );
      expect(
        await bots.reviewEvidence(reviewScope, reviewSession, evidence),
        isNull,
      );
      final restarted = makeReview();
      expect(await restarted.proposals(reviewScope), isEmpty);
      final stale = await restarted.decide(
        scope: reviewScope,
        proposalId: proposal.id,
        approve: true,
        reviewer: 'owner',
      );
      expect(stale.status, BotMemoryReviewProposalStatus.invalid);
      expect(stale.evidence, isEmpty);
      expect(stale.after, isNull);
      expect(applications, 0);
      final currentBot = bots.byId(mia.id)!;
      final memory = bots.userMemory(currentBot, group: group.id);
      final suspended = memory.entries.first;
      expect(memory.unavailableEntries, {suspended.id});
      bots.retainGroupMemory(
        currentBot,
        group.id,
        suspended.id,
        suspended.revision,
      );
      expect(
        bots.userMemory(currentBot, group: group.id).prompt,
        contains('Source-backed fact'),
      );
    },
  );

  test(
    'queued private messages are restored and dispatched after restart',
    () async {
      final group = groups.save(name: 'Queue room', members: [mia.id]);
      groups.send(group.id, text: '@Mia group prompt');
      bots.sendPrivate(mia, const ComposerMessage(text: 'saved private input'));
      expect(
        bots.pendingPrivateItems(mia).single,
        isA<UserMessageItem>()
            .having((item) => item.queued, 'queued', isTrue)
            .having((item) => item.text, 'text', 'saved private input'),
      );
      expect(bots.threadOf(mia)!.session.itemCount, 0);
      bots.dispose();
      workspace.dispose();

      workspace = Workspace(kernels: [kernel]);
      bots = Bots(
        workspace: workspace,
        folders: folders,
        clock: () => now,
        computer: () async => 'Mac',
      );
      await bots.start();
      await wait(40);
      final session = bots.threadOf(bots.byId(mia.id)!)!.session;
      expect(
        [
          for (var index = 0; index < session.itemCount; index++)
            if (session.itemAt(index) case UserMessageItem(:final text)) text,
        ],
        ['saved private input'],
      );
      expect(bots.pendingPrivateItems(mia), isEmpty);
      expect(bots.groups.messages(group.id).single.text, '@Mia group prompt');
    },
  );

  test('a group kept: its members those there are, named after them if '
      'not named', () {
    final group = groups.save(name: '', members: [mia.id, leo.id, 'nobody']);
    expect(group.members, [mia.id, leo.id]);
    expect(group.name, 'Mia、Leo');
    final kept = jsonDecode(
      utf8.decode(folders.files['/bots/groups/groups.json']!),
    ) as List;
    expect((kept.single as Map)['members'], [mia.id, leo.id]);
  });

  test('the stored lead clears on removal, bot deletion, and reset', () {
    final members = [mia.id, leo.id, ann.id];
    final group = groups.save(name: 'Planning', members: members, lead: leo.id);
    final id = group.id;
    BotGroup? coldGroup() {
      final cold = BotGroups(bots)..start();
      try {
        return cold.byId(id);
      } finally {
        cold.dispose();
      }
    }

    expect(coldGroup()!.lead, leo.id);
    groups.save(id: id, name: 'Planning', members: [mia.id, ann.id]);
    expect(coldGroup()!.toJson().containsKey('lead'), isFalse);
    groups.save(id: id, name: 'Planning', members: members);
    expect(coldGroup()!.lead, isNull);

    groups.save(id: id, name: 'Planning', members: members, lead: leo.id);
    bots.delete(leo.id);
    expect(coldGroup()!.members, [mia.id, ann.id]);
    expect(coldGroup()!.lead, isNull);

    groups.save(
      id: id,
      name: 'Planning',
      members: [mia.id, ann.id],
      lead: ann.id,
    );
    expect(coldGroup()!.lead, ann.id);
    groups.save(
      id: id,
      name: 'Planning',
      members: [mia.id, ann.id],
      clearLead: true,
    );
    expect(coldGroup()!.lead, isNull);
    groups.say(id, mia.id, 'Recent reply');
    groups.send(id, text: 'Continue');
    expect(groups.relay(id).holder, mia.id);
    groups.delete(id);
    expect(coldGroup(), isNull);
  });

  test('removing the active lead cannot replay the next message', () {
    final group = groups.save(
      name: 'g',
      members: [mia.id, leo.id],
      lead: mia.id,
    );
    groups.send(group.id, text: 'Start');
    groups.send(group.id, text: 'While the lead is busy');
    expect(toldNames(), ['Mia']);
    groups.save(id: group.id, name: group.name, members: [leo.id]);
    groups.send(group.id, text: 'Next');
    expect(toldNames(), ['Mia', 'Leo']);
    groups.turnEnded(group.id, leo.id, '<bot_say>Done</bot_say>');
    expect(toldNames(), ['Mia', 'Leo']);
    expect(groups.relay(group.id).holder, isNull);
  });

  test('a timed-out lead does not hand off to a removed member', () async {
    groups.stuck = const Duration(milliseconds: 20);
    final group = groups.save(
      name: 'g',
      members: [mia.id, leo.id],
      lead: mia.id,
    );
    groups.send(group.id, text: 'Start');
    groups.save(id: group.id, name: group.name, members: [mia.id]);
    await wait(50);
    expect(toldNames(), ['Mia']);
    expect(groups.relay(group.id).holder, isNull);
  });

  test('what is said kept, and as the bots read it: each message under its '
      'number, who and when; pictures by their files', () async {
    final group = groups.save(name: '江湖', members: [mia.id, leo.id]);
    groups.send(
      group.id,
      text: '你们好',
      images: [
        ImageAttachment(
          bytes: Uint8List.fromList([1, 2]),
          mediaType: 'image/jpeg',
        ),
      ],
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    groups.turnEnded(
      group.id,
      mia.id,
      '<bot_say>[laughs] 嗨</bot_say><bot_narrate>她挥挥手</bot_narrate>',
    );
    final messages = groups.messages(group.id);
    expect(messages.map((m) => (m.seq, m.from)), [
      (1, linkGroupUser),
      (2, mia.id),
    ]);
    expect(messages.first.images, ['1-1.jpg']);
    expect(groups.image(group.id, '1-1.jpg')!.type, 'image/jpeg');
    expect(groups.image(group.id, '../groups.json'), isNull);
    final chat = utf8.decode(folders.files[groups.chatFile(group.id)]!);
    expect(chat, contains('# 江湖'));
    expect(
      chat,
      contains('## #1 · 用户 · 2026-11-12 14:00:00\n你们好\n![picture]('),
    );
    expect(chat, contains('## #2 · Mia · 2026-11-12 14:00:00\n嗨\n*她挥挥手*'));
    // Kept: there again when the app starts again.
    final again = BotGroups(bots)..start();
    addTearDown(again.dispose);
    expect(again.messages(group.id), hasLength(2));
  });

  String? holder(BotGroup group) => groups.relay(group.id).holder;

  test(
    'cold group routing prioritizes @, then the saved lead, then fallback',
    () {
      const path = '/bots/groups/groups.json';
      final base = groups.save(
        name: 'Legacy',
        members: [mia.id, leo.id, ann.id],
      );
      final led = groups.save(name: 'With lead', members: base.members);
      folders.writeFile(
        path,
        utf8.encode(
          jsonEncode([
            base.toJson(),
            {...led.toJson(), 'lead': leo.id},
          ]),
        ),
      );
      final cold = BotGroups(bots)..start();
      addTearDown(cold.dispose);
      cold.tell = (_, member, note) => told.add((member, note));

      cold.say(led.id, ann.id, 'Earlier update');
      cold.send(led.id, text: 'Check this @Mia', ref: 1);
      expect(cold.relay(led.id).holder, mia.id);
      cold.turnEnded(led.id, mia.id, '<bot_say>Acknowledged</bot_say>');

      cold.send(led.id, text: 'Continue', ref: 1);
      expect(cold.relay(led.id).holder, leo.id);
      expect(told.last.$2, contains('you are this group\'s default lead'));

      cold.say(base.id, ann.id, 'Quote this');
      cold.say(base.id, mia.id, 'More recent');
      cold.send(base.id, text: 'Follow up', ref: 1);
      expect(cold.relay(base.id).holder, ann.id);
    },
  );

  test('the user speaks: it goes to whom they call on; else to the bot '
      'that spoke last; else to one at random', () async {
    final group = groups.save(name: 'g', members: [mia.id, leo.id, ann.id]);
    groups.send(group.id, text: '你好 @Leo @Ann');
    expect(toldNames(), ['Leo']);
    expect(holder(group), leo.id);
    final note = told.single.$2;
    expect(note, contains('Now: 2026-11-12 14:00:00.'));
    expect(note, contains('## #1 · 用户 · 2026-11-12 14:00:00 · new\n你好'));
    expect(note, contains('Why you are told now: 用户 called on you (@).'));
    expect(note, contains('In it: you (Leo), 用户 (the user), Mia, Ann.'));
    expect(note, contains('<bot_next>name</bot_next>'));
    expect(note, contains('No <bot_next> means the conversation stops'));
    groups.turnEnded(group.id, leo.id, '<bot_say>好</bot_say>');
    expect(holder(group), isNull);
    now = now.add(const Duration(minutes: 5));
    groups.send(group.id, text: '在吗');
    expect(toldNames(), ['Leo', 'Leo']);
    expect(told.last.$2, contains('you were the last to speak here'));
    expect(
      told.last.$2,
      contains('You last looked at it: 2026-11-12 14:00:00.'),
    );
    // #1 seen before; #2 its own; #3 new.
    expect(told.last.$2, contains('· 2026-11-12 14:00:00\n你好'));
    expect(told.last.$2, contains('## #3 · 用户 · 2026-11-12 14:05:00 · new'));
    final fresh = groups.save(name: 'h', members: [mia.id, ann.id]);
    groups.send(fresh.id, text: '大家好');
    expect([mia.id, ann.id], contains(holder(fresh)));
    expect(told.last.$2, contains('no one here has yet: you start'));
  });

  test(
    'passed on as it says, as many times as it may; then it stops',
    () async {
      final group = groups.save(name: 'g', members: [mia.id, leo.id]);
      groups.send(group.id, text: '@Mia 聊聊');
      var turns = 0;
      for (var who = holder(group); who != null; who = holder(group)) {
        turns++;
        groups.turnEnded(
          group.id,
          who,
          '<bot_say>$turns</bot_say>',
          next: who == mia.id ? 'Leo' : 'Mia',
        );
      }
      // The user's, then eight passes.
      expect(turns, 9);
      expect(
        told[1].$2,
        contains('Why you are told now: Mia handed the conversation to you.'),
      );
      expect(told.last.$2, contains('Hand it to no one now'));
      expect(told.last.$2, isNot(contains('<bot_next>name')));
    },
  );

  test('passed to no one, to the user, or to itself: it stops', () {
    final group = groups.save(name: 'g', members: [mia.id, leo.id]);
    for (final next in [null, '用户', 'Mia', ' ']) {
      told.clear();
      groups.send(group.id, text: '@Mia 嗯');
      groups.turnEnded(group.id, mia.id, '', next: next);
      expect(holder(group), isNull);
      expect(toldNames(), ['Mia']);
    }
  });

  test('passed by a name without what is in brackets, or by its start: '
      'to them; to one not there: back, told who is', () {
    final bo = bots.save(name: '小包（私人助理）', identity: '', abilities: {});
    final group = groups.save(name: 'g', members: [mia.id, leo.id, bo.id]);
    groups.send(group.id, text: '@Mia 嗯');
    groups.turnEnded(group.id, mia.id, '<bot_say>好</bot_say>', next: '@小包');
    expect(holder(group), bo.id);
    groups.turnEnded(group.id, bo.id, '<bot_say>在</bot_say>', next: 'Le');
    expect(holder(group), leo.id);
    groups.turnEnded(group.id, leo.id, '<bot_say>嗯</bot_say>', next: '苏九娘');
    expect(holder(group), leo.id);
    expect(
      told.last.$2,
      contains(
        'Why you are told now: you wrote <bot_next>苏九娘</bot_next>, but '
        'there is no 苏九娘 in this group, so it reached no one.',
      ),
    );
    expect(told.last.$2, contains('Hand it to one of Mia, 小包（私人助理）'));
    groups.turnEnded(group.id, leo.id, '');
    expect(holder(group), isNull);
    expect(groups.relay(group.id).left, BotGroups.passes - 3);
  });

  test('quoting: the user quoting a bot has it answer; a bot quotes by its '
      'number; each read with what it quotes', () {
    final group = groups.save(name: 'g', members: [mia.id, leo.id]);
    groups.say(group.id, leo.id, '我昨天吃了布丁');
    groups.send(group.id, text: '真的吗', ref: 1);
    expect(holder(group), leo.id);
    expect(told.last.$2, contains('用户 answered your message (quoted it)'));
    expect(told.last.$2, contains('> re #1 · Leo: 我昨天吃了布丁\n真的吗'));
    final reply = BotGroups.replyTo([
      UserMessageItem(text: botEventMessage(told.last.$2)),
      const AssistantTextItem(
        '<bot_say ref="2">真的</bot_say><bot_narrate>他点头</bot_narrate>',
      ),
    ], group.id);
    expect(
      reply,
      '<bot_say ref="2">真的</bot_say><bot_narrate>他点头</bot_narrate>',
    );
    groups.turnEnded(group.id, leo.id, reply, next: 'Mia');
    expect(told.last.$2, contains('> re #2 · 用户: 真的吗\n真的'));
    expect(groups.messages(group.id)[1].ref, 1);
    // One quoting none before it: none.
    groups.send(group.id, text: '嗯', ref: 99);
    expect(groups.messages(group.id).last.ref, isNull);
  });

  test("told the group's rules, and a reply as an example", () {
    final group = groups.save(
      name: 'g',
      members: [mia.id, leo.id],
      rules: '只说中文',
    );
    groups.send(group.id, text: '@Mia 嗨');
    final note = told.last.$2;
    expect(
      note,
      contains("The group's rules, which everyone here keeps to:\n只说中文"),
    );
    expect(note, contains('<bot_say ref="1">哈哈 才不是我</bot_say>'));
    expect(note, contains('<bot_next>Leo</bot_next>'));
    expect(groups.messages(group.id).where((m) => m.notice), isEmpty);
    groups.save(id: group.id, name: 'g', members: [mia.id, leo.id], rules: '');
    expect(groups.messages(group.id).last.text, '用户 修改了群规');
  });

  test(
    'passed on at most as the group says: at least two; none, unbounded',
    () {
      final group = groups.save(
        name: 'g',
        members: [mia.id, leo.id],
        passes: 1,
      );
      expect(group.passes, 2);
      groups.send(group.id, text: '@Mia 聊');
      expect(groups.relay(group.id).left, 2);
      groups.save(
        id: group.id,
        name: 'g',
        members: [mia.id, leo.id],
        passes: 0,
      );
      groups.turnEnded(group.id, mia.id, '');
      groups.send(group.id, text: '@Mia 再聊');
      expect(groups.relay(group.id).left, BotGroups.unbounded);
    },
  );

  test('handed on by a bot: told after the group\'s gap; the user speaking '
      'meanwhile, it goes as they say', () async {
    final group = groups.save(
      name: 'g',
      members: [mia.id, leo.id, ann.id],
      gap: 1,
    );
    expect(group.gap, 1);
    // The user's: at once.
    groups.send(group.id, text: '@Mia 聊');
    expect(toldNames(), ['Mia']);
    groups.turnEnded(group.id, mia.id, '<bot_say>嗯</bot_say>', next: 'Leo');
    expect(holder(group), leo.id);
    expect(toldNames(), ['Mia']);
    expect(groups.typing(group.id), isEmpty);
    await wait(1100);
    expect(toldNames(), ['Mia', 'Leo']);

    groups.turnEnded(group.id, leo.id, '<bot_say>好</bot_say>', next: 'Mia');
    groups.send(group.id, text: '@Ann 你呢');
    expect(toldNames(), ['Mia', 'Leo', 'Ann']);
    await wait(1100);
    expect(toldNames(), ['Mia', 'Leo', 'Ann']);
    expect(holder(group), ann.id);
  });

  test('one that cannot take it, busy elsewhere or its turn failed: '
      'another who is free has it, told why', () {
    final group = groups.save(name: 'g', members: [mia.id, leo.id, ann.id]);
    final other = groups.save(name: '别处', members: [leo.id, mia.id]);
    groups.send(other.id, text: '@Leo 忙吗');
    groups.send(group.id, text: '@Mia 你先');
    groups.turnEnded(group.id, mia.id, '<bot_say>好</bot_say>', next: 'Leo');
    // Leo at work in the other: Ann, not Mia who passed it.
    expect(holder(group), ann.id);
    expect(
      told.last.$2,
      contains(
        'Why you are told now: Mia passed it to Leo, but Leo is busy in '
        '"别处"; so it is yours.',
      ),
    );
    groups.turnEnded(group.id, ann.id, '', failed: true);
    expect(holder(group), mia.id);
    expect(told.last.$2, contains('but Ann ran into an error; so it is yours'));
  });

  test(
    'one not done in time: another has it; its words still said after',
    () async {
      groups.stuck = const Duration(milliseconds: 30);
      final group = groups.save(name: 'g', members: [mia.id, leo.id]);
      groups.send(group.id, text: '@Mia 在吗');
      await wait(60);
      expect(holder(group), leo.id);
      expect(
        told.last.$2,
        contains('用户 called on Mia, but Mia did not answer in 0 seconds'),
      );
      groups.turnEnded(group.id, mia.id, '<bot_say>来了</bot_say>', next: 'Leo');
      expect(groups.messages(group.id).last.text, '<bot_say>来了</bot_say>');
      expect(holder(group), leo.id);
      expect(toldNames(), ['Mia', 'Leo']);
    },
  );

  test('the user speaking while one is at work on it: once it is done, it '
      'goes as when they spoke', () {
    final group = groups.save(name: 'g', members: [mia.id, leo.id, ann.id]);
    groups.send(group.id, text: '@Mia 一');
    groups.send(group.id, text: '@Leo 二');
    expect(toldNames(), ['Mia']);
    groups.turnEnded(group.id, mia.id, '<bot_say>嗯</bot_say>', next: 'Ann');
    expect(toldNames(), ['Mia', 'Leo']);
    expect(told.last.$2, contains('用户 called on you'));
    expect(told.last.$2, contains('## #3 · Mia · 2026-11-12 14:00:00 · new'));
  });

  test('told the latest twenty, each cut past its length, where all of it '
      'is said', () {
    final group = groups.save(name: 'g', members: [mia.id]);
    for (var i = 1; i <= 24; i++) {
      groups.say(group.id, mia.id, i == 20 ? 'x' * 600 : '$i');
    }
    groups.send(group.id, text: '@Mia 看看');
    final note = told.single.$2;
    expect(
      note,
      contains('The latest messages (#6–#25), the new ones marked:'),
    );
    expect(note, isNot(contains('## #5 ·')));
    expect(note, contains('${'x' * 500}… (use bot_history'));
    expect(note, isNot(contains('x' * 501)));
  });

  test('private and each group have separate workers, prompts, and tools', () {
    final group = groups.save(name: '江湖', members: [mia.id, leo.id]);
    final other = groups.save(name: '别处', members: [mia.id]);
    bots.setMemory(mia, 'private-only note');
    final dm = bots.threadFor(mia);
    final first = bots.threadFor(mia, group: group.id);
    final second = bots.threadFor(mia, group: other.id);
    expect({
      dm.project.path,
      first.project.path,
      second.project.path,
    }, hasLength(3));
    expect(identical(bots.threadFor(mia, group: group.id), first), isTrue);
    final setup = workspace.agentSetup!(dm.project.path)!.workspace();
    final room = workspace.agentSetup!(first.project.path)!.workspace();
    expect(setup.instructions, contains('private-only note'));
    expect(room.instructions, contains('Your name is Mia.'));
    expect(room.instructions, contains('<group_chats>'));
    expect(room.instructions, isNot(contains('private-only note')));
    expect(room.instructions, isNot(contains('/bots/WORLD.md')));
    expect(room.tools, isEmpty);
    expect(room.userServers, isFalse);
    expect(bots.offersTool(first.project.path, 'session_read'), isFalse);
    expect(bots.offersTool(first.project.path, 'bot_history'), isTrue);
    expect(bots.offersTool(mia.folder, 'bot_history'), isFalse);
    // The world they share: everyone, and who is in which group.
    final world = utf8.decode(folders.files['/bots/WORLD.md']!);
    expect(world, contains('- Mia'));
    expect(world, contains('[only chats]'));
    expect(
      world,
      contains('- "江湖": 用户, Mia, Leo. Its chat: ${groups.chatFile(group.id)}'),
    );
  });

  for (final inGroup in [false, true]) {
    test(
      'compaction refreshes only the active ${inGroup ? 'group' : 'private'} '
      'bot prompt and keeps the session',
      () async {
        final launches = <ClaudeLaunch>[];
        final workers = <FakeCli>[];
        startCli = (launch) async {
          launches.add(launch);
          final cli = FakeCli();
          workers.add(cli);
          return cli;
        };
        groups.tell = null;
        final bot = inGroup ? leo : mia;
        final group = groups.save(name: 'Planning', members: [bot.id]);
        final other = groups.save(name: 'Research', members: [bot.id]);
        final scope = inGroup ? group.id : null;
        final requestedScope = inGroup ? other.id : group.id;
        void remember(String text, {String? group}) {
          bots.changeUserMemory(bot, [
            (action: BotMemoryAction.add, id: null, revision: null, text: text),
          ], group: group);
        }

        remember('Private memory');
        remember('Planning memory', group: group.id);
        remember('Research memory', group: other.id);
        final ownMemory = inGroup ? 'Planning memory' : 'Private memory';
        final session = bots.threadFor(bot, group: scope).session;
        void send(String text) {
          if (scope == null) {
            bots.sendPrivate(bot, ComposerMessage(text: text));
          } else {
            groups.send(scope, text: '@${bot.name} $text');
          }
        }

        send('First question');
        await pumpEventQueue();
        final cli = workers.single;
        expect(launches.single.ownPrompt, isTrue);
        expect(launches.single.refreshSystemPromptOnCompaction, isTrue);
        expect(launches.single.instructions, contains(ownMemory));
        expect(launches.single.instructions, isNot(contains('Fresh memory')));
        expect(cli.users, hasLength(1));
        expect(session.isStreaming, isTrue);
        const sessionId = '821354b1-8c65-42a1-a205-bbc5254b79f1';
        cli.push({
          'type': 'system',
          'subtype': 'init',
          'session_id': sessionId,
        });

        // Written after launch, so the response must use current host memory.
        remember('Fresh memory', group: scope);
        cli.push({
          'type': 'control_request',
          'request_id': 'refresh',
          'request': {
            'subtype': 'refresh_system_prompt',
            'group_id': requestedScope,
            'cwd': bots.runtimeFolder(bot, group: requestedScope),
          },
        });
        await pumpEventQueue();
        final response =
            cli.written.singleWhere(
                  (message) => message['type'] == 'control_response',
                )['response']
                as Map;
        expect(response['request_id'], 'refresh');
        expect(response['subtype'], 'success');
        final prompt = (response['response'] as Map)['system_prompt'];
        expect(prompt, contains(ownMemory));
        expect(prompt, contains('Fresh memory'));
        for (final note in [
          'Private memory',
          'Planning memory',
          'Research memory',
        ]) {
          if (note != ownMemory) expect(prompt, isNot(contains(note)));
        }
        expect(session.isStreaming, isTrue);
        expect(session.sessionId, sessionId);
        expect(workers, [cli]);
        expect(cli.users, hasLength(1));

        Future<void> compact({required bool refreshed}) async {
          cli.push({
            'type': 'system',
            'subtype': 'compact_boundary',
            'uuid': 'compaction-$refreshed',
            'compact_metadata': {
              'trigger': 'auto',
              if (refreshed) ...{
                'system_prompt_refreshed': true,
                'prompt_request_id': 'refresh',
              },
            },
          });
          cli.push({'type': 'result', 'subtype': 'success'});
          await pumpEventQueue();
          expect(session.isStreaming, isFalse);
          expect(bots.threadFor(bot, group: scope).session, same(session));
          expect(session.sessionId, sessionId);
        }

        await compact(refreshed: true);
        if (!inGroup) expect(bots.byId(bot.id)?.chatOnly, isTrue);
        expect(workers, [cli]);
        expect(cli.closed, isFalse);
        send('Second question');
        await pumpEventQueue();
        expect(cli.users, hasLength(2));
        expect(session.isStreaming, isTrue);
        await compact(refreshed: false);
        expect(cli.closed, isTrue);
        expect(launches, hasLength(2));
        expect(launches.last.resume, sessionId);
        expect(launches.last.instructions, contains('Fresh memory'));
      },
    );
  }

  for (final inGroup in [false, true]) {
    test('cold resume freezes ${inGroup ? 'group' : 'private'} bot memory '
        'until compaction or withdrawal', () async {
      final launches = <ClaudeLaunch>[];
      final workers = <FakeCli>[];
      startCli = (launch) async {
        launches.add(launch);
        final cli = FakeCli();
        workers.add(cli);
        return cli;
      };
      const original = 'Original user note';
      const edited = 'Edited user note';
      const later = 'Later user note';
      const withdrawn = 'Withdrawn user note';
      const other = 'Note from the other conversation';
      const sessionId = '821354b1-8c65-42a1-a205-bbc5254b79f1';
      groups.tell = null;
      var bot = inGroup ? leo : mia;
      final group = groups.save(name: 'Planning', members: [bot.id]);
      final scope = inGroup ? group.id : null;
      bots.changeUserMemory(bot, [
        (action: BotMemoryAction.add, id: null, revision: null, text: original),
        (
          action: BotMemoryAction.add,
          id: null,
          revision: null,
          text: withdrawn,
        ),
      ], group: scope);
      bots.changeUserMemory(bot, [
        (action: BotMemoryAction.add, id: null, revision: null, text: other),
      ], group: inGroup ? null : group.id);

      void editNote(String text) {
        final entry = bots.userMemory(bot, group: scope).entries.first;
        bots.changeUserMemory(bot, [
          (
            action: BotMemoryAction.update,
            id: entry.id,
            revision: entry.revision,
            text: text,
          ),
        ], group: scope);
      }

      void expectNotes(Object? prompt, String included, {bool pruned = false}) {
        expect(
          prompt,
          allOf([
            contains(included),
            for (final note in [original, edited, later, other])
              if (note != included) isNot(contains(note)),
            pruned ? isNot(contains(withdrawn)) : contains(withdrawn),
          ]),
        );
      }

      Future<FakeCli> send(String text) async {
        final launched = workers.length;
        if (scope == null) {
          bots.sendPrivate(bot, ComposerMessage(text: text));
        } else {
          groups.send(scope, text: '@${bot.name} $text');
        }
        await pumpEventQueue();
        expect(workers, hasLength(launched + 1));
        expect(workers.last.users, hasLength(1));
        return workers.last;
      }

      final initialThread = bots.threadFor(bot, group: scope);
      final initial = initialThread.session;
      final first = await send('First question');
      expect(launches.single.resume, isNull);
      expectNotes(launches.single.instructions, original);
      first.push({
        'type': 'system',
        'subtype': 'init',
        'session_id': sessionId,
      });
      first.push({'type': 'result', 'subtype': 'success'});
      await pumpEventQueue();
      expect(initial.isStreaming, isFalse);
      expect(initialThread.id, sessionId);

      final record = SessionRecord(
        id: initialThread.id!,
        title: 'First question',
        updatedAt: now,
        cwd: initialThread.project.path,
      );
      final keptKernel = KernelDescriptor(
        id: kernel.id,
        label: kernel.label,
        icon: kernel.icon,
        description: kernel.description,
        create: kernel.create,
        catalog: _KeptSessionCatalog(record),
      );
      Future<void> reopen() async {
        bots.dispose();
        workspace.dispose();
        workspace = Workspace(kernels: [keptKernel]);
        bots = Bots(
          workspace: workspace,
          folders: folders,
          chinese: true,
          clock: () => now,
          computer: () async => 'Leo 的 MacBook',
        );
        expect(workers.last.closed, isTrue);
        final loaded = workspace.load();
        await bots.start();
        await loaded;
        groups = bots.groups;
        bot = bots.byId(bot.id)!;
        expect(bots.threadFor(bot, group: scope).record, same(record));
      }

      editNote(edited);
      await reopen();
      expect(bots.userMemory(bot, group: scope).entries.first.text, edited);
      final resumed = bots.threadFor(bot, group: scope).session;
      expect(resumed, isNot(same(initial)));
      final second = await send('Resume the conversation');
      expect(launches.last.resume, sessionId);
      expectNotes(launches.last.instructions, original);
      expect(resumed.isStreaming, isTrue);
      second.push({
        'type': 'control_request',
        'request_id': 'refresh',
        'request': {'subtype': 'refresh_system_prompt'},
      });
      await pumpEventQueue();
      expectNotes(second.responses.single['system_prompt'], edited);
      expect(resumed.sessionId, sessionId);
      expect(launches, hasLength(2));

      // Only the notes sent in the refresh response have reached the model.
      editNote(later);
      second.push({
        'type': 'system',
        'subtype': 'compact_boundary',
        'uuid': 'compaction',
        'compact_metadata': {
          'trigger': 'auto',
          'system_prompt_refreshed': true,
          'prompt_request_id': 'refresh',
        },
      });
      second.push({'type': 'result', 'subtype': 'success'});
      await pumpEventQueue();
      expect(resumed.isStreaming, isFalse);
      expect(resumed.sessionId, sessionId);
      expect(second.closed, isFalse);
      expect(launches, hasLength(2));

      await reopen();
      expect(bots.userMemory(bot, group: scope).entries.first.text, later);
      final third = await send('Resume after compaction');
      expect(launches.last.resume, sessionId);
      expectNotes(launches.last.instructions, edited);
      final active = bots.threadFor(bot, group: scope).session;
      expect(active.isStreaming, isTrue);

      Future<Map<String, Object?>> checkPrompt(String id) async {
        third.push({
          'type': 'control_request',
          'request_id': id,
          'request': {'subtype': 'check_system_prompt'},
        });
        await pumpEventQueue();
        return third.responses.last;
      }

      expect(await checkPrompt('before-withdrawal'), {'valid': true});
      final snapshotPath = folders.files.keys.singleWhere(
        (path) => path.contains('/prompt-memory-v1/'),
      );
      final earlierSnapshot = utf8.decode(folders.files[snapshotPath]!);
      expectNotes(earlierSnapshot, edited);
      final entry = bots.userMemory(bot, group: scope).entries.last;
      expect(entry.text, withdrawn);
      bots.changeUserMemory(bot, [
        (
          action: BotMemoryAction.remove,
          id: entry.id,
          revision: entry.revision,
          text: null,
        ),
      ], group: scope);

      final checked = await checkPrompt('after-withdrawal');
      expect(checked['valid'], isTrue);
      expectNotes(checked['system_prompt'], edited, pruned: true);
      expect(utf8.decode(folders.files[snapshotPath]!), earlierSnapshot);
      expect(active.isStreaming, isTrue);
      expect(active.sessionId, sessionId);
      expect(launches, hasLength(3));

      third.push({
        'type': 'system',
        'subtype': 'host_prompt_applied',
        'prompt_request_id': 'before-withdrawal',
      });
      await pumpEventQueue();
      expect(utf8.decode(folders.files[snapshotPath]!), earlierSnapshot);
      third.push({
        'type': 'system',
        'subtype': 'host_prompt_applied',
        'prompt_request_id': 'after-withdrawal',
      });
      await pumpEventQueue();
      expectNotes(
        utf8.decode(folders.files[snapshotPath]!),
        edited,
        pruned: true,
      );
      third.push({'type': 'result', 'subtype': 'success'});
      await pumpEventQueue();
      expect(active.isStreaming, isFalse);
      expect(third.closed, isFalse);
      expect(launches, hasLength(3));

      await reopen();
      expect(bots.userMemory(bot, group: scope).entries.single.text, later);
      await send('Resume after withdrawal');
      expect(launches.last.resume, sessionId);
      expectNotes(launches.last.instructions, edited, pruned: true);
    });
  }

  test('external Bot holds a private follow-up until it can resume with pruned memory', () async {
    final launches = <ClaudeLaunch>[];
    final workers = <_ExternalCli>[];
    startCli = (launch) async {
      launches.add(launch);
      final worker = _ExternalCli();
      workers.add(worker);
      return worker;
    };
    const sessionId = '821354b1-8c65-42a1-a205-bbc5254b79f1';
    const retained = 'Original retained note';
    const edited = 'New wording of the retained note';
    const withdrawn = 'Secret note to withdraw';
    const followUp = 'Follow-up question';
    bots.changeUserMemory(mia, [
      for (final text in [retained, withdrawn])
        (action: BotMemoryAction.add, id: null, revision: null, text: text),
    ]);

    final thread = bots.threadFor(mia);
    final session = thread.session;
    bots.sendPrivate(mia, const ComposerMessage(text: 'First question'));
    await pumpEventQueue();
    final first = workers.single;
    final firstUser = first.users.single;
    expect(launches.single.resume, isNull);
    expect(launches.single.instructions, contains(retained));
    expect(launches.single.instructions, contains(withdrawn));
    first.push({'type': 'system', 'subtype': 'init', 'session_id': sessionId});
    await pumpEventQueue();
    expect(thread.id, sessionId);
    expect(session.isStreaming, isTrue);

    (String?, bool) followUpState() => [
      for (var i = 0; i < session.itemCount; i++)
        if (session.itemAt(i) case UserMessageItem(:final text, :final queued)
            when text == followUp)
          (session.itemIdAt(i), queued),
    ].single;

    bots.sendPrivate(mia, const ComposerMessage(text: followUp));
    await pumpEventQueue();
    final (followUpId, queued) = followUpState();
    expect(followUpId, isNotNull);
    expect(queued, isTrue);
    expect(first.users.single, same(firstUser));
    expect(launches, hasLength(1));
    bots.sendPrivate(
      mia,
      const ComposerMessage(text: 'Later phone message'),
      linkRequest: (key: 'phone/safe-queue', fingerprint: 'later-phone'),
    );
    await pumpEventQueue();

    final notes = bots.userMemory(mia).entries;
    bots.changeUserMemory(mia, [
      (
        action: BotMemoryAction.update,
        id: notes.first.id,
        revision: notes.first.revision,
        text: edited,
      ),
      (
        action: BotMemoryAction.remove,
        id: notes.last.id,
        revision: notes.last.revision,
        text: null,
      ),
    ]);
    await pumpEventQueue();
    expect(bots.userMemory(mia).activeEntries.single.text, edited);
    expect(session.isStreaming, isTrue);
    expect(followUpState(), (followUpId, true));
    expect(first.users.single, same(firstUser));
    expect(first.closed, isFalse);
    expect(launches, hasLength(1));

    first.push({'type': 'result', 'subtype': 'success'});
    await pumpEventQueue();
    expect(launches, hasLength(2));
    expect(first.closed, isTrue);
    expect(launches.last.resume, sessionId);
    expect(launches.last.instructions, contains(retained));
    expect(launches.last.instructions, isNot(contains(edited)));
    expect(launches.last.instructions, isNot(contains(withdrawn)));
    expect(first.users.single, same(firstUser));
    final resumedUser = workers.last.users.single;
    expect(resumedUser['uuid'], followUpId);
    expect(resumedUser['session_id'], sessionId);
    expect((resumedUser['message'] as Map)['content'], [
      {'type': 'text', 'text': followUp},
    ]);
    expect(followUpState(), (followUpId, false));
    expect(session.isStreaming, isTrue);

    workers.last.push({'type': 'result', 'subtype': 'success'});
    await pumpEventQueue();
    expect(launches, hasLength(2));
    expect(workers.last.users, hasLength(2));
    expect((workers.last.users.last['message'] as Map)['content'], [
      {'type': 'text', 'text': 'Later phone message'},
    ]);
  });

  test('told of a group with what is new in it, its first line the '
      "group's; what each heard and said, in its timeline", () async {
    final group = groups.save(name: '江湖', members: [mia.id, leo.id]);
    groups.send(group.id, text: '@Mia 晚上吃啥');
    await wait(20);
    final note = told.single.$2;
    expect(note, startsWith('[group ${group.id}] The group chat "江湖".'));
    expect(note, contains('In it: you (Mia), 用户 (the user), Leo.'));
    expect(note, contains('## #1 · 用户 · 2026-11-12 14:00:00 · new\n@Mia 晚上吃啥'));
    expect(note, contains('Use bot_history'));
    expect(note, isNot(contains(groups.chatFile(group.id))));
    expect(
      ChatCodec.botGroupOf(UserMessageItem(text: botEventMessage(note))),
      group.id,
    );
    groups.turnEnded(group.id, mia.id, '<bot_say>火锅！</bot_say>');
    String timeline(Bot bot) =>
        utf8.decode(folders.files['/bots/${bot.id}/timeline/2026-11-12.md']!);
    expect(timeline(mia), contains('- 14:00 [群·江湖 #1] 用户: @Mia 晚上吃啥'));
    expect(timeline(mia), contains('- 14:00 [群·江湖 #2] 我: 火锅！'));
    expect(timeline(leo), contains('- 14:00 [群·江湖 #2] Mia: 火锅！'));
    expect(bots.timeline(leo).count, 2);
  });

  test("what a bot said to a group: after the group's note, till the user "
      'wrote to it', () {
    final items = <ChatItem>[
      UserMessageItem(text: '在吗'),
      AssistantTextItem('<bot_say>在</bot_say>'),
      UserMessageItem(text: botEventMessage('[group g1] new')),
      AssistantTextItem('<bot_say>大家好</bot_say>'),
      // Sent the user in private from the group's turn: theirs.
      const ToolCallItem(
        kind: ToolKind.other,
        target: '',
        tool: 'bot_send',
        input: {'to': 'private', 'text': '私下跟你说'},
      ),
      UserMessageItem(text: '你在群里说啥了'),
      AssistantTextItem('<bot_say>打了个招呼</bot_say>'),
    ];
    expect(ChatCodec.botPlaces(items), [
      null,
      null,
      'g1',
      'g1',
      null,
      null,
      null,
    ]);
    expect(ChatCodec.botSentToUser(items[4]), '私下跟你说');
    // What it says to the group after it, its reply all the same.
    expect(
      BotGroups.replyTo([
        ...items.take(5),
        AssistantTextItem('<bot_say>发过去了</bot_say>'),
      ], 'g1'),
      '<bot_say>大家好</bot_say><bot_say>发过去了</bot_say>',
    );
    // As the phone has it.
    expect(
      ChatCodec.botSentToUser(ChatCodec.decode(ChatCodec.encode(items[4]))!),
      '私下跟你说',
    );
    expect(BotGroups.replyTo(items, 'g1'), '<bot_say>大家好</bot_say>');
    expect(BotGroups.replyTo(items, 'g2'), '');
  });

  test('pictures a bot made in its turn at a group: with its reply there', () {
    final png = Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10, 1, 2]);
    final made = ImageAttachment(bytes: png, mediaType: 'image/png');
    final items = <ChatItem>[
      UserMessageItem(text: botEventMessage('[group g1] new')),
      ToolCallItem(
        kind: ToolKind.image,
        target: '',
        tool: 'generate_image',
        images: [made],
      ),
      // A picture read is not one sent.
      ToolCallItem(kind: ToolKind.read, target: 'a.png', images: [made]),
      ToolCallItem(
        kind: ToolKind.image,
        target: '',
        status: ToolStatus.failed,
        images: [made],
      ),
      AssistantTextItem('<bot_say>就这张</bot_say>'),
    ];
    expect(BotGroups.picturesTo(items, 'g1'), [made]);
    expect(BotGroups.picturesTo(items, 'g2'), isEmpty);

    final group = groups.save(name: 'g', members: [mia.id, leo.id]);
    groups.send(group.id, text: '@Mia 发张图');
    groups.turnEnded(group.id, mia.id, '', images: [made]);
    final sent = groups.messages(group.id).last;
    expect((sent.from, sent.text), (mia.id, ''));
    expect(sent.images, ['2-1.png']);
    expect(groups.image(group.id, '2-1.png')!.bytes, png);
    // Of itself, with a picture.
    final said = groups.say(group.id, leo.id, '看', images: [made]);
    expect(said.images, ['3-1.png']);
  });

  test('a bot says something in a group of itself: there for whoever has '
      'it next, no one woken', () {
    final group = groups.save(name: 'g', members: [mia.id, leo.id]);
    final said = groups.say(group.id, mia.id, '今晚八点开会');
    expect(said.from, mia.id);
    expect(groups.messages(group.id).single.text, '<bot_say>今晚八点开会</bot_say>');
    expect(told, isEmpty);
    expect(() => groups.say(group.id, ann.id, 'x'), throwsStateError);
  });

  test('one gone from a group: what it said there still under its name', () {
    final group = groups.save(name: 'g', members: [mia.id, leo.id]);
    groups.say(group.id, leo.id, '我先走了');
    bots.delete(leo.id);
    groups.send(group.id, text: '再见');
    final chat = utf8.decode(folders.files[groups.chatFile(group.id)]!);
    expect(chat, contains('## #1 · Leo · '));
  });

  test('deleted: its messages and its bots\' conversations of it gone; a '
      'bot deleted leaves its groups', () {
    final group = groups.save(name: 'g', members: [mia.id, leo.id]);
    groups.send(group.id, text: 'hi');
    bots.delete(leo.id);
    expect(groups.byId(group.id)!.members, [mia.id]);
    groups.delete(group.id);
    expect(groups.groups, isEmpty);
    expect(
      folders.files.keys.where(
        (k) => p.isWithin('/bots/groups/${group.id}', k),
      ),
      isEmpty,
    );
  });
}

class _ExternalCli extends FakeCli implements ClaudeExternalTransport {}

class _KeptSessionCatalog implements SessionCatalog {
  _KeptSessionCatalog(this.record);

  final SessionRecord record;

  @override
  Future<List<ProjectRecord>> projects() async => [
    ProjectRecord(path: record.cwd, sessions: [record]),
  ];

  @override
  Future<List<SessionRecord>> sessionsIn(String cwd) async =>
      cwd == record.cwd ? [record] : [];

  @override
  Future<void> delete(String id) async {}
}
