import 'dart:convert';
import 'dart:io';

import 'package:bao_link/bao_link.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../chat/chat_models.dart';
import '../chat/composer/composer_files.dart';
import '../chat/reply_suggestions.dart';
import '../kernel/agent_kernel.dart';
import '../kernel/claude_code/claude_code_translator.dart';
import '../link/chat_codec.dart';
import '../platform/data_dir.dart';
import '../remote/remote_claude.dart';
import '../search/memory_history.dart';
import '../workspace/workspace.dart';
import 'bot.dart';
import 'bot_legacy_diary.dart';
import 'bots.dart';

final _indexes = Expando<MemoryHistoryIndex>('bot history');

/// One index per Bot host. Callers supply request-specific authorization. The
/// adapter also checks the live Bot, project and group before reading sources.
/// Stable source locators use the stored transcript UUID or the group sequence.
MemoryHistoryIndex botHistoryIndex(Bots bots) {
  return _indexes[bots] ??= _BotHistorySource(bots).index();
}

final class _BotHistorySource {
  _BotHistorySource(this.bots);

  final Bots bots;
  final _activeRecords = <(String, String), SessionRecord>{};

  MemoryHistoryIndex index() {
    final data = DataDirectory.current;
    return MemoryHistoryIndex(
      source: MemoryHistorySource(
        load: (scope) => _messages(scope),
        loadSession: (scope, id) => _messages(scope, sessionIds: {id}),
        read: (ref) async => (await _readMany(ref.scope, [ref])).firstOrNull,
        readMany: _readMany,
        checkpoint: _checkpoint,
      ),
      path: bots.folders.root == data.botsDir
          ? p.join(data.cacheDir, 'bot-history')
          : null,
    );
  }

  Future<List<MemoryHistoryMessage>> _readMany(
    MemoryHistoryScope scope,
    List<MemoryHistoryReference> refs,
  ) async {
    final wanted = refs.toSet();
    final messages = await _messages(
      scope,
      sessionIds: {for (final ref in wanted) ref.sessionId},
    );
    return [
      for (final message in messages)
        if (wanted.contains(message.reference)) message,
    ];
  }

  Future<List<MemoryHistoryMessage>> _messages(
    MemoryHistoryScope scope, {
    Set<String>? sessionIds,
  }) async {
    final bot = bots.byId(scope.botId);
    if (bot == null) return const [];
    final diary = BotLegacyDiary(bots.folders, bot);
    if (scope.kind == MemoryHistoryScopeKind.bot) {
      return diary.messages(scope, sessionIds: sessionIds);
    }
    if (scope.kind == MemoryHistoryScopeKind.group) {
      final group = scope.groupId!;
      if (bots.groups.byId(group)?.members.contains(bot.id) != true) {
        return const [];
      }
      final messages = diary.messages(scope, sessionIds: sessionIds);
      if (sessionIds != null && !sessionIds.contains(group)) return messages;
      final bytes = _groupBytes(bot, group);
      if (bytes == null) return messages;
      for (final line in const LineSplitter().convert(
        utf8.decode(bytes, allowMalformed: true),
      )) {
        if (line.trim().isEmpty) continue;
        try {
          if (jsonDecode(line) case final Map<String, Object?> row
              when row['_deleted'] != true &&
                  row['seq'] is int &&
                  row['at'] is int &&
                  row['from'] is String &&
                  (row['text'] == null || row['text'] is String)) {
            final original = LinkGroupMessage.fromJson(row);
            if (original.notice || original.seq < 1) continue;
            final text = original.mine
                ? original.text
                : ChatCodec.literalBotText(original.text) ??
                      _botWords(original.text);
            if (text.trim().isEmpty) continue;
            messages.add(
              MemoryHistoryMessage(
                reference: MemoryHistoryReference(
                  scope: scope,
                  sessionId: group,
                  messageId: '${original.seq}',
                ),
                role: original.mine
                    ? MemoryHistoryRole.user
                    : MemoryHistoryRole.assistant,
                text: text,
                time: original.at,
                sequence: original.seq,
                senderId: original.from,
              ),
            );
          }
        } on FormatException {
          // A partially written line has no usable original to quote.
        }
      }
      return messages;
    }

    final records = await _records(bot, scope, sessionIds);
    final messages = diary.messages(scope, sessionIds: sessionIds);
    for (final record in records) {
      final rows = await _readRecord(record.session);
      messages.addAll(
        projectBotHistoryTranscript(
          scope: scope,
          sessionId: record.session.id,
          rows: rows,
          legacyPrivate: record.legacyPrivate,
        ),
      );
    }
    if (scope.kind == MemoryHistoryScopeKind.dm) {
      final deliveries = _deliveries(bot, scope);
      messages.addAll(
        sessionIds == null
            ? deliveries
            : deliveries.where(
                (msg) => sessionIds.contains(msg.reference.sessionId),
              ),
      );
    }
    return identical(bots.byId(bot.id), bot) ? messages : const [];
  }

