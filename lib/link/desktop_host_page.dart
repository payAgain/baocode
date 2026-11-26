import 'dart:async';

import 'package:bao_link/bao_link.dart'
    show
        LinkMethods,
        LinkPath,
        LinkPathKind,
        LinkPeer,
        LinkSessionStatus,
        ProjectInfo;

import 'package:flutter/material.dart';

import '../ide/ide_list.dart' show IdeListRow;
import '../theme/codicons.dart';
import '../chat/chat_column.dart';
import '../chat/chat_width.dart';
import '../l10n/l10n.dart';
import '../sidebar/sidebar.dart' show relativeTime;
import '../sidebar/sidebar_times.dart';
import '../chat/widgets/conversation_card_header.dart';
import '../chat/widgets/inline_rename_field.dart';
import '../chat/widgets/hover_scroll_text.dart';
import '../workspace/islands.dart';
import '../settings/pages/settings_widgets.dart' show SettingsText;
import '../settings/user_settings.dart' show GlobalStorage;
import '../theme/app_theme.dart' show AppColors;
import '../chat/widgets/markdown_view.dart';
import '../chat/widgets/user_message_bubble.dart';
import 'computer_group_sidebar.dart';
import 'desktop_host_chats.dart';
import 'desktop_host_composer.dart';
import 'desktop_host_connection.dart';
import 'desktop_host_controls.dart';
import 'desktop_host_project_history.dart';
import 'link_host.dart';
import 'desktop_remote_activity.dart';
import 'desktop_remote_session_actions.dart';
import 'desktop_host_session_controls.dart';
import 'desktop_remote_people.dart';
import 'desktop_remote_media.dart';
import 'desktop_remote_media_preview.dart';
import 'desktop_remote_rail.dart';
import 'desktop_remote_project_tools.dart';

typedef DesktopHostChatKey = ({String kind, String id});

/// Optional persistence for selection, keyed by the authenticated host ID.
/// Writes for a host must preserve invocation order.
abstract interface class DesktopHostLastChatStore {
  Future<DesktopHostChatKey?> read(String host);
  Future<void> write(String host, DesktopHostChatKey chat);
}

class SavedDesktopHostChat implements DesktopHostLastChatStore {
  SavedDesktopHostChat._(this.storage);
  final GlobalStorage storage;
  static final _instances = Expando<SavedDesktopHostChat>();
  static SavedDesktopHostChat? forStorage(GlobalStorage? storage) =>
      storage == null
      ? null
      : _instances[storage] ??= SavedDesktopHostChat._(storage);

  @override
  Future<DesktopHostChatKey?> read(String host) async => switch (storage
      .get<Map>('workbench.desktopLastChat.$host')) {
    {'kind': final String kind, 'id': final String id} => (kind: kind, id: id),
    _ => null,
  };

  @override
  Future<void> write(String host, DesktopHostChatKey chat) => storage.set(
    'workbench.desktopLastChat.$host',
    {'kind': chat.kind, 'id': chat.id},
  );
}

/// A client view of one remote host. The workbench owns both models and their
/// binding.
class DesktopHostPage extends StatefulWidget {
  const DesktopHostPage({
    super.key,
    required this.connection,
    required this.chats,
    required this.onBack,
    this.lastChatStore,
    this.localHost,
    this.onSelectComputer,
    this.computerNavigation = 0,
    this.reviewVisible = true,
    this.windowHeader,
  });

  final DesktopHostConnection connection;
  final DesktopHostChats chats;
  final VoidCallback onBack;
  final DesktopHostLastChatStore? lastChatStore;
  final LinkHost? localHost;
  final ValueChanged<String>? onSelectComputer;
  final int computerNavigation;
  final bool reviewVisible;
  final Widget Function(Widget directoryToggle)? windowHeader;

  @override
  State<DesktopHostPage> createState() => _DesktopHostPageState();
}

class _DesktopHostPageState extends State<DesktopHostPage> {
  // The connection belongs to the workbench and outlives this page. Keep
  // unsent drafts in memory when switching back to the local workspace.
  // The host component is LinkPeer.remote, not the display name or route.
  static final _drafts =
      Expando<Map<(String, String, String), DesktopHostDraft>>();
  static final _emptyDraft = DesktopHostDraft('');

  bool _working = false;
  bool _sidebarHidden = false;
  bool _rosterExpanded = true;
  bool _compactCatalog = false;
  ({LinkPeer peer, DesktopHostChatKey? editor})? _peopleDock;
  bool _leaving = false;
  Object? _chatRequest;
  final _remoteActionsKey = GlobalKey<DesktopRemoteSessionActionsState>();
  final _collapsedFolders = <(String, String)>{};
  final _restoring = <(int, String)>{};
  final _restoreHandled = <String>{};
  String? _selectedComputer;
  int _selectionEpoch = 0;
  String? _localError;
  String? _localChatError;

  DesktopHostConnection get _connection => widget.connection;
  DesktopHostChats get _chats => widget.chats;
  bool get _busy => _working || _connection.busy;
  bool get _stored => _connection.groupSelected;
  bool get _online => _stored && _connection.peer != null;
  bool get _chatBusy => _chatRequest != null || _chats.busy;

  void _openPeople(LinkPeer peer, {DesktopHostChatKey? editor}) {
    if (!_online || peer.isClosed || !identical(_connection.peer, peer)) return;
    if (editor != null &&
        (_chats.selected?.kind != editor.kind ||
            _chats.selected?.id != editor.id)) {
      return;
    }
    setState(() => _peopleDock = (peer: peer, editor: editor));
  }

