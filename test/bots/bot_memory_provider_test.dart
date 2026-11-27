import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baocode/bots/bot_memory_provider.dart';
import 'package:baocode/workspace/preference_store.dart';
import 'package:flutter_test/flutter_test.dart';

const query = '红茶 green tea';
const command = '$botExternalRecallCommand $query';
final endpoint = Uri.parse('https://memory.invalid/recall');

Future<void> _withFake(
  Future<void> Function(BotMemoryProvider, _Client, MemoryPreferenceStore)
  verify,
) async {
  final prefs = MemoryPreferenceStore();
  final provider = BotMemoryProvider(prefs);
  final client = _Client();
  await HttpOverrides.runZoned(
    () => verify(provider, client, prefs),
    createHttpClient: (_) {
      client.created++;
      return client;
    },
  );
}

void main() {
  test('disallows unsafe URLs and permits a neutral HTTPS path', () {
    for (final bad in [
      'http://memory.invalid/recall',
      'https:///recall',
      'https://someone:sample-fixture-password@memory.invalid/recall',
      'https://someone@memory.invalid/recall',
      'https://@memory.invalid/recall',
      'https://memory.invalid/recall?key=secret',
      'https://memory.invalid/recall?',
      'https://memory.invalid/recall#x',
      'https://memory.invalid:0/recall',
      'https://memory.invalid:6000000/recall',
      'https://memory.invalid\\recall',
      'https://memory.invalid/some path',
    ]) {
      expect(BotMemoryProvider.parseEndpoint(bad), isNull, reason: bad);
    }
    expect(BotMemoryProvider.parseEndpoint(endpoint.toString()), endpoint);
  });

  test('creates no client without endpoint-bound consent', () async {
    await _withFake((provider, client, prefs) async {
      Future<void> check() async {
        expect(
          await provider.recall(
            query: query,
            currentDirectMessage: () => command,
          ),
          isEmpty,
        );
        expect(client.created, 0);
      }

      await check();
      prefs.preferences = {'endpoint': endpoint.toString()};
      await check();
      prefs.preferences = {
        'queryConsent': '1',
        'endpoint': endpoint.toString(),
      };
      await check();
      prefs.preferences = {
        'queryConsent': 1,
        'endpoint': 'http://memory.invalid',
      };
      await check();
    });
  });

  test('requires an exact live direct command and refuses secret and oversized queries', () async {
    await _withFake((provider, client, _) async {
      await provider.setConsentedEndpoint(endpoint);
      for (final message in [null, query, '$command more', 'hello $command']) {
        expect(
          await provider.recall(
            query: query,
            currentDirectMessage: () => message,
          ),
          isEmpty,
        );
      }
      for (final bad in ['api key: test-only-1234', '中' * 400, 'x\ny']) {
        expect(
          await provider.recall(
            query: bad,
            currentDirectMessage: () => '$botExternalRecallCommand $bad',
          ),
          isEmpty,
        );
      }
      expect(client.created, 0);
    });
  });

  test(
    'consented request sends only exact query, reads bounded plain snippets',
    () async {
      await _withFake((provider, client, _) async {
        await provider.setConsentedEndpoint(endpoint);
        final long = '🟩' * 650;
        client.request.response = _Response(
          jsonEncode({
            'results': [
              {
                'text': '   one    ',
                'reference': {'id': 'forged'},
              },
              {'text': 'password: sample-fixture-password'},
              {'text': long},
              {'text': '3'},
              {'text': '4'},
              {'text': '5'},
              {'text': '6'},
              {'id': 'skip'},
            ],
          }),
        );
        final found = await provider.recall(
          query: query,
          currentDirectMessage: () => command,
        );
        expect(client.created, 1);
        expect(client.endpoint, endpoint);
        expect(client.request.followRedirects, isFalse);
        expect(client.request.headers.contentType, ContentType.json);
        expect(client.request.headers.values, {
          HttpHeaders.acceptHeader: 'application/json',
          HttpHeaders.acceptEncodingHeader: 'identity',
        });
        expect(jsonDecode(utf8.decode(client.request.body)), {'query': query});
        expect(found, ['one', '🟩' * 600, '3', '4', '5']);
        expect(client.closed, isTrue);
      });
    },
  );

  test('redirect, malformed JSON, and declared or streamed oversized bodies yield no results', () async {
    for (final failure in [
      _Response('{}', statusCode: 307),
      _Response('{'),
      _Response('x' * 33000, contentLength: 33000),
      _Response('x' * 33000),
      _Response('[]', mimeType: ContentType.text),
    ]) {
      await _withFake((provider, client, _) async {
        await provider.setConsentedEndpoint(endpoint);
        client.request.response = failure;
        expect(
          await provider.recall(
            query: query,
            currentDirectMessage: () => command,
          ),
          isEmpty,
        );
        expect(client.request.followRedirects, isFalse);
        expect(client.created, 1);
        expect(client.closed, isTrue);
      });
    }
  });

  test('revoking consent during connection prevents a request body', () async {
    await _withFake((provider, client, _) async {
      await provider.setConsentedEndpoint(endpoint);
      final opened = Completer<HttpClientRequest>();
      client.opened = opened;
      final recall = provider.recall(
        query: query,
        currentDirectMessage: () => command,
      );
      await client.connecting.future;
      await provider.setConsentedEndpoint(null);
      opened.complete(client.request);
      expect(await recall, isEmpty);
      expect(client.closed, isTrue);
      expect(client.request.body, isEmpty);
      expect(
        await provider.recall(
          query: query,
          currentDirectMessage: () => command,
        ),
        isEmpty,
      );
      expect(client.created, 1);
    });
  });

  test(
    'a changed DM and a cancelled call prevent writing a pending request',
    () async {
      for (final cancel in [false, true]) {
        await _withFake((provider, client, _) async {
          await provider.setConsentedEndpoint(endpoint);
          var message = command;
          final cancelled = Completer<void>();
          final opened = Completer<HttpClientRequest>();
          client.opened = opened;
          final recall = provider.recall(
            query: query,
            currentDirectMessage: () => message,
            cancelled: cancelled.future,
          );
          await client.connecting.future;
          if (cancel) {
            cancelled.complete();
          } else {
            message = '';
          }
          opened.complete(client.request);
          expect(await recall, isEmpty);
          expect(client.request.body, isEmpty);
        });
      }
    },
  );

  test(
    'a response that never finishes is bounded by the overall timeout',
    () async {
      await _withFake((provider, client, _) async {
        await provider.setConsentedEndpoint(endpoint);
        client.request.pendingResponse = Completer<HttpClientResponse>();
        expect(
          await provider.recall(
            query: query,
            currentDirectMessage: () => command,
          ),
          isEmpty,
        );
        expect(client.created, 1);
        expect(client.closed, isTrue);
      });
    },
  );
}

