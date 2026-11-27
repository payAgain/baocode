import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../ide/file_service.dart';
import '../l10n/l10n.dart';
import '../settings/pages/settings_widgets.dart' show SettingsColors;
import '../theme/app_theme.dart';
import '../workspace/window_controls.dart';
import 'bot.dart';
import 'bot_memory.dart';
import 'bot_memory_migration.dart';
import 'bots.dart';
import 'desktop_bot_editor_ui.dart';

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
    builder: (context) => BotModernDialog(
      width: 640,
      height: 460,
      scrollable: false,
      icon: Icons.history_outlined,
      title: _tr('Original ${backup.source}', '${backup.source} 备份原文'),
      headerTrailing: BotCodeChip('SHA-256 ${backup.digest.substring(0, 12)}…'),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 10,
        children: [
          BotEditorCard(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: SelectableText(
              'SHA-256 ${backup.digest}',
              style: AppFonts.uiCodeStyle(11.5).copyWith(
                color: SettingsColors.textSecondary,
              ),
            ),
          ),
          Expanded(
            child: BotEditorCard(
              child: ListView(
                children: [
                  SelectableText(
                    utf8.decode(backup.bytes, allowMalformed: true),
                    style: AppFonts.uiCodeStyle(12.5).copyWith(
                      height: 1.5,
                      color: SettingsColors.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          style: botEditorTonalButtonStyle(context),
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
      builder: (context) => BotModernDialog(
        width: 640,
        height: 490,
        scrollable: false,
        icon: restore ? Icons.restore_outlined : Icons.difference_outlined,
        title: restore
            ? _tr('Review backup restore', '核对备份恢复内容')
            : _tr('Review Markdown import', '核对 Markdown 导入内容'),
        headerTrailing: BotCodeChip(_source.fileName),
        body: ListView(
          children: [
            BotEditorNotice(
              tone: preview.hasChanges
                  ? BotEditorTone.accent
                  : BotEditorTone.neutral,
              message: preview.hasChanges
                  ? _tr(
                      '${preview.added} entries added · ${preview.removed} removed',
                      '新增 ${preview.added} 项 · 移除 ${preview.removed} 项',
                    )
                  : _tr(
                      'There are no changes to saved memory.',
                      '已保存的记忆没有变更。',
                    ),
            ),
            const SizedBox(height: 14),
            Text(
              _tr('Saved now', '当前已保存'),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: SettingsColors.textSecondary,
              ),
            ),
            const SizedBox(height: 6),
            BotEditorCard(
              child: SelectableText(
                preview.before.isEmpty ? _tr('(empty)', '（空）') : preview.before,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: SettingsColors.textPrimary,
                ),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              _tr('After applying', '应用后'),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: SettingsColors.textSecondary,
              ),
            ),
            const SizedBox(height: 6),
            BotEditorCard(
              borderColor: preview.hasChanges
                  ? AppColors.accent.withValues(alpha: 0.35)
                  : null,
              child: SelectableText(
                preview.after.isEmpty ? _tr('(empty)', '（空）') : preview.after,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: SettingsColors.textPrimary,
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            style: botEditorTonalButtonStyle(context),
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.commonCancel),
          ),
          if (preview.hasChanges)
            FilledButton(
              style: botEditorButtonStyle(context),
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
          return BotModernDialog(
            width: 640,
            height: 560,
            scrollable: false,
            icon: Icons.fact_check_outlined,
            accentColor: AppColors.added,
            title: _tr('Review Hermes import', '核对 Hermes 导入内容'),
            headerTrailing: BotCodeChip(fileName),
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 12,
              children: [
                Row(
                  children: [
                    Text(
                      _tr('Target memory', '导入目标'),
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                        color: SettingsColors.textSecondary,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: BotModernDropdown<BotMemoryMirror>(
                        value: target,
                        hint: Text(
                          _tr('Choose target memory', '请选择导入目标'),
                          style: TextStyle(color: SettingsColors.textQuaternary),
                        ),
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
                    ),
                  ],
                ),
                Expanded(
                  child: ListView(
                    children: [
                      if (plainBulletsWarning) ...[
                        BotEditorNotice(
                          tone: BotEditorTone.warning,
                          message: _tr(
                            'No Hermes § separator was found, but multiple bullet lines were detected. Without standalone § lines, the whole file will be imported as a single note.',
                            '未检测到 Hermes § 分隔符，但文件包含多条列表项。如果没有独立 § 分隔行，整份内容会作为单条笔记导入。',
                          ),
                        ),
                        const SizedBox(height: 10),
                      ],
                      if (previewError case final error?)
                        BotEditorNotice(
                          tone: BotEditorTone.danger,
                          message: error,
                        )
                      else if (current == null)
                        BotEditorNotice(
                          tone: BotEditorTone.neutral,
                          message: _tr(
                            'Choose whether this file imports into private preferences or private self facts.',
                            '请选择将该文件导入到私有用户偏好还是私有自身事实。',
                          ),
                        )
                      else ...[
                        BotEditorCard(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            spacing: 4,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    width: 7,
                                    height: 7,
                                    decoration: BoxDecoration(
                                      color: current.hasChanges
                                          ? AppColors.added
                                          : SettingsColors.textSecondary,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
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
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w500,
                                        color: SettingsColors.textPrimary,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              if (!current.hasChanges)
                                Padding(
                                  padding: const EdgeInsets.only(left: 15),
                                  child: Text(
                                    _tr(
                                      'No new entries to import.',
                                      '没有可导入的新条目。',
                                    ),
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: SettingsColors.textSecondary,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        if (current.outsideBudget > 0) ...[
                          const SizedBox(height: 10),
                          BotEditorNotice(
                            tone: BotEditorTone.warning,
                            message: _tr(
                              '${current.outsideBudget} new entries will be saved outside the prompt budget. Trim older entries in "Memory and review" before adding more.',
                              '${current.outsideBudget} 个新条目会保存，但超出提示词预算；在“记忆与审核”中精简旧条目后才能继续新增。',
                            ),
                          ),
                        ],
                        if (current.hasChanges) ...[
                          const SizedBox(height: 12),
                          for (var i = 0; i < current.additions.length; i++) ...[
                            if (i > 0) const SizedBox(height: 8),
                            BotEditorCard(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                spacing: 8,
                                children: [
                                  Row(
                                    children: [
                                      BotEditorStatusBadge(
                                        label: '#${i + 1}',
                                        tone: BotEditorTone.accent,
                                      ),
                                      if (current.outsideBudgetIndexes
                                          .contains(i)) ...[
                                        const SizedBox(width: 6),
                                        BotStatusPill(
                                          label: _tr(
                                            'Outside prompt budget',
                                            '超出提示词预算',
                                          ),
                                          tone: BotEditorTone.warning,
                                        ),
                                      ],
                                    ],
                                  ),
                                  SelectableText(
                                    current.additions[i],
                                    style: TextStyle(
                                      fontSize: 13.5,
                                      height: 1.5,
                                      color: SettingsColors.textPrimary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                        if (current.blocked.isNotEmpty) ...[
                          const SizedBox(height: 14),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 2),
                            child: Text(
                              _tr('Skipped entries (not imported)', '已拦截条目（不会导入）'),
                              style: TextStyle(
                                fontSize: 12.5,
                                color: colorScheme.error,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          for (final item in current.blocked)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: BotEditorNotice(
                                tone: BotEditorTone.danger,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  spacing: 4,
                                  children: [
                                    Text(
                                      switch (item.reason) {
                                        BotMemoryImportBlockReason.credential =>
                                          _tr(
                                            '#${item.index} · Contains credentials or keys (hidden)',
                                            '#${item.index} · 包含凭证或密钥（内容已隐藏）',
                                          ),
                                        BotMemoryImportBlockReason.forgotten =>
                                          _tr(
                                            '#${item.index} · Previously forgotten',
                                            '#${item.index} · 该内容此前已被遗忘',
                                          ),
                                      },
                                      style: TextStyle(
                                        fontSize: 12.5,
                                        color: colorScheme.error,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    if (item.reason !=
                                        BotMemoryImportBlockReason.credential)
                                      SelectableText(
                                        item.text,
                                        style: TextStyle(
                                          fontSize: 12.5,
                                          height: 1.45,
                                          color: SettingsColors.textSecondary,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ],
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                style: botEditorTonalButtonStyle(context),
                onPressed: () => Navigator.pop(context),
                child: Text(context.l10n.commonCancel),
              ),
              if (current != null && current.hasChanges)
                FilledButton(
                  style: botEditorButtonStyle(context),
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

  Widget _hermesCard(BuildContext context) {
    final accent = AppColors.accent;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            accent.withValues(alpha: 0.12),
            botDialogCardColor,
          ],
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withValues(alpha: 0.28)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 10,
          children: [
            Row(
              children: [
                BotEditorIcon(
                  icon: Icons.file_open_outlined,
                  accentColor: accent,
                  size: 30,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _tr('Import from Hermes', '从 Hermes 导入'),
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: SettingsColors.textPrimary,
                    ),
                  ),
                ),
                const BotCodeChip('~/.hermes/memories'),
              ],
            ),
            Text(
              _tr(
                'Import Hermes memory notes from ~/.hermes/memories (MEMORY.md or USER.md).',
                '从 ~/.hermes/memories 导入 Hermes 记忆笔记（MEMORY.md 或 USER.md）。',
              ),
              style: TextStyle(
                fontSize: 12.5,
                color: SettingsColors.textSecondary,
                height: 1.45,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: FilledButton.icon(
                style: botEditorButtonStyle(context),
                onPressed: _busy ? null : _reviewHermesImport,
                icon: const Icon(Icons.file_open_outlined, size: 16),
                label: Text(_tr('Import Hermes file', '导入 Hermes 文件')),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _mirrorCard(BuildContext context) {
    final theme = Theme.of(context);
    final (badgeLabel, badgeTone) = _mirrorError != null
        ? (_tr('Read failed', '读取失败'), BotEditorTone.danger)
        : _changed
        ? (_tr('External edits', '有外部修改'), BotEditorTone.warning)
        : (_tr('In sync', '已同步'), BotEditorTone.neutral);
    return BotEditorCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 10,
        children: [
          Row(
            children: [
              Icon(
                Icons.sync_alt_rounded,
                size: 16,
                color: const Color(0xFF56B6C2),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _tr('Markdown mirror', 'Markdown 镜像'),
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: SettingsColors.textPrimary,
                  ),
                ),
              ),
              BotStatusPill(label: badgeLabel, tone: badgeTone),
            ],
          ),
          Row(
            children: [
              Text(
                _tr('Memory file', '记忆文件'),
                style: TextStyle(
                  fontSize: 12.5,
                  color: SettingsColors.textSecondary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: BotModernDropdown<BotMemoryMirror>(
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
            ],
          ),
          Text(
            _mirrorError ??
                (_changed
                    ? _tr(
                        'The Markdown file differs from its last known version.',
                        'Markdown 文件与已知版本不同。',
                      )
                    : _tr('No external changes detected.', '没有检测到外部修改。')),
            style: TextStyle(
              fontSize: 12.5,
              color: _mirrorError != null
                  ? theme.colorScheme.error
                  : SettingsColors.textSecondary,
              height: 1.4,
            ),
          ),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              TextButton.icon(
                style: botEditorGhostButtonStyle(context),
                onPressed: _busy || !_changed
                    ? null
                    : () => _review(restore: false),
                icon: const Icon(Icons.difference_outlined, size: 15),
                label: Text(_tr('Review changes', '查看变更')),
              ),
              if (WindowControls.canPickFiles)
                TextButton.icon(
                  style: botEditorGhostButtonStyle(context),
                  onPressed: _busy || _mirrorError != null
                      ? null
                      : () => _export(archive: false),
                  icon: const Icon(Icons.upload_file_outlined, size: 15),
                  label: Text(_tr('Export current entries', '导出当前条目')),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _backupCard(
    BuildContext context,
    BotLegacyMarkdownBackup? backup,
  ) {
    final theme = Theme.of(context);
    final (badgeLabel, badgeTone) = _backupError != null
        ? (_tr('Unavailable', '不可用'), BotEditorTone.danger)
        : backup == null
        ? (_tr('None', '暂无'), BotEditorTone.neutral)
        : backup.possiblyMirrored
        ? (_tr('May include edits', '可能含镜像改动'), BotEditorTone.warning)
        : (_tr('Available', '可用'), BotEditorTone.success);
    return BotEditorCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 8,
        children: [
          Row(
            children: [
              Icon(
                Icons.restore_outlined,
                size: 16,
                color: SettingsColors.textSecondary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _tr('Original backup', '原始备份'),
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: SettingsColors.textPrimary,
                  ),
                ),
              ),
              BotStatusPill(label: badgeLabel, tone: badgeTone),
            ],
          ),
          if (backup == null)
            Text(
              _backupError ??
                  _tr('No original backup is available.', '暂无原始备份。'),
              style: TextStyle(
                fontSize: 12.5,
                color: _backupError != null
                    ? theme.colorScheme.error
                    : SettingsColors.textSecondary,
                height: 1.4,
              ),
            )
          else ...[
            Text(
              backup.possiblyMirrored
                  ? _tr(
                      'The earliest available backup may already include mirrored edits. Restore adds missing notes to saved memory.',
                      '最早可取得的备份可能已经包含镜像写入的改动。恢复会把缺少的旧笔记加入已保存的记忆。',
                    )
                  : _tr(
                      'Original backup available. Restore adds missing notes to saved memory.',
                      '原始备份可用。恢复会把缺少的旧笔记加入已保存的记忆。',
                    ),
              style: TextStyle(
                fontSize: 12.5,
                color: SettingsColors.textSecondary,
                height: 1.45,
              ),
            ),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                TextButton.icon(
                  style: botEditorGhostButtonStyle(context),
                  onPressed: _busy ? null : () => _viewBackup(backup),
                  icon: const Icon(Icons.visibility_outlined, size: 15),
                  label: Text(_tr('View backup', '查看备份')),
                ),
                if (WindowControls.canPickFiles)
                  TextButton.icon(
                    style: botEditorGhostButtonStyle(context),
                    onPressed: _busy ? null : () => _export(archive: true),
                    icon: const Icon(Icons.download_outlined, size: 15),
                    label: Text(_tr('Export original backup', '导出原始备份')),
                  ),
                TextButton.icon(
                  style: botEditorGhostButtonStyle(context),
                  onPressed: _busy ? null : () => _review(restore: true),
                  icon: const Icon(Icons.restore_page_outlined, size: 15),
                  label: Text(_tr('Review restore', '查看恢复内容')),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final backup = _backup;
    return BotModernDialog(
      width: 580,
      icon: Icons.swap_horiz_rounded,
      accentColor: AppColors.added,
      title: _tr('Import & migration', '导入与迁移'),
      subtitle: _tr(
        '${widget.bot.name} · Hermes import, Markdown mirrors, and backups',
        '${widget.bot.name} · Hermes 导入、Markdown 镜像与原始备份',
      ),
      headerTrailing: IconButton(
        tooltip: _tr('Check for changes', '检查变更'),
        visualDensity: VisualDensity.compact,
        onPressed: _busy ? null : () => _run(() async {}),
        icon: Icon(Icons.refresh, size: 18, color: SettingsColors.textSecondary),
      ),
      busy: _busy,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        spacing: 12,
        children: [
          if (_message case final message?)
            BotEditorNotice(tone: BotEditorTone.success, message: message),
          if (_error case final error?)
            BotEditorNotice(tone: BotEditorTone.danger, message: error),
          if (WindowControls.canPickFiles) _hermesCard(context),
          _mirrorCard(context),
          _backupCard(context, backup),
        ],
      ),
      actions: [
        TextButton(
          style: botEditorTonalButtonStyle(context),
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: Text(MaterialLocalizations.of(context).closeButtonLabel),
        ),
      ],
    );
  }
}