  Widget _withPeopleDock({
    required double width,
    required bool wide,
    required LinkPeer? peer,
    required Widget child,
  }) {
    final dock = switch (_peopleDock) {
      final dock? when identical(dock.peer, peer) && !dock.peer.isClosed =>
        dock,
      _ => null,
    };
    // Leave room for the conversation when the sidebar is also open.
    final panelWidth = width < 1050 ? 300.0 : 360.0;
    final sideBySide = dock != null && wide;
    final compact = dock != null && !sideBySide;
    return Stack(
      fit: StackFit.expand,
      children: [
        PositionedDirectional(
          start: 0,
          end: sideBySide ? panelWidth + 1 : 0,
          top: 0,
          bottom: 0,
          child: Offstage(
            offstage: compact,
            child: ExcludeFocus(
              excluding: compact,
              child: TickerMode(enabled: !compact, child: child),
            ),
          ),
        ),
        if (dock != null)
          PositionedDirectional(
            top: 0,
            bottom: 0,
            end: 0,
            width: sideBySide ? panelWidth + 1 : width,
            child: Row(
              children: [
                SizedBox(
                  width: sideBySide ? 1 : 0,
                  child: sideBySide ? const VerticalDivider(width: 1) : null,
                ),
                Expanded(
                  child: DesktopRemotePeopleManager(
                    peer: dock.peer,
                    initialBotId: dock.editor?.kind == 'bot'
                        ? dock.editor?.id
                        : null,
                    initialGroupId: dock.editor?.kind == 'group'
                        ? dock.editor?.id
                        : null,
                    compact: compact,
                    onCatalog: _chats.acceptCatalogReply,
                    isCurrentPeer: (expected) =>
                        mounted &&
                        !_leaving &&
                        _peopleDock == dock &&
                        identical(_connection.peer, expected),
                    onClose: () {
                      if (_peopleDock == dock) {
                        setState(() => _peopleDock = null);
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  @override
  void didUpdateWidget(DesktopHostPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.computerNavigation != widget.computerNavigation) {
      _sidebarHidden = false;
      _rosterExpanded = true;
      _compactCatalog = true;
    }
  }

  void _toggleCatalog(bool wide) => setState(() {
    if (wide) {
      _sidebarHidden = !_sidebarHidden;
    } else {
      _compactCatalog = !_compactCatalog;
    }
  });

  @override
  void dispose() {
    final chats = _chats;
    final selected = chats.selected;
    if (selected != null || _chatRequest != null) {
      // Workbench navigation can remove this page without using either back
      // button. Close its subscription after the tree finishes unmounting,
      // since closeChat notifies any remaining model listeners.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (identical(chats.selected, selected)) chats.closeChat();
      });
    }
    super.dispose();
  }

  Future<void> _runConnection(
    Future<void> Function(DesktopHostConnection) action,
  ) async {
    if (_busy) return;
    final connection = _connection;
    setState(() {
      _working = true;
      _localError = null;
    });
    try {
      await action(connection);
    } on Exception {
      if (mounted && identical(_connection, connection)) {
        final text = _HostText(context);
        setState(() => _localError = text.actionFailed);
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  void _back() {
    if (_leaving) return;
    _leaving = true;
    if (_chats.selected != null || _chatRequest != null) _closeChat();
    widget.onBack();
  }

  Future<bool> _runChat(Future<void> Function(DesktopHostChats) action) async {
    if (!_online || _busy || _chatBusy) return false;
    final chats = _chats;
    final peer = _connection.peer;
    final request = Object();
    bool isCurrent() =>
        mounted &&
        identical(_chats, chats) &&
        identical(_chatRequest, request) &&
        identical(_connection.peer, peer);
    setState(() {
      _chatRequest = request;
      _localChatError = null;
    });
    try {
      await action(chats);
      return isCurrent() && chats.error == null;
    } on Exception {
      if (isCurrent()) {
        setState(() => _localChatError = _HostText(context).actionFailed);
      }
      return false;
    } finally {
      if (mounted && identical(_chatRequest, request)) {
        setState(() => _chatRequest = null);
      }
    }
  }

  Future<void> _openChat(DesktopHostChat chat, {bool remember = true}) async {
    if (remember && _compactCatalog) setState(() => _compactCatalog = false);
    final selected = _chats.selected;
    if (selected?.kind == chat.kind && selected?.id == chat.id) return;
    final host = _connection.peer?.remote;
    if (host == null || !_online || _busy || _chatBusy) return;
    _restoreHandled.add(host);
    final store = widget.lastChatStore;
    final opened = await _runChat((chats) => chats.open(chat));
    final current = _chats.selected;
    if (remember &&
        opened &&
        store != null &&
        current?.kind == chat.kind &&
        current?.id == chat.id) {
      try {
        await store.write(host, (kind: chat.kind, id: chat.id));
      } on Exception {
        // A storage failure should not close a working conversation.
      }
    }
  }

  Future<void> _createSession(ProjectInfo folder) async {
    final peer = _connection.peer;
    if (peer == null || !_online || _busy || _chatBusy) return;
    final host = peer.remote;
    _restoreHandled.add(host);
    setState(() => _collapsedFolders.remove((host, folder.id)));
    final label = _HostText(context).newSession;
    final opened = await _runChat(
      (chats) => chats.createInProject(folder.id, label),
    );
    if (!mounted || !opened || !identical(_connection.peer, peer)) return;
    if (_compactCatalog) setState(() => _compactCatalog = false);
    final current = _chats.selected;
    if (current != null &&
        current.kind == 'project' &&
        current.projectId == folder.id) {
      try {
        await widget.lastChatStore?.write(host, (
          kind: current.kind,
          id: current.id,
        ));
      } on Exception {
        /* Selection remains usable. */
      }
    }
  }

  Future<void> _manageSession(
    LinkPeer peer,
    DesktopHostChat chat,
    String method,
  ) async {
    bool current() =>
        mounted &&
        identical(_connection.peer, peer) &&
        _online &&
        !_busy &&
        !_chatBusy &&
        _chats.chats.any(
          (c) =>
              c.kind == 'project' &&
              c.id == chat.id &&
              c.projectId == chat.projectId,
        );
    if (!current()) return;
    final strings = context.l10n;
    final params = <String, Object?>{'session': chat.id};
    switch (method) {
      case LinkMethods.rename:
        var title = chat.title;
        final value = await showDialog<String>(
          context: context,
          builder: (dialog) => AlertDialog(
            title: Text(strings.commonRename),
            content: TextFormField(
              initialValue: title,
              autofocus: true,
              onChanged: (s) => title = s,
              onFieldSubmitted: (s) => Navigator.pop(dialog, s),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog),
                child: Text(strings.commonCancel),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialog, title),
                child: Text(strings.commonSave),
              ),
            ],
          ),
        );
        if (value == null ||
            value.trim().isEmpty ||
            value.trim() == chat.title) {
          return;
        }
        params['title'] = value.trim();
      case LinkMethods.pin:
        params['pinned'] = !chat.pinned;
      case LinkMethods.archive:
      case LinkMethods.delete:
        final deleting = method == LinkMethods.delete;
        final accepted = await showDialog<bool>(
          context: context,
          builder: (dialog) => AlertDialog(
            title: Text(
              deleting
                  ? strings.sidebarDeleteAgentTitle
                  : strings.sidebarArchive,
            ),
            content: Text(
              deleting
                  ? strings.sidebarDeleteAgentMessage(chat.title)
                  : chat.title,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog, false),
                child: Text(strings.commonCancel),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialog, true),
                child: Text(
                  deleting ? strings.commonDelete : strings.sidebarArchive,
                ),
              ),
            ],
          ),
        );
        if (accepted != true) return;
      default:
        return;
    }
    if (current()) {
      await _runChat((_) async {
        await peer.call(method, params);
      });
    }
  }

  bool _canRestore(String host) =>
      _online &&
      !_leaving &&
      !_busy &&
      !_chatBusy &&
      _connection.peer?.remote == host &&
      _chats.selected == null &&
      _chats.error == null &&
      !_restoreHandled.contains(host);

  void _queueRestore() {
    final selectedComputer = _connection.selectedHostId;
    if (_selectedComputer != selectedComputer) {
      _selectedComputer = selectedComputer;
      _selectionEpoch++;
      _restoreHandled.remove(selectedComputer);
      _localError = null;
      _localChatError = null;
    }
    final store = widget.lastChatStore;
    final host = _connection.peer?.remote;
    final epoch = _selectionEpoch;
    if (store == null ||
        host == null ||
        !_canRestore(host) ||
        _chats.chats.isEmpty ||
        _restoring.contains((epoch, host))) {
      return;
    }
    final connection = _connection;
    final chats = _chats;
    final peer = connection.peer;
    bool isCurrent() =>
        mounted &&
        identical(connection, _connection) &&
        identical(peer, connection.peer) &&
        epoch == _selectionEpoch &&
        identical(chats, _chats) &&
        identical(store, widget.lastChatStore) &&
        _canRestore(host);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!isCurrent() || !_restoring.add((epoch, host))) return;
      DesktopHostChatKey? key;
      try {
        key = await store.read(host);
      } on Exception {
        // Storage can be unavailable. The catalog remains usable.
      } finally {
        _restoring.remove((epoch, host));
      }
      if (!isCurrent()) return;
      _restoreHandled.add(host);
      final match = chats.chats
          .where((chat) => chat.kind == key?.kind && chat.id == key?.id)
          .firstOrNull;
      if (match != null) await _openChat(match, remember: false);
    });
  }

  void _closeChat() {
    setState(() {
      _compactCatalog = false;
      _chatRequest = null;
      _localChatError = null;
    });
    _chats.closeChat();
  }

  bool Function() _conversationGuard(LinkPeer? peer, DesktopHostChat chat) {
    final connection = _connection;
    final chats = _chats;
    return () =>
        mounted &&
        !_leaving &&
        _online &&
        identical(_connection, connection) &&
        identical(connection.peer, peer) &&
        identical(_chats, chats) &&
        chats.isCurrentConversation(peer, chat);
  }

  Future<bool> _send(
    bool Function() isCurrent,
    String draft,
    DesktopRemoteAttachments attachments,
  ) async {
    if (!isCurrent()) return false;
    var confirmed = false;
    await _runChat((chats) async {
      if (!isCurrent()) return;
      final request = _chatRequest;
      final sent = await chats.sendWithAttachments(draft, attachments);
      confirmed = sent && identical(_chatRequest, request);
    });
    return confirmed && isCurrent();
  }

  @override
  Widget build(BuildContext context) {
    final text = _HostText(context);
    return ListenableBuilder(
      listenable: Listenable.merge([_connection, _chats, widget.localHost]),
      builder: (context, _) {
        _queueRestore();
        return Material(
          color: AppColors.windowCanvas,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final error = _localError ?? (_stored ? _connection.error : null);
              final host = _online ? _connection.peer?.remote : null;
              final selected = host == null ? null : _chats.selected;
              final wide = constraints.maxWidth >= 880;
              final showSidebar = wide && (!_sidebarHidden || selected == null);
              final showCompactCatalog =
                  !wide && (selected == null || _compactCatalog);
              final catalog = showSidebar || showCompactCatalog
                  ? Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: _catalog(
                        text,
                        error,
                        showChatStatus: selected == null,
                        compact: !wide,
                      ),
                    )
                  : null;
              final conversation = host == null || selected == null
                  ? Center(
                      child: _Notice(
                        host != null
                            ? text.chooseChat
                            : _stored
                            ? text.groupDisconnected
                            : text.chooseComputer,
                      ),
                    )
                  : selected.kind == 'project'
                  ? DesktopRemoteActivity(
                      key: ValueKey((
                        _connection.peer,
                        selected.id,
                        selected.projectId,
                      )),
                      files: switch (selected.projectId) {
                        final id? when id.isNotEmpty => DesktopRemoteRail(
                          peer: _connection.peer!,
                          chat: selected,
                          isCurrent: _conversationGuard(
                            _connection.peer,
                            selected,
                          ),
                        ),
                        _ => null,
                      },
                      session: DesktopRemoteActivitySession.fromChats(
                        _chats,
                        _connection.peer,
                        selected,
                      ),
                      hostName: _connection.hostName ?? text.host,
                      builder: (_, button, activityStrip) => _conversation(
                        text,
                        host,
                        selected,
                        error,
                        wide: wide,
                        activityButton: button,
                        activityStrip: activityStrip,
                      ),
                    )
                  : _conversation(text, host, selected, error, wide: wide);
              final body = _withPeopleDock(
                width: constraints.maxWidth,
                wide: wide,
                peer: host == null ? null : _connection.peer,
                child: Row(
                  children: [
                    if (showSidebar) ...[
                      SizedBox(width: 280, child: catalog),
                      const VerticalDivider(width: 1),
                    ],
                    Expanded(
                      key: const ValueKey('host-content'),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Offstage(
                            offstage: showCompactCatalog,
                            child: ExcludeFocus(
                              excluding: showCompactCatalog,
                              child: _contentPane(
                                conversation,
                                session: selected != null,
                              ),
                            ),
                          ),
                          if (showCompactCatalog) catalog!,
                        ],
                      ),
                    ),
                  ],
                ),
              );
              final directory = TextButton.icon(
                key: const ValueKey('host-toggle-sidebar'),
                onPressed: selected == null ? null : () => _toggleCatalog(wide),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 28),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                icon: Icon(
                  showSidebar || showCompactCatalog
                      ? Codicons.layoutSidebarLeft
                      : Codicons.layoutSidebarLeftOff,
                  size: 16,
                ),
                label: Text(
                  showCompactCatalog && selected != null
                      ? text.returnToChat
                      : text.sessionDirectory,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              );
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  widget.windowHeader?.call(directory) ??
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: directory,
                      ),
                  Expanded(child: body),
                ],
              );
            },
          ),
        );
      },
    );
  }

  Widget _contentPane(Widget child, {required bool session}) => Padding(
    padding: const EdgeInsets.all(Islands.gap),
    child: Island(
      color: AppColors.background,
      child: Material(
        type: MaterialType.transparency,
        child: session ? child : _column(child),
      ),
    ),
  );
  Widget _column(Widget child) => ValueListenableBuilder<double>(
    valueListenable: ChatWidth.current,
    child: child,
    builder: (context, width, pane) => ChatColumn(
      maxWidth: width,
      left: Islands.inset,
      right: Islands.inset,
      child: pane,
    ),
  );

  bool _currentProject(LinkPeer expected, String id) =>
      mounted &&
      _online &&
      identical(_connection.peer, expected) &&
      _chats.projects.any((p) => p.id == id);

  Widget _catalog(
    _HostText text,
    String? error, {
    required bool showChatStatus,
    required bool compact,
  }) {
    final chatError = _localChatError ?? _chats.error;
    final groups = <String, List<DesktopHostChat>>{
      'project': [],
      'bot': [],
      'group': [],
    };
    if (_online) {
      for (final chat in _chats.chats) {
        groups[chat.kind]?.add(chat);
      }
    }
    final host = _connection.peer?.remote;
    final folders = _online ? _chats.projects : const <ProjectInfo>[];
    final byFolder = <String, List<DesktopHostChat>>{};
    for (final chat in groups['project']!) {
      if (chat.projectId case final id?) {
        (byFolder[id] ??= []).add(chat);
      }
    }
    return CustomScrollView(
      key: const ValueKey('host-catalog'),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.only(top: 4),
          sliver: SliverToBoxAdapter(
            child: ComputerGroupSidebar(
              key: ObjectKey(widget.localHost),
              host: widget.localHost,
              connection: _connection,
              expanded: _rosterExpanded,
              onToggle: () =>
                  setState(() => _rosterExpanded = !_rosterExpanded),
              onLocal: _back,
              onSelect: (id) {
                if (widget.onSelectComputer case final select?) {
                  select(id);
                } else {
                  unawaited(_connection.selectGroupMember(id));
                }
              },
              onConnectionInfo: (id) {
                if (_connection.peer?.remote == id) _showConnectionInfo(text);
              },
              reviewVisible:
                  widget.reviewVisible &&
                  !(compact &&
                      identical(_peopleDock?.peer, _connection.peer) &&
                      _peopleDock != null),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_busy) _Progress(text.working),
              if (showChatStatus && error != null)
                _Notice(error, isError: true),
              if (_stored && widget.localHost == null) _host(text),

              if (_online && showChatStatus) ...[
                const SizedBox(height: 16),
                if (_chatBusy) _Progress(text.loadingChats),
                if (chatError != null) _Notice(chatError, isError: true),
                if (!_chatBusy &&
                    chatError == null &&
                    folders.isEmpty &&
                    groups.values.every((group) => group.isEmpty))
                  _Notice(text.emptyCatalog),
              ],
            ],
          ),
        ),
        for (final entry in groups.entries)
          if (entry.key == 'project'
              ? folders.isNotEmpty
              : entry.value.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
                child: Semantics(
                  header: true,
                  child: Text(
                    text.group(entry.key),
                    style: SettingsText.heading,
                  ),
                ),
              ),
            ),
            if (entry.key == 'project' && host != null)
              for (final folder in folders) ...[
                SliverToBoxAdapter(
                  child: _CatalogRow(
                    key: ValueKey(('folder', folder.id)),
                    label: folder.name,
                    leading: DesktopRemoteProjectIcon(
                      peer: _connection.peer,
                      project: folder,
                      size: 16,
                      isCurrent: _currentProject,
                      color: AppColors.textFaint,
                      fallback: _collapsedFolders.contains((host, folder.id))
                          ? Codicons.folder
                          : Codicons.folderOpened,
                    ),
                    action: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          key: ValueKey(('new-session', folder.id)),
                          tooltip: text.newSession,
                          constraints: const BoxConstraints.tightFor(
                            width: 28,
                            height: 28,
                          ),
                          padding: EdgeInsets.zero,
                          icon: const Icon(Icons.add, size: 16),
                          onPressed: _busy || _chatBusy
                              ? null
                              : () => _createSession(folder),
                        ),
                        if (_connection.peer case final peer?)
                          DesktopRemoteProjectActions(
                            peer: peer,
                            project: folder,
                            hostName: _connection.hostName ?? text.host,
                            isCurrent: _currentProject,
                            enabled: !_busy && !_chatBusy,
                            onError: (message) =>
                                setState(() => _localChatError = message),
                          ),
                      ],
                    ),
                    icon: _collapsedFolders.contains((host, folder.id))
                        ? Codicons.folder
                        : Codicons.folderOpened,
                    trailing: _collapsedFolders.contains((host, folder.id))
                        ? Codicons.chevronRight
                        : Codicons.chevronDown,
                    onTap: () => setState(() {
                      final key = (host, folder.id);
                      if (!_collapsedFolders.remove(key)) {
                        _collapsedFolders.add(key);
                      }
                    }),
                  ),
                ),
                if (!_collapsedFolders.contains((host, folder.id)))
                  _chatRows([
                    for (final pinned in [true, false])
                      ...?(byFolder[folder.id]?.where(
                        (chat) => chat.pinned == pinned,
                      )),
                  ]),
              ]
            else
              _chatRows(entry.value),
          ],
        const SliverToBoxAdapter(child: SizedBox(height: 16)),
      ],
    );
  }

  Widget _chatRows(List<DesktopHostChat> chats) => SliverList.builder(
    itemCount: chats.length,
    itemBuilder: (context, index) {
      final chat = chats[index];
      final selected = _chats.selected;
      final peer = _connection.peer;
      final strings = context.l10n;
      return _CatalogRow(
        key: ValueKey((chat.kind, chat.id)),
        action: chat.kind != 'project' || peer == null || chat.provisional
            ? null
            : PopupMenuButton<String>(
                key: ValueKey(('manage-session', chat.id)),
                tooltip: _HostText(context).manage,
                enabled: !_busy && !_chatBusy,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 128),
                icon: const Icon(Icons.more_horiz, size: 16),
                style: IconButton.styleFrom(
                  minimumSize: const Size(28, 28),
                  fixedSize: const Size(28, 28),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onSelected: (method) => _manageSession(peer, chat, method),
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: LinkMethods.rename,
                    child: Text(strings.commonRename),
                  ),
                  PopupMenuItem(
                    value: LinkMethods.pin,
                    child: Text(
                      chat.pinned ? strings.sidebarUnpin : strings.sidebarPin,
                    ),
                  ),
                  PopupMenuItem(
                    value: LinkMethods.archive,
                    child: Text(strings.sidebarArchive),
                  ),
                  PopupMenuItem(
                    value: LinkMethods.delete,
                    child: Text(strings.commonDelete),
                  ),
                ],
              ),
        selected: selected?.kind == chat.kind && selected?.id == chat.id,
        onTap: _busy || _chatBusy ? null : () => _openChat(chat),
        indent: chat.kind == 'project' ? 24 : 0,
        icon: switch (chat.kind) {
          'project' =>
            chat.pinned ? Icons.push_pin_outlined : Codicons.commentDiscussion,
          'bot' => Icons.smart_toy_outlined,
          _ => Icons.groups_outlined,
        },
        activity: switch (chat.status) {
          LinkSessionStatus.needsInput => Tooltip(
            message: strings.sidebarNeedsInput,
            child: const Icon(Icons.pending_actions, size: 14),
          ),
          LinkSessionStatus.running => Tooltip(
            message: strings.sidebarRunning,
            child: const Icon(Icons.play_arrow, size: 14),
          ),
          _ => null,
        },
        unread: chat.unread,
        label: chat.title,
        updatedAt: chat.updatedAt,
      );
    },
  );

  Widget _host(_HostText text) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    child: Row(
      children: [
        const Icon(Codicons.deviceDesktop, size: 16),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _connection.hostName ?? text.host,
                style: SettingsText.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                _online ? text.online : text.groupDisconnected,
                style: SettingsText.description,
              ),
            ],
          ),
        ),
        if (!_online)
          TextButton(
            onPressed: _busy
                ? null
                : () => _runConnection((c) => c.reconnect()),
            child: Text(text.reconnect),
          ),
        if (_online)
          PopupMenuButton<String>(
            tooltip: text.hostOptions,
            enabled: !_busy,
            iconSize: 16,
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'connectionInfo',
                child: Text(text.connectionInfo),
              ),
            ],
            onSelected: (_) => _showConnectionInfo(text),
          ),
      ],
    ),
  );

  void _showConnectionInfo(_HostText text) {
    final connection = _connection;
    final peer = connection.peer;
    if (!_online || peer == null || peer.isClosed || _leaving) return;

    Future<LinkPath> readPath() async {
      try {
        return await peer.connection.path();
      } on Object {
        return LinkPath.none;
      }
    }

    final path = readPath();
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(text.connectionInfo),
        content: ListenableBuilder(
          listenable: connection,
          builder: (context, _) => FutureBuilder<LinkPath>(
            future: path,
            builder: (context, result) {
              if (!mounted ||
                  _leaving ||
                  !identical(_connection, connection) ||
                  !identical(connection.peer, peer) ||
                  peer.isClosed) {
                return Text(text.groupDisconnected);
              }
              final path = result.data;
              if (path == null) return Text(text.working);
              if (path.kind == LinkPathKind.none) {
                return Text(text.routeUnavailable);
              }
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(text.route(path.kind)),
                  if (path.rtt case final rtt? when !rtt.isNegative)
                    Text(text.latency(rtt.inMilliseconds)),
                ],
              );
            },
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
  }

  Widget _conversation(
    _HostText text,
    String host,
    DesktopHostChat chat,
    String? connectionError, {
    required bool wide,
    Widget? activityButton,
    Widget? activityStrip,
  }) {
    final history = chat.kind == 'project' ? _chats.projectHistory : null;
    // The native history lays out its own text column and paints the minimap
    // in the surrounding margin. Only the composer is width-capped here.
    Widget bodyColumn(Widget child) => history == null ? _column(child) : child;
    Widget composerColumn(Widget child) =>
        history == null ? child : _column(child);
    final messages = _chats.messages;
    final hasEarlier = _chats.hasEarlier;
    final error = _localChatError ?? _chats.error;
    final connection = _connection;
    final peer = connection.peer;
    final isCurrent = _conversationGuard(peer, chat);
    final groupReply = chat.kind == 'group' ? _chats.groupReply : null;
    final canQuote =
        chat.kind == 'group' && !_busy && !_chatBusy && isCurrent();
    void selectReply(DesktopHostGroupQuote reply, {bool cancel = false}) {
      if (!_busy && !_chatBusy && isCurrent()) {
        _chats.selectGroupReply(peer, chat, reply, cancel: cancel);
      }
    }

    final chatKey = (host, chat.kind, chat.id);
    final drafts = _drafts[connection] ??= {};
    Future<bool> send(String draft, [DesktopRemoteAttachments? attachments]) {
      if (peer == null) return Future.value(false);
      return _send(
        isCurrent,
        draft,
        attachments ??
            DesktopRemoteAttachments(
              (peer, chat.kind, chat.id, chat.projectId),
              const [],
              const [],
            ),
      );
    }

    Widget composer(Widget? deliveryMenu) => _HostComposer(
      key: ValueKey((connection, peer, chat.projectId)),
      initialDraft: drafts[chatKey] ?? _emptyDraft,
      busy: _busy || _chatBusy,
      controls: _chats.sessionControls,
      peer: peer,
      chat: chat,
      chats: _chats,
      isMediaCurrent: isCurrent,
      activityStrip: activityStrip,
      deliveryMenu: deliveryMenu,
      project: chat.kind == 'project'
          ? _chats.projects.where((p) => p.id == chat.projectId).firstOrNull
          : null,
      onChanged: (draft) {
        if (draft.isEmpty) {
          drafts.remove(chatKey);
        } else {
          drafts[chatKey] = draft;
        }
      },
      onSend: send,
      onSendWithAttachments: send,
    );

    return Column(
      key: ValueKey(chatKey),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConversationCardHeader(
          title: _RemoteTitle(
            title: chat.title,
            onRename: chat.kind != 'project' || !_online || _busy || _chatBusy
                ? null
                : (value) {
                    final peer = connection.peer;
                    if (peer == null ||
                        peer.remote != host ||
                        _chats.selected?.id != chat.id ||
                        _chats.selected?.kind != 'project') {
                      return;
                    }
                    unawaited(
                      _runChat((_) async {
                        await peer.call(LinkMethods.rename, {
                          'session': chat.id,
                          'title': value,
                        });
                      }),
                    );
                  },
          ),
          trailing: [
            ?activityButton,
            if ((chat.kind == 'bot' || chat.kind == 'group') && peer != null)
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: chat.kind == 'bot'
                    ? text.botSettings
                    : text.groupSettings,
                icon: const Icon(Icons.settings_outlined, size: 16),
                onPressed: _busy || _chatBusy
                    ? null
                    : () => _openPeople(
                        peer,
                        editor: (kind: chat.kind, id: chat.id),
                      ),
              ),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: wide ? text.closeChat : text.backToChats,
              onPressed: _closeChat,
              icon: Icon(
                wide ? Icons.close : Icons.list_alt_outlined,
                size: 16,
              ),
            ),
          ],
        ),
        Expanded(
          child: bodyColumn(
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (connectionError != null)
                  _Notice(connectionError, isError: true),
                if (_chatBusy) _Progress(text.working),
                if (error != null) _Notice(error, isError: true),
                Expanded(
                  child: history != null
                      ? DesktopHostProjectHistory(
                          feed: history,
                          media: (peer: peer, chat: chat, isCurrent: isCurrent),
                          openMessageEditor: (index, item) => _remoteActionsKey
                              .currentState
                              ?.openMessageEditor(history, index, item),
                          earlierEnabled: !_busy && !_chatBusy,
                          emptyLabel: !_chatBusy && error == null
                              ? text.emptyChat
                              : null,
                          onPickReply: _busy || _chatBusy
                              ? null
                              : (reply) {
                                  final previous = drafts[chatKey];
                                  if (!isCurrent() ||
                                      _busy ||
                                      _chatBusy ||
                                      (previous?.text.trim().isNotEmpty ??
                                          false)) {
                                    return;
                                  }
                                  setState(
                                    () => drafts[chatKey] = DesktopHostDraft(
                                      reply,
                                      images: previous?.images ?? const [],
                                    ),
                                  );
                                },
                        )
                      : messages.isEmpty && !hasEarlier
                      ? Center(
                          child: !_chatBusy && error == null
                              ? _Notice(text.emptyChat)
                              : null,
                        )
                      : ListView.builder(
                          // Keep the newest replies visible when at the bottom, even
                          // when loading older messages or the host is streaming.
                          reverse: true,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          itemCount: messages.length + (hasEarlier ? 1 : 0),
                          itemBuilder: (context, index) {
                            if (index == messages.length) {
                              return Center(
                                child: TextButton(
                                  onPressed: _busy || _chatBusy
                                      ? null
                                      : () => _runChat((c) => c.earlier()),
                                  child: Text(text.earlier),
                                ),
                              );
                            }
                            final message =
                                messages[messages.length - 1 - index];
                            final reference = message.groupReference;
                            final replyTarget = message.groupReplyTarget;
                            return DesktopRemoteMessageImages(
                              peer: peer,
                              chat: chat,
                              images: message.images,
                              isCurrent: isCurrent,
                              child: _MessageBubble(
                                message: message,
                                sender: message.mine
                                    ? text.you
                                    : message.sender,
                                group: chat.kind == 'group',
                                quote: reference == null
                                    ? null
                                    : _GroupQuoteBanner(
                                        label: text.quotedMessage(
                                          reference.sequence,
                                          reference.target,
                                        ),
                                        preview: switch (reference.target) {
                                          final target? => text.quotePreview(
                                            target,
                                          ),
                                          null => '',
                                        },
                                      ),
                                replyTooltip: text.replyToMessage,
                                onReply: canQuote && replyTarget != null
                                    ? () => selectReply(replyTarget)
                                    : null,
                              ),
                            );
                          },
                        ),
                ),
                if (groupReply != null)
                  _GroupQuoteBanner(
                    label: text.replyingTo(groupReply),
                    preview: text.quotePreview(groupReply),
                    trailing: IconButton(
                      tooltip: text.cancelReply,
                      onPressed: canQuote
                          ? () => selectReply(groupReply, cancel: true)
                          : null,
                      icon: const Icon(Icons.close, size: 16),
                    ),
                  ),
                composerColumn(
                  chat.kind == 'project'
                      ? DesktopRemoteSessionActions(
                          key: _remoteActionsKey,
                          peer: peer,
                          chat: chat,
                          chats: _chats,
                          enabled: !_busy && !_chatBusy,
                          composer: composer,
                        )
                      : composer(null),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _HostComposer extends StatelessWidget {
  const _HostComposer({
    super.key,
    required this.initialDraft,
    required this.busy,
    required this.onChanged,
    required this.onSend,
    required this.onSendWithAttachments,
    required this.peer,
    required this.chat,
    required this.isMediaCurrent,
    required this.chats,
    this.activityStrip,
    this.deliveryMenu,
    this.controls,
    this.project,
  });

  final DesktopHostDraft initialDraft;
  final bool busy;
  final ValueChanged<DesktopHostDraft> onChanged;
  final Future<bool> Function(String) onSend;
  final Future<bool> Function(String, DesktopRemoteAttachments)
  onSendWithAttachments;
  final LinkPeer? peer;
  final DesktopHostChat chat;
  final bool Function() isMediaCurrent;
  final DesktopHostChats chats;
  final Widget? activityStrip;
  final Widget? deliveryMenu;
  final DesktopHostSessionControls? controls;
  final ProjectInfo? project;

  @override
  Widget build(BuildContext context) {
    final text = _HostText(context);
    final branchView = chats.projectBranchView(peer, chat);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        activityStrip ?? const SizedBox.shrink(),
        DesktopHostComposer(
          initialDraft: initialDraft,
          busy: busy,
          placeholder: text.message,
          sendLabel: text.send,
          onChanged: onChanged,
          onSend: onSend,
          onSendWithAttachments: onSendWithAttachments,
          peer: peer,
          chat: chat,
          isMediaCurrent: isMediaCurrent,
          deliveryMenu: deliveryMenu,
          controls: controls,
        ),
        DesktopHostSessionFooter(
          project: project,
          controls: controls,
          branchAccess: branchView == null || peer == null
              ? null
              : (
                  peer: peer!,
                  view: branchView,
                  isCurrent: () => identical(
                    branchView,
                    chats.projectBranchView(peer, chat),
                  ),
                ),
        ),
      ],
    );
  }
}

class _RemoteTitle extends StatefulWidget {
  const _RemoteTitle({required this.title, this.onRename});
  final String title;
  final ValueChanged<String>? onRename;
  @override
  State<_RemoteTitle> createState() => _RemoteTitleState();
}

class _RemoteTitleState extends State<_RemoteTitle> {
  bool editing = false;
  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      color: AppColors.textMuted,
      fontSize: 12.5,
      fontWeight: FontWeight.w500,
    );
    return Align(
      alignment: Alignment.centerLeft,
      child: editing && widget.onRename != null
          ? SizedBox(
              width: 320,
              child: InlineRenameField(
                initial: widget.title,
                style: style,
                onDone: (value) {
                  setState(() => editing = false);
                  final next = value?.trim();
                  if (next != null && next.isNotEmpty && next != widget.title) {
                    widget.onRename?.call(next);
                  }
                },
              ),
            )
          : GestureDetector(
              onDoubleTap: widget.onRename == null
                  ? null
                  : () => setState(() => editing = true),
              child: HoverScrollText(widget.title, style: style),
            ),
    );
  }
}

