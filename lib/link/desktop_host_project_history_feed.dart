import 'package:flutter/foundation.dart';

import '../chat/chat_feed.dart';
import '../chat/chat_models.dart';
import '../chat/chat_session.dart' show ComposerMessage, UserPlace;
import '../chat/composer/composer_draft.dart';

/// Read-only history from an open project on the authenticated host.
class DesktopHostProjectHistoryFeed extends ChangeNotifier
    implements PagedChatFeed {
  DesktopHostProjectHistoryFeed({
    required this._earlier,
    required this._paging,
  });

  final Future<void> Function() _earlier;
  final bool Function() _paging;

  // Keep unrecognized wire positions here too: subsequent suffix and prepend
  // indexes count them even when this version cannot show them.
  List<ChatItem?> _wire = const [];
  List<ChatItem> _items = const [];
  bool _dirty = false;

  void replaceTail(int start, Iterable<ChatItem?> tail) {
    _wire = [..._wire.take(start), ...tail];
    _dirty = true;
  }

  void prepend(List<ChatItem?> page) {
    _wire = [...page, ..._wire];
    prependedCount += page.whereType<ChatItem>().length;
    _dirty = true;
  }

  void publish({
    required bool live,
    required bool earlier,
    required bool interaction,
  }) {
    if (!_dirty &&
        live == isStreaming &&
        earlier == hasEarlierHistory &&
        interaction == _interaction) {
      return;
    }
    _dirty = false;
    _items = _wire.whereType<ChatItem>().toList(growable: false);
    isStreaming = live;
    hasEarlierHistory = earlier;
    _interaction = interaction;
    notifyListeners();
  }

  bool _interaction = false;

  List<String> get suggestions {
    if (isStreaming || _interaction) return const [];
    for (final item in _items.reversed) {
      if (item is UserMessageItem) break;
      if (item is AssistantTextItem) return item.suggestions;
    }
    return const [];
  }

  @override
  int get itemCount => _items.length;
  @override
  ChatItem itemAt(int index) => _items[index];
  @override
  bool isStreaming = false;
  // Follow an active turn only if already at the bottom. A host update can
  // come from another client while the user is reading a previous turn.
  @override
  bool get isUnprompted => true;
  @override
  bool hasEarlierHistory = false;
  @override
  bool get loadingEarlier => _paging();
  @override
  int prependedCount = 0;
  @override
  Future<void> loadEarlier() => _earlier();
  @override
  bool get canEditMessages => false;
  @override
  ({int index, ComposerDraft draft})? get editing => null;
  @override
  set editing(({int index, ComposerDraft draft})? value) {}
  @override
  void editMessage(int index, ComposerMessage message, {UserPlace? from}) {}
  @override
  VoidCallback? moveToBackgroundAt(int index) => null;
  @override
  VoidCallback? stopAt(int index) => null;
}
