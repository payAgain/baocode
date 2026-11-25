import 'package:flutter/foundation.dart';

import '../chat/chat_feed.dart';
import '../chat/chat_models.dart';
import '../chat/chat_session.dart' show ComposerMessage, UserPlace;
import '../chat/composer/composer_draft.dart';
import 'desktop_remote_media_preview.dart';

typedef DesktopHostHistoryRow = ({
  ChatItem item,
  List<DesktopRemoteImage> images,
});

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
  List<DesktopHostHistoryRow?> _wire = const [];
  List<DesktopHostHistoryRow> _items = const [];
  bool _dirty = false;

  void replaceTail(int start, Iterable<DesktopHostHistoryRow?> tail) {
    _wire = [..._wire.take(start), ...tail];
    _dirty = true;
  }

  void prepend(List<DesktopHostHistoryRow?> page) {
    _wire = [...page, ..._wire];
    prependedCount += page.nonNulls.length;
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
    _items = _wire.nonNulls.toList(growable: false);
    isStreaming = live;
    hasEarlierHistory = earlier;
    _interaction = interaction;
    notifyListeners();
  }

  bool _interaction = false;

  List<String> get suggestions {
    if (isStreaming || _interaction) return const [];
    for (final (item: item, images: _) in _items.reversed) {
      if (item is UserMessageItem) break;
      if (item is AssistantTextItem) return item.suggestions;
    }
    return const [];
  }

  /// Wire indexes include rows that failed to decode or were filtered out.
  int? wireIndexAt(int index, UserMessageItem item) {
    if (index < 0 ||
        index >= _items.length ||
        !identical(_items[index].item, item)) {
      return null;
    }
    for (final (wireIndex, entry) in _wire.indexed) {
      if (entry == null) continue;
      if (index-- == 0) return identical(entry.item, item) ? wireIndex : null;
    }
    return null;
  }

  @override
  int get itemCount => _items.length;
  @override
  ChatItem itemAt(int index) => _items[index].item;

  List<DesktopRemoteImage> imagesAt(int index) => _items[index].images;
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
