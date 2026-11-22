import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'bot.dart';
import 'bots.dart';
import 'desktop_bot_groups.dart';
import 'desktop_bot_page.dart';
import 'desktop_bot_settings.dart';

enum _Panel { list, chat, settings, groups }

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

  void _show(_Panel panel, [Bot? bot]) => setState(() {
    _panel = panel;
    _selectedId = bot?.id;
  });

  @override
  Widget build(BuildContext context) =>
      Material(type: MaterialType.transparency, child: _panels());

  Widget _panels() => ListenableBuilder(
    listenable: widget.bots,
    builder: (context, _) {
      final selected = widget.bots.bots
          .where((bot) => bot.id == _selectedId)
          .firstOrNull;
      void back() => _show(_Panel.list);
      switch (_panel) {
        case _Panel.chat when selected != null:
          return DesktopBotPage(
            key: ValueKey(selected.id),
            bots: widget.bots,
            botId: selected.id,
            onBack: back,
            onOpenChat: widget.onOpenChat,
          );
        case _Panel.settings when _selectedId == null || selected != null:
          return DesktopBotSettings(
            bots: widget.bots,
            bot: selected,
            onBack: back,
          );
        case _Panel.groups:
          return DesktopBotGroups(bots: widget.bots, onBack: back);
        default:
          return _list(context);
      }
    },
  );

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
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text(
                  zh ? '私聊' : 'Private chats',
                  style: TextStyle(color: AppColors.textMuted),
                ),
              ),
              for (final bot in widget.bots.bots)
                ListTile(
                  key: ValueKey(bot.id),
                  leading: const Icon(Icons.chat_bubble_outline),
                  title: Text(bot.name),
                  subtitle: bot.signature.isEmpty
                      ? null
                      : Text(
                          bot.signature,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                  onTap: () => _show(_Panel.chat, bot),
                  trailing: IconButton(
                    tooltip: zh ? '配置 ${bot.name}' : 'Configure ${bot.name}',
                    icon: const Icon(Icons.tune),
                    onPressed: () => _show(_Panel.settings, bot),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
