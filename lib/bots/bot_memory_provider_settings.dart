import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'bot.dart';
import 'bot_memory_provider.dart';
import 'bots.dart';

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
    return AlertDialog(
      scrollable: true,
      constraints: const BoxConstraints(maxWidth: 520),
      title: Text(label('External memory', '外部记忆')),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        spacing: 12,
        children: [
          Text(
            label(
              'Use a read-only HTTPS provider dedicated to ${widget.botName}’s private chat on this computer.',
              '为此电脑上 ${widget.botName} 的私聊配置专用的只读 HTTPS 提供方。',
            ),
          ),
          Text(
            label(
              'To request external recall, send $botExternalRecallCommand followed by your search words in the private chat. Only those words are sent to the endpoint. The provider may record the exact query. Keep secrets out of queries.',
              '如需外部检索，请在私聊中发送 $botExternalRecallCommand，后接一个空格和搜索词。接口只收到搜索词。提供方可能记录完整查询。请勿在查询中加入机密信息。',
            ),
          ),
          if (_loading)
            const LinearProgressIndicator()
          else ...[
            Text(enabled ? label('Enabled', '已启用') : label('Off', '已关闭')),
            TextField(
              controller: _endpoint,
              enabled: !_saving,
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              onChanged: (_) => setState(() => _consented = false),
              decoration: InputDecoration(
                labelText: label('HTTPS recall endpoint', 'HTTPS 检索接口'),
                hintText: 'https://memory.example/recall',
                errorText: _endpoint.text.isNotEmpty && endpoint == null
                    ? label(
                        'Use HTTPS without credentials, a query string, or a fragment.',
                        '请使用不含凭据、查询参数或片段的 HTTPS 地址。',
                      )
                    : null,
              ),
            ),
            Text(
              label(
                'The endpoint accepts POST {"query":"…"} and returns {"results":[{"text":"…"}]}.',
                '接口接收 POST {"query":"…"} 并返回 {"results":[{"text":"…"}]}。',
              ),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _consented,
              onChanged: _saving || endpoint == null
                  ? null
                  : (value) => setState(() => _consented = value ?? false),
              title: Text(
                label(
                  'I allow this endpoint to receive my explicit recall queries.',
                  '我允许此接口接收我明确发起的检索查询。',
                ),
              ),
            ),
            if (_error)
              Text(
                label('Could not save the setting.', '无法保存设置。'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: Text(context.l10n.commonCancel),
        ),
        if (enabled)
          OutlinedButton(
            onPressed: _saving ? null : () => _save(null),
            child: Text(label('Disable', '关闭')),
          ),
        FilledButton(
          onPressed: _saving || !_consented || endpoint == null
              ? null
              : () => _save(endpoint),
          child: Text(label('Enable', '启用')),
        ),
      ],
    );
  }
}