  List<int>? _groupBytes(Bot bot, String id) {
    final group = bots.groups.byId(id);
    if (group == null || !group.members.contains(bot.id)) return null;
    return bots.folders.readFile(
      p.join(p.dirname(bots.groups.chatFile(group.id)), 'messages.jsonl'),
    );
  }

  List<MemoryHistoryMessage> _deliveries(Bot bot, MemoryHistoryScope scope) => [
    for (final delivery in bots.privateDeliveries(bot))
      if (ChatCodec.botSentToUser(delivery.item) case final String text
          when text.trim().isNotEmpty &&
              !delivery.item.input.containsKey('hostCommand'))
        MemoryHistoryMessage(
          reference: MemoryHistoryReference(
            scope: scope,
            sessionId: 'bot-dm-deliveries:${bot.id}',
            messageId: delivery.id,
          ),
          role: MemoryHistoryRole.assistant,
          text: _botDisplayText(text),
          time: delivery.at,
          sequence: delivery.at.microsecondsSinceEpoch,
        ),
  ];

  Future<List<_HistoryRecord>> _records(
    Bot bot,
    MemoryHistoryScope scope,
    Set<String>? sessionIds,
  ) async {
    final Iterable<AgentThread> threads = switch (scope.kind) {
      MemoryHistoryScopeKind.dm => [
        ...bots.privateHistory(bot),
        ?bots.threadOf(bot),
      ],
      MemoryHistoryScopeKind.project => [
        for (final project in bots.workspace.projects)
          if (project.path == scope.projectId &&
              project.host == null &&
              !bots.workspace.isHidden(project))
            ...bots.workspace.threads.where(
              (thread) =>
                  thread.project == project && !bots.isBotThread(thread),
            ),
      ],
      _ => const [],
    };
    final byId = <String, _HistoryRecord>{};
    final listed = <String, List<SessionRecord>>{};
    for (final thread in threads) {
      final cwd = thread.project.path;
      final id = thread.id;
      final catalog = thread.kernel.catalog;
      if (id == null ||
          sessionIds != null && !sessionIds.contains(id) ||
          thread.project.host != null ||
          catalog is! ClaudeCatalog) {
        continue;
      }
      final key = (cwd, id);
      var record = thread.record ?? _activeRecords[key];
      if (record?.id != id || record?.cwd != cwd || record?.path == null) {
        final sessions = listed[cwd] ??= await catalog.sessionsIn(cwd);
        record = sessions
            .where((record) => record.id == id && record.cwd == cwd)
            .firstOrNull;
        if (record != null && thread.record == null) {
          _activeRecords[key] = record;
        }
      }
      if (record?.path != null) {
        byId[id] = (
          session: record!,
          legacyPrivate:
              scope.kind == MemoryHistoryScopeKind.dm &&
              bots.isLegacyPrivateThread(bot, thread),
        );
      }
    }
    return byId.values.toList();
  }