class _CatalogRow extends StatelessWidget {
  const _CatalogRow({
    super.key,
    required this.label,
    required this.icon,
    this.trailing,
    this.action,
    this.leading,
    this.activity,
    this.unread = 0,
    this.updatedAt,
    this.selected = false,
    this.indent = 0,
    this.onTap,
  });
  final String label;
  final IconData icon;
  final IconData? trailing;
  final Widget? action;
  final Widget? leading;
  final Widget? activity;
  final int unread;
  final DateTime? updatedAt;
  final bool selected;
  final double indent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    enabled: onTap != null,
    child: IdeListRow(
      height: 32,
      onTap: onTap,
      selected: selected,
      tooltip: label,
      builder: (context, hovered) => Padding(
        padding: EdgeInsets.only(left: 8 + indent, right: 8),
        child: Row(
          children: [
            leading ?? Icon(icon, size: 15, color: AppColors.textFaint),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: AppColors.textPrimary),
              ),
            ),
            ?activity,
            if (unread > 0)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Tooltip(
                  message: context.l10n.sidebarUnread,
                  child: Text(
                    '$unread',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
              ),
            if (updatedAt != null)
              ValueListenableBuilder<bool>(
                valueListenable: SidebarTimes.shown,
                builder: (context, shown, _) => shown
                    ? Text(
                        relativeTime(updatedAt!, DateTime.now(), context.l10n),
                        style: TextStyle(
                          fontSize: 11,
                          color: AppColors.textFaint,
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ?action,
            if (trailing != null)
              Icon(trailing, size: 13, color: AppColors.textFaint),
          ],
        ),
      ),
    ),
  );
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.sender,
    required this.group,
    required this.replyTooltip,
    this.quote,
    this.onReply,
  });

  final DesktopHostMessage message;
  final String sender;
  final bool group;
  final String replyTooltip;
  final Widget? quote;
  final VoidCallback? onReply;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
    child: SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (group && sender.isNotEmpty) ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    sender,
                    style: SettingsText.heading,
                    textAlign: message.mine ? TextAlign.end : TextAlign.start,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (message.groupReplyTarget != null)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: replyTooltip,
                    onPressed: onReply,
                    icon: const Icon(Icons.reply, size: 16),
                  ),
              ],
            ),
            const SizedBox(height: 4),
          ],
          ?quote,
          if (message.mine)
            UserMessageBubble(text: message.text, textOnly: true)
          else
            MarkdownView(message.text, textOnly: true),
        ],
      ),
    ),
  );
}

