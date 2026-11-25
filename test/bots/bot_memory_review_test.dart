import 'dart:async';
import 'dart:convert';

import 'package:baocode/bots/bot_folders.dart';
import 'package:baocode/bots/bot_memory.dart';
import 'package:baocode/bots/bot_memory_review.dart';
import 'package:baocode/bots/bot_memory_skill.dart';
import 'package:baocode/workspace/preference_store.dart';
import 'package:flutter_test/flutter_test.dart';

const private = BotMemoryScope(botId: 'bot');
const group = BotMemoryScope(botId: 'bot', groupId: 'room');
const _fakeValue = 'synthetic-credential';
const _credentialEvidence = 'password: $_fakeValue';

void main() {
  test('threshold, restart, foreground priority and turn dedupe', () async {
    final host = _Host();
    var review = host.review();
    for (var turn = 0; turn < 9; turn++) {
      await host.record(review, private, turn);
    }
    await host.record(review, private, 8);
    expect((await review.status(private)).queued, 0);
    await host.record(review, private, 9);
    expect((await review.status(private)).queued, 1);
    host.busy = true;
    review = host.review();
    expect(await review.runNext(), isFalse);
    expect(host.calls, isEmpty);
    host.busy = false;
    expect(await review.runNext(), isTrue);
    expect(host.calls, hasLength(1));
    final status = await review.status(private);
    final request = host.calls.single;
    expect(status.limits['maxOutputTokens'], request.maxOutputTokens);
    expect(status.limits['maxAttempts'], 3);
    expect(status.lastUsage?.requestCount, 1);
    expect(
      status.lastUsage?.inputCharacters,
      request.system.runes.length + request.prompt.runes.length,
    );
    expect(
      status.lastUsage?.outputCharacters,
      jsonEncode({
        'proposals': [host.propose('e1')],
      }).runes.length,
    );
    review = host.review(); // The auto-apply intent was saved before restart.
    expect(await review.runNext(), isTrue);
    expect(await review.runNext(), isFalse);
    expect(
      host.memories[private]!.entries.single.text,
      'Use the preflight command.',
    );
    expect(
      (await review.proposals(private, pendingOnly: false)).single.status,
      BotMemoryReviewProposalStatus.applied,
    );
  });

  test(
    'manual review with automatic paused is scoped and revalidates evidence',
    () async {
      final host = _Host();
      final review = host.review();
      await review.configure(
        group,
        automatic: false,
        memoryApproval: true,
        model: '@upstream/exact',
      );
      await host.record(review, private, 1, message: 'Private source');
      await host.record(review, group, 1, message: 'Room source');
      await review.refine(scope: group, focus: 'preflight');
      expect(await review.runNext(), isTrue);
      expect(host.calls.single.prompt, contains('Room source'));
      expect(host.calls.single.prompt, isNot(contains('Private source')));
      expect(host.calls.single.model, '@upstream/exact');
      expect(host.memories, isEmpty);
      final proposal = (await review.proposals(group)).single;
      expect(proposal.evidence.single['messageId'], '1');
      expect(await review.proposals(private), isEmpty);
      await expectLater(
        review.decide(
          scope: private,
          proposalId: proposal.id,
          approve: true,
          reviewer: 'owner',
        ),
        throwsStateError,
      );
      host.sources[(group, '1')] = 'Edited source';
      final invalid = await review.decide(
        scope: group,
        proposalId: proposal.id,
        approve: true,
        reviewer: 'owner',
      );
      expect(invalid.status, BotMemoryReviewProposalStatus.invalid);
      expect(invalid.after, isNull);
      expect(host.memories, isEmpty);
    },
  );

  test(
    'edits require approval, respect revisions, and decisions replay',
    () async {
      final host = _Host();
      host.memories[private] = BotMemory.fromMarkdown('- Old command');
      host.propose = (ref) => {
        'action': 'update',
        'id': 1,
        'revision': 1,
        'text': 'New command',
        'evidence': [ref],
      };
      final review = host.review();
      await host.record(review, private, 0, toolIterations: 10);
      await review.runNext();
      final proposal = (await review.proposals(private)).single;
      expect(proposal.before, 'Old command');
      expect(proposal.after, 'New command');
      expect(proposal.toJson(), isNot(contains('changes')));
      host.memories[private] = host.memories[private]!.apply([
        (action: BotMemoryAction.update, id: 1, revision: 1, text: 'User edit'),
      ]);
      final result = await review.decide(
        scope: private,
        proposalId: proposal.id,
        approve: true,
        reviewer: 'owner',
      );
      expect(result.status, BotMemoryReviewProposalStatus.conflict);
      final repeated = await review.decide(
        scope: private,
        proposalId: proposal.id,
        approve: false,
        reviewer: 'other',
      );
      expect(repeated.status, result.status);
      expect(repeated.reviewer, 'owner');
      expect(host.memories[private]!.entries.single.text, 'User edit');
    },
  );

  test(
    'a full memory can approve an add before a remove in one batch',
    () async {
      final host = _Host()..proposeRows = _replacement;
      final review = host.review();
      final old = List.filled(850, 'a').join();
      final kept = List.filled(botUserMemoryLimit - 855, 'b').join();
      final full = BotMemory.fromMarkdown('- $old\n- $kept');
      expect(full.markdown.length, botUserMemoryLimit);
      host.memories[private] = full;
      await host.record(review, private, 0);
      await host.record(review, private, 1, toolIterations: 10);
      // Give each change a different source so the batch must retain both.
      host.proposeRows = (ref) => [
        _replacement(ref).first,
        {
          ..._replacement(ref).last,
          'evidence': ['e2'],
        },
      ];
      expect(await review.runNext(), isTrue);
      expect(jsonDecode(host.calls.single.prompt)['memoryBudget'], {
        'usedCharacters': botUserMemoryLimit,
        'maxCharacters': botUserMemoryLimit,
      });
      final proposal = (await review.proposals(private)).single;
      expect(proposal.action, BotMemoryReviewAction.batch);
      expect(await review.runNext(), isFalse);
      expect(host.memories[private], same(full));
      expect(host.applications, isEmpty);
      final evidence1 = {
        'messageId': '1',
        'role': 'user',
        'sessionId': 'session',
      };
      final evidence0 = {
        'messageId': '0',
        'role': 'user',
        'sessionId': 'session',
      };
      final wire = proposal.toJson();
      expect(wire['evidence'], [evidence1, evidence0]);
      expect(wire['changes'], [
        {
          'action': 'add',
          'before': null,
          'after': 'Replacement fact',
          'evidence': [evidence1],
        },
        {
          'action': 'remove',
          'before': old,
          'after': null,
          'evidence': [evidence0],
        },
      ]);
      await expectLater(
        review.decide(
          scope: private,
          proposalId: proposal.id,
          approve: true,
          reviewer: 'owner',
          allowBatch: false,
        ),
        throwsStateError,
      );
      expect(host.applications, isEmpty);
      final decision = await review.decide(
        scope: private,
        proposalId: proposal.id,
        approve: true,
        reviewer: 'owner',
      );
      expect(decision.status, BotMemoryReviewProposalStatus.applied);
      expect(host.applications.single.$1, proposal.id);
      expect(host.applications.single.$2, hasLength(2));
      expect(host.memories[private]!.entries.map((entry) => entry.text), [
        kept,
        'Replacement fact',
      ]);
    },
  );

  test(
    'a staged batch writes nothing if one memory revision changed',
    () async {
      final host = _Host()..proposeRows = _replacement;
      host.memories[private] = BotMemory.fromMarkdown('- Old fact');
      final review = host.review();
      await host.record(review, private, 0, toolIterations: 10);
      await review.runNext();
      final proposal = (await review.proposals(private)).single;
      final edited = host.memories[private]!.apply([
        (action: BotMemoryAction.update, id: 1, revision: 1, text: 'User edit'),
      ]);
      host.memories[private] = edited;
      final decision = await review.decide(
        scope: private,
        proposalId: proposal.id,
        approve: true,
        reviewer: 'owner',
      );
      expect(decision.status, BotMemoryReviewProposalStatus.conflict);
      expect(host.applications.single.$2, hasLength(2));
      expect(host.memories[private], same(edited));
      expect(edited.hasOperation(proposal.id), isFalse);
    },
  );

  test('an oversized replacement is rejected before approval', () async {
    final host = _Host()..proposeRows = _replacement;
    final kept = List.filled(
      botUserMemoryLimit - '- Old fact\n- '.length,
      'a',
    ).join();
    final memory = BotMemory.fromMarkdown('- Old fact\n- $kept');
    host.memories[private] = memory;
    final review = host.review();
    await host.record(review, private, 0, toolIterations: 10);
    expect(await review.runNext(), isTrue);
    expect(await review.proposals(private, pendingOnly: false), isEmpty);
    final status = await review.status(private);
    expect(status.error, contains('Free 8 characters'));
    expect(status.queued, 0);
    expect(host.applications, isEmpty);
    expect(host.memories[private], same(memory));
  });

  test('a review cannot stage a batch that clears all memory', () async {
    final host = _Host()
      ..proposeRows = (ref) => [
        for (final id in [1, 2])
          {
            'action': 'remove',
            'id': id,
            'revision': 1,
            'evidence': [ref],
          },
      ];
    final memory = BotMemory.fromMarkdown('- First fact\n- Second fact');
    host.memories[private] = memory;
    final review = host.review();
    await host.record(review, private, 0, toolIterations: 10);
    expect(await review.runNext(), isTrue);
    expect(await review.proposals(private, pendingOnly: false), isEmpty);
    expect((await review.status(private)).error, contains('empty'));
    expect(host.applications, isEmpty);
    expect(host.memories[private], same(memory));
  });

  test(
    'changed evidence for one row invalidates and scrubs the whole batch',
    () async {
      final host = _Host()
        ..proposeRows = (ref) => [
          _replacement(ref).first,
          {
            ..._replacement(ref).last,
            'evidence': ['e2'],
          },
        ];
      host.memories[private] = BotMemory.fromMarkdown('- Old fact');
      final review = host.review();
      await host.record(review, private, 0);
      await host.record(review, private, 1, toolIterations: 10);
      await review.runNext();
      final proposal = (await review.proposals(private)).single;
      host.sources.remove((private, '0'));
      final decision = await review.decide(
        scope: private,
        proposalId: proposal.id,
        approve: true,
        reviewer: 'owner',
      );
      expect(decision.status, BotMemoryReviewProposalStatus.invalid);
      expect(decision.toJson()['changes'], isEmpty);
      expect(decision.evidence, isEmpty);
      expect(host.applications, isEmpty);
      expect(
        jsonEncode(host.store.preferences),
        isNot(contains('Replacement fact')),
      );
    },
  );

  test(
    'an invalid model row blocks a valid add from the same review',
    () async {
      final invalidRows = <Object?>[
        null,
        {
          'action': 'remove',
          'id': 42,
          'revision': 1,
          'evidence': ['e1'],
        },
        {
          'action': 'remove',
          'id': 1,
          'revision': '1',
          'evidence': ['e1'],
        },
        {
          'action': 'remove',
          'id': 1,
          'revision': 1,
          'evidence': ['e9'],
        },
        {
          'action': 'remove',
          'id': 1,
          'revision': 1,
          'text': 'Unexpected field',
          'evidence': ['e1'],
        },
      ];
      for (final invalid in invalidRows) {
        final host = _Host()
          ..proposeRows = (ref) => [_replacement(ref).first, invalid];
        host.memories[private] = BotMemory.fromMarkdown('- Old fact');
        final review = host.review();
        await host.record(review, private, 0, toolIterations: 10);
        await review.runNext();
        expect(
          await review.proposals(private, pendingOnly: false),
          isEmpty,
          reason: '$invalid',
        );
        expect(await review.runNext(), isFalse);
        expect(host.applications, isEmpty);
      }
    },
  );

  for (final approval in [false, true]) {
    test('add-only review batch respects approval=$approval', () async {
      final host = _Host()
        ..proposeRows = (ref) => [
          {
            'action': 'add',
            'text': 'First fact',
            'evidence': ['e2'],
          },
          {
            'action': 'add',
            'text': 'Second fact',
            'evidence': [ref],
          },
        ];
      final review = host.review();
      await review.configure(private, memoryApproval: approval);
      await host.record(review, private, 0);
      await host.record(review, private, 1, toolIterations: 10);
      await review.runNext();
      final proposal = (await review.proposals(
        private,
        pendingOnly: false,
      )).single;
      expect(
        proposal.status,
        approval
            ? BotMemoryReviewProposalStatus.pending
            : BotMemoryReviewProposalStatus.applying,
      );
      if (approval) {
        expect(await review.runNext(), isFalse);
        expect(host.applications, isEmpty);
        await review.decide(
          scope: private,
          proposalId: proposal.id,
          approve: true,
          reviewer: 'owner',
        );
      } else {
        expect(await review.runNext(), isTrue);
      }
      expect(host.applications.single.$2, hasLength(2));
      expect(
        host.memories[private]!.entries.map((entry) => entry.sourceMessage),
        ['0', '1'],
      );
    });
  }

  test(
    'restart replays the whole batch after memory was already written',
    () async {
      final host = _Host()..proposeRows = _replacement;
      host.memories[private] = BotMemory.fromMarkdown('- Old fact');
      final review = host.review();
      await host.record(review, private, 0, toolIterations: 10);
      await review.runNext();
      final proposal = (await review.proposals(private)).single;
      host.failAfterApply = true;
      await expectLater(
        review.decide(
          scope: private,
          proposalId: proposal.id,
          approve: true,
          reviewer: 'owner',
        ),
        throwsStateError,
      );
      expect(
        (await review.proposals(private, pendingOnly: false)).single.status,
        BotMemoryReviewProposalStatus.applying,
      );
      final committed = host.memories[private]!.toJson();
      expect(host.memories[private]!.entries.single.text, 'Replacement fact');
      expect(host.memories[private]!.hasOperation(proposal.id), isTrue);
      host.memories[private] = BotMemory.fromJson(committed);
      final restarted = host.review();
      expect(await restarted.runNext(), isTrue);
      expect(await restarted.runNext(), isFalse);
      expect(host.calls, hasLength(1));
      expect(host.applications.map((event) => event.$1), [
        proposal.id,
        proposal.id,
      ]);
      expect(host.applications.last.$2, host.applications.first.$2);
      expect(host.memories[private]!.toJson(), committed);
      expect(
        (await restarted.proposals(private, pendingOnly: false)).single.status,
        BotMemoryReviewProposalStatus.applied,
      );
    },
  );

  test('withdrawal discards an in-flight add even if it paraphrases', () async {
    final host = _Host();
    host.memories[private] = BotMemory.fromMarkdown('- Run a preflight check');
    final review = host.review();
    final asked = Completer<void>();
    final answer = Completer<String>();
    host.respond = (_) {
      asked.complete();
      return answer.future;
    };
    await host.record(review, private, 1, toolIterations: 10);
    final running = review.runNext();
    await asked.future;
    host.withdraw(private, 1);
    answer.complete(
      jsonEncode({
        'proposals': [host.propose('e1')],
      }),
    );
    expect(await running, isTrue);

    final restarted = host.review();
    expect(await restarted.runNext(), isFalse);
    expect(await restarted.proposals(private, pendingOnly: false), isEmpty);
    expect(host.memories[private]!.entries, isEmpty);
    expect(host.applications, isEmpty);
  });

  test(
    'a job queued before withdrawal does not call the model on restart',
    () async {
      final host = _Host();
      host.memories[private] = BotMemory.fromMarkdown(
        '- Run a preflight check',
      );
      final review = host.review();
      await host.record(review, private, 1, toolIterations: 10);
      expect((await review.status(private)).queued, 1);
      host.withdraw(private, 1);

      final restarted = host.review();
      expect(await restarted.runNext(), isTrue);
      expect(await restarted.runNext(), isFalse);
      expect(host.calls, isEmpty);
      expect((await restarted.status(private)).queued, 0);
    },
  );

  test(
    'old, undated, and cutoff-time user evidence require approval',
    () async {
      final host = _Host();
      host.memories[private] = BotMemory.fromMarkdown(
        '- Run a preflight check',
      );
      final cutoff = host.now;
      host.withdraw(private, 1);
      host.now = cutoff.add(const Duration(minutes: 1));
      final review = host.review();
      await host.record(review, private, 0, occurredAt: cutoff);
      await host.record(review, private, 1);
      await host.record(
        review,
        private,
        2,
        occurredAt: cutoff.subtract(const Duration(minutes: 1)),
      );
      host.proposeRows = (ref) => [
        host.propose(ref),
        {
          'action': 'add',
          'text': 'Another wording',
          'evidence': ['e2'],
        },
        {
          'action': 'add',
          'text': 'A third wording',
          'evidence': ['e3'],
        },
      ];
      await review.refine(scope: private);
      expect(await review.runNext(), isTrue);
      final proposal = (await review.proposals(private)).single;
      expect(proposal.action, BotMemoryReviewAction.batch);
      expect(proposal.status, BotMemoryReviewProposalStatus.pending);
      expect(await review.runNext(), isFalse);
      expect(host.memories[private]!.entries, isEmpty);
      expect(host.applications, isEmpty);
    },
  );

  test(
    'fresh user evidence can auto-save without seeing old material',
    () async {
      final host = _Host();
      host.memories[private] = BotMemory.fromMarkdown(
        '- Run a preflight check',
      );
      final review = host.review();
      await host.record(
        review,
        private,
        0,
        message: 'Historical material',
        occurredAt: host.now.subtract(const Duration(minutes: 1)),
      );
      host.withdraw(private, 1);
      host.now = host.now.add(const Duration(minutes: 1));
      host.propose = (ref) => {
        'action': 'add',
        'text': 'Name builds after constellations.',
        'evidence': [ref],
      };
      await host.record(
        review,
        private,
        1,
        message: 'Name builds after constellations.',
        occurredAt: host.now,
        toolIterations: 10,
      );
      expect(await review.runNext(), isTrue);
      expect(host.calls.single.prompt, isNot(contains('Historical material')));
      expect(await host.review().runNext(), isTrue);
      expect(
        host.memories[private]!.entries.single.text,
        'Name builds after constellations.',
      );
    },
  );

  test('withdrawn source IDs are excluded only within their scope', () async {
    final host = _Host();
    host.memories[private] = BotMemory.fromMarkdown('').apply(
      [
        (
          action: BotMemoryAction.add,
          id: null,
          revision: null,
          text: 'Run a preflight check',
        ),
      ],
      session: 'session',
      sourceMessage: '0',
    );
    host.withdraw(private, 1);
    host.now = host.now.add(const Duration(minutes: 1));
    final review = host.review();
    await host.record(
      review,
      private,
      0,
      occurredAt: host.now,
      toolIterations: 10,
    );
    expect(await review.runNext(), isTrue);
    expect(await review.proposals(private, pendingOnly: false), isEmpty);
    expect(host.calls, isEmpty);

    await host.record(
      review,
      group,
      0,
      occurredAt: host.now,
      toolIterations: 10,
    );
    expect(await review.runNext(), isTrue);
    expect(await review.runNext(), isTrue);
    expect(host.calls.single.scope, group);
    expect(host.memories[group]!.entries, hasLength(1));
    expect(host.memories[private]!.entries, isEmpty);
  });

  test(
    'withdrawal scrubs an affected batch during display and decision',
    () async {
      final host = _Host()..proposeRows = _replacement;
      host.memories[private] = BotMemory.fromMarkdown('- Old fact');
      final review = host.review();
      await host.record(review, private, 0, toolIterations: 10);
      await review.runNext();
      final original = (await review.proposals(private)).single;
      expect(original.toJson()['changes'], hasLength(2));
      host.withdraw(private, 1);

      final restarted = host.review();
      expect((await restarted.status(private)).pending, 0);
      expect(await restarted.proposals(private), isEmpty);
      final decision = await restarted.decide(
        scope: private,
        proposalId: original.id,
        approve: true,
        reviewer: 'owner',
      );
      expect(decision.status, BotMemoryReviewProposalStatus.invalid);
      expect(decision.evidence, isEmpty);
      expect(decision.toJson()['changes'], isEmpty);
      final persisted = jsonEncode(host.store.preferences);
      expect(persisted, isNot(contains('Replacement fact')));
      expect(persisted, isNot(contains('Old fact')));
      expect(host.applications, isEmpty);
    },
  );

  test('approval rechecks withdrawal after async evidence lookup', () async {
    final host = _Host()..proposeRows = _replacement;
    host.memories[private] = BotMemory.fromMarkdown('- Old fact');
    final review = host.review();
    await host.record(review, private, 0, toolIterations: 10);
    await review.runNext();
    final proposal = (await review.proposals(private)).single;
    host.onReadEvidence = () {
      host.onReadEvidence = null;
      host.withdraw(private, 1);
    };
    final decision = await review.decide(
      scope: private,
      proposalId: proposal.id,
      approve: true,
      reviewer: 'owner',
    );
    expect(decision.status, BotMemoryReviewProposalStatus.invalid);
    expect(decision.toJson()['changes'], isEmpty);
    expect(host.memories[private]!.entries, isEmpty);
    expect(host.applications, isEmpty);
  });

  test(
    'withdrawal blocks restart replay of an uncommitted automatic add',
    () async {
      final host = _Host();
      host.memories[private] = BotMemory.fromMarkdown(
        '- Run a preflight check',
      );
      final review = host.review();
      await host.record(review, private, 0, toolIterations: 10);
      await review.runNext();
      expect(
        (await review.proposals(private, pendingOnly: false)).single.status,
        BotMemoryReviewProposalStatus.applying,
      );
      host.withdraw(private, 1);

      final restarted = host.review();
      expect(await restarted.runNext(), isTrue);
      final invalid = (await restarted.proposals(
        private,
        pendingOnly: false,
      )).single;
      expect(invalid.status, BotMemoryReviewProposalStatus.invalid);
      expect(invalid.after, isNull);
      expect(host.applications, isEmpty);
      expect(host.memories[private]!.entries, isEmpty);
    },
  );

  test(
    'committed batch replay preserves its receipt after withdrawal',
    () async {
      final host = _Host()..proposeRows = _replacement;
      host.memories[private] = BotMemory.fromMarkdown('- Old fact');
      final review = host.review();
      await host.record(review, private, 0, toolIterations: 10);
      await review.runNext();
      final proposal = (await review.proposals(private)).single;
      host.failAfterApply = true;
      await expectLater(
        review.decide(
          scope: private,
          proposalId: proposal.id,
          approve: true,
          reviewer: 'owner',
        ),
        throwsStateError,
      );
      final entry = host.memories[private]!.entries.single;
      host.withdraw(private, entry.id);
      final durable = host.memories[private]!.toJson();
      host.memories[private] = BotMemory.fromJson(durable);
      host.sources.clear();

      final restarted = host.review();
      expect(await restarted.runNext(), isTrue);
      final receipt = (await restarted.proposals(
        private,
        pendingOnly: false,
      )).single;
      expect(receipt.id, proposal.id);
      expect(receipt.status, BotMemoryReviewProposalStatus.applied);
      expect(receipt.reviewer, 'owner');
      expect(receipt.toJson()['changes'], isEmpty);
      expect(receipt.evidence, isEmpty);
      expect(host.applications, hasLength(1));
      expect(host.memories[private]!.toJson(), durable);
    },
  );

  test(
    'an exact duplicate preserves one fact and joins independent evidence',
    () async {
      final host = _Host();
      final review = host.review();
      await host.record(review, private, 0, toolIterations: 10);
      expect(await review.runNext(), isTrue);
      expect(await review.runNext(), isTrue);
      final original = host.memories[private];
      host.propose = (ref) => {
        'action': 'add',
        'text': 'USE  THE preflight command.',
        'evidence': [ref],
      };
      await host.record(review, private, 1, toolIterations: 10);
      expect(await review.runNext(), isTrue);
      await review.refine(scope: private);
      expect(await review.runNext(), isTrue);
      expect(await review.runNext(), isFalse);
      expect(host.memories[private], same(original));
      expect(host.applications, hasLength(1));
      final proposal = (await review.proposals(
        private,
        pendingOnly: false,
      )).single;
      expect(proposal.evidence.map((evidence) => evidence['messageId']), [
        '0',
        '1',
      ]);
    },
  );

  test('typed evidence writes only to the authorized project memory', () async {
    const project = 'owned-project';
    const text = 'Use the signed release manifest.';
    final store = MemoryPreferenceStore();
    var projectMemory = BotMemory.fromMarkdown('', capacity: 2200);
    var canUseProject = true;
    final applications = <String>[];
    final skills = BotMemorySkills(
      store: MemoryPreferenceStore(),
      folders: MemoryBotFolders(),
      root: '/bots/managed-skills',
      canUseProject: (bot, id) =>
          canUseProject && bot == private.botId && id == project,
    );
    var answerText = text;
    BotMemoryReview review() => BotMemoryReview(
      store: store,
      scopeExists: (scope) => scope == private,
      foregroundBusy: () => false,
      readMemory: (_) => fail('Project review read private memory'),
      readEvidence: (_, _, _) async =>
          fail('Project review read private evidence'),
      readProjectEvidence: (scope, id, session, source) async {
        expect((scope, id), (private, project));
        return source.role == BotMemoryReviewRole.userFact
            ? text
            : 'Delegated task';
      },
      readProjectMemory: (scope, id) {
        expect((scope, id), (private, project));
        return projectMemory;
      },
      applyMemory: (
        _,
        _, {
        required sessionId,
        required messageId,
        required operationId,
        required changeSources,
      }) => fail('Project review wrote private memory'),
      applyProjectMemory:
          (scope, id, changes, {required operationId, required changeSources}) {
            expect((scope, id), (private, project));
            expect(changeSources, [(sessionId: 'typed', messageId: '1')]);
            projectMemory = projectMemory.apply(
              changes,
              operationId: operationId,
              changeSources: changeSources,
            );
            applications.add(operationId);
          },
      skills: skills,
      ask: (request) async {
        final input = jsonDecode(request.prompt) as Map<String, Object?>;
        if (request.sessionId == 'typed') {
          expect(input['memoryScope'], 'project');
          expect(input['memoryBudget'], {
            'usedCharacters': projectMemory.markdown.runes.length,
            'maxCharacters': 2200,
          });
        } else {
          expect(input['memoryScope'], isNull);
        }
        return jsonEncode({
          'proposals': [
            {
              'action': 'add',
              'text': answerText,
              'evidence': ['e1'],
            },
          ],
        });
      },
    );
    final first = review();
    Future<void> record(String session, BotMemoryReviewRole role) =>
        first.recordTurn(
          scope: private,
          sessionId: session,
          turnId: '1',
          project: project,
          toolIterations: 10,
          evidence: [BotMemoryReviewEvidence(messageId: '1', role: role)],
        );
    await record('delegated', BotMemoryReviewRole.user);
    expect(await first.runNext(), isTrue);
    expect(await first.proposals(private, pendingOnly: false), isEmpty);
    await record('typed', BotMemoryReviewRole.userFact);
    expect(await first.runNext(), isTrue);
    final staged = (await first.proposals(private, pendingOnly: false)).single;
    expect(staged.toJson()['project'], project);
    expect(staged.status, BotMemoryReviewProposalStatus.applying);
    expect(await review().runNext(), isTrue);
    expect(projectMemory.entries.single.text, text);
    expect(applications, [staged.id]);
    await expectLater(first.refine(scope: private), throwsStateError);

    // Revocation invalidates a new pending copy before it can disclose or write.
    await first.configure(private, memoryApproval: true);
    answerText = 'Also record the manifest version.';
    await first.refine(scope: private, sessionId: 'typed', project: project);
    expect(await first.runNext(), isTrue);
    final pending = (await first.proposals(private)).single;
    canUseProject = false;
    final decision = await first.decide(
      scope: private,
      proposalId: pending.id,
      approve: true,
      reviewer: 'owner',
    );
    expect(decision.status, BotMemoryReviewProposalStatus.invalid);
    expect(decision.after, isNull);
    expect(decision.evidence, isEmpty);
    expect(applications, [staged.id]);
  });

  test(
    'an assistant completion claim cannot authorize a project skill',
    () async {
      const project = 'owned-project';
      final skills = BotMemorySkills(
        store: MemoryPreferenceStore(),
        folders: MemoryBotFolders(),
        root: '/bots/managed-skills',
        canUseProject: (bot, id) => bot == private.botId && id == project,
      );
      final review = BotMemoryReview(
        store: MemoryPreferenceStore(),
        scopeExists: (scope) => scope == private,
        foregroundBusy: () => false,
        readMemory: (_) => BotMemory.fromMarkdown(''),
        readEvidence: (_, _, _) async => null,
        readProjectEvidence: (scope, id, session, source) async {
          expect((scope, id, session), (private, project, 'task-session'));
          return switch (source.role) {
            BotMemoryReviewRole.user => 'Verify release preflight.',
            BotMemoryReviewRole.task => 'I verified that preflight passed.',
            _ => null,
          };
        },
        applyMemory: (
          _,
          _, {
          required sessionId,
          required messageId,
          required operationId,
          required changeSources,
        }) => fail('Unexpected memory write'),
        skills: skills,
        ask: (_) async => jsonEncode({
          'proposals': [
            {
              'action': 'skill',
              'skill': {
                'name': 'release-preflight',
                'trigger': 'Before publishing a release.',
                'steps': ['Check the release manifest.', 'Run preflight.'],
                'verification': 'The preflight report was successful.',
              },
              'evidence': ['e1', 'e2'],
            },
          ],
        }),
      );
      await review.recordTurn(
        scope: private,
        sessionId: 'task-session',
        turnId: 'turn',
        project: project,
        toolIterations: 10,
        evidence: const [
          BotMemoryReviewEvidence(
            messageId: 'request',
            role: BotMemoryReviewRole.user,
          ),
          BotMemoryReviewEvidence(
            messageId: 'claim',
            role: BotMemoryReviewRole.task,
          ),
        ],
      );
      expect(await review.runNext(), isTrue);
      expect(await review.proposals(private, pendingOnly: false), isEmpty);
      expect(await review.runNext(), isFalse);
      expect(await skills.list(botId: private.botId), isEmpty);
    },
  );

  test(
    'model failures have bounded retries and avoid credential persistence',
    () async {
      final host = _Host();
      final review = host.review();
      final initial = host.now;
      host.fail = true;
      await host.record(review, private, 0, toolIterations: 10);
      await review.runNext();
      expect(await review.runNext(), isFalse);
      host.now = initial.add(const Duration(seconds: 10));
      await host.review().runNext();
      host.now = initial.add(const Duration(seconds: 30));
      await host.review().runNext();
      expect(host.calls, hasLength(3));
      expect((await review.status(private)).queued, 0);
      expect(
        jsonEncode(host.store.preferences),
        isNot(contains('synthetic-credential')),
      );
      host.fail = false;
      await host.record(review, private, 1, message: _credentialEvidence);
      await review.refine(scope: private);
      await review.runNext();
      expect(host.calls.last.prompt, isNot(contains('synthetic-credential')));
      await review.invalidate(scope: private, sessionId: 'session');
      expect(await review.proposals(private, pendingOnly: false), isEmpty);
    },
  );
}

