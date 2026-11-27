import 'dart:async';

import 'package:bao_editor/monaco/flutter/editor_document_model.dart'
    show EditorOffsetEdit;
import 'package:bao_link/bao_link.dart';
import 'package:flutter/material.dart';

import '../ide/lsp_ui/minimal_edits.dart' show minimalOffsetEdits;
import '../l10n/l10n.dart';
import '../link/bot_memory_management.dart';
import '../settings/pages/settings_widgets.dart' show SettingsColors;
import '../theme/app_theme.dart';
import 'bot.dart' show Bot;
import 'bots.dart';
import 'desktop_bot_editor_ui.dart';

/// Local and paired desktop use the same controls and host-managed revisions.
Future<void> showLocalBotMemory(BuildContext context, Bots bots, Bot bot) {
  final management = BotMemoryManagement(
    bots,
    reviewer: 'desktop',
    localOwner: true,
  );
  return showDesktopBotMemory(
    context,
    botId: bot.id,
    name: bot.name,
    groups: {
      for (final group in bots.groups.groups)
        if (group.members.contains(bot.id)) group.id: group.name,
    },
    methods: management.methods,
    call: management.call,
    localOwner: true,
  );
}

Future<void> showDesktopBotMemory(
  BuildContext context, {
  required String botId,
  required String name,
  required Map<String, String> groups,
  required Iterable<String> methods,
  required Future<Map<String, Object?>> Function(String, Map<String, Object?>)
  call,
  bool localOwner = false,
}) => showDialog<void>(
  context: context,
  builder: (_) => _MemoryDialog(
    botId: botId,
    name: name,
    groups: groups,
    methods: methods.toSet(),
    call: call,
    localOwner: localOwner,
  ),
);

typedef _Row = Map<String, Object?>;

Iterable<_Row> _rows(Object? value) =>
    value is List ? value.whereType<_Row>() : const [];
_Row _row(Object? value) => value is _Row ? value : const {};

class _MemoryDialog extends StatefulWidget {
  const _MemoryDialog({
    required this.botId,
    required this.name,
    required this.groups,
    required this.methods,
    required this.call,
    required this.localOwner,
  });

  final String botId;
  final String name;
  final Map<String, String> groups;
  final Set<String> methods;
  final Future<_Row> Function(String, _Row) call;
  final bool localOwner;

  @override
  State<_MemoryDialog> createState() => _MemoryDialogState();
}

class _MemoryDialogState extends State<_MemoryDialog> {
  final _filter = TextEditingController();
  final _query = TextEditingController();
  String? _group;
  _Row _memory = const {};
  _Row _factScopes = const {};
  _Row _facts = const {};
  String? _factProject;
  _Row _review = const {};
  _Row _skills = const {};
  bool _showArchivedSkills = false;
  List<_Row> _hits = const [];
  String? _cursor;
  String? _searched;
  bool _legacyDiary = false;
  String? _historyProject;
  bool _busy = false;
  bool _audit = false;
  String? _message;
  String? _error;

  String _tr(String en, String zh) =>
      Localizations.maybeLocaleOf(context)?.languageCode == 'zh' ? zh : en;
  bool _has(String method) => widget.methods.contains(method);

  @override
  void initState() {
    super.initState();
    unawaited(_run(_load));
  }

  @override
  void dispose() {
    _filter.dispose();
    _query.dispose();
    super.dispose();
  }

  Future<_Row> _call(String method, [_Row arguments = const {}]) => widget.call(
    method,
    {...arguments, 'bot': widget.botId, 'group': ?_group},
  );

