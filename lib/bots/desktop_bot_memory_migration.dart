import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../ide/file_service.dart';
import '../l10n/l10n.dart';
import '../workspace/window_controls.dart';
import 'bot.dart';
import 'bot_memory.dart';
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

class _LocalizedMigrationException implements Exception {
  const _LocalizedMigrationException(this.message);

  final String message;

  @override
  String toString() => message;
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

  String _hermesTargetLabel(BotMemoryMirror target) => switch (target) {
    BotMemoryMirror.self => _tr(
      'Private self facts (SELF.md)',
      '私有自身事实（SELF.md）',
    ),
    BotMemoryMirror.memory => _tr(
      'Private preferences (MEMORY.md)',
      '私有用户偏好（MEMORY.md）',
    ),
    BotMemoryMirror.people => _tr(
      'People notes (PEOPLE.md)',
      '人物笔记（PEOPLE.md）',
    ),
  };

  String _formatError(Object error) {
    if (error is _LocalizedMigrationException) return error.message;
    final String raw;
    switch (error) {
      case StateError(:final message):
        raw = message;
      case FormatException(:final message):
        raw = message;
      case ArgumentError(:final message):
        raw = message?.toString() ?? '$error';
      default:
        return localizedFileError(context.l10n, error);
    }
    return switch (raw) {
      'The Markdown changed. Review it again.' ||
      'Saved memory or its Markdown mirror changed. Review again.' ||
      'The saved memory or Markdown changed. Review the differences again.' =>
        _tr(
          'Saved memory or Markdown changed. Review again.',
          '已保存的记忆或 Markdown 已变更，请重新核对。',
        ),
      'This Bot memory is no longer available.' ||
      'This Hermes preview is no longer valid.' => _tr(
        'This Bot memory is no longer available.',
        '此 Bot 记忆已不可用。',
      ),
      'The original backup is unavailable.' => _tr(
        'The original backup is unavailable.',
        '原始备份不可用。',
      ),
      'The Markdown file is missing. A missing file cannot be imported.' => _tr(
        'The Markdown file is missing. A missing file cannot be imported.',
        'Markdown 文件不存在，无法导入。',
      ),
      'This import would bring back a forgotten entry.' => _tr(
        'This import would bring back a forgotten entry.',
        '导入内容包含已遗忘的条目，无法恢复。',
      ),
      'Credentials cannot be imported as memory.' => _tr(
        'Credentials cannot be imported as memory.',
        '包含凭证或密钥的内容不能导入为记忆。',
      ),
      'This import would replace a protected entry.' => _tr(
        'This import would replace a protected entry.',
        '导入内容会覆盖受保护的条目。',
      ),
      'These notes contain mixed Markdown. Edit them in Memory to preserve individual entries.' =>
        _tr(
          'These notes contain mixed Markdown. Edit them in Memory to preserve individual entries.',
          '当前笔记包含混合 Markdown 格式，请在“记忆与审核”中逐条编辑。',
        ),
      _ => raw,
    };
  }

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
      _mirrorError = _formatError(error);
    }
    try {
      _backup = widget.bots.ownerMemoryBackup(widget.bot, _source);
    } on Object catch (error) {
      _backupError = _formatError(error);
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
        setState(() => _error = _formatError(error));
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

  static const _maxImportBytes = 5 * 1024 * 1024;

  Future<void> _reviewHermesImport() async {
    ({
      String fileName,
      String markdown,
      bool plainBulletsWarning,
      BotMemoryMirror? target,
      BotHermesImportPreview? preview,
    })?
    loaded;
    await _run(() async {
      final paths = await WindowControls.pickOpenFiles(
        directory: widget.bots.hermesMemoriesDirectory(),
        multiple: false,
      );
      if (paths.isEmpty || !mounted) return;
      if (paths.length != 1) {
        throw _LocalizedMigrationException(
          _tr(
            'Choose a single Hermes Markdown file.',
            '请选择单个 Hermes Markdown 文件。',
          ),
        );
      }
      final path = paths.single;
      if (widget.bots.isManagedBotMemoryPath(widget.bot, path)) {
        throw _LocalizedMigrationException(
          _tr(
            'Cannot import a file from BaoCode’s own Bot memory folder.',
            '不能从 BaoCode 自身的 Bot 记忆目录中导入文件。',
          ),
        );
      }
      final size = await fileByteSize(path);
      if (size > _maxImportBytes) {
        throw IdeFileTooLargeException(path, size);
      }
      final bytes = await readFileBytes(path);
      final String markdown;
      try {
        markdown = decodeBotMemoryMarkdown(bytes);
      } on FormatException {
        throw _LocalizedMigrationException(
          _tr(
            'The selected file is not valid UTF-8 text.',
            '所选文件不是有效的 UTF-8 文本文件。',
          ),
        );
      }
      if (!mounted) return;
      final fileName = p.basename(path);
      final target = defaultHermesImportTarget(fileName);
      loaded = (
        fileName: fileName,
        markdown: markdown,
        plainBulletsWarning: looksLikeNonHermesBulletList(markdown),
        target: target,
        preview: target == null
            ? null
            : widget.bots.previewHermesMemoryImport(
                widget.bot,
                target,
                markdown,
              ),
      );
    });
    final ready = loaded;
    if (ready == null || !mounted) return;

    final fileName = ready.fileName;
    final markdown = ready.markdown;
    final plainBulletsWarning = ready.plainBulletsWarning;
    var target = ready.target;
    var preview = ready.preview;
    String? previewError;

    final confirmed = await showDialog<BotHermesImportPreview>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, refresh) {
          final current = preview;
          final colorScheme = Theme.of(context).colorScheme;
          return AlertDialog(
            title: Text(_tr('Review Hermes import', '核对 Hermes 导入内容')),
            content: SizedBox(
              width: 640,
              height: 440,
              child: ListView(
                children: [
                  Text(fileName),
                  const SizedBox(height: 8),
                  DropdownButton<BotMemoryMirror>(
                    isExpanded: true,
                    value: target,
                    hint: Text(_tr('Choose target memory', '请选择导入目标')),
                    items: [
                      for (final option in const [
                        BotMemoryMirror.memory,
                        BotMemoryMirror.self,
                      ])
                        DropdownMenuItem(
                          value: option,
                          child: Text(_hermesTargetLabel(option)),
                        ),
                    ],
                    onChanged: (next) {
                      if (next == null || next == target) return;
                      refresh(() {
                        target = next;
                        previewError = null;
                        try {
                          preview = widget.bots.previewHermesMemoryImport(
                            widget.bot,
                            next,
                            markdown,
                          );
                        } on Object catch (error) {
                          preview = null;
                          previewError = _formatError(error);
                        }
                      });
                    },
                  ),
                  if (plainBulletsWarning) ...[
                    const SizedBox(height: 8),
                    Text(
                      _tr(
                        'No Hermes § separator was found, but multiple bullet lines were detected. Without standalone § lines, the whole file will be imported as a single note.',
                        '未检测到 Hermes § 分隔符，但文件包含多条列表项。如果没有独立 § 分隔行，整份内容会作为单条笔记导入。',
                      ),
                      style: TextStyle(color: colorScheme.error),
                    ),
                  ],
                  if (previewError case final error?) ...[
                    const SizedBox(height: 8),
                    Text(error, style: TextStyle(color: colorScheme.error)),
                  ] else if (current == null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _tr(
                        'Choose whether this file imports into private preferences or private self facts.',
                        '请选择将该文件导入到私有用户偏好还是私有自身事实。',
                      ),
                    ),
                  ] else ...[
                    const SizedBox(height: 8),
                    Text(
                      [
                        _tr(
                          'Parsed ${current.sourceCount} · ${current.additions.length} new',
                          '共解析 ${current.sourceCount} 条 · 新增 ${current.additions.length} 条',
                        ),
                        if (current.skippedDuplicates > 0)
                          _tr(
                            '${current.skippedDuplicates} duplicates skipped',
                            '已跳过 ${current.skippedDuplicates} 条重复',
                          ),
                        if (current.blocked.isNotEmpty)
                          _tr(
                            '${current.blocked.length} blocked',
                            '已拦截 ${current.blocked.length} 条',
                          ),
                      ].join(' · '),
                    ),
                    if (!current.hasChanges)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          _tr('No new entries to import.', '没有可导入的新条目。'),
                        ),
                      ),
                    if (current.outsideBudget > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          _tr(
                            '${current.outsideBudget} new entries will be saved outside the prompt budget. Trim older entries in "Memory and review" before adding more.',
                            '${current.outsideBudget} 个新条目会保存，但超出提示词预算；在“记忆与审核”中精简旧条目后才能继续新增。',
                          ),
                        ),
                      ),
                    if (current.hasChanges) ...[
                      const Divider(),
                      for (var i = 0; i < current.additions.length; i++) ...[
                        if (i > 0) const SizedBox(height: 8),
                        Text(
                          current.outsideBudgetIndexes.contains(i)
                              ? '#${i + 1} · ${_tr('Outside prompt budget', '超出提示词预算')}'
                              : '#${i + 1}',
                          style: Theme.of(context).textTheme.labelMedium,
                        ),
                        SelectableText(current.additions[i]),
                      ],
                    ],
                    if (current.blocked.isNotEmpty) ...[
                      const Divider(),
                      Text(
                        _tr('Skipped entries (not imported)', '已拦截条目（不会导入）'),
                        style: TextStyle(color: colorScheme.error),
                      ),
                      for (final item in current.blocked) ...[
                        const SizedBox(height: 6),
                        Text(switch (item.reason) {
                          BotMemoryImportBlockReason.credential => _tr(
                            '#${item.index} · Contains credentials or keys (hidden)',
                            '#${item.index} · 包含凭证或密钥（内容已隐藏）',
                          ),
                          BotMemoryImportBlockReason.forgotten => _tr(
                            '#${item.index} · Previously forgotten',
                            '#${item.index} · 该内容此前已被遗忘',
                          ),
                        }, style: TextStyle(color: colorScheme.error)),
                        if (item.reason !=
                            BotMemoryImportBlockReason.credential)
                          SelectableText(item.text),
                      ],
                    ],
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(context.l10n.commonCancel),
              ),
              if (current != null && current.hasChanges)
                FilledButton(
                  onPressed: () => Navigator.pop(context, current),
                  child: Text(_tr('Import notes', '导入笔记')),
                ),
            ],
          );
        },
      ),
    );
    if (confirmed == null || !mounted) return;
    await _run(() async {
      widget.bots.applyHermesMemoryImport(confirmed);
      if (!mounted) return;
      setState(
        () => _message = _tr(
          'Imported ${confirmed.additions.length} Hermes notes into ${_hermesTargetLabel(confirmed.target)}.',
          '已将 ${confirmed.additions.length} 条 Hermes 笔记导入到${_hermesTargetLabel(confirmed.target)}。',
        ),
      );
    });
  }

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
            if (WindowControls.canPickFiles) ...[
              const Divider(),
              Text(
                _tr(
                  'Import Hermes memory notes from ~/.hermes/memories (MEMORY.md or USER.md).',
                  '从 ~/.hermes/memories 导入 Hermes 记忆笔记（MEMORY.md 或 USER.md）。',
                ),
              ),
              TextButton.icon(
                onPressed: _busy ? null : _reviewHermesImport,
                icon: const Icon(Icons.file_open_outlined),
                label: Text(_tr('Import Hermes file', '导入 Hermes 文件')),
              ),
            ],
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