class _Client implements HttpClient {
  int created = 0;
  Uri? endpoint;
  bool closed = false;
  @override
  Duration? connectionTimeout;
  @override
  bool autoUncompress = true;
  Completer<HttpClientRequest>? opened;
  final connecting = Completer<void>();
  final request = _Request();

  @override
  Future<HttpClientRequest> postUrl(Uri url) async {
    endpoint = url;
    connecting.complete();
    return opened == null ? request : opened!.future;
  }

  @override
  void close({bool force = false}) {
    expect(force, isTrue);
    closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  @override
  bool followRedirects = true;
  @override
  final _Headers headers = _Headers();
  _Response response = _Response('{"results":[{"text":"default"}]}');
  Completer<HttpClientResponse>? pendingResponse;
  final body = <int>[];

  @override
  void add(List<int> data) => body.addAll(data);

  @override
  Future<HttpClientResponse> close() async =>
      pendingResponse?.future ?? response;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Headers implements HttpHeaders {
  @override
  ContentType? contentType;
  final values = <String, Object>{};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      values[name] = value;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(
    String body, {
    this.statusCode = 200,
    this.contentLength = -1,
    ContentType? mimeType,
  }) : _body = Stream.value(utf8.encode(body)),
       headers = (_Headers()..contentType = mimeType ?? ContentType.json);

  final Stream<List<int>> _body;
  @override
  final int statusCode;
  @override
  final int contentLength;
  @override
  final HttpHeaders headers;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _body.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
