import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:bao_link/bao_link.dart';
import 'package:bao_markdown/bao_markdown.dart';
import 'package:flutter/foundation.dart';

import '../chat/chat_models.dart';
import 'chat_codec.dart';
import 'desktop_host_project_history_feed.dart';
import 'desktop_host_session_controls.dart';
import 'desktop_remote_media.dart';
import 'desktop_remote_media_preview.dart';
import 'desktop_remote_session_actions_snapshot.dart';

class DesktopHostChat {
  const DesktopHostChat({
    required this.id,
    required this.title,
    required this.kind,
    this.projectId,
    this.updatedAt,
    this.pinned = false,
    this.provisional = false,
    this.status = LinkSessionStatus.idle,
    this.unread = 0,
  });

  final String id;
  final String title;
  final String kind;
  final String? projectId;
  final DateTime? updatedAt;
  final bool pinned;
  final bool provisional;
  final LinkSessionStatus status;
  final int unread;

  (String, String) get _key => (kind, id);
}

class DesktopHostMessage {
  const DesktopHostMessage({
    required this.text,
    required this.sender,
    required this.mine,
    this.images = const [],
    this.groupReplyTarget,
    this.groupReference,
  });

  final String text;
  final String sender;
  final bool mine;
  final List<DesktopRemoteImage> images;
  final DesktopHostGroupQuote? groupReplyTarget;
  final ({int sequence, DesktopHostGroupQuote? target})? groupReference;
}

class DesktopHostGroupQuote {
  const DesktopHostGroupQuote._(
    this._follow, {
    required this.sequence,
    required this.sender,
    required this.mine,
    required this.preview,
    required this.hasImage,
  });

  final Object _follow;
  final int sequence;
  final String sender;
  final bool mine;
  final String preview;
  final bool hasImage;
}

/// The paired desktop's catalog and one open chat, over its existing link.
/// The caller owns the peer. A new peer with the same authenticated identity
/// restores selection, and [reset] also forgets the selection and catalog.
class DesktopHostChats extends ChangeNotifier {
  DesktopHostChats({this.onCatalog});
  final void Function(LinkPeer, LinkState)? onCatalog;
  static const _pageSize = 50;
  static const _uncertain =
      'The host did not confirm delivery. Check the conversation before sending again.';
  static const _attachment = '[Attachment]';
  static const _approval =
      'Continue on the host to answer the pending request.';
  static const _systemNotes =
      'system-reminder|bao-event|task-notification|local-command-caveat';
  static final _hiddenNotes = RegExp(
    '<($_systemNotes)\\b[^>]*>.*?(?:</\\1>|\$)',
    dotAll: true,
  );

  LinkPeer? _peer;
  StreamSubscription<LinkEvent>? _events;
  Object? _binding;
  String? _host;
  bool _disposed = false;
  bool _loadingState = false;
  bool _stateEventSeen = false;
  String? _stateError;
  List<ProjectInfo> _projects = const [];
  List<ProjectInfo> get projects => _projects;
  List<DesktopHostChat> _chats = const [];
  Map<String, String?> _botSessions = const {};
  Map<String, String> _botNames = const {};
  DesktopHostChat? _selected;
  _HostView? _view;
  DesktopHostChat? _unlistedDraft;
  Object? _creating;
  final _controls = Expando<DesktopHostSessionControls>();
  _PendingSend? _sending;
  final Map<(String, String), String> _sendErrors = {};

  List<DesktopHostChat> get chats => _chats;
  DesktopHostChat? get selected => _selected;
  DesktopHostSessionControls? get sessionControls => switch (_view) {
    final view? when view.ready && !view.opening => _controls[view],
    _ => null,
  };
  List<DesktopHostMessage> get messages => _view?.messages ?? const [];

  DesktopHostGroupQuote? get groupReply => _view?.groupReply;

  void selectGroupReply(
    LinkPeer? peer,
    DesktopHostChat chat,
    DesktopHostGroupQuote reply, {
    bool cancel = false,
  }) {
    if (busy || !isCurrentConversation(peer, chat)) return;
    final view = _view!;
    if (!view.group ||
        !identical(reply._follow, view.groupIdentity) ||
        (cancel && !identical(view.groupReply, reply))) {
      return;
    }
    view.groupReply = cancel ? null : reply;
    notifyListeners();
  }

