import 'package:bao_link/bao_link.dart' show LinkGroupMessage, isAvatarImage;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chat/chat_models.dart' show ImageAttachment;
import '../chat/widgets/image_thumbnails.dart';
import '../chat/widgets/scroll_edge_fade.dart';
import '../l10n/l10n.dart';
import '../link/chat_codec.dart';
import '../settings/pages/settings_widgets.dart' show SettingsColors;
import '../theme/app_theme.dart';
import '../theme/workbench_theme.dart' show themeColors;
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
                avatar: const BotAvatarBadge(
                  label: 'G',
                  icon: Icons.groups_outlined,
                  tint: Color(0xFF5E9BFF),
                  size: 30,
                ),
                onBack: widget.onBack,
                action: IconButton(
                  tooltip: _labels(context, 'New group', '新建群聊'),
                  style: botToolbarIconButtonStyle(context),
                  onPressed: bots.bots.isEmpty ? null : () => _editGroup(),
                  icon: const Icon(Icons.group_add_outlined, size: 18),
                ),
              ),
              Expanded(
                child: groups.isEmpty
                    ? BotEmptyState(
                        label: 'G',
                        icon: Icons.groups_outlined,
                        tint: const Color(0xFF5E9BFF),
                        title: _labels(context, 'No group chats yet', '还没有群聊'),
                        description: _labels(
                          context,
                          'Create a group to coordinate multiple bots in one shared room.',
                          '创建群聊，让多个机器人协同完成同一任务。',
                        ),
                        action: bots.bots.isEmpty
                            ? null
                            : FilledButton.icon(
                                style: botEditorButtonStyle(context),
                                onPressed: () => _editGroup(),
                                icon: const Icon(Icons.add, size: 16),
                                label: Text(_labels(context, 'New group', '新建群聊')),
                              ),
                      )
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
                        children: [
                          _centered(
                            Material(
                              color: SettingsColors.card,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                                side: BorderSide(color: SettingsColors.stroke),
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: Column(
                                children: [
                                  for (var i = 0; i < groups.length; i++) ...[
                                    ListTile(
                                      key: ValueKey(groups[i].id),
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                            horizontal: 14,
                                            vertical: 6,
                                          ),
                                      hoverColor: SettingsColors.hover,
                                      leading: BotAvatarBadge(
                                        label: groups[i].name,
                                        icon: Icons.groups_outlined,
                                        size: 38,
                                      ),
                                      title: Text(
                                        groups[i].name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                          color: SettingsColors.textPrimary,
                                        ),
                                      ),
                                      subtitle: _memberLine(bots, groups[i]),
                                      trailing: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          if (bots.groups.unread(groups[i].id)
                                              case final unread when unread > 0) ...[
                                            Badge(label: Text('$unread')),
                                            const SizedBox(width: 8),
                                          ],
                                          Icon(
                                            Icons.chevron_right,
                                            size: 17,
                                            color: SettingsColors.textQuaternary,
                                          ),
                                        ],
                                      ),
                                      onTap: () => setState(
                                        () => _selected = groups[i].id,
                                      ),
                                    ),
                                    if (i < groups.length - 1)
                                      Container(
                                        height: 1,
                                        margin:
                                            const EdgeInsetsDirectional.only(
                                              start: 66,
                                            ),
                                        color: SettingsColors.divider,
                                      ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ],
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
  final _focus = FocusNode();
  final _scroll = ScrollController();
  bool _seenScheduled = false;

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
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
      builder: (context) => BotModernDialog(
        width: 400,
        icon: Icons.swap_horiz,
        title: _labels(context, 'Change default lead', '更换默认主理人'),
        subtitle: _labels(
          context,
          'An @mention takes priority. The current turn continues.',
          '@提及优先。当前轮次会继续。',
        ),
        body: Material(
          color: SettingsColors.card,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: SettingsColors.stroke),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (i, id)
                  in <String?>[null, ...group.members].indexed) ...[
                if (i > 0) Container(height: 1, color: SettingsColors.divider),
                InkWell(
                  hoverColor: SettingsColors.hover,
                  onTap: () => Navigator.pop(context, (id: id)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    child: Row(
                      children: [
                        if (id == null)
                          const BotAvatarBadge(
                            label: '*',
                            icon: Icons.auto_awesome_outlined,
                            size: 30,
                          )
                        else
                          BotAvatarBadge(
                            label: _memberName(bots, group, id),
                            size: 30,
                          ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            id == null
                                ? _labels(
                                    context,
                                    'No default lead',
                                    '不设默认主理人',
                                  )
                                : _memberName(bots, group, id),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: group.lead == id
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                              color: SettingsColors.textPrimary,
                            ),
                          ),
                        ),
                        if (group.lead == id)
                          Icon(
                            Icons.check_rounded,
                            size: 18,
                            color: AppColors.accent,
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            style: botEditorTonalButtonStyle(context),
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.commonCancel),
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
    final statusTone = handler == null
        ? BotEditorTone.neutral
        : relay.waiting
        ? BotEditorTone.warning
        : BotEditorTone.success;
    final statusDot = handler == null
        ? SettingsColors.textQuaternary
        : relay.waiting
        ? AppColors.caution
        : AppColors.added;
    final buttonBg = themeColors['button.background'];
    final buttonFg = themeColors['button.foreground'];
    _markRead();
    return Column(
      children: [
        _GroupHeader(
          title: group.name,
          avatar: BotAvatarBadge(
            label: group.name,
            icon: Icons.groups_outlined,
            size: 32,
          ),
          titleBadge: Semantics(
            liveRegion: true,
            child: BotMetaPill(
              label: status,
              dotColor: statusDot,
              tone: statusTone,
            ),
          ),
          subtitle: Wrap(
            spacing: 6,
            runSpacing: 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ?_memberLine(bots, group),
              if (group.members.isNotEmpty)
                Text(
                  '·',
                  style: TextStyle(
                    fontSize: 12,
                    color: SettingsColors.textQuaternary,
                  ),
                ),
              _headerLine(
                _labels(context, 'Default lead: $leadName', '默认主理人：$leadName'),
              ),
            ],
          ),
          onBack: widget.onBack,
          action: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 4,
            children: [
              IconButton(
                tooltip: _labels(context, 'Change default lead', '更换默认主理人'),
                style: botToolbarIconButtonStyle(context),
                onPressed: group.members.isEmpty ? null : _changeLead,
                icon: const Icon(Icons.swap_horiz, size: 17),
              ),
              IconButton(
                tooltip: _labels(context, 'Edit group', '编辑群聊'),
                style: botToolbarIconButtonStyle(context),
                onPressed: widget.onEdit,
                icon: const Icon(Icons.edit_outlined, size: 17),
              ),
            ],
          ),
        ),
        Expanded(
          child: messages.isEmpty
              ? BotEmptyState(
                  label: group.name,
                  icon: Icons.groups_outlined,
                  title: _labels(context, 'No messages yet', '还没有消息'),
                  description: _labels(
                    context,
                    'Mention @bot or send a message to kick off a group turn.',
                    '发送消息或使用 @提及 指定机器人加入对话。',
                  ),
                )
              : SelectionArea(
                  child: ScrollEdgeFade(
                    child: ListView.builder(
                      controller: _scroll,
                      reverse: true,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      itemCount: messages.length,
                      itemBuilder: (context, index) {
                        final i = messages.length - index - 1;
                        final message = messages[i];
                        final prev = i > 0 ? messages[i - 1] : null;
                        final grouped = shouldGroupBotMessage(
                          sameSender:
                              prev != null &&
                              !prev.notice &&
                              !message.notice &&
                              prev.mine == message.mine &&
                              (message.mine || prev.from == message.from),
                          previousAt: prev == null ||
                                  prev.at.millisecondsSinceEpoch == 0
                              ? null
                              : prev.at,
                          currentAt: message.at.millisecondsSinceEpoch == 0
                              ? null
                              : message.at,
                        );
                        return _centered(
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 18),
                            child: _GroupMessage(
                              bots: bots,
                              group: group,
                              message: message,
                              grouped: grouped,
                              lookupQuote: (seq) => messages
                                  .where((item) => item.seq == seq && !item.notice)
                                  .firstOrNull,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
        ),
        _centered(
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 16),
            child: ListenableBuilder(
              listenable: _focus,
              builder: (context, child) => AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                decoration: BoxDecoration(
                  color: AppColors.bubbleFill,
                  border: Border.all(
                    color: _focus.hasFocus
                        ? AppColors.accent.withValues(alpha: 0.72)
                        : AppColors.bubbleBorder(),
                  ),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: child,
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 2, 6, 6),
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
                          focusNode: _focus,
                          minLines: 1,
                          maxLines: 5,
                          style: TextStyle(
                            fontSize: 13.5,
                            color: SettingsColors.textPrimary,
                          ),
                          decoration: InputDecoration(
                            hintText: context.l10n.editorStartTyping,
                            hintStyle: TextStyle(
                              fontSize: 13.5,
                              color: SettingsColors.textQuaternary,
                            ),
                            border: InputBorder.none,
                            contentPadding: const EdgeInsets.fromLTRB(
                              12,
                              10,
                              8,
                              6,
                            ),
                          ),
                        ),
                      ),
                    ),
                    ValueListenableBuilder(
                      valueListenable: _input,
                      builder: (context, value, _) {
                        final canSend = value.text.trim().isNotEmpty;
                        return IconButton(
                          tooltip: context.l10n.cmdChatSubmit,
                          style: IconButton.styleFrom(
                            minimumSize: const Size.square(32),
                            fixedSize: const Size.square(32),
                            padding: EdgeInsets.zero,
                            backgroundColor: canSend
                                ? buttonBg
                                : SettingsColors.hover,
                            foregroundColor: canSend
                                ? buttonFg
                                : SettingsColors.textQuaternary,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(9),
                            ),
                          ),
                          onPressed: canSend ? _send : null,
                          icon: const Icon(Icons.arrow_upward, size: 17),
                        );
                      },
                    ),
                  ],
                ),
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
    this.grouped = false,
  });
  final Bots bots;
  final BotGroup group;
  final LinkGroupMessage message;
  final LinkGroupMessage? Function(int) lookupQuote;
  final bool grouped;

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
    if (message.notice) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: SettingsColors.card,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: SettingsColors.stroke),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Text(
                message.text,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11.5,
                  color: SettingsColors.textSecondary,
                ),
              ),
            ),
          ),
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
      grouped: grouped,
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
    builder: (context, _) => BotModernDialog(
      width: 440,
      icon: Icons.groups_outlined,
      title: _editing
          ? _labels(context, 'Edit group', '编辑群聊')
          : _labels(context, 'New group', '新建群聊'),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          TextField(
            controller: _name,
            style: TextStyle(
              fontSize: 13.5,
              color: SettingsColors.textPrimary,
            ),
            decoration: botEditorInput(_labels(context, 'Group name', '群名称')),
          ),
          BotEditorSection(
            title: _labels(context, 'Members', '群成员'),
            children: [
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
              const SizedBox(height: 4),
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
        ],
      ),
      actions: [
        TextButton(
          style: botEditorTonalButtonStyle(context),
          onPressed: () => Navigator.pop(context),
          child: Text(context.l10n.commonCancel),
        ),
        FilledButton(
          style: botEditorButtonStyle(context),
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
    this.avatar,
    this.titleBadge,
    this.subtitle,
    required this.onBack,
    this.action,
  });
  final String title;
  final Widget? avatar;
  final Widget? titleBadge;
  final Widget? subtitle;
  final VoidCallback onBack;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 16, 8),
        child: Row(
          children: [
            IconButton(
              tooltip: context.l10n.chatBack,
              style: botToolbarIconButtonStyle(context),
              onPressed: onBack,
              icon: const BackButtonIcon(),
            ),
            const SizedBox(width: 8),
            if (avatar case final badge?) ...[badge, const SizedBox(width: 10)],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        flex: 2,
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            color: SettingsColors.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if (titleBadge case final pill?) ...[
                        const SizedBox(width: 8),
                        Flexible(fit: FlexFit.loose, child: pill),
                      ],
                    ],
                  ),
                  if (subtitle case final sub?) ...[
                    const SizedBox(height: 2),
                    sub,
                  ],
                ],
              ),
            ),
            if (action case final trailing?) ...[
              const SizedBox(width: 8),
              trailing,
            ],
          ],
        ),
      ),
      Container(height: 1, color: SettingsColors.divider),
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
  style: TextStyle(fontSize: 12, color: SettingsColors.textSecondary),
);

Widget _centered(Widget child) => Align(
  child: ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 780),
    child: SizedBox(width: double.infinity, child: child),
  ),
);

String _labels(BuildContext context, String english, String chinese) =>
    Localizations.localeOf(context).languageCode == 'zh' ? chinese : english;