List<Map<String, Object?>> _replacement(String ref) => [
  {
    'action': 'add',
    'text': 'Replacement fact',
    'evidence': [ref],
  },
  {
    'action': 'remove',
    'id': 1,
    'revision': 1,
    'evidence': [ref],
  },
];

class _ReviewStore extends MemoryPreferenceStore {
  bool failNextWrite = false;

  @override
  Future<void> write(Map<String, Object?> preferences) async {
    if (failNextWrite) {
      failNextWrite = false;
      throw StateError('Interrupted while saving the journal decision');
    }
    await super.write(preferences);
  }
}

class _Host {
  final store = _ReviewStore();
  final memories = <BotMemoryScope, BotMemory>{};
  final sources = <(BotMemoryScope, String), String>{};
  final calls = <BotMemoryReviewRequest>[];
  final applications = <(String, List<BotMemoryChange>)>[];
  DateTime now = DateTime.utc(2026, 11, 25);
  bool busy = false;
  bool fail = false;
  bool failAfterApply = false;
  List<Object?> Function(String ref)? proposeRows;
  Future<String> Function(BotMemoryReviewRequest request)? respond;
  void Function()? onReadEvidence;

  Map<String, Object?> Function(String ref) propose = (ref) => {
    'action': 'add',
    'text': 'Use the preflight command.',
    'evidence': [ref],
  };

