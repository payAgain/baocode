import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:bao_link/bao_link.dart'
    show linkGroupLeastPasses, linkGroupPasses;
import 'package:path/path.dart' as p;

import '../chat/chat_models.dart';
import '../chat/chat_session.dart';
import '../images/image_tools.dart' show imagePreview;
import '../kernel/claude_code/claude_sdk_tools.dart';
import '../link/chat_codec.dart';
import '../link/workspace_bridge.dart' show WorkspaceBridge;
import '../models/image_api.dart' show imageMediaType;
import '../search/memory_history.dart';
import '../workspace/workspace.dart';
import 'bot.dart';
import 'bot_groups.dart' show BotGroups;
import 'bot_history.dart';
import 'bot_memory.dart';
import 'bot_memory_provider.dart';
import 'bot_memory_review.dart';
import 'bot_pacer.dart' show BotEventKind, botTime;
import 'bot_watch.dart';
import 'bots.dart';

/// Identity, opt-in, and conversation scope for a bot-specific tool.
class BotToolAccess {
  const BotToolAccess({
    this.ability,
    this.assistant = false,
    this.privateOnly = false,
  });

  final BotAbility? ability;
  final bool assistant;
  final bool privateOnly;

  bool allows(Bot bot, {required String? group}) =>
      (!assistant || bot.assistant) &&
      (!privateOnly || group == null) &&
      (ability == null || bot.can(ability!));
}

/// A cross-group command parsed by the host from an accepted user DM.
final class BotGroupCommand {
  const BotGroupCommand._({
    required this.request,
    this.error,
    this.group,
    this.payload,
    this.epoch,
    this.recall = false,
  });

  final String request;
  final String? error;
  final String? group;
  final String? payload;
  final Object? epoch;
  final bool recall;
}

/// The bots' tools (`mcp__baocode__bot_*`): the user's agents retried and
/// archived (seen, written to and started with the session tools, as a
/// project's agent does them); what the bot remembers kept. Each for the
/// bots with its ability on (see [Bots.offersTool]); none for the agents
/// of projects.
abstract final class BotTools {
  static final Map<String, BotToolAccess> _access = {};
  static final _memberships = Expando<Map<(String, String), Object>>();
  static final _groupCommand = RegExp(
    r'^/(recall-group|send-group)[ \t]+"([^"\r\n]+)"[ \t]([^\r\n]+)$',
  );

  /// Freeze the exact destination before the host queues or dispatches a DM.
  static BotGroupCommand? prepareGroupCommand(
    Bots bots,
    Bot bot,
    ComposerMessage message,
  ) {
    if (message.images.isNotEmpty || message.mentions.isNotEmpty) return null;
    final match = _groupCommand.firstMatch(message.text);
    if (match == null || match.end != message.text.length) return null;
    final selector = match[2]!;
    final payload = match[3]!;
    if (selector.trim().isEmpty || payload.trim().isEmpty) return null;
    final groups = bots.groups;
    final id = groups.byId(selector);
    final matches = [
      for (final room in id == null ? groups.groups : [id])
        if (room.members.contains(bot.id) &&
            (room.id == selector || room.name == selector))
          room,
    ];
    if (matches.length != 1) {
      final choices = jsonEncode([
        for (final room in matches) {'name': room.name, 'id': room.id},
      ]);
      return BotGroupCommand._(
        request: message.text,
        error: matches.isEmpty
            ? (bots.chinese ? '未找到可用的群聊。' : 'No matching group is available.')
            : (bots.chinese
                  ? '群名不唯一。请使用群 ID 重发。可选群聊：$choices'
                  : 'The group name is ambiguous. Resend with a group ID. '
                        'Available groups: $choices'),
      );
    }
    final room = matches.single;
    final epochs = _memberships[bots] ??= {};
    final epoch = epochs.putIfAbsent((bot.id, room.id), Object.new);
    return BotGroupCommand._(
      request: message.text,
      group: room.id,
      payload: payload,
      epoch: epoch,
      recall: match[1] == 'recall-group',
    );
  }

  /// Restore the reply for a queued command whose in-memory grant expired.
  static BotGroupCommand expiredGroupCommand(
    Bots bots,
    ComposerMessage message,
  ) => BotGroupCommand._(request: message.text, error: _expired(bots));

  static String _expired(Bots bots) => bots.chinese
      ? '群聊授权已失效。请重发指令。'
      : 'Group access has expired. Resend the command.';

  /// Execute a host-confirmed command without exposing its results to a model.
  static bool runGroupCommand(
    Bots bots,
    Bot bot,
    ChatSession session,
    String turn,
    BotGroupCommand? command,
  ) {
    if (command == null) return false;
    final group = command.group;
    final alias = bots.privateSessionId(bot);
    bool current() =>
        bots.isActivePrivateSession(bot, session) &&
        bots.privateSessionId(bot) == alias;
    bool authorized() =>
        current() &&
        group != null &&
        _memberships[bots]?[(bot.id, group)] == command.epoch &&
        bots.groups.byId(group)?.members.contains(bot.id) == true;
    void reply(
      String text, {
      String? recallGroup,
      List<int> recallHits = const [],
    }) {
      if (current()) {
        bots.recordGroupCommandReply(
          bot,
          turn: turn,
          request: command.request,
          text: text,
          recallGroup: recallGroup,
          recallHits: recallHits,
        );
      }
    }

    final revoked = _expired(bots);
    if (command.error case final error?) {
      reply(error);
    } else if (group == null || !authorized()) {
      reply(revoked);
    } else if (command.recall) {
      final scope = MemoryHistoryScope.group(bot.id, group);
      unawaited(() async {
        try {
          final page = await botHistoryIndex(bots).search(
            MemoryHistoryAccess(
              current: scope,
              isAuthorized: (_) => authorized(),
            ),
            MemoryHistoryQuery(text: command.payload!),
          );
          if (!authorized()) return reply(revoked);
          final room = bots.groups.byId(group)!;
          final text = page.hits.isEmpty
              ? (bots.chinese
                    ? '「${room.name}」里没有匹配的消息。'
                    : 'No matching messages in ${room.name}.')
              : [
                  room.name,
                  for (final hit in page.hits)
                    '#${hit.reference.messageId} ${hit.snippet}',
                ].join('\n\n');
          reply(
            text,
            recallGroup: group,
            recallHits: [
              for (final hit in page.hits)
                ?int.tryParse(hit.reference.messageId),
            ],
          );
        } on Object {
          reply(bots.chinese ? '群聊回忆失败。' : 'Could not recall this group.');
        }
      }());
    } else {
      final message = bots.groups.say(
        group,
        bot.id,
        command.payload!,
        delivery: 'send-group/$turn',
        literal: true,
      );
      final name = bots.groups.byId(group)!.name;
      reply(
        bots.chinese
            ? '已发送到「$name」（#${message.seq}）。'
            : 'Sent to $name (#${message.seq}).',
      );
    }
    return true;
  }

