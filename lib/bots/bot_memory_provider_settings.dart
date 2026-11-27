import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../settings/pages/settings_widgets.dart' show SettingsColors;
import 'bot.dart';
import 'bot_memory_provider.dart';
import 'bots.dart';
import 'desktop_bot_editor_ui.dart';

Future<void> showBotMemoryProviderSettings(
  BuildContext context,
  Bots bots,
  Bot bot,
) async {
  final provider = botMemoryProvider(bots, bot);
  if (provider == null) return;
  await showDialog<void>(
    context: context,
    builder: (context) => _ProviderSettings(
      provider: provider,
      botName: bot.name,
      isCurrent: () {
        final live = bots.byId(bot.id);
        return live != null && live.created == bot.created;
      },
    ),
  );
}

class _ProviderSettings extends StatefulWidget {
  const _ProviderSettings({
    required this.provider,
    required this.botName,
    required this.isCurrent,
  });

  final BotMemoryProvider provider;
  final String botName;
  final bool Function() isCurrent;

  @override
  State<_ProviderSettings> createState() => _ProviderSettingsState();
}

class _ProviderSettingsState extends State<_ProviderSettings> {
  final _endpoint = TextEditingController();
  Uri? _enabled;
  bool _consented = false;
  bool _loading = true;
  bool _saving = false;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final endpoint = await widget.provider.enabledEndpoint();
    if (!mounted) return;
    setState(() {
      _enabled = endpoint;
      _endpoint.text = endpoint?.toString() ?? '';
      _loading = false;
    });
  }

  @override
  void dispose() {
    _endpoint.dispose();
    super.dispose();
  }

  Future<void> _save(Uri? endpoint) async {
    if (!widget.isCurrent()) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      _error = false;
      _saving = true;
    });
    try {
      await widget.provider.setConsentedEndpoint(endpoint);
      if (mounted) Navigator.pop(context);
    } on Object {
      if (!mounted) return;
      setState(() {
        _error = true;
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final chinese = Localizations.localeOf(context).languageCode == 'zh';
    String label(String en, String zh) => chinese ? zh : en;
    final endpoint = BotMemoryProvider.parseEndpoint(_endpoint.text);
    final enabled = _enabled != null;
    const tealAccent = Color(0xFF56B6C2);
    return BotModernDialog(
      width: 500,
      icon: Icons.cloud_outlined,
      accentColor: tealAccent,
      title: label('External memory', '外部记忆'),
      subtitle: label(
        'Read-only HTTPS recall for ${widget.botName}’s private chat on this computer',
        '仅用于此电脑上 ${widget.botName} 的私聊只读检索',
      ),
      headerTrailing: _loading
          ? null
          : BotStatusPill(
              label: enabled ? label('Enabled', '已启用') : label('Off', '已关闭'),
              tone: enabled ? BotEditorTone.success : BotEditorTone.neutral,
            ),
      busy: _loading || _saving,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        spacing: 16,
        children: [
          BotEditorNotice(
            tone: BotEditorTone.accent,
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: label(
                      'In private chat, send ',
                      '如需外部检索，请在私聊中发送 ',
                    ),
                  ),
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: BotCodeChip(
                      botExternalRecallCommand,
                      color: tealAccent,
                    ),
                  ),
                  TextSpan(
                    text: label(
                      ' followed by your search words. Only those words are sent, and the provider may log exact queries—keep secrets out of queries.',
                      '，后接空格和搜索词。接口仅收到搜索词，提供方可能记录完整查询，请勿加入机密信息。',
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (!_loading) ...[
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 7,
              children: [
                Text(
                  label('HTTPS recall endpoint', 'HTTPS 检索接口'),
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    color: SettingsColors.textSecondary,
                  ),
                ),
                TextField(
                  controller: _endpoint,
                  enabled: !_saving,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  enableSuggestions: false,
                  onChanged: (_) => setState(() => _consented = false),
                  style: TextStyle(
                    fontSize: 13.5,
                    color: SettingsColors.textPrimary,
                  ),
                  decoration: botEditorInput(
                    null,
                    hintText: 'https://memory.example/recall',
                    errorText: _endpoint.text.isNotEmpty && endpoint == null
                        ? label(
                            'Use HTTPS without credentials, a query string, or a fragment.',
                            '请使用不含凭据、查询参数或片段的 HTTPS 地址。',
                          )
                        : null,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      Text(
                        label('Protocol:', '接口格式：'),
                        style: TextStyle(
                          fontSize: 12,
                          color: SettingsColors.textTertiary,
                        ),
                      ),
                      const BotCodeChip('POST {"query":"…"}'),
                      Text(
                        '→',
                        style: TextStyle(
                          fontSize: 12,
                          color: SettingsColors.textTertiary,
                        ),
                      ),
                      const BotCodeChip('{"results":[{"text":"…"}]}'),
                    ],
                  ),
                ),
              ],
            ),
            BotEditorCard(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              borderColor: _consented
                  ? tealAccent.withValues(alpha: 0.45)
                  : null,
              child: CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _consented,
                onChanged: _saving || endpoint == null
                    ? null
                    : (value) => setState(() => _consented = value ?? false),
                title: Text(
                  label(
                    'I allow this endpoint to receive my explicit recall queries.',
                    '我允许此接口接收我明确发起的检索查询。',
                  ),
                  style: TextStyle(
                    fontSize: 12.5,
                    color: endpoint == null
                        ? SettingsColors.textTertiary
                        : SettingsColors.textPrimary,
                  ),
                ),
              ),
            ),
            if (_error)
              BotEditorNotice(
                tone: BotEditorTone.danger,
                message: label('Could not save the setting.', '无法保存设置。'),
              ),
          ],
        ],
      ),
      footerLeading: enabled
          ? TextButton(
              style: botEditorTonalButtonStyle(context, destructive: true),
              onPressed: _saving ? null : () => _save(null),
              child: Text(label('Disable', '关闭')),
            )
          : null,
      actions: [
        TextButton(
          style: botEditorTonalButtonStyle(context),
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: Text(context.l10n.commonCancel),
        ),
        FilledButton(
          style: botEditorButtonStyle(context),
          onPressed: _saving || !_consented || endpoint == null
              ? null
              : () => _save(endpoint),
          child: Text(label('Enable', '启用')),
        ),
      ],
    );
  }
}
