import 'dart:async';
import 'dart:io';

import 'package:baocode/bots/bot_history.dart';
import 'package:baocode/search/memory_history.dart';
import 'package:flutter_test/flutter_test.dart';

const _dm = MemoryHistoryScope.dm('bot');
const _group = MemoryHistoryScope.group('bot', 'red');
const _otherGroup = MemoryHistoryScope.group('bot', 'blue');
const _otherBot = MemoryHistoryScope.dm('other');
const _project = MemoryHistoryScope.project('bot', '/repo');

void main() {
  test(
    'literal Unicode search with narrow filters and stable cursor',
    () async {
      final source = _Source([
        _message(_dm, 'one', 1, '先改喝红茶，then run C:/work/App v1.2.3'),
        _message(_dm, 'one', 2, '红茶与绿茶'),
        _message(_dm, 'two', 3, '红茶 🙂'),
        _message(_project, 'three', 4, '红茶与项目'),
      ]);
      final index = MemoryHistoryIndex(source: source.callbacks);
      final access = _access(_dm, allowed: [_project]);

      for (final query in [
        '红茶',
        '改喝红茶',
        '茶，THEN',
        'c:/WORK/App',
        'v1.2.3',
        '红',
        '🙂',
      ]) {
        final page = await index.search(
          access,
          MemoryHistoryQuery(text: query),
        );
        expect(page.hits, isNotEmpty, reason: query);
        for (final hit in page.hits) {
          expect(hit.reference.scope, _dm);
          expect(
            hit.snippet
                .substring(hit.matchStart, hit.matchStart + hit.matchLength)
                .toLowerCase(),
            query.toLowerCase(),
          );
        }
      }
      final first = await index.search(
        access,
        const MemoryHistoryQuery(text: '红茶', limit: 1),
      );
      expect(first.hits.single.reference.sessionId, 'two');
      expect(first.cursor, isNotNull);
      final second = await index.search(
        access,
        MemoryHistoryQuery(text: '红茶', limit: 2, cursor: first.cursor),
      );
      expect(second.hits.map((hit) => hit.reference.messageId), ['2', '1']);
      expect(second.cursor, isNull);
      final invalid = await index.search(
        access,
        MemoryHistoryQuery(text: '绿茶', cursor: first.cursor),
      );
      expect(invalid.hits, isEmpty);
      final narrow = await index.search(
        access,
        MemoryHistoryQuery(
          text: '红茶',
          sessionId: 'one',
          since: _at(2),
          before: _at(3),
        ),
      );
      expect(narrow.hits.single.reference.messageId, '2');
      final project = await index.search(
        access,
        const MemoryHistoryQuery(
          text: '红茶',
          scope: _project,
          projectId: '/repo',
        ),
      );
      expect(project.hits.single.projectId, '/repo');
    },
  );

  test(
    'empty queries paginate only recent messages in the chosen scope',
    () async {
      final source = _Source([
        _message(_group, 'red', 1, 'too early'),
        _message(_group, 'red', 2, 'first message'),
        _message(_group, 'red', 3, 'second message'),
        _message(_group, 'red', 4, 'too late'),
        _message(_group, 'different session', 3, 'another session'),
        _message(_otherGroup, 'blue', 3, 'out of scope'),
        _message(_dm, 'private', 3, 'no group target'),
      ]);
      final index = MemoryHistoryIndex(source: source.callbacks);
      final access = _access(_dm, allowed: [_group]);

      MemoryHistoryQuery recent({String text = '', String? cursor}) =>
          MemoryHistoryQuery(
            text: text,
            scope: _group,
            sessionId: 'red',
            since: _at(2),
            before: _at(4),
            cursor: cursor,
            limit: 1,
          );

      final first = await index.search(access, recent());
      expect(first.hits.single.snippet, 'second message');
      expect(first.hits.single.matchStart, 0);
      expect(first.hits.single.matchLength, 0);
      expect(first.cursor, isNotNull);
      final next = await index.search(
        access,
        recent(text: '  ', cursor: first.cursor),
      );
      expect(next.hits.single.snippet, 'first message');
      expect(next.cursor, isNull);
      final otherQuery = await index.search(
        access,
        recent(text: 'message', cursor: first.cursor),
      );
      expect(otherQuery.hits, isEmpty);
      final defaults = await index.search(access, const MemoryHistoryQuery());
      expect(defaults.hits.single.reference.scope, _dm);
    },
  );

  test(
    'scope and reference cannot broaden the current authorized request',
    () async {
      final source = _Source([
        _message(_dm, 'one', 1, 'needle private'),
        _message(_group, 'red', 1, 'needle red'),
        _message(_otherGroup, 'blue', 1, 'needle blue'),
        _message(_otherBot, 'one', 1, 'needle other Bot'),
      ]);
      final index = MemoryHistoryIndex(source: source.callbacks);
      final owner = _access(_dm, allowed: [_group, _otherBot]);
      final group = _access(_group, allowed: [_dm, _otherGroup]);

      final own = await index.search(
        owner,
        const MemoryHistoryQuery(text: 'needle'),
      );
      expect(own.hits.single.reference.scope, _dm);
      final granted = await index.search(
        owner,
        const MemoryHistoryQuery(text: 'needle', scope: _group),
      );
      final ref = granted.hits.single.reference;
      expect(MemoryHistoryReference.fromJson(ref.toJson()), ref);
      expect(await index.locate(owner, ref), isNull);
      expect(
        (await index.locate(owner, ref, scope: _group))?.text,
        'needle red',
      );
      expect(await index.browse(owner, ref, scope: _otherGroup), isNull);
      expect(
        (await index.search(
          owner,
          const MemoryHistoryQuery(text: 'needle', scope: _otherBot),
        )).hits,
        isEmpty,
      );
      expect(
        (await index.search(
          group,
          const MemoryHistoryQuery(text: 'needle', scope: _otherGroup),
        )).hits,
        isEmpty,
      );
      expect(
        (await index.search(
          group,
          const MemoryHistoryQuery(text: 'needle', scope: _dm),
        )).hits,
        isEmpty,
      );
      expect(source.loads.toSet(), {_dm, _group});
    },
  );

  test(
    'browse rechecks the original window and confines it to one session',
    () async {
      final anchor = _message(_group, 'red', 2, '原话\n保留换行');
      final source = _Source([
        _message(_group, 'red', 1, 'before'),
        anchor,
        _message(_group, 'red', 3, 'after'),
        _message(_group, 'another', 0, 'different session'),
        _message(_otherGroup, 'red', 1, 'different group'),
      ]);
      final index = MemoryHistoryIndex(source: source.callbacks);
      final access = _access(_group);
      final window = (await index.browse(access, anchor.reference))!;
      expect(window.anchor.text, '原话\n保留换行');
      expect(window.before.single.text, 'before');
      expect(window.after.single.text, 'after');
      source.messages.remove(anchor.reference);
      expect(await index.browse(access, anchor.reference), isNull);
      expect(await index.locate(access, anchor.reference), isNull);
    },
  );

  test('stale checkpoint cannot expose a removed or edited source', () async {
    final removed = _message(_dm, 'one', 1, 'old wording');
    final source = _Source([removed]);
    final index = MemoryHistoryIndex(source: source.callbacks);
    final access = _access(_dm);
    const old = MemoryHistoryQuery(text: 'old');
    expect(
      (await index.search(access, old)).hits.single.reference,
      removed.reference,
    );
    source.messages[removed.reference] = _message(_dm, 'one', 1, 'new wording');
    expect((await index.search(access, old)).hits, isEmpty);
    expect(
      (await index.locate(access, removed.reference))?.text,
      'new wording',
    );
    source.messages.clear();
    expect((await index.search(access, old)).hits, isEmpty);
    expect(await index.locate(access, removed.reference), isNull);
  });

  test(
    'change in membership or invalidation stops in-flight results',
    () async {
      for (final revoke in [true, false]) {
        final reachedRead = Completer<void>();
        final finishRead = Completer<void>();
        var allowed = true;
        final msg = _message(_group, 'red', 1, 'group words');
        final index = MemoryHistoryIndex(
          source: MemoryHistorySource(
            load: (_) async => [msg],
            read: (_) async {
              reachedRead.complete();
              await finishRead.future;
              return msg;
            },
          ),
        );
        final search = index.search(
          _access(_group, authorized: (_) => allowed),
          const MemoryHistoryQuery(text: 'words'),
        );
        await reachedRead.future;
        if (revoke) {
          allowed = false;
        } else {
          await index.invalidate(_group);
        }
        finishRead.complete();
        expect((await search).hits, isEmpty);
      }
    },
  );

  test('a persistent shard is reused, purged and rebuilt', () async {
    final dir = await Directory.systemTemp.createTemp('memory-history-test');
    addTearDown(() => dir.delete(recursive: true));
    final source = _Source([_message(_dm, 'one', 1, 'stored words')]);
    final first = MemoryHistoryIndex(source: source.callbacks, path: dir.path);
    const query = MemoryHistoryQuery(text: 'words');
    final access = _access(_dm);
    expect((await first.search(access, query)).hits, hasLength(1));
    expect(source.loads, [_dm]);
    final restarted = MemoryHistoryIndex(
      source: source.callbacks,
      path: dir.path,
    );
    expect((await restarted.search(access, query)).hits, hasLength(1));
    expect(source.loads, [_dm]);
    await restarted.invalidateBot('bot');
    expect(await dir.list().toList(), isEmpty);
    await restarted.rebuild(_dm);
    expect(source.loads, [_dm, _dm]);
    expect(await dir.list().toList(), hasLength(1));
  });

  test('legacy transcript only indexes visible, explicitly private turns', () {
    final rows = [
      _row('assistant', 'unrouted', '<bot_say>unrouted text</bot_say>'),
      _row('user', 'private', 'What did I say before?'),
      _row('assistant', 'reply', [
        {'type': 'thinking', 'thinking': 'hidden thought'},
        {
          'type': 'text',
          'text': 'unwrapped developer note <bot_say>Private reply</bot_say>',
        },
      ]),
      _row(
        'user',
        'group',
        '<bao-event>[group red] copied group words</bao-event>',
      ),
      _row('assistant', 'group-answer', '<bot_say>Group reply</bot_say>'),
      _row('user', 'task', '<bao-event>Host task completed</bao-event>'),
      _row('assistant', 'ambiguous', '<bot_say>Ambiguous reply</bot_say>'),
      _row('assistant', 'tool', [
        {
          'type': 'tool_use',
          'id': 'private-delivery',
          'name': 'mcp__bot__bot_send',
          'input': {'to': 'private', 'text': 'Delivered'},
        },
        {
          'type': 'tool_use',
          'id': 'failed-delivery',
          'name': 'mcp__bot__bot_send',
          'input': {'to': 'private', 'text': 'Failed'},
        },
      ]),
      _row('user', 'tool-result', [
        {
          'type': 'tool_result',
          'tool_use_id': 'private-delivery',
          'content': 'Sent to the user, in your chat with them.',
        },
        {
          'type': 'tool_result',
          'tool_use_id': 'failed-delivery',
          'is_error': true,
          'content': 'Sent to the user, in your chat with them.',
        },
      ]),
    ];
    final messages = projectBotHistoryTranscript(
      scope: _dm,
      sessionId: 'legacy',
      rows: rows,
      legacyPrivate: true,
    );
    expect(messages.map((message) => message.reference.messageId), [
      'private',
      'reply',
      'private-delivery',
    ]);
    expect(messages.map((message) => message.text), [
      'What did I say before?',
      'Private reply',
      'Delivered',
    ]);
  });
}

