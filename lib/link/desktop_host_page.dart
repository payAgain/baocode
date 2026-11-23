import 'dart:async';

import 'package:bao_link/bao_link.dart' show LinkMethods, LinkPeer, ProjectInfo;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
import '../settings/pages/settings_widgets.dart'
    show SettingsColors, SettingsText;
import '../settings/user_settings.dart' show GlobalStorage;
import '../theme/app_theme.dart' show AppColors;
import '../chat/widgets/markdown_view.dart';
import '../chat/widgets/user_message_bubble.dart';
import 'desktop_host_chats.dart';
import 'desktop_host_composer.dart';
import 'desktop_host_connection.dart';
import 'desktop_host_controls.dart';
import 'desktop_host_project_history.dart';
import 'desktop_host_session_controls.dart';
import 'desktop_remote_rail.dart';

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
  });

  final DesktopHostConnection connection;
  final DesktopHostChats chats;
  final VoidCallback onBack;
  final DesktopHostLastChatStore? lastChatStore;

  @override
  State<DesktopHostPage> createState() => _DesktopHostPageState();
}

class _DesktopHostPageState extends State<DesktopHostPage> {
  // The connection belongs to the workbench and outlives this page. Keep
  // its unsent text in memory when switching back to the local workspace.
  static final _drafts = Expando<Map<(String, String, String), String>>();

  final _invite = TextEditingController();
  final _inviteFocus = FocusNode();
  bool _working = false;
  bool _sidebarHidden = false;
  bool _openingInvite = false;
  bool _leaving = false;
  bool _confirmingForget = false;
  String? _confirmingCode;
  Object? _chatRequest;
  final _collapsedFolders = <(String, String)>{};
  final _restoring = <String>{};
  final _restoreHandled = <String>{};
  String? _localError;
  String? _localChatError;

  DesktopHostConnection get _connection => widget.connection;
  DesktopHostChats get _chats => widget.chats;
  bool get _busy => _working || _connection.busy;
  bool get _online =>
      _connection.pendingCode == null && _connection.peer != null;
  bool get _stored =>
      _online ||
      (_connection.pendingCode == null && _connection.hostName != null);
  bool get _showInvite => _connection.pendingCode == null && !_stored;
  bool get _chatBusy => _chatRequest != null || _chats.busy;

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
    _invite.dispose();
    _inviteFocus.dispose();
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

  Future<void> _paste() async {
    if (!_showInvite) return;
    await _runConnection((connection) async {
      final previous = _invite.value;
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (!mounted ||
          !identical(_connection, connection) ||
          !_showInvite ||
          _invite.value != previous) {
        return;
      }
      final text = data?.text?.trim();
      if (text == null || text.isEmpty) {
        setState(() => _localError = _HostText(context).emptyClipboard);
        return;
      }
      _invite.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
      _inviteFocus.requestFocus();
    });
  }

  Future<void> _pair() async {
    final invite = _invite.text.trim();
    if (!_showInvite || invite.isEmpty) return;
    await _runConnection((connection) async {
      _openingInvite = true;
      try {
        await connection.pair(invite);
      } finally {
        _openingInvite = false;
      }
    });
  }

  Future<void> _confirm(String code) async {
    if (_connection.pendingCode != code) return;
    await _runConnection((connection) async {
      _confirmingCode = code;
      _drafts[connection]?.clear();
      try {
        await connection.confirm();
        if (mounted && identical(_connection, connection) && _stored) {
          _invite.clear();
        }
      } finally {
        _confirmingCode = null;
      }
    });
  }

