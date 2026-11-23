import 'dart:async';

import 'package:bao_link/bao_link.dart';
import 'package:flutter/widgets.dart';

import '../chat/chat_models.dart';
import '../l10n/l10n.dart';
import '../notifications/attention_host.dart';
import '../notifications/attention_settings.dart';
import '../notifications/notification_sound.dart';
import 'chat_codec.dart';

typedef _BotSeen = ({int unread, BotStatus status, String? last, int notice});

/// Local notices from the paired desktop's live catalog. The caller owns the
/// peer and passes only its authorized connection and accepted state snapshots.
/// The first snapshot on each connection is a baseline, including on reconnect.
///
/// `away` describes this pairing's app lifecycle. It can govern delivery to a
/// registered iPhone on that iPhone's own connection. `push` and the host's
/// HTTPS forwarding to APNs (sandbox or production) are iPhone-only; no token
/// or push relay participates in this adapter. The desktop process and link
/// need to stay alive, including when the window is minimized or hidden.
class DesktopRemoteNotifications {
  DesktopRemoteNotifications({
    required this.host,
    required this.settings,
    required this.l10n,
    this.shown,
  }) {
    _lifecycle = AppLifecycleListener(onStateChange: (_) => _syncAway());
  }

  final AttentionHost host;
  final AttentionSettings Function() settings;
  final AppLocalizations Function() l10n;

  /// Whether the chat is visible in the foreground workbench. If omitted,
  /// [NotifyWhen.unfocused] only notifies while the app is away.
  final bool Function(String kind, String id)? shown;

  late final AppLifecycleListener _lifecycle;
  LinkPeer? _peer;
  bool _disposed = false;
  bool? _sentAway;
  DateTime? _lastSound;
  Map<String, LinkSessionStatus> _sessions = {};
  final Map<String, AttentionEvent> _sessionEvents = {};
  Map<String, _BotSeen> _bots = {};
  Map<String, int> _groups = {};

  static bool? get _away => switch (WidgetsBinding.instance.lifecycleState) {
    AppLifecycleState.inactive ||
    AppLifecycleState.hidden ||
    AppLifecycleState.paused => true,
    AppLifecycleState.resumed || null => false,
    AppLifecycleState.detached => null,
  };

  /// Call with `DesktopHostConnection.peer` before the catalog for that peer
  /// is applied, and with null on disconnect or revocation.
  void bind(LinkPeer? peer) {
    if (_disposed) return;
    if (peer?.isClosed == true) peer = null;
    if (identical(_peer, peer)) return;
    _peer = peer;
    _sentAway = null;
    _sessions = {};
    _sessionEvents.clear();
    _bots = {};
    _groups = {};
    _syncAway();
  }

  void _syncAway() {
    final peer = _peer;
    final away = _away;
    if (peer == null || peer.isClosed || away == null || away == _sentAway) {
      return;
    }
    _sentAway = away;
    // Calls are written in order on the control stream. Older hosts can
    // reject this optional RPC and will still supply the same local feed.
    unawaited(_sendAway(peer, away));
  }

  static Future<void> _sendAway(LinkPeer peer, bool away) async {
    try {
      await peer.call(LinkMethods.away, {
        'away': away,
      }, const Duration(seconds: 2));
    } on Object {
      // Optional presence must not interfere with the workspace connection.
    }
  }

  /// Feed the existing catalog's decoded state after its current-peer and
  /// pushed-state vs. initial-response checks. This issues no catalog calls.
  void acceptState(LinkPeer peer, LinkState state) {
    if (!identical(_peer, peer) || peer.isClosed) return;
    final previous = _sessions;
    final privateSessions = {for (final bot in state.bots) ?bot.session};
    final sessions = {
      for (final session in state.sessions)
        if (session.id.isNotEmpty && !privateSessions.contains(session.id))
          session.id: session,
    };
    _sessions = sessions.map((id, session) => MapEntry(id, session.status));
    _sessionEvents.removeWhere((id, _) => _sessions[id] != previous[id]);
    for (final session in sessions.values) {
      final before = previous[session.id];
      if (before == null || before == session.status) continue;
      final event = switch (session.status) {
        LinkSessionStatus.needsInput => AttentionEvent.needsInput,
        LinkSessionStatus.idle when before == LinkSessionStatus.running =>
          AttentionEvent.finished,
        _ => null,
      };
      if (event == null) continue;
      _sessionEvents[session.id] = event;
      _notify(
        peer,
        state.device.name,
        'project',
        session.id,
        session.title,
        event,
        (l10n) => event == AttentionEvent.needsInput
            ? l10n.attentionNeedsInput
            : l10n.attentionFinished,
      );
    }
    _acceptBots(peer, state);
    _acceptGroups(peer, state);
  }

