import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../ide/file_service.dart';
import '../l10n/l10n.dart';
import '../workspace/window_controls.dart';
import 'bot.dart';
import 'bot_memory_migration.dart';
import 'bots.dart';

Future<void> showDesktopBotMemoryMigration(
  BuildContext context,
  Bots bots,
  Bot bot,
) => showDialog<void>(
  context: context,
  builder: (_) => _MigrationDialog(bots: bots, bot: bot),
);

class _MigrationDialog extends StatefulWidget {
  const _MigrationDialog({required this.bots, required this.bot});

  final Bots bots;
  final Bot bot;

  @override
  State<_MigrationDialog> createState() => _MigrationDialogState();
}

class _MigrationDialogState extends State<_MigrationDialog> {
  BotMemoryMirror _source = BotMemoryMirror.memory;
  BotLegacyMarkdownBackup? _backup;
  bool _changed = false;
  bool _busy = false;
  String? _backupError;
  String? _mirrorError;
  String? _message;
  String? _error;

  String _tr(String en, String zh) =>
      Localizations.maybeLocaleOf(context)?.languageCode == 'zh' ? zh : en;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _changed = false;
    _backup = null;
    _backupError = null;
    _mirrorError = null;
    try {
      _changed = widget.bots.ownerMemoryMirrorChanged(widget.bot, _source);
    } on Object catch (error) {
      _mirrorError = '$error';
    }
    try {
      _backup = widget.bots.ownerMemoryBackup(widget.bot, _source);
    } on Object catch (error) {
      _backupError = '$error';
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      await action();
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = localizedFileError(context.l10n, error));
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _load();
        });
      }
    }
  }

  Future<void> _export({required bool archive}) => _run(() async {
    final source = _source;
    final backup = _backup;
    final prefix = source.fileName.split('.').first;
    final path = await WindowControls.pickSaveFile(
      name: archive ? '$prefix-original.md' : '$prefix-current.json',
    );
    if (path == null || !mounted) return;
    final Uint8List bytes;
    if (archive) {
      final saved = widget.bots.ownerMemoryBackup(widget.bot, source);
      if (saved == null || saved.digest != backup?.digest) {
        throw StateError(
          _tr('The backup changed. Reload and try again.', '备份已变更，请重新加载后重试。'),
        );
      }
      bytes = saved.bytes;
    } else {
      bytes = widget.bots.ownerMemoryExport(widget.bot, source);
    }
    await IdeFileService('').writeBytes(path, bytes);
    if (mounted) setState(() => _message = _tr('Export saved.', '已保存导出文件。'));
  });

  Future<void> _viewBackup(BotLegacyMarkdownBackup backup) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(_tr('Original ${backup.source}', '${backup.source} 备份原文')),
      content: SizedBox(
        width: 640,
        height: 400,
        child: ListView(
          children: [
            Text('SHA-256 ${backup.digest}'),
            const SizedBox(height: 12),
            SelectableText(utf8.decode(backup.bytes, allowMalformed: true)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(MaterialLocalizations.of(context).closeButtonLabel),
        ),
      ],
    ),
  );

  Future<void> _review({required bool restore}) => _run(() async {
    final preview = widget.bots.previewOwnerMemoryMigration(
      widget.bot,
      _source,
      restore: restore,
    );
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          restore
              ? _tr('Review backup restore', '核对备份恢复内容')
              : _tr('Review Markdown import', '核对 Markdown 导入内容'),
        ),
        content: SizedBox(
          width: 640,
          height: 400,
          child: ListView(
            children: [
              Text(
                preview.hasChanges
                    ? _tr(
                        '${preview.added} entries added · ${preview.removed} removed',
                        '新增 ${preview.added} 项 · 移除 ${preview.removed} 项',
                      )
                    : _tr(
                        'There are no changes to saved memory.',
                        '已保存的记忆没有变更。',
                      ),
              ),
              const Divider(),
              Text(_tr('Saved now', '当前已保存')),
              SelectableText(
                preview.before.isEmpty ? _tr('(empty)', '（空）') : preview.before,
              ),
              const Divider(),
              Text(_tr('After applying', '应用后')),
              SelectableText(
                preview.after.isEmpty ? _tr('(empty)', '（空）') : preview.after,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.commonCancel),
          ),
          if (preview.hasChanges)
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(
                restore
                    ? _tr('Restore notes', '恢复笔记')
                    : _tr('Import changes', '导入变更'),
              ),
            ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    widget.bots.applyOwnerMemoryMigration(preview);
    setState(() => _message = _tr('Memory saved.', '已保存记忆。'));
  });

  @override
  Widget build(BuildContext context) {
    final backup = _backup;
    return AlertDialog(
      title: Text(_tr('Legacy memory', '旧版记忆')),
      content: SizedBox(
        width: 560,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: DropdownButton<BotMemoryMirror>(
                    isExpanded: true,
                    value: _source,
                    items: [
                      for (final source in BotMemoryMirror.values)
                        DropdownMenuItem(
                          value: source,
                          child: Text(source.fileName),
                        ),
                    ],
                    onChanged: _busy
                        ? null
                        : (source) {
                            if (source == null) return;
                            setState(() {
                              _source = source;
                              _message = null;
                              _error = null;
                              _load();
                            });
                          },
                  ),
                ),
                IconButton(
                  tooltip: _tr('Check for changes', '检查变更'),
                  onPressed: _busy ? null : () => _run(() async {}),
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            if (_busy) const LinearProgressIndicator(),
            const SizedBox(height: 12),
            Text(
              _mirrorError ??
                  (_changed
                      ? _tr(
                          'The Markdown file differs from its last known version.',
                          'Markdown 文件与已知版本不同。',
                        )
                      : _tr('No external changes detected.', '没有检测到外部修改。')),
            ),
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: _busy || !_changed
                      ? null
                      : () => _review(restore: false),
                  child: Text(_tr('Review changes', '查看变更')),
                ),
                if (WindowControls.canPickFiles)
                  TextButton(
                    onPressed: _busy || _mirrorError != null
                        ? null
                        : () => _export(archive: false),
                    child: Text(_tr('Export current entries', '导出当前条目')),
                  ),
              ],
            ),
            const Divider(),
            if (backup == null)
              Text(
                _backupError ??
                    _tr('No original backup is available.', '暂无原始备份。'),
              )
            else ...[
              Text(
                backup.possiblyMirrored
                    ? _tr(
                        'The earliest available backup may already include mirrored edits.',
                        '最早可取得的备份可能已经包含镜像写入的改动。',
                      )
                    : _tr('Original backup available.', '原始备份可用。'),
              ),
              Text(
                _tr(
                  'Restore adds missing notes to saved memory.',
                  '恢复会把缺少的旧笔记加入已保存的记忆。',
                ),
              ),
              Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: _busy ? null : () => _viewBackup(backup),
                    child: Text(_tr('View backup', '查看备份')),
                  ),
                  if (WindowControls.canPickFiles)
                    TextButton(
                      onPressed: _busy ? null : () => _export(archive: true),
                      child: Text(_tr('Export original backup', '导出原始备份')),
                    ),
                  TextButton(
                    onPressed: _busy ? null : () => _review(restore: true),
                    child: Text(_tr('Review restore', '查看恢复内容')),
                  ),
                ],
              ),
            ],
            if (_message case final message?) Text(message),
            if (_error case final error?)
              Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: Text(MaterialLocalizations.of(context).closeButtonLabel),
        ),
      ],
    );
  }
}
