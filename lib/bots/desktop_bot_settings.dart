import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
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
  final _abilities = <BotAbility>{};
  bool _chatOnly = false;
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
    _abilities
      ..clear()
      ..addAll(bot?.abilities ?? const {});
    _chatOnly = bot?.chatOnly ?? false;
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
      abilities: {
        for (final ability in BotAbility.values)
          if (edited(
            _abilities.contains(ability),
            initial?.can(ability),
            current?.can(ability),
          ))
            ability,
      },
      proactive: current?.proactive ?? const BotProactive(),
      chatOnly: edited(_chatOnly, initial?.chatOnly, current?.chatOnly),
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
      builder: (context) => AlertDialog(
        scrollable: true,
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        constraints: const BoxConstraints(maxWidth: 440),
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: AppColors.partBorder),
        ),
        icon: const Align(
          alignment: AlignmentDirectional.centerStart,
          child: BotEditorIcon(icon: Icons.delete_outline, warning: true),
        ),
        title: Text(
          title,
          textAlign: TextAlign.start,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        content: Text(warning),
        actionsOverflowButtonSpacing: 8,
        actions: [
          OutlinedButton(
            autofocus: true,
            style: botEditorButtonStyle(context),
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
    ) => SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: Text(subtitle),
      value: value,
      onChanged: (value) => setState(() => onChanged(value)),
    );

    Widget ability(BotAbility ability, String title, String subtitle) =>
        permission(title, subtitle, _abilities.contains(ability), (enabled) {
          if (enabled) {
            _abilities.add(ability);
          } else {
            _abilities.remove(ability);
          }
        });

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
            OutlinedButton(
              style: botEditorButtonStyle(context),
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
            spacing: 12,
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
                title: label('Permissions', '权限'),
                children: [
                  permission(
                    label('Chat only', '仅聊天'),
                    label(
                      'Disables file changes and shell commands.',
                      '禁止修改文件和运行命令。',
                    ),
                    _chatOnly,
                    (enabled) => _chatOnly = enabled,
                  ),
                  ability(
                    BotAbility.agents,
                    label('Manage agents', '管理智能体'),
                    label(
                      'Can view and control your agent sessions.',
                      '可以查看和控制你的智能体会话。',
                    ),
                  ),
                  ability(
                    BotAbility.browser,
                    label('Use the browser', '使用浏览器'),
                    label('Can interact with your browser.', '可以操作你的浏览器。'),
                  ),
                  ability(
                    BotAbility.proactive,
                    label('Monitor agent activity', '关注智能体动态'),
                    label(
                      'Can receive agent updates and notify your linked phone.',
                      '可以接收智能体动态并通知已连接的手机。',
                    ),
                  ),
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
              if (bot != null)
                BotEditorSection(
                  title: label('Memory', '记忆'),
                  children: [
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: OutlinedButton.icon(
                        onPressed: () =>
                            showLocalBotMemory(context, widget.bots, bot),
                        icon: const Icon(Icons.notes_outlined),
                        label: Text(label('Memory and review', '记忆与审核')),
                      ),
                    ),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: OutlinedButton.icon(
                        onPressed: () => showBotMemoryProviderSettings(
                          context,
                          widget.bots,
                          bot,
                        ),
                        icon: const Icon(Icons.cloud_outlined),
                        label: Text(label('External memory', '外部记忆')),
                      ),
                    ),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: OutlinedButton.icon(
                        onPressed: () => showDesktopBotMemoryMigration(
                          context,
                          widget.bots,
                          bot,
                        ),
                        icon: const Icon(Icons.restore_outlined),
                        label: Text(label('Legacy memory', '旧版记忆')),
                      ),
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
  }) => TextFormField(
    key: key,
    controller: controller,
    focusNode: focusNode,
    minLines: multiline ? 2 : 1,
    maxLines: multiline ? 8 : 1,
    textInputAction: multiline ? TextInputAction.newline : TextInputAction.next,
    decoration: botEditorInput(label, multiline: multiline),
    validator: validator,
  );
}
