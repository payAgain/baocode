import 'dart:async';
import 'dart:convert';

import 'package:bao_link/bao_link.dart';
import 'package:baocode/bots/bot.dart';
import 'package:baocode/bots/bot_folders.dart';
import 'package:baocode/bots/bot_memory.dart';
import 'package:baocode/bots/bot_memory_review.dart';
import 'package:baocode/bots/bot_memory_skill.dart';
import 'package:baocode/bots/bots.dart';
import 'package:baocode/link/bot_memory_management.dart';
import 'package:baocode/workspace/preference_store.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('revoked project skill proposals cannot be listed or decided', () async {
    final host = await _Host.start();
    final paired = host.management(localOwner: false);
    final local = host.management(localOwner: true);
    final before = await host.call(paired, LinkMethods.botMemoryReview);
    expect(before['pending'], 2);
    expect(_proposals(before).map((proposal) => proposal['action']), [
      'skill',
      'add',
    ]);
    final proposalId = _proposals(before).first['id'];
    final evidenceReads = host.projectEvidenceReads;

    host.revokeProjects();
    for (final management in [paired, local]) {
      final after = await host.call(management, LinkMethods.botMemoryReview, {
        'pendingOnly': false,
      });
      expect(after['pending'], 1);
      expect(_proposals(after).single['action'], 'add');
      for (final approve in [true, false]) {
        await expectLater(
          host.call(management, LinkMethods.decideBotMemory, {
            'proposal': proposalId,
            'approve': approve,
          }),
          throwsA(
            isA<LinkRemoteException>().having(
              (error) => error.message,
              'message',
              'Review proposal is unavailable',
            ),
          ),
        );
      }
    }
    expect((await host.review.status(host.scope)).pending, 1);
    expect(host.projectEvidenceReads, evidenceReads);
    expect(await host.review.skills!.list(botId: host.bot.id), isEmpty);

    host.enableProjects();
    final restored = await host.call(local, LinkMethods.botMemoryReview);
    final skill = _proposals(restored).first;
    expect(skill['id'], proposalId);
    expect(skill['status'], 'pending');
    expect(skill['reviewer'], isNull);
  });

  test(
    'approval cannot apply or return a skill revoked during evidence lookup',
    () async {
      final host = await _Host.start();
      final local = host.management(localOwner: true);
      final proposal = _proposals(
        await host.call(local, LinkMethods.botMemoryReview),
      ).first;
      final reading = Completer<void>();
      final resume = Completer<void>();
      host.beforeProjectEvidence = () async {
        if (!reading.isCompleted) reading.complete();
        await resume.future;
      };
      final pending = host.call(local, LinkMethods.decideBotMemory, {
        'proposal': proposal['id'],
        'approve': true,
      });
      await reading.future;
      host.revokeProjects();
      resume.complete();
      await expectLater(pending, throwsA(isA<LinkRemoteException>()));

      host.enableProjects();
      expect(await host.review.skills!.list(botId: host.bot.id), isEmpty);
      final history = _proposals(
        await host.call(local, LinkMethods.botMemoryReview, {
          'pendingOnly': false,
        }),
      ).first;
      expect(history['status'], 'invalid');
      expect(history['after'], isNull);
      expect(history['evidence'], isEmpty);
    },
  );

  test('only the local owner receives a project-scoped source token', () async {
    final host = await _Host.start();
    final paired = host.management(localOwner: false);
    final local = host.management(localOwner: true);
    final remoteProposal = _proposals(
      await host.call(paired, LinkMethods.botMemoryReview),
    ).first;
    expect(
      _evidence(remoteProposal).every((row) => row['source'] == null),
      isTrue,
    );

    final localProposal = _proposals(
      await host.call(local, LinkMethods.botMemoryReview),
    ).first;
    final sources = _evidence(localProposal)
        .where((row) => row['source'] != null)
        .toList();
    final row = sources.single;
    expect(row['role'], 'user');
    final source = row['source'] as Map<String, Object?>;
    expect(source['historyProject'], host.project);
    expect(source['scope'], {
      'kind': 'project',
      'botId': host.bot.id,
      'projectId': '/release',
    });
    expect(jsonEncode(localProposal), isNot(contains('task/request')));

    final unavailable = throwsA(
      isA<LinkRemoteException>().having(
        (error) => error.code,
        'code',
        LinkErrors.notFound,
      ),
    );
    await expectLater(
      host.call(local, LinkMethods.botMemorySource, {'source': source}),
      unavailable,
    );
    await expectLater(
      host.call(local, LinkMethods.botMemorySource, {
        'source': source,
        'historyProject': host.otherProject,
      }),
      unavailable,
    );
    await expectLater(
      host.call(paired, LinkMethods.botMemorySource, {
        'source': source,
        'historyProject': host.project,
      }),
      unavailable,
    );
    host.revokeProjects();
    await expectLater(
      host.call(local, LinkMethods.botMemorySource, {
        'source': source,
        'historyProject': host.project,
      }),
      unavailable,
    );
  });
}

