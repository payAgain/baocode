import 'dart:async';
import 'dart:convert';

import 'package:bao_link/bao_link.dart';
import 'package:flutter/foundation.dart' show listEquals, setEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bots/desktop_bot_editor_ui.dart';
import '../bots/desktop_bot_memory.dart';
import '../chat/chat_models.dart' show ImageAttachment;
import '../settings/pages/settings_widgets.dart' show SettingsColors;
import '../theme/app_theme.dart';
import '../workspace/window_controls.dart';

part 'desktop_remote_people_editors.dart';
part 'desktop_remote_people_wire.dart';

/// A dockable manager for the workspace on an already authenticated peer.
/// The caller owns the peer and supplies the current one on reconnection.
class DesktopRemotePeopleManager extends StatelessWidget {
  const DesktopRemotePeopleManager({
    super.key,
    required this.peer,
    this.onClose,
    this.compact = false,
    this.onCatalog,
    this.isCurrentPeer,
    this.initialBotId,
    this.initialGroupId,
    this.pickImage,
  }) : assert(initialBotId == null || initialGroupId == null);

  final LinkPeer? peer;

  /// Dismisses the dock. Also called after saving a directly opened Bot or group.
  final VoidCallback? onClose;
  final bool compact;
  final String? initialBotId;
  final String? initialGroupId;

  /// Forward explicit state replies to the existing chat catalog. The host
  /// deduplicates pushed state against the last reply on this same peer.
  /// A reply can arrive after the panel closes; ignore it unless [peer] is
  /// still the chat catalog's bound peer.
  final void Function(LinkPeer, Map<String, Object?>)? onCatalog;

  /// Guard actions during the gap between a connection change and a rebuild.
  final bool Function(LinkPeer)? isCurrentPeer;

  /// The native picker by default. The callback may supply test image bytes.
  final Future<ImageAttachment?> Function()? pickImage;

  @override
  Widget build(BuildContext context) => _BoundPeopleManager(
    key: ValueKey((peer, initialBotId, initialGroupId)),
    options: this,
  );
}

class _BoundPeopleManager extends StatefulWidget {
  const _BoundPeopleManager({required super.key, required this.options});

  final DesktopRemotePeopleManager options;

  @override
  State<_BoundPeopleManager> createState() =>
      _DesktopRemotePeopleManagerState();
}

typedef _Confirmation = ({
  String title,
  String detail,
  String action,
  IconData icon,
  double previousOffset,
  Future<void> Function(LinkPeer) run,
});

class _DesktopRemotePeopleManagerState extends State<_BoundPeopleManager> {
  StreamSubscription<LinkEvent>? _events;
  LinkPeer? _peer;
  _PeopleCatalog? _catalog;
  _PeopleDraft? _draft;
  _PeopleDraft? _returnToBot;
  _Confirmation? _confirm;
  Object? _problem;
  String? _notice;
  bool _busy = false;
  final _unsupported = <String>{};
  // A legacy host's only lead-bearing group may be cleared while the dock
  // closes. Keep capability evidence for the lifetime of its authenticated peer.
  static final _observedGroupOptions = Expando<Set<String>>();
  final _observedBotFlags = <String>{};
  final _scroll = ScrollController(keepScrollOffset: false);

  String _tr(String en, String zh) =>
      Localizations.maybeLocaleOf(context)?.languageCode == 'zh' ? zh : en;

  @override
  void initState() {
    super.initState();
    final peer = widget.options.peer;
    if (peer == null || peer.isClosed) return;
    _peer = peer;
    _events = peer.events.listen((event) {
      if (!_active(peer) || event.name != LinkEvents.state) return;
      if (event.data case final Map<String, Object?> state) {
        try {
          final catalog = _decodeCatalog(peer, state);
          setState(() => _catalog = catalog);
        } on _PeopleProblem {
          // A malformed event cannot replace the last complete catalog.
        }
      }
    });
    unawaited(
      peer.done.then((_) {
        if (!mounted || !identical(_peer, peer)) return;
        setState(() {
          _peer = null;
          _catalog = null;
          _draft = null;
          _returnToBot = null;
          _confirm = null;
          _busy = false;
          _problem = null;
          _notice = null;
        });
      }),
    );
    _busy = true;
    unawaited(
      _loadInitial(
        peer,
        widget.options.initialBotId,
        widget.options.initialGroupId,
      ),
    );
  }