  void _acceptBots(LinkPeer peer, LinkState state) {
    final beforeBots = _bots;
    _bots = {};
    final seenWatches = <(String, String)>{};
    for (final bot in state.bots) {
      if (bot.id.isEmpty || _bots.containsKey(bot.id)) continue;
      final before = beforeBots[bot.id];
      var high = before?.notice ?? 0;
      final fresh = <int, LinkBotNotice>{};
      for (final notice in bot.notices) {
        if (notice.id > high) high = notice.id;
        if (before != null && notice.id > before.notice) {
          fresh.putIfAbsent(notice.id, () => notice);
        }
      }
      _bots[bot.id] = (
        unread: bot.unread,
        status: bot.status,
        last: bot.last,
        notice: high,
      );
      if (before == null) continue;

      final wrote =
          bot.unread > before.unread ||
          (before.status == BotStatus.typing &&
              bot.status == BotStatus.idle &&
              bot.last != before.last);
      final last = bot.last;
      if (wrote && last != null) {
        final preview = _preview(last);
        if (preview.isNotEmpty) {
          _notify(
            peer,
            state.device.name,
            'bot',
            bot.id,
            bot.name,
            AttentionEvent.finished,
            (_) => preview,
          );
        }
      }

      final ordered = fresh.keys.toList()..sort();
      for (final id in ordered) {
        final notice = fresh[id]!;
        final event = switch (notice.kind) {
          'waiting' => AttentionEvent.needsInput,
          'failed' || 'done' || 'running' => AttentionEvent.finished,
          _ => null,
        };
        if (event == null ||
            notice.chat.isEmpty ||
            !seenWatches.add((notice.chat, notice.kind))) {
          continue;
        }
        // A watch notice for the same project condition is a second
        // representation of the transition, not a second notification.
        if ((notice.kind == 'waiting' || notice.kind == 'done') &&
            _sessionEvents[notice.chat] == event) {
          continue;
        }
        _notify(
          peer,
          state.device.name,
          'project',
          notice.chat,
          bot.name,
          event,
          (l10n) {
            final label = switch (notice.kind) {
              'waiting' => l10n.attentionNeedsInput,
              'failed' => l10n.sidePanelTaskFailed,
              'running' => l10n.statusRunningInBackground,
              _ => l10n.attentionFinished,
            };
            final subject = _preview(notice.title);
            // Leave detailed errors and host paths inside the authenticated chat.
            return subject.isEmpty ? label : '$subject · $label';
          },
        );
      }
    }
  }

  void _acceptGroups(LinkPeer peer, LinkState state) {
    final beforeGroups = _groups;
    _groups = {};
    for (final group in state.groups) {
      if (group.id.isEmpty || _groups.containsKey(group.id)) continue;
      final before = beforeGroups[group.id];
      final last = group.last;
      final seq = last?.seq ?? 0;
      _groups[group.id] = seq > (before ?? 0) ? seq : before ?? 0;
      // The host marks open group subscriptions as seen even when this app
      // is in the background. Sequence, not unread count, detects additions.
      if (before == null ||
          last == null ||
          seq <= before ||
          last.mine ||
          last.notice ||
          last.from.isEmpty) {
        continue;
      }
      final preview = _preview(
        ChatCodec.botSays(_withoutNotes(last.text)).lastOrNull ?? '',
      );
      if (preview.isEmpty && last.images.isEmpty) continue;
      _notify(
        peer,
        state.device.name,
        'group',
        group.id,
        group.name,
        AttentionEvent.finished,
        (l10n) => preview.isEmpty ? l10n.shownImage : preview,
      );
    }
  }

  static final _hiddenNotes = RegExp(
    r'<(system-reminder|bao-event|task-notification|local-command-caveat)\b[^>]*>.*?(?:</\1>|$)',
    dotAll: true,
  );

  static String _withoutNotes(String text) =>
      text.replaceAll(_hiddenNotes, '').replaceAll(imageReferencePattern, '');

  static String _preview(String text) => oneLineExcerpt(_withoutNotes(text));

  void _notify(
    LinkPeer peer,
    String device,
    String kind,
    String id,
    String title,
    AttentionEvent event,
    String Function(AppLocalizations) body,
  ) {
    final away = _away;
    if (away == null) return;
    final preferences = settings();
    if (!preferences.notifies(event)) return;
    if (!away &&
        preferences.when == NotifyWhen.unfocused &&
        (shown?.call(kind, id) ?? true)) {
      return;
    }

    if (event == AttentionEvent.needsInput) {
      unawaited(_bestEffort(host.requestAttention));
    }
    final heading = [
      title,
      device,
    ].where((text) => text.trim().isNotEmpty).join(' · ');
    unawaited(
      _bestEffort(
        () => host.notify(
          // Remote IDs cannot match the local AttentionService's numeric IDs.
          id: [
            'remote',
            peer.remote,
            kind,
            id,
          ].map(Uri.encodeComponent).join(':'),
          title: heading.isEmpty ? 'BaoCode' : _preview(heading),
          body: body(l10n()),
        ),
      ),
    );
    if (preferences.sound == NotificationSoundValue.none) return;
    final now = DateTime.now();
    final last = _lastSound;
    if (last != null && now.difference(last) < const Duration(seconds: 1)) {
      return;
    }
    _lastSound = now;
    unawaited(
      _bestEffort(() => NotificationSound.play(host, preferences.sound)),
    );
  }

  static Future<void> _bestEffort(Future<void> Function() deliver) async {
    try {
      await deliver();
    } on Object {
      // The platform or sound asset may be unavailable. The link stays live.
    }
  }

  void dispose() {
    if (_disposed) return;
    bind(null);
    _disposed = true;
    _lifecycle.dispose();
  }
}