  Future<String?> _checkpoint(MemoryHistoryScope scope) async {
    final bot = bots.byId(scope.botId);
    if (bot == null) return null;
    final diary = BotLegacyDiary(bots.folders, bot);
    if (scope.kind == MemoryHistoryScopeKind.group) {
      final group = scope.groupId!;
      if (bots.groups.byId(group)?.members.contains(bot.id) != true) {
        return null;
      }
      final bytes = _groupBytes(bot, group);
      return sha256
          .convert(
            utf8.encode(
              jsonEncode([
                if (bytes != null) sha256.convert(bytes).toString(),
                diary.revisions(),
              ]),
            ),
          )
          .toString();
    }
    if (scope.kind == MemoryHistoryScopeKind.bot) {
      return sha256
          .convert(utf8.encode(jsonEncode(diary.revisions())))
          .toString();
    }
    final records = await _records(bot, scope, null);
    final revisions = <Object?>[2];
    if (scope.kind == MemoryHistoryScopeKind.dm) {
      revisions.add(diary.revisions());
    }
    for (final record in records) {
      final path = record.session.path!;
      final stat = await File(path).stat();
      revisions.add([
        record.session.id,
        path,
        record.legacyPrivate,
        stat.type.toString(),
        stat.size,
        stat.modified.microsecondsSinceEpoch,
        stat.changed.microsecondsSinceEpoch,
      ]);
    }
    if (scope.kind == MemoryHistoryScopeKind.dm) {
      revisions.add([for (final msg in _deliveries(bot, scope)) msg.toJson()]);
    }
    return sha256.convert(utf8.encode(jsonEncode(revisions))).toString();
  }
}

typedef _HistoryRecord = ({SessionRecord session, bool legacyPrivate});

Future<List<Map<String, Object?>>> _readRecord(SessionRecord record) async {
  try {
    return await readClaudeHistory(record);
  } on FileSystemException {
    // Its source was removed or cannot be read. Show no saved copy.
    return const [];
  }
}

/// Project a saved branch without executing or resuming it. Only explicitly
/// private legacy turns are eligible for assistant replies. The group log is
/// the sole source of group history, including for old mixed transcripts.
List<MemoryHistoryMessage> projectBotHistoryTranscript({
  required MemoryHistoryScope scope,
  required String sessionId,
  required Iterable<Map<String, Object?>> rows,
  bool legacyPrivate = false,
}) {
  final dm = scope.kind == MemoryHistoryScopeKind.dm;
  if (!dm && scope.kind != MemoryHistoryScopeKind.project) return const [];
  final messages = <MemoryHistoryMessage>[];
  final pending = <String, String>{};
  final retracted = <String>{};
  var privateTurn = !legacyPrivate;
  DateTime? turnTime;
  void add(
    int sequence,
    String id,
    MemoryHistoryRole role,
    String text,
    DateTime? time,
  ) {
    if (text.trim().isEmpty) return;
    messages.add(
      MemoryHistoryMessage(
        reference: MemoryHistoryReference(
          scope: scope,
          sessionId: sessionId,
          messageId: id,
        ),
        role: role,
        text: text,
        time: time ?? _unknownTime,
        sequence: sequence,
      ),
    );
  }

  for (final (sequence, row) in rows.indexed) {
    if (row['isSidechain'] == true || row['parent_tool_use_id'] != null) {
      continue;
    }
    final body = row['message'];
    if (body is! Map<String, Object?>) continue;
    if (row['type'] == 'tombstone') {
      if (body['uuid'] case final String id) retracted.add(id);
      for (final block in _blocks(body['message'])) {
        if (block['id'] case final String id) retracted.add(id);
      }
      continue;
    }
    if (row['uuid'] case final String id when id.isNotEmpty) {
      final at = switch (row['timestamp']) {
        final String value => DateTime.tryParse(value),
        _ => null,
      };
      final blocks = _blocks(body['content']);
      final text = _plainText(body['content'], blocks);
      switch (row['type']) {
        case 'user':
          for (final block in blocks) {
            if (legacyPrivate &&
                block['type'] == 'tool_result' &&
                block['tool_use_id'] is String) {
              final callId = block['tool_use_id']! as String;
              final sent = pending.remove(callId);
              if (sent != null && _confirmedPrivateDelivery(block)) {
                add(
                  sequence,
                  callId,
                  MemoryHistoryRole.assistant,
                  sent,
                  at ?? turnTime,
                );
              }
            }
          }
          final hidden =
              row['isMeta'] == true ||
              row['isSynthetic'] == true ||
              row['isCompactSummary'] == true ||
              row['isVisibleInTranscriptOnly'] == true;
          if (hidden) {
            if (legacyPrivate && _containsGroupEvent(text)) privateTurn = false;
            continue;
          }
          if (blocks.any((block) => block['type'] == 'tool_result')) continue;
          final item = UserMessageItem(text: text);
          if (dm &&
              (ChatCodec.botEvent(item) != null || _containsGroupEvent(text))) {
            turnTime = at ?? turnTime;
            privateTurn = !legacyPrivate && !_containsGroupEvent(text);
            continue;
          }
          if (_hiddenPrompt(text)) {
            if (legacyPrivate && text.isNotEmpty) privateTurn = false;
            continue;
          }
          final words = dm
              ? _botDisplayText(splitCodeAppendix(text).body)
              : splitCodeAppendix(text).body.trim();
          if (words.isNotEmpty ||
              blocks.any((block) => block['type'] == 'image')) {
            privateTurn = true;
            turnTime = at ?? turnTime;
          }
          add(sequence, id, MemoryHistoryRole.user, words, at ?? turnTime);
        case 'assistant':
          if (row['isMeta'] == true ||
              row['isSynthetic'] == true ||
              row['isCompactSummary'] == true ||
              row['isVisibleInTranscriptOnly'] == true) {
            continue;
          }
          if (legacyPrivate) {
            for (final block in blocks) {
              if (_privateDelivery(block) case (final callId, final words)) {
                pending[callId] = words;
              }
            }
          }
          if (dm && !privateTurn) continue;
          add(
            sequence,
            id,
            MemoryHistoryRole.assistant,
            dm ? _botWords(text) : ReplySuggestions.strip(text).trim(),
            at ?? turnTime,
          );
      }
    }
  }
  return [
    for (final message in messages)
      if (!retracted.contains(message.reference.messageId)) message,
  ];
}

