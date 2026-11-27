import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../settings/pages/settings_widgets.dart' show SettingsColors;
import '../theme/app_theme.dart';
import 'bot.dart';
import 'bot_memory_provider_settings.dart';
import 'bots.dart';
import 'desktop_bot_editor_ui.dart';
import 'desktop_bot_memory.dart';
import 'desktop_bot_memory_migration.dart';

/// Creates or edits a bot in the same store used by the phone.
class DesktopBotSettings extends StatefulWidget {
  const DesktopBotSettings({
    super.key,
    required this.bots,
    this.bot,
    this.drawer = false,
    required this.onBack,
  });

  final Bots bots;
  final Bot? bot;
  final bool drawer;
  final VoidCallback onBack;

  @override
  State<DesktopBotSettings> createState() => _DesktopBotSettingsState();
}

class _DesktopBotSettingsState extends State<DesktopBotSettings> {
  final _form = GlobalKey<FormState>();
  final _nameField = GlobalKey();
  final _nameFocus = FocusNode();
  final _name = TextEditingController();
  final _gender = TextEditingController();
  final _signature = TextEditingController();
  final _identity = TextEditingController();
  final _style = TextEditingController();
  Bot? _initial;
  BotAvatarImage? _picture;
  bool _monitorsAgentActivity = false;
  bool _writesFirst = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadDraft();
  }

  @override
  void didUpdateWidget(DesktopBotSettings oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bots != widget.bots || oldWidget.bot?.id != widget.bot?.id) {
      _loadDraft();
    } else if (oldWidget.bot?.avatar != widget.bot?.avatar) {
      _loadPicture();
    }
  }

  void _loadDraft() {
    _error = null;
    final bot = _initial = widget.bot;
    _loadPicture();
    _name.text = bot?.name ?? '';
    _gender.text = bot?.gender ?? '';
    _signature.text = bot?.signature ?? '';
    _identity.text = bot?.identity ?? '';
    _style.text = bot?.style ?? '';
    _monitorsAgentActivity = bot?.can(BotAbility.proactive) ?? false;
    _writesFirst = bot?.writesFirst ?? true;
  }

  void _loadPicture() {
    final bot = widget.bot;
    _picture = bot == null ? null : widget.bots.avatarImage(bot);
  }

  @override
  void dispose() {
    _nameFocus.dispose();
    _name.dispose();
    _gender.dispose();
    _signature.dispose();
    _identity.dispose();
    _style.dispose();
    super.dispose();
  }

  void _save() {
    if (!_form.currentState!.validate()) {
      if (_nameField.currentContext case final context?) {
        Scrollable.ensureVisible(context, alignment: .15);
      }
      _nameFocus.requestFocus();
      return;
    }
    final bots = widget.bots;
    if (bots.folders.root == null) {
      setState(() => _error = _label('Could not save the bot.', '无法保存 Bot。'));
      return;
    }
    final initial = _initial;
    final current = initial == null ? null : bots.byId(initial.id);
    if (initial != null && current == null) {
      setState(() => _error = _label('This bot was deleted.', '此 Bot 已删除。'));
      return;
    }

    // Merge field by field so saving the draft keeps edits made on the phone
    // (or in the bot's files) while this page was open.
    T edited<T>(T draft, T? original, T? latest) =>
        latest != null && draft == original ? latest : draft;

    // Keep the stored tool abilities for compatibility with existing callers.
    final abilities = {...?current?.abilities}..remove(BotAbility.proactive);
    if (edited(
      _monitorsAgentActivity,
      initial?.can(BotAbility.proactive),
      current?.can(BotAbility.proactive),
    )) {
      abilities.add(BotAbility.proactive);
    }

    bots.save(
      id: current?.id,
      name: edited(_name.text.trim(), initial?.name, current?.name),
      avatar: current?.avatar,
      gender: edited(_gender.text.trim(), initial?.gender, current?.gender),
      signature: edited(
        _signature.text.trim(),
        initial?.signature,
        current?.signature,
      ),
      identity: edited(
        _identity.text.trim(),
        initial?.identity,
        current?.identity,
      ),
      style: edited(_style.text.trim(), initial?.style, current?.style),
      abilities: abilities,
      proactive: current?.proactive ?? const BotProactive(),
      writesFirst: edited(
        _writesFirst,
        initial?.writesFirst,
        current?.writesFirst,
      ),
    );
    widget.onBack();
  }

  String _label(String en, String zh) =>
      Localizations.localeOf(context).languageCode == 'zh' ? zh : en;

  Future<void> _delete() async {
    final id = _initial?.id;
    final bots = widget.bots;
    final bot = id == null ? null : bots.byId(id);
    if (bot == null || bot.assistant) return;

    final l10n = context.l10n;

    final title = _label('Delete ${bot.name}?', '删除 ${bot.name}？');
    final warning = _label(
      'This permanently deletes the bot, its private conversation, and its memory.',
      '这会永久删除该 Bot、其私聊记录和记忆。',
    );
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => BotModernDialog(
        width: 440,
        icon: Icons.delete_outline,
        warning: true,
        title: title,
        body: Text(
          warning,
          style: TextStyle(
            fontSize: 13.5,
            height: 1.5,
            color: SettingsColors.textSecondary,
          ),
        ),
        actions: [
          TextButton(
            autofocus: true,
            style: botEditorTonalButtonStyle(context),
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            style: botEditorButtonStyle(context, destructive: true),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.commonDelete),
          ),
        ],
      ),
    );
    if (!mounted ||
        confirmed != true ||
        !identical(widget.bots, bots) ||
        _initial?.id != bot.id) {
      return;
    }
    if (bots.byId(bot.id)?.assistant != false) return;
    bots.delete(bot.id);
    widget.onBack();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final label = _label;
    final creating = _initial == null;

    Widget permission(
      String title,
      String subtitle,
      bool value,
      ValueChanged<bool> onChanged,
    ) => BotEditorSwitchTile(
      title: title,
      subtitle: subtitle,
      value: value,
      onChanged: (value) => setState(() => onChanged(value)),
    );

    Widget tileDivider() => Container(
      height: 1,
      margin: const EdgeInsets.symmetric(horizontal: 6),
      color: SettingsColors.divider,
    );

    final bot = widget.bot;
    final avatar = bot?.avatar;
    final picture = _picture;
    return Material(
      color: AppColors.conversationSurface,
      child: BotEditorLayout(
        title: creating
            ? label('New bot', '新建 Bot')
            : label('Bot settings', 'Bot 设置'),
        name: bot?.name,
        icon: Icons.smart_toy_outlined,
        avatar: picture != null
            ? Image.memory(
                picture.bytes,
                width: 40,
                height: 40,
                fit: BoxFit.cover,
                cacheWidth: 80,
                errorBuilder: (_, _, _) => const Icon(Icons.smart_toy_outlined),
                semanticLabel: label('Avatar', '头像'),
              )
            : avatar != null && avatar.isNotEmpty && !isAvatarImage(avatar)
            ? Text(avatar, maxLines: 1, style: const TextStyle(fontSize: 22))
            : null,
        close: IconButton(
          tooltip: widget.drawer
              ? MaterialLocalizations.of(context).closeButtonTooltip
              : l10n.chatBack,
          onPressed: widget.onBack,
          icon: widget.drawer
              ? const Icon(Icons.close)
              : const BackButtonIcon(),
        ),
        status: switch (_error) {
          final String error => Semantics(
            liveRegion: true,
            child: Text(
              error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
          null => null,
        },
        actions: BotEditorActions(
          children: [
            TextButton(
              style: botEditorTonalButtonStyle(context),
              onPressed: widget.onBack,
              child: Text(l10n.commonCancel),
            ),
            FilledButton(
              style: botEditorButtonStyle(context),
              onPressed: _save,
              child: Text(
                creating ? label('Create bot', '创建 Bot') : l10n.commonSave,
              ),
            ),
          ],
        ),
        body: Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 14,
            children: [
              BotEditorSection(
                title: label('Profile', '基本资料'),
                children: [
                  _field(
                    _name,
                    label('Name', '名称'),
                    key: _nameField,
                    focusNode: _nameFocus,
                    validator: (value) => value!.trim().isEmpty
                        ? label('Enter a name.', '请输入名称。')
                        : null,
                  ),
                  _field(_gender, label('Gender', '性别')),
                  _field(_signature, label('Signature', '签名')),
                ],
              ),
              BotEditorSection(
                title: label('Persona', '角色设定'),
                children: [
                  _field(_identity, label('Identity', '身份设定'), multiline: true),
                  _field(
                    _style,
                    label('Speaking style', '说话风格'),
                    multiline: true,
                  ),
                ],
              ),
              BotEditorSection(
                title: label('Tool access', '工具权限'),
                children: [
                  Text(
                    label(
                      'Private chats and Bot groups have full access to files, '
                          'shell commands, the browser, agent sessions, and other BaoCode tools, '
                          'including your configured MCP tools. Access is limited by BaoCode’s OS permissions.',
                      '私聊和 Bot 群聊都可以完整使用文件、终端命令、浏览器、智能体会话及其他 BaoCode 工具，'
                          '包括你配置的 MCP 工具。访问范围受 BaoCode 的操作系统权限约束。',
                    ),
                  ),
                ],
              ),
              BotEditorSection(
                title: label('Messaging', '消息设置'),
                children: [
                  Column(
                    children: [
                      permission(
                        label('Monitor agent activity', '关注智能体动态'),
                        label(
                          'Can receive agent updates and notify your linked phone.',
                          '可以接收智能体动态并通知已连接的手机。',
                        ),
                        _monitorsAgentActivity,
                        (enabled) => _monitorsAgentActivity = enabled,
                      ),
                      tileDivider(),
                      permission(
                        label('Can message you first', '可以主动给你发消息'),
                        label(
                          'Allows private messages from a group without a recent message from you.',
                          '即使你最近没有发消息，也可以从群聊主动私信你。',
                        ),
                        _writesFirst,
                        (enabled) => _writesFirst = enabled,
                      ),
                    ],
                  ),
                ],
              ),
              if (bot != null)
                BotEditorSection(
                  title: label('Memory', '记忆'),
                  children: [
                    Column(
                      children: [
                        BotEditorNavTile(
                          icon: Icons.auto_stories_outlined,
                          tint: AppColors.accent,
                          title: label('Memory and review', '记忆与审核'),
                          subtitle: label(
                            'View preferences, facts, skills, and review proposals',
                            '查看偏好、事实、技能与复盘提案',
                          ),
                          onTap: () =>
                              showLocalBotMemory(context, widget.bots, bot),
                        ),
                        tileDivider(),
                        BotEditorNavTile(
                          icon: Icons.cloud_outlined,
                          tint: const Color(0xFF56B6C2),
                          title: label('External memory', '外部记忆'),
                          subtitle: label(
                            'Configure a read-only HTTPS recall endpoint',
                            '配置专用的只读 HTTPS 外部检索接口',
                          ),
                          onTap: () => showBotMemoryProviderSettings(
                            context,
                            widget.bots,
                            bot,
                          ),
                        ),
                        tileDivider(),
                        BotEditorNavTile(
                          icon: Icons.swap_horiz_rounded,
                          tint: AppColors.added,
                          title: label('Import & migration', '导入与迁移'),
                          subtitle: label(
                            'Import Hermes files, sync Markdown mirrors, and restore backups',
                            '导入 Hermes 文件（MEMORY.md / USER.md）、同步镜像与恢复备份',
                          ),
                          onTap: () => showDesktopBotMemoryMigration(
                            context,
                            widget.bots,
                            bot,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              if (_initial?.assistant == false)
                BotEditorSection(
                  title: label('Destructive actions', '危险操作'),
                  danger: true,
                  children: [
                    BotEditorDangerButton(
                      icon: Icons.delete_outline,
                      label: label('Delete bot', '删除 Bot'),
                      onPressed: _delete,
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    Key? key,
    bool multiline = false,
    FocusNode? focusNode,
    FormFieldValidator<String>? validator,
  }) => BotEditorInsetField(
    fieldKey: key,
    controller: controller,
    focusNode: focusNode,
    label: label,
    multiline: multiline,
    validator: validator,
  );
}