  BotMemoryReview review() => BotMemoryReview(
    store: store,
    scopeExists: (scope) => scope == private || scope == group,
    foregroundBusy: () => busy,
    clock: () => now,
    readEvidence: (scope, session, evidence) async {
      onReadEvidence?.call();
      return sources[(scope, evidence.messageId)];
    },
    readMemory: (scope) => memories[scope] ?? BotMemory.fromMarkdown(''),
    applyMemory:
        (
          scope,
          changes, {
          required sessionId,
          required messageId,
          required operationId,
          required changeSources,
        }) {
          applications.add((operationId, changes));
          memories[scope] = (memories[scope] ?? BotMemory.fromMarkdown(''))
              .apply(
                changes,
                session: sessionId,
                sourceMessage: messageId,
                operationId: operationId,
                changeSources: changeSources,
              );
          if (failAfterApply) {
            failAfterApply = false;
            store.failNextWrite = true;
          }
        },
    ask: (request) async {
      calls.add(request);
      if (fail) throw StateError(_credentialEvidence);
      if (respond case final responder?) return responder(request);
      final prompt = jsonDecode(request.prompt) as Map<String, Object?>;
      final rows = (prompt['conversation'] as List)
          .cast<Map<String, Object?>>();
      final ref =
          rows.lastWhere((row) => row['role'] == 'user')['ref'] as String;
      return jsonEncode({
        'proposals': proposeRows?.call(ref) ?? [propose(ref)],
      });
    },
  );

  void withdraw(BotMemoryScope scope, int id) {
    final memory = memories[scope]!;
    final entry = memory.entries.firstWhere((entry) => entry.id == id);
    memories[scope] = memory.apply([
      (
        action: BotMemoryAction.remove,
        id: id,
        revision: entry.revision,
        text: null,
      ),
    ], at: now);
  }

  Future<void> record(
    BotMemoryReview review,
    BotMemoryScope scope,
    int turn, {
    int toolIterations = 0,
    String? message,
    DateTime? occurredAt,
  }) {
    sources[(scope, '$turn')] = message ?? 'Please use the preflight command.';
    return review.recordTurn(
      scope: scope,
      sessionId: 'session',
      turnId: '$turn',
      toolIterations: toolIterations,
      evidence: [
        BotMemoryReviewEvidence(
          messageId: '$turn',
          role: BotMemoryReviewRole.user,
          occurredAt: occurredAt,
        ),
      ],
    );
  }
}