  Future<void> _forget(_HostText text) async {
    if (_busy || !_stored || _confirmingForget) return;
    final connection = _connection;
    final name = connection.hostName;
    _confirmingForget = true;
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: Text(text.forgetTitle),
          content: Text(text.forgetDescription),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.pop(context, false),
              child: Text(text.cancel),
            ),
            TextButton(
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
              onPressed: () => Navigator.pop(context, true),
              child: Text(text.forget),
            ),
          ],
        ),
      );
      if (confirmed != true ||
          !mounted ||
          !identical(connection, _connection) ||
          !_stored ||
          connection.hostName != name) {
        return;
      }
      await _runConnection((connection) async {
        await connection.forget();
        if (connection.hostName == null &&
            connection.peer == null &&
            connection.pendingCode == null) {
          _drafts[connection]?.clear();
          if (mounted && identical(connection, _connection)) _invite.clear();
        }
      });
    } finally {
      _confirmingForget = false;
    }
  }

  void _back() {
    if (_leaving) return;
    _leaving = true;
    if (_openingInvite ||
        (_connection.pendingCode != null && _confirmingCode == null)) {
      unawaited(_connection.cancelPairing().onError<Exception>((_, _) {}));
    }
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
    final store = widget.lastChatStore;
    final host = _connection.peer?.remote;
    if (store == null ||
        host == null ||
        !_canRestore(host) ||
        _chats.chats.isEmpty ||
        _restoring.contains(host)) {
      return;
    }
    final connection = _connection;
    final chats = _chats;
    bool isCurrent() =>
        mounted &&
        identical(connection, _connection) &&
        identical(chats, _chats) &&
        identical(store, widget.lastChatStore) &&
        _canRestore(host);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!isCurrent() || !_restoring.add(host)) return;
      DesktopHostChatKey? key;
      try {
        key = await store.read(host);
      } on Exception {
        // Storage can be unavailable. The catalog remains usable.
      } finally {
        _restoring.remove(host);
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
      _chatRequest = null;
      _localChatError = null;
    });
    _chats.closeChat();
  }

  Future<bool> _send((String, String, String) chatKey, String draft) async {
    final chat = _chats.selected;
    final message = draft.trim();
    if (message.isEmpty ||
        chat == null ||
        chatKey != (_connection.peer?.remote, chat.kind, chat.id)) {
      return false;
    }
    return _runChat((chats) => chats.send(message));
  }

  @override
  Widget build(BuildContext context) {
    final text = _HostText(context);
    return ListenableBuilder(
      listenable: Listenable.merge([_connection, _chats]),
      builder: (context, _) {
        _queueRestore();
        return Material(
          color: AppColors.windowCanvas,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final code = _connection.pendingCode ?? _confirmingCode;
              final error = _localError ?? _connection.error;
              final host = code == null ? _connection.peer?.remote : null;
              final selected = host == null ? null : _chats.selected;
              final wide = host != null && constraints.maxWidth >= 880;
              final catalog = _catalog(
                text,
                code,
                error,
                showChatStatus: selected == null,
              );
              final conversation = host == null || selected == null
                  ? Center(child: _Notice(text.chooseChat))
                  : selected.kind == 'project'
                  ? DesktopRemoteRail(
                      peer: _connection.peer!,
                      chat: selected,
                      child: _conversation(
                        text,
                        host,
                        selected,
                        error,
                        wide: wide,
                      ),
                    )
                  : _conversation(text, host, selected, error, wide: wide);
              final switcher = Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 16,
                  runSpacing: 4,
                  children: [
                    FilledButton.icon(
                      onPressed: _back,
                      icon: const Icon(Icons.arrow_back),
                      label: Text(
                        text.switchToLocal,
                        textAlign: TextAlign.center,
                      ),
                    ),
                    Semantics(
                      header: true,
                      child: Text(
                        text.title,
                        style: SettingsText.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              );
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!wide) switcher,
                  if (!wide) const Divider(height: 1),
                  Expanded(
                    child: Row(
                      children: [
                        if (wide && (!_sidebarHidden || selected == null)) ...[
                          SizedBox(
                            width: 280,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  switcher,
                                  Expanded(child: catalog),
                                ],
                              ),
                            ),
                          ),
                          const VerticalDivider(width: 1),
                        ],
                        Expanded(
                          key: const ValueKey('host-content'),
                          child: _contentPane(
                            wide || selected != null ? conversation : catalog,
                            session: selected != null,
                          ),
                        ),
                      ],
                    ),
                  ),
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

  Widget _catalog(
    _HostText text,
    String? code,
    String? error, {
    required bool showChatStatus,
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
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 16),
              if (_busy) _Progress(text.working),
              if (showChatStatus && error != null)
                _Notice(error, isError: true),
              if (code != null)
                _comparison(text, code)
              else if (_showInvite && (!_connection.busy || _working))
                _pairing(text)
              else if (_stored)
                _host(text),
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
                    action: IconButton(
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
                _online ? text.online : text.offline,
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
        PopupMenuButton<String>(
          tooltip: text.hostOptions,
          enabled: !_busy,
          iconSize: 16,
          itemBuilder: (_) => [
            PopupMenuItem(value: 'forget', child: Text(text.forget)),
          ],
          onSelected: (_) => _forget(text),
        ),
      ],
    ),
  );

  Widget _conversation(
    _HostText text,
    String host,
    DesktopHostChat chat,
    String? connectionError, {
    required bool wide,
  }) {
    final messages = _chats.messages;
    final hasEarlier = _chats.hasEarlier;
    final error = _localChatError ?? _chats.error;
    final connection = _connection;
    final chatKey = (host, chat.kind, chat.id);
    final drafts = _drafts[connection] ??= {};
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
            if (wide) ...[
              if (_sidebarHidden)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: text.switchToLocal,
                  icon: const Icon(Codicons.deviceDesktop, size: 16),
                  onPressed: _back,
                ),
              IconButton(
                key: const ValueKey('host-toggle-sidebar'),
                visualDensity: VisualDensity.compact,
                tooltip: text.sidebar,
                icon: const Icon(Codicons.layoutSidebarLeft, size: 16),
                onPressed: () =>
                    setState(() => _sidebarHidden = !_sidebarHidden),
              ),
            ],
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
          child: _column(
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (connectionError != null)
                  _Notice(connectionError, isError: true),
                if (_chatBusy) _Progress(text.working),
                if (error != null) _Notice(error, isError: true),
                const Divider(height: 1),
                Expanded(
                  child: chat.kind == 'project' && _chats.projectHistory != null
                      ? DesktopHostProjectHistory(
                          feed: _chats.projectHistory!,
                          earlierEnabled: !_busy && !_chatBusy,
                          emptyLabel: !_chatBusy && error == null
                              ? text.emptyChat
                              : null,
                          onPickReply: _busy || _chatBusy
                              ? null
                              : (reply) {
                                  if (_busy ||
                                      _chatBusy ||
                                      (drafts[chatKey]?.trim().isNotEmpty ??
                                          false)) {
                                    return;
                                  }
                                  setState(() => drafts[chatKey] = reply);
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
                            return _MessageBubble(
                              message: message,
                              sender: message.mine ? text.you : message.sender,
                              group: chat.kind == 'group',
                            );
                          },
                        ),
                ),
                const Divider(height: 1),
                _HostComposer(
                  key: ObjectKey(connection),
                  initialDraft: drafts[chatKey] ?? '',
                  busy: _busy || _chatBusy,
                  controls: _chats.sessionControls,
                  project: chat.kind == 'project'
                      ? _chats.projects
                            .where((p) => p.id == chat.projectId)
                            .firstOrNull
                      : null,
                  onChanged: (draft) {
                    if (draft.isEmpty) {
                      drafts.remove(chatKey);
                    } else {
                      drafts[chatKey] = draft;
                    }
                  },
                  onSend: (draft) => _send(chatKey, draft),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _pairing(_HostText text) => _HostCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(text.pairTitle, style: SettingsText.title),
        const SizedBox(height: 6),
        Text(text.pairDescription, style: SettingsText.description),
        const SizedBox(height: 16),
        TextField(
          controller: _invite,
          focusNode: _inviteFocus,
          enabled: !_busy,
          autocorrect: false,
          enableSuggestions: false,
          enableIMEPersonalizedLearning: false,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _pair(),
          style: SettingsText.path,
          decoration: InputDecoration(
            labelText: text.invite,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton(
              onPressed: _busy ? null : _paste,
              child: Text(text.paste),
            ),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _invite,
              builder: (context, value, _) => FilledButton(
                onPressed: _busy || value.text.trim().isEmpty ? null : _pair,
                child: Text(text.pair),
              ),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _comparison(_HostText text, String code) => _HostCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(text.codeTitle, style: SettingsText.title),
        const SizedBox(height: 6),
        Text(text.compare, style: SettingsText.description),
        const SizedBox(height: 14),
        Semantics(
          liveRegion: true,
          child: SelectableText(
            code,
            style: SettingsText.path.copyWith(fontSize: 22, letterSpacing: 1),
          ),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton(
              onPressed: _busy ? null : () => _confirm(code),
              child: Text(text.confirm),
            ),
            OutlinedButton(
              onPressed: _busy
                  ? null
                  : () => _runConnection(
                      (connection) => connection.cancelPairing(),
                    ),
              child: Text(text.cancelPairing),
            ),
          ],
        ),
      ],
    ),
  );
}

