import 'dart:async';
import 'dart:math' as math;

import 'package:bao_link/bao_link.dart' show LinkErrors, LinkRemoteException;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../ide/git/git_graph_painter.dart';
import '../ide/git/git_model.dart';
import '../ide/git/ide_git_commit_panel.dart'
    show IdeGitCommitPanel, IdeGitCommitTabs;
import '../ide/git/ide_git_list_tree_switch.dart';
import '../ide/git/ide_git_log_view.dart'
    show IdeGitIslandSplit, IdeGitLogView, ideCommitChangeStatus;
import '../ide/git/ide_git_patch_reader.dart';
import '../ide/git/ide_git_presentation.dart';
import '../ide/git/scm_tree.dart';
import '../ide/ide_dates.dart';
import '../l10n/l10n.dart';
import '../ide/ide_input.dart';
import '../ide/ide_list.dart';
import '../theme/material_file_icons.dart';
import '../theme/app_theme.dart' show AppColors;
import '../theme/codicons.dart';
import '../theme/workbench_theme.dart' show themeColors;
import '../workspace/islands.dart';
import 'desktop_remote_git_client.dart';

class DesktopRemoteGitView extends StatefulWidget {
  const DesktopRemoteGitView({
    super.key,
    required this.client,
    required this.project,
    required this.review,
  });

  final DesktopRemoteGitClient client;
  final String project;
  final Widget review;

  @override
  State<DesktopRemoteGitView> createState() => _DesktopRemoteGitViewState();
}

class _DesktopRemoteGitViewState extends State<DesktopRemoteGitView> {
  final _message = TextEditingController();
  final _search = TextEditingController();
  final _checked = <String>{};
  RemoteGitStatus? _status;
  RemoteGitCapabilities? _capabilities;
  Future<RemoteGitHistory?>? _history;
  final _olderCommits = <RemoteGitCommit>[];
  Future<RemoteGitStashes?>? _stashes;
  Future<RemoteGitCommitFiles?>? _commitFiles;
  Future<RemoteGitCommitFiles?>? _stashFiles;
  RemoteGitCommit? _commit;
  String? _commitBranch;
  RemoteGitStash? _stash;
  Future<RemoteGitDiff?>? _diff;
  String? _diffPath;
  String? _diffGroup;
  bool _workingDiff = false;
  String? _branch;
  String? _path;
  String? _author;
  DateTimeRange? _dates;
  Timer? _searchDelay;
  bool _loading = true;
  bool _loadFailed = false;
  bool _writing = false;
  String? _operationError;
  bool _review = false;
  bool _stashTab = false;
  bool _tree = false;
  bool _folded = false;
  double? _detailsHeight;
  double? _detailsWidth;

  bool get _zh => Localizations.localeOf(context).languageCode == 'zh';
  String _text(String en, String zh) => _zh ? zh : en;