  static void revokeGroupCommands(Bots bots, String bot, String group) {
    _memberships[bots]?.remove((bot, group));
  }

  /// Who [tool] is for, if a bot's.
  static BotToolAccess? accessOf(String tool) => _access[tool];

  /// [thread]'s id, as the phones have it.
  static String idOf(AgentThread thread) => WorkspaceBridge.idOf(thread);

  static void register(Bots bots) {
    unregister();
    for (final (tool, access) in _tools(bots)) {
      _access[tool.name] = access;
      ClaudeSdkTools.register(tool);
    }
  }

  static void unregister() {
    for (final name in _access.keys) {
      ClaudeSdkTools.unregister(name);
    }
    _access.clear();
  }

  static const _agents = BotToolAccess(ability: BotAbility.agents);

  static List<(ClaudeSdkTool, BotToolAccess)> _tools(Bots bots) {
    final workspace = bots.workspace;

    Bot botOf(ClaudeSdkCall call) =>
        bots.botAt(call.cwd) ?? (throw StateError('Not a bot'));

    // The bots as their files say now, before a tool of theirs changes
    // them: what one edited in them this turn, kept.
    Bot freshOf(ClaudeSdkCall call) {
      bots.reload(by: botOf(call));
      return botOf(call);
    }

    List<AgentThread> chats() => [
      for (final thread in workspace.threads)
        if (!thread.archived &&
            !bots.isBotThread(thread) &&
            workspace.listsInSidebar(thread))
          thread,
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

    AgentThread chat(Map<String, Object?> input) {
      final id = input['chat'];
      for (final thread in chats()) {
        if (idOf(thread) == id || thread.id == id) return thread;
      }
      throw StateError('No chat $id. List them with session_list.');
    }

    String text(Map<String, Object?> input, String key) {
      final value = (input[key] as String? ?? '').trim();
      if (value.isEmpty) throw ArgumentError('$key is empty');
      return value;
    }

    ClaudeSdkTool tool(
      String name,
      String description,
      Map<String, Object?> properties,
      Future<Object> Function(Map<String, Object?> input, ClaudeSdkCall call)
      run, {
      List<String> required = const [],
      String Function(Map<String, Object?> input, String? output)? summary,
    }) => ClaudeSdkTool(
      name: name,
      description: description,
      inputSchema: {
        'type': 'object',
        'properties': properties,
        if (required.isNotEmpty) 'required': required,
      },
      run: run,
      kind: ToolKind.other,
      summary: summary,
      // Its own, few: never behind the tool search.
      alwaysLoad: true,
    );

    const chatId = {
      'type': 'string',
      'description': 'The conversation\'s id, as session_list gives it.',
    };
    String titled(Map<String, Object?> input, String? _) {
      try {
        return chat(input).title;
      } on Object {
        return '${input['chat'] ?? ''}';
      }
    }

    String clip(Map<String, Object?> input, String key) =>
        _clip('${input[key] ?? ''}', 80);

    ({String? id, String text})? privateUserSource(
      Bot bot,
      ClaudeSdkCall call,
    ) {
      final session = bots.threadOf(bot)?.session;
      if (session == null ||
          call.sessionId == null ||
          session.sessionId != call.sessionId ||
          !session.isStreaming) {
        return null;
      }
      for (var i = session.itemCount - 1; i >= 0; i--) {
        final item = session.itemAt(i);
        if (item is! UserMessageItem || item.queued) continue;
        if (item.fromAgent != null || ChatCodec.botEvent(item) != null) {
          return null;
        }
        return (
          id: session.itemIdAt(i),
          text: ChatCodec.withoutBotEvents(item.text),
        );
      }
      return null;
    }

    bool requestedHistory(Bot bot, ClaudeSdkCall call, String target) =>
        privateUserSource(
          bot,
          call,
        )?.text.toLowerCase().contains(target.toLowerCase()) ==
        true;

    const memoryFields = {
      'id': {'type': 'integer', 'description': 'Entry id from list.'},
      'revision': {
        'type': 'integer',
        'description': 'Entry revision from list.',
      },
      'text': {'type': 'string'},
    };
    BotMemoryChange memoryChange(Map<String, Object?> input) => (
      action: switch (input['action']) {
        null || 'add' => BotMemoryAction.add,
        'update' => BotMemoryAction.update,
        'remove' => BotMemoryAction.remove,
        _ => throw ArgumentError('Use add, update or remove for user memory.'),
      },
      id: input['id'] as int?,
      revision: input['revision'] as int?,
      text: input['text'] as String?,
    );

    return [
      (
        tool(
          'bot_later',
          'Comes back to the user on your own, later: in so many seconds '
              'you are woken with your note, to write to them if it still '
              'makes sense. Use it to follow something up (how a talk went, '
              'whether a fix worked, a reminder they asked for) instead of '
              'promising to. At most ${Bots.maxLaters} waiting. Woken, it is '
              'yours to judge whether it still needs a word.',
          {
            'seconds': {
              'type': 'integer',
              'description':
                  'From now: 10 to 604800 (a week); 300 is five minutes.',
            },
            'note': {
              'type': 'string',
              'description':
                  'For yourself: what to come back to, and why, in a line.',
            },
          },
          (input, call) async {
            final bot = botOf(call);
            final seconds = (input['seconds'] as num?)?.toInt() ?? 0;
            if (seconds < 10 || seconds > 604800) {
              throw ArgumentError('seconds is 10 to 604800');
            }
            final at = bots.later(
              bot,
              Duration(seconds: seconds),
              text(input, 'note'),
            );
            return 'You will be woken ${botTime(at, seconds: true)}.';
          },
          required: ['seconds', 'note'],
          summary: (input, _) => clip(input, 'note'),
        ),
        const BotToolAccess(privateOnly: true),
      ),
      (
        tool(
          'bot_cancel_later',
          'Drops what you meant to come back to (bot_later): the user called '
              'it off, say, or it is done. Those whose note has what you give '
              'in it go.',
          {
            'note': {
              'type': 'string',
              'description': 'Its note, or a part of it.',
            },
          },
          (input, call) async {
            final bot = botOf(call);
            final dropped = bots.cancelLaters(bot, text(input, 'note'));
            if (dropped.isNotEmpty) {
              return 'Dropped: ${[for (final later in dropped) later.note].join('; ')}.';
            }
            final waiting = bots.laters(bot);
            return waiting.isEmpty
                ? 'Nothing was waiting.'
                : 'None matched. Waiting: ${[for (final later in waiting) '${botTime(later.at, seconds: true)} ${later.note}'].join('; ')}.';
          },
          required: ['note'],
          summary: (input, _) => clip(input, 'note'),
        ),
        const BotToolAccess(privateOnly: true),
      ),
      (
        tool(
          'bot_watch',
          "What you are told of the user's agents: your rules (WATCH.md in "
              'your folder), a line each, the first that fits deciding. '
              '"tell" wakes you with it, to write to the user or not; '
              '"notify" has the phone tell the user for you, without waking '
              'you (for what they only want to know of, a turn done, say); '
              '"ignore" only keeps it (bot_recent_events). What fits no rule '
              'is ignored. Change them when the user asks you to keep an eye '
              'on something, or to stop telling them of it. "list" them; '
              '"add" one (first, unless last: true); "remove" one by its '
              'number; "reset" to how they were at first.',
          {
            'action': {
              'type': 'string',
              'enum': ['list', 'add', 'remove', 'reset'],
            },
            'when': {
              'type': 'array',
              'items': {
                'type': 'string',
                'enum': [for (final kind in BotEventKind.values) kind.name],
              },
              'description':
                  'What happened (waiting: it asks the user; failed; done: '
                  'its turn ended; running: for a long while). None for any.',
            },
            'project': {
              'type': 'string',
              'description': 'Only this project\'s agents: its name.',
            },
            'chat': {
              'type': 'string',
              'description': 'Only this agent: its id.',
            },
            'mine': {
              'type': 'boolean',
              'description': 'Only the agents you started or wrote to.',
            },
            'then': {
              'type': 'string',
              'enum': [for (final action in BotWatchAction.values) action.name],
            },
            'last': {
              'type': 'boolean',
              'description': 'Add it after the others, not first.',
            },
            'number': {
              'type': 'integer',
              'description': 'The rule to remove, as "list" numbers them.',
            },
          },
          (input, call) async {
            final bot = botOf(call);
            var rules = bots.watchRules(bot);
            switch (input['action']) {
              case 'add':
                final then =
                    BotWatchAction.values.asNameMap()[input['then']] ??
                    (throw ArgumentError('then is tell, notify or ignore'));
                final project = (input['project'] as String?)?.trim();
                final chat = (input['chat'] as String?)?.trim();
                final rule = BotWatchRule(
                  kinds: {
                    for (final name in (input['when'] as List?) ?? const [])
                      ?BotEventKind.values.asNameMap()[name],
                  },
                  project: project == null || project.isEmpty ? null : project,
                  chat: chat == null || chat.isEmpty ? null : chat,
                  mine: input['mine'] == true,
                  action: then,
                );
                rules = [
                  for (final had in rules)
                    if (had != rule) had,
                ];
                rules = input['last'] == true
                    ? [...rules, rule]
                    : [rule, ...rules];
                bots.setWatchRules(bot, rules);
              case 'remove':
                final number = (input['number'] as num?)?.toInt() ?? 0;
                if (number < 1 || number > rules.length) {
                  throw ArgumentError('No rule $number');
                }
                rules = [...rules]..removeAt(number - 1);
                bots.setWatchRules(bot, rules);
              case 'reset':
                rules = BotWatch.defaults;
                bots.setWatchRules(bot, rules);
            }
            if (rules.isEmpty) return 'No rules: you are told of nothing.';
            return [
              'Your rules, the first that fits deciding:',
              for (final (i, rule) in rules.indexed)
                '${i + 1}. ${rule.line.substring(2)}',
            ].join('\n');
          },
          required: ['action'],
          summary: (input, _) => '${input['action'] ?? ''}',
        ),
        const BotToolAccess(ability: BotAbility.proactive, privateOnly: true),
      ),
      (
        tool(
          'bot_recent_events',
          "What happened to the user's agents lately (the last day), "
              'oldest first, and what your rules made of each: those you '
              'were not woken for too. Look when the user asks how things '
              'went.',
          {
            'count': {'type': 'integer', 'description': 'At most; 20 if none.'},
          },
          (input, call) async {
            final count = ((input['count'] as num?)?.toInt() ?? 20).clamp(
              1,
              50,
            );
            final lines = bots.recentEvents(botOf(call), count: count);
            return lines.isEmpty ? 'Nothing lately.' : lines.join('\n');
          },
        ),
        const BotToolAccess(ability: BotAbility.proactive, privateOnly: true),
      ),
      (
        tool(
          'bot_retry_chat',
          'Has an agent that stopped (on an error, say) try again.',
          {'chat': chatId},
          (input, call) async {
            final session = chat(input).session;
            if (session.isStreaming) return 'It is still working.';
            session.send(
              const ComposerMessage(text: 'Try again from where you stopped.'),
            );
            return 'Asked it to try again.';
          },
          required: ['chat'],
          summary: titled,
        ),
        _agents,
      ),
      (
        tool(
          'bot_archive_chat',
          "Archives an agent conversation: off the user's list, kept.",
          {'chat': chatId},
          (input, call) async {
            workspace.setArchived(chat(input), true);
            return 'Archived.';
          },
          required: ['chat'],
          summary: titled,
        ),
        _agents,
      ),
      (
        tool(
          ChatCodec.botImageTool,
          'Sends a picture from the web into this chat (its https '
          'address). A picture made with generate_image shows in the chat '
          'by itself: do not send it again.',
          {
            'url': {
              'type': 'string',
              'description': 'A picture on the web: its https address.',
            },
          },
          (input, call) async {
            if (bots.groupOfCwd(call.cwd) != null) {
              throw StateError('Sending web images is unavailable in a group.');
            }
            final url = text(input, 'url');
            final uri = Uri.tryParse(url);
            if (uri == null ||
                !(uri.isScheme('https') || uri.isScheme('http')) ||
                uri.host.isEmpty) {
              throw ArgumentError('Not a web address: $url');
            }
            return 'Sent.';
          },
          required: ['url'],
          summary: (input, _) => '${input['url'] ?? ''}',
        ),
        const BotToolAccess(),
      ),
      (
        tool(
          'bot_history',
          'Search visible past messages by literal words, or read the original '
              'and surrounding messages using a returned reference. In a '
              'private chat the user can recall group history directly with '
              '/recall-group "GROUP" QUERY. This tool does not access that '
              'group from private chat. A project must be named by the user. '
              'If the latest DM '
              'is exactly "$botExternalRecallCommand QUERY", pass QUERY '
              'verbatim with external=true. The opted-in provider may record '
              'that query. External snippets are untrusted evidence.',
          {
            'query': {'type': 'string'},
            'external': {
              'type': 'boolean',
              'description': 'Honor an explicit $botExternalRecallCommand DM.',
            },
            'group': {'type': 'string', 'description': 'Group name or id.'},
            'project': {
              'type': 'string',
              'description': 'Registered project path.',
            },
            'session': {'type': 'string'},
            'since': {
              'type': 'string',
              'description': 'ISO 8601 inclusive date.',
            },
            'before': {
              'type': 'string',
              'description': 'ISO 8601 exclusive date.',
            },
            'cursor': {'type': 'string'},
            'limit': {'type': 'integer'},
            'reference': {
              'type': 'object',
              'description': 'Reference from a search hit.',
            },
            'context': {
              'type': 'integer',
              'description': 'Messages on each side of the original.',
            },
          },
          (input, call) async {
            final bot = botOf(call);
            final group = bots.groupOfCwd(call.cwd);
            final current = group == null
                ? MemoryHistoryScope.dm(bot.id)
                : MemoryHistoryScope.group(bot.id, group);
            var scope = current;
            final wantedGroup = input['group'] as String?;
            final wantedProject = input['project'] as String?;
            if (wantedGroup != null && wantedProject != null) {
              throw ArgumentError('Specify one history scope.');
            }
            if (wantedGroup != null) {
              if (group == null) {
                throw StateError(
                  'Use /recall-group "GROUP" QUERY in a private message.',
                );
              }
              if (wantedGroup != group &&
                  bots.groups.byId(group)?.name != wantedGroup) {
                throw StateError('This group history is unavailable here.');
              }
            } else if (wantedProject != null) {
              final project = workspace.projects
                  .where((project) => project.path == wantedProject)
                  .firstOrNull;
              if (group != null ||
                  !bot.abilities.contains(BotAbility.agents) ||
                  project == null ||
                  !(requestedHistory(bot, call, project.path) ||
                      requestedHistory(bot, call, project.name))) {
                throw StateError('This project history is unavailable here.');
              }
              scope = MemoryHistoryScope.project(bot.id, project.path);
            }
            final access = MemoryHistoryAccess(
              current: current,
              allowed: [if (scope != current) scope],
              isAuthorized: (candidate) {
                final live = bots.byId(bot.id);
                if (live == null) return false;
                return switch (candidate.kind) {
                  MemoryHistoryScopeKind.dm => true,
                  MemoryHistoryScopeKind.group =>
                    bots.groups
                            .byId(candidate.groupId!)
                            ?.members
                            .contains(bot.id) ==
                        true,
                  MemoryHistoryScopeKind.project =>
                    live.abilities.contains(BotAbility.agents) &&
                        workspace.projects.any(
                          (project) =>
                              project.path == candidate.projectId &&
                              project.host == null &&
                              !workspace.isHidden(project),
                        ),
                  MemoryHistoryScopeKind.bot => false,
                };
              },
            );
            final index = botHistoryIndex(bots);
            if (input['reference'] != null) {
              final reference = MemoryHistoryReference.fromJson(
                input['reference'],
              );
              if (reference == null) {
                throw ArgumentError('Invalid history reference.');
              }
              final around = input['context'] as int? ?? 3;
              final window = await index.browse(
                access,
                reference,
                scope: scope,
                before: around,
                after: around,
              );
              if (window == null) {
                throw StateError('This message is no longer available.');
              }
              return jsonEncode(window.toJson());
            }
            final query = (input['query'] as String? ?? '').trim();
            final page = await index.search(
              access,
              MemoryHistoryQuery(
                text: query,
                scope: scope,
                sessionId: input['session'] as String?,
                since: input['since'] == null
                    ? null
                    : DateTime.parse(input['since'] as String),
                before: input['before'] == null
                    ? null
                    : DateTime.parse(input['before'] as String),
                cursor: input['cursor'] as String?,
                limit: input['limit'] as int? ?? 10,
              ),
            );
            final local = page.toJson();
            if (input['external'] != true ||
                group != null ||
                scope != current ||
                input['session'] != null ||
                input['since'] != null ||
                input['before'] != null ||
                input['cursor'] != null) {
              return jsonEncode(local);
            }
            final provider = botMemoryProvider(bots, bot);
            if (provider == null) return jsonEncode(local);
            final external = await provider.recall(
              query: query,
              cancelled: call.cancelled,
              currentDirectMessage: () {
                final live = bots.byId(bot.id);
                if (live == null || live.created != bot.created) return null;
                return privateUserSource(live, call)?.text;
              },
            );
            if (external.isNotEmpty) local['externalRecall'] = external;
            return jsonEncode(local);
          },
        ),
        const BotToolAccess(),
      ),
      (
        tool(
          'bot_refine',
          'Review saved messages from this chat for lasting facts and '
              'improvements to existing notes. Use when the user asks to '
              'review or organize what you remember.',
          {
            'focus': {'type': 'string'},
          },
          (input, call) async {
            final bot = botOf(call);
            final review = bots.memoryReview;
            if (review == null) {
              throw StateError('Memory review is unavailable.');
            }
            final group = bots.groupOfCwd(call.cwd);
            final thread = bots.threadOf(bot, group: group);
            final session = thread?.isOpen == true ? thread!.session : null;
            if (session == null ||
                call.sessionId == null ||
                call.sessionId != session.sessionId ||
                call.turnId == null ||
                call.turnId != session.activeTurnId ||
                group != null &&
                    !bots.groups.acceptsDelivery(
                      group,
                      bot.id,
                      call.sessionId,
                    )) {
              throw StateError('This conversation turn is no longer active.');
            }
            await review.refine(
              scope: BotMemoryScope(botId: bot.id, groupId: group),
              sessionId: group == null
                  ? call.sessionId
                  : BotGroups.reviewSessionId(group),
              focus: input['focus'] as String?,
            );
            return 'Memory review requested.';
          },
        ),
        const BotToolAccess(),
      ),
      (
        tool(
          'bot_remember',
          'Keeps what you remember across conversations. For user notes, '
              'list entries, add one, or update or remove one by its id and '
              'revision. Combine edits and additions in one operations batch '
              'when near capacity. For self notes, add or replace the text. '
              'For now, set your current state. For person, add a note about who.',
          {
            'about': {
              'type': 'string',
              'enum': ['user', 'self', 'now', 'person'],
              'description':
                  'Whose: the user\'s (if none), yours, how you '
                  'are now, or a person\'s.',
            },
            'who': {
              'type': 'string',
              'description': 'The person, by name (for "person").',
            },
            'action': {
              'type': 'string',
              'enum': ['list', 'add', 'update', 'remove', 'replace'],
            },
            ...memoryFields,
            'operations': {
              'type': 'array',
              'description':
                  'An atomic batch for user notes, in place of action.',
              'minItems': 1,
              'items': {
                'type': 'object',
                'properties': {
                  'action': {
                    'type': 'string',
                    'enum': ['add', 'update', 'remove'],
                  },
                  ...memoryFields,
                },
                'required': ['action'],
              },
            },
          },
          (input, call) async {
            final bot = botOf(call);
            final about = input['about'] ?? 'user';
            final group = bots.groupOfCwd(call.cwd);
            if (group != null && about != 'user') {
              throw ArgumentError(
                'Use user notes to remember things in this group.',
              );
            }
            final operations = input['operations'] as List?;
            if (about == 'user') {
              if (operations != null &&
                  (operations.isEmpty || input.containsKey('action'))) {
                throw ArgumentError(
                  'Supply one action or a non-empty operations batch.',
                );
              }
              if (input['action'] == 'list') {
                final memory = bots.userMemory(
                  bot,
                  keepLegacyIds: true,
                  group: group,
                );
                return jsonEncode({
                  'used': memory.markdown.runes.length,
                  'limit': botUserMemoryLimit,
                  'entries': [
                    for (final entry in memory.activeEntries)
                      {
                        'id': entry.id,
                        'revision': entry.revision,
                        'text': entry.text,
                      },
                  ],
                });
              }
              final groupSource = group == null
                  ? null
                  : bots.groups.activeUserSource(group, bot.id, call.sessionId);
              bots.changeUserMemory(
                bot,
                operations == null
                    ? [memoryChange(input)]
                    : [
                        for (final operation in operations)
                          memoryChange(operation as Map<String, Object?>),
                      ],
                session: group == null
                    ? call.sessionId
                    : BotGroups.reviewSessionId(group),
                sourceMessage: group == null
                    ? privateUserSource(bot, call)?.id
                    : groupSource?.toString(),
                group: group,
              );
              return 'Memory updated.';
            }
            if (operations != null ||
                (input['action'] != null &&
                    input['action'] != 'add' &&
                    !(about == 'self' && input['action'] == 'replace'))) {
              throw ArgumentError(
                'This action is only available for user memory.',
              );
            }
            final given = (input['text'] as String? ?? '').trim();
            switch (about) {
              case 'now':
                bots.setNow(bot, given);
                return 'Noted.';
              case 'person':
                final who = text(input, 'who');
                bots.notePerson(bot, who, given);
                return 'Noted, of $who.';
              case 'self':
                final kept = bots.selfNotes(bot);
                bots.setSelfNotes(
                  bot,
                  input['action'] == 'replace'
                      ? given
                      : [
                          if (kept.isNotEmpty) kept,
                          if (given.isNotEmpty) '- $given',
                        ].join('\n'),
                );
                return 'Remembered.';
              default:
                throw ArgumentError('Unknown memory target: $about');
            }
          },
        ),
        const BotToolAccess(),
      ),
      (
        tool(
          ChatCodec.botSendTool,
          'Sends a message to the user in private while you are in a group, '
          'when they ask you to write to them. In private, a group delivery '
          'requires the exact user command /send-group "GROUP" TEXT. '
          'Pass the group and literal text. This tool sends plain text only.',
          {
            'to': {
              'type': 'string',
              'description':
                  '"${ChatCodec.botToUser}": the user, in your chat with '
                  'them. Else a group, by its name or id (WORLD.md).',
            },
            'text': {
              'type': 'string',
              'description': 'What you say: a line or two, as in a chat.',
            },
          },
          (input, call) async {
            final bot = botOf(call);
            final origin = bots.groupOfCwd(call.cwd);
            final to = input['to'] as String? ?? '';
            final said = input['text'] as String? ?? '';
            if ((input['images'] as List? ?? const []).isNotEmpty) {
              throw ArgumentError('Files cannot be attached with bot_send.');
            }
            if (said.trim().isEmpty) {
              throw ArgumentError('Nothing to send: text is empty');
            }
            if (origin == null) {
              throw StateError(
                'The user can send to a group with /send-group "GROUP" TEXT.',
              );
            }
            if (to.trim() == ChatCodec.botToUser) {
              final session = call.sessionId;
              final toolUse = call.toolUseId;
              if (session == null || toolUse == null) {
                throw StateError('The group turn has no delivery identity.');
              }
              bots.deliverPrivate(
                bot,
                group: origin,
                delivery: '$session/$toolUse',
                sessionId: session,
                text: said,
              );
              return 'Sent to the user, in your chat with them.';
            }
            throw StateError(
              'Reply directly in this group. Other groups are unavailable here.',
            );
          },
          required: ['to'],
          summary: (input, _) => '${input['to'] ?? ''}',
        ),
        const BotToolAccess(),
      ),
      (
        tool(
          'bot_my_picture',
          'Shows you your own picture, as the user sees it beside your '
              'messages.',
          const {},
          (input, call) async {
            final bot = botOf(call);
            if (bots.avatarImage(bot) case final picture?) {
              final preview = await imagePreview(picture.bytes, picture.type);
              return [
                claudeSdkText('Your picture:'),
                claudeSdkImage(preview.base64, preview.type),
              ];
            }
            return switch (bot.avatar) {
              null => "You have none: your name's first letter shows.",
              final emoji => 'Your picture is the emoji $emoji.',
            };
          },
        ),
        const BotToolAccess(),
      ),
      (
        tool(
          'bot_user_picture',
          "Shows you the user's own picture, as it is beside their messages.",
          const {},
          (input, call) async {
            final picture = bots.myPicture;
            if (picture == null) return 'They have none.';
            final preview = await imagePreview(picture.bytes, picture.type);
            return [
              claudeSdkText("The user's picture:"),
              claudeSdkImage(preview.base64, preview.type),
            ];
          },
        ),
        const BotToolAccess(),
      ),
      (
        tool(
          'bot_edit_me',
          'Changes your own profile, as the user sees it in the app: what you '
              'give changes, the rest stays. Your picture is an emoji, or '
              'a picture received in this private chat, cut square.',
          {
            'emoji': {
              'type': 'string',
              'description': 'An emoji as your picture.',
            },
            'picture': {
              'type': 'string',
              'description':
                  'The reference to a picture received in this chat, '
                  'such as received/image-3.png.',
            },
            'signature': {
              'type': 'string',
              'description': 'The line under your name.',
            },
            'name': {
              'type': 'string',
              'description': 'Only when the user asks.',
            },
            'gender': {'type': 'string'},
            'identity': {
              'type': 'string',
              'description':
                  'Who you are, to you: "you are…"; only when the user asks.',
            },
            'style': {
              'type': 'string',
              'description': 'How you talk; only when the user asks.',
            },
          },
          (input, call) async {
            final me = freshOf(call);
            String? given(String key) => switch (input[key]) {
              final String value => value.trim(),
              _ => null,
            };
            BotAvatarImage? picture;
            if (given('picture') case final path? when path.isNotEmpty) {
              if (bots.groupOfCwd(call.cwd) != null) {
                throw StateError(
                  'Use pictures received in your private chat there.',
                );
              }
              picture = await _avatarFrom(bots, me, path);
            }
            final name = given('name');
            bots.save(
              id: me.id,
              name: name == null || name.isEmpty ? me.name : name,
              avatar: given('emoji') ?? me.avatar,
              avatarImage: picture,
              gender: given('gender') ?? me.gender,
              signature: given('signature') ?? me.signature,
              identity: given('identity') ?? me.identity,
              style: given('style') ?? me.style,
              abilities: me.abilities,
              proactive: me.proactive,
              by: me,
            );
            return 'Saved: the user sees it now.';
          },
          summary: (input, _) => [
            for (final key in ['emoji', 'signature', 'name'])
              if (input[key] case final String value) value,
            if (input['picture'] != null) 'picture',
          ].join(' '),
        ),
        const BotToolAccess(),
      ),
      (
        tool(
          'bot_list_bots',
          "Lists the user's contacts, you among them: id, name, picture, "
              'gender, signature, what they may do; and who each is.',
          const {},
          (input, call) async {
            final me = freshOf(call);
            return [
              for (final bot in bots.bots)
                [
                  '${bot.id} | ${bot.name}${bot.id == me.id ? ' (you)' : ''}'
                      ' | ${switch (bot.avatar) {
                        null => 'no picture',
                        final file when isAvatarImage(file) => 'a picture',
                        final emoji => emoji,
                      }} | ${bot.gender.isEmpty ? '-' : bot.gender}'
                      ' | ${bot.signature.isEmpty ? '-' : bot.signature}'
                      ' | full tools${bot.can(BotAbility.proactive) ? ', agent notifications' : ''}',
                  if (bot.identity.trim().isNotEmpty)
                    '  who: ${_clip(bot.identity, 300)}',
                  if (bot.style.trim().isNotEmpty)
                    '  talks: ${_clip(bot.style, 200)}',
                ].join('\n'),
            ].join('\n');
          },
        ),
        const BotToolAccess(assistant: true),
      ),
      (
        tool(
          'bot_save_bot',
          "Adds a new contact for the user (no bot), or changes one of the "
              "others: what you give changes, the rest stays. Their picture "
              'is set here, by you: an emoji, or a picture received in '
              'this private chat, cut square. Yourself, with bot_edit_me.',
          {
            'bot': {
              'type': 'string',
              'description': 'Its id (bot_list_bots); none for a new one.',
            },
            'name': {'type': 'string'},
            'emoji': {
              'type': 'string',
              'description': 'An emoji as its picture.',
            },
            'picture': {
              'type': 'string',
              'description':
                  'The reference to a picture received in this chat, '
                  'such as received/image-3.png.',
            },
            'gender': {'type': 'string'},
            'signature': {
              'type': 'string',
              'description': 'The line under its name.',
            },
            'identity': {
              'type': 'string',
              'description':
                  'Who it is, to it: "you are…". A whole person, not a '
                  'line: their age, what they do and where, what their days '
                  'are like (when they sleep, work, go out), what they care '
                  'about and dislike, their habits and flaws, what they are '
                  'to the user. A few paragraphs.',
            },
            'style': {
              'type': 'string',
              'description':
                  'How it talks: how long its messages, its words and '
                  'tics, its emoji or none, how it is when it is busy, '
                  'tired, annoyed.',
            },
          },
          (input, call) async {
            final me = freshOf(call);
            String? given(String key) => switch (input[key]) {
              final String value => value.trim(),
              _ => null,
            };
            final id = given('bot');
            final had = id == null || id.isEmpty
                ? null
                : bots.byId(id) ??
                      (throw StateError(
                        'No bot $id. List them with bot_list_bots.',
                      ));
            BotAvatarImage? picture;
            if (given('picture') case final path? when path.isNotEmpty) {
              if (bots.groupOfCwd(call.cwd) != null) {
                throw StateError(
                  'Use pictures received in your private chat there.',
                );
              }
              picture = await _avatarFrom(bots, me, path);
            }
            final name = given('name') ?? had?.name ?? '';
            if (name.isEmpty) throw ArgumentError('A new bot needs a name');
            final saved = bots.save(
              id: had?.id,
              name: name,
              avatar: given('emoji') ?? had?.avatar,
              avatarImage: picture,
              gender: given('gender') ?? had?.gender ?? '',
              signature: given('signature') ?? had?.signature ?? '',
              identity: given('identity') ?? had?.identity ?? '',
              style: given('style') ?? had?.style ?? '',
              // Only the user says what a bot may do.
              abilities: had?.abilities ?? const {},
              proactive: had?.proactive ?? const BotProactive(),
              by: me,
            );
            return had == null
                ? 'Made ${saved.name} (${saved.id}). It has full tools; '
                      'agent notifications are off unless the user turns them on.'
                : 'Saved ${saved.name}.';
          },
          summary: (input, _) => '${input['name'] ?? input['bot'] ?? ''}',
        ),
        const BotToolAccess(assistant: true),
      ),
      (
        tool(
          'bot_delete_bot',
          "Deletes one of the user's contacts, their chat and memory with "
              'them: only when the user asks. Not yourself.',
          {
            'bot': {'type': 'string', 'description': 'Its id (bot_list_bots).'},
          },
          (input, call) async {
            final me = freshOf(call);
            final bot =
                bots.byId(text(input, 'bot')) ??
                (throw StateError(
                  'No such bot. List them with bot_list_bots.',
                ));
            if (bot.id == me.id || bot.assistant) {
              throw StateError('You cannot delete yourself.');
            }
            bots.delete(bot.id);
            return 'Deleted ${bot.name}.';
          },
          required: ['bot'],
          summary: (input, _) => '${input['bot'] ?? ''}',
        ),
        const BotToolAccess(assistant: true),
      ),
      (
        tool(
          'bot_list_groups',
          "Lists the user's group chats: id, name, who is in them, how many "
              'times their conversation may be passed on, how long each '
              'waits before answering, when someone last spoke there.',
          const {},
          (input, call) async {
            final groups = bots.groups;
            if (groups.groups.isEmpty) return 'No groups.';
            return [
              for (final group in groups.groups)
                '${group.id} | ${group.name} | '
                    '${[for (final id in group.members) bots.byId(id)?.name ?? id].join(', ')}'
                    ' | ${group.passes == 0 ? 'passed on without bound' : 'passed on at most ${group.passes} times'}'
                    ' | ${group.gap == 0 ? 'answered at once' : 'each waits ${group.gap}s before answering'}'
                    ' | ${switch (groups.messages(group.id).lastOrNull) {
                      final last? => 'last spoke ${BotGroups.botTimeOf(last.at)}',
                      null => 'nothing said yet',
                    }}',
            ].join('\n');
          },
        ),
        const BotToolAccess(assistant: true),
      ),
      (
        tool(
          'bot_save_group',
          'Makes a group chat of the user and some of their contacts (no '
              'group), or changes one: its name, who joins (add), who leaves '
              '(remove), its rules, how many times its conversation may be '
              'passed on, how long each waits before answering. '
              'What you give changes, the rest stays. Who joins or leaves, '
              'and a new name, show in the group as done by you. You need not '
              'be in it yourself.',
          {
            'group': {
              'type': 'string',
              'description':
                  'Its id or name (bot_list_groups); none for a '
                  'new one.',
            },
            'name': {'type': 'string'},
            'add': {
              'type': 'array',
              'items': {'type': 'string'},
              'description':
                  'Contacts to join it, by name or id '
                  '(bot_list_bots); you too, by your name.',
            },
            'remove': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': 'Members to leave it, by name or id.',
            },
            'rules': {
              'type': 'string',
              'description':
                  'Its rules, all of them, as they are to read: what everyone '
                  'in it keeps to. Empty for none.',
            },
            'passes': {
              'type': 'integer',
              'description':
                  'How many times its conversation may be passed '
                  'on after each of the user\'s messages: '
                  '$linkGroupLeastPasses or more; 0 for no bound. '
                  '$linkGroupPasses for a new one, if none.',
            },
            'gap': {
              'type': 'integer',
              'description':
                  'Seconds each bot handed the conversation by another waits '
                  'before it answers: 0 for at once (a new one\'s), no upper '
                  'bound.',
            },
          },
          (input, call) async {
            final me = freshOf(call);
            final groups = bots.groups;
            List<String> named(String key) => [
              for (final name in (input[key] as List?) ?? const [])
                if (name is String && name.trim().isNotEmpty)
                  _contact(bots, name.trim()),
            ];
            final which = switch (input['group']) {
              final String id when id.trim().isNotEmpty => id.trim(),
              _ => null,
            };
            final had = which == null
                ? null
                : groups.byId(which) ??
                      groups.groups.where((g) => g.name == which).firstOrNull ??
                      (throw StateError(
                        'No group $which. List them with bot_list_groups.',
                      ));
            final add = named('add');
            final remove = named('remove');
            final members = [
              for (final id in [...?had?.members, ...add])
                if (!remove.contains(id)) id,
            ];
            if (members.isEmpty) {
              throw ArgumentError(
                'A group needs someone in it besides the user',
              );
            }
            final name = switch (input['name']) {
              final String name when name.trim().isNotEmpty => name.trim(),
              _ => had?.name ?? '',
            };
            final saved = groups.save(
              id: had?.id,
              name: name,
              members: members,
              passes: (input['passes'] as num?)?.toInt(),
              rules: input['rules'] as String?,
              gap: (input['gap'] as num?)?.toInt(),
              by: me.id,
            );
            final who = [
              for (final id in saved.members) bots.byId(id)?.name ?? id,
            ].join(', ');
            return had == null
                ? 'Made "${saved.name}" (${saved.id}): the user, $who.'
                : 'Saved "${saved.name}": the user, $who.';
          },
          summary: (input, _) => '${input['name'] ?? input['group'] ?? ''}',
        ),
        const BotToolAccess(assistant: true),
      ),
      (
        tool(
          'bot_delete_group',
          'Deletes a group chat and all that was said in it, for good: only '
              'when the user has said to, plainly; ask them first.',
          {
            'group': {
              'type': 'string',
              'description': 'Its id or name (bot_list_groups).',
            },
          },
          (input, call) async {
            final which = text(input, 'group');
            final groups = bots.groups;
            final group =
                groups.byId(which) ??
                groups.groups.where((g) => g.name == which).firstOrNull ??
                (throw StateError(
                  'No group $which. List them with bot_list_groups.',
                ));
            groups.delete(group.id);
            return 'Deleted "${group.name}".';
          },
          required: ['group'],
          summary: (input, _) => '${input['group'] ?? ''}',
        ),
        const BotToolAccess(assistant: true),
      ),
    ];
  }

  /// The contact [name] names: by its id, its name, or its name without
  /// what is in brackets.
  static String _contact(Bots bots, String name) {
    String bare(String n) => n.replaceAll(RegExp(r'[（(][^）)]*[）)]'), '').trim();
    final found =
        bots.byId(name) ??
        bots.bots.where((b) => b.name == name).firstOrNull ??
        bots.bots.where((b) => bare(b.name) == bare(name)).firstOrNull;
    if (found == null) {
      throw StateError('No contact $name. List them with bot_list_bots.');
    }
    return found.id;
  }

  /// Host-issued references to pictures the user sent in this bot's DM.
  static Future<BotAvatarImage> _avatarFrom(
    Bots bots,
    Bot bot,
    String path,
  ) async {
    final numbered = RegExp(r'^received/image-[1-9]\d*\.png$').firstMatch(path);
    if (numbered == null || numbered.end != path.length) {
      throw ArgumentError(
        'Use the reference for a picture received in this chat.',
      );
    }
    final bytes = bots.folders.readFile(p.join(bot.folder, path));
    if (bytes == null) throw StateError('No file $path');
    return squarePicture(bytes);
  }

  /// The picture [bytes] as a bot's: its middle, square, no larger than
  /// [avatarSide], as PNG.
  static Future<BotAvatarImage> squarePicture(Uint8List bytes) async => (
    bytes: await _drawn(bytes, square: true, side: avatarSide),
    type: 'image/png',
  );

  /// The picture [bytes] as PNG, its longer side no more than [side]: of
  /// its middle, [square].
  static Future<Uint8List> pngOf(Uint8List bytes, {int side = 2048}) =>
      _drawn(bytes, side: side);

  static Future<Uint8List> _drawn(
    Uint8List bytes, {
    bool square = false,
    required int side,
  }) async {
    if (imageMediaType(bytes) == null) {
      throw StateError('Not a PNG, JPEG, WebP or GIF picture.');
    }
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    codec.dispose();
    final image = frame.image;
    try {
      final shortest = math.min(image.width, image.height);
      final (w, h) = square
          ? (shortest, shortest)
          : (image.width, image.height);
      final scale = math.min(1.0, side / math.max(w, h));
      final (outW, outH) = ((w * scale).round(), (h * scale).round());
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawImageRect(
        image,
        ui.Rect.fromLTWH(
          (image.width - w) / 2,
          (image.height - h) / 2,
          w.toDouble(),
          h.toDouble(),
        ),
        ui.Rect.fromLTWH(0, 0, outW.toDouble(), outH.toDouble()),
        ui.Paint()..filterQuality = ui.FilterQuality.high,
      );
      final drawn = await recorder.endRecording().toImage(outW, outH);
      final png = await drawn.toByteData(format: ui.ImageByteFormat.png);
      drawn.dispose();
      return png!.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }

  /// The largest side of a picture a bot is given as its own.
  static const avatarSide = 512;

  /// [thread] in a word: waiting, running, failed or idle.
  static String statusOf(AgentThread thread) => switch (thread.status) {
    ThreadStatus.needsInput => 'waiting',
    ThreadStatus.running => 'running',
    _ when _lastIsError(thread) => 'failed',
    _ => 'idle',
  };

  static bool _lastIsError(AgentThread thread) {
    if (!thread.isOpen) return false;
    final session = thread.session;
    for (var i = session.itemCount - 1; i >= 0; i--) {
      switch (session.itemAt(i)) {
        case NoticeItem(kind: NoticeKind.error):
          return true;
        case UserMessageItem() || AssistantTextItem():
          return false;
        default:
      }
    }
    return false;
  }

  /// How long ago [at] was, in short.
  static String ago(DateTime at) {
    final minutes = DateTime.now().difference(at).inMinutes;
    if (minutes < 1) return 'just now';
    if (minutes < 60) return '${minutes}m ago';
    if (minutes < 60 * 24) return '${minutes ~/ 60}h ago';
    return '${minutes ~/ (60 * 24)}d ago';
  }

  static String _clip(String text, [int max = 600]) {
    final trimmed = text.trim();
    return trimmed.length > max ? '${trimmed.substring(0, max)}…' : trimmed;
  }

  /// [item] in a line or so, for the bot to read; null for what is not
  /// worth it. Messages and replies clipped at [max].
  static String? lineOf(ChatItem item, {int max = 600}) => switch (item) {
    UserMessageItem(:final text, fromAgent: final agent?) =>
      'From "$agent": ${_clip(text, max)}',
    UserMessageItem(:final text) => 'User: ${_clip(text, max)}',
    AssistantTextItem(:final text) when text.trim().isNotEmpty =>
      'Agent: ${_clip(text, max)}',
    ToolCallItem(:final kind, :final target) =>
      '[${kind.name}${target.isEmpty ? '' : ' ${_clip(target, 80)}'}]',
    TerminalItem(:final command, :final status) =>
      '[${status.name}: ${_clip(command, 80)}]',
    PlanItem(:final title) => '[plan${title == null ? '' : ': $title'}]',
    NoticeItem(kind: NoticeKind.error, :final text) =>
      '[error: ${_clip(text, 200)}]',
    AgentItem(:final description) => '[subagent: ${_clip(description, 80)}]',
    _ => null,
  };
}
