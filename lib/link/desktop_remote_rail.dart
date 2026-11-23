import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:bao_link/bao_link.dart';
import 'package:flutter/material.dart';

import '../ide/ide_list.dart';
import '../ide/ide_panes.dart' show IdePaneAction, IdeViewTitle;
import '../l10n/l10n.dart';
import '../sidebar/sidebar.dart' show SidebarIconButton;
import '../theme/app_theme.dart' show AppColors;
import '../theme/codicons.dart';
import '../theme/material_file_icons.dart' show FileIcon, FolderIcon;
import '../workspace/window_controls.dart';
import 'desktop_host_chats.dart';
import 'desktop_remote_media.dart';
import 'desktop_remote_media_preview.dart';

/// Docks a host explorer alongside a bounded conversation pane.
class DesktopRemoteRail extends StatefulWidget {
  const DesktopRemoteRail({
    super.key,
    required this.peer,
    required this.chat,
    required this.child,
    this.isCurrent,
  });

  final LinkPeer peer;
  final DesktopHostChat chat;
  final Widget child;
  final bool Function()? isCurrent;

  @override
  State<DesktopRemoteRail> createState() => _DesktopRemoteRailState();
}

class _DesktopRemoteRailState extends State<DesktopRemoteRail> {
  bool _open = false;
  final _expanded = <String>{};
  final _folders = <String, _Folder>{};
  _LegacyTree? _legacy;
  (String, Future<_FilePreview>)? _preview;
  bool _downloading = false;
  String? _downloadStatus;
  StreamSubscription<LinkEvent>? _connection;

  String? get _project => switch (widget.chat) {
    DesktopHostChat(kind: 'project', projectId: final id?) when id.isNotEmpty =>
      id,
    _ => null,
  };

  bool get _connected =>
      !widget.peer.isClosed && (widget.isCurrent?.call() ?? true);

  @override
  void initState() {
    super.initState();
    _watchPeer();
  }

  @override
  void didUpdateWidget(DesktopRemoteRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget.chat;
    final chat = widget.chat;
    if (oldWidget.peer != widget.peer) {
      unawaited(_connection?.cancel());
      _watchPeer();
    }
    if (oldWidget.peer != widget.peer ||
        (old.kind, old.id, old.projectId) !=
            (chat.kind, chat.id, chat.projectId)) {
      _reset();
    }
  }

  void _watchPeer() {
    final peer = widget.peer;
    _connection = peer.events.listen(
      null,
      onDone: () {
        if (mounted && identical(widget.peer, peer)) setState(_reset);
      },
    );
  }

  @override
  void dispose() {
    unawaited(_connection?.cancel());
    super.dispose();
  }

  void _reset() {
    _open = false;
    _clearFiles();
  }

  void _clearFiles() {
    _folders.clear();
    _legacy = null;
    _expanded.clear();
    _preview = null;
    _downloading = false;
    _downloadStatus = null;
  }

  void _toggle() => setState(() {
    if (_open) {
      _reset();
    } else {
      _open = true;
      _load('');
    }
  });

  void _refresh() => setState(() {
    _clearFiles();
    _load('');
  });

  void _load(String path) => unawaited(_fetchFolder(path));

  Future<void> _fetchFolder(String path) async {
    if (!_connected) return;
    if (_folders[path] case final folder? when !folder.failed) return;
    final request = _folders[path] = _Folder();
    final peer = widget.peer;
    final project = _project!;
    bool current() =>
        mounted && _connected && identical(_folders[path], request);
    try {
      List<_Entry> entries;
      var legacy = _legacy;
      if (legacy != null) {
        entries = legacy.folders[path] ?? const [];
      } else {
        try {
          entries = await _loadFolder(peer, project, path);
        } on LinkRemoteException catch (error) {
          // Older hosts only expose their filtered project file index.
          if (path.isNotEmpty ||
              error.code != LinkErrors.unknown ||
              !current()) {
            rethrow;
          }
          legacy = await _loadLegacyTree(peer, project);
          entries = legacy.folders[''] ?? const [];
        }
      }
      if (current()) {
        setState(() {
          _legacy = legacy;
          request.entries = entries;
        });
      }
    } on Object {
      if (current()) setState(() => request.failed = true);
    }
  }

  void _toggleFolder(String path) => setState(() {
    if (!_expanded.remove(path)) {
      _expanded.add(path);
      _load(path);
    }
  });

