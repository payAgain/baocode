import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../workspace/preference_store.dart';
import 'bot.dart';
import 'bot_memory.dart';
import 'bots.dart';

const botExternalRecallCommand = '/recall-external';

final _providers = Expando<Map<(String, DateTime?), BotMemoryProvider>>();

/// Provider settings belong to the host, outside Bot cards and the Link wire
/// format. Each Bot has its own preference record and consent applies to its
/// saved endpoint only. The creation date prevents reuse after Bot recreation.
BotMemoryProvider? botMemoryProvider(Bots bots, Bot bot) {
  final root = bots.folders.root;
  if (root == null) return null;
  final providers = _providers[bots] ??= {};
  return providers.putIfAbsent((bot.id, bot.created), () {
    final key = sha256.convert(
      utf8.encode(jsonEncode([bot.id, bot.created?.toUtc().toIso8601String()])),
    );
    return BotMemoryProvider(
      PreferenceStore.file(p.join(root, 'external-memory', '$key.json')),
    );
  });
}

/// A read-only HTTPS connector. The configured endpoint must hold only memory
/// intended for this Bot's DM. It accepts POST {"query":"…"} and returns JSON
/// {"results":[{"text":"…"}]}. No Bot ID or authentication is sent.
final class BotMemoryProvider {
  BotMemoryProvider(this._preferences);

  final PreferenceStore _preferences;

  static const _consentVersion = 1;
  static const _timeout = Duration(seconds: 3);
  static const _maxQueryBytes = 512;
  static const _maxResponseBytes = 32 * 1024;
  static const _maxResults = 5;
  static const _maxResultCharacters = 600;
  static final _unsafeUrlCharacters = RegExp(r'[\x00-\x20\x7f\\]');
  static final _urlUserInfo = RegExp(
    r'^https://[^/?#]*@',
    caseSensitive: false,
  );
  static final _queryControls = RegExp(r'[\x00-\x1f\x7f]');

  int _revision = 0;
  bool _updating = false;
  HttpClient? _active;

  static Uri? parseEndpoint(String value) {
    final text = value.trim();
    if (text.length > 2048 ||
        _unsafeUrlCharacters.hasMatch(text) ||
        _urlUserInfo.hasMatch(text)) {
      return null;
    }
    final uri = Uri.tryParse(text);
    if (uri == null ||
        uri.scheme != 'https' ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.authority.contains('@') ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.port < 1 ||
        uri.port > 65535) {
      return null;
    }
    return uri;
  }

  Future<Uri?> enabledEndpoint() async {
    final values = await _preferences.read();
    return switch (values) {
      {'queryConsent': _consentVersion, 'endpoint': final String endpoint} =>
        parseEndpoint(endpoint),
      _ => null,
    };
  }

  /// Called only by the host settings after the user accepts the query notice.
  /// Pass null to revoke consent.
  Future<void> setConsentedEndpoint(Uri? endpoint) async {
    if (endpoint != null && parseEndpoint(endpoint.toString()) != endpoint) {
      throw ArgumentError('Invalid external recall endpoint.');
    }
    final revision = ++_revision;
    _updating = true;
    _active?.close(force: true);
    try {
      await _preferences.write({
        if (endpoint != null) ...{
          'queryConsent': _consentVersion,
          'endpoint': endpoint.toString(),
        },
      });
    } finally {
      if (revision == _revision) _updating = false;
    }
  }

  /// Requires an exact query from a direct user command in the current DM.
  /// [currentDirectMessage] is checked again after asynchronous work.
  Future<List<String>> recall({
    required String query,
    required String? Function() currentDirectMessage,
    Future<void>? cancelled,
  }) async {
    final text = query.trim();
    final command = '$botExternalRecallCommand $text';
    if (text.isEmpty ||
        text.length > _maxQueryBytes ||
        _queryControls.hasMatch(text) ||
        botMemoryHasCredential(text) ||
        utf8.encode(text).length > _maxQueryBytes ||
        currentDirectMessage() != command) {
      return const [];
    }

    final revision = _revision;
    bool authorized() =>
        revision == _revision &&
        !_updating &&
        currentDirectMessage() == command;
    if (!authorized() || _active != null) return const [];

    try {
      final endpoint = await enabledEndpoint();
      if (endpoint == null || !authorized() || _active != null) return const [];
      final client = HttpClient()
        ..connectionTimeout = _timeout
        ..autoUncompress = false;
      _active = client;
      var stopped = false;
      unawaited(
        cancelled?.then((_) {
          stopped = true;
          client.close(force: true);
        }),
      );
      try {
        final results = await _post(
          client,
          endpoint,
          text,
          () => identical(_active, client) && !stopped && authorized(),
        ).timeout(_timeout);
        return stopped || !authorized() ? const [] : results;
      } finally {
        client.close(force: true);
        _active = null;
      }
    } on Object {
      // Remote failures must not suppress local history or expose request data.
      return const [];
    }
  }

  static Future<List<String>> _post(
    HttpClient client,
    Uri endpoint,
    String query,
    bool Function() authorized,
  ) async {
    final request = await client.postUrl(endpoint);
    if (!authorized()) return const [];
    request.followRedirects = false;
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    request.add(utf8.encode(jsonEncode({'query': query})));
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok ||
        response.headers.contentType?.mimeType != 'application/json' ||
        response.contentLength > _maxResponseBytes) {
      return const [];
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response) {
      if (chunk.length > _maxResponseBytes - bytes.length) return const [];
      bytes.add(chunk);
    }
    final decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
    if (decoded case {'results': final List<Object?> rows}) {
      final results = <String>[];
      for (final row in rows) {
        if (row case {'text': final String raw}) {
          final text = raw.trim();
          if (text.isEmpty || botMemoryHasCredential(text)) continue;
          results.add(
            String.fromCharCodes(text.runes.take(_maxResultCharacters)),
          );
          if (results.length == _maxResults) break;
        }
      }
      return results;
    }
    return const [];
  }
}
