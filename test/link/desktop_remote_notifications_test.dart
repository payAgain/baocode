import 'package:bao_link/bao_link.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/link/desktop_remote_notifications.dart';
import 'package:baocode/notifications/attention_host.dart';
import 'package:baocode/notifications/attention_settings.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const _device = DeviceInfo(name: 'Host', kind: 'mac', system: 'macOS');
const _attention = MethodChannel('baocode/attention');

LinkState _state(
  LinkSessionStatus status, {
  List<LinkBot> bots = const [],
  List<LinkGroup> groups = const [],
}) => LinkState(
  device: _device,
  sessions: [
    SessionSummary(
      id: 'session',
      project: 'project',
      title: 'Remote task',
      updatedAt: DateTime(2026),
      status: status,
    ),
  ],
  bots: bots,
  groups: groups,
);

Future<LinkPeer> _peer(
  List<(String, Map<String, Object?>)> requests, {
  String remote = 'paired-host',
  bool oldHost = false,
}) async {
  final (a, b) = MemoryLinkConnection.pair(a: 'desktop', b: remote);
  final accepting = LinkPeer.accept(
    b,
    onRequest: (method, params) {
      requests.add((method, params));
      if (oldHost) throw const LinkRemoteException(LinkErrors.unknown, 'old');
      return null;
    },
  );
  final client = await LinkPeer.connect(a);
  final host = await accepting;
  addTearDown(client.close);
  addTearDown(host.close);
  return client;
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <MethodCall>[];
  final requests = <(String, Map<String, Object?>)>[];
  const idle = LinkSessionStatus.idle;
  const running = LinkSessionStatus.running;
  const waiting = LinkSessionStatus.needsInput;
  const silent = AttentionSettings(sound: NotificationSoundValue.none);

  List<Map<Object?, Object?>> posted() => [
    for (final call in calls)
      if (call.method == 'notify') call.arguments as Map<Object?, Object?>,
  ];

  setUp(() {
    calls.clear();
    requests.clear();
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(_attention, (
      call,
    ) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(_attention, null);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    debugDefaultTargetPlatformOverride = null;
  });

  DesktopRemoteNotifications notifications({
    AttentionSettings Function()? settings,
    bool Function(String kind, String id)? shown,
  }) {
    final notices = DesktopRemoteNotifications(
      host: ChannelAttentionHost.instance,
      settings: settings ?? () => silent,
      l10n: () => englishLocalizations,
      shown: shown,
    );
    addTearDown(notices.dispose);
    return notices;
  }

  for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
    test(
      'routes fresh, connected transitions through $platform native attention',
      () async {
        debugDefaultTargetPlatformOverride = platform;
        final peer = await _peer(requests);
        final notices = notifications()..bind(peer);
        notices.acceptState(peer, _state(waiting));
        expect(posted(), isEmpty);

        binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        notices.acceptState(peer, _state(running));
        notices.acceptState(peer, _state(waiting));
        notices.acceptState(peer, _state(waiting));
        notices.acceptState(peer, _state(running));
        notices.acceptState(peer, _state(idle));
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await pumpEventQueue();

        expect(posted().map((notice) => notice['body']), [
          englishLocalizations.attentionNeedsInput,
          englishLocalizations.attentionFinished,
        ]);
        expect(posted().first['id'], posted().last['id']);
        expect(posted().first['title'], 'Remote task · Host');
        expect(calls.map((call) => call.method), [
          'requestAttention',
          'notify',
          'notify',
        ]);
        expect(requests, hasLength(3));
        expect(
          requests.map((request) => request.$1),
          everyElement(LinkMethods.away),
        );
        expect(requests.map((request) => request.$2), [
          {'away': false},
          {'away': true},
          {'away': false},
        ]);
      },
    );
  }

  test(
    'reconnect silently replaces the baseline and drops old peers',
    () async {
      final first = await _peer(requests);
      final notices = notifications()..bind(first);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      notices.acceptState(first, _state(running));
      await first.close();
      notices.acceptState(first, _state(idle));

      final next = await _peer(requests, oldHost: true);
      notices.bind(next);
      notices.acceptState(first, _state(waiting));
      notices.acceptState(next, _state(waiting));
      expect(posted(), isEmpty);
      notices.acceptState(next, _state(running));
      notices.acceptState(next, _state(idle));
      await pumpEventQueue();
      expect(posted().map((notice) => notice['body']), [
        englishLocalizations.attentionFinished,
      ]);
      expect(
        requests.map((request) => request.$1),
        everyElement(LinkMethods.away),
      );
    },
  );

  test(
    'only live private Bot replies and new watch notices are shown',
    () async {
      final peer = await _peer(requests);
      final notices = notifications()..bind(peer);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      LinkBot bot({
        int unread = 0,
        BotStatus status = BotStatus.idle,
        String? last,
        List<LinkBotNotice> watched = const [],
      }) => LinkBot(
        id: 'bot',
        name: 'Helper',
        unread: unread,
        status: status,
        last: last,
        notices: watched,
      );
      LinkBotNotice watch(int id, String kind, {String chat = 'session'}) =>
          LinkBotNotice(
            id: id,
            kind: kind,
            chat: chat,
            title: 'Watched task',
            project: 'Host project',
            detail: 'private full error and paths',
          );
      final old = watch(10, 'done');
      final overlap = watch(11, 'waiting');
      final failed = watch(12, 'failed', chat: 'other');
      final futureKind = watch(13, 'future', chat: 'unknown');
      notices.acceptState(
        peer,
        _state(
          running,
          bots: [
            bot(unread: 5, last: 'Prior message', watched: [old]),
          ],
        ),
      );
      expect(posted(), isEmpty);

      notices.acceptState(
        peer,
        _state(
          waiting,
          bots: [
            bot(
              unread: 6,
              last: 'Fresh private reply',
              watched: [old, overlap],
            ),
          ],
        ),
      );
      notices.acceptState(
        peer,
        _state(
          waiting,
          bots: [
            bot(
              last: 'Fresh private reply',
              status: BotStatus.typing,
              watched: [old, overlap, futureKind, failed, failed],
            ),
          ],
        ),
      );
      notices.acceptState(
        peer,
        _state(
          waiting,
          bots: [
            bot(
              last: 'Reply even while the host marks the chat read',
              watched: [failed],
            ),
          ],
        ),
      );
      notices.acceptState(
        peer,
        _state(
          waiting,
          bots: [
            bot(
              last: 'Reply even while the host marks the chat read',
              watched: [old, overlap, failed],
            ),
          ],
        ),
      );

      expect(posted().map((n) => n['body']), [
        englishLocalizations.attentionNeedsInput,
        'Fresh private reply',
        'Watched task · ${englishLocalizations.sidePanelTaskFailed}',
        'Reply even while the host marks the chat read',
      ]);
    },
  );

  test(
    'groups use the latest unseen sequence, not host read counts or raw markup',
    () async {
      final peer = await _peer(requests);
      final notices = notifications()..bind(peer);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      LinkState group(
        int seq,
        String from,
        String text, {
        List<String> images = const [],
      }) => _state(
        idle,
        groups: [
          LinkGroup(
            id: 'group',
            name: 'Team',
            last: LinkGroupMessage(
              seq: seq,
              at: DateTime(2026),
              from: from,
              text: text,
              images: images,
            ),
          ),
        ],
      );
      notices.acceptState(peer, group(1, 'bot', '<bot_say>Prior</bot_say>'));
      notices.acceptState(peer, group(2, linkGroupUser, 'My own message'));
      notices.acceptState(peer, group(3, linkGroupApp, 'Joined'));
      notices.acceptState(
        peer,
        group(4, 'bot', '<bot_narrate>Private narration</bot_narrate>'),
      );
      final fresh = group(
        5,
        'bot',
        '<bot_say>[whispers] Hi<system-reminder>private</system-reminder></bot_say>',
      );
      notices.acceptState(peer, fresh);
      notices.acceptState(peer, fresh);
      notices.acceptState(peer, group(4, 'bot', '<bot_say>Replay</bot_say>'));
      notices.acceptState(peer, fresh);
      notices.acceptState(
        peer,
        group(6, 'bot', '', images: ['host-image.png']),
      );
      expect(posted().map((n) => n['body']), [
        'Hi',
        englishLocalizations.shownImage,
      ]);
      expect(posted().map((n) => n['title']), ['Team · Host', 'Team · Host']);
    },
  );

  test(
    'honors current visibility, global toggle, event filter, and sound',
    () async {
      var settings = silent;
      var showing = true;
      final peer = await _peer(requests);
      final notices = notifications(
        settings: () => settings,
        shown: (kind, id) => showing && kind == 'project' && id == 'session',
      )..bind(peer);
      notices.acceptState(peer, _state(running));
      notices.acceptState(peer, _state(waiting));
      expect(posted(), isEmpty);

      showing = false;
      settings = const AttentionSettings(enabled: false);
      notices.acceptState(peer, _state(running));
      notices.acceptState(peer, _state(idle));
      expect(posted(), isEmpty);

      showing = true;
      settings = const AttentionSettings(
        when: NotifyWhen.always,
        sound: '/synthetic/notice.wav',
        events: {AttentionEvent.needsInput},
      );
      notices.acceptState(peer, _state(idle));
      notices.acceptState(peer, _state(waiting));
      notices.acceptState(peer, _state(running));
      notices.acceptState(peer, _state(idle));
      await pumpEventQueue();
      expect(posted().map((notice) => notice['body']), [
        englishLocalizations.attentionNeedsInput,
      ]);
      expect(
        calls.singleWhere((call) => call.method == 'playSound').arguments,
        {'path': '/synthetic/notice.wav'},
      );
    },
  );
}
