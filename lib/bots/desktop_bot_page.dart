import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chat/chat_session.dart';
import '../kernel/kernel_types.dart' show KernelHealthStatus;
import '../l10n/l10n.dart';
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
    required this.onBack,
    required this.onOpenChat,
  });

  final Bots bots;

  /// The ID of the selected bot, or null for the assistant.
  final String? botId;
  final VoidCallback onBack;
  final ValueChanged<String> onOpenChat;

  @override
  State<DesktopBotPage> createState() => _DesktopBotPageState();
}

class _DesktopBotPageState extends State<DesktopBotPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  ChatSession? _session;
  bool _workspaceReady = false;
  bool _syncScheduled = false;
  bool _restoringDraft = false;
  bool _triedEarlier = false;
  Bot? get _bot => switch (widget.botId) {
    final id? => widget.bots.byId(id),
    null => widget.bots.bots.where((bot) => bot.assistant).firstOrNull,
  };

  @override
  void initState() {
    super.initState();
    _input.addListener(_inputChanged);
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
    _restoringDraft = true;
    final text = session?.draft.content ?? '';
    final selection = session?.draft.selection;
    _input.value = TextEditingValue(
      text: text,
      selection:
          selection != null && selection.isValid && selection.end <= text.length
          ? selection
          : TextSelection.collapsed(offset: text.length),
    );
    _restoringDraft = false;
    session?.addListener(_sessionChanged);
    session?.attach();
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _sessionChanged() => setState(() {});

  void _inputChanged() {
    if (_restoringDraft) return;
    if (_session?.draft case final draft?) {
      draft.save(_input.text, _input.selection, draft.images, by: this);
    }
    setState(() {});
  }

  bool get _canSend => switch (_session) {
    final session? =>
      !session.loadingHistory &&
          session.health.status != KernelHealthStatus.failed &&
          session.canSend &&
          _input.text.trim().isNotEmpty,
    null => false,
  };

  void _send() {
    final session = _session;
    final bot = _bot;
    if (session == null || bot == null || !_canSend) return;
    session.send(
      ComposerMessage(text: _input.text.trim()),
      notes: widget.bots.suggestionNotes(bot, wanted: false),
    );
    _input.clear();
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  void dispose() {
    _unwatch(widget.bots);
    _session?.removeListener(_sessionChanged);
    _session?.detach();
    _input.dispose();
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
          _centered(
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 16),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: AppColors.bubbleFill,
                  border: Border.all(color: AppColors.bubbleBorder()),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: CallbackShortcuts(
                        bindings: {
                          if (_canSend)
                            const SingleActivator(
                              LogicalKeyboardKey.enter,
                            ): () {
                              if (_input.value.composing.isCollapsed) _send();
                            },
                        },
                        child: TextField(
                          controller: _input,
                          enabled: session != null,
                          minLines: 1,
                          maxLines: 5,
                          style: TextStyle(color: AppColors.text),
                          decoration: InputDecoration(
                            hintText: l10n.editorStartTyping,
                            border: InputBorder.none,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 12,
                            ),
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: l10n.cmdChatSubmit,
                      color: AppColors.accent,
                      onPressed: _canSend ? _send : null,
                      icon: const Icon(Icons.arrow_upward),
                    ),
                  ],
                ),
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
                  if (message.text.isNotEmpty)
                    Text(
                      message.text,
                      style: TextStyle(
                        color: narration ? AppColors.textMuted : AppColors.text,
                        fontStyle: narration
                            ? FontStyle.italic
                            : FontStyle.normal,
                      ),
                    ),
                  for (final image in message.images)
                    Image.memory(
                      image.bytes,
                      fit: BoxFit.contain,
                      height: 180,
                      errorBuilder: (context, error, stackTrace) =>
                          const Icon(Icons.broken_image_outlined),
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
