import 'dart:async';

import 'package:flutter/material.dart';

import '../chat/chat_keys.dart';
import '../chat/chat_models.dart' show UserMessageItem;
import '../chat/chat_session.dart';
import '../chat/composer/composer.dart';
import '../chat/stop_confirmation.dart';
import '../chat/widgets/image_thumbnails.dart';
import '../chat/widgets/user_message_bubble.dart';
import '../kernel/kernel_types.dart' show KernelHealthStatus;
import '../keybindings/chat_keybindings.dart';
import '../l10n/l10n.dart';
import '../link/chat_codec.dart';
import '../theme/app_theme.dart';
import '../workspace/editor_launcher.dart' show openExternal;
import '../workspace/session_tools.dart';
import '../workspace/workspace.dart';
import 'bot.dart';
import 'bots.dart';
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
  bool _workspaceReady = false;
  bool _syncScheduled = false;
  bool _triedEarlier = false;
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
    _triedEarlier = false;
    session?.addListener(_sessionChanged);
    session?.attach();
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _sessionChanged() => setState(() {});

  bool _canStop(ChatSession session) {
    if (!identical(_session, session) || !session.isStreaming) return false;
    // A private prompt queued during a group turn doesn't change the turn
    // being answered. Only the surface that owns that turn may stop it.
    for (var i = session.itemCount - 1; i >= 0; i--) {
      if (session.itemAt(i) case final UserMessageItem item when !item.queued) {
        return ChatCodec.botGroupOf(item) == null;
      }
    }
    return !session.hasEarlierHistory;
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
                : session == null
                ? const SizedBox.shrink()
                : _history(context, session),
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
                  canStop: () => _canStop(session),
                  canSubmit: () =>
                      identical(_session, session) &&
                      _bot?.id == bot.id &&
                      !session.loadingHistory &&
                      session.health.status != KernelHealthStatus.failed &&
                      session.canSend,
                  onIntercept: (message) {
                    // Like the phone, private bot chat has its own suggestion
                    // policy and doesn't send ordinary chat's place notes.
                    session.send(
                      message,
                      notes: widget.bots.suggestionNotes(bot, wanted: false),
                    );
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

  Widget _history(BuildContext context, ChatSession session) {
    final messages = desktopBotMessages(
      Iterable.generate(session.itemCount, session.itemAt),
      hasEarlier: session.hasEarlierHistory,
    );
    final earlier = session.hasEarlierHistory;
    if (messages.isEmpty &&
        earlier &&
        !session.loadingEarlier &&
        !_triedEarlier) {
      // A page can contain only group turns. Read one more automatically
      // to find private messages, with the usual control for older pages.
      _triedEarlier = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !identical(session, _session)) return;
        unawaited(session.loadEarlier());
      });
    }
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
    return DesktopBotMessageRow(
      mine: message.kind == DesktopBotMessageKind.user,
      sentAt: message.sentAt,
      content: [
        if (message.textWithAttachments case final text?)
          UserMessageBubble(text: text)
        else if (message.text.isNotEmpty)
          DesktopBotMessageText(
            message.text,
            narration: message.kind == DesktopBotMessageKind.narration,
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
                    // External content loads only when the user opens it.
                    onPressed: () => unawaited(openExternal(url.toString())),
                    icon: const Icon(Icons.image_outlined, size: 16),
                    label: Text(context.l10n.fileLinkOpenInBrowser),
                  ),
              ],
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