  DesktopRemoteGitClient get _client => widget.client;
  String get _project => widget.project;
  String? get _expected =>
      _capabilities?.canWrite == true && !_loading && !_writing
      ? _status?.state
      : null;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _searchDelay?.cancel();
    _search.dispose();
    _message.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _loadFailed = false;
      if (_status != null) {
        _loadHistory();
      }
      if (_stashTab) {
        _stashes = _client.stashes(_project)..ignore();
      }
    });
    try {
      final status = await _client.status(_project);
      if (!mounted) return;
      setState(() {
        if (_workingDiff && _status?.state != status?.state) {
          _workingDiff = false;
          _diff = null;
          _diffPath = null;
        }
        if (_status == null && status != null) {
          _checked.addAll(
            status.files.where((f) => f.group != 'merge').map((f) => f.path),
          );
          _loadHistory();
        }
        _status = status;
        _checked.retainAll(status?.files.map((file) => file.path) ?? []);
      });
      if (status != null) {
        try {
          final capabilities = await _client.capabilities(_project);
          if (!mounted) return;
          _capabilities = capabilities;
        } on Object {
          if (!mounted) return;
          _capabilities = null;
        }
      }
      setState(() => _loading = false);
    } on Object {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadFailed = true;
        _capabilities = null;
      });
    }
  }

  void _loadHistory({int offset = 0}) {
    if (offset == 0) _olderCommits.clear();
    _history = _client.history(
      _project,
      offset: offset,
      branch: _branch,
      path: _path,
      author: _author,
      since: _dates?.start,
      until: _dates?.end.add(const Duration(days: 1)),
      search: _search.text.trim().isEmpty ? null : _search.text.trim(),
    )..ignore();
  }

  void _selectCommit(RemoteGitCommit? commit) => setState(() {
    _commit = commit;
    _folded = false;
    _diff = null;
    _commitBranch = _branch;
    _commitFiles = commit == null
        ? null
        : _client.commitFiles(_project, commit.hash, branch: _commitBranch);
  });

  void _openFile(
    RemoteGitFile file, {
    RemoteGitCommit? commit,
    RemoteGitStash? stash,
  }) => setState(() {
    _diffPath = file.path;
    _diffGroup = file.group;
    _workingDiff = commit == null && stash == null;
    _diff = stash != null
        ? _client.stashDiff(_project, stash.id, file.path)
        : commit != null
        ? _client.commitDiff(
            _project,
            commit.hash,
            file.path,
            branch: _commitBranch,
          )
        : _client.workingDiff(
            _project,
            file.path,
            staged: file.group == 'index',
          );
  });

  Future<void> _write(Future<bool> Function() operation) async {
    setState(() {
      _writing = true;
      _operationError = null;
    });
    try {
      if (!await operation() && mounted) {
        _operationError = _text(
          'This host does not support the Git operation.',
          '此主机不支持该 Git 操作。',
        );
      }
    } on Object catch (error) {
      if (mounted) {
        _operationError =
            error is LinkRemoteException &&
                error.code == LinkErrors.gitOutcomeUnknown
            ? _text(
                'The result is unknown. Check the repository state before retrying.',
                '操作结果未知，请确认仓库状态后再重试。',
              )
            : '${_text('Git operation failed', 'Git 操作失败')}：$error';
      }
    } finally {
      if (mounted) {
        await _refresh();
        if (mounted) setState(() => _writing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    if (status == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          if (!_loading)
            Row(
              children: [
                Expanded(
                  child: _notice(
                    _loadFailed
                        ? _text('Could not load Git', '无法加载 Git')
                        : _text('Project Git is unavailable', '项目 Git 不可用'),
                  ),
                ),
                TextButton(
                  onPressed: _refresh,
                  child: Text(_text('Retry', '重试')),
                ),
              ],
            ),
          Expanded(child: widget.review),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_loading || _writing) const LinearProgressIndicator(minHeight: 2),
        if (_loadFailed) _notice(_text('Could not refresh Git', '无法刷新 Git')),
        if (_operationError case final error?)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(error, maxLines: 3, overflow: TextOverflow.ellipsis),
          ),
        Expanded(
          child: _review
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _back(
                      _text('Session changes', '会话改动'),
                      () => setState(() => _review = false),
                    ),
                    Expanded(child: widget.review),
                  ],
                )
              : _split(status),
        ),
      ],
    );
  }

  Widget _split(RemoteGitStatus status) => LayoutBuilder(
    builder: (context, limits) {
      final beside = IdeGitLogView.detailsBeside(limits.maxWidth);
      final folded = !beside && _folded;
      final maxDetails = beside
          ? math.min(
              limits.maxWidth * .6,
              math.max(220.0, limits.maxWidth - 280),
            )
          : math.min(
              limits.maxHeight * .75,
              math.max(0.0, limits.maxHeight - 120),
            );
      final preferred = beside
          ? _detailsWidth ?? 380.0
          : folded
          ? IdeGitCommitPanel.foldedHeight
          : _detailsHeight ?? math.max(limits.maxHeight / 2, 340.0);
      return IdeGitIslandSplit(
        beside: beside,
        extent: math.min(preferred, maxDetails),
        onResize: folded
            ? null
            : (size) => setState(() {
                final clamped = size
                    .clamp(
                      math.min(beside ? 220.0 : 145.0, maxDetails),
                      maxDetails,
                    )
                    .toDouble();
                if (beside) {
                  _detailsWidth = clamped;
                } else {
                  _detailsHeight = clamped;
                }
              }),
        log: Island(
          color: AppColors.code,
          child: _diff == null ? _log(status) : _diffView(),
        ),
        details: Island(
          color: AppColors.code,
          child: _details(status, beside: beside, folded: folded),
        ),
      );
    },
  );

  Widget _log(RemoteGitStatus status) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 4, 0),
        child: Row(
          children: [
            Expanded(
              child: IgnorePointer(
                ignoring: _capabilities == null,
                child: ExcludeFocus(
                  excluding: _capabilities == null,
                  child: IdeInputBox(
                    controller: _search,
                    placeholder: _text('Search commits', '搜索提交信息'),
                    radius: Islands.controlRadius,
                    onChanged: (_) {
                      _searchDelay?.cancel();
                      _searchDelay = Timer(
                        const Duration(milliseconds: 250),
                        () => setState(_loadHistory),
                      );
                    },
                    onSubmitted: (_) {
                      _searchDelay?.cancel();
                      setState(_loadHistory);
                    },
                  ),
                ),
              ),
            ),
            _icon(
              _text('Session changes', '会话改动'),
              Icons.rate_review_outlined,
              () => setState(() => _review = true),
            ),
            _icon(
              _text('Refresh Git', '刷新 Git'),
              Icons.refresh,
              _loading || _writing ? null : _refresh,
            ),
          ],
        ),
      ),
      if (_capabilities case final capabilities?)
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            children: [
              PopupMenuButton<String>(
                tooltip: _text('Branch', '分支'),
                onSelected: (branch) => setState(() {
                  _branch = branch.isEmpty ? null : branch;
                  _loadHistory();
                }),
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: '',
                    child: Text(_text('Current branch', '当前分支')),
                  ),
                  for (final branch in capabilities.branches)
                    PopupMenuItem(value: branch, child: Text(branch)),
                ],
                child: _filterLabel(
                  Codicons.gitBranch,
                  _branch ?? _text('Current branch', '当前分支'),
                  active: _branch != null,
                  dropdown: true,
                ),
              ),
              _filter(
                Codicons.file,
                _path ?? _text('Path', '路径'),
                _path != null,
                () => _filterPathOrAuthor(path: true),
              ),
              _filter(
                Codicons.person,
                _author ?? _text('Author', '作者'),
                _author != null,
                () => _filterPathOrAuthor(path: false),
              ),
              _filter(
                Codicons.calendar,
                _text('Date', '日期'),
                _dates != null,
                _filterDate,
              ),
              _icon(
                _text('Clear filters', '清除筛选'),
                Icons.filter_alt_off_outlined,
                () => setState(() {
                  _searchDelay?.cancel();
                  _search.clear();
                  _branch = _path = _author = null;
                  _dates = null;
                  _loadHistory();
                }),
              ),
            ],
          ),
        ),
      const Divider(height: 1),
      Expanded(child: _historyRows(status)),
    ],
  );

  Widget _filter(
    IconData icon,
    String label,
    bool active,
    VoidCallback onTap,
  ) => TextButton(
    style: _toolbarStyle(active),
    onPressed: onTap,
    child: _filterLabel(icon, label),
  );

  ButtonStyle _toolbarStyle(bool selected) => TextButton.styleFrom(
    foregroundColor: AppColors.textPrimary,
    backgroundColor: Islands.segmentFill(selected: selected, hovered: false),
    padding: const EdgeInsets.symmetric(horizontal: 8),
    minimumSize: const Size(0, 26),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(Islands.rowRadius),
    ),
    textStyle: Theme.of(context).textTheme.labelLarge
        ?.copyWith(fontSize: 12, fontWeight: FontWeight.w500),
  );

  Widget _filterLabel(
    IconData icon,
    String label, {
    bool active = false,
    bool dropdown = false,
  }) => Padding(
    padding: EdgeInsets.symmetric(horizontal: dropdown ? 8 : 0, vertical: 5),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 14,
          color: active ? AppColors.accent : themeColors['icon.foreground'],
        ),
        const SizedBox(width: 4),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 105),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12),
          ),
        ),
        if (dropdown) ...[
          const SizedBox(width: 3),
          const Icon(Codicons.chevronDown, size: 12),
        ],
      ],
    ),
  );

  Future<void> _filterPathOrAuthor({required bool path}) async {
    final value = await _prompt(
      path ? _text('Path', '路径') : _text('Author', '作者'),
      initial: (path ? _path : _author) ?? '',
    );
    if (!mounted || value == null) return;
    setState(() {
      if (path) {
        _path = value.isEmpty ? null : value;
      } else {
        _author = value.isEmpty ? null : value;
      }
      _loadHistory();
    });
  }

  Future<void> _filterDate() async {
    final dates = await showDateRangePicker(
      context: context,
      firstDate: DateTime(1970),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      initialDateRange: _dates,
    );
    if (!mounted || dates == null) return;
    setState(() {
      _dates = dates;
      _loadHistory();
    });
  }

  Widget _historyRows(RemoteGitStatus status) => FutureBuilder(
    future: _history,
    builder: (context, snapshot) {
      final history = snapshot.data;
      final commits = [
        ..._olderCommits,
        if (snapshot.connectionState == ConnectionState.done && history != null)
          ...history.commits,
      ];
      final rows = ideGraphRows([
        for (final commit in commits)
          IdeGitCommit(
            id: commit.hash,
            parentIds: commit.parentIds,
            subject: commit.subject,
            message: commit.subject,
            author: commit.authorName,
            authorEmail: '',
            date: commit.authorDate ?? DateTime.fromMillisecondsSinceEpoch(0),
          ),
      ], headRevision: status.head);
      final graphWidth = rows
          .fold(24.0, (width, row) => math.max(width, ideGraphWidth(row)))
          .clamp(24.0, 72.0)
          .toDouble();
      return ListView.builder(
        itemCount: rows.length + 2,
        itemBuilder: (context, index) {
          if (index == 0) {
            return _row(
              label: _text('Working tree changes', '本地更改'),
              leading: const Icon(Icons.edit_outlined, size: 15),
              selected: _commit == null,
              onTap: () => _selectCommit(null),
            );
          }
          if (index > rows.length) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const LinearProgressIndicator(minHeight: 2);
            }
            if (snapshot.hasError) {
              return _notice(_text('Could not load history', '无法加载提交历史'));
            }
            if (history == null) {
              return _notice(_text('History is unavailable', '提交历史不可用'));
            }
            if (history.nextOffset case final offset?) {
              return TextButton(
                onPressed: () => setState(() {
                  _olderCommits.addAll(history.commits);
                  _loadHistory(offset: offset);
                }),
                child: Text(_text('Load more', '加载更多')),
              );
            }
            if (history.truncated) {
              return _notice(_text('Showing recent commits', '仅显示近期提交'));
            }
            return rows.isEmpty
                ? _notice(_text('No commits', '没有提交记录'))
                : const SizedBox.shrink();
          }
          final row = rows[index - 1];
          final commit = commits[index - 1];
          final date = commit.authorDate?.toLocal();
          final when = date == null
              ? ''
              : MaterialLocalizations.of(context).formatShortDate(date);
          final selected = _commit?.hash == commit.hash;
          void select() => _selectCommit(commit);
          return IdeGitKeyboardAction(
            key: ValueKey(commit.hash),
            onActivate: select,
            child: IdeListRow(
              height: ideGitHistoryRowHeight,
              builder: (context, hovered) => Row(
                children: [
                  IdeGitHistoryGraph(
                    row: row,
                    width: graphWidth,
                    background: IdeGitHistoryGraph.rowBackground(
                      background: AppColors.code,
                      selected: selected,
                      focused: false,
                      hovered: hovered,
                    ),
                    hovered: hovered,
                  ),
                  Expanded(
                    flex: 3,
                    child: Text(
                      commit.subject,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: row.kind == IdeGraphRowKind.head
                            ? FontWeight.w600
                            : null,
                        color: IdeListColors.foreground,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      commit.authorName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: IdeListColors.description,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
              ),
              tooltip: [
                commit.subject,
                commit.shortHash,
                commit.authorName,
                when,
                ...commit.refs,
              ].where((value) => value.isNotEmpty).join(' · '),
              selected: selected,
              onTap: select,
            ),
          );
        },
      );
    },
  );

  Widget _details(
    RemoteGitStatus status, {
    required bool beside,
    required bool folded,
  }) => LayoutBuilder(
    builder: (context, constraints) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_commit case final commit?)
          Row(
            children: [
              Expanded(child: _back(commit.subject, () => _selectCommit(null))),
              if (!beside)
                _icon(
                  folded
                      ? _text('Expand details', '展开')
                      : _text('Fold details', '折叠'),
                  folded ? Icons.expand_more : Icons.expand_less,
                  () => setState(() => _folded = !_folded),
                ),
            ],
          )
        else
          IdeGitCommitTabs(
            stashSelected: _stashTab,
            folded: folded,
            onToggleFold: beside
                ? null
                : () => setState(() => _folded = !_folded),
            onSelect: (stash) => setState(() {
              _stashTab = stash;
              _folded = false;
              if (stash) _stashes ??= _client.stashes(_project);
            }),
          ),
        if (!folded && constraints.maxHeight > 72) ...[
          const Divider(height: 1),
          Expanded(
            child: _commit != null
                ? _commitDetails(_commit!)
                : _stashTab
                ? _stashDetails(status)
                : _workspace(status),
          ),
        ],
      ],
    ),
  );

  Widget _commitDetails(RemoteGitCommit commit) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _notice(
        [commit.shortHash, commit.authorName, ...commit.refs].join(' · '),
      ),
      Expanded(child: _detailFiles(_commitFiles!, commit: commit)),
    ],
  );

  Widget _detailFiles(
    Future<RemoteGitCommitFiles?> files, {
    RemoteGitCommit? commit,
    RemoteGitStash? stash,
  }) => FutureBuilder(
    key: ObjectKey(files),
    future: files,
    builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.waiting) {
        return const Center(child: CircularProgressIndicator());
      }
      final result = snapshot.data;
      return result == null
          ? _notice(_text('Could not load changed files', '无法加载变更文件'))
          : _files(
              result.files,
              result.truncated,
              commit: commit,
              stash: stash,
            );
    },
  );

  Widget _workspace(RemoteGitStatus status) {
    final expected = _expected;
    final selectable = status.files.where(
      (file) => file.group != 'merge' && _checked.contains(file.path),
    );
    final selected = <String, RemoteGitFile>{
      for (final file in selectable) file.path: file,
    }.values.toList();
    final commitEnabled =
        expected != null &&
        selected.isNotEmpty &&
        !status.files.any((f) => f.group == 'merge');
    return LayoutBuilder(
      builder: (context, limits) {
        final showForm = limits.maxHeight >= 130;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (_capabilities?.canWrite == true)
                  _icon(
                    _text('Toggle all files', '全选或取消全选'),
                    Icons.checklist,
                    () => setState(() {
                      if (selected.isNotEmpty) {
                        _checked.clear();
                      } else {
                        _checked.addAll(
                          status.files
                              .where((f) => f.group != 'merge')
                              .map((f) => f.path),
                        );
                      }
                    }),
                  ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      status.branch ?? _text('Detached HEAD', '分离的 HEAD'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
                IdeGitListTreeSwitch(
                  tree: _tree,
                  labels: false,
                  onChanged: (tree) => setState(() => _tree = tree),
                ),
                const SizedBox(width: 8),
              ],
            ),
            Expanded(
              child: _files(status.files, status.truncated, working: true),
            ),
            if (showForm && _capabilities?.canWrite == true)
              IdeGitCommitForm(
                message: IdeInputBox(
                  controller: _message,
                  maxLines: 2,
                  placeholder: _text('Commit message', '提交信息'),
                  radius: Islands.controlRadius,
                ),
                actions: ValueListenableBuilder(
                  valueListenable: _message,
                  builder: (context, value, _) {
                    final enabled =
                        commitEnabled && value.text.trim().isNotEmpty;
                    return IdeGitCommitActions(
                      onCommit: enabled
                          ? () => _submit(expected, selected, push: false)
                          : null,
                      onPush: enabled && _capabilities?.canPush == true
                          ? () => _submit(expected, selected, push: true)
                          : null,
                    );
                  },
                ),
              ),
          ],
        );
      },
    );
  }

  Future<void> _submit(
    String expected,
    List<RemoteGitFile> files, {
    required bool push,
  }) async {
    final text = _message.text;
    if (push &&
        !await _confirm(
          _text(
            'Commit selected files and push the current branch from the host?',
            '提交选中的文件并从主机推送当前分支？',
          ),
        )) {
      return;
    }
    if (!mounted || _expected != expected) return;
    await _write(() async {
      final result = await _client.commit(
        _project,
        expectedState: expected,
        message: text,
        files: files,
        push: push,
      );
      if (result == null) return false;
      if (!mounted) return true;
      if (_message.text == text) _message.clear();
      if (push && !result.pushed) {
        _operationError =
            '${_text('Commit succeeded, but push failed', '提交成功，但推送失败')}：${result.pushError ?? ''}';
      }
      return true;
    });
  }

  Widget _stashDetails(RemoteGitStatus status) {
    if (_stash case final stash?) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _back(stash.message, () => setState(() => _stash = null)),
          Expanded(child: _detailFiles(_stashFiles!, stash: stash)),
        ],
      );
    }
    final expected = _expected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_capabilities?.canWrite == true)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: expected == null || status.files.isEmpty
                  ? null
                  : () => _createStash(expected),
              icon: const Icon(Icons.add, size: 15),
              label: Text(_text('Create stash', '创建 Stash')),
            ),
          ),
        Expanded(
          child: FutureBuilder(
            future: _stashes,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              final result = snapshot.data;
              if (snapshot.hasError) {
                return _notice(_text('Could not load stashes', '无法加载 Stash'));
              }
              if (result == null) {
                return _notice(
                  _text('Stash is unavailable on this host', '此主机不支持 Stash'),
                );
              }
              if (result.entries.isEmpty) {
                return _notice(_text('No stashes', '没有 Stash'));
              }
              return ListView(
                children: [
                  for (final stash in result.entries)
                    IdeGitStashRow(
                      key: ValueKey(stash.id),
                      message: stash.message,
                      tooltip: stash.message,
                      description: stash.date == null
                          ? null
                          : ideFromNow(
                              stash.date!,
                              ago: true,
                              l10n: context.l10n,
                            ),
                      onTap: () => setState(() {
                        _stash = stash;
                        _stashFiles = _client.stashFiles(_project, stash.id);
                      }),
                      actions: expected == null
                          ? null
                          : PopupMenuButton<_StashAction>(
                              tooltip: _text('Stash actions', 'Stash 操作'),
                              padding: EdgeInsets.zero,
                              iconSize: 15,
                              onSelected: (action) =>
                                  _changeStash(action, stash, expected),
                              itemBuilder: (_) => [
                                PopupMenuItem(
                                  value: _StashAction.apply,
                                  child: Text(_text('Apply', '应用')),
                                ),
                                PopupMenuItem(
                                  value: _StashAction.pop,
                                  child: Text(_text('Pop', '弹出')),
                                ),
                                PopupMenuItem(
                                  value: _StashAction.drop,
                                  child: Text(_text('Drop', '删除')),
                                ),
                              ],
                            ),
                    ),
                  if (result.truncated)
                    _notice(_text('Stash list truncated', 'Stash 列表已截断')),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _createStash(String expected) async {
    var include = false;
    var message = '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(_text('Create stash', '创建 Stash')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                onChanged: (value) => message = value,
                decoration: InputDecoration(
                  hintText: _text('Optional message', '说明（可选）'),
                ),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: include,
                onChanged: (value) => setDialogState(() => include = value!),
                title: Text(_text('Include untracked files', '包括未跟踪文件')),
              ),
            ],
          ),
          actions: _dialogActions(context),
        ),
      ),
    );
    if (!mounted || confirmed != true || _expected != expected) return;
    await _write(
      () async =>
          await _client.createStash(
            _project,
            expectedState: expected,
            message: message.trim().isEmpty ? null : message.trim(),
            includeUntracked: include,
          ) !=
          null,
    );
  }

  Future<void> _changeStash(
    _StashAction action,
    RemoteGitStash stash,
    String expected,
  ) async {
    if (action == _StashAction.drop &&
        !await _confirm(
          _text('Permanently delete this stash?', '永久删除这条 Stash？'),
        )) {
      return;
    }
    if (!mounted || _expected != expected) return;
    await _write(
      () async =>
          (await switch (action) {
            _StashAction.apply => _client.applyStash(
              _project,
              stash.id,
              expectedState: expected,
            ),
            _StashAction.pop => _client.popStash(
              _project,
              stash.id,
              expectedState: expected,
            ),
            _StashAction.drop => _client.dropStash(
              _project,
              stash.id,
              expectedState: expected,
            ),
          }) !=
          null,
    );
  }

  Widget _files(
    List<RemoteGitFile> files,
    bool truncated, {
    bool working = false,
    RemoteGitCommit? commit,
    RemoteGitStash? stash,
  }) {
    if (files.isEmpty) return _notice(_text('No Git changes', '没有 Git 变更'));
    Widget fileRow(RemoteGitFile file, {int depth = 0}) {
      final group = switch (file.group) {
        'index' => _text('Staged', '已暂存'),
        'untracked' => _text('Untracked', '未跟踪'),
        'merge' => _text('Conflict', '冲突'),
        'workingTree' => _text('Working tree', '工作区'),
        _ => file.originalPath ?? '',
      };
      final expected = _expected;
      final directory = p.posix.dirname(file.path);
      final tree = _tree && working;
      final status = switch ((file.group, file.status)) {
        ('untracked', _) => IdeGitStatus.untracked,
        ('merge', _) => IdeGitStatus.bothModified,
        ('workingTree', 'M') => IdeGitStatus.modified,
        ('workingTree', 'D') => IdeGitStatus.deleted,
        _ => ideCommitChangeStatus(file.status),
      };
      return _row(
        label: file.path,
        depth: depth,
        content: IdeGitFileLabel(
          icon: FileIcon(file.path),
          name: p.posix.basename(file.path),
          description: tree || directory == '.' ? null : directory,
          status: file.status,
          statusColor: status.color,
          strikeThrough: status.strikeThrough,
        ),
        selected:
            _diff != null && _diffPath == file.path && _diffGroup == file.group,
        tooltip: [
          file.path,
          group,
        ].where((value) => value.isNotEmpty).join(' · '),
        leading:
            working && _capabilities?.canWrite == true && file.group != 'merge'
            ? SizedBox(
                width: 26,
                child: Checkbox(
                  visualDensity: VisualDensity.compact,
                  semanticLabel: file.path,
                  value: _checked.contains(file.path),
                  onChanged: (value) => setState(
                    () => value!
                        ? _checked.add(file.path)
                        : _checked.remove(file.path),
                  ),
                ),
              )
            : null,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (group.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 100),
                child: Text(
                  group,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10),
                ),
              ),
            if (group.isNotEmpty) const SizedBox(width: 5),
            if (working && expected != null && file.group != 'merge')
              _icon(
                file.group == 'index'
                    ? _text('Unstage', '取消暂存')
                    : _text('Stage', '暂存'),
                file.group == 'index' ? Icons.remove : Icons.add,
                () => _write(
                  () async =>
                      (await (file.group == 'index'
                          ? _client.unstage(_project, [
                              file,
                            ], expectedState: expected)
                          : _client.stage(_project, [
                              file,
                            ], expectedState: expected))) !=
                      null,
                ),
                size: 25,
              ),
          ],
        ),
        onTap: () => _openFile(file, commit: commit, stash: stash),
      );
    }

    Iterable<Widget> tree() sync* {
      const root = '/';
      for (final group in files.map((file) => file.group).toSet()) {
        final entries = {
          for (final file in files.where((file) => file.group == group))
            '/${file.path}': file,
        };
        Iterable<Widget> nodesAt(List<IdeScmTreeNode> nodes, int depth) sync* {
          for (final node in nodes) {
            switch (node) {
              case IdeScmTreeFolder():
                yield IdeListRow(
                  builder: (context, _) => Padding(
                    padding: EdgeInsetsDirectional.only(
                      start: 4 + math.min(depth, 6) * 12,
                    ),
                    child: IdeGitFileLabel(
                      icon: FolderIcon(node.path, expanded: true),
                      name: node.label,
                    ),
                  ),
                );
                yield* nodesAt(node.children, depth + 1);
              case IdeScmTreeFile():
                yield fileRow(entries[node.resource.path]!, depth: depth);
            }
          }
        }

        yield* nodesAt(
          ideScmTree(root, [
            for (final path in entries.keys)
              IdeGitResource(
                path: path,
                status: IdeGitStatus.modified,
                group: IdeGitGroup.workingTree,
              ),
          ], paths: p.posix),
          0,
        );
      }
    }

    return ListView(
      children: [
        if (_tree && working)
          ...tree()
        else
          for (final file in files) fileRow(file),
        if (truncated) _notice(_text('File list truncated', '文件列表已截断')),
      ],
    );
  }

  Widget _diffView() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _back(
        _diffPath!,
        () => setState(() => _diff = null),
        tooltip: _text('Back from diff', '返回变更'),
      ),
      Expanded(
        child: FutureBuilder(
          key: ObjectKey(_diff),
          future: _diff,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            final diff = snapshot.data;
            if (diff == null) {
              return _notice(_text('Could not load Git diff', '无法加载 Git 差异'));
            }
            return IdeGitPatchReader(
              patch: diff.text,
              emptyLabel: _text('No textual diff', '没有文本差异'),
              truncationLabel: diff.truncated
                  ? _text('Diff truncated', '差异已截断')
                  : null,
            );
          },
        ),
      ),
    ],
  );

  Widget _row({
    required String label,
    required VoidCallback onTap,
    Widget? leading,
    Widget? trailing,
    Widget? content,
    String? tooltip,
    bool selected = false,
    int depth = 0,
  }) => IdeGitKeyboardAction(
    onActivate: onTap,
    child: IdeListRow(
      tooltip: tooltip ?? label,
      selected: selected,
      onTap: onTap,
      height: ideGitHistoryRowHeight,
      builder: (context, hovered) => Padding(
        padding: EdgeInsetsDirectional.only(
          start: 4 + math.min(depth, 6) * 12,
          end: 4,
        ),
        child: Row(
          children: [
            if (leading != null) ...[leading, const SizedBox(width: 6)],
            Expanded(child: content ?? IdeResourceLabel(name: label)),
            if (trailing != null) ...[const SizedBox(width: 6), trailing],
          ],
        ),
      ),
    ),
  );

  Widget _icon(
    String label,
    IconData icon,
    VoidCallback? onTap, {
    double size = 34,
  }) => IconButton(
    tooltip: label,
    constraints: BoxConstraints.tightFor(width: size, height: size),
    padding: EdgeInsets.zero,
    icon: Icon(icon, size: 16),
    onPressed: onTap,
  );

  Widget _back(String label, VoidCallback onPressed, {String? tooltip}) => Row(
    children: [
      _icon(tooltip ?? _text('Back', '返回'), Icons.arrow_back, onPressed),
      Expanded(
        child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    ],
  );

  Widget _notice(String text) =>
      Padding(padding: const EdgeInsets.all(8), child: Text(text));

  Future<String?> _prompt(String label, {required String initial}) {
    var text = initial;
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(label),
        content: TextFormField(
          initialValue: initial,
          autofocus: true,
          onChanged: (value) => text = value,
          onFieldSubmitted: (value) => Navigator.pop(context, value.trim()),
        ),
        actions: _dialogActions(context, result: () => text.trim()),
      ),
    );
  }

  Future<bool> _confirm(String question) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          content: Text(question),
          actions: _dialogActions(context),
        ),
      ) ==
      true;

  List<Widget> _dialogActions(
    BuildContext context, {
    Object Function()? result,
  }) => [
    TextButton(
      onPressed: () => Navigator.pop(context),
      child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
    ),
    FilledButton(
      onPressed: () => Navigator.pop(context, result?.call() ?? true),
      child: Text(MaterialLocalizations.of(context).okButtonLabel),
    ),
  ];
}

enum _StashAction { apply, pop, drop }
