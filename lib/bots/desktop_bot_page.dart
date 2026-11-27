import 'dart:async';

import 'package:bao_link/bao_link.dart' show LinkMethods, LinkRemoteException;
import 'package:flutter/material.dart';

import '../chat/chat_keys.dart';
import '../chat/chat_models.dart' show ChatItem;
import '../chat/chat_session.dart';
import '../chat/composer/composer.dart';
import '../chat/stop_confirmation.dart';
import '../chat/widgets/image_thumbnails.dart';
import '../chat/widgets/scroll_edge_fade.dart';
import '../chat/widgets/user_message_bubble.dart';
import '../kernel/kernel_types.dart' show KernelHealthStatus;
import '../keybindings/chat_keybindings.dart';
import '../l10n/l10n.dart';
import '../link/bot_memory_management.dart';
import '../settings/pages/settings_widgets.dart' show SettingsColors;
import '../theme/app_theme.dart';
import '../workspace/editor_launcher.dart' show openExternal;
import '../workspace/session_tools.dart';
import '../workspace/workspace.dart';
import 'bot.dart';
import 'bots.dart';
import 'desktop_bot_editor_ui.dart';
import 'desktop_bot_message_row.dart';
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
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    final botEmoji =
        bot?.avatar != null &&
            bot!.avatar!.isNotEmpty &&
            !isAvatarImage(bot.avatar)
        ? bot.avatar
        : null;
    Widget headerAvatar(double size) => BotAvatarBadge(
      label: bot?.name ?? 'Bot',
      emoji: botEmoji,
      icon: bot?.assistant == true ? Icons.smart_toy_outlined : null,
      accent: bot?.assistant == true,
      size: size,
    );
    return Material(
      color: AppColors.conversationSurface,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 16, 8),
            child: Row(
              children: [
                IconButton(
                  tooltip: l10n.chatBack,
                  style: botToolbarIconButtonStyle(context),
                  onPressed: widget.onBack,
                  icon: const BackButtonIcon(),
                ),
                const SizedBox(width: 8),
                if (bot != null) ...[
                  headerAvatar(32),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        bot?.name ?? l10n.chatConversation,
                        style: TextStyle(
                          fontSize: 14,
                          color: SettingsColors.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (bot != null) ...[
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Flexible(
                              fit: FlexFit.loose,
                              child: BotMetaPill(
                                label: l10n.desktopBotPrivateChat,
                                tone: BotEditorTone.accent,
                              ),
                            ),
                            if (bot.signature.isNotEmpty) ...[
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  bot.signature,
                                  style: TextStyle(
                                    color: SettingsColors.textSecondary,
                                    fontSize: 12,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                if (bot != null && archives.isNotEmpty) ...[
                  PopupMenuButton<AgentThread>(
                    tooltip: zh
                        ? '继续归档对话'
                        : 'Resume archived conversation',
                    icon: const Icon(Icons.history, size: 17),
                    iconColor: SettingsColors.textSecondary,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 30,
                      height: 30,
                    ),
                    color: AppColors.surfaceRaised,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                      side: BorderSide(color: SettingsColors.stroke),
                    ),
                    onSelected: (thread) =>
                        _activateArchived(bot, session, thread),
                    itemBuilder: (context) => [
                      for (final thread in archives)
                        PopupMenuItem(
                          value: thread,
                          child: Row(
                            children: [
                              Icon(
                                Icons.history,
                                size: 15,
                                color: SettingsColors.textSecondary,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  thread.localizedTitle(l10n),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(width: 6),
                ],
                if (widget.onSettings != null && bot != null)
                  TextButton.icon(
                    style: botEditorTonalButtonStyle(context),
                    onPressed: widget.onSettings,
                    icon: const Icon(Icons.tune, size: 15),
                    label: Text(zh ? 'Bot 设置' : 'Bot settings'),
                  ),
              ],
            ),
          ),
          Container(height: 1, color: SettingsColors.divider),
          Expanded(
            child: loading
                ? Center(
                    child: Text(
                      l10n.chatLoadingHistory,
                      style: TextStyle(color: SettingsColors.textSecondary),
                    ),
                  )
                : session == null || bot == null
                ? const SizedBox.shrink()
                : _history(context, bot, session),
          ),
          if (session?.health.status == KernelHealthStatus.failed)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
              child: _centered(
                BotEditorNotice(
                  tone: BotEditorTone.danger,
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton.icon(
                      style: botEditorTonalButtonStyle(
                        context,
                        destructive: true,
                      ),
                      onPressed: session!.restart,
                      icon: const Icon(Icons.refresh, size: 15),
                      label: Text(l10n.healthRetry),
                    ),
                  ),
                ),
              ),
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
    final emoji =
        bot.avatar != null &&
            bot.avatar!.isNotEmpty &&
            !isAvatarImage(bot.avatar)
        ? bot.avatar
        : null;
    if (messages.isEmpty && !earlier) {
      return BotEmptyState(
        label: bot.name,
        emoji: emoji,
        icon: bot.assistant ? Icons.smart_toy_outlined : null,
        title: bot.name,
        description: bot.signature.isNotEmpty
            ? bot.signature
            : _tr(
                'Start a private conversation with ${bot.name}.',
                '开始与 ${bot.name} 私聊。',
              ),
      );
    }
    return SelectionArea(
      child: ScrollEdgeFade(
        child: ListView.builder(
          controller: _scroll,
          reverse: true,
          padding: const EdgeInsets.symmetric(vertical: 14),
          itemCount: messages.length + (earlier ? 1 : 0),
          itemBuilder: (context, index) => _centered(
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: index == messages.length
                  ? Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Center(
                        child: TextButton(
                          style: botEditorTonalButtonStyle(context),
                          onPressed: session.loadingEarlier
                              ? null
                              : () => unawaited(session.loadEarlier()),
                          child: Text(
                            session.loadingEarlier
                                ? context.l10n.chatLoadingHistory
                                : context.l10n.chatLoadEarlier,
                          ),
                        ),
                      ),
                    )
                  : _buildMessageAt(context, bot, emoji, messages, index),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMessageAt(
    BuildContext context,
    Bot bot,
    String? emoji,
    List<DesktopBotMessage> messages,
    int reverseIndex,
  ) {
    final i = messages.length - reverseIndex - 1;
    final message = messages[i];
    final prev = i > 0 ? messages[i - 1] : null;
    final isUser = message.kind == DesktopBotMessageKind.user;
    final prevIsUser = prev?.kind == DesktopBotMessageKind.user;
    final grouped = shouldGroupBotMessage(
      sameSender:
          prev != null &&
          prev.kind != DesktopBotMessageKind.chat &&
          message.kind != DesktopBotMessageKind.chat &&
          isUser == prevIsUser,
      previousAt: prev?.sentAt,
      currentAt: message.sentAt,
    );
    return _message(
      context,
      bot,
      emoji,
      message,
      grouped: grouped,
    );
  }

  Widget _message(
    BuildContext context,
    Bot bot,
    String? emoji,
    DesktopBotMessage message, {
    bool grouped = false,
  }) {
    if (message.kind == DesktopBotMessageKind.chat) {
      final thread = _projectChat(message.text);
      if (thread == null) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton.icon(
            style: botEditorOutlinedButtonStyle(context),
            onPressed: () {
              if (_projectChat(message.text) case final current?) {
                widget.onOpenChat(SessionTools.idOf(current));
              }
            },
            icon: const Icon(Icons.chat_bubble_outline, size: 15),
            label: Text(
              thread.localizedTitle(context.l10n),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      );
    }
    final isUser = message.kind == DesktopBotMessageKind.user;
    final recallStyle = botEditorTonalButtonStyle(context).copyWith(
      minimumSize: const WidgetStatePropertyAll(Size(0, 28)),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      ),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    return DesktopBotMessageRow(
      mine: isUser,
      sender: isUser ? null : bot.name,
      avatar: isUser
          ? null
          : BotAvatarBadge(
              label: bot.name,
              emoji: emoji,
              icon: bot.assistant ? Icons.smart_toy_outlined : null,
              accent: bot.assistant,
              size: 28,
            ),
      sentAt: message.sentAt,
      grouped: grouped,
      bare: message.textWithAttachments != null,
      content: [
        if (message.textWithAttachments case final text?)
          UserMessageBubble(text: text)
        else if (message.text.isNotEmpty)
          DesktopBotMessageText(
            message.text,
            narration: message.kind == DesktopBotMessageKind.narration,
          ),
        if (message.recallSources case final recall?)
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final sequence in recall.sequences)
                TextButton(
                  style: recallStyle,
                  onPressed: () =>
                      unawaited(_openRecallSource(recall.delivery, sequence)),
                  child: Text(_tr('Source #$sequence', '原话 #$sequence')),
                ),
            ],
          ),
        if (message.queued)
          Text(
            context.l10n.queuedMessages(1),
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: SettingsColors.textSecondary,
            ),
          ),
      ],
      media: message.images.isEmpty && message.imageUrl == null
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (message.images.isNotEmpty)
                  ImageThumbnails(images: message.images),
                if (message.imageUrl case final url?)
                  TextButton.icon(
                    style: recallStyle,
                    // External content loads only when the user opens it.
                    onPressed: () => unawaited(openExternal(url.toString())),
                    icon: const Icon(Icons.image_outlined, size: 15),
                    label: Text(context.l10n.fileLinkOpenInBrowser),
                  ),
              ],
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
          return BotModernDialog(
            width: 560,
            icon: Icons.format_quote_outlined,
            title: available
                ? '${bots.groups.byId(group!)!.name} · #$sequence'
                : _tr('Source message unavailable', '原话已不可用'),
            body: available
                ? Material(
                    color: SettingsColors.card,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(color: SettingsColors.stroke),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: SelectionArea(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final (i, message)
                              in [
                                ...window.before,
                                window.anchor,
                                ...window.after,
                              ].indexed) ...[
                            if (i > 0)
                              Container(
                                height: 1,
                                color: SettingsColors.divider,
                              ),
                            ColoredBox(
                              color: identical(message, window.anchor)
                                  ? AppColors.accent.withValues(alpha: 0.12)
                                  : Colors.transparent,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 10,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  spacing: 4,
                                  children: [
                                    BotMetaPill(
                                      label: '#${message.sequence}',
                                      tone: identical(message, window.anchor)
                                          ? BotEditorTone.accent
                                          : BotEditorTone.neutral,
                                    ),
                                    Text(
                                      message.text,
                                      style: TextStyle(
                                        fontSize: 13.5,
                                        height: 1.5,
                                        color: SettingsColors.textPrimary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  )
                : Text(
                    _tr(
                      'This referenced group message is no longer available.',
                      '引用的群聊原话已不存在或无法查看。',
                    ),
                    style: TextStyle(
                      fontSize: 13.5,
                      color: SettingsColors.textSecondary,
                    ),
                  ),
            actions: [
              TextButton(
                style: botEditorTonalButtonStyle(dialog),
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
