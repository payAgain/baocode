import 'package:flutter/material.dart';

import '../chat/chat_session.dart';
import '../l10n/l10n.dart';
import '../link/chat_codec.dart';
import '../settings/pages/settings_widgets.dart' show SettingsColors;
import '../theme/app_theme.dart';
import '../workspace/workspace.dart';
import 'bot.dart';
import 'bot_groups.dart';
import 'bots.dart';
import 'desktop_bot_editor_ui.dart';
import 'desktop_bot_groups.dart';
import 'desktop_bot_messages.dart';
import 'desktop_bot_page.dart';
import 'desktop_bot_settings.dart';

enum _Panel { list, chat, settings, groups }

typedef _Preview = ({String text, DateTime at});
typedef _Conversation = ({
  String id,
  bool group,
  String name,
  String fallback,
  _Preview? preview,
  int unread,
});

class DesktopBotHub extends StatefulWidget {
  const DesktopBotHub({
    super.key,
    required this.bots,
    required this.onBack,
    required this.onOpenChat,
  });

  final Bots bots;
  final VoidCallback onBack;
  final ValueChanged<String> onOpenChat;

  @override
  State<DesktopBotHub> createState() => _DesktopBotHubState();
}

class _DesktopBotHubState extends State<DesktopBotHub> {
  _Panel _panel = _Panel.list;
  String? _selectedId;
  final _searchedHistory = <ChatSession>{};
  bool _settingsOpen = false;

  void _show(_Panel panel, [String? id]) => setState(() {
    _panel = panel;
    _settingsOpen = false;
    _selectedId = id;
  });