  Future<void> _run(Future<void> Function() action) async {
    if (_busy || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      await action();
    } on Object catch (error) {
      if (!mounted) return;
      setState(
        () => _error = error is LinkRemoteException ? error.message : '$error',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load() async {
    await _loadMemory();
    if (!mounted) return;
    if (_has(LinkMethods.botMemoryReview)) {
      final review = await _call(LinkMethods.botMemoryReview, {
        'pendingOnly': !_audit,
        'batch': true,
      });
      if (mounted) setState(() => _review = review);
    }
    if (!mounted || _group != null) return;
    if (_has(LinkMethods.botMemoryFactScopes)) await _loadFactScopes();
    if (mounted && _has(LinkMethods.botMemorySkills)) {
      await _loadSkills(_skills['project'] as String?);
    }
  }

  Future<void> _loadMemory() async {
    final memory = await _call(LinkMethods.botMemoryEntries);
    if (mounted) setState(() => _memory = memory);
  }

  Future<void> _loadSnapshotStatus() async {
    if (_memory.containsKey('snapshotStatus')) await _loadMemory();
    if (mounted &&
        _group == null &&
        _factProject == null &&
        _facts.containsKey('snapshotStatus')) {
      await _loadFacts();
    }
  }

  static Map<String, String> _factProjects(_Row scopes) => {
    for (final row in _rows(scopes['projects']))
      if (row case {'id': final String id, 'name': final String name}) id: name,
  };

  _Row get _factArguments => {
    'factScope': _factProject == null ? 'private' : 'project',
    'project': ?_factProject,
  };

  Future<void> _loadFactScopes() async {
    final scopes = await _call(LinkMethods.botMemoryFactScopes);
    if (!mounted) return;
    final projects = _factProjects(scopes);
    setState(() {
      _factScopes = scopes;
      if (_historyProject != null && !projects.containsKey(_historyProject)) {
        _historyProject = null;
        _hits = const [];
        _searched = null;
        _cursor = null;
      }
      if (!projects.containsKey(_factProject)) {
        _factProject = scopes['private'] == true
            ? null
            : projects.keys.firstOrNull;
      }
      _facts = const {};
    });
    if (scopes['private'] == true || _factProject != null) await _loadFacts();
  }

  Future<void> _loadFacts() async {
    final facts = await _call(LinkMethods.botMemoryEntries, _factArguments);
    if (mounted) setState(() => _facts = facts);
  }

  Future<void> _loadSkills([String? project]) async {
    final skills = await _call(LinkMethods.botMemorySkills, {
      'project': ?project,
      'includeArchived': _showArchivedSkills,
    });
    if (mounted) setState(() => _skills = skills);
  }

  Future<void> _maintainSkill(_Row skill, String key, bool value) =>
      _run(() async {
        final project = _skills['project'];
        await _call(LinkMethods.maintainBotMemorySkill, {
          'project': project,
          'name': skill['name'],
          'revision': skill['revision'],
          key: value,
        });
        await _loadSkills(project as String?);
      });

  Future<void> _viewSkill(_Row skill) async {
    final project = _skills['project'];
    Future<_Row> page([int? before]) => _call(
      LinkMethods.botMemorySkillRevisions,
      {'project': project, 'name': skill['name'], 'beforeRevision': ?before},
    );
    _Row? loaded;
    await _run(() async {
      loaded = await page();
    });
    final first = loaded;
    if (!mounted || first == null) return;
    final revisions = _rows(first['revisions']).toList();
    if (revisions.isEmpty) return;
    final current = revisions.first;
    var selected = revisions.elementAtOrNull(1);
    var before = first['beforeRevision'] as int?;
    var loading = false;
    String? error;
    await showDialog<void>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, refresh) => BotModernDialog(
          width: 640,
          height: 520,
          scrollable: false,
          icon: Icons.psychology_outlined,
          title: '${skill['name']}',
          subtitle: _tr(
            'Current revision ${current['revision']}',
            '当前修订 ${current['revision']}',
          ),
          busy: loading,
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 10,
            children: [
              if (revisions.length > 1)
                Row(
                  children: [
                    Text(
                      _tr('Compare', '版本对比'),
                      style: TextStyle(
                        fontSize: 12.5,
                        color: SettingsColors.textSecondary,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: BotModernDropdown<int>(
                        value: selected?['revision'] as int?,
                        items: [
                          for (final row in revisions.skip(1))
                            DropdownMenuItem(
                              value: row['revision'] as int,
                              child: Text(
                                _tr(
                                  'Compare revision ${row['revision']} to ${current['revision']}',
                                  '比较修订 ${row['revision']} 与 ${current['revision']}',
                                ),
                              ),
                            ),
                        ],
                        onChanged: (revision) => refresh(
                          () => selected = revisions.firstWhere(
                            (row) => row['revision'] == revision,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              if (before != null)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton(
                    style: botEditorTonalButtonStyle(context),
                    onPressed: loading
                        ? null
                        : () async {
                            refresh(() {
                              loading = true;
                              error = null;
                            });
                            try {
                              final older = await page(before);
                              if (!context.mounted) return;
                              refresh(() {
                                revisions.addAll(_rows(older['revisions']));
                                before = older['beforeRevision'] as int?;
                              });
                            } on Object catch (problem) {
                              if (context.mounted) {
                                refresh(
                                  () => error = problem is LinkRemoteException
                                      ? problem.message
                                      : '$problem',
                                );
                              }
                            } finally {
                              if (context.mounted) {
                                refresh(() => loading = false);
                              }
                            }
                          },
                    child: Text(_tr('Load older revisions', '加载更早的修订')),
                  ),
                ),
              if (error case final message?)
                BotEditorNotice(tone: BotEditorTone.danger, message: message),
              Expanded(
                child: ListView(
                  children: [
                    if (selected case final older?) ...[
                      Text(
                        _tr(
                          'Changes since revision ${older['revision']}',
                          '自修订 ${older['revision']} 以来的变更',
                        ),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: SettingsColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 6),
                      BotEditorCard(
                        child: SelectableText(
                          _skillDiff(
                            older['markdown'] as String,
                            current['markdown'] as String,
                          ),
                          style: AppFonts.uiCodeStyle(12).copyWith(
                            height: 1.5,
                            color: SettingsColors.textPrimary,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _tr(
                          'Revision ${older['revision']}',
                          '修订 ${older['revision']}',
                        ),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: SettingsColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 6),
                      BotEditorCard(
                        child: SelectableText(
                          older['markdown'] as String,
                          style: AppFonts.uiCodeStyle(12).copyWith(
                            height: 1.5,
                            color: SettingsColors.textPrimary,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    Text(
                      _tr(
                        'Current revision ${current['revision']}',
                        '当前修订 ${current['revision']}',
                      ),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: SettingsColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 6),
                    BotEditorCard(
                      child: SelectableText(
                        current['markdown'] as String,
                        style: AppFonts.uiCodeStyle(12).copyWith(
                          height: 1.5,
                          color: SettingsColors.textPrimary,
                        ),
                      ),
                    ),
                  ],
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
      ),
    );
  }

  String _skillDiff(String before, String after) {
    final edits = minimalOffsetEdits(before, [
      EditorOffsetEdit(0, before.length, after),
    ]);
    if (edits.isEmpty) return _tr('The content is identical.', '内容相同。');
    return [
      for (final edit in edits) ...[
        if (edit.start != edit.end)
          for (final line
              in before.substring(edit.start, edit.end).trimRight().split('\n'))
            '− $line',
        if (edit.text.isNotEmpty)
          for (final line in edit.text.trimRight().split('\n')) '+ $line',
      ],
    ].join('\n');
  }

  Future<void> _change(_Row change, {bool fact = false}) => _run(() async {
    final memory = await _call(LinkMethods.changeBotMemory, {
      if (fact) ..._factArguments,
      'changes': [change],
    });
    if (!mounted) return;
    setState(() {
      if (fact) {
        _facts = memory;
      } else {
        _memory = memory;
      }
    });
  });

  Future<String?> _text(
    String title,
    String value, {
    String? hint,
    bool multiline = true,
  }) async {
    var draft = value;
    return showDialog<String>(
      context: context,
      builder: (context) => BotModernDialog(
        width: 520,
        icon: Icons.edit_note_outlined,
        title: title,
        body: TextFormField(
          autofocus: true,
          initialValue: draft,
          onChanged: (text) => draft = text,
          minLines: multiline ? 3 : 1,
          maxLines: multiline ? 8 : 1,
          style: TextStyle(fontSize: 13.5, color: SettingsColors.textPrimary),
          decoration: botEditorInput(
            null,
            hintText: hint,
            multiline: multiline,
          ),
        ),
        actions: [
          TextButton(
            style: botEditorTonalButtonStyle(context),
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.commonCancel),
          ),
          FilledButton(
            style: botEditorButtonStyle(context),
            onPressed: () => Navigator.pop(context, draft.trim()),
            child: Text(context.l10n.commonSave),
          ),
        ],
      ),
    );
  }

  Future<void> _edit([_Row? entry, String? factKind]) async {
    final title = switch ((entry, factKind)) {
      (null, null) => _tr('Add memory', '添加记忆'),
      (null, final kind?) => _addFactLabel(kind),
      (_, null) => _tr('Edit memory', '编辑记忆'),
      _ => _tr('Edit fact', '编辑事实'),
    };
    final text = await _text(title, entry?['text'] as String? ?? '');
    if (text == null || text.isEmpty) return;
    await _change({
      'action': entry == null ? 'add' : 'update',
      'text': text,
      if (entry != null) ...{
        'id': entry['id'],
        'revision': entry['revision'],
      } else
        'kind': ?factKind,
    }, fact: factKind != null);
  }

  String _addFactLabel(String kind) => switch (kind) {
    'self' => _tr('Add self fact', '添加自我事实'),
    'person' => _tr('Add person fact', '添加人物事实'),
    _ => _tr('Add project fact', '添加项目事实'),
  };

  Future<void> _addPersonFact(Iterable<_Row> entries) async {
    final people = {
      for (final row in _rows(_facts['people']))
        if (row case {'key': final String key, 'name': final String name})
          key: name,
    };
    final notes = <String, String>{};
    for (final entry in entries) {
      if (entry case {
        'personKey': final String key,
        'personName': final String name,
      }) {
        people.putIfAbsent(key, () => name);
        if (entry['text'] case final String text when text.isNotEmpty) {
          notes.putIfAbsent(key, () => text);
        }
      }
    }
    final names = <String, int>{};
    final labels = <String, String>{};
    for (final MapEntry(key: key, value: name) in people.entries) {
      final count = names.update(name, (count) => count + 1, ifAbsent: () => 1);
      labels[key] = count == 1 ? name : '$name ($count)';
    }
    final form = GlobalKey<FormState>();
    String? selected = people.isEmpty ? '' : null;
    var name = '';
    var text = '';
    var distinct = false;
    final change = await showDialog<_Row>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, refresh) => BotModernDialog(
          width: 520,
          icon: Icons.person_add_alt_outlined,
          title: _addFactLabel('person'),
          body: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 12,
              children: [
                if (people.isNotEmpty) ...[
                  Text(
                    _tr('Person', '人物'),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: SettingsColors.textSecondary,
                    ),
                  ),
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: selected,
                    decoration: botEditorInput(null),
                    dropdownColor: AppColors.surfaceRaised,
                    hint: Text(_tr('Select a person', '选择人物')),
                    items: [
                      for (final item in labels.entries)
                        DropdownMenuItem(
                          value: item.key,
                          child: Text(
                            item.value,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      DropdownMenuItem(
                        value: '',
                        child: Text(_tr('Enter a name', '输入姓名')),
                      ),
                    ],
                    onChanged: (key) => refresh(() => selected = key),
                    validator: (key) => key == null
                        ? _tr('Select a person.', '请选择人物。')
                        : null,
                  ),
                ],
                if (selected == '') ...[
                  BotEditorInsetField(
                    initialValue: name,
                    label: _tr('Person name', '人物姓名'),
                    onChanged: (value) => name = value.trim(),
                    validator: (_) => name.isEmpty
                        ? _tr('Enter a person name.', '请输入人物姓名。')
                        : null,
                  ),
                  BotEditorCard(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 2,
                    ),
                    child: CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text(
                        _tr(
                          'Create a separate person with this name',
                          '用此姓名新建独立人物',
                        ),
                      ),
                      value: distinct,
                      onChanged: (value) =>
                          refresh(() => distinct = value == true),
                    ),
                  ),
                ] else if (notes[selected] case final note?)
                  BotEditorCard(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 9,
                    ),
                    child: Text(
                      note,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: SettingsColors.textSecondary,
                      ),
                    ),
                  ),
                BotEditorInsetField(
                  label: _tr('Fact', '事实'),
                  multiline: true,
                  minLines: 3,
                  maxLines: 6,
                  onChanged: (value) => text = value.trim(),
                  validator: (_) =>
                      text.isEmpty ? _tr('Enter a fact.', '请输入事实。') : null,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              style: botEditorTonalButtonStyle(context),
              onPressed: () => Navigator.pop(context),
              child: Text(context.l10n.commonCancel),
            ),
            FilledButton(
              style: botEditorButtonStyle(context),
              onPressed: () {
                if (form.currentState?.validate() != true) return;
                Navigator.pop(context, <String, Object?>{
                  'action': 'add',
                  'kind': 'person',
                  'text': text,
                  if (selected == '') ...{
                    'personName': name,
                    if (distinct) 'newPerson': true,
                  } else
                    'personKey': selected,
                });
              },
              child: Text(context.l10n.commonSave),
            ),
          ],
        ),
      ),
    );
    if (change != null) await _change(change, fact: true);
  }

  Future<void> _forget(_Row entry, {bool fact = false}) async {
    final confirmed = await _confirm(
      fact
          ? _tr('Forget this fact?', '忘掉这条事实？')
          : _tr('Forget this memory?', '忘掉这条记忆？'),
      entry['sourceUnavailable'] == true ||
              fact && entry['sourceKind'] != 'conversation'
          ? _tr('This removes the entry from saved memory.', '这会从已保存的记忆中移除这一项。')
          : _tr(
              'The original message remains in conversation history.',
              '原始消息仍保留在对话历史中。',
            ),
      _tr('Forget', '忘掉'),
    );
    if (confirmed) {
      await _change({
        'action': 'remove',
        'id': entry['id'],
        'revision': entry['revision'],
      }, fact: fact);
    }
  }

  Future<void> _retain(_Row entry, {required bool fact}) async {
    final agreed = await _confirm(
      _tr('Keep this fact?', '保留这条事实？'),
      _tr(
        'The Bot can use this fact again. The deleted source stays unavailable.',
        'Bot 将可以再次使用这条事实，已删除的来源仍不可用。',
      ),
      _tr('Keep fact', '保留事实'),
    );
    if (agreed) {
      await _change({
        'action': 'retain',
        'id': entry['id'],
        'revision': entry['revision'],
      }, fact: fact);
    }
  }

  Future<void> _shareMemory(_Row entry, {required bool fact}) async {
    final project = fact ? _factProject : null;
    final group = await showDialog<String>(
      context: context,
      builder: (context) => BotModernDialog(
        width: 400,
        icon: Icons.groups_outlined,
        title: _tr('Choose a group', '选择群聊'),
        body: BotEditorCard(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final group in widget.groups.entries)
                Material(
                  type: MaterialType.transparency,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    hoverColor: SettingsColors.hover,
                    onTap: () => Navigator.of(context).pop(group.key),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              group.value,
                              style: TextStyle(
                                fontSize: 13.5,
                                color: SettingsColors.textPrimary,
                              ),
                            ),
                          ),
                          Icon(
                            Icons.chevron_right,
                            size: 17,
                            color: SettingsColors.iconTertiary,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
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
    if (group == null || !mounted) return;
    final name = widget.groups[group] ?? group;
    final approved = await _confirm(
      _tr('Share with $name?', '共享到 $name？'),
      '${_tr('The Bot may use this text in that group.', 'Bot 可以在该群聊中使用以下内容。')}\n\n'
      '${entry['markdown'] ?? entry['text'] ?? ''}',
      _tr('Share', '共享'),
    );
    if (!approved || !mounted) return;
    await _run(() async {
      await _call(LinkMethods.shareBotMemoryEntry, {
        'group': group,
        'id': entry['id'],
        'revision': entry['revision'],
        if (fact) 'factScope': project == null ? 'private' : 'project',
        'project': ?project,
      });
      if (mounted) {
        setState(() => _message = _tr('Shared with $name.', '已共享到 $name。'));
      }
    });
  }

  Future<void> _revokeMemoryShare(_Row entry, String shareId) async {
    final approved = await _confirm(
      _tr('Revoke this share?', '撤回这条共享？'),
      _tr(
        'The Bot will stop loading this memory in the group. Group messages already sent stay in the chat.',
        'Bot 将停止在群聊中加载此记忆。已经发送的群消息会保留。',
      ),
      _tr('Revoke share', '撤回共享'),
    );
    if (!approved || !mounted) return;
    await _run(() async {
      final memory = await _call(LinkMethods.revokeBotMemoryShare, {
        'id': entry['id'],
        'revision': entry['revision'],
        'shareId': shareId,
      });
      if (mounted) setState(() => _memory = memory);
    });
  }

  Future<bool> _confirm(String title, String detail, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => BotModernDialog(
          width: 460,
          icon: Icons.help_outline,
          title: title,
          body: Text(
            detail,
            style: TextStyle(
              fontSize: 13.5,
              height: 1.5,
              color: SettingsColors.textSecondary,
            ),
          ),
          actions: [
            TextButton(
              style: botEditorTonalButtonStyle(context),
              onPressed: () => Navigator.pop(context),
              child: Text(context.l10n.commonCancel),
            ),
            FilledButton(
              style: botEditorButtonStyle(context),
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ==
      true;

  Future<void> _search({bool more = false}) => _run(() async {
    final query = more ? _searched : _query.text.trim();
    if (query == null || query.isEmpty) return;
    final results = await _call(LinkMethods.botMemorySearch, {
      'query': query,
      'cursor': more ? _cursor : null,
      if (_legacyDiary && _group == null) 'legacyDiary': true,
      if (_group == null && !_legacyDiary) 'historyProject': ?_historyProject,
    });
    if (!mounted) return;
    setState(() {
      _searched = query;
      _cursor = results['cursor'] as String?;
      _hits = [if (more) ..._hits, ..._rows(results['hits'])];
    });
  });

  Future<void> _openSource(
    Object? source, {
    bool legacyDiary = false,
    String? historyProject,
  }) => _run(() async {
    final window = await _call(LinkMethods.botMemorySource, {
      'source': source,
      if (legacyDiary) 'legacyDiary': true,
      'historyProject': ?historyProject,
    });
    if (!mounted) return;
    final anchor = _row(window['anchor']);
    final reference = anchor['reference'];
    final groupSource = _group != null;
    final canDelete =
        widget.localOwner &&
        _has(LinkMethods.deleteBotMemorySource) &&
        window['canDeleteOriginal'] == true &&
        reference != null;
    final delete = await showDialog<bool>(
      context: context,
      builder: (context) => BotModernDialog(
        width: 600,
        height: 460,
        scrollable: false,
        icon: anchor['kind'] == 'diarySummary'
            ? Icons.book_outlined
            : Icons.chat_bubble_outline,
        title: anchor['kind'] == 'diarySummary'
            ? _tr('Diary summaries', '日记摘要')
            : _tr('Source messages', '原始消息'),
        body: SelectionArea(
          child: ListView(
            children: [
              for (final message in [
                ..._rows(window['before']),
                anchor,
                ..._rows(window['after']),
              ])
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: BotEditorCard(
                    borderColor: identical(message, anchor)
                        ? AppColors.accent.withValues(alpha: 0.45)
                        : null,
                    backgroundColor: identical(message, anchor)
                        ? AppColors.accent.withValues(alpha: 0.08)
                        : null,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: 4,
                      children: [
                        Text(
                          [
                            _role(message['role']),
                            _date(message['time']),
                          ].where((part) => part.isNotEmpty).join(' · '),
                          style: TextStyle(
                            fontSize: 11.5,
                            color: identical(message, anchor)
                                ? AppColors.accent
                                : SettingsColors.textTertiary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          '${message['text'] ?? ''}',
                          style: TextStyle(
                            fontSize: 13.5,
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
        ),
        footerLeading: canDelete
            ? TextButton(
                style: botEditorTonalButtonStyle(context, destructive: true),
                onPressed: () async {
                  final agreed = await _confirm(
                    _tr('Delete this original message?', '删除这条原始消息？'),
                    groupSource
                        ? _tr(
                            'This removes the original for all group members, refreshes the group model context, and pauses notes that depend on it.',
                            '这会为所有群成员移除原始消息，刷新该群的模型上下文，并暂停依赖它的笔记。',
                          )
                        : _tr(
                            'This removes the message from the private chat and the bot’s diary.',
                            '这会从私聊和机器人的日记中删除这条消息。',
                          ),
                    _tr('Delete original', '删除原始消息'),
                  );
                  if (agreed && context.mounted) Navigator.pop(context, true);
                },
                child: Text(_tr('Delete original', '删除原始消息')),
              )
            : null,
        actions: [
          TextButton(
            style: botEditorTonalButtonStyle(context),
            onPressed: () => Navigator.pop(context),
            child: Text(MaterialLocalizations.of(context).closeButtonLabel),
          ),
        ],
      ),
    );
    if (delete != true || !canDelete || !mounted) return;
    final result = await _call(LinkMethods.deleteBotMemorySource, {
      'source': reference,
      'confirm': true,
      'historyProject': ?historyProject,
    });
    if (!mounted) return;
    if (result['deleted'] != true) {
      throw StateError(
        _tr('The original message could not be deleted.', '无法删除原始消息。'),
      );
    }
    setState(() {
      _message = _tr('Original message deleted.', '已删除原始消息。');
      _hits = const [];
      _cursor = null;
      _searched = null;
    });
    await _load();
  });

  Future<void> _configure(String key, Object value) => _run(() async {
    await _call(LinkMethods.configureBotMemoryReview, {key: value});
    await _load();
  });

  Future<void> _refine() async {
    final focus = await _text(
      _tr('Organize memory', '整理记忆'),
      '',
      hint: _tr('Optional focus', '可选关注点'),
    );
    if (focus == null) return;
    await _run(() async {
      await _call(LinkMethods.refineBotMemory, {'focus': focus});
      await _load();
      if (mounted) setState(() => _message = _tr('Review queued.', '已安排复盘。'));
    });
  }

  Future<void> _decide(_Row proposal, bool approve) => _run(() async {
    final result = await _call(LinkMethods.decideBotMemory, {
      'proposal': proposal['id'],
      'approve': approve,
      if (proposal['action'] == 'batch') 'batch': true,
    });
    await _load();
    if (mounted) setState(() => _message = _status(result['status']));
  });

  Future<void> _newConversation() async {
    final agreed = await _confirm(
      _tr('Start a new conversation?', '开启新对话？'),
      _tr(
        'The current history remains available. The new conversation starts with current memory.',
        '当前历史仍可查看，新对话将使用最新记忆。',
      ),
      _tr('Start', '开启'),
    );
    if (agreed) {
      await _run(() async {
        await _call(LinkMethods.newBotConversation);
        if (mounted) {
          setState(
            () => _message = _tr('New conversation started.', '已开启新对话。'),
          );
          await _loadSnapshotStatus();
        }
      });
    }
  }

  String _date(Object? value) {
    final time = value is String ? DateTime.tryParse(value)?.toLocal() : null;
    if (time == null) return '';
    final material = MaterialLocalizations.of(context);
    return '${material.formatMediumDate(time)} ${material.formatTimeOfDay(TimeOfDay.fromDateTime(time))}';
  }

  String _role(Object? role) => switch (role) {
    'user' => _tr('User', '用户'),
    'assistant' => _tr('Bot', 'Bot'),
    'task' => _tr('Task', '任务'),
    _ => '',
  };

  String _status(Object? status) => switch (status) {
    'pending' => _tr('Pending', '待审核'),
    'applied' => _tr('Applied', '已生效'),
    'rejected' => _tr('Rejected', '已拒绝'),
    'conflict' => _tr('Conflict', '有冲突'),
    'invalid' => _tr('Source unavailable', '来源不可用'),
    'applying' => _tr('Applying', '正在应用'),
    _ => '',
  };

  @override
  Widget build(BuildContext context) {
    final tabLabels = [
      _tr('Memory', '记忆'),
      _tr('History', '历史'),
      if (_has(LinkMethods.botMemoryFactScopes)) _tr('Facts', '事实'),
      if (_has(LinkMethods.botMemoryReview)) _tr('Review', '待审核'),
      if (_has(LinkMethods.botMemorySkills)) _tr('Skills', '技能'),
    ];
    return BotModernDialog(
      width: 740,
      height: 710,
      scrollable: false,
      icon: Icons.auto_stories_outlined,
      title: _tr('${widget.name} memory', '${widget.name} 的记忆'),
      busy: _busy,
      headerTrailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          BotModernDropdown<String>(
            width: 150,
            value: _group ?? '',
            onChanged: _busy
                ? null
                : (value) {
                    if (value == null || value == (_group ?? '')) return;
                    setState(() {
                      _group = value.isEmpty ? null : value;
                      _memory = const {};
                      _facts = const {};
                      _review = const {};
                      _hits = const [];
                      _cursor = null;
                      _searched = null;
                    });
                    unawaited(_run(_load));
                  },
            items: [
              DropdownMenuItem(
                value: '',
                child: Text(_tr('Private chat', '私聊')),
              ),
              for (final group in widget.groups.entries)
                DropdownMenuItem(
                  value: group.key,
                  child: Text(group.value, overflow: TextOverflow.ellipsis),
                ),
            ],
          ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: _tr('Reload status', '重新加载状态'),
            visualDensity: VisualDensity.compact,
            onPressed: _busy ? null : () => _run(_load),
            icon: Icon(
              Icons.refresh,
              size: 18,
              color: SettingsColors.textSecondary,
            ),
          ),
        ],
      ),
      body: DefaultTabController(
        length: tabLabels.length,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error case final error?) ...[
              BotEditorNotice(tone: BotEditorTone.danger, message: error),
              const SizedBox(height: 10),
            ],
            if (_message case final message?) ...[
              BotEditorNotice(tone: BotEditorTone.success, message: message),
              const SizedBox(height: 10),
            ],
            Builder(
              builder: (context) {
                final controller = DefaultTabController.of(context);
                return AnimatedBuilder(
                  animation: controller,
                  builder: (context, _) => BotSegmentedTabs(
                    tabs: tabLabels,
                    selectedIndex: controller.index,
                    onSelected: (index) => controller.animateTo(index),
                  ),
                );
              },
            ),
            const SizedBox(height: 6),
            Expanded(
              child: TabBarView(
                children: [
                  _entries(),
                  _history(),
                  if (_has(LinkMethods.botMemoryFactScopes)) _factEntries(),
                  if (_has(LinkMethods.botMemoryReview)) _reviews(),
                  if (_has(LinkMethods.botMemorySkills)) _learnedSkills(),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          style: botEditorTonalButtonStyle(context),
          onPressed: () => Navigator.pop(context),
          child: Text(MaterialLocalizations.of(context).closeButtonLabel),
        ),
      ],
    );
  }

  Widget _learnedSkills() {
    if (_group != null) {
      return Center(
        child: Text(
          _tr('Select Private chat to manage project skills.', '请选择私聊以管理项目技能。'),
          style: TextStyle(color: SettingsColors.textSecondary),
        ),
      );
    }
    final projects = _rows(_skills['projects']);
    if (projects.isEmpty) {
      return Center(
        child: Text(
          _tr('No available projects.', '没有可用项目。'),
          style: TextStyle(color: SettingsColors.textSecondary),
        ),
      );
    }
    final skills = _rows(_skills['skills']);
    final canMaintain = !_busy && _has(LinkMethods.maintainBotMemorySkill);
    return ListView(
      padding: const EdgeInsets.only(top: 10),
      children: [
        Text(
          _tr('Project', '项目'),
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: SettingsColors.textSecondary,
          ),
        ),
        const SizedBox(height: 6),
        DropdownButtonFormField<String>(
          key: ValueKey(_skills['project']),
          initialValue: _skills['project'] as String?,
          isExpanded: true,
          dropdownColor: AppColors.surfaceRaised,
          decoration: botEditorInput(null),
          items: [
            for (final project in projects)
              DropdownMenuItem(
                value: project['id'] as String,
                child: Text(
                  '${project['name']}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: _busy
              ? null
              : (project) {
                  if (project != null) {
                    unawaited(_run(() => _loadSkills(project)));
                  }
                },
        ),
        const SizedBox(height: 6),
        BotEditorSwitchTile(
          title: _tr('Show archived skills', '显示已归档技能'),
          value: _showArchivedSkills,
          onChanged: _busy
              ? null
              : (value) {
                  setState(() => _showArchivedSkills = value);
                  unawaited(
                    _run(() => _loadSkills(_skills['project'] as String?)),
                  );
                },
        ),
        const SizedBox(height: 6),
        if (skills.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              _tr('No learned skills in this project.', '此项目还没有学习到的技能。'),
              style: TextStyle(
                fontSize: 12.5,
                color: SettingsColors.textSecondary,
              ),
            ),
          ),
        for (final skill in skills)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: BotEditorCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 6,
                children: [
                  Text(
                    '${skill['name']}',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: SettingsColors.textPrimary,
                    ),
                  ),
                  Text(
                    '${skill['trigger']}',
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.45,
                      color: SettingsColors.textPrimary,
                    ),
                  ),
                  Text(
                    [
                      _tr(
                        'Revision ${skill['revision']}',
                        '修订 ${skill['revision']}',
                      ),
                      if (skill['archived'] == true)
                        _tr('Archived', '已归档')
                      else if (skill['stale'] == true)
                        _tr('Stale', '近期未使用'),
                      if (skill['pinned'] == true) _tr('Pinned', '已固定'),
                      if (skill['locked'] == true) _tr('Locked', '已锁定'),
                      if (_date(skill['lastUsedAt']) case final time
                          when time.isNotEmpty)
                        _tr('Last used $time', '上次使用 $time'),
                    ].join(' · '),
                    style: TextStyle(
                      color: SettingsColors.textTertiary,
                      fontSize: 11.5,
                    ),
                  ),
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      if (_has(LinkMethods.botMemorySkillRevisions))
                        TextButton.icon(
                          style: botEditorGhostButtonStyle(context),
                          onPressed: _busy ? null : () => _viewSkill(skill),
                          icon: const Icon(Icons.history, size: 14),
                          label: Text(_tr('Revision history', '修订历史')),
                        ),
                      if (_has(LinkMethods.maintainBotMemorySkill)) ...[
                        TextButton.icon(
                          style: botEditorGhostButtonStyle(context),
                          onPressed: canMaintain
                              ? () => _maintainSkill(
                                  skill,
                                  'pinned',
                                  skill['pinned'] != true,
                                )
                              : null,
                          icon: Icon(
                            skill['pinned'] == true
                                ? Icons.push_pin
                                : Icons.push_pin_outlined,
                            size: 14,
                          ),
                          label: Text(
                            skill['pinned'] == true
                                ? _tr('Unpin', '取消固定')
                                : _tr('Pin', '固定'),
                          ),
                        ),
                        TextButton.icon(
                          style: botEditorGhostButtonStyle(context),
                          onPressed: canMaintain
                              ? () => _maintainSkill(
                                  skill,
                                  'locked',
                                  skill['locked'] != true,
                                )
                              : null,
                          icon: Icon(
                            skill['locked'] == true
                                ? Icons.lock_open_outlined
                                : Icons.lock_outline,
                            size: 14,
                          ),
                          label: Text(
                            skill['locked'] == true
                                ? _tr('Unlock', '解锁')
                                : _tr('Lock', '锁定'),
                          ),
                        ),
                        TextButton.icon(
                          style: botEditorGhostButtonStyle(context),
                          onPressed: canMaintain
                              ? () => _maintainSkill(
                                  skill,
                                  'archived',
                                  skill['archived'] != true,
                                )
                              : null,
                          icon: Icon(
                            skill['archived'] == true
                                ? Icons.unarchive_outlined
                                : Icons.archive_outlined,
                            size: 14,
                          ),
                          label: Text(
                            skill['archived'] == true
                                ? _tr('Restore', '恢复')
                                : _tr('Archive', '归档'),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  List<Widget> _memorySummary(_Row memory) {
    final used = memory['used'];
    final budget = memory['budget'];
    final injected = memory['injected'];
    final snapshotStatus = memory['snapshotStatus'];
    if (used is! int && injected is! int && snapshotStatus is! String) {
      return const [];
    }
    final progress = (used is int && budget is int && budget > 0)
        ? (used / budget).clamp(0.0, 1.0)
        : null;
    final (statusLabel, statusTone) = switch (snapshotStatus) {
      'confirmed' => (
        _tr('Current snapshot confirmed', '已确认当前快照'),
        BotEditorTone.success,
      ),
      'pending' => (
        _tr('Snapshot refresh pending', '等待刷新快照'),
        BotEditorTone.warning,
      ),
      String() => (
        _tr('Current snapshot unknown', '当前快照未知'),
        BotEditorTone.neutral,
      ),
      _ => (null, BotEditorTone.neutral),
    };
    return [
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: BotEditorCard(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 7,
            children: [
              if (used is int && budget is int) ...[
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _tr(
                          '$used / $budget characters saved',
                          '已保存 $used / $budget 字符',
                        ),
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: SettingsColors.textPrimary,
                        ),
                      ),
                    ),
                    if (statusLabel != null)
                      BotStatusPill(label: statusLabel, tone: statusTone),
                  ],
                ),
                if (progress != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 4,
                      backgroundColor: SettingsColors.stroke,
                    ),
                  ),
              ] else if (statusLabel != null)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: BotStatusPill(label: statusLabel, tone: statusTone),
                ),
              if (injected is int)
                Text(
                  _tr(
                    '$injected characters fit the next snapshot budget',
                    '下次快照预算可容纳 $injected 字符',
                  ),
                  style: TextStyle(
                    fontSize: 12,
                    color: SettingsColors.textSecondary,
                  ),
                ),
            ],
          ),
        ),
      ),
    ];
  }

  Widget _factEntries() {
    if (_group != null) {
      return Center(
        child: Text(_tr('Select Private chat to manage facts.', '请选择私聊以管理事实。')),
      );
    }
    final projects = _factProjects(_factScopes);
    final hasPrivate = _factScopes['private'] == true;
    if (!hasPrivate && projects.isEmpty) {
      return Center(child: Text(_tr('No fact stores available.', '暂无可用的事实库。')));
    }
    final project = _factProject;
    final entries = _rows(_facts['entries']);
    final groups = project == null
        ? {
            'self': _tr('Self facts', '自我事实'),
            'person': _tr('People facts', '人物事实'),
          }
        : {'project': _tr('Project facts', '项目事实')};
    return ListView(
      padding: const EdgeInsets.only(top: 10),
      children: [
        if (projects.isNotEmpty) ...[
          Row(
            children: [
              Text(
                _tr('Fact store', '事实库'),
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  color: SettingsColors.textSecondary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<String>(
                  key: ValueKey(project),
                  initialValue: project ?? '',
                  isExpanded: true,
                  dropdownColor: AppColors.surfaceRaised,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontSize: 13,
                    color: SettingsColors.textPrimary,
                  ),
                  decoration: botEditorInput(null),
                  items: [
                    if (hasPrivate)
                      DropdownMenuItem(
                        value: '',
                        child: Text(_tr('Private facts', '私聊事实')),
                      ),
                    for (final project in projects.entries)
                      DropdownMenuItem(
                        value: project.key,
                        child: Text(
                          project.value,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: _busy
                      ? null
                      : (value) {
                          if (value == null || value == (project ?? '')) return;
                          setState(() {
                            _factProject = value.isEmpty ? null : value;
                            _facts = const {};
                          });
                          unawaited(_run(_loadFacts));
                        },
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
        ],
        ..._memorySummary(_facts),
        for (final group in groups.entries) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    group.value,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: SettingsColors.textSecondary,
                    ),
                  ),
                ),
                if (_has(LinkMethods.changeBotMemory))
                  TextButton.icon(
                    style: botEditorTonalButtonStyle(context),
                    onPressed: _busy || _facts.isEmpty
                        ? null
                        : group.key == 'person'
                        ? () => _addPersonFact(entries)
                        : () => _edit(null, group.key),
                    icon: const Icon(Icons.add, size: 15),
                    label: Text(_addFactLabel(group.key)),
                  ),
              ],
            ),
          ),
          for (final entry in entries)
            if (entry['kind'] == group.key)
              _entryCard(
                entry,
                scope: projects[project] ?? _tr('Private chat', '私聊'),
                snapshotStatus: _facts['snapshotStatus'],
                factKind: group.key,
              ),
          if (_facts.isNotEmpty &&
              !entries.any((entry) => entry['kind'] == group.key))
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                _tr('No saved facts.', '暂无已保存的事实。'),
                style: TextStyle(
                  fontSize: 12.5,
                  color: SettingsColors.textSecondary,
                ),
              ),
            ),
        ],
      ],
    );
  }

  Widget _entries() {
    final filter = _filter.text.trim().toLowerCase();
    final entries = _rows(_memory['entries'])
        .where((row) => '${row['text']}'.toLowerCase().contains(filter));
    final hasSessionActions =
        _has(LinkMethods.refreshBotMemory) ||
        (_group == null && _has(LinkMethods.newBotConversation));
    return ListView(
      padding: const EdgeInsets.only(top: 10),
      children: [
        ..._memorySummary(_memory),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _filter,
                onChanged: (_) => setState(() {}),
                style: TextStyle(
                  fontSize: 13.5,
                  color: SettingsColors.textPrimary,
                ),
                decoration: botEditorInput(
                  null,
                  hintText: _tr('Filter saved memory', '筛选已保存的记忆'),
                  prefixIcon: const Icon(Icons.search, size: 17),
                ),
              ),
            ),
            if (_has(LinkMethods.changeBotMemory)) ...[
              const SizedBox(width: 8),
              FilledButton.icon(
                style: botEditorButtonStyle(context),
                onPressed: _busy ? null : () => _edit(),
                icon: const Icon(Icons.add, size: 16),
                label: Text(_tr('Add memory', '添加记忆')),
              ),
            ],
          ],
        ),
        if (hasSessionActions) ...[
          const SizedBox(height: 6),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              if (_has(LinkMethods.refreshBotMemory))
                TextButton.icon(
                  style: botEditorGhostButtonStyle(context),
                  onPressed: _busy
                      ? null
                      : () => _run(() async {
                          final result = await _call(
                            LinkMethods.refreshBotMemory,
                          );
                          if (mounted) {
                            setState(
                              () => _message = switch (result['status']) {
                                'afterReply' => _tr(
                                  'Memory will refresh after the current reply.',
                                  '当前回复结束后将刷新记忆。',
                                ),
                                'onOpen' => _tr(
                                  'The next conversation launch will use the latest memory.',
                                  '下次启动会话时将载入最新记忆。',
                                ),
                                'restarting' => _tr(
                                  'Refreshing memory in the current conversation.',
                                  '正在刷新当前会话的记忆。',
                                ),
                                _ => _tr(
                                  'Memory refresh requested.',
                                  '已请求刷新记忆。',
                                ),
                              },
                            );
                            await _loadSnapshotStatus();
                          }
                        }),
                  icon: const Icon(Icons.sync, size: 15),
                  label: Text(_tr('Refresh chat memory', '刷新会话记忆')),
                ),
              if (_group == null && _has(LinkMethods.newBotConversation))
                TextButton.icon(
                  style: botEditorGhostButtonStyle(context),
                  onPressed: _busy ? null : _newConversation,
                  icon: const Icon(Icons.add_comment_outlined, size: 15),
                  label: Text(_tr('New conversation', '开启新对话')),
                ),
            ],
          ),
        ],
        const SizedBox(height: 10),
        if (entries.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              _tr('No matching memory.', '没有符合条件的记忆。'),
              style: TextStyle(
                fontSize: 12.5,
                color: SettingsColors.textSecondary,
              ),
            ),
          ),
        for (final entry in entries)
          _entryCard(
            entry,
            scope: widget.groups[_group] ?? _tr('Private chat', '私聊'),
            snapshotStatus: _memory['snapshotStatus'],
          ),
      ],
    );
  }

  Widget _entryCard(
    _Row entry, {
    required String scope,
    required Object? snapshotStatus,
    String? factKind,
  }) {
    final fact = factKind != null;
    final shared = entry['kind'] == 'sharedFact';
    final share = entry['share'];
    final sourceUnavailable = entry['sourceUnavailable'] == true;
    final canShare =
        widget.localOwner &&
        _group == null &&
        !sourceUnavailable &&
        widget.groups.isNotEmpty &&
        _has(LinkMethods.shareBotMemoryEntry);
    final canRetain =
        sourceUnavailable &&
        widget.localOwner &&
        _has(LinkMethods.deleteBotMemorySource);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: BotEditorCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            SelectableText(
              '${entry['text'] ?? ''}',
              style: TextStyle(
                fontSize: 13.5,
                height: 1.5,
                color: SettingsColors.textPrimary,
              ),
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Text(
                    [
                      if (!fact)
                        switch (entry['kind']) {
                          'sharedFact' => _tr('Shared memory', '共享记忆'),
                          'groupFact' => _tr('Group fact', '群聊事实'),
                          _ => _tr('User preference', '用户偏好'),
                        },
                      if (share case {'sourceRevision': final int revision})
                        _tr('Source revision $revision', '来源修订 $revision'),
                      if (factKind == 'person')
                        entry['personName'] as String? ??
                            _tr('Unassigned person', '未关联人物'),
                      scope,
                      if (entry['revision'] case final int revision)
                        if (fact || snapshotStatus != null)
                          _tr('Saved revision $revision', '已保存修订 $revision'),
                      if (entry['activeRevision'] case final int revision)
                        snapshotStatus == 'confirmed'
                            ? _tr('Loaded revision $revision', '已载入修订 $revision')
                            : _tr(
                                'Last confirmed revision $revision',
                                '上次确认的修订 $revision',
                              )
                      else if (snapshotStatus == 'confirmed')
                        _tr('Not in the current snapshot', '未载入当前快照'),
                      if (!sourceUnavailable && entry['injected'] == false)
                        _tr('Outside the next snapshot budget', '超出下次快照预算'),
                      if (entry['sourceKind'] == 'migration')
                        _tr('Imported from old notes', '从旧笔记导入'),
                      if (entry['needsReview'] == true)
                        _tr('Needs review', '待核对'),
                      if (sourceUnavailable)
                        _tr('Paused · Source unavailable', '已暂停 · 来源不可用'),
                      _date(entry['updatedAt']),
                    ].where((part) => part.isNotEmpty).join(' · '),
                    style: TextStyle(
                      color: SettingsColors.textTertiary,
                      fontSize: 11.5,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                if (entry['source'] case final source?)
                  if (_has(LinkMethods.botMemorySource))
                    TextButton.icon(
                      style: botEditorGhostButtonStyle(context),
                      onPressed: _busy ? null : () => _openSource(source),
                      icon: const Icon(Icons.forum_outlined, size: 14),
                      label: Text(_tr('View source', '查看原话')),
                    ),
                if (canShare)
                  TextButton.icon(
                    style: botEditorGhostButtonStyle(context),
                    onPressed: _busy
                        ? null
                        : () => _shareMemory(entry, fact: fact),
                    icon: const Icon(Icons.ios_share_outlined, size: 14),
                    label: Text(_tr('Share to group', '共享到群聊')),
                  ),
                if (widget.localOwner && _has(LinkMethods.revokeBotMemoryShare))
                  if (share case {'id': final String shareId})
                    TextButton.icon(
                      style: botEditorGhostButtonStyle(context),
                      onPressed: _busy
                          ? null
                          : () => _revokeMemoryShare(entry, shareId),
                      icon: const Icon(Icons.link_off_outlined, size: 14),
                      label: Text(_tr('Revoke share', '撤回共享')),
                    ),
                if (!shared && _has(LinkMethods.changeBotMemory)) ...[
                  if (canRetain)
                    TextButton.icon(
                      style: botEditorGhostButtonStyle(context),
                      onPressed: _busy
                          ? null
                          : () => _retain(entry, fact: fact),
                      icon: const Icon(Icons.check_circle_outline, size: 14),
                      label: Text(_tr('Keep fact', '保留事实')),
                    ),
                  TextButton.icon(
                    style: botEditorGhostButtonStyle(context),
                    onPressed: _busy || sourceUnavailable
                        ? null
                        : () => _edit(entry, factKind),
                    icon: const Icon(Icons.edit_outlined, size: 14),
                    label: Text(_tr('Edit', '编辑')),
                  ),
                  TextButton.icon(
                    style: botEditorGhostButtonStyle(context),
                    onPressed: _busy
                        ? null
                        : () => _change({
                            'action': 'pin',
                            'id': entry['id'],
                            'revision': entry['revision'],
                            'pinned': entry['pinned'] != true,
                          }, fact: fact),
                    icon: Icon(
                      entry['pinned'] == true
                          ? Icons.push_pin
                          : Icons.push_pin_outlined,
                      size: 14,
                    ),
                    label: Text(
                      entry['pinned'] == true
                          ? _tr('Unpin', '取消固定')
                          : _tr('Pin', '固定'),
                    ),
                  ),
                  TextButton.icon(
                    style: botEditorGhostButtonStyle(
                      context,
                      destructive: true,
                    ),
                    onPressed: _busy ? null : () => _forget(entry, fact: fact),
                    icon: const Icon(Icons.delete_outline, size: 14),
                    label: Text(_tr('Forget', '忘掉')),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _history() {
    return ListView(
      padding: const EdgeInsets.only(top: 10),
      children: [
        if (widget.localOwner &&
            _group == null &&
            _factProjects(_factScopes).isNotEmpty) ...[
          Text(
            _tr('History scope', '历史范围'),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: SettingsColors.textSecondary,
            ),
          ),
          const SizedBox(height: 6),
          DropdownButtonFormField<String>(
            key: ValueKey(_historyProject),
            initialValue: _historyProject ?? '',
            isExpanded: true,
            dropdownColor: AppColors.surfaceRaised,
            decoration: botEditorInput(null),
            items: [
              DropdownMenuItem(value: '', child: Text(_tr('Private chat', '私聊'))),
              for (final project in _factProjects(_factScopes).entries)
                DropdownMenuItem(value: project.key, child: Text(project.value)),
            ],
            onChanged: _busy
                ? null
                : (value) => setState(() {
                    _historyProject = value == '' ? null : value;
                    _legacyDiary = false;
                    _hits = const [];
                    _searched = null;
                    _cursor = null;
                  }),
          ),
          const SizedBox(height: 8),
        ],
        if (widget.localOwner && _group == null && _historyProject == null)
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(
              _tr('Search unassigned legacy diaries', '搜索范围未知的旧日记'),
              style: TextStyle(fontSize: 13, color: SettingsColors.textPrimary),
            ),
            value: _legacyDiary,
            onChanged: _busy
                ? null
                : (value) => setState(() {
                    _legacyDiary = value ?? false;
                    _hits = const [];
                    _searched = null;
                    _cursor = null;
                  }),
          ),
        const SizedBox(height: 4),
        TextField(
          controller: _query,
          onSubmitted: (_) => _search(),
          style: TextStyle(fontSize: 13.5, color: SettingsColors.textPrimary),
          decoration: botEditorInput(
            null,
            hintText: _tr('Search conversation history', '搜索对话历史'),
            suffixIcon: IconButton(
              tooltip: _tr('Search', '搜索'),
              onPressed: _busy || !_has(LinkMethods.botMemorySearch)
                  ? null
                  : () => _search(),
              icon: const Icon(Icons.search, size: 18),
            ),
          ),
        ),
        const SizedBox(height: 10),
        if (_searched != null && _hits.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              _tr('No matching messages.', '没有符合条件的消息。'),
              style: TextStyle(
                fontSize: 12.5,
                color: SettingsColors.textSecondary,
              ),
            ),
          ),
        for (final match in _hits)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: BotEditorCard(
              padding: EdgeInsets.zero,
              child: ListTile(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(11),
                ),
                title: Text(
                  '${match['snippet'] ?? ''}',
                  style: TextStyle(
                    fontSize: 13.5,
                    height: 1.45,
                    color: SettingsColors.textPrimary,
                  ),
                ),
                subtitle: Text(
                  [
                    if (match['kind'] == 'diarySummary')
                      _tr('Diary summary', '日记摘要')
                    else
                      _role(match['role']),
                    _date(match['time']),
                  ].where((part) => part.isNotEmpty).join(' · '),
                  style: TextStyle(
                    color: SettingsColors.textTertiary,
                    fontSize: 11.5,
                  ),
                ),
                onTap: _busy || !_has(LinkMethods.botMemorySource)
                    ? null
                    : () => _openSource(
                        match['reference'],
                        legacyDiary: _legacyDiary && _group == null,
                        historyProject: _group == null ? _historyProject : null,
                      ),
              ),
            ),
          ),
        if (_cursor != null)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              style: botEditorTonalButtonStyle(context),
              onPressed: _busy ? null : () => _search(more: true),
              child: Text(_tr('More results', '更多结果')),
            ),
          ),
      ],
    );
  }

  List<Widget> _reviewUsage() {
    final limits = _row(_review['limits']);
    final usage = _row(_review['lastUsage']);
    final decimal = MaterialLocalizations.of(context).formatDecimal;
    String? count(_Row row, String key) => switch (row[key]) {
      final int n => decimal(n),
      _ => null,
    };
    final evidence = [
      if (count(limits, 'maxEvidenceMessages') case final n?)
        _tr('$n messages', '$n 条消息'),
      if (count(limits, 'maxEvidenceCharacters') case final n?)
        _tr('$n characters', '$n 字符'),
    ].join(' · ');
    final output = [
      if (count(limits, 'maxOutputTokens') case final n?)
        _tr('$n tokens', '$n 个令牌'),
      if (count(limits, 'maxOutputCharacters') case final n?)
        _tr('$n characters', '$n 字符'),
    ].join(' · ');
    final limitLines = [
      if (evidence.isNotEmpty)
        _tr('Evidence per request: $evidence', '每次请求的证据：$evidence'),
      if (output.isNotEmpty)
        _tr('Output per request: $output', '每次请求的输出：$output'),
      if (count(limits, 'maxAttempts') case final n?)
        _tr('$n attempts per job', '每次作业最多尝试 $n 次'),
    ];
    final usageLines = [
      if (usage['requestCount'] case final int n)
        n == 1
            ? _tr('1 request', '1 次请求')
            : _tr('${decimal(n)} requests', '${decimal(n)} 次请求'),
      if (count(usage, 'inputCharacters') case final n?)
        _tr('Input: $n characters', '输入：$n 字符'),
      if (count(usage, 'outputCharacters') case final n?)
        _tr('Output: $n characters', '输出：$n 字符'),
    ];
    return [
      if (limitLines.isNotEmpty)
        ListTile(
          title: Text(_tr('Review limits', '复盘限额')),
          subtitle: Text(
            [...limitLines, _tr('Price unknown', '价格未知')].join('\n'),
          ),
        ),
      if (usageLines.isNotEmpty)
        ListTile(
          title: Text(_tr('Last review usage', '上次复盘用量')),
          subtitle: Text(usageLines.join('\n')),
        ),
    ];
  }

  Widget _reviews() {
    final settings = _row(_review['settings']);
    final theme = Theme.of(context);
    final options = {
      'automatic': _tr('Automatic review', '自动复盘'),
      'memoryApproval': _tr(
        'Require approval for all memory changes',
        '所有记忆变更均需审核',
      ),
      'skillApproval': _tr('Require approval for skills', '技能变更需审核'),
    };
    final usage = _reviewUsage();
    return ListView(
      padding: const EdgeInsets.only(top: 10),
      children: [
        if (settings.isNotEmpty) ...[
          BotEditorCard(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: Column(
              children: [
                for (final option in options.entries) ...[
                  BotEditorSwitchTile(
                    title: option.value,
                    value: settings[option.key] == true,
                    onChanged:
                        _busy || !_has(LinkMethods.configureBotMemoryReview)
                        ? null
                        : (value) => _configure(option.key, value),
                  ),
                  Container(height: 1, color: SettingsColors.divider),
                ],
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                  title: Text(
                    _tr('Review model', '复盘模型'),
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w500,
                      color: SettingsColors.textPrimary,
                    ),
                  ),
                  subtitle: Text(
                    settings['model'] as String? ??
                        _tr('Use the Bot model', '使用 Bot 模型'),
                    style: TextStyle(
                      fontSize: 12,
                      color: SettingsColors.textSecondary,
                    ),
                  ),
                  trailing: Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: SettingsColors.iconTertiary,
                  ),
                  onTap: _busy || !_has(LinkMethods.configureBotMemoryReview)
                      ? null
                      : () async {
                          final model = await _text(
                            _tr('Review model', '复盘模型'),
                            settings['model'] as String? ?? '',
                            hint: _tr(
                              'Leave blank to use the Bot model',
                              '留空则使用 Bot 模型',
                            ),
                            multiline: false,
                          );
                          if (model != null) await _configure('model', model);
                        },
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
        ],
        if (_review['running'] == true ||
            (_review['queued'] is int && (_review['queued'] as int) > 0) ||
            _date(_review['lastReviewedAt']).isNotEmpty ||
            _review['error'] is String) ...[
          BotEditorCard(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 4,
              children: [
                if (_review['running'] == true)
                  Text(_tr('Reviewing memory…', '正在复盘记忆…')),
                if (_review['queued'] case final int queued when queued > 0)
                  Text(_tr('$queued queued', '$queued 项等待复盘')),
                if (_date(_review['lastReviewedAt']) case final time
                    when time.isNotEmpty)
                  Text(
                    _tr('Last review · $time', '上次复盘 · $time'),
                    style: TextStyle(
                      fontSize: 12,
                      color: SettingsColors.textSecondary,
                    ),
                  ),
                if (_review['error'] case final String error)
                  Text(
                    error,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
        ],
        if (usage.isNotEmpty) ...[
          BotEditorCard(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            child: Column(children: usage),
          ),
          const SizedBox(height: 10),
        ],
        Wrap(
          spacing: 8,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (_has(LinkMethods.refineBotMemory))
              TextButton.icon(
                style: botEditorTonalButtonStyle(context),
                onPressed: _busy ? null : _refine,
                icon: const Icon(Icons.auto_awesome_outlined, size: 15),
                label: Text(_tr('Organize memory', '整理记忆')),
              ),
            FilterChip(
              label: Text(_tr('Show audit history', '显示审核记录')),
              selected: _audit,
              onSelected: _busy
                  ? null
                  : (value) {
                      setState(() => _audit = value);
                      unawaited(_run(_load));
                    },
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (_rows(_review['proposals']).isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              _audit
                  ? _tr('No review history.', '暂无审核记录。')
                  : _tr('No pending proposals.', '没有待审核提案。'),
              style: TextStyle(
                fontSize: 12.5,
                color: SettingsColors.textSecondary,
              ),
            ),
          ),
        for (final proposal in _rows(_review['proposals'])) _proposal(proposal),
      ],
    );
  }

  String _proposalAction(Object? action) => switch (action) {
    'add' => _tr('Add memory', '添加记忆'),
    'update' => _tr('Update memory', '更新记忆'),
    'remove' => _tr('Forget memory', '忘掉记忆'),
    'batch' => _tr('Memory changes', '批量整理记忆'),
    'skill' => _tr('Skill', '技能'),
    _ => '',
  };

  Widget _diffStrip(
    String label,
    String text, {
    required Color accent,
    required Color background,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SizedBox(height: 8),
      Text(
        label,
        style: TextStyle(
          fontSize: 11.5,
          color: accent,
          fontWeight: FontWeight.w600,
        ),
      ),
      const SizedBox(height: 4),
      ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: DecoratedBox(
          decoration: BoxDecoration(color: background),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(width: 3, color: accent),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 11,
                      vertical: 8,
                    ),
                    child: SelectableText(
                      text,
                      style: TextStyle(
                        fontSize: 13.5,
                        height: 1.45,
                        color: SettingsColors.textPrimary,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ],
  );

  List<Widget> _proposalDiff(_Row change) => [
    if (change['before'] case final String before when before.isNotEmpty)
      _diffStrip(
        _tr('Current', '当前内容'),
        before,
        accent: AppColors.removed,
        background: AppColors.removedBackground,
      ),
    if (change['after'] case final String after when after.isNotEmpty)
      _diffStrip(
        _tr('Proposed', '拟议内容'),
        after,
        accent: AppColors.added,
        background: AppColors.addedBackground,
      ),
  ];

  List<Widget> _proposalSources(_Row proposal) => [
    if (_has(LinkMethods.botMemorySource))
      for (final evidence in _rows(proposal['evidence']))
        if (evidence['source'] case final source?)
          TextButton.icon(
            style: botEditorGhostButtonStyle(context),
            onPressed: _busy
                ? null
                : () => _openSource(
                    source,
                    historyProject: _row(source)['historyProject'] as String?,
                  ),
            icon: const Icon(Icons.forum_outlined, size: 14),
            label: Text(
              _tr(
                'View ${_role(evidence['role']).toLowerCase()} source',
                '查看${_role(evidence['role'])}原话',
              ),
            ),
          ),
  ];

  Widget _proposal(_Row proposal) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: BotEditorCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            [
              _proposalAction(proposal['action']),
              _status(proposal['status']),
              _date(proposal['reviewedAt'] ?? proposal['createdAt']),
            ].where((part) => part.isNotEmpty).join(' · '),
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: SettingsColors.textPrimary,
            ),
          ),
          ..._proposalDiff(proposal),
          for (final change in _rows(proposal['changes'])) ...[
            const SizedBox(height: 10),
            Container(height: 1, color: SettingsColors.divider),
            const SizedBox(height: 8),
            Text(
              _proposalAction(change['action']),
              style: TextStyle(
                fontSize: 12,
                color: SettingsColors.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
            ..._proposalDiff(change),
            if (_proposalSources(change) case final sources
                when sources.isNotEmpty) ...[
              const SizedBox(height: 6),
              Wrap(spacing: 4, runSpacing: 4, children: sources),
            ],
          ],
          if (proposal['reviewer'] case final String reviewer) ...[
            const SizedBox(height: 8),
            Text(
              _tr('Reviewed by $reviewer', '审核人 $reviewer'),
              style: TextStyle(
                fontSize: 12,
                color: SettingsColors.textSecondary,
              ),
            ),
          ],
          if (proposal['error'] case final String error) ...[
            const SizedBox(height: 8),
            BotEditorNotice(tone: BotEditorTone.danger, message: error),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (_rows(proposal['changes'])
                  .every((change) => !change.containsKey('evidence')))
                ..._proposalSources(proposal),
              if (proposal['status'] == 'pending' &&
                  _has(LinkMethods.decideBotMemory)) ...[
                TextButton(
                  style: botEditorGhostButtonStyle(context, destructive: true),
                  onPressed: _busy ? null : () => _decide(proposal, false),
                  child: Text(
                    proposal['action'] == 'batch'
                        ? _tr('Reject batch', '拒绝整批')
                        : _tr('Reject', '拒绝'),
                  ),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 30),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(7),
                    ),
                    textStyle: Theme.of(context).textTheme.labelMedium?.copyWith(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  onPressed: _busy ? null : () => _decide(proposal, true),
                  child: Text(
                    proposal['action'] == 'batch'
                        ? _tr('Approve batch', '通过整批')
                        : _tr('Approve', '通过'),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    ),
  );
}
