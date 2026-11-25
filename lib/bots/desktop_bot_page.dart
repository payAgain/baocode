import 'dart:async';

import 'package:bao_link/bao_link.dart' show LinkMethods, LinkRemoteException;
import 'package:flutter/material.dart';

import '../chat/chat_keys.dart';
import '../chat/chat_models.dart' show ChatItem;
import '../chat/chat_session.dart';
import '../chat/composer/composer.dart';
import '../chat/stop_confirmation.dart';
import '../chat/widgets/user_message_bubble.dart';
import '../kernel/kernel_types.dart' show KernelHealthStatus;
import '../keybindings/chat_keybindings.dart';
import '../l10n/l10n.dart';
import '../link/bot_memory_management.dart';
import '../theme/app_theme.dart';
import '../workspace/editor_launcher.dart' show openExternal;
import '../workspace/session_tools.dart';
import '../workspace/workspace.dart';
import 'bot.dart';
import 'bots.dart';
import 'desktop_bot_messages.dart';

/// A bot's private chat. It uses the same conversation the phone opens.
class DesktopBotPage extends StatefulWidget {
  const DesktopBotPage({
    super.key,
    required this.bots,
    this.botId,
    this.onSettings,
    required this.onBack,
    required this.onOpenChat,
  });

  final Bots bots;

  /// The ID of the selected bot, or null for the assistant.
  final String? botId;
  final VoidCallback? onSettings;
  final VoidCallback onBack;
  final ValueChanged<String> onOpenChat;

  @override
  State<DesktopBotPage> createState() => _DesktopBotPageState();
}

class _DesktopBotPageState extends State<DesktopBotPage> with ChatKeyTarget {
  final _scroll = ScrollController();
  ChatSession? _session;
  List<ChatItem> _archived = const [];
  bool _loadingArchived = false;
  bool _workspaceReady = false;
  bool _syncScheduled = false;
  Bot? get _bot => switch (widget.botId) {
    final id? => widget.bots.byId(id),
    null => widget.bots.bots.where((bot) => bot.assistant).firstOrNull,
  };

  @override
  void initState() {
    super.initState();
    _watch(widget.bots);
  }