  @override
  void didUpdateWidget(DesktopBotHub oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.bots, widget.bots)) return;
    _searchedHistory.clear();
    _panel = _Panel.list;
    _selectedId = null;
    _settingsOpen = false;
  }

  @override
  Widget build(BuildContext context) =>
      Material(color: AppColors.conversationSurface, child: _panels());

  Widget _panels() => ListenableBuilder(
    listenable: Listenable.merge([widget.bots, widget.bots.groups]),
    builder: (context, _) {
      final id = _selectedId;
      final selected = id == null ? null : widget.bots.byId(id);
      void back() => _show(_Panel.list);
      switch (_panel) {
        case _Panel.chat when selected != null:
          return LayoutBuilder(
            builder: (context, bounds) => Row(
              children: [
                Expanded(
                  child: DesktopBotPage(
                    key: ValueKey(selected.id),
                    bots: widget.bots,
                    botId: selected.id,
                    onBack: back,
                    onSettings: () =>
                        setState(() => _settingsOpen = !_settingsOpen),
                    onOpenChat: widget.onOpenChat,
                  ),
                ),
                if (_settingsOpen)
                  Container(width: 1, color: SettingsColors.divider),
                if (_settingsOpen)
                  SizedBox(
                    key: const ValueKey('bot-settings-drawer'),
                    width: (bounds.maxWidth * .45).clamp(0.0, 416.0),
                    child: DesktopBotSettings(
                      key: ValueKey(selected.id),
                      bots: widget.bots,
                      bot: selected,
                      drawer: true,
                      onBack: () {
                        if (widget.bots.byId(selected.id) == null) {
                          back();
                        } else {
                          setState(() => _settingsOpen = false);
                        }
                      },
                    ),
                  ),
              ],
            ),
          );
        case _Panel.settings when id == null:
          return DesktopBotSettings(bots: widget.bots, onBack: back);
        case _Panel.groups:
          return DesktopBotGroups(
            bots: widget.bots,
            onBack: back,
            initialGroupId: id,
          );
        default:
          return _list(context);
      }
    },
  );

  _Preview? _privatePreview(AgentThread thread) {
    final session = thread.session;
    if (session.loadingHistory) return null;
    final latest = desktopBotMessages(
      Iterable.generate(session.itemCount, session.itemAt),
      hasEarlier: session.hasEarlierHistory,
      previewOnly: true,
    ).lastOrNull;
    if (latest == null) return null;
    return (text: latest.text, at: latest.sentAt ?? thread.updatedAt);
  }

  void _findOlderPrivateText(AgentThread thread) {
    final session = thread.session;
    if ((!session.loadingHistory && !session.hasEarlierHistory) ||
        !_searchedHistory.add(session)) {
      return;
    }
    final bots = widget.bots;
    // A legacy head can contain group turns. Read its retained pages using
    // the history reader so showing the preview doesn't resume that model.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !identical(bots, widget.bots)) return;
      try {
        await loadBotChatHistory(session);
      } finally {
        if (mounted && identical(bots, widget.bots)) setState(() {});
      }
    });
  }

  List<_Conversation> _conversations() {
    final bots = widget.bots;
    final rows = <_Conversation>[];
    for (final bot in bots.bots) {
      final thread = bots.threadOf(bot);
      _Preview? preview;
      if (thread != null && thread.isOpen) {
        preview = _privatePreview(thread);
        if (preview == null) _findOlderPrivateText(thread);
      }
      if (preview == null) {
        for (final history in bots.privateHistory(bot).reversed) {
          preview = _privatePreview(history);
          if (preview != null) break;
          _findOlderPrivateText(history);
        }
      }
      if (bots.privateDeliveries(bot).lastOrNull case final delivery?) {
        final text = ChatCodec.botSentToUser(delivery.item);
        if (text != null &&
            text.isNotEmpty &&
            (preview == null || delivery.at.isAfter(preview.at))) {
          preview = (text: text, at: delivery.at);
        }
      }
      rows.add((
        id: bot.id,
        group: false,
        name: bot.name,
        fallback: bot.signature,
        preview: preview,
        unread: bots.unread(bot),
      ));
    }
    for (final group in bots.groups.groups) {
      _Preview? preview;
      for (final message in bots.groups.messages(group.id).reversed) {
        if (message.notice) continue;
        final text = BotGroups.quotedText(message);
        if (text.isEmpty) continue;
        preview = (text: text, at: message.at);
        break;
      }
      rows.add((
        id: group.id,
        group: true,
        name: group.name,
        fallback: '',
        preview: preview,
        unread: bots.groups.unread(group.id),
      ));
    }
    rows.sort((a, b) {
      final recent = switch ((a.preview, b.preview)) {
        (final a?, final b?) => b.at.compareTo(a.at),
        (_?, null) => -1,
        (null, _?) => 1,
        _ => 0,
      };
      if (recent != 0) return recent;
      final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      if (byName != 0) return byName;
      if (a.group != b.group) return a.group ? 1 : -1;
      return a.id.compareTo(b.id);
    });
    return rows;
  }

  String _formatTime(BuildContext context, DateTime at) {
    final material = MaterialLocalizations.of(context);
    final local = at.toLocal();
    return '${material.formatMediumDate(local)} '
        '${material.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
  }

  Widget _avatarForConversation(BuildContext context, _Conversation row) {
    if (row.group) {
      return const BotAvatarBadge(
        label: 'G',
        icon: Icons.groups_outlined,
        tint: Color(0xFF5E9BFF),
        size: 38,
      );
    }
    final bot = widget.bots.byId(row.id);
    final emoji =
        bot?.avatar != null &&
            bot!.avatar!.isNotEmpty &&
            !isAvatarImage(bot.avatar)
        ? bot.avatar
        : null;
    return BotAvatarBadge(
      label: row.name,
      emoji: emoji,
      icon: bot?.assistant == true ? Icons.smart_toy_outlined : null,
      accent: bot?.assistant == true,
      size: 38,
    );
  }

  Widget _row(BuildContext context, _Conversation row, bool zh) {
    final text = row.preview?.text ?? row.fallback;
    final bot = row.group ? null : widget.bots.byId(row.id);
    final tagLabel = row.group
        ? (zh ? '群聊' : 'Group')
        : (bot?.assistant == true ? (zh ? '助理' : 'Assistant') : null);
    return ListTile(
      key: ValueKey((row.group, row.id)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      hoverColor: SettingsColors.hover,
      leading: _avatarForConversation(context, row),
      title: Row(
        children: [
          Flexible(
            flex: 3,
            child: Text(
              row.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: SettingsColors.textPrimary,
              ),
            ),
          ),
          if (tagLabel != null) ...[
            const SizedBox(width: 8),
            Flexible(
              fit: FlexFit.loose,
              child: BotMetaPill(
                label: tagLabel,
                tone: row.group ? BotEditorTone.neutral : BotEditorTone.accent,
              ),
            ),
          ],
        ],
      ),
      subtitle: text.isEmpty
          ? null
          : Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                text.replaceAll(RegExp(r'\s+'), ' ').trim(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  color: SettingsColors.textSecondary,
                ),
              ),
            ),
      onTap: () => _show(row.group ? _Panel.groups : _Panel.chat, row.id),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            spacing: 4,
            children: [
              if (row.preview case final preview?)
                Text(
                  _formatTime(context, preview.at),
                  style: TextStyle(
                    fontSize: 11.5,
                    color: SettingsColors.textQuaternary,
                  ),
                ),
              if (row.unread > 0) Badge(label: Text('${row.unread}')),
            ],
          ),
          const SizedBox(width: 8),
          Icon(
            Icons.chevron_right,
            size: 17,
            color: SettingsColors.textQuaternary,
          ),
        ],
      ),
    );
  }

  Widget _list(BuildContext context) {
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    final conversations = _conversations();
    final groupCount = widget.bots.groups.groups.length;
    final botCount = widget.bots.bots.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 48,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                IconButton(
                  tooltip: context.l10n.chatBack,
                  style: botToolbarIconButtonStyle(context),
                  onPressed: widget.onBack,
                  icon: const BackButtonIcon(),
                ),
                const SizedBox(width: 8),
                const BotAvatarBadge(
                  label: 'Bot',
                  icon: Icons.smart_toy_outlined,
                  accent: true,
                  size: 24,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Bot',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: SettingsColors.textPrimary,
                    ),
                  ),
                ),
                Tooltip(
                  message: zh ? '新建 Bot' : 'Create bot',
                  child: TextButton.icon(
                    style: botEditorTonalButtonStyle(context),
                    onPressed: () => _show(_Panel.settings),
                    icon: const Icon(Icons.add, size: 16),
                    label: Text(zh ? '新建 Bot' : 'New Bot'),
                  ),
                ),
              ],
            ),
          ),
        ),
        Container(height: 1, color: SettingsColors.divider),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
            children: [
              Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 780),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        spacing: 12,
                        runSpacing: 10,
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                zh ? '我的 Bot 与群聊' : 'Bots & Group Chats',
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w600,
                                  color: SettingsColors.textPrimary,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                zh
                                    ? '管理私人助理、自定义 Bot 与多机器人协作群聊'
                                    : 'Chat with your personal assistant, custom bots, and multi-bot groups',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: SettingsColors.textSecondary,
                                ),
                              ),
                            ],
                          ),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              BotMetaPill(
                                label: zh ? '$botCount 个 Bot' : '$botCount bots',
                                icon: Icons.smart_toy_outlined,
                                tone: BotEditorTone.accent,
                              ),
                              BotMetaPill(
                                label: zh
                                    ? '$groupCount 个群聊'
                                    : '$groupCount groups',
                                icon: Icons.groups_outlined,
                              ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      Material(
                        color: SettingsColors.card,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(color: SettingsColors.stroke),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 6,
                          ),
                          hoverColor: SettingsColors.hover,
                          leading: const BotAvatarBadge(
                            label: 'G',
                            icon: Icons.groups_outlined,
                            tint: Color(0xFF5E9BFF),
                            size: 38,
                          ),
                          title: Text(
                            zh ? '群聊' : 'Group chats',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: SettingsColors.textPrimary,
                            ),
                          ),
                          subtitle: Text(
                            groupCount == 0
                                ? (zh
                                      ? '创建多机器人协作群聊'
                                      : 'Create a shared chat with multiple bots')
                                : (zh
                                      ? '$groupCount 个活跃群聊'
                                      : '$groupCount active group chats'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.5,
                              color: SettingsColors.textSecondary,
                            ),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (groupCount > 0) ...[
                                BotMetaPill(label: '$groupCount'),
                                const SizedBox(width: 8),
                              ],
                              Icon(
                                Icons.chevron_right,
                                size: 17,
                                color: SettingsColors.textQuaternary,
                              ),
                            ],
                          ),
                          onTap: () => _show(_Panel.groups),
                        ),
                      ),
                      const SizedBox(height: 22),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                        child: Text(
                          zh ? '最近对话' : 'Recent conversations',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: SettingsColors.textSecondary,
                          ),
                        ),
                      ),
                      if (conversations.isEmpty)
                        Material(
                          color: SettingsColors.card,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: BorderSide(color: SettingsColors.stroke),
                          ),
                          child: BotEmptyState(
                            label: 'Bot',
                            icon: Icons.smart_toy_outlined,
                            title: zh ? '还没有对话' : 'No conversations yet',
                            description: zh
                                ? '创建一个 Bot 或发起群聊开始协作。'
                                : 'Create a bot or start a group chat to begin.',
                            action: FilledButton.icon(
                              style: botEditorButtonStyle(context),
                              onPressed: () => _show(_Panel.settings),
                              icon: const Icon(Icons.add, size: 16),
                              label: Text(zh ? '新建 Bot' : 'New Bot'),
                            ),
                          ),
                        )
                      else
                        Material(
                          color: SettingsColors.card,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: BorderSide(color: SettingsColors.stroke),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: Column(
                            children: [
                              for (var i = 0; i < conversations.length; i++) ...[
                                _row(context, conversations[i], zh),
                                if (i < conversations.length - 1)
                                  Container(
                                    height: 1,
                                    margin: const EdgeInsetsDirectional.only(
                                      start: 66,
                                    ),
                                    color: SettingsColors.divider,
                                  ),
                              ],
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