  void _read(String path) => setState(() {
    if (!_connected) return;
    final peer = widget.peer;
    final project = _project!;
    late final Future<_FilePreview> result;
    result = remoteImageType(path) == null
        ? _readFile(peer, project, path)
        : previewRemoteFileImage(
            peer,
            project,
            path,
            isCurrent: () =>
                mounted && _connected && identical(_preview?.$2, result),
          ).then((bytes) => _FilePreview(image: bytes));
    // The host can fail before the next frame attaches the FutureBuilder.
    result.ignore();
    _preview = (path, result);
    _downloading = false;
    _downloadStatus = null;
  });

  Future<void> _download() async {
    final preview = _preview;
    final project = _project;
    final peer = widget.peer;
    if (preview == null || project == null || _downloading || !_connected) {
      return;
    }
    final l10n = context.l10n;
    bool current() => mounted && _connected && identical(_preview, preview);
    setState(() {
      _downloading = true;
      _downloadStatus = null;
    });
    try {
      final saved = await downloadRemoteFile(
        peer: peer,
        project: project,
        path: preview.$1,
        isCurrent: current,
      );
      if (saved && current()) {
        _downloadStatus = l10n.localeName.startsWith('zh')
            ? '已保存文件。'
            : 'File saved.';
      }
    } on Object catch (error) {
      if (current()) _downloadStatus = remoteMediaError(l10n, error);
    } finally {
      if (current()) setState(() => _downloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final connectedProject = _project != null && _connected;
    final l10n = context.l10n;
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedWidth || !constraints.hasBoundedHeight) {
          return widget.child;
        }
        final wide = constraints.maxWidth >= 520;
        final available =
            connectedProject &&
            constraints.maxWidth >= 245 &&
            constraints.maxHeight >= (wide ? 150 : 340);
        final explorer = available && _open ? _explorer(context) : null;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: widget.child),
                  if (!wide && explorer != null)
                    SizedBox(
                      height: constraints.maxHeight * .45,
                      child: explorer,
                    ),
                ],
              ),
            ),
            if (wide && explorer != null)
              SizedBox(
                width: math.min(400, constraints.maxWidth * .37),
                child: explorer,
              ),
            if (available)
              SizedBox(
                width: 40,
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Container(
                    margin: const EdgeInsets.only(top: 8),
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      border: Border.all(color: AppColors.partBorder),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: SidebarIconButton(
                      key: const ValueKey('desktop-remote-files-toggle'),
                      icon: Codicons.files,
                      tooltip: _open ? l10n.sidePanelHide : l10n.sidePanelFiles,
                      size: 26,
                      onTap: _toggle,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _explorer(BuildContext context) {
    final l10n = context.l10n;
    final preview = _preview;
    final rows = [
      if (_legacy?.truncated == true)
        (
          0,
          l10n.localeName.startsWith('zh')
              ? '主机仅返回了部分文件。'
              : 'The host returned a partial file list.',
        ),
      ..._rows('', 0, l10n),
    ];
    return DecoratedBox(
      key: const ValueKey('desktop-remote-explorer'),
      decoration: BoxDecoration(
        color: AppColors.code,
        border: Border.all(color: AppColors.partBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            IdeViewTitle(
              l10n.wbExplorer,
              border: AppColors.partBorder,
              actions: [
                IdePaneAction(
                  icon: Codicons.refresh,
                  tooltip: l10n.cmdRefreshExplorer,
                  onPressed: _refresh,
                ),
                IdePaneAction(
                  icon: Codicons.collapseAll,
                  tooltip: l10n.cmdCollapseExplorerFolders,
                  onPressed: () => setState(_expanded.clear),
                ),
              ],
            ),
            Expanded(
              flex: preview == null ? 1 : 2,
              child: ListView.builder(
                primary: false,
                padding: const EdgeInsets.symmetric(vertical: 3),
                itemCount: rows.length,
                itemBuilder: (context, index) {
                  final (depth, value) = rows[index];
                  return value is _Entry
                      ? _row(value, depth)
                      : _Notice(value as String, depth: depth);
                },
              ),
            ),
            if (preview != null)
              Expanded(
                flex: 3,
                child: _FilePreviewPane(
                  key: ValueKey(preview),
                  path: preview.$1,
                  result: preview.$2,
                  downloading: _downloading,
                  status: _downloadStatus,
                  onDownload: WindowControls.canPickFiles ? _download : null,
                  onClose: () => setState(() {
                    _preview = null;
                    _downloadStatus = null;
                    _downloading = false;
                  }),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Iterable<(int, Object)> _rows(
    String path,
    int depth,
    AppLocalizations l10n,
  ) sync* {
    final folder = _folders[path];
    final entries = folder?.entries;
    if (folder?.failed == true) {
      yield (
        depth,
        l10n.explorerCannotReadFolder(path.isEmpty ? l10n.wbExplorer : path),
      );
    } else if (entries == null) {
      yield (depth, l10n.quickOpenLoadingFiles);
    } else if (entries.isEmpty) {
      yield (depth, l10n.remoteBrowserEmpty);
    } else {
      for (final entry in entries) {
        yield (depth, entry);
        if (entry.directory && _expanded.contains(entry.path)) {
          yield* _rows(entry.path, depth + 1, l10n);
        }
      }
    }
  }

  Widget _row(_Entry entry, int depth) {
    final expanded = _expanded.contains(entry.path);
    final selected = _preview?.$1 == entry.path;
    return IdeListRow(
      key: ValueKey(entry.path),
      selected: selected,
      tooltip: entry.path,
      height: math.max(
        IdeListColors.rowHeight,
        MediaQuery.textScalerOf(context).scale(13) * 1.45,
      ),
      onTap: () =>
          entry.directory ? _toggleFolder(entry.path) : _read(entry.path),
      builder: (context, hovered) => Padding(
        padding: EdgeInsets.only(
          left: 4 + math.min(depth, 8) * IdeListColors.indent,
          right: 6,
        ),
        child: Row(
          children: [
            SizedBox(
              width: 16,
              child: entry.directory
                  ? Icon(
                      expanded ? Codicons.chevronDown : Codicons.chevronRight,
                      size: 14,
                    )
                  : null,
            ),
            if (entry.directory)
              FolderIcon(entry.name, expanded: expanded)
            else
              FileIcon(entry.name),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                entry.name,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 13,
                  color: selected
                      ? IdeListColors.inactiveSelectionForeground
                      : hovered
                      ? IdeListColors.hoverForeground
                      : IdeListColors.foreground,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice(this.message, {this.depth = 0});

  final String message;
  final int depth;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
      10 + math.min(depth, 8) * IdeListColors.indent,
      6,
      10,
      6,
    ),
    child: Text(
      message,
      style: TextStyle(color: AppColors.textMuted, fontSize: 12),
    ),
  );
}

class _Entry {
  const _Entry(this.name, this.path, {required this.directory});

  final String name;
  final String path;
  final bool directory;
}

class _Folder {
  List<_Entry>? entries;
  bool failed = false;
}

// The link names paths with POSIX separators on all hosts. Only use relative
// names from the project listing, including on hosts accepting absolute reads.
int _compareEntries(_Entry a, _Entry b) {
  if (a.directory != b.directory) return a.directory ? -1 : 1;
  final order = a.name.toLowerCase().compareTo(b.name.toLowerCase());
  return order != 0 ? order : a.name.compareTo(b.name);
}

typedef _LegacyTree = ({Map<String, List<_Entry>> folders, bool truncated});

Future<_LegacyTree> _loadLegacyTree(LinkPeer peer, String project) async {
  final response = await peer.call(LinkMethods.files, {'project': project});
  if (response case {'paths': final List<Object?> paths}) {
    final folders = <String, Map<String, _Entry>>{};
    for (final path in paths.whereType<String>().take(LinkLimits.files)) {
      final names = path.split('/');
      if (!names.every(remoteFileName)) continue;
      var parent = '';
      for (final (index, name) in names.indexed) {
        final path = parent.isEmpty ? name : '$parent/$name';
        final siblings = folders.putIfAbsent(parent, () => {});
        final directory = index < names.length - 1;
        if (directory || !siblings.containsKey(name)) {
          siblings[name] = _Entry(name, path, directory: directory);
        }
        parent = path;
      }
    }
    return (
      folders: {
        for (final MapEntry(:key, :value) in folders.entries)
          key: value.values.toList()..sort(_compareEntries),
      },
      truncated:
          (response as Map)['truncated'] == true ||
          paths.length > LinkLimits.files,
    );
  }
  throw const FormatException('Invalid host file list');
}

Future<List<_Entry>> _loadFolder(
  LinkPeer peer,
  String project,
  String path,
) async {
  final response = await peer.call(LinkMethods.folder, {
    'project': project,
    'path': path,
  });
  if (response case {
    'folders': final List<Object?> folders,
    'files': final List<Object?> files,
  }) {
    final entries = <String, _Entry>{};
    for (final (names, directory) in [(folders, true), (files, false)]) {
      for (final name in names.whereType<String>().where(remoteFileName)) {
        entries.putIfAbsent(
          name,
          () => _Entry(
            name,
            path.isEmpty ? name : '$path/$name',
            directory: directory,
          ),
        );
      }
    }
    return entries.values.toList()..sort(_compareEntries);
  }
  throw const FormatException('Invalid host folder');
}

class _FilePreview {
  const _FilePreview({
    this.text,
    this.image,
    this.binary = false,
    this.tooLarge = false,
    this.size,
  });

  final String? text;
  final Uint8List? image;
  final bool binary;
  final bool tooLarge;
  final int? size;
}

Future<_FilePreview> _readFile(
  LinkPeer peer,
  String project,
  String path,
) async {
  final response = await peer.call(LinkMethods.read, {
    'project': project,
    'path': path,
  });
  return switch (response) {
    {'binary': true} => const _FilePreview(binary: true),
    {'tooLarge': true, 'size': final int size} => _FilePreview(
      tooLarge: true,
      size: size,
    ),
    {'tooLarge': true} => const _FilePreview(tooLarge: true),
    {'text': final String text} when text.length <= LinkLimits.file =>
      _FilePreview(text: text),
    {'text': final String text} => _FilePreview(
      tooLarge: true,
      size: text.length,
    ),
    _ => throw const FormatException('Invalid host file'),
  };
}

class _FilePreviewPane extends StatelessWidget {
  const _FilePreviewPane({
    super.key,
    required this.path,
    required this.result,
    required this.onClose,
    required this.downloading,
    this.status,
    this.onDownload,
  });

  final String path;
  final Future<_FilePreview> result;
  final VoidCallback onClose;
  final bool downloading;
  final String? status;
  final VoidCallback? onDownload;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Divider(height: 1, color: AppColors.partBorder),
        IdeViewTitle(
          path,
          border: AppColors.partBorder,
          actions: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 90),
              child: Text(
                l10n.shownReadOnly,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: AppColors.textMuted),
              ),
            ),
            if (onDownload != null)
              KeyedSubtree(
                key: const ValueKey('desktop-remote-download'),
                child: IdePaneAction(
                  icon: Codicons.cloudDownload,
                  tooltip: l10n.explorerDownload,
                  onPressed: downloading ? () {} : onDownload!,
                ),
              ),
            IdePaneAction(
              icon: Codicons.close,
              tooltip: l10n.sidePanelCloseTab,
              onPressed: onClose,
            ),
          ],
        ),
        if (status case final message?) _Notice(message),
        Expanded(
          child: FutureBuilder(
            future: result,
            builder: (context, snapshot) {
              final Widget content = switch (snapshot) {
                AsyncSnapshot(connectionState: ConnectionState.waiting) =>
                  _Notice(l10n.langLoading),
                AsyncSnapshot(
                  error: LinkRemoteException(code: LinkErrors.notFound),
                ) =>
                  _Notice(l10n.placeholderNotFound),
                AsyncSnapshot(data: _FilePreview(binary: true)) => _Notice(
                  l10n.placeholderBinary,
                ),
                AsyncSnapshot(error: final RemoteMediaTooLarge error) =>
                  _Notice(remoteMediaError(l10n, error)),
                AsyncSnapshot(error: final RemoteUnsupportedImage error) =>
                  _Notice(remoteMediaError(l10n, error)),
                AsyncSnapshot(data: _FilePreview(image: final bytes?)) =>
                  SizedBox(height: 180, child: DesktopRemoteImagePixels(bytes)),
                AsyncSnapshot(
                  data: _FilePreview(tooLarge: true, :final size),
                ) =>
                  _Notice(
                    l10n.placeholderTooLarge(
                      size == null ? '${LinkLimits.file ~/ 1024} KB+' : '$size',
                    ),
                  ),
                AsyncSnapshot(data: _FilePreview(text: final text?)) => Padding(
                  padding: const EdgeInsets.all(10),
                  // Literal text only. A remote document cannot load resources
                  // or run any of the local editor's open/edit actions.
                  child: SelectableText(
                    text,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: AppColors.text,
                    ),
                  ),
                ),
                _ => _Notice(l10n.placeholderUnexpected),
              };
              return SingleChildScrollView(primary: false, child: content);
            },
          ),
        ),
      ],
    );
  }
}