class _Source {
  _Source(Iterable<MemoryHistoryMessage> input)
    : messages = {for (final msg in input) msg.reference: msg};

  final Map<MemoryHistoryReference, MemoryHistoryMessage> messages;
  final loads = <MemoryHistoryScope>[];

  MemoryHistorySource get callbacks => MemoryHistorySource(
    checkpoint: (_) async => 'fixed-test-revision',
    load: (scope) async {
      loads.add(scope);
      return [
        for (final msg in messages.values)
          if (msg.reference.scope == scope) msg,
      ];
    },
    read: (ref) async => messages[ref],
  );
}

MemoryHistoryAccess _access(
  MemoryHistoryScope current, {
  Iterable<MemoryHistoryScope> allowed = const [],
  bool Function(MemoryHistoryScope)? authorized,
}) => MemoryHistoryAccess(
  current: current,
  allowed: allowed,
  isAuthorized: authorized ?? (_) => true,
);

DateTime _at(int seq) => DateTime.utc(2026, 11, 1, 0, seq);

MemoryHistoryMessage _message(
  MemoryHistoryScope scope,
  String session,
  int seq,
  String text,
) => MemoryHistoryMessage(
  reference: MemoryHistoryReference(
    scope: scope,
    sessionId: session,
    messageId: '$seq',
  ),
  role: MemoryHistoryRole.user,
  text: text,
  time: _at(seq),
  sequence: seq,
);

Map<String, Object?> _row(String role, String id, Object content) => {
  'type': role,
  'uuid': id,
  'timestamp': '2026-11-01T00:00:00Z',
  'message': {'role': role, 'content': content},
};
