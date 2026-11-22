import 'package:flutter/material.dart';

import '../chat/chat_session.dart';
import '../theme/app_theme.dart';
import '../workspace/workspace.dart';
import 'bot_groups.dart';
import 'bots.dart';
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
      Material(type: MaterialType.transparency, child: _panels());

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
                  const VerticalDivider(width: 1, thickness: 1),
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
    if (!session.hasEarlierHistory ||
        session.loadingEarlier ||
        !_searchedHistory.add(session)) {
      return;
    }
    final bots = widget.bots;
    // The latest page can be entirely group turns. Page through the local
    // transcript without attaching a view or preparing the backend.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      while (mounted &&
          identical(bots, widget.bots) &&
          _panel == _Panel.list &&
          session.hasEarlierHistory) {
        final before = session.prependedCount;
        await session.loadEarlier();
        if (!mounted ||
            session.prependedCount == before ||
            _privatePreview(thread) != null) {
          return;
        }
      }
      // If the user left the list before the search finished, resume on return.
      _searchedHistory.remove(session);
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

  Widget _row(BuildContext context, _Conversation row, bool zh) {
    final text = row.preview?.text ?? row.fallback;
    return ListTile(
      key: ValueKey((row.group, row.id)),
      leading: Icon(
        row.group ? Icons.groups_outlined : Icons.chat_bubble_outline,
      ),
      title: Text(row.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: text.isEmpty
          ? null
          : Text(
              text.replaceAll(RegExp(r'\s+'), ' ').trim(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
      onTap: () => _show(row.group ? _Panel.groups : _Panel.chat, row.id),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (row.preview case final preview?)
                Text(
                  _formatTime(context, preview.at),
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              if (row.unread > 0) Badge(label: Text('${row.unread}')),
            ],
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: Icon(Icons.chevron_right),
          ),
        ],
      ),
    );
  }

  Widget _list(BuildContext context) {
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              BackButton(onPressed: widget.onBack),
              const Expanded(
                child: Text(
                  'Bot',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                tooltip: zh ? '新建 Bot' : 'Create bot',
                onPressed: () => _show(_Panel.settings),
                icon: const Icon(Icons.person_add_alt_outlined),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: AppColors.partBorder),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              ListTile(
                leading: const Icon(Icons.group_outlined),
                title: Text(zh ? '群聊' : 'Group chats'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _show(_Panel.groups),
              ),
              for (final row in _conversations()) _row(context, row, zh),
            ],
          ),
        ),
      ],
    );
  }
}