class _HostComposer extends StatelessWidget {
  const _HostComposer({
    super.key,
    required this.initialDraft,
    required this.busy,
    required this.onChanged,
    required this.onSend,
    this.controls,
    this.project,
  });

  final String initialDraft;
  final bool busy;
  final ValueChanged<String> onChanged;
  final Future<bool> Function(String) onSend;
  final DesktopHostSessionControls? controls;
  final ProjectInfo? project;

  @override
  Widget build(BuildContext context) {
    final text = _HostText(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DesktopHostComposer(
          initialDraft: initialDraft,
          busy: busy,
          placeholder: text.message,
          sendLabel: text.send,
          onChanged: onChanged,
          onSend: onSend,
          controls: controls,
        ),
        DesktopHostSessionFooter(project: project, controls: controls),
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
    this.updatedAt,
    this.selected = false,
    this.indent = 0,
    this.onTap,
  });
  final String label;
  final IconData icon;
  final IconData? trailing;
  final Widget? action;
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
            Icon(icon, size: 15, color: AppColors.textFaint),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: AppColors.textPrimary),
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
  });

  final DesktopHostMessage message;
  final String sender;
  final bool group;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
    child: SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (group && sender.isNotEmpty) ...[
            Text(
              sender,
              style: SettingsText.heading,
              textAlign: message.mine ? TextAlign.end : TextAlign.start,
            ),
            const SizedBox(height: 4),
          ],
          if (message.mine)
            UserMessageBubble(text: message.text, textOnly: true)
          else
            MarkdownView(message.text, textOnly: true),
        ],
      ),
    ),
  );
}

