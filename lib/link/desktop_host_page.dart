import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../settings/pages/settings_widgets.dart'
    show SettingsColors, SettingsText;
import '../theme/app_theme.dart' show AppColors;
import 'desktop_host_chats.dart';
import 'desktop_host_connection.dart';

/// A client view of one remote host. The workbench owns both models and their
/// binding; displaying this page never opens a host conversation on its own.
class DesktopHostPage extends StatefulWidget {
  const DesktopHostPage({
    super.key,
    required this.connection,
    required this.chats,
    required this.onBack,
  });

  final DesktopHostConnection connection;
  final DesktopHostChats chats;
  final VoidCallback onBack;

  @override
  State<DesktopHostPage> createState() => _DesktopHostPageState();
}

class _DesktopHostPageState extends State<DesktopHostPage> {
  final _invite = TextEditingController();
  final _inviteFocus = FocusNode();
  final _draft = TextEditingController();
  bool _working = false;
  bool _confirmingForget = false;
  String? _confirmingCode;
  Object? _chatRequest;
  (String, String)? _draftChat;
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
    if (selected != null) {
      // Workbench navigation can remove this page without using either back
      // button. Close its subscription after the tree finishes unmounting,
      // since closeChat notifies any remaining model listeners.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (identical(chats.selected, selected)) chats.closeChat();
      });
    }
    _invite.dispose();
    _inviteFocus.dispose();
    _draft.dispose();
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
    await _runConnection((connection) => connection.pair(invite));
  }

  Future<void> _confirm(String code) async {
    if (_connection.pendingCode != code) return;
    await _runConnection((connection) async {
      _confirmingCode = code;
      try {
        await connection.confirm();
        if (mounted && identical(_connection, connection) && _stored) {
          _invite.clear();
          _discardDraft();
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
        if (mounted && identical(connection, _connection) && !_stored) {
          _invite.clear();
          _discardDraft();
        }
      });
    } finally {
      _confirmingForget = false;
    }
  }

  Future<void> _back() async {
    if (!_stored && _busy) return;
    if (_connection.pendingCode != null) {
      await _runConnection((connection) => connection.cancelPairing());
      if (!mounted || _connection.pendingCode != null) return;
    }
    if (_chats.selected != null) _closeChat();
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

  Future<void> _openChat(DesktopHostChat chat) async {
    if (_chats.selected != null) return;
    await _runChat((chats) {
      // A manual open starts with a clean composer. Reconnect restores the
      // still-selected chat through the model and does not enter here.
      _draft.clear();
      _draftChat = (chat.kind, chat.id);
      return chats.open(chat);
    });
  }

  void _closeChat() {
    _discardDraft();
    _chats.closeChat();
  }

  void _discardDraft() {
    _draft.clear();
    _draftChat = null;
    setState(() {
      _chatRequest = null;
      _localChatError = null;
    });
  }

  Future<void> _send(DesktopHostChat chat) async {
    final draft = _draft.text;
    final message = draft.trim();
    if (message.isEmpty || _draftChat != (chat.kind, chat.id)) return;
    final sent = await _runChat((chats) => chats.send(message));
    if (sent &&
        mounted &&
        _draftChat == (chat.kind, chat.id) &&
        _draft.text == draft) {
      _draft.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = _HostText(context);
    return ListenableBuilder(
      listenable: Listenable.merge([_connection, _chats]),
      builder: (context, _) {
        final code = _connection.pendingCode ?? _confirmingCode;
        final error = _localError ?? _connection.error;
        final selected = _online ? _chats.selected : null;
        return Material(
          color: AppColors.code,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final inset = constraints.maxWidth < 600 ? 16.0 : 32.0;
              final header = _HostHeading(
                title: text.title,
                tooltip: text.back,
                icon: Icons.arrow_back,
                onBack: !_stored && _busy ? null : _back,
              );
              return Padding(
                padding: EdgeInsets.symmetric(horizontal: inset),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 760),
                    child: selected == null
                        ? _catalog(text, header, code, error)
                        : _conversation(text, header, selected, error),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _catalog(_HostText text, Widget header, String? code, String? error) {
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
    return CustomScrollView(
      key: const ValueKey('host-catalog'),
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 16),
              header,
              const SizedBox(height: 12),
              if (_busy) _Progress(text.working),
              if (error != null) _Notice(error, isError: true),
              if (code != null)
                _comparison(text, code)
              else if (_showInvite)
                _pairing(text)
              else
                _host(text),
              if (_online) ...[
                const SizedBox(height: 16),
                if (_chatBusy) _Progress(text.loadingChats),
                if (chatError != null) _Notice(chatError, isError: true),
                if (!_chatBusy &&
                    chatError == null &&
                    groups.values.every((group) => group.isEmpty))
                  _Notice(text.emptyCatalog),
              ],
            ],
          ),
        ),
        for (final entry in groups.entries)
          if (entry.value.isNotEmpty) ...[
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
            SliverList.builder(
              itemCount: entry.value.length,
              itemBuilder: (context, index) {
                final chat = entry.value[index];
                return ListTile(
                  key: ValueKey((chat.kind, chat.id)),
                  dense: true,
                  enabled: !_busy && !_chatBusy,
                  onTap: () => _openChat(chat),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                  leading: Icon(switch (chat.kind) {
                    'project' => Icons.folder_outlined,
                    'bot' => Icons.smart_toy_outlined,
                    _ => Icons.groups_outlined,
                  }, size: 19),
                  title: Text(
                    chat.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: SettingsText.label,
                  ),
                  trailing: const Icon(Icons.chevron_right, size: 18),
                );
              },
            ),
          ],
        const SliverToBoxAdapter(child: SizedBox(height: 16)),
      ],
    );
  }

  Widget _host(_HostText text) => _HostCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_connection.hostName ?? text.host, style: SettingsText.title),
        const SizedBox(height: 6),
        _Notice(_online ? text.online : text.offline),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (!_online)
              FilledButton(
                onPressed: _busy
                    ? null
                    : () => _runConnection((c) => c.reconnect()),
                child: Text(text.reconnect),
              ),
            OutlinedButton(
              onPressed: _busy ? null : () => _forget(text),
              child: Text(text.forget),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _conversation(
    _HostText text,
    Widget header,
    DesktopHostChat chat,
    String? connectionError,
  ) {
    final messages = _chats.messages;
    final hasEarlier = _chats.hasEarlier;
    final error = _localChatError ?? _chats.error;
    return Column(
      key: ValueKey((chat.kind, chat.id)),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        header,
        _HostHeading(
          title: chat.title,
          tooltip: text.backToChats,
          icon: Icons.list_alt_outlined,
          onBack: _closeChat,
        ),
        if (connectionError != null) _Notice(connectionError, isError: true),
        if (_chatBusy) _Progress(text.working),
        if (error != null) _Notice(error, isError: true),
        const Divider(height: 1),
        Expanded(
          child: messages.isEmpty && !hasEarlier
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
                    final message = messages[messages.length - 1 - index];
                    return _MessageBubble(
                      message: message,
                      sender: message.mine ? text.you : message.sender,
                    );
                  },
                ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _draft,
                  minLines: 1,
                  maxLines: 3,
                  style: SettingsText.label,
                  decoration: InputDecoration(
                    labelText: text.message,
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: _draft,
                builder: (context, value, _) => FilledButton(
                  onPressed: _busy || _chatBusy || value.text.trim().isEmpty
                      ? null
                      : () => _send(chat),
                  child: Text(text.send),
                ),
              ),
            ],
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

class _HostHeading extends StatelessWidget {
  const _HostHeading({
    required this.title,
    required this.tooltip,
    required this.icon,
    required this.onBack,
  });

  final String title;
  final String tooltip;
  final IconData icon;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      IconButton(onPressed: onBack, tooltip: tooltip, icon: Icon(icon)),
      const SizedBox(width: 8),
      Expanded(
        child: Semantics(
          header: true,
          child: Text(
            title,
            style: SettingsText.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    ],
  );
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message, required this.sender});

  final DesktopHostMessage message;
  final String sender;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsetsDirectional.only(
      start: message.mine ? 24 : 0,
      end: message.mine ? 0 : 24,
      bottom: 10,
    ),
    child: Align(
      alignment: message.mine
          ? AlignmentDirectional.centerEnd
          : AlignmentDirectional.centerStart,
      child: _HostCard(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (sender.isNotEmpty) ...[
              Text(sender, style: SettingsText.heading),
              const SizedBox(height: 4),
            ],
            SelectableText(message.text, style: SettingsText.label),
          ],
        ),
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
  String get title => _zh ? '连接电脑' : 'Connect to a Host';
  String get back => _zh ? '返回' : 'Back';
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
  String get backToChats => _zh ? '返回主机会话列表' : 'Back to host chats';
  String get emptyChat => _zh ? '还没有消息。' : 'No messages yet.';
  String get earlier => _zh ? '加载更早的消息' : 'Load earlier messages';
  String get message => _zh ? '消息' : 'Message';
  String get send => _zh ? '发送' : 'Send';
  String get you => _zh ? '你' : 'You';
  String get emptyClipboard => _zh ? '剪贴板中没有文本。' : 'The clipboard has no text.';
  String get actionFailed =>
      _zh ? '操作失败，请重试。' : 'The action failed. Try again.';
}