class _GroupQuoteBanner extends StatelessWidget {
  const _GroupQuoteBanner({
    required this.label,
    required this.preview,
    this.trailing,
  });

  final String label;
  final String preview;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsetsDirectional.fromSTEB(12, 4, 8, 4),
    child: Row(
      children: [
        const Icon(Icons.format_quote, size: 16),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: SettingsText.heading,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (preview.isNotEmpty)
                Text(
                  preview,
                  style: SettingsText.description,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
        ?trailing,
      ],
    ),
  );
}

class _Notice extends StatelessWidget {
  const _Notice(this.label, {this.isError = false});

  final String label;
  final bool isError;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Text(
      label,
      style: SettingsText.description.copyWith(
        color: isError ? Theme.of(context).colorScheme.error : null,
      ),
    ),
  );
}

class _Progress extends StatelessWidget {
  const _Progress(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(
      children: [
        const ExcludeSemantics(
          child: SizedBox.square(
            dimension: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(child: _Notice(label)),
      ],
    ),
  );
}

// Kept with the view while its strings are scoped to this page.
class _HostText {
  _HostText(BuildContext context)
    : _zh = Localizations.localeOf(context).languageCode == 'zh';

  final bool _zh;

  String get botSettings => _zh ? '机器人设置' : 'Bot settings';
  String get groupSettings => _zh ? '群聊设置' : 'Group settings';
  String get replyToMessage => _zh ? '引用回复' : 'Reply to message';
  String get cancelReply => _zh ? '取消引用' : 'Cancel reply';
  String replyingTo(DesktopHostGroupQuote reply) {
    final target = '#${reply.sequence} · ${reply.mine ? you : reply.sender}';
    return _zh ? '正在回复 $target' : 'Replying to $target';
  }

  String quotedMessage(int sequence, DesktopHostGroupQuote? quote) {
    final sender = quote == null ? '' : ' · ${quote.mine ? you : quote.sender}';
    return _zh ? '引用 #$sequence$sender' : 'Quoted #$sequence$sender';
  }

  String quotePreview(DesktopHostGroupQuote quote) => quote.preview.isNotEmpty
      ? quote.preview
      : quote.hasImage
      ? (_zh ? '图片' : 'Image')
      : '';
  String get working => _zh ? '正在处理…' : 'Working…';
  String get online => _zh ? '已连接' : 'Connected';
  String get groupDisconnected =>
      _zh ? '未连接组成员' : 'Group computer not connected';
  String get host => _zh ? '主机' : 'Host';
  String get reconnect => _zh ? '重新连接' : 'Reconnect';
  String get cancel => _zh ? '取消' : 'Cancel';
  String group(String kind) => switch (kind) {
    'project' => _zh ? '项目' : 'Projects',
    'bot' => _zh ? '机器人' : 'Bots',
    _ => _zh ? '群聊' : 'Groups',
  };
  String get loadingChats => _zh ? '正在加载主机会话…' : 'Loading host conversations…';
  String get emptyCatalog =>
      _zh ? '主机上没有会话。' : 'No conversations on this host.';
  String get manage => _zh ? '管理会话' : 'Manage chat';
  String get newSession => _zh ? '新建会话' : 'New chat';
  String get hostOptions => _zh ? '主机选项' : 'Host options';
  String get connectionInfo => _zh ? '连接信息' : 'Connection info';
  String get routeUnavailable => _zh ? '暂无连接路径信息' : 'Route unavailable';
  String route(LinkPathKind kind) => switch (kind) {
    LinkPathKind.lan => _zh ? '局域网' : 'Local network',
    LinkPathKind.direct => _zh ? '直连' : 'Direct',
    LinkPathKind.relay => _zh ? '中继' : 'Relay',
    LinkPathKind.none => routeUnavailable,
  };
  String latency(int ms) => _zh ? '往返时延：$ms 毫秒' : 'Round-trip time: $ms ms';
  String get sessionDirectory => _zh ? '会话目录' : 'Session directory';
  String get backToChats => _zh ? '返回主机会话列表' : 'Back to host chats';
  String get closeChat => _zh ? '关闭会话' : 'Close chat';
  String get returnToChat => _zh ? '返回当前会话' : 'Return to current conversation';
  String get chooseComputer =>
      _zh ? '请从侧栏选择一台电脑。' : 'Select a computer from the sidebar.';
  String get chooseChat => _zh ? '请选择主机会话。' : 'Select a host conversation.';
  String get emptyChat => _zh ? '还没有消息。' : 'No messages yet.';
  String get earlier => _zh ? '加载更早的消息' : 'Load earlier messages';
  String get message => _zh ? '消息' : 'Message';
  String get send => _zh ? '发送' : 'Send';
  String get you => _zh ? '你' : 'You';
  String get actionFailed =>
      _zh ? '操作失败，请重试。' : 'The action failed. Try again.';
}
