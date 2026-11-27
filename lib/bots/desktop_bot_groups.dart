import 'package:bao_link/bao_link.dart' show LinkGroupMessage, isAvatarImage;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chat/chat_models.dart' show ImageAttachment;
import '../chat/widgets/image_thumbnails.dart';
import '../l10n/l10n.dart';
import '../link/chat_codec.dart';
import '../theme/app_theme.dart';
import 'bot_group_prompt.dart';
import 'bot_groups.dart' show BotGroups;
import 'bots.dart';
import 'desktop_bot_editor_ui.dart';
import 'desktop_bot_message_row.dart';

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
        lead: draft.lead == original.lead ? null : draft.lead,
        clearLead: draft.clearLead,
      );
      return;
    }
    final members = draft.members.where((id) => bots.byId(id) != null).toList();
    if (members.isEmpty) return;
    final group = bots.groups.save(
      name: draft.name,
      members: members,
      lead: draft.lead,
    );
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

  Future<void> _changeLead() async {
    final bots = widget.bots;
    final group = widget.group;
    final choice = await showDialog<({String? id})>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(_labels(context, 'Change default lead', '更换默认主理人')),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              _labels(
                context,
                'An @mention takes priority. The current turn continues.',
                '@提及优先。当前轮次会继续。',
              ),
            ),
          ),
          for (final id in <String?>[null, ...group.members])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, (id: id)),
              child: Text(
                id == null
                    ? _labels(context, 'No default lead', '不设默认主理人')
                    : _memberName(bots, group, id),
              ),
            ),
        ],
      ),
    );
    if (!mounted || !identical(bots, widget.bots) || choice == null) return;
    final current = bots.groups.byId(group.id);
    final lead = choice.id;
    if (current == null || current.lead == lead) return;
    if (lead != null &&
        (!current.members.contains(lead) || bots.byId(lead) == null)) {
      return;
    }
    bots.groups.save(
      id: current.id,
      name: current.name,
      members: current.members,
      lead: lead,
      clearLead: lead == null,
    );
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
    final relay = bots.groups.relay(group.id);
    final lead = group.lead;
    final leadName = lead == null
        ? _labels(context, 'None', '无')
        : _memberName(bots, group, lead);
    final handler = switch (relay.holder) {
      final id? => _memberName(bots, group, id),
      null => null,
    };
    final status = handler == null
        ? _labels(context, 'No bot handling this turn', '当前没有机器人处理')
        : relay.waiting
        ? _labels(context, 'Waiting for: $handler', '等待 $handler')
        : _labels(context, 'Handling: $handler', '正在处理：$handler');
    _markRead();
    return Column(
      children: [
        _GroupHeader(
          title: group.name,
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ?_memberLine(bots, group),
              _headerLine(
                _labels(context, 'Default lead: $leadName', '默认主理人：$leadName'),
              ),
              Semantics(liveRegion: true, child: _headerLine(status)),
            ],
          ),
          onBack: widget.onBack,
          action: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: _labels(context, 'Change default lead', '更换默认主理人'),
                onPressed: group.members.isEmpty ? null : _changeLead,
                icon: const Icon(Icons.swap_horiz),
              ),
              IconButton(
                tooltip: _labels(context, 'Edit group', '编辑群聊'),
                onPressed: widget.onEdit,
                icon: const Icon(Icons.edit_outlined),
              ),
            ],
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
                          lookupQuote: (seq) => messages
                              .where((item) => item.seq == seq && !item.notice)
                              .firstOrNull,
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
    required this.lookupQuote,
  });
  final Bots bots;
  final BotGroup group;
  final LinkGroupMessage message;
  final LinkGroupMessage? Function(int) lookupQuote;

  String _sender(BuildContext context, LinkGroupMessage item) => item.mine
      ? _labels(context, 'You', '你')
      : _memberName(bots, group, item.from);

  Widget? _quote(BuildContext context, int? ref) {
    if (ref == null || ref <= 0 || ref >= message.seq) return null;
    final item = lookupQuote(ref);
    final label = _labels(context, 'Reply to #$ref', '回复 #$ref');
    return DesktopGroupQuoteBanner(
      label: item == null ? label : '$label · ${_sender(context, item)}',
      preview: item == null
          ? ''
          : BotGroups.quotedText(
              item,
              picture: _labels(context, '[Image]', '[图片]'),
            ),
    );
  }

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
    final literal = message.mine
        ? message.text
        : ChatCodec.literalBotText(message.text);
    final parts = literal != null
        ? [(tag: ChatCodec.botSayTag, text: literal, ref: message.ref)]
        : [
            for (final (:tag, :text, :ref) in ChatCodec.botPartsOf(
              ChatCodec.withoutBotEvents(message.text),
            ))
              if (tag == ChatCodec.botSayTag || tag == ChatCodec.botNarrateTag)
                if (ChatCodec.withoutVoiceCues(text) case final shown
                    when shown.isNotEmpty)
                  (tag: tag, text: shown, ref: ref ?? message.ref),
          ];
    if (parts.isEmpty && message.images.isEmpty) return const SizedBox.shrink();
    final name = _sender(context, message);
    final avatar = message.mine ? null : bots.byId(message.from)?.avatar;
    final images = [
      for (final name in message.images)
        switch (bots.groups.image(group.id, name)) {
          final image? => ImageAttachment(
            bytes: image.bytes,
            mediaType: image.type,
            name: name,
          ),
          null => null,
        },
    ];
    return DesktopBotMessageRow(
      mine: message.mine,
      sender: name,
      avatar: avatar == null || avatar.isEmpty || isAvatarImage(avatar)
          ? null
          : DesktopBotMessageAvatar(sender: name, emoji: avatar),
      sentAt: message.at.millisecondsSinceEpoch == 0 ? null : message.at,
      quote: parts.isEmpty ? _quote(context, message.ref) : null,
      content: [
        for (final (:tag, :text, :ref) in parts) ...[
          ?_quote(context, ref),
          if (text.isNotEmpty)
            DesktopBotMessageText(
              text,
              narration: tag == ChatCodec.botNarrateTag,
            ),
        ],
      ],
      media: images.isEmpty ? null : ImageThumbnails(images: images),
    );
  }
}