  @override
  void didUpdateWidget(DesktopBotPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.bots, widget.bots)) {
      _unwatch(oldWidget.bots);
      _workspaceReady = false;
      _bind(null);
      _watch(widget.bots);
    } else if (oldWidget.botId != widget.botId) {
      _bind(null);
      _scheduleSync();
    }
  }

  void _watch(Bots bots) {
    bots.addListener(_scheduleSync);
    bots.workspace.addListener(_scheduleSync);
    unawaited(
      bots.workspace.loaded.then((_) {
        if (!mounted || !identical(widget.bots, bots)) return;
        _workspaceReady = true;
        _scheduleSync();
      }),
    );
  }

  void _unwatch(Bots bots) {
    bots.removeListener(_scheduleSync);
    bots.workspace.removeListener(_scheduleSync);
  }

  void _scheduleSync() {
    if (_syncScheduled) return;
    _syncScheduled = true;
    // Resolving/opening the thread can itself notify the workspace.
    scheduleMicrotask(() {
      if (!mounted) return;
      final bot = _bot;
      final session = _workspaceReady && bot != null
          ? widget.bots.threadFor(bot).session
          : null;
      _bind(session);
      _syncScheduled = false;
      setState(() {});
    });
  }

  void _bind(ChatSession? session) {
    if (identical(_session, session)) return;
    _session?.removeListener(_sessionChanged);
    _session?.detach();
    _session = session;
    _archived = const [];
    _loadingArchived = false;
    session?.addListener(_sessionChanged);
    session?.attach();
    if ((session, _bot) case (final session?, final bot?)) {
      _loadingArchived = true;
      unawaited(_loadArchive(bot, session));
    }
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  Future<void> _loadArchive(Bot bot, ChatSession session) async {
    try {
      final items = await loadPrivateBotHistory(widget.bots, bot);
      if (mounted && identical(_session, session)) {
        setState(() => _archived = items);
      }
    } finally {
      if (mounted && identical(_session, session)) {
        setState(() => _loadingArchived = false);
      }
    }
  }

  void _sessionChanged() => setState(() {});

  void _activateArchived(Bot bot, ChatSession? session, AgentThread thread) {
    if (!identical(_session, session) || _bot?.id != bot.id) return;
    try {
      widget.bots.activateConversation(bot, thread);
    } on StateError catch (error) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  bool _canStop(ChatSession session) =>
      identical(_session, session) && session.isStreaming;

  Future<void> _refine(Bot bot, String focus) async {
    final management = BotMemoryManagement(widget.bots, reviewer: 'desktop');
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    String message;
    try {
      await management.call(LinkMethods.refineBotMemory, {
        'bot': bot.id,
        'focus': focus,
      });
      message = zh ? '已安排复盘。' : 'Review queued.';
    } on LinkRemoteException catch (error) {
      message = error.message;
    }
    if (mounted) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Object? chatContextKey(String key) => switch (key) {
    ChatContextKeys.requestInProgress => _session?.isStreaming ?? false,
    _ => null,
  };

  @override
  Map<String, VoidCallback> get chatCommands => {
    if (_session case final session? when _canStop(session))
      ChatCommandIds.cancel: () => stopTurn(context, session),
  };

  @override
  void dispose() {
    _unwatch(widget.bots);
    _session?.removeListener(_sessionChanged);
    _session?.detach();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final bot = _bot;
    final session = _session;
    final archives = bot == null || !_workspaceReady
        ? const <AgentThread>[]
        : widget.bots
              .privateHistory(bot)
              .reversed
              .where(
                (thread) => widget.bots.canActivateConversation(bot, thread),
              )
              .toList();
    final loading =
        !_workspaceReady ||
        (bot != null && session == null) ||
        session?.loadingHistory == true;
    if (!loading && bot != null && widget.bots.unread(bot) > 0) {
      final bots = widget.bots;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            identical(widget.bots, bots) &&
            _bot?.id == bot.id &&
            identical(_session, session)) {
          bots.seen(bot);
        }
      });
    }
    return Material(
      color: AppColors.conversationSurface,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 4, 18, 4),
            child: Row(
              children: [
                IconButton(
                  tooltip: l10n.chatBack,
                  onPressed: widget.onBack,
                  icon: const BackButtonIcon(),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        bot?.name ?? l10n.chatConversation,
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (bot != null)
                        Text(
                          [
                            l10n.desktopBotPrivateChat,
                            if (bot.signature.isNotEmpty) bot.signature,
                          ].join(' · '),
                          style: TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 12,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                if (bot != null && archives.isNotEmpty)
                  PopupMenuButton<AgentThread>(
                    tooltip:
                        Localizations.localeOf(context).languageCode == 'zh'
                        ? '继续归档对话'
                        : 'Resume archived conversation',
                    icon: const Icon(Icons.history),
                    onSelected: (thread) =>
                        _activateArchived(bot, session, thread),
                    itemBuilder: (context) => [
                      for (final thread in archives)
                        PopupMenuItem(
                          value: thread,
                          child: Text(thread.localizedTitle(l10n)),
                        ),
                    ],
                  ),
                if (widget.onSettings != null && bot != null)
                  TextButton.icon(
                    onPressed: widget.onSettings,
                    icon: const Icon(Icons.tune, size: 18),
                    label: Text(
                      Localizations.localeOf(context).languageCode == 'zh'
                          ? 'Bot 设置'
                          : 'Bot settings',
                    ),
                  ),
              ],
            ),
          ),
          Divider(height: 1, color: AppColors.partBorder),
          Expanded(
            child: loading
                ? Center(
                    child: Text(
                      l10n.chatLoadingHistory,
                      style: TextStyle(color: AppColors.textMuted),
                    ),
                  )
                : session == null || bot == null
                ? const SizedBox.shrink()
                : _history(context, bot, session),
          ),
          if (session?.health.status == KernelHealthStatus.failed)
            TextButton.icon(
              onPressed: session!.restart,
              icon: const Icon(Icons.error_outline),
              label: Text(l10n.healthRetry),
            ),
          if (bot != null && session != null)
            _centered(
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 4, 18, 16),
                child: ChatComposer(
                  key: ObjectKey(session),
                  session: session,
                  draft: session.draft,
                  showSessionControls: false,
                  privatePromptText: desktopBotPromptText,
                  preserveText: true,
                  canStop: () => _canStop(session),
                  canSubmit: () =>
                      identical(_session, session) &&
                      _bot?.id == bot.id &&
                      !session.loadingHistory &&
                      session.health.status != KernelHealthStatus.failed &&
                      session.canSend,
                  onIntercept: (message) {
                    final bots = widget.bots;
                    final focus =
                        message.images.isEmpty && message.mentions.isEmpty
                        ? refineBotFocus(message.text)
                        : null;
                    if (focus != null && bots.memoryReview != null) {
                      unawaited(_refine(bot, focus));
                    } else {
                      bots.sendPrivate(
                        bot,
                        message,
                        notes: bots.suggestionNotes(bot, wanted: false),
                      );
                    }
                    if (_scroll.hasClients) _scroll.jumpTo(0);
                    return true;
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _history(BuildContext context, Bot bot, ChatSession session) {
    final items = privateBotTimeline(
      widget.bots,
      bot,
      session,
      _archived,
      includeRecallSources: true,
    );
    final messages = desktopBotMessages(
      items.map((entry) => entry.item),
      hasEarlier: false,
    );
    final earlier = session.hasEarlierHistory || _loadingArchived;
    if (messages.isEmpty && !earlier) {
      return Center(
        child: Icon(Icons.chat_bubble_outline, color: AppColors.textFaint),
      );
    }
    return SelectionArea(
      child: ListView.builder(
        controller: _scroll,
        reverse: true,
        padding: const EdgeInsets.symmetric(vertical: 12),
        itemCount: messages.length + (earlier ? 1 : 0),
        itemBuilder: (context, index) => _centered(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
            child: index == messages.length
                ? Center(
                    child: TextButton(
                      onPressed: session.loadingEarlier
                          ? null
                          : () => unawaited(session.loadEarlier()),
                      child: Text(
                        session.loadingEarlier
                            ? context.l10n.chatLoadingHistory
                            : context.l10n.chatLoadEarlier,
                      ),
                    ),
                  )
                : _message(context, messages[messages.length - index - 1]),
          ),
        ),
      ),
    );
  }

  Widget _message(BuildContext context, DesktopBotMessage message) {
    if (message.kind == DesktopBotMessageKind.chat) {
      final thread = _projectChat(message.text);
      if (thread == null) return const SizedBox.shrink();
      return Align(
        alignment: AlignmentDirectional.centerStart,
        child: OutlinedButton.icon(
          onPressed: () {
            if (_projectChat(message.text) case final current?) {
              widget.onOpenChat(SessionTools.idOf(current));
            }
          },
          icon: const Icon(Icons.chat_bubble_outline, size: 16),
          label: Text(
            thread.localizedTitle(context.l10n),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    }
    final user = message.kind == DesktopBotMessageKind.user;
    final narration = message.kind == DesktopBotMessageKind.narration;
    return Align(
      alignment: user
          ? AlignmentDirectional.centerEnd
          : AlignmentDirectional.centerStart,
      child: FractionallySizedBox(
        widthFactor: 0.88,
        alignment: user
            ? AlignmentDirectional.centerEnd
            : AlignmentDirectional.centerStart,
        child: Align(
          alignment: user
              ? AlignmentDirectional.centerEnd
              : AlignmentDirectional.centerStart,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: user ? AppColors.bubbleFill : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (message.textWithAttachments case final text?)
                    UserMessageBubble(text: text)
                  else if (message.text.isNotEmpty)
                    Text(
                      message.text,
                      style: TextStyle(
                        color: narration ? AppColors.textMuted : AppColors.text,
                        fontStyle: narration
                            ? FontStyle.italic
                            : FontStyle.normal,
                      ),
                    ),
                  if (message.recallSources case final recall?)
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final sequence in recall.sequences)
                          TextButton(
                            onPressed: () => unawaited(
                              _openRecallSource(recall.delivery, sequence),
                            ),
                            child: Text(
                              _tr('Source #$sequence', '原话 #$sequence'),
                            ),
                          ),
                      ],
                    ),
                  for (final image in message.images)
                    Image.memory(
                      image.bytes,
                      fit: BoxFit.contain,
                      height: 180,
                      errorBuilder: (context, error, stackTrace) =>
                          const Icon(Icons.broken_image_outlined),
                    ),
                  if (message.queued)
                    Text(
                      context.l10n.queuedMessages(1),
                      style: TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  if (message.imageUrl case final url?)
                    TextButton.icon(
                      // Remote content loads only when the user opens it.
                      onPressed: () => unawaited(openExternal(url.toString())),
                      icon: const Icon(Icons.image_outlined, size: 16),
                      label: Text(context.l10n.fileLinkOpenInBrowser),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _tr(String en, String zh) =>
      Localizations.localeOf(context).languageCode == 'zh' ? zh : en;

  Future<void> _openRecallSource(String delivery, int sequence) async {
    final bot = _bot;
    if (bot == null) return;
    final bots = widget.bots;
    final window = await bots.openGroupRecallSource(bot, delivery, sequence);
    if (!mounted || !identical(widget.bots, bots) || _bot?.id != bot.id) return;
    final group = window?.anchor.reference.scope.groupId;
    await showDialog<void>(
      context: context,
      builder: (dialog) => ListenableBuilder(
        listenable: Listenable.merge([bots, bots.groups]),
        builder: (context, _) {
          final available =
              window != null &&
              bots.canOpenGroupRecallSource(bot, delivery, sequence);
          return AlertDialog(
            title: Text(
              available
                  ? '${bots.groups.byId(group!)!.name} · #$sequence'
                  : _tr('Source message unavailable', '原话已不可用'),
            ),
            content: available
                ? SizedBox(
                    width: 560,
                    child: SelectionArea(
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final message in [
                            ...window.before,
                            window.anchor,
                            ...window.after,
                          ])
                            ListTile(
                              selected: identical(message, window.anchor),
                              title: Text(message.text),
                              subtitle: Text('#${message.sequence}'),
                            ),
                        ],
                      ),
                    ),
                  )
                : null,
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog),
                child: Text(MaterialLocalizations.of(dialog).closeButtonLabel),
              ),
            ],
          );
        },
      ),
    );
  }

  AgentThread? _projectChat(String id) {
    final workspace = widget.bots.workspace;
    final thread = SessionTools.threadOf(workspace, id);
    if (thread == null ||
        thread.archived ||
        !workspace.listsInSidebar(thread)) {
      return null;
    }
    return thread;
  }

  Widget _centered(Widget child) => Align(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 780),
      child: SizedBox(width: double.infinity, child: child),
    ),
  );
}