  Future<void> _loadInitial(
    LinkPeer peer,
    String? botId,
    String? groupId,
  ) async {
    try {
      final catalog = await _readCatalog(peer);
      _check(peer);
      if (botId != null) {
        await _openBot(peer, _PeopleDraft.bot(catalog, botId));
      } else if (groupId != null) {
        _changeView(() => _draft = _PeopleDraft.group(catalog, groupId));
      }
    } on Object catch (error) {
      if (_active(peer)) setState(() => _problem = error);
    } finally {
      if (_active(peer)) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _peer = null;
    unawaited(_events?.cancel());
    _scroll.dispose();
    super.dispose();
  }

  bool _active(LinkPeer peer) =>
      mounted &&
      identical(_peer, peer) &&
      !peer.isClosed &&
      (widget.options.isCurrentPeer?.call(peer) ?? true);

  void _check(LinkPeer peer) {
    if (!_active(peer)) throw _PeopleProblem.stopped;
  }

  Future<Object?> _call(
    LinkPeer peer,
    String method, [
    Map<String, Object?> args = const {},
  ]) async {
    _check(peer);
    if (_unsupported.contains(method)) throw _PeopleProblem.unavailable;
    try {
      final result = await peer.call(method, args);
      // State replies are also routed to the parent catalog when this panel
      // is gone, but only that consumer may decide whether its peer is bound.
      if (method != LinkMethods.state) _check(peer);
      return result;
    } on LinkRemoteException catch (error) {
      _check(peer);
      if (error.code == 'unknown' || error.code == LinkErrors.unsupported) {
        _unsupported.add(method);
        throw _PeopleProblem.unavailable;
      }
      if (error.code == LinkErrors.notFound) throw _PeopleProblem.conflict;
      rethrow;
    }
  }

  Future<_PeopleCatalog> _readCatalog(LinkPeer peer) async {
    final forward = widget.options.onCatalog;
    final state = await _call(peer, LinkMethods.state);
    if (state is! Map<String, Object?>) throw _PeopleProblem.unavailable;
    if (!_active(peer)) {
      if (!peer.isClosed && state['device'] is Map<String, Object?>) {
        forward?.call(peer, state);
      }
      throw _PeopleProblem.stopped;
    }
    final catalog = _decodeCatalog(peer, state);
    setState(() => _catalog = catalog);
    forward?.call(peer, state);
    _check(peer);
    return catalog;
  }

  _PeopleCatalog _decodeCatalog(LinkPeer peer, Map<String, Object?> state) =>
      _PeopleCatalog(
        state,
        observedGroupOptions: _observedGroupOptions[peer] ??= <String>{},
        observedBotFlags: _observedBotFlags,
      );

  Future<void> _run(Future<void> Function(LinkPeer) action) async {
    final peer = _peer;
    if (_busy || peer == null || !_active(peer)) return;
    setState(() {
      _busy = true;
      _confirm = null;
      _problem = null;
      _notice = null;
    });
    try {
      await action(peer);
    } on Object catch (error) {
      if (_active(peer)) setState(() => _problem = error);
    } finally {
      if (_active(peer)) setState(() => _busy = false);
    }
  }

  void _changeView(VoidCallback change) {
    if (_scroll.hasClients) _scroll.jumpTo(0);
    setState(() {
      _problem = null;
      _notice = null;
      change();
    });
  }

  void _edit(VoidCallback change) => setState(change);

  void _close() {
    final close = widget.options.onClose;
    if (close == null) return;
    _peer = null;
    unawaited(_events?.cancel());
    _events = null;
    close();
  }

  void _back() => _changeView(() {
    if (_draft?.kind == _PeopleKind.memory) {
      _draft = _returnToBot;
      _returnToBot = null;
    } else {
      _draft = null;
    }
  });

  void _cancelReview() {
    final review = _confirm;
    if (review == null) return;
    final draft = _draft;
    _changeView(() => _confirm = null);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !identical(_draft, draft) ||
          _confirm != null ||
          !_scroll.hasClients) {
        return;
      }
      _scroll.jumpTo(
        review.previousOffset.clamp(0.0, _scroll.position.maxScrollExtent),
      );
    });
  }

  Future<void> _openBot(LinkPeer peer, _PeopleDraft draft) async {
    _check(peer);
    _changeView(() => _draft = draft);
    if (!isAvatarImage(_text(draft.base, 'avatar'))) return;
    try {
      final reply = await _call(peer, LinkMethods.botAvatar, {'bot': draft.id});
      _check(peer);
      setState(() => draft.hostPicture = _decodePicture(reply));
    } on Object {
      // Keep the advertised token on save even if preview is unavailable.
      _check(peer);
    }
  }

  Future<Map<String, Object?>> _readMemory(LinkPeer peer, String id) async {
    final reply = await _call(peer, LinkMethods.botMemory, {'bot': id});
    if (reply case final Map<String, Object?> data
        when data['text'] is String) {
      return data;
    }
    throw _PeopleProblem.unavailable;
  }

  Future<void> _openStructuredMemory(_PeopleDraft bot) async {
    final peer = _peer;
    final catalog = _catalog;
    if (peer == null || catalog == null || bot.id == null || !_active(peer)) {
      return;
    }
    await showDesktopBotMemory(
      context,
      botId: bot.id!,
      name: bot.name,
      groups: {
        for (final group in catalog.groupRows.entries)
          if (_stringList(group.value['members'])?.contains(bot.id) == true)
            group.key: _text(group.value, 'name'),
      },
      methods: catalog.botMemoryOptions,
      call: (method, args) async {
        final result = await _call(peer, method, args);
        if (result is! Map<String, Object?>) throw _PeopleProblem.unavailable;
        return result;
      },
    );
  }

  Future<void> _openMemory(LinkPeer peer, _PeopleDraft bot) async {
    final memory = await _readMemory(peer, bot.id!);
    _check(peer);
    _changeView(() {
      _returnToBot = bot;
      _draft = _PeopleDraft.memory(bot.id!, memory);
    });
  }

  Future<void> _saveMemory(
    LinkPeer peer,
    _PeopleDraft draft,
    String key,
  ) async {
    final value = draft.text[key]!.trim();
    final id = draft.id!;
    final latest = await _readMemory(peer, id);
    if (latest[key] is! String) throw _PeopleProblem.unavailable;
    if (_merge(draft.base[key], latest[key], value) != value) {
      throw _PeopleProblem.conflict;
    }
    await _call(
      peer,
      key == 'text' ? LinkMethods.setBotMemory : LinkMethods.setBotSelf,
      {'bot': id, 'text': value},
    );
    final confirmed = await _verify(() => _readMemory(peer, id));
    if (confirmed[key] != value) {
      throw _PeopleProblem.unconfirmed;
    }
    _check(peer);
    setState(() {
      draft.base = {...draft.base, key: confirmed[key]};
      draft.text[key] = confirmed[key] as String;
      _notice = _tr('Saved on the host.', '已保存到主机。');
    });
  }

  Future<T> _verify<T>(Future<T> Function() read) async {
    try {
      return await read();
    } on Object {
      throw _PeopleProblem.unconfirmed;
    }
  }

  Future<void> _saveEntry(LinkPeer peer, _PeopleDraft draft) async {
    final bot = draft.kind == _PeopleKind.bot;
    final key = bot ? 'bot' : 'group';
    final latest = await _readCatalog(peer);
    final params = bot ? draft.botParams(latest) : draft.groupParams(latest);
    final Object? result;
    try {
      result = await _call(
        peer,
        bot ? LinkMethods.saveBot : LinkMethods.saveGroup,
        params,
      );
    } on TimeoutException {
      // The host might have created the entry even if its reply was lost.
      if (_active(peer)) _changeView(() => _draft = null);
      rethrow;
    }
    // Once accepted, show the catalog even if verifying the write fails.
    // An acknowledged create must never remain ready to submit a duplicate.
    _check(peer);
    _changeView(() => _draft = null);
    final entity = result is Map<String, Object?> ? result[key] : null;
    final id = entity is Map<String, Object?> ? entity['id'] : null;
    final catalog = await _verify(() => _readCatalog(peer));
    final saved = (bot ? catalog.botRows : catalog.groupRows)[id];
    if (saved == null ||
        id is! String ||
        (draft.id != null && draft.id != id) ||
        !_entrySaved(bot, saved, params)) {
      throw _PeopleProblem.unconfirmed;
    }
    if (params['avatarImage'] case final Map<String, Object?> picture) {
      final reply = await _verify(
        () => _call(peer, LinkMethods.botAvatar, {'bot': id}),
      );
      if (reply is! Map<String, Object?> ||
          reply['data'] != picture['data'] ||
          reply['type'] != picture['type']) {
        throw _PeopleProblem.unconfirmed;
      }
    }
    _check(peer);
    if (draft.id != null &&
        (bot ? widget.options.initialBotId : widget.options.initialGroupId) ==
            draft.id &&
        widget.options.onClose != null) {
      _close();
      return;
    }
    setState(() => _notice = _tr('Saved on the host.', '已保存到主机。'));
  }

  bool _entrySaved(
    bool bot,
    Map<String, Object?> saved,
    Map<String, Object?> sent,
  ) {
    if (saved['name'] != sent['name']) return false;
    if (!bot) {
      if (!listEquals(
        _stringList(saved['members']),
        sent['members'] as List<String>,
      )) {
        return false;
      }
      return _groupOptions.every(
            (key) =>
                !sent.containsKey(key) || _groupValue(saved, key) == sent[key],
          ) &&
          (!sent.containsKey(_leadOption) ||
              saved[_leadOption] == sent[_leadOption]);
    }
    if (!_validBotSettings(saved) ||
        !_botText.every(
          (key) => !sent.containsKey(key) || _text(saved, key) == sent[key],
        )) {
      return false;
    }
    if (!_botFlags.every(
      (key) => !sent.containsKey(key) || _flag(saved, key) == sent[key],
    )) {
      return false;
    }
    if (!setEquals(
      _stringList(saved['abilities'])?.toSet(),
      (sent['abilities'] as List<String>).toSet(),
    )) {
      return false;
    }
    final schedule = sent['proactive'] as Map<String, Object?>;
    if (!_proactiveFields.every(
      (key) => _proactive(saved)[key] == schedule[key],
    )) {
      return false;
    }
    if (sent.containsKey('avatarImage')) {
      return isAvatarImage(_text(saved, 'avatar'));
    }
    return _text(saved, 'avatar') == (sent['avatar'] ?? '');
  }

  Future<void> _remove(
    LinkPeer peer,
    _PeopleDraft draft, {
    bool clearChat = false,
  }) async {
    final bot = draft.kind == _PeopleKind.bot;
    final id = draft.id!;
    final fresh = await _readCatalog(peer);
    final row = (bot ? fresh.botRows : fresh.groupRows)[id];
    if (row == null ||
        row['name'] != draft.base['name'] ||
        (clearChat && row['session'] != draft.base['session'])) {
      throw _PeopleProblem.conflict;
    }
    if (bot && !clearChat && (id == 'assistant' || row['assistant'] == true)) {
      throw _PeopleProblem.unavailable;
    }
    final method = clearChat
        ? LinkMethods.clearBotChat
        : bot
        ? LinkMethods.deleteBot
        : LinkMethods.deleteGroup;
    await _call(peer, method, {(bot ? 'bot' : 'group'): id});
    _check(peer);
    _changeView(() => _draft = null);
    final catalog = await _verify(() => _readCatalog(peer));
    final actual = (bot ? catalog.botRows : catalog.groupRows)[id];
    final session = actual?['session'];
    if (clearChat
        ? session is! String || session == row['session']
        : actual != null) {
      throw _PeopleProblem.unconfirmed;
    }
    _check(peer);
    setState(
      () => _notice = clearChat
          ? _tr('Chat cleared on the host.', '已清空主机上的聊天。')
          : _tr('Deleted on the host.', '已从主机删除。'),
    );
  }

  Future<void> _replaceProfile(LinkPeer peer, _PeopleDraft draft) async {
    final latest = await _readCatalog(peer);
    if (!latest.hasBots) throw _PeopleProblem.unavailable;
    await _call(peer, LinkMethods.setMe, draft.profile);
    _check(peer);
    _changeView(() => _draft = null);
    setState(
      () => _notice = _tr(
        'The host accepted the profile replacement.',
        '主机已接受资料替换。',
      ),
    );
  }

  Future<void> _pick(LinkPeer peer, _PeopleDraft draft) async {
    final picker = widget.options.pickImage;
    final ImageAttachment? picture;
    if (picker != null) {
      picture = await picker();
    } else {
      final paths = await WindowControls.pickOpenFiles(multiple: false);
      _check(peer);
      if (paths.isEmpty) return;
      picture = await WindowControls.readImageFile(paths.first);
      if (picture == null) throw _PeopleProblem.badPicture;
    }
    _check(peer);
    if (picture == null) return;
    if (!_validPicture(picture)) throw _PeopleProblem.badPicture;
    setState(() {
      draft.replaceAvatar = true;
      draft.pickedPicture = picture;
    });
  }

  String _errorText(Object problem) => switch (problem) {
    _PeopleProblem.offline ||
    _PeopleProblem.stopped => _tr('Host offline.', '主机离线。'),
    _PeopleProblem.unavailable => _tr(
      'This host does not provide this setting.',
      '此主机不提供此设置。',
    ),
    _PeopleProblem.conflict => _tr(
      'Settings changed on the host. Reopen the editor to try again.',
      '主机上的设置已更改，请重新打开编辑器后重试。',
    ),
    _PeopleProblem.invalid => _tr(
      'Check the required fields and number ranges.',
      '请检查必填项和数字范围。',
    ),
    _PeopleProblem.badPicture => _tr(
      'Choose a PNG, JPEG, GIF or WebP image up to 1 MiB.',
      '请选择不超过 1 MiB 的 PNG、JPEG、GIF 或 WebP 图片。',
    ),
    _PeopleProblem.unconfirmed || TimeoutException() => _tr(
      'The host did not confirm the result. Check the host before retrying.',
      '主机未确认操作结果，请在重试前检查主机。',
    ),
    _ => _tr('The host action failed.', '主机操作失败。'),
  };

  @override
  Widget build(BuildContext context) => Material(
    key: const ValueKey('desktop-remote-people-manager'),
    color: AppColors.conversationSurface,
    child: _buildView(),
  );

  Widget _editor({
    required String title,
    required IconData icon,
    required Widget body,
    String? name,
    Widget? avatar,
    Widget? actions,
    bool warning = false,
  }) {
    final problem = _problem;
    final notice = _notice;
    return BotEditorLayout(
      title: title,
      name: name,
      icon: icon,
      avatar: avatar,
      body: body,
      actions: actions,
      controller: _scroll,
      busy: _busy,
      warning: warning,
      close: widget.options.onClose == null
          ? null
          : IconButton(
              style: botToolbarIconButtonStyle(context),
              tooltip: widget.options.compact
                  ? _tr('Back to workspace', '返回工作区')
                  : _tr('Close settings', '关闭设置'),
              onPressed: _close,
              icon: Icon(
                widget.options.compact ? Icons.arrow_back : Icons.close,
                size: 18,
              ),
            ),
      status: problem == null && notice == null
          ? null
          : Semantics(
              liveRegion: true,
              child: BotEditorNotice(
                message: problem == null ? notice! : _errorText(problem),
                tone: problem == null
                    ? BotEditorTone.accent
                    : BotEditorTone.danger,
              ),
            ),
    );
  }

  Widget _buildView() {
    final catalog = _catalog;
    final editor = _PeopleEditors(this);
    if (_peer == null || catalog == null) {
      return _catalogView(switch ((_peer, _busy)) {
        (null, _) => BotEditorNotice(
          message: _errorText(_PeopleProblem.offline),
          tone: BotEditorTone.warning,
        ),
        (_, true) => BotEditorSection(
          title: _tr('Status', '连接状态'),
          children: [
            Row(
              children: [
                const SizedBox.square(
                  dimension: 15,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _tr('Loading host settings…', '正在加载主机设置…'),
                    style: TextStyle(
                      fontSize: 13,
                      color: SettingsColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        _ => BotEditorSection(
          title: _tr('Status', '连接状态'),
          children: [
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: OutlinedButton.icon(
                style: botEditorOutlinedButtonStyle(context),
                onPressed: () => _run((peer) async {
                  await _readCatalog(peer);
                }),
                icon: const Icon(Icons.refresh, size: 16),
                label: Text(_tr('Refresh', '刷新')),
              ),
            ),
          ],
        ),
      });
    }
    if (_confirm case final review?) {
      return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _cancelReview,
        },
        child: FocusScope(
          child: _editor(
            title: _tr('Review change', '确认操作'),
            icon: review.icon,
            warning: true,
            body: BotEditorSection(
              title: review.title,
              danger: true,
              children: [
                Text(
                  review.detail,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    color: SettingsColors.textSecondary,
                  ),
                ),
                BotEditorActions(
                  children: [
                    OutlinedButton(
                      autofocus: true,
                      style: botEditorOutlinedButtonStyle(context),
                      onPressed: _cancelReview,
                      child: Text(_tr('Cancel', '取消')),
                    ),
                    FilledButton(
                      style: botEditorButtonStyle(context, destructive: true),
                      onPressed: () => _run(review.run),
                      child: Text(review.action),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }
    if (_draft case final draft?) {
      return KeyedSubtree(
        key: ObjectKey(draft),
        child: editor.buildDraft(draft, catalog),
      );
    }
    return _catalogView(editor.list(catalog));
  }

  Widget _catalogView(Widget body) => _editor(
    title: _tr('Bots, groups & profile', '机器人、群聊和资料'),
    icon: Icons.people_outline,
    body: body,
  );
}

Widget _section(List<Widget> children) => Column(
  crossAxisAlignment: CrossAxisAlignment.stretch,
  children: [
    for (final widget in children)
      Padding(padding: const EdgeInsets.only(bottom: 10), child: widget),
  ],
);
