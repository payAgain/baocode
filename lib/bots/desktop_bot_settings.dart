import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../theme/app_theme.dart';
import 'bot.dart';
import 'bots.dart';

/// Creates or edits a bot in the same store used by the phone.
class DesktopBotSettings extends StatefulWidget {
  const DesktopBotSettings({
    super.key,
    required this.bots,
    this.bot,
    required this.onBack,
  });

  final Bots bots;
  final Bot? bot;
  final VoidCallback onBack;

  @override
  State<DesktopBotSettings> createState() => _DesktopBotSettingsState();
}

class _DesktopBotSettingsState extends State<DesktopBotSettings> {
  final _form = GlobalKey<FormState>();
  final _nameFocus = FocusNode();
  final _name = TextEditingController();
  final _gender = TextEditingController();
  final _signature = TextEditingController();
  final _identity = TextEditingController();
  final _style = TextEditingController();
  Bot? _initial;
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
    }
  }

  void _loadDraft() {
    _error = null;
    final bot = _initial = widget.bot;
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
    final colors = Theme.of(context).colorScheme;
    final title = _label('Delete ${bot.name}?', '删除 ${bot.name}？');
    final warning = _label(
      'This permanently deletes the bot, its private conversation, and its memory.',
      '这会永久删除该 Bot、其私聊记录和记忆。',
    );
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(warning),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: colors.error,
              foregroundColor: colors.onError,
            ),
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

    return Material(
      color: AppColors.conversationSurface,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 4, 12, 4),
            child: Row(
              children: [
                IconButton(
                  tooltip: l10n.chatBack,
                  onPressed: widget.onBack,
                  icon: const BackButtonIcon(),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    creating
                        ? label('New bot', '新建 Bot')
                        : label('Bot settings', 'Bot 设置'),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                FilledButton(
                  onPressed: _save,
                  child: Text(
                    creating ? label('Create bot', '创建 Bot') : l10n.commonSave,
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: AppColors.partBorder),
          if (_error case final error?)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: Form(
                    key: _form,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _field(
                          _name,
                          label('Name', '名称'),
                          focusNode: _nameFocus,
                          validator: (value) => value!.trim().isEmpty
                              ? label('Enter a name.', '请输入名称。')
                              : null,
                        ),
                        _field(_gender, label('Gender', '性别')),
                        _field(_signature, label('Signature', '签名')),
                        _field(
                          _identity,
                          label('Identity', '身份设定'),
                          multiline: true,
                        ),
                        _field(
                          _style,
                          label('Speaking style', '说话风格'),
                          multiline: true,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          label('Permissions', '权限'),
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
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
                          label(
                            'Can interact with your browser.',
                            '可以操作你的浏览器。',
                          ),
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
                        if (_initial?.assistant == false) ...[
                          const SizedBox(height: 12),
                          const Divider(),
                          Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Theme.of(context)
                                    .colorScheme
                                    .error,
                              ),
                              onPressed: _delete,
                              child: Text(label('Delete bot', '删除 Bot')),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    bool multiline = false,
    FocusNode? focusNode,
    FormFieldValidator<String>? validator,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextFormField(
      controller: controller,
      focusNode: focusNode,
      minLines: multiline ? 3 : 1,
      maxLines: multiline ? 8 : 1,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        alignLabelWithHint: multiline,
      ),
      validator: validator,
    ),
  );
}