List<Map<String, Object?>> _proposals(Map<String, Object?> response) =>
    (response['proposals'] as List).cast<Map<String, Object?>>();

List<Map<String, Object?>> _evidence(Map<String, Object?> proposal) =>
    (proposal['evidence'] as List).cast<Map<String, Object?>>();

class _Host {
  _Host(this.bots, this.bot, this.project, this.otherProject);

  final Bots bots;
  final Bot bot;
  final String project;
  final String otherProject;
  var projectEvidenceReads = 0;
  Future<void> Function()? beforeProjectEvidence;

  BotMemoryScope get scope => BotMemoryScope(botId: bot.id);
  BotMemoryReview get review => bots.memoryReview!;

  static Future<_Host> start() async {
    final workspace = Workspace();
    addTearDown(workspace.dispose);
    final folders = MemoryBotFolders();
    final bots = Bots(workspace: workspace, folders: folders);
    addTearDown(bots.dispose);
    await bots.start();
    workspace.importFolders(['/release', '/other']);
    String id(String path) => workspace.localProjectId(
      workspace.projects.singleWhere((project) => project.path == path),
    )!;
    final host = _Host(bots, bots.bots.single, id('/release'), id('/other'));
    host.enableProjects();
    final skills = BotMemorySkills(
      store: MemoryPreferenceStore(),
      folders: folders,
      root: '/bots/skills',
      canUseProject: (botId, project) =>
          bots.projectFactAccess(botId, project) != null,
    );
    final review = bots.memoryReview = BotMemoryReview(
      store: MemoryPreferenceStore(),
      scopeExists: bots.reviewScopeExists,
      readEvidence: (_, _, _) async => 'Use the compact agenda format.',
      readProjectEvidence: (_, _, _, source) async {
        host.projectEvidenceReads++;
        await host.beforeProjectEvidence?.call();
        return switch (source.role) {
          BotMemoryReviewRole.user => 'Check the release manifest.',
          BotMemoryReviewRole.task => 'The release manifest is ready.',
          BotMemoryReviewRole.verification => 'The manifest validation passed.',
          _ => null,
        };
      },
      readMemory: (_) => BotMemory.fromMarkdown(''),
      applyMemory: (
        _,
        _, {
        required sessionId,
        required messageId,
        required operationId,
        required changeSources,
      }) => fail('Unexpected private memory write'),
      ask: (request) async => jsonEncode({
        'proposals': [
          if (request.sessionId == 'private-session')
            {
              'action': 'add',
              'text': 'Use the compact agenda format.',
              'evidence': ['e1'],
            }
          else
            {
              'action': 'skill',
              'skill': {
                'name': 'review-manifest',
                'trigger': 'Before sending a release manifest.',
                'steps': ['Open the manifest.', 'Check the date.'],
                'verification': 'The manifest validation passed.',
              },
              'evidence': ['e1', 'e2', 'e3'],
            },
        ],
      }),
      foregroundBusy: () => false,
      skills: skills,
      threshold: 1,
    );
    await review.configure(
      host.scope,
      memoryApproval: true,
      skillApproval: true,
    );
    await review.recordTurn(
      scope: host.scope,
      sessionId: 'private-session',
      turnId: 'turn',
      evidence: const [
        BotMemoryReviewEvidence(
          messageId: 'private-message',
          role: BotMemoryReviewRole.user,
        ),
      ],
    );
    await review.runNext();
    await review.recordTurn(
      scope: host.scope,
      sessionId: 'project-session',
      turnId: 'task',
      project: host.project,
      evidence: const [
        BotMemoryReviewEvidence(
          messageId: 'task/request',
          role: BotMemoryReviewRole.user,
        ),
        BotMemoryReviewEvidence(
          messageId: 'task/report',
          role: BotMemoryReviewRole.task,
        ),
        BotMemoryReviewEvidence(
          messageId: 'task/check',
          role: BotMemoryReviewRole.verification,
        ),
      ],
    );
    await review.runNext();
    return host;
  }

  void enableProjects() => _setAbilities({BotAbility.agents});
  void revokeProjects() => _setAbilities({});

  void _setAbilities(Set<BotAbility> abilities) => bots.save(
    id: bot.id,
    name: bot.name,
    identity: bot.identity,
    abilities: abilities,
    by: bot,
  );

  BotMemoryManagement management({required bool localOwner}) =>
      BotMemoryManagement(bots, reviewer: 'desktop', localOwner: localOwner);

  Future<Map<String, Object?>> call(
    BotMemoryManagement management,
    String method, [
    Map<String, Object?> args = const {},
  ]) => management.call(method, {'bot': bot.id, ...args});
}
