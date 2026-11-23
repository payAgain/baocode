import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:bao_link/bao_link.dart';
import 'package:flutter/foundation.dart';

import '../chat/chat_models.dart' show UserMessageItem, imageReferencePattern;
import 'chat_codec.dart';

class DesktopHostChat {
  const DesktopHostChat({
    required this.id,
    required this.title,
    required this.kind,
    this.projectId,
  });

  final String id;
  final String title;
  final String kind;
  final String? projectId;

  (String, String) get _key => (kind, id);
}

class DesktopHostMessage {
  const DesktopHostMessage({
    required this.text,
    required this.sender,
    required this.mine,
  });

  final String text;
  final String sender;
  final bool mine;
}

/// The paired desktop's catalog and one open chat, over its existing link.
/// The caller owns the peer. A new peer with the same authenticated identity
/// restores selection, and [reset] also forgets the selection and catalog.
class DesktopHostChats extends ChangeNotifier {
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
  _PendingSend? _sending;
  final Map<(String, String), String> _sendErrors = {};

  List<DesktopHostChat> get chats => _chats;
  DesktopHostChat? get selected => _selected;
  List<DesktopHostMessage> get messages => _view?.messages ?? const [];
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
      (_view?.interaction == true ? _approval : null) ??
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

  void _applyState(LinkPeer peer, Object? data, {bool pushed = false}) {
    if (data is! Map<String, Object?> || !data.containsKey('device')) {
      throw const FormatException('Invalid host state');
    }
    final state = LinkState.fromJson(data);
    if (pushed) _stateEventSeen = true;
    final oldBotSessions = _botSessions;
    _botSessions = {for (final bot in state.bots) bot.id: bot.session};
    _botNames = {for (final bot in state.bots) bot.id: bot.name};
    final botIds = _botSessions.values.toSet();
    _projects = List.unmodifiable(state.projects);
    final projects = state.projects.map((project) => project.id).toSet();
    final entries = <(String, String), DesktopHostChat>{};
    void add(String kind, String id, String title, {String? projectId}) {
      if (id.isEmpty) return;
      entries[(kind, id)] = DesktopHostChat(
        id: id,
        title: title.isEmpty ? id : title,
        kind: kind,
        projectId: projectId,
      );
    }

    for (final session in state.sessions) {
      if (projects.contains(session.project) && !botIds.contains(session.id)) {
        add('project', session.id, session.title, projectId: session.project);
      }
    }
    for (final bot in state.bots) {
      add('bot', bot.id, bot.name);
    }
    for (final group in state.groups) {
      add('group', group.id, group.name);
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
    _closeView();
    _selected = null;
    notifyListeners();
  }

  void _closeView() {
    final view = _view;
    _view = null;
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
    text = text.trim();
    final chat = _selected;
    final view = _view;
    if (text.isEmpty ||
        busy ||
        chat == null ||
        view == null ||
        view.peer.isClosed ||
        !view.ready ||
        view.interaction) {
      return;
    }
    final pending = _sending = _PendingSend(chat._key);
    final coldBot = view.target == null;
    _sendErrors.remove(chat._key);
    view.error = null;
    notifyListeners();
    try {
      if (!identical(_sending, pending) || !identical(_view, view)) return;
      pending.submitted = true;
      final result = await view.peer.call(
        view.group ? LinkMethods.sendGroup : LinkMethods.send,
        {
          if (coldBot) 'bot': chat.id else ...view.params,
          'text': text,
          'id': base64Url.encode(randomBytes(16)),
        },
      );
      if (!identical(_sending, pending)) return;
      if (view.group) {
        if (result case {'seq': final int seq} when seq > 0) return;
      } else if (result case {'session': final String id} when id.isNotEmpty) {
        if (coldBot) {
          if (identical(_view, view)) {
            // The message is confirmed even if following its new session
            // subsequently fails or the link drops while loading it.
            _sending = null;
            await _openView(view.peer, _selected!, id);
          }
          return;
        }
        if (id == view.target) return;
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
      view.hasEarlier = update['earlier'] == true;
      view.interaction = update['interaction'] != null;
      return true;
    }
    return false;
  }

  void _prepend(_HostView view, Map<String, Object?> data) {
    if (data['items'] case final List<Object?> items) {
      view.sessionItems = [...items, ...view.sessionItems];
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
  }

  Iterable<DesktopHostMessage> _groupMessages(_HostView view) sync* {
    for (final item in view.groupItems.values) {
      if (item.notice) continue;
      final sender = item.mine ? 'You' : _botNames[item.from] ?? item.from;
      final lines = item.mine
          ? [_visibleText(item.text)]
          : _botLines(item.text);
      yield* _lines(
        lines,
        sender,
        mine: item.mine,
        attachment: item.images.isNotEmpty,
      );
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
          yield* _lines(
            [text],
            from is String && from.isNotEmpty ? from : 'You',
            mine: from == null,
            attachment: hasImage,
          );
        case {'t': 'text', 'text': final String text} when showReply:
          yield* _lines(bot ? _botLines(text) : [_visibleText(text)], sender);
        case {
              't': 'tool',
              'tool': ChatCodec.botSendTool,
              'status': 'succeeded',
              'sent': final String text,
            }
            when bot:
          // The host sets `sent` exclusively for a successful private send.
          yield* _lines([_visibleText(text)], sender, attachment: hasImage);
        case {
              't': 'tool',
              'tool': ChatCodec.botImageTool,
              'status': 'succeeded',
            }
            when bot && showReply:
          if (hasImage || item['url'] is String) {
            yield* _lines(const [], sender, attachment: true);
          }
      }
    }
  }

  static String _visibleText(String text) => text
      .replaceAll(_hiddenNotes, '')
      .replaceAll(imageReferencePattern, '')
      .trim();

  static Iterable<String> _botLines(String text) =>
      ChatCodec.botSays(_visibleText(text));

  static Iterable<DesktopHostMessage> _lines(
    Iterable<String> lines,
    String sender, {
    bool mine = false,
    bool attachment = false,
  }) sync* {
    for (final text in lines) {
      if (text.isNotEmpty) {
        yield DesktopHostMessage(text: text, sender: sender, mine: mine);
      }
    }
    if (attachment) {
      yield DesktopHostMessage(text: _attachment, sender: sender, mine: mine);
    }
  }
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
  String? error;
  List<Object?> sessionItems = const [];
  final groupItems = SplayTreeMap<int, LinkGroupMessage>();
  List<DesktopHostMessage> messages = const [];
}

class _PendingSend {
  _PendingSend(this.chat);
  final (String, String) chat;
  bool submitted = false;
}