class _HostCard extends StatelessWidget {
  const _HostCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: SettingsColors.card,
      border: Border.all(color: SettingsColors.stroke),
      borderRadius: BorderRadius.circular(8),
    ),
    child: child,
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
  String get title => _zh ? '远程工作区' : 'Remote workspace';
  String get switchToLocal => _zh ? '切回本地' : 'Switch to local';
  String get pairTitle => _zh ? '配对一台电脑' : 'Pair a Host';
  String get pairDescription => _zh
      ? '在要连接的电脑上打开 BaoCode 的「设置 → 手机」，显示配对二维码并复制链接。'
      : 'On the host computer, open BaoCode’s Settings → Mobile, show the pairing QR code, and copy its link.';
  String get invite => _zh ? '配对链接' : 'Pairing link';
  String get paste => _zh ? '粘贴' : 'Paste';
  String get pair => _zh ? '配对' : 'Pair';
  String get codeTitle => _zh ? '核对安全码' : 'Compare Safety Codes';
  String get compare => _zh
      ? '请核对另一台电脑上显示的安全码。只有两边的数字完全相同，才能确认配对。'
      : 'Check the safety code on the host computer. Only pair if all the digits on both computers match.';
  String get confirm => _zh ? '安全码一致，完成配对' : 'Codes match, pair';
  String get cancelPairing => _zh ? '取消配对' : 'Cancel pairing';
  String get working => _zh ? '正在处理…' : 'Working…';
  String get online => _zh ? '已连接' : 'Connected';
  String get offline => _zh ? '主机离线' : 'Host offline';
  String get host => _zh ? '主机' : 'Host';
  String get reconnect => _zh ? '重新连接' : 'Reconnect';
  String get forget => _zh ? '忘记主机' : 'Forget host';
  String get forgetTitle => _zh ? '要忘记这台主机吗？' : 'Forget this host?';
  String get forgetDescription => _zh
      ? '这会移除此电脑上保存的配对信息。要再次连接，必须使用新的配对链接。'
      : 'This removes the pairing saved on this computer. You’ll need a new invite to connect again.';
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
  String get sidebar => _zh ? '显示或隐藏侧栏' : 'Toggle sidebar';
  String get backToChats => _zh ? '返回主机会话列表' : 'Back to host chats';
  String get closeChat => _zh ? '关闭会话' : 'Close chat';
  String get chooseChat => _zh ? '请选择主机会话。' : 'Select a host conversation.';
  String get emptyChat => _zh ? '还没有消息。' : 'No messages yet.';
  String get earlier => _zh ? '加载更早的消息' : 'Load earlier messages';
  String get message => _zh ? '消息' : 'Message';
  String get send => _zh ? '发送' : 'Send';
  String get you => _zh ? '你' : 'You';
  String get emptyClipboard => _zh ? '剪贴板中没有文本。' : 'The clipboard has no text.';
  String get actionFailed =>
      _zh ? '操作失败，请重试。' : 'The action failed. Try again.';
}