  /// Match a captured authenticated conversation, even between UI rebuilds.
  bool isCurrentConversation(LinkPeer? peer, DesktopHostChat chat) {
    final view = _view;
    final selected = _selected;
    return peer != null &&
        !peer.isClosed &&
        identical(_peer, peer) &&
        view != null &&
        identical(view.peer, peer) &&
        view.ready &&
        !view.opening &&
        selected?.kind == chat.kind &&
        selected?.id == chat.id &&
        selected?.projectId == chat.projectId;
  }

  /// Identity of the currently followed project view that may switch branches.
  /// A close/reopen of the same conversation gets a new identity.
  Object? projectBranchView(LinkPeer? peer, DesktopHostChat chat) {
    if (chat.kind != 'project' ||
        !isCurrentConversation(peer, chat) ||
        !_projects.any((p) => p.id == chat.projectId && p.canSwitchBranch)) {
      return null;
    }
    return _view;
  }

  bool get hasEarlier => _view?.hasEarlier ?? false;
  bool get busy =>
      _loadingState ||
      _sending != null ||
      (_view?.opening ?? false) ||
      (_view?.paging ?? false);
  String? get error =>
      _sendErrors[_selected?._key] ??
      _view?.error ??
      _stateError ??
      (_view?.interaction == true &&
              !(_selected?.kind == 'project' &&
                  decodeRemoteInteraction(_view?.actionState['interaction']) !=
                      null)
          ? _approval
          : null) ??
      (_selected != null && _view == null && _peer != null && !_loadingState
          ? 'The conversation is not currently available on the host.'
          : null);

  void bind(LinkPeer? peer) {
    if (_disposed) return;
    if (peer?.isClosed == true) peer = null;
    if (identical(_peer, peer)) return;
    final host = peer?.remote;
    if (host != null && _host != null && host != _host) {
      _forget();
    } else {
      _disconnect();
    }
    _peer = peer;
    if (peer != null) {
      _host = host;
      _loadingState = true;
      final current = peer;
      final binding = _binding = Object();
      _events = current.events.listen((event) {
        if (!identical(_binding, binding)) return;
        _onEvent(current, event);
      });
      unawaited(
        current.done.then((_) {
          if (identical(_binding, binding)) bind(null);
        }),
      );
      unawaited(_requestState(current, binding));
    }
    notifyListeners();
  }

  void reset() {
    if (_disposed) return;
    _forget();
    notifyListeners();
  }

  void _forget() {
    _disconnect();
    _host = null;
    _unlistedDraft = null;
    _selected = null;
    _projects = const [];
    _chats = const [];
    _botSessions = const {};
    _botNames = const {};
    _sendErrors.clear();
  }

