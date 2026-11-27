import 'dart:convert';
import 'dart:io';

import 'package:bao_agent/bao_agent.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/harness.dart';

List<Map<String, Object?>> lines(String file) => [
  for (final line in File(file).readAsLinesSync())
    if (line.trim().isNotEmpty)
      (jsonDecode(line) as Map).cast<String, Object?>(),
];

String requestText(ModelRequest request) =>
    jsonEncode(request.body['messages']);

void main() {
  late Harness h;

  tearDown(() => h.dispose());

  test('a turn: init, replay, streamed text, result, idle', () async {
    h = await Harness.start(script: [Reply.text('Hello there.')]);
    final init = await h.request('initialize');
    expect(init['commands'], isNotEmpty);
    expect(init['models'], isNotEmpty);
    expect(init['current_permission_mode'], 'default');
    final messages = await h.turn('Say hello');
    final types = [
      for (final m in messages) '${m['type']}:${m['subtype'] ?? ''}',
    ];
    expect(types.first, 'system:session_state_changed');
    expect(types, contains('system:init'));
    expect(types, contains('command_lifecycle:'));
    expect(types, contains('stream_event:'));
    expect(types, contains('assistant:'));
    expect(types.last, 'system:session_state_changed');
    // Replayed as sent, before it is started.
    final replay = messages.firstWhere((m) => m['isReplay'] == true);
    expect(replay['uuid'], 'user-1');
    expect(types.indexOf('system:init'), lessThan(messages.indexOf(replay)));
    final result = h.lastResult;
    expect(result['subtype'], 'success');
    expect(result['result'], 'Hello there.');
    expect(result['is_error'], false);
    expect(result['num_turns'], 1);
    expect(
      (result['modelUsage'] as Map).values,
      everyElement(contains('contextWindow')),
    );
    expect(result['total_cost_usd'], greaterThan(0));
    // A request status before the request.
    expect(
      h.of('system', 'status').any((m) => m['status'] == 'requesting'),
      isTrue,
    );
    // Every message carries the session's id.
    expect(messages.every((m) => m['session_id'] != null), isTrue);
  });

  test('tool iterations count responses containing tools', () async {
    h = await Harness.start(
      files: {'a.txt': 'A', 'b.txt': 'B', 'c.txt': 'C'},
      script: [
        Reply([
          for (final name in ['a', 'b'])
            {
              'type': 'tool_use',
              'id': 'toolu_$name',
              'name': 'Read',
              'input': {'file_path': '$name.txt'},
            },
        ]),
        Reply.tool('Read', {'file_path': 'c.txt'}),
        Reply.text('Read all three files.'),
      ],
    );
    await h.turn('Read the files');
    expect(h.lastResult['num_turns'], 3);
    expect(h.lastResult['tool_iterations'], 2);
  });

  test(
    'the session file: a chain of lines as Claude Code writes them',
    () async {
      h = await Harness.start(
        script: [
          Reply([
            {'type': 'thinking', 'thinking': 'Let me think.'},
            {'type': 'text', 'text': 'Thought about it.'},
          ]),
        ],
      );
      await h.turn('Think');
      final kept = lines(h.sessionFile);
      // The notes kept for the model (what is left of the budget) are
      // links of the chain too.
      final chain = [
        for (final line in kept)
          if (const {'user', 'assistant', 'attachment'}.contains(line['type']))
            line,
      ];
      expect(chain.first['uuid'], 'user-1');
      expect(chain.first['parentUuid'], isNull);
      for (var i = 1; i < chain.length; i++) {
        expect(chain[i]['parentUuid'], chain[i - 1]['uuid']);
      }
      final conversation = [
        for (final line in chain)
          if (line['type'] == 'user' || line['type'] == 'assistant') line,
      ];
      final answers = conversation
          .where((l) => l['type'] == 'assistant')
          .toList();
      expect(answers, hasLength(2));
      // One line a block, of one message.
      expect(
        (answers[0]['message'] as Map)['id'],
        (answers[1]['message'] as Map)['id'],
      );
      expect(
        ((answers[0]['message'] as Map)['content'] as List).single['type'],
        'thinking',
      );
      for (final line in conversation) {
        expect(line['sessionId'], isNotNull);
        expect(line['cwd'], h.cwd);
        expect(line['timestamp'], isNotNull);
        expect(line['version'], agentVersion);
      }
      // The file is where Claude Code keeps the project's sessions.
      expect(
        h.sessionFile,
        startsWith(
          p.join(
            h.config,
            'projects',
            h.cwd.replaceAll(RegExp('[^a-zA-Z0-9]'), '-'),
          ),
        ),
      );
    },
  );

  test('the request: system prompt, memory, tools, cache marks', () async {
    h = await Harness.start(
      files: {'CLAUDE.md': 'Always answer in French.'},
      script: [Reply.text('Bonjour.')],
    );
    await h.turn('Hi');
    final request = h.model.turns.single;
    final system = request.body['system'] as List;
    expect(jsonEncode(system.first), contains('You are the coding agent'));
    expect(system, hasLength(2));
    final messages = request.body['messages'] as List;
    // The instructions before the prompt, then the context as a system
    // message after it.
    final first = jsonEncode(messages.first);
    expect(first, contains('Always answer in French.'));
    expect((messages[1] as Map)['role'], 'system');
    expect(jsonEncode(messages[1]), contains(h.cwd));
    expect(jsonEncode(messages[1]), contains('Today is'));
    final tools = [
      for (final t in request.body['tools'] as List) (t as Map)['name'],
    ];
    expect(
      tools,
      containsAll([
        'Agent',
        'Bash',
        'Read',
        'Edit',
        'Write',
        'WebFetch',
        'WebSearch',
      ]),
    );
    // Both blocks of the system prompt cached, and the end of the
    // conversation; the tools not.
    expect(jsonEncode(request.body['tools']), isNot(contains('cache_control')));
    for (final block in system) {
      expect(jsonEncode(block), contains('cache_control'));
    }
    expect(jsonEncode(messages.last), contains('cache_control'));
    expect(request.body['stream'], isNull, reason: 'the client sets it');
    expect(request.body['max_tokens'], greaterThan(1000));
    // The session, for a proxy to keep the conversation where it is cached.
    final session = h.engine.session;
    expect(jsonDecode(session.apiConfig().userId!), {
      'session_id': session.sessionId,
    });
  });

  test('restricted host sessions omit workspace memory and hooks', () async {
    h = await Harness.start(
      files: {'CLAUDE.md': 'The workspace memory must not reach this room.'},
      settings: {
        'hooks': {
          'UserPromptSubmit': [
            {
              'hooks': [
                {'type': 'command', 'command': 'echo unexpected-hook-result'},
              ],
            },
          ],
        },
      },
      systemPrompt: 'You are an agent. Reply in this room.',
      restrictedContext: true,
      strictMcpConfig: true,
      tools: [],
      script: [Reply.text('Hello.')],
    );
    await h.turn('Room message');
    final request = h.model.turns.single;
    final body = jsonEncode(request.body);
    expect(body, contains('Reply in this room.'));
    expect(body, isNot(contains('The workspace memory')));
    expect(body, isNot(contains('unexpected-hook-result')));
    expect(request.body['tools'] ?? const [], isEmpty);
  });

  test('restricted host sessions leave @ mentions as plain text', () async {
    h = await Harness.start(
      files: {'notes/private.txt': 'Private workspace contents'},
      systemPrompt: 'You are an agent. Reply in this room.',
      restrictedContext: true,
      strictMcpConfig: true,
      tools: [],
      script: [Reply.text('Hello.')],
    );
    const message = 'Look at @notes/private.txt and @notes/';
    await h.turn(message);
    final sent = requestText(h.model.turns.single);
    expect(sent, contains(message));
    expect(sent, isNot(contains('Private workspace contents')));
    expect(sent, isNot(contains('The user mentioned the folder')));
    expect(
      h.engine.session.mainRun.readFiles[p.join(h.cwd, 'notes/private.txt')],
      isNull,
    );
  });

  test('images and @-mentioned files go to the model', () async {
    h = await Harness.start(
      files: {'lib/a.dart': 'void main() {}\n', 'lib/b.dart': '// b\n'},
      script: [
        Reply.tool('Edit', {
          'file_path': 'PLACEHOLDER',
          'old_string': 'void main() {}',
          'new_string': 'void main() { print(1); }',
        }),
        Reply.text('ok'),
      ],
    );
    // Edited without a Read of its own: the mention read it.
    (h.model.script.first.blocks.single['input'] as Map)['file_path'] = p.join(
      h.cwd,
      'lib/a.dart',
    );
    await h.turn(
      'Look at @lib/a.dart and @lib/',
      blocks: [
        {'type': 'text', 'text': '[Image #1]'},
        {
          'type': 'image',
          'source': {
            'type': 'base64',
            'media_type': 'image/png',
            'data': 'iVBORw0KGgo=',
          },
        },
      ],
    );
    final sent = requestText(h.model.turns.first);
    expect(sent, contains('void main() {}'));
    expect(sent, contains('which Read gives as follows'));
    expect(sent, contains('b.dart'));
    expect(sent, contains('"type":"image"'));
    expect(h.toolResults.single['is_error'], isNot(true));
    expect(h.file('lib/a.dart'), contains('print(1)'));
  });

  test(
    'messages sent while working: later as the next turn, next within',
    () async {
      h = await Harness.start(
        script: [
          Reply.tool('Bash', {'command': 'sleep 0.3', 'description': 'Wait'}),
          Reply.text('first done'),
          Reply.text('second done'),
        ],
      );
      final firstIdle = h.nextIdle();
      h.send('first');
      // Sent while the first works: joins it between its calls.
      await h.messages.firstWhere(
        (m) => m['type'] == 'assistant' && jsonEncode(m).contains('tool_use'),
      );
      h.send('also this', priority: 'next');
      await firstIdle;
      final asked = requestText(h.model.turns[1]);
      expect(asked, contains('also this'));
      final started = [
        for (final m in h.of('command_lifecycle')) m['command_uuid'],
      ];
      expect(started, ['user-1', 'user-2']);
      // Two sent later, while the turn runs: one turn after it, together.
      h.model.script.insert(
        0,
        Reply.tool('Bash', {'command': 'sleep 0.3', 'description': 'Wait'}),
      );
      h.model.script.insert(1, Reply.text('third'));
      final idle = h.nextIdle();
      h.send('third');
      await h.messages.firstWhere(
        (m) => m['type'] == 'assistant' && jsonEncode(m).contains('tool_use'),
      );
      h.send('fourth');
      h.send('fifth');
      await idle;
      await h.nextIdle();
      final last = requestText(h.model.turns.last);
      expect(last, contains('fourth'));
      expect(last, contains('fifth'));
      expect(h.model.turns.length, 5);
    },
  );

  test('a queued message can be taken back', () async {
    h = await Harness.start(
      script: [
        Reply.tool('Bash', {'command': 'sleep 0.3', 'description': 'Wait'}),
        Reply.text('done'),
      ],
    );
    final idle = h.nextIdle();
    h.send('first');
    await h.messages.firstWhere((m) => m['type'] == 'assistant');
    final queued = h.send('second');
    final answer = await h.request('cancel_async_message', {
      'message_uuid': queued,
    });
    expect(answer['cancelled'], isTrue);
    expect(
      h
          .of('command_lifecycle')
          .any((m) => m['command_uuid'] == queued && m['state'] == 'cancelled'),
      isTrue,
    );
    await idle;
    expect(
      (await h.request('cancel_async_message', {
        'message_uuid': 'nope',
      }))['cancelled'],
      isFalse,
    );
    expect(h.model.turns.length, 2);
  });

  test('an interrupt stops the turn and says so', () async {
    h = await Harness.start(
      script: [
        Reply.tool('Bash', {'command': 'sleep 30', 'description': 'Long'}),
        Reply.text('never'),
      ],
    );
    final idle = h.nextIdle();
    h.send('go');
    await h.messages.firstWhere(
      (m) => m['type'] == 'assistant' && jsonEncode(m).contains('tool_use'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await h.request('interrupt');
    await idle.timeout(const Duration(seconds: 10));
    expect(h.lastResult['subtype'], 'error_during_execution');
    final kept = File(h.sessionFile).readAsStringSync();
    expect(kept, contains('[Request interrupted by user for tool use]'));
    // The next turn goes on from there: the call answered.
    h.model.script
      ..clear()
      ..add(Reply.text('resumed'));
    await h.turn('again');
    final asked = h.model.turns.last.body['messages'] as List;
    expect(jsonEncode(asked), contains('interrupted'));
    expect(h.lastResult['result'], 'resumed');
  });

  test('send now stops the turn for a message waiting, the tasks in the '
      'background going on', () async {
    h = await Harness.start(
      script: [
        Reply.tool('Bash', {
          'command': 'sleep 30',
          'description': 'Serve',
          'run_in_background': true,
        }),
        Reply.tool('Bash', {'command': 'sleep 30', 'description': 'Long'}),
        Reply.text('never'),
      ],
    );
    final init = await h.request('initialize');
    expect(init['capabilities'], contains('interrupt_send_now_v1'));
    final idle = h.nextIdle();
    h.send('go');
    await h.messages.firstWhere(
      (m) => m['type'] == 'assistant' && jsonEncode(m).contains('"Long"'),
    );
    expect(
      (await h.request('interrupt', {
        'send_now': true,
        'message_uuid': 'nope',
      }))['send_now'],
      'nothing_waiting',
    );
    final waiting = h.send('stop and do this');
    h.model.script
      ..clear()
      ..add(Reply.text('doing it'));
    expect(
      (await h.request('interrupt', {
        'send_now': true,
        'message_uuid': waiting,
      }))['send_now'],
      'stopped',
    );
    await idle.timeout(const Duration(seconds: 10));
    expect(h.lastResult['subtype'], 'error_during_execution');
    await h.nextIdle().timeout(const Duration(seconds: 10));
    expect(h.lastResult['result'], 'doing it');
    expect(
      jsonEncode(h.model.turns.last.body['messages']),
      contains('stop and do this'),
    );
    expect(h.of('system', 'task_started'), hasLength(1));
    expect(
      h.of('system').where((m) => m['subtype'] == 'task_notification'),
      isEmpty,
    );
  });

  test('a message of priority now stops the turn running', () async {
    h = await Harness.start(
      script: [
        Reply.tool('Bash', {'command': 'sleep 30', 'description': 'Long'}),
        Reply.text('never'),
      ],
    );
    final idle = h.nextIdle();
    h.send('go');
    await h.messages.firstWhere(
      (m) => m['type'] == 'assistant' && jsonEncode(m).contains('tool_use'),
    );
    h.model.script
      ..clear()
      ..add(Reply.text('now then'));
    h.send('this first', priority: 'now');
    await idle.timeout(const Duration(seconds: 10));
    await h.nextIdle().timeout(const Duration(seconds: 10));
    expect(h.lastResult['result'], 'now then');
  });

  test('an interrupt while streaming text', () async {
    h = await Harness.start(script: [Reply.text('x' * 400)]);
    h.model.delay = const Duration(milliseconds: 100);
    final idle = h.nextIdle();
    h.send('go');
    await h.messages.firstWhere((m) => m['type'] == 'stream_event');
    await h.request('interrupt');
    await idle;
    expect(h.lastResult['subtype'], 'error_during_execution');
  });

  test('a session resumed goes on with its conversation', () async {
    h = await Harness.start(script: [Reply.text('The answer is 42.')]);
    await h.turn('What is the answer?');
    final id = h.lastResult['session_id'] as String;
    await h.engine.close();
    final first = h;
    h = await Harness.start(
      from: first,
      resume: id,
      script: [Reply.text('I said 42.')],
    );
    await h.turn('What did you say?');
    final asked = requestText(h.model.turns.single);
    expect(asked, contains('What is the answer?'));
    expect(asked, contains('The answer is 42.'));
    expect(h.lastResult['session_id'], id);
  });

  test(
    'managed transcripts share configuration but resume only in their project',
    () async {
      const id = 'a3da19b6-9c8c-4a2b-92b5-f267b398bddc';
      h = await Harness.start(
        sessionId: id,
        settings: {
          'env': {'ANTHROPIC_BASE_URL': 'https://shared-settings.invalid'},
        },
        script: [Reply.text('Legacy answer')],
      );
      await h.turn('Legacy question');
      await h.engine.close();
      final legacy = File(h.sessionFile);
      final legacyText = legacy.readAsStringSync();
      File(p.join(h.config, 'skills', 'shared-config', 'SKILL.md'))
        ..createSync(recursive: true)
        ..writeAsStringSync('Say hello from the shared config.');
      final projects = p.join(h.root, 'managed', 'projects');

      final managed = await Harness.start(
        from: h,
        sessionId: id,
        transcriptProjectsDir: projects,
        script: [Reply.text('Managed answer')],
      );
      addTearDown(managed.dispose);
      await managed.turn('Managed question');
      expect(managed.lastResult['session_id'], id);
      final session = managed.engine.session;
      final path = p.join(
        projects,
        p.basename(legacy.parent.path),
        '$id.jsonl',
      );
      expect(session.store.file, path);
      expect(File(path).readAsStringSync(), contains('Managed answer'));
      expect(session.apiConfig().baseUrl, 'https://shared-settings.invalid');
      expect(
        session.promptCommands.map((command) => command.name),
        contains('shared-config'),
      );
      expect(session.autoMemoryDir, p.join(legacy.parent.path, 'memory'));
      expect(session.paths.findSession(id), path);
      final options = EngineOptions.fromJson(managed.engine.options.toJson());
      expect(options.transcriptProjectsDir, projects);
      expect(options.configDir, h.config);
      expect(options.sessionId, id);
      await managed.engine.close();

      final resumed = await Harness.start(
        from: h,
        resume: id,
        transcriptProjectsDir: projects,
        script: [Reply.text('Managed followup')],
      );
      addTearDown(resumed.dispose);
      await resumed.turn('What did you say?');
      final asked = requestText(resumed.model.turns.single);
      expect(asked, contains('Managed question'));
      expect(asked, contains('Managed answer'));
      expect(asked, isNot(contains('Legacy')));
      await resumed.engine.close();
      expect(legacy.readAsStringSync(), legacyText);

      final otherProject = Directory(p.join(projects, 'other-project'))
        ..createSync();
      File(path).renameSync(p.join(otherProject.path, '$id.jsonl'));
      final missing = await Harness.start(
        from: h,
        resume: id,
        transcriptProjectsDir: projects,
      );
      addTearDown(missing.dispose);
      await expectLater(missing.request('initialize'), throwsStateError);
      await missing.turn('Do not fall back');
      expect(missing.lastResult['is_error'], isTrue);
      expect(missing.lastResult['result'], contains('Managed transcript'));
      expect(missing.model.turns, isEmpty);
      expect(File(path).existsSync(), isFalse);
      expect(legacy.readAsStringSync(), legacyText);
    },
  );

  test('prompt suggestions and a title, when asked for', () async {
    h = await Harness.start(
      promptSuggestions: true,
      script: [Reply.text('Tests added. Want me to run them?')],
      errands: (request) {
        final system = jsonEncode(request.body['system']);
        if (system.contains('name conversations')) {
          return Reply.text('Adding tests');
        }
        if (system.contains('predict the next message')) {
          return Reply.text('Run the tests');
        }
        return null;
      },
    );
    final suggestion = h.messages.firstWhere(
      (m) => m['type'] == 'prompt_suggestion',
    );
    await h.turn('Add tests');
    expect(
      (await suggestion.timeout(const Duration(seconds: 5)))['suggestion'],
      'Run the tests',
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(
      File(h.sessionFile).readAsStringSync(),
      contains('"aiTitle":"Adding tests"'),
    );
  });

  test('a rename is kept as the title', () async {
    h = await Harness.start(script: [Reply.text('ok')]);
    await h.turn('hi');
    await h.request('rename_session', {'title': 'My session'});
    expect(
      File(h.sessionFile).readAsStringSync(),
      contains('"customTitle":"My session"'),
    );
    expect(() => h.request('rename_session', {'title': ''}), throwsStateError);
  });

  test('without a key the turn says how to set one up', () async {
    h = await Harness.start(script: [], environment: {'ANTHROPIC_API_KEY': ''});
    // The harness's client stands in for the API: a real one has no key.
    final engine = AgentEngine(
      EngineOptions(
        cwd: h.cwd,
        environment: {'HOME': h.root, 'CLAUDE_CONFIG_DIR': h.config},
        configDir: h.config,
      ),
      send: (m) {
        if (m['type'] == 'result') _results.add(m);
      },
    );
    engine.receive({
      'type': 'user',
      'uuid': 'u',
      'message': {'role': 'user', 'content': 'hi'},
    });
    for (var i = 0; i < 100 && _results.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(_results.single['is_error'], isTrue);
    expect(_results.single['result'], contains('API key'));
    await engine.close();
  });
}

final _results = <Map<String, Object?>>[];