typedef _GroupDraft = ({
  String name,
  Set<String> members,
  String? lead,
  bool clearLead,
});

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
  late String? _lead = widget.group?.lead;
  bool _clearLead = false;

  String? get _selectedLead => switch (_lead) {
    final id? when widget.bots.byId(id) != null => id,
    _ => null,
  };

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
              decoration: botEditorInput(_labels(context, 'Group name', '群名称')),
            ),
            const SizedBox(height: 16),
            Text(_labels(context, 'Members', '群成员')),
            for (final bot in widget.bots.bots)
              BotEditorMemberTile(
                key: ValueKey(bot.id),
                member: (id: bot.id, name: bot.name),
                selected: _members.contains(bot.id),
                onChanged: (selected) => setState(() {
                  if (selected == true) {
                    _members.add(bot.id);
                  } else {
                    _members.remove(bot.id);
                    if (_lead == bot.id) _lead = null;
                  }
                }),
              ),
            const SizedBox(height: 12),
            BotEditorLeadPicker(
              pickerKey: const ValueKey('group-lead-picker'),
              label: _labels(context, 'Default lead', '默认主理人'),
              defaultLabel: _labels(context, 'No default lead', '不设默认主理人'),
              members: [
                for (final bot in widget.bots.bots)
                  if (_members.contains(bot.id)) (id: bot.id, name: bot.name),
              ],
              lead: _selectedLead,
              onChanged: _members.any((id) => widget.bots.byId(id) != null)
                  ? (choice) => setState(() {
                      _lead = choice;
                      _clearLead = _lead == null;
                    })
                  : null,
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
                  lead: _selectedLead,
                  clearLead: _clearLead,
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
    : _headerLine(
        [for (final id in group.members) _memberName(bots, group, id)]
            .join(', '),
      );

Widget _headerLine(String text) => Text(
  text,
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
