import 'dart:convert';
import 'dart:typed_data';

import 'package:baocode/bots/bot_folders.dart';
import 'package:baocode/bots/bot_memory.dart';
import 'package:baocode/bots/bot_memory_review.dart';
import 'package:baocode/bots/bot_memory_skill.dart';
import 'package:baocode/workspace/preference_store.dart';
import 'package:flutter_test/flutter_test.dart';

const _scope = BotMemoryScope(botId: 'bot');
const _group = BotMemoryScope(botId: 'bot', groupId: 'room');
const _project = '/projects/owned';

BotMemorySkillDraft _draft({int? revision}) => BotMemorySkillDraft(
  name: 'release-preflight',
  trigger: 'Verify release preflight before publishing.',
  steps: ['Check the release manifest.', 'Run the documented preflight.'],
  verification: 'The preflight report completed successfully.',
  expectedRevision: revision,
);

void main() {
  test('rejects untrusted file references and command interpolation', () {
    for (final text in [
      'Use [secrets](../secrets).',
      'Check !`pwd`.',
      'Check @../notes.',
      'Load /usr/local/script.',
    ]) {
      expect(
        () => BotMemorySkillDraft(
          name: 'release',
          trigger: text,
          steps: ['Check release.', 'Run preflight.'],
          verification: 'Success',
        ),
        throwsFormatException,
      );
    }
  });

  test('registry scopes discovery, checks the exact file, and respects lock and archive', () async {
    final host = _SkillHost();
    var skills = host.skills();
    final saved = await skills.apply(
      botId: 'bot',
      project: _project,
      draft: _draft(),
      proposalId: 'p1',
      evidence: [],
    );
    expect(saved.revision, 1);
    final markdown = utf8.decode(host.folders.files.values.single);
    expect(markdown, startsWith('---\nname: release-preflight\n'));
    expect(markdown, isNot(contains('allowed-tools')));
    skills = host.skills();
    expect(
      (await skills.apply(
        botId: 'bot',
        project: _project,
        draft: _draft(),
        proposalId: 'p1',
        evidence: [],
      )).revision,
      1,
    );
    expect(
      await skills.loadForTask(
        botId: 'other',
        project: _project,
        task: 'release preflight',
      ),
      isEmpty,
    );
    expect(
      await skills.loadForTask(
        botId: 'bot',
        project: '/projects/elsewhere',
        task: 'release preflight',
      ),
      isEmpty,
    );
    final candidates = await skills.loadForTask(
      botId: 'bot',
      project: _project,
      task: 'release preflight',
    );
    expect(candidates.single.markdown, markdown);
    expect((await skills.list(botId: 'bot')).single.lastUsedAt, isNull);
    host.now = host.now.add(const Duration(days: 14));
    expect((await skills.list(botId: 'bot')).single.isStale(host.now), isTrue);
    await skills.markUsed(
      botId: 'bot',
      project: _project,
      noteDigests: {botMemoryDigest(botMemorySkillNote(candidates.single))},
    );
    expect((await skills.list(botId: 'bot')).single.lastUsedAt, host.now);
    await skills.maintain(
      botId: 'bot',
      project: _project,
      name: saved.name,
      revision: 1,
      locked: true,
    );
    await expectLater(
      skills.apply(
        botId: 'bot',
        project: _project,
        draft: _draft(revision: 2),
        proposalId: 'p2',
        evidence: [],
      ),
      throwsStateError,
    );
    await expectLater(
      skills.maintain(
        botId: 'bot',
        project: _project,
        name: saved.name,
        revision: 2,
        locked: false,
        archived: true,
      ),
      throwsStateError,
    );
    expect(
      await skills.confirmForDispatch(
        botId: 'bot',
        project: _project,
        candidates: candidates,
      ),
      isEmpty,
    );
    await skills.maintain(
      botId: 'bot',
      project: _project,
      name: saved.name,
      revision: 2,
      locked: false,
      pinned: true,
    );
    host.now = host.now.add(const Duration(days: 31));
    await skills.archiveStale();
    expect((await skills.list(botId: 'bot')).single.archived, isFalse);
    await skills.maintain(
      botId: 'bot',
      project: _project,
      name: saved.name,
      revision: 3,
      pinned: false,
    );
    await skills.archiveStale();
    expect(await skills.list(botId: 'bot'), isEmpty);
    expect(
      (await skills.list(botId: 'bot', includeArchived: true)).single.archived,
      isTrue,
    );
    await skills.maintain(
      botId: 'bot',
      project: _project,
      name: saved.name,
      revision: 5,
      archived: false,
    );
    expect(
      (await skills.loadForTask(
        botId: 'bot',
        project: _project,
        task: 'release preflight',
      )).single.markdown,
      markdown,
    );
    host.folders.files.updateAll(
      (path, bytes) => Uint8List.fromList(utf8.encode('$markdown\nEdit')),
    );
    expect(
      await skills.loadForTask(
        botId: 'bot',
        project: _project,
        task: 'release preflight',
      ),
      isEmpty,
    );
  });

  for (final requiresApproval in [false, true]) {
    test(
      'project skill review ${requiresApproval ? 'requires approval' : 'auto-saves'}',
      () async {
        final host = _SkillHost();
        final skills = host.skills();
        final review = BotMemoryReview(
          store: MemoryPreferenceStore(),
          scopeExists: (scope) => scope == _scope || scope == _group,
          foregroundBusy: () => false,
          readMemory: (_) => BotMemory.fromMarkdown(''),
          readEvidence: (_, _, _) async => null,
          readProjectEvidence: (_, _, _, source) async => switch (source.role) {
            BotMemoryReviewRole.task =>
              'Release manifest checked and preflight succeeded.',
            BotMemoryReviewRole.verification =>
              'Runtime recorded a successful check: npm test',
            _ => 'Verify the release.',
          },
          applyMemory: (
            _,
            changes, {
            required sessionId,
            required messageId,
            required operationId,
            required changeSources,
          }) => fail('Project cannot write ${changes.length} Bot facts'),
          skills: skills,
          ask: (request) async => jsonEncode({
            'proposals': [
              {
                'action': 'skill',
                'skill': _draft().toJson(),
                'evidence': ['e1', 'e2', 'e3'],
              },
              {
                'action': 'skill',
                'skill': {
                  ..._draft().toJson(),
                  'allowed-tools': ['Bash'],
                },
                'evidence': ['e1', 'e2', 'e3'],
              },
            ],
          }),
        );
        await review.configure(_scope, skillApproval: requiresApproval);
        final sources = [
          const BotMemoryReviewEvidence(
            messageId: 'task-request',
            role: BotMemoryReviewRole.user,
          ),
          const BotMemoryReviewEvidence(
            messageId: 'completion',
            role: BotMemoryReviewRole.task,
          ),
          const BotMemoryReviewEvidence(
            messageId: 'verification',
            role: BotMemoryReviewRole.verification,
          ),
        ];
        await expectLater(
          review.recordTurn(
            scope: _group,
            sessionId: 'room',
            turnId: '1',
            evidence: sources,
            project: _project,
          ),
          throwsStateError,
        );
        await review.recordTurn(
          scope: _scope,
          sessionId: 'project-session',
          turnId: '1',
          evidence: sources,
          project: _project,
          toolIterations: 10,
        );
        await review.runNext();
        if (requiresApproval) {
          expect(await skills.list(botId: 'bot'), isEmpty);
          final proposal = (await review.proposals(_scope)).single;
          expect(proposal.after, _draft().markdown);
          await review.decide(
            scope: _scope,
            proposalId: proposal.id,
            approve: true,
            reviewer: 'owner',
          );
        } else {
          await review.runNext();
        }
        final saved = (await skills.list(botId: 'bot')).single;
        expect(saved.name, 'release-preflight');
        expect(saved.evidence, hasLength(3));
        expect(
          (await review.proposals(_scope, pendingOnly: false)),
          hasLength(1),
        );
      },
    );
  }
}

class _SkillHost {
  final store = MemoryPreferenceStore();
  final folders = MemoryBotFolders();
  DateTime now = DateTime.utc(2026, 11, 25);

  BotMemorySkills skills() => BotMemorySkills(
    store: store,
    folders: folders,
    root: '/bots/managed-skills',
    canUseProject: (bot, project) => bot == 'bot' && project == _project,
    clock: () => now,
  );
}
