import 'package:flutter/material.dart';

import '../ide/git/git_graph_painter.dart';
import '../ide/git/git_model.dart';
import '../theme/app_theme.dart' show AppColors;
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

enum _Page { workspace, history, review }

class _DesktopRemoteGitViewState extends State<DesktopRemoteGitView> {
  late var _repository = _loadRepository();
  _Page _page = _Page.workspace;
  RemoteGitCommit? _commit;
  Future<RemoteGitCommitFiles?>? _commitFiles;
  String? _diffPath;
  Future<RemoteGitDiff?>? _diff;

  Future<(RemoteGitStatus?, RemoteGitHistory?)> _loadRepository() async {
    final status = await widget.client.status(widget.project);
    if (status == null) return (null, null);
    RemoteGitHistory? history;
    try {
      history = await widget.client.history(widget.project);
    } on Object {
      // History is optional: keep the working-tree status usable on hosts
      // where the history request fails independently.
    }
    return (status, history);
  }

  bool get _zh => Localizations.localeOf(context).languageCode == 'zh';
  String _text(String en, String zh) => _zh ? zh : en;

  void _refresh() => setState(() {
    _repository = _loadRepository();
    _commit = null;
    _commitFiles = null;
    _diff = null;
  });

  void _openFile(RemoteGitFile file, {RemoteGitCommit? commit}) => setState(() {
    _diffPath = file.path;
    _diff = commit == null
        ? widget.client.workingDiff(
            widget.project,
            file.path,
            staged: file.group == 'index',
          )
        : widget.client.commitDiff(widget.project, commit.hash, file.path);
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _repository,
      builder: (context, snapshot) {
        final (status, history) = snapshot.data ?? (null, null);
        if (status == null) {
          return Column(
            children: [
              if (snapshot.connectionState == ConnectionState.waiting)
                const LinearProgressIndicator(minHeight: 2),
              if (snapshot.hasError)
                Row(
                  children: [
                    Expanded(
                      child: Text(_text('Could not load Git', '无法加载 Git')),
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
        return LayoutBuilder(
          builder: (context, constraints) {
            final split = constraints.maxWidth >= 600;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _tab(
                      _Page.workspace,
                      split ? 'Git' : _text('Workspace', '工作区'),
                      active: split && _page == _Page.history,
                    ),
                    if (!split) _tab(_Page.history, _text('History', '历史')),
                    _tab(_Page.review, _text('Session changes', '会话改动')),
                    IconButton(
                      tooltip: _text('Refresh Git', '刷新 Git'),
                      icon: const Icon(Icons.refresh, size: 17),
                      onPressed:
                          snapshot.connectionState == ConnectionState.waiting
                          ? null
                          : _refresh,
                    ),
                  ],
                ),
                if (snapshot.connectionState == ConnectionState.waiting)
                  const LinearProgressIndicator(minHeight: 2),
                if (snapshot.hasError)
                  Text(_text('Could not refresh Git', '无法刷新 Git')),
                const Divider(height: 1),
                Expanded(
                  child: _page == _Page.review
                      ? widget.review
                      : _diff != null
                      ? _diffView()
                      : split
                      ? Row(
                          children: [
                            Expanded(child: _history(status, history)),
                            const VerticalDivider(width: 1),
                            Expanded(child: _workspace(status)),
                          ],
                        )
                      : _page == _Page.history
                      ? _history(status, history)
                      : _workspace(status),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _tab(_Page page, String label, {bool active = false}) => TextButton(
    style: active || _page == page
        ? TextButton.styleFrom(backgroundColor: AppColors.partBorder)
        : null,
    onPressed: () => setState(() {
      _page = page;
      _diff = null;
    }),
    child: Text(label),
  );

  Widget _workspace(RemoteGitStatus status) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (status.branch case final branch?)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(branch, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      Expanded(child: _files(status.files, status.truncated)),
    ],
  );

  Widget _history(RemoteGitStatus status, RemoteGitHistory? history) {
    if (_commitFiles case final files?) {
      final commit = _commit!;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _back(
            commit.subject,
            () => setState(() {
              _commit = null;
              _commitFiles = null;
            }),
          ),
          Expanded(
            child: FutureBuilder(
              future: files,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                final result = snapshot.data;
                return result == null
                    ? _notice(_text('Could not load commit files', '无法加载提交文件'))
                    : _files(result.files, result.truncated, commit: commit);
              },
            ),
          ),
        ],
      );
    }
    if (history == null || history.commits.isEmpty) {
      return _notice(_text('No commit history', '没有提交历史'));
    }
    final rows = ideGraphRows([
      for (final commit in history.commits)
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
    return ListView.builder(
      itemCount: rows.length + (history.truncated ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == rows.length) {
          return _notice(_text('Showing recent commits', '仅显示近期提交'));
        }
        final row = rows[index];
        final commit = history.commits[index];
        return ListTile(
          dense: true,
          leading: CustomPaint(
            size: Size(ideGraphWidth(row).clamp(11.0, 72.0), 44),
            painter: IdeGraphPainter(
              row,
              background: AppColors.background,
              height: 44,
            ),
          ),
          title: Text(
            commit.subject,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            [commit.shortHash, commit.authorName, ...commit.refs].join('  ·  '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => setState(() {
            _commit = commit;
            _commitFiles = widget.client.commitFiles(
              widget.project,
              commit.hash,
            );
          }),
        );
      },
    );
  }

  Widget _files(
    List<RemoteGitFile> files,
    bool truncated, {
    RemoteGitCommit? commit,
  }) {
    if (files.isEmpty) return _notice(_text('No Git changes', '没有 Git 变更'));
    return ListView.builder(
      itemCount: files.length + (truncated ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == files.length) {
          return _notice(_text('File list truncated', '文件列表已截断'));
        }
        final file = files[index];
        return ListTile(
          dense: true,
          leading: Text(file.status),
          title: Text(file.path, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            switch (file.group) {
              'index' => _text('Staged', '已暂存'),
              'untracked' => _text('Untracked', '未跟踪'),
              'merge' => _text('Conflict', '冲突'),
              'workingTree' => _text('Working tree', '工作区'),
              _ => file.originalPath ?? '',
            },
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => _openFile(file, commit: commit),
        );
      },
    );
  }

  Widget _diffView() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _back(_diffPath!, () => setState(() => _diff = null)),
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
            if (diff.text.isEmpty && !diff.truncated) {
              return _notice(_text('No textual diff', '没有文本差异'));
            }
            return SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: SelectableText(
                diff.truncated
                    ? '${diff.text}\n${_text('Diff truncated', '差异已截断')}'
                    : diff.text,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            );
          },
        ),
      ),
    ],
  );

  Widget _back(String label, VoidCallback onPressed) => Row(
    children: [
      IconButton(
        tooltip: _text('Back', '返回'),
        onPressed: onPressed,
        icon: const Icon(Icons.arrow_back, size: 17),
      ),
      Expanded(
        child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    ],
  );

  Widget _notice(String text) =>
      Padding(padding: const EdgeInsets.all(12), child: Text(text));
}