  void _disconnect() {
    _closeView();
    _binding = null;
    _creating = null;
    _peer = null;
    unawaited(_events?.cancel());
    _events = null;
    _loadingState = false;
    _stateEventSeen = false;
    _stateError = null;
    if (_sending case final pending?) {
      if (pending.submitted) _sendErrors[pending.chat] = _uncertain;
      _sending = null;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _forget();
    super.dispose();
  }

  Future<void> _requestState(LinkPeer peer, Object binding) async {
    try {
      final result = await peer.call(LinkMethods.state);
      if (identical(_binding, binding) && !_stateEventSeen) {
        _applyState(peer, result);
      }
    } on Object {
      if (identical(_binding, binding) && !_stateEventSeen) {
        _loadingState = false;
        _stateError = 'Could not load the host’s conversations.';
        notifyListeners();
      }
    }
  }

  /// Explicit state reads also advance the host's push deduplication, so a
  /// child of the remote workspace must forward the reply to the catalog.
  void acceptCatalogReply(LinkPeer peer, Map<String, Object?> state) {
    if (_disposed || !identical(_peer, peer) || peer.isClosed) return;
    try {
      // Like a state event, this supersedes the initial bind request.
      _applyState(peer, state, pushed: true);
    } on Object {
      // Leave the last usable catalog in place after a malformed reply.
    }
  }

  void _applyState(LinkPeer peer, Object? data, {bool pushed = false}) {
    if (data is! Map<String, Object?> || !data.containsKey('device')) {
      throw const FormatException('Invalid host state');
    }
    final state = LinkState.fromJson(data);
    onCatalog?.call(peer, state);
    if (pushed) _stateEventSeen = true;
    final oldBotSessions = _botSessions;
    _botSessions = {for (final bot in state.bots) bot.id: bot.session};
    _botNames = {for (final bot in state.bots) bot.id: bot.name};
    final botIds = _botSessions.values.toSet();
    _projects = List.unmodifiable(state.projects);
    final projects = state.projects.map((project) => project.id).toSet();
    final entries = <(String, String), DesktopHostChat>{};
    void add(
      String kind,
      String id,
      String title, {
      String? projectId,
      DateTime? updatedAt,
      bool pinned = false,
      LinkSessionStatus status = LinkSessionStatus.idle,
      int unread = 0,
    }) {
      if (id.isEmpty) return;
      entries[(kind, id)] = DesktopHostChat(
        id: id,
        title: title.isEmpty ? id : title,
        kind: kind,
        projectId: projectId,
        updatedAt: updatedAt,
        pinned: pinned,
        status: status,
        unread: unread,
      );
    }

    for (final session in state.sessions) {
      if (projects.contains(session.project) && !botIds.contains(session.id)) {
        add(
          'project',
          session.id,
          session.title,
          projectId: session.project,
          pinned: session.pinned,
          status: session.status,
          unread: session.unread ? 1 : 0,
          updatedAt: session.updatedAt.millisecondsSinceEpoch > 0
              ? session.updatedAt
              : null,
        );
      }
    }
    for (final bot in state.bots) {
      add(
        'bot',
        bot.id,
        bot.name,
        status: bot.status == BotStatus.typing
            ? LinkSessionStatus.running
            : LinkSessionStatus.idle,
        unread: bot.unread,
        updatedAt: bot.updatedAt,
      );
    }
    for (final group in state.groups) {
      add(
        'group',
        group.id,
        group.name,
        status: group.typing.isNotEmpty
            ? LinkSessionStatus.running
            : LinkSessionStatus.idle,
        unread: group.unread,
        updatedAt: group.updatedAt,
      );
    }
    // The host deliberately omits an untouched draft until the first send.
    if (_unlistedDraft case final draft?) {
      if (entries.containsKey(draft._key) ||
          !projects.contains(draft.projectId) ||
          botIds.contains(draft.id)) {
        _unlistedDraft = null;
      } else if (_selected?._key == draft._key) {
        entries[draft._key] = draft;
      }
    }
    _chats = List.unmodifiable(entries.values);
    _loadingState = false;
    _stateError = null;
    if (_selected case final selected?) {
      final match = entries[selected._key];
      if (match != null) {
        _selected = match;
        // A cold bot can get its session from a send acknowledgment before
        // the catalog announces it. Keep that follow if the link still says
        // nothing about a change to the bot's session.
        final target =
            match.kind == 'bot' &&
                oldBotSessions[match.id] == _botSessions[match.id] &&
                _view != null
            ? _view!.target
            : _target(match);
        if (_view == null || _view!.target != target) {
          unawaited(_openView(peer, match, target));
          return;
        } else {
          _render(_view!, match);
        }
      } else if (_view != null) {
        _closeView();
        _selected = null;
      }
    }
    notifyListeners();
  }

  String? _target(DesktopHostChat chat) =>
      chat.kind == 'bot' ? _botSessions[chat.id] : chat.id;

  Future<void> createInProject(String projectId, String placeholder) async {
    final peer = _peer;
    if (peer == null ||
        peer.isClosed ||
        busy ||
        _creating != null ||
        !_projects.any((p) => p.id == projectId)) {
      return;
    }
    final request = _creating = Object();
    try {
      final result = await peer.call(LinkMethods.draft, {'project': projectId});
      if (!identical(request, _creating) ||
          !identical(peer, _peer) ||
          !_projects.any((p) => p.id == projectId)) {
        return;
      }
      if (result case {'session': final String id} when id.isNotEmpty) {
        final existing = _chats
            .where(
              (c) =>
                  c.kind == 'project' && c.id == id && c.projectId == projectId,
            )
            .firstOrNull;
        final chat =
            existing ??
            DesktopHostChat(
              id: id,
              kind: 'project',
              projectId: projectId,
              title: placeholder,
              provisional: true,
            );
        if (existing == null) {
          final old = _unlistedDraft;
          _unlistedDraft = chat;
          _chats = List.unmodifiable([
            ..._chats.where((c) => !identical(c, old)),
            chat,
          ]);
        }
        await open(chat);
      } else {
        throw const FormatException('Missing host session');
      }
    } finally {
      if (identical(_creating, request)) _creating = null;
    }
  }

  Future<void> open(DesktopHostChat chat) async {
    final peer = _peer;
    final current = _chats
        .where((entry) => entry._key == chat._key)
        .firstOrNull;
    if (peer == null || _loadingState || current == null) return;
    final same = _selected?._key == current._key ? _view : null;
    if (same != null && (same.opening || same.ready)) return;
    _selected = current;
    await _openView(peer, current, same?.target ?? _target(current));
  }

  void closeChat() {
    _creating = null;
    _closeView();
    _selected = null;
    notifyListeners();
  }

  void _closeView() {
    final view = _view;
    _view = null;
    _projectHistories[this] = null;
    if (view?.target == null || view!.peer.isClosed) return;
    unawaited(
      view.peer
          .call(
            view.group ? LinkMethods.closeGroup : LinkMethods.close,
            view.params,
          )
          .then<void>((_) {}, onError: (Object _) {}),
    );
  }

  Future<void> _openView(
    LinkPeer peer,
    DesktopHostChat chat,
    String? target,
  ) async {
    _closeView();
    final view = _view = _HostView(peer, target, group: chat.kind == 'group');
    if (chat.kind == 'project') {
      _projectHistories[this] = view.history = DesktopHostProjectHistoryFeed(
        earlier: () async {
          if (identical(_view, view) && !busy) await earlier();
        },
        paging: () => view.paging,
      );
    }
    view.opening = target != null;
    notifyListeners();
    if (target == null || !identical(_view, view)) return;
    try {
      final response = await peer.call(
        view.group ? LinkMethods.openGroup : LinkMethods.open,
        {
          ...view.params,
          if (view.group)
            'count': _pageSize
          else ...{
            'window': _pageSize,
            'have': const <String>[],
          },
        },
      );
      if (!identical(_view, view)) return;
      if (response is! Map<String, Object?>) {
        throw const FormatException('Invalid history');
      }
      if (view.group) {
        if (!_mergeGroup(view, response)) {
          throw const FormatException('Invalid group history');
        }
        view.hasEarlier = response['more'] == true;
      } else {
        if (response['session'] != target ||
            response['start'] != 0 ||
            !_applySession(view, response)) {
          throw const FormatException('Invalid session history');
        }
        view.mirror?.opened(response);
      }
      view.ready = true;
      _render(view, _selected!);
    } on Object {
      if (identical(_view, view)) {
        view.error = 'Could not open the conversation.';
      }
    } finally {
      if (identical(_view, view)) {
        view.opening = false;
        notifyListeners();
      }
    }
  }

  Future<void> earlier() async {
    final view = _view;
    if (view == null ||
        view.opening ||
        !view.ready ||
        view.paging ||
        !view.hasEarlier) {
      return;
    }
    final before = view.group ? view.groupItems.firstKey() : null;
    if (view.group && before == null) return;
    view.paging = true;
    view.error = null;
    notifyListeners();
    if (!identical(view, _view)) return;
    try {
      final reply = await view.peer.call(
        view.group ? LinkMethods.earlierGroup : LinkMethods.earlier,
        {...view.params, 'count': _pageSize, 'before': ?before},
      );
      if (!identical(view, _view)) return;
      if (reply is! Map<String, Object?>) {
        throw const FormatException('Invalid earlier history');
      }
      if (view.group) {
        if (!_mergeGroup(view, reply)) {
          throw const FormatException('Invalid group history');
        }
        view.hasEarlier = reply['more'] == true;
      } else if (reply['items'] is! List<Object?>) {
        throw const FormatException('Invalid earlier history');
      } else if (view.mirror case final mirror?) {
        mirror.earlier(view.target!, reply['items']! as List<Object?>);
        _prepend(view, reply);
      }
      // A peer with a mirror announces earlier pages in wire order.
      _render(view, _selected!);
    } on Object {
      if (identical(view, _view)) {
        view.error = 'Could not load earlier messages.';
      }
    } finally {
      if (identical(view, _view)) {
        view.paging = false;
        notifyListeners();
      }
    }
  }

  Future<void> send(String text) async {
    await _send(text);
  }

  Future<bool> sendWithAttachments(
    String text,
    DesktopRemoteAttachments attachments,
  ) => _send(text, attachments);

  Future<bool> _send(
    String text, [
    DesktopRemoteAttachments? attachments,
  ]) async {
    text = text.trim();
    final chat = _selected;
    final view = _view;
    if ((text.isEmpty && (attachments?.images.isEmpty ?? true)) ||
        busy ||
        chat == null ||
        view == null ||
        view.peer.isClosed ||
        !view.ready ||
        view.interaction) {
      return false;
    }
    final target = (view.peer, chat.kind, chat.id, chat.projectId);
    final images = attachments?.images ?? const <DesktopRemotePickedImage>[];
    final approved = attachments?.mentions ?? const <DesktopRemoteMention>[];
    if ((attachments != null && attachments.target != target) ||
        approved.any((mention) => mention.target != target) ||
        (view.group && approved.isNotEmpty) ||
        images.any((image) => image.target != target) ||
        images.length > remoteAttachmentCount ||
        images.fold<int>(0, (sum, image) => sum + image.size) >
            remoteAttachmentLimit) {
      return false;
    }
    final mentions = remoteMentionsIn(text, target, approved);
    final reply = view.groupReply;
    final pending = _sending = _PendingSend(chat._key);
    final coldBot = view.target == null;
    _sendErrors.remove(chat._key);
    view.error = null;
    notifyListeners();
    try {
      if (!identical(_sending, pending) || !identical(_view, view)) {
        return false;
      }
      pending.submitted = true;
      final result = await view.peer.call(
        view.group ? LinkMethods.sendGroup : LinkMethods.send,
        {
          if (coldBot) 'bot': chat.id else ...view.params,
          'text': text,
          'id': base64Url.encode(randomBytes(16)),
          if (reply != null) 'ref': reply.sequence,
          if (images.isNotEmpty)
            'images': [for (final image in images) image.toWire()],
          if (mentions.isNotEmpty)
            'mentions': [for (final mention in mentions) mention.path],
        },
      );
      if (!identical(_sending, pending)) return false;
      if (view.group) {
        if (result case {'seq': final int seq}
            when seq > (reply?.sequence ?? 0)) {
          if (!identical(_view, view)) return false;
          view.groupReply = null;
          return true;
        }
      } else if (result case {'session': final String id} when id.isNotEmpty) {
        if (coldBot) {
          if (identical(_view, view)) {
            // The message is confirmed even if following its new session
            // subsequently fails or the link drops while loading it.
            _sending = null;
            await _openView(view.peer, _selected!, id);
            return identical(view.peer, _peer) && _selected?._key == chat._key;
          }
          return false;
        }
        if (id == view.target) return identical(_view, view);
      }
      _sendErrors[chat._key] = _uncertain;
    } on LinkRemoteException catch (exception) {
      if (identical(_sending, pending)) {
        // The generic failure can also mean that the host's response failed
        // after taking the message. Known rejections are safe to retry.
        _sendErrors[chat._key] = exception.code == 'failed'
            ? _uncertain
            : 'The host rejected the message: ${exception.message}';
      }
    } on Object {
      if (identical(_sending, pending)) _sendErrors[chat._key] = _uncertain;
    } finally {
      if (identical(_sending, pending)) {
        _sending = null;
        notifyListeners();
      }
    }
    return false;
  }

  void _onEvent(LinkPeer peer, LinkEvent event) {
    if (event.name == LinkEvents.state) {
      try {
        _applyState(peer, event.data, pushed: true);
      } on Object {
        // A malformed push cannot replace the last usable catalog.
      }
      return;
    }
    final view = _view;
    final chat = _selected;
    final data = event.data;
    if (view == null ||
        chat == null ||
        view.target == null ||
        data is! Map<String, Object?>) {
      return;
    }
    if (view.group) {
      if (event.name != LinkEvents.group ||
          data['group'] != view.target ||
          !_mergeGroup(view, data)) {
        return;
      }
      if (!view.ready) return;
    } else {
      if (data['session'] != view.target || !view.ready) return;
      switch (event.name) {
        case LinkEvents.session:
          final mirror = view.mirror;
          final update = mirror == null ? data : mirror.apply(data);
          if (update == null || !_applySession(view, update)) {
            unawaited(_openView(peer, chat, view.target));
            return;
          }
        case LinkEvents.earlier:
          if (!view.paging || peer.mirror == null) return;
          _prepend(view, data);
        case LinkEvents.resync:
          unawaited(_openView(peer, chat, view.target));
          return;
        default:
          return;
      }
    }
    _render(view, chat);
    notifyListeners();
  }

  bool _applySession(_HostView view, Map<String, Object?> update) {
    if (update
        case {
          'start': final int start,
          'count': final int count,
          'items': final List<Object?> tail,
        }
        when start >= 0 &&
            start <= view.sessionItems.length &&
            start + tail.length == count) {
      view.sessionItems = [...view.sessionItems.take(start), ...tail];
      view.history?.replaceTail(start, tail.map(_projectItem));
      view.live = switch (update['live']) {
        final bool live => live,
        _ => switch (view.sessionItems.lastOrNull) {
          {'t': 'live'} => true,
          _ => false,
        },
      };
      view.hasEarlier = update['earlier'] == true;
      view.interaction = update['interaction'] != null;
      view.actionState = {
        'session': update['session'],
        'tasks': update['tasks'],
        'changes': update['changes'],
        'interaction': update['interaction'],
        'goal': update['goal'],
        'quota': update['quota'],
        'actions': update['actions'],
      };
      final controls = _controls[view] ??= DesktopHostSessionControls(
        peer: view.peer,
        session: view.target!,
        kind: _selected!.kind,
        isCurrent: () => identical(_view, view) && view.ready && !view.opening,
        onChanged: notifyListeners,
      );
      controls.apply(update);
      return true;
    }
    return false;
  }

  void _prepend(_HostView view, Map<String, Object?> data) {
    if (data['items'] case final List<Object?> items) {
      view.sessionItems = [...items, ...view.sessionItems];
      if (view.history case final history?) {
        history.prepend(items.map(_projectItem).toList());
      }
      view.hasEarlier = data['earlier'] == true;
    }
  }

  bool _mergeGroup(_HostView view, Map<String, Object?> data) {
    if (data['messages'] case final List<Object?> messages) {
      for (final item in messages) {
        if (item case {'seq': final int seq, 'from': final String from}
            when seq > 0 && from.isNotEmpty) {
          try {
            view.groupItems.putIfAbsent(
              seq,
              () => LinkGroupMessage.fromJson(item as Map<String, Object?>),
            );
          } on Object {
            // Skip invalid records while keeping the rest of the page.
          }
        }
      }
      return true;
    }
    return false;
  }

  void _render(_HostView view, DesktopHostChat chat) {
    view.messages = List.unmodifiable(
      view.group ? _groupMessages(view) : _sessionMessages(view, chat),
    );
    view.history?.publish(
      live: view.live,
      earlier: view.hasEarlier,
      interaction: view.interaction,
    );
  }

  static DesktopHostHistoryRow? _projectItem(Object? raw) {
    if (raw is! Map<String, Object?>) return null;
    final data = {...raw};
    if (data['text'] case final String text) {
      final shown = text.replaceAll(_hiddenNotes, '');
      if (data['t'] == 'user') {
        final images = data['images'];
        final attachment = images is List && images.isNotEmpty;
        final words = shown.replaceAll(imageReferencePattern, '').trimRight();
        if (words.trim().isEmpty && !attachment) return null;
        data['text'] = attachment
            ? [if (words.isNotEmpty) words, _attachment].join('\n')
            : words;
      } else {
        data['text'] = shown;
      }
    }
    final item = ChatCodec.decode(data, hostTranscript: true);
    if (item == null) return null;
    final images = switch (data) {
      {'t': 'user'} => DesktopRemoteImage.message(images: data['images']),
      {'t': 'tool', 'status': 'succeeded'} => DesktopRemoteImage.message(
        images: data['images'],
        toolImage: data['url'] is String ? data['url'] as String : null,
      ),
      {'t': 'text', 'text': final String text} => DesktopRemoteImage.message(
        markdown: _visibleText(text),
      ),
      _ => const <DesktopRemoteImage>[],
    };
    return (item: item, images: images);
  }

  Iterable<DesktopHostMessage> _groupMessages(_HostView view) sync* {
    final partsBySequence = <int, List<({String text, int? ref})>>{};
    List<({String text, int? ref})> partsOf(LinkGroupMessage item) =>
        partsBySequence.putIfAbsent(item.seq, () => _groupParts(item).toList());
    final summaries = <int, DesktopHostGroupQuote>{};
    DesktopHostGroupQuote summarize(LinkGroupMessage item) =>
        summaries.putIfAbsent(
          item.seq,
          () => DesktopHostGroupQuote._(
            view.groupIdentity,
            sequence: item.seq,
            sender: item.mine ? 'You' : _botNames[item.from] ?? item.from,
            mine: item.mine,
            preview: _quotePreview(
              partsOf(item).map((part) => part.text).join(' '),
            ),
            hasImage: item.images.isNotEmpty,
          ),
        );
    for (final item in view.groupItems.values) {
      if (item.notice) continue;
      final target = summarize(item);
      final parts = partsOf(item);
      final images = DesktopRemoteImage.group(item.images);
      final rows = parts.length + (item.images.isNotEmpty ? 1 : 0);
      for (var index = 0; index < rows; index++) {
        final attachment = index == parts.length;
        final (:text, :ref) = attachment
            ? (text: _attachment, ref: parts.isEmpty ? item.ref : null)
            : parts[index];
        final quoted = ref == null ? null : view.groupItems[ref];
        yield DesktopHostMessage(
          text: text,
          sender: target.sender,
          mine: item.mine,
          images: attachment ? images : const [],
          groupReplyTarget: index == 0 ? target : null,
          groupReference: ref != null && ref > 0 && ref < item.seq
              ? (
                  sequence: ref,
                  target: quoted != null && !quoted.notice
                      ? summarize(quoted)
                      : null,
                )
              : null,
        );
      }
    }
  }

  static Iterable<({String text, int? ref})> _groupParts(
    LinkGroupMessage item,
  ) sync* {
    final visible = _visibleText(item.text);
    if (item.mine) {
      if (visible.isNotEmpty) yield (text: visible, ref: item.ref);
      return;
    }
    for (final (:tag, :text, :ref) in ChatCodec.botPartsOf(visible)) {
      if (tag != ChatCodec.botSayTag) continue;
      final shown = _botMarkdown(text);
      if (shown.isNotEmpty) yield (text: shown, ref: ref ?? item.ref);
    }
  }

  Iterable<DesktopHostMessage> _sessionMessages(
    _HostView view,
    DesktopHostChat chat,
  ) sync* {
    final bot = chat.kind == 'bot';
    final sender = bot ? chat.title : 'Assistant';
    // A private bot page can start in the middle of a group turn. Only a
    // known turn origin or an explicit private delivery establishes routing.
    var showReply = !bot;
    for (final item in view.sessionItems) {
      if (item is! Map<String, Object?>) continue;
      final images = item['images'];
      final hasImage = images is List && images.isNotEmpty;
      switch (item) {
        case {'t': 'user', 'text': final String raw}:
          final text = _visibleText(raw);
          final user = UserMessageItem(text: raw);
          final group = ChatCodec.botGroupOf(user) != null;
          // A queued private message can be taken up with a group note.
          // Keep the user's words, but do not publish the ambiguous reply.
          final groupNote =
              group ||
              _hiddenNotes
                  .allMatches(raw)
                  .any(
                    (note) =>
                        ChatCodec.botGroupOf(UserMessageItem(text: note[0]!)) !=
                        null,
                  );
          final system =
              ChatCodec.botEvent(user) != null ||
              (text.isEmpty && _hiddenNotes.hasMatch(raw));
          if (item['queued'] != true) showReply = !groupNote && !system;
          if (group || system) continue;
          final from = item['agent'];
          // The visible words can survive a merged or queued private prompt,
          // but its media cannot be attributed to the private turn.
          final showImages = !bot || (showReply && !groupNote);
          yield* _lines(
            [text],
            from is String && from.isNotEmpty ? from : 'You',
            mine: from == null,
            attachment: showImages && hasImage,
            images: showImages
                ? DesktopRemoteImage.message(images: images, markdown: text)
                : const [],
          );
        case {'t': 'text', 'text': final String text} when showReply:
          if (bot) {
            // Markdown image alt text can resemble a voice cue. Extract
            // references from the admitted bot_say body before stripping cues.
            for (final (tag, words) in ChatCodec.botParts(_visibleText(text))) {
              if (tag != ChatCodec.botSayTag) continue;
              yield* _lines(
                [_botMarkdown(words)],
                sender,
                images: DesktopRemoteImage.message(markdown: words),
              );
            }
          } else {
            yield* _lines([_visibleText(text)], sender);
          }
        case {
              't': 'tool',
              'tool': ChatCodec.botSendTool,
              'status': 'succeeded',
              'sent': final String text,
            }
            when bot:
          // The host sets `sent` exclusively for a successful private send.
          final visible = _visibleText(text);
          yield* _lines(
            [visible],
            sender,
            attachment: showReply && hasImage,
            images: showReply
                ? DesktopRemoteImage.message(images: images, markdown: visible)
                : const [],
          );
        case {
              't': 'tool',
              'tool': ChatCodec.botImageTool,
              'status': 'succeeded',
            }
            when bot && showReply:
          if (hasImage || item['url'] is String) {
            yield* _lines(
              const [],
              sender,
              attachment: true,
              images: DesktopRemoteImage.message(
                images: images,
                toolImage: item['url'] is String ? item['url'] as String : null,
              ),
            );
          }
      }
    }
  }

  static String _visibleText(String text) => text
      .replaceAll(_hiddenNotes, '')
      .replaceAll(imageReferencePattern, '')
      .trim();

  // A lowercase bracketed label also looks like a speech cue. Only remove
  // cues in prose, keeping Markdown locations and code indentation intact.
  static String _botMarkdown(String text) {
    final cue = ChatCodec.voiceCue;
    if (!cue.hasMatch(text)) return text.trim();
    final lines = MdLines(text);
    final blocks = MdBlocks(lines);
    bool protects(MdInline run, Match match) =>
        run.start <= match.start &&
        match.end <= run.end &&
        switch (run.kind) {
          MdInlineKind.strong ||
          MdInlineKind.emphasis ||
          MdInlineKind.strongEmphasis ||
          MdInlineKind.strike => run.children.any(
            (child) => protects(child, match),
          ),
          _ => true,
        };
    String stripLine(int i) {
      final line = lines.line(i);
      final info = blocks.info(i);
      if ((!info.hasInline && !info.isTable) || !cue.hasMatch(line)) {
        return line;
      }
      final inlines = parseInline(
        line,
        info.contentStart,
        info.contentEnd,
        definitions: blocks.definitions,
      );
      return line.replaceAllMapped(
        cue,
        (match) => inlines.any((run) => protects(run, match)) ? match[0]! : '',
      );
    }

    return [for (var i = 0; i < lines.lineCount; i++) stripLine(i)]
        .join('\n')
        .trim();
  }

  static String _quotePreview(String text) {
    final line = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final head = String.fromCharCodes(line.runes.take(120));
    return head.length < line.length ? '$head…' : head;
  }

  static Iterable<DesktopHostMessage> _lines(
    Iterable<String> lines,
    String sender, {
    bool mine = false,
    bool attachment = false,
    List<DesktopRemoteImage> images = const [],
  }) sync* {
    for (final text in lines) {
      if (text.isNotEmpty) {
        yield DesktopHostMessage(text: text, sender: sender, mine: mine);
      }
    }
    if (attachment || images.isNotEmpty) {
      yield DesktopHostMessage(
        text: _attachment,
        sender: sender,
        mine: mine,
        images: List.unmodifiable(images),
      );
    }
  }

  /// Only a currently open project follow backs the session actions. Private
  /// bots share a transcript with their group turns, which are not editable
  /// or answerable from either of those views.
  DesktopRemoteSessionSnapshot? remoteActionSnapshot(
    LinkPeer? peer,
    DesktopHostChat chat,
  ) {
    final view = _view;
    if (view == null ||
        chat.kind != 'project' ||
        _selected?._key != chat._key ||
        _selected?.projectId != chat.projectId ||
        view.target != chat.id ||
        !identical(view.peer, peer) ||
        view.peer.isClosed ||
        view.opening ||
        !view.ready) {
      return null;
    }
    return DesktopRemoteSessionSnapshot(
      follow: view,
      state: view.actionState,
      items: view.sessionItems,
      live: view.live,
      busy: busy,
    );
  }
}

final _projectHistories = Expando<DesktopHostProjectHistoryFeed>();

extension DesktopHostProjectHistoryAccess on DesktopHostChats {
  /// The history feed when this model has opened a project subscription.
  DesktopHostProjectHistoryFeed? get projectHistory => _projectHistories[this];
}

class _HostView {
  _HostView(this.peer, this.target, {required this.group})
    : mirror = !group && peer.mirror == null ? LinkSessionMirror() : null,
      ready = target == null;

  final LinkPeer peer;
  final String? target;
  final bool group;
  final LinkSessionMirror? mirror;
  Map<String, Object?> get params => {group ? 'group' : 'session': target};
  bool opening = false;
  bool ready;
  bool paging = false;
  bool hasEarlier = false;
  bool interaction = false;
  bool live = false;
  Map<String, Object?> actionState = const {};
  DesktopHostProjectHistoryFeed? history;
  String? error;
  List<Object?> sessionItems = const [];
  final groupItems = SplayTreeMap<int, LinkGroupMessage>();
  final groupIdentity = Object();
  DesktopHostGroupQuote? groupReply;
  List<DesktopHostMessage> messages = const [];
}

class _PendingSend {
  _PendingSend(this.chat);
  final (String, String) chat;
  bool submitted = false;
}
