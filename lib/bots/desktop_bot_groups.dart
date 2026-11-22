import 'package:bao_link/bao_link.dart' show LinkGroupMessage;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';
import '../link/chat_codec.dart';
import '../theme/app_theme.dart';
import 'bot_group_prompt.dart';
import 'bots.dart';

/// Desktop access to the same groups and message log that the phone uses.
class DesktopBotGroups extends StatefulWidget {
  const DesktopBotGroups({
    super.key,
    required this.bots,
    required this.onBack,
    this.initialGroupId,
  });

  final Bots bots;
  final VoidCallback onBack;
  final String? initialGroupId;

  @override
  State<DesktopBotGroups> createState() => _DesktopBotGroupsState();
}

class _DesktopBotGroupsState extends State<DesktopBotGroups> {
  String? _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.initialGroupId;
  }

  Future<void> _editGroup([BotGroup? original]) async {
    final bots = widget.bots;
    final draft = await showDialog<_GroupDraft>(
      context: context,
      builder: (_) => _GroupEditor(bots: bots, group: original),
    );
    if (!mounted || !identical(bots, widget.bots) || draft == null) return;
    if (original != null) {
      final current = bots.groups.byId(original.id);
      if (current == null) return;
      // Preserve unrelated edits that arrived while the dialog was open.
      final previous = original.members.toSet();
      final removed = previous.difference(draft.members);
      bots.groups.save(
        id: current.id,
        name: draft.name == original.name ? current.name : draft.name,
        members: [
          for (final id in current.members)
            if (!removed.contains(id)) id,
          ...draft.members.difference(previous),
        ],
      );
      return;
    }
    final members = draft.members.where((id) => bots.byId(id) != null).toList();
    if (members.isEmpty) return;
    final group = bots.groups.save(name: draft.name, members: members);
    setState(() => _selected = group.id);
  }

  @override
  void didUpdateWidget(DesktopBotGroups oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.bots, oldWidget.bots)) _selected = null;
  }

  @override
  Widget build(BuildContext context) {
    final bots = widget.bots;
    return Material(
      color: AppColors.conversationSurface,
      child: ListenableBuilder(
        listenable: Listenable.merge([bots, bots.groups]),
        builder: (context, _) {
          final selected = _selected;
          final group = selected == null ? null : bots.groups.byId(selected);
          if (group != null) {
            return _GroupChat(
              key: ValueKey(group.id),
              bots: bots,
              group: group,
              onBack: () => setState(() => _selected = null),
              onEdit: () => _editGroup(group),
            );
          }
          final groups = bots.groups.groups;
          return Column(
            children: [
              _GroupHeader(
                title: _labels(context, 'Group chats', '群聊'),
                onBack: widget.onBack,
                action: IconButton(
                  tooltip: _labels(context, 'New group', '新建群聊'),
                  onPressed: bots.bots.isEmpty ? null : () => _editGroup(),
                  icon: const Icon(Icons.group_add_outlined),
                ),
              ),
              Expanded(
                child: groups.isEmpty
                    ? Center(
                        child: Text(
                          _labels(context, 'No group chats yet', '还没有群聊'),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: groups.length,
                        itemBuilder: (context, index) {
                          final group = groups[index];
                          final unread = bots.groups.unread(group.id);
                          return _centered(
                            ListTile(
                              key: ValueKey(group.id),
                              leading: const Icon(Icons.groups_outlined),
                              title: Text(
                                group.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: _memberLine(bots, group),
                              trailing: unread > 0
                                  ? Badge(label: Text('$unread'))
                                  : const Icon(Icons.chevron_right),
                              onTap: () => setState(() => _selected = group.id),
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _GroupChat extends StatefulWidget {
  const _GroupChat({
    super.key,
    required this.bots,
    required this.group,
    required this.onBack,
    required this.onEdit,
  });

  final Bots bots;
  final BotGroup group;
  final VoidCallback onBack;
  final VoidCallback onEdit;

  @override
  State<_GroupChat> createState() => _GroupChatState();
}

class _GroupChatState extends State<_GroupChat> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _seenScheduled = false;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send() {
    final text = _input.text.trim();
    final groups = widget.bots.groups;
    final id = widget.group.id;
    if (text.isEmpty || groups.byId(id) == null) return;
    groups.send(id, text: text);
    _input.clear();
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _markRead() {
    final groups = widget.bots.groups;
    final id = widget.group.id;
    if (_seenScheduled || groups.unread(id) == 0) return;
    _seenScheduled = true;
    // Mark read after rendering the selected group. The store notifies the
    // desktop list and connected phones when its unread count changes.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _seenScheduled = false;
      if (groups.byId(id) != null) groups.seen(id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final bots = widget.bots;
    final group = widget.group;
    final messages = bots.groups.messages(group.id);
    _markRead();
    return Column(
      children: [
        _GroupHeader(
          title: group.name,
          subtitle: _memberLine(bots, group),
          onBack: widget.onBack,
          action: IconButton(
            tooltip: _labels(context, 'Edit group', '编辑群聊'),
            onPressed: widget.onEdit,
            icon: const Icon(Icons.edit_outlined),
          ),
        ),
        Expanded(
          child: messages.isEmpty
              ? Center(
                  child: Text(_labels(context, 'No messages yet', '还没有消息')),
                )
              : SelectionArea(
                  child: ListView.builder(
                    controller: _scroll,
                    reverse: true,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    itemCount: messages.length,
                    itemBuilder: (context, index) => _centered(
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 4,
                        ),
                        child: _GroupMessage(
                          bots: bots,
                          group: group,
                          message: messages[messages.length - index - 1],
                        ),
                      ),
                    ),
                  ),
                ),
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
                        const SingleActivator(LogicalKeyboardKey.enter): () {
                          if (_input.value.composing.isCollapsed) _send();
                        },
                      },
                      child: TextField(
                        controller: _input,
                        minLines: 1,
                        maxLines: 5,
                        style: TextStyle(color: AppColors.text),
                        decoration: InputDecoration(
                          hintText: context.l10n.editorStartTyping,
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.all(12),
                        ),
                      ),
                    ),
                  ),
                  ValueListenableBuilder(
                    valueListenable: _input,
                    builder: (context, value, _) => IconButton(
                      tooltip: context.l10n.cmdChatSubmit,
                      color: AppColors.accent,
                      onPressed: value.text.trim().isEmpty ? null : _send,
                      icon: const Icon(Icons.arrow_upward),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _GroupMessage extends StatelessWidget {
  const _GroupMessage({
    required this.bots,
    required this.group,
    required this.message,
  });
  final Bots bots;
  final BotGroup group;
  final LinkGroupMessage message;

  @override
  Widget build(BuildContext context) {
    final message = this.message;
    final styles = Theme.of(context).textTheme;
    if (message.notice) {
      return Center(
        child: Text(
          message.text,
          textAlign: TextAlign.center,
          style: styles.bodySmall?.copyWith(color: AppColors.textMuted),
        ),
      );
    }
    final parts = message.mine
        ? [(ChatCodec.botSayTag, message.text)]
        : [
            for (final (tag, text) in ChatCodec.botParts(
              ChatCodec.withoutBotEvents(message.text),
            ))
              if (tag == ChatCodec.botSayTag || tag == ChatCodec.botNarrateTag)
                if (ChatCodec.withoutVoiceCues(text) case final shown
                    when shown.isNotEmpty)
                  (tag, shown),
          ];
    if (parts.isEmpty && message.images.isEmpty) return const SizedBox.shrink();
    final alignment = message.mine
        ? AlignmentDirectional.centerEnd
        : AlignmentDirectional.centerStart;
    final name = message.mine
        ? _labels(context, 'You', '你')
        : _memberName(bots, group, message.from);
    return Align(
      alignment: alignment,
      child: FractionallySizedBox(
        alignment: alignment,
        widthFactor: 0.88,
        child: Align(
          alignment: alignment,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: message.mine ? AppColors.bubbleFill : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    style: styles.labelMedium?.copyWith(
                      color: AppColors.textMuted,
                    ),
                  ),
                  for (final (tag, text) in parts)
                    if (text.isNotEmpty)
                      Text(
                        text,
                        style: styles.bodyMedium?.copyWith(
                          color: tag == ChatCodec.botNarrateTag
                              ? AppColors.textMuted
                              : AppColors.text,
                          fontStyle: tag == ChatCodec.botNarrateTag
                              ? FontStyle.italic
                              : null,
                        ),
                      ),
                  for (final name in message.images)
                    if (bots.groups.image(group.id, name) case final image?)
                      Image.memory(
                        image.bytes,
                        fit: BoxFit.contain,
                        height: 180,
                        errorBuilder: (context, error, stack) =>
                            const Icon(Icons.broken_image_outlined),
                      )
                    else
                      const Icon(Icons.broken_image_outlined),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

typedef _GroupDraft = ({String name, Set<String> members});

class _GroupEditor extends StatefulWidget {
  const _GroupEditor({required this.bots, this.group});

  final Bots bots;
  final BotGroup? group;

  @override
  State<_GroupEditor> createState() => _GroupEditorState();
}

class _GroupEditorState extends State<_GroupEditor> {
  late final _name = TextEditingController(text: widget.group?.name);
  late final _members = widget.group?.members.toSet() ?? <String>{};

  bool get _editing => widget.group != null;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.bots,
    builder: (context, _) => AlertDialog(
      title: Text(
        _editing
            ? _labels(context, 'Edit group', '编辑群聊')
            : _labels(context, 'New group', '新建群聊'),
      ),
      scrollable: true,
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              decoration: InputDecoration(
                labelText: _labels(context, 'Group name', '群名称'),
              ),
            ),
            const SizedBox(height: 16),
            Text(_labels(context, 'Members', '群成员')),
            for (final bot in widget.bots.bots)
              CheckboxListTile(
                key: ValueKey(bot.id),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(bot.name),
                value: _members.contains(bot.id),
                onChanged: (selected) => setState(() {
                  if (selected == true) {
                    _members.add(bot.id);
                  } else {
                    _members.remove(bot.id);
                  }
                }),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.l10n.commonCancel),
        ),
        FilledButton(
          onPressed:
              _editing || _members.any((id) => widget.bots.byId(id) != null)
              ? () => Navigator.pop(context, (
                  name: _name.text.trim(),
                  members: _members.toSet(),
                ))
              : null,
          child: Text(
            _editing
                ? context.l10n.commonSave
                : _labels(context, 'Create', '创建'),
          ),
        ),
      ],
    ),
  );
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.title,
    this.subtitle,
    required this.onBack,
    this.action,
  });
  final String title;
  final Widget? subtitle;
  final VoidCallback onBack;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(6, 4, 18, 4),
        child: Row(
          children: [
            IconButton(
              tooltip: context.l10n.chatBack,
              onPressed: onBack,
              icon: const BackButtonIcon(),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  ?subtitle,
                ],
              ),
            ),
            ?action,
          ],
        ),
      ),
      Divider(height: 1, color: AppColors.partBorder),
    ],
  );
}

String _memberName(Bots bots, BotGroup group, String id) =>
    bots.byId(id)?.name ?? group.names[id] ?? id;

Widget? _memberLine(Bots bots, BotGroup group) => group.members.isEmpty
    ? null
    : Text(
        [for (final id in group.members) _memberName(bots, group, id)]
            .join(', '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, color: AppColors.textMuted),
      );

Widget _centered(Widget child) => Align(
  child: ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 780),
    child: SizedBox(width: double.infinity, child: child),
  ),
);

String _labels(BuildContext context, String english, String chinese) =>
    Localizations.localeOf(context).languageCode == 'zh' ? chinese : english;