final _unknownTime = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

List<Map<String, Object?>> _blocks(Object? value) => value is List<Object?>
    ? value.whereType<Map<String, Object?>>().toList()
    : const [];

String _plainText(Object? content, List<Map<String, Object?>> blocks) {
  if (content is String) return content.trim();
  return [
    for (final block in blocks)
      if (block['text'] case final String text
          when block['type'] == 'text' &&
              !text.trimLeft().startsWith('<system-reminder>'))
        text,
  ].join('\n').trim();
}

bool _containsGroupEvent(String text) =>
    RegExp(r'<bao-event>\s*\[group\s').hasMatch(text);

bool _hiddenPrompt(String text) =>
    text.startsWith('<system-reminder>') ||
    text.startsWith('<task-notification>') ||
    text.startsWith('<local-command-caveat>') ||
    text.startsWith('<local-command-stdout>') ||
    text.startsWith('<command-name>') ||
    text.startsWith('[Request interrupted by user') ||
    text.startsWith('Stop hook feedback:\n[') ||
    ClaudeTranslator.agentMessage(text) != null;

String _botDisplayText(String text) =>
    ChatCodec.withoutBotEvents(text.replaceAll(imageReferencePattern, ''));

String _botWords(String text) => [
  for (final (tag, part) in ChatCodec.botParts(_botDisplayText(text)))
    if (tag == ChatCodec.botSayTag || tag == ChatCodec.botNarrateTag)
      if (ChatCodec.withoutVoiceCues(part) case final words
          when words.isNotEmpty)
        words,
].join('\n');

(String, String)? _privateDelivery(Map<String, Object?> block) {
  final name = block['name'];
  final input = block['input'];
  if (block['id'] case final String id
      when block['type'] == 'tool_use' &&
          name is String &&
          (name == ChatCodec.botSendTool ||
              name.endsWith('__${ChatCodec.botSendTool}')) &&
          input is Map<String, Object?> &&
          input['to'] == ChatCodec.botToUser) {
    if (input['text'] case final String words) {
      return (id, _botDisplayText(words));
    }
  }
  return null;
}

bool _confirmedPrivateDelivery(Map<String, Object?> block) {
  if (block['is_error'] == true) return false;
  final content = block['content'];
  final text = _plainText(content, _blocks(content));
  return text == 'Sent to the user, in your chat with them.';
}
