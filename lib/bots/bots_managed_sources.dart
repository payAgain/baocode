part of 'bots.dart';

extension BotManagedSources on Bots {
  bool isManagedOriginalDeleted(
    BotMemoryScope scope,
    String? project,
    String session,
    String message,
  ) {
    if (scope.groupId != null) return false;
    final bot = byId(scope.botId);
    if (bot == null) return false;
    final cwd = project == null
        ? runtimeFolder(bot)
        : workspace.localProjectById(project)?.path;
    if (cwd == null) return false;
    if (ManagedTranscripts.isOriginalDeleted(cwd, session, message)) {
      return true;
    }
    if (project != null) {
      final split = message.indexOf('/');
      if (split > 0) {
        return ManagedTranscripts.isOriginalDeleted(
              cwd,
              session,
              message.substring(0, split),
            ) ||
            ManagedTranscripts.isOriginalDeleted(
              cwd,
              session,
              message.substring(split + 1),
            );
      }
    }
    return false;
  }

  AgentThread? _managedSourceThread(
    MemoryHistoryReference ref,
    String? project,
  ) {
    final bot = byId(ref.scope.botId);
    if (_disposed || bot == null) return null;
    final String cwd;
    if (project == null) {
      if (ref.scope != MemoryHistoryScope.dm(bot.id)) return null;
      cwd = runtimeFolder(bot);
    } else {
      final local = workspace.localProjectById(project);
      if (local == null ||
          projectFactAccess(bot.id, project) == null ||
          ref.scope != MemoryHistoryScope.project(bot.id, local.path)) {
        return null;
      }
      cwd = local.path;
    }
    if (!ManagedTranscripts.exists(cwd, ref.sessionId)) return null;
    return workspace.threads
        .where(
          (thread) =>
              thread.project.host == null &&
              thread.project.path == cwd &&
              thread.id == ref.sessionId,
        )
        .firstOrNull;
  }

  bool canDeleteManagedOriginal(MemoryHistoryReference ref, {String? project}) {
    final thread = _managedSourceThread(ref, project);
    return thread != null &&
        workspace.canEditKeptTranscript(thread) &&
        ManagedTranscripts.canDeleteOriginal(
          thread.project.path,
          ref.sessionId,
          ref.messageId,
        );
  }

  Future<void> deleteManagedOriginal(
    MemoryHistoryReference ref, {
    String? project,
  }) async {
    final thread = _managedSourceThread(ref, project);
    if (thread == null) throw StateError('The source is unavailable');
    final cwd = thread.project.path;
    await workspace.editKeptTranscript(
      thread,
      SessionRecord(
        id: ref.sessionId,
        title: '',
        updatedAt: thread.updatedAt,
        cwd: cwd,
        path: ManagedTranscripts.transcriptPath(cwd, ref.sessionId),
      ),
      () {
        if (!identical(_managedSourceThread(ref, project), thread)) {
          throw StateError('The source is unavailable');
        }
        if (!ManagedTranscripts.deleteOriginal(
          cwd,
          ref.sessionId,
          ref.messageId,
          redactCopies: project == null
              ? (role, text) => _redactManagedDiaryCopies(ref, role, text)
              : null,
        )) {
          throw StateError(
            'The source changed or the conversation is still running',
          );
        }
      },
    );
    final affected = project == null ? [byId(ref.scope.botId)!] : bots;
    final cleanup = <Future<void>>[];
    for (final bot in affected) {
      final scope = BotMemoryScope(botId: bot.id);
      cleanup.add(
        botHistoryIndex(this).invalidate(
          project == null
              ? MemoryHistoryScope.dm(bot.id)
              : MemoryHistoryScope.project(bot.id, cwd),
        ),
      );
      if (memoryReview case final review?) {
        cleanup.add(
          review.invalidateDeletedSources(
            scope,
            project: project,
            sessionId: ref.sessionId,
            messageId: ref.messageId,
          ),
        );
      }
      if (project == null) {
        cleanup.add(
          botHistoryIndex(this).invalidate(MemoryHistoryScope.bot(bot.id)),
        );
        memoryWithdrawn(bot);
      }
      _checkLiveMemoryShares(bot);
    }
    _factsChanged();
    await Future.wait(cleanup);
  }

  void _redactManagedDiaryCopies(
    MemoryHistoryReference ref,
    String role,
    List<String> payload,
  ) {
    final mine = role == 'assistant';
    BotLegacyDiary(folders, byId(ref.scope.botId)!).redactOriginal(
      ref,
      legacyText: [
        for (final text in [...payload, payload.join(), payload.join('\n')])
          if (mine)
            BotLife.saysOf(text)
          else
            ChatCodec.withoutBotEvents(
              text.replaceAll(imageReferencePattern, ''),
            ),
      ],
      mine: mine,
    );
  }
}
