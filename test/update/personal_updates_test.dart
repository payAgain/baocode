import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:baocode/ide/ide_notifications.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/update/installer_io.dart';
import 'package:baocode/update/update_channel.dart';
import 'package:baocode/update/update_controller.dart';
import 'package:baocode/update/update_io.dart';
import 'package:baocode/update/update_manifest.dart';
import 'package:baocode/update/update_service.dart';
import 'package:baocode/update/version.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'update_fakes.dart';

void main() {
  final personalManifest = Uri.parse(
    'https://github.com/payAgain/baocode/releases/latest/download/latest.json',
  );

  test(
    'personal build ignores the runtime update URL and uses an isolated cache',
    () {
      final updates = platformUpdates(
        updatesDirectory: p.join('data', 'updates'),
        releaseMode: true,
        environment: {
          manifestUrlVariable: 'https://dl.baocode.dev/releases/latest.json',
        },
      )!;
      expect(updates.manifestUrl, personalManifest);
      expect(
        (updates.backend as IoUpdateBackend).directory,
        p.join('data', 'updates-personal'),
      );
      expect(
        updates.installer.log,
        p.join('data', 'updates-personal', 'install.log'),
      );
    },
    skip: !(Platform.isMacOS || Platform.isWindows || Platform.isLinux),
  );

  test('personal manifest limits downloads to the fork release paths', () {
    final policy = UpdateUrlPolicy.forManifest(personalManifest);
    final base = 'https://github.com/payAgain/baocode/releases/download';
    expect(policy.allows(Uri.parse('$base/v2.0.3+37/BaoCode.zip')), isTrue);
    for (final url in [
      'https://dl.baocode.dev/releases/2.0.3/BaoCode.zip',
      'https://github.com/baocode-dev/baocode/releases/download/v2.0.3/BaoCode.zip',
      'https://github.com/payAgain/baocode-other/releases/download/v2.0.3/BaoCode.zip',
      'https://github.com/payAgain/baocode/blob/main/BaoCode.zip',
      'https://release-assets.githubusercontent.com/BaoCode.zip',
      '$base/v2.0.3+37/bad%2Fname.zip',
      '$base/v2.0.3+37/bad%5Cname.zip',
      '$base/v2.0.3+37/BaoCode.zip?next=other',
    ]) {
      expect(policy.allows(Uri.parse(url)), isFalse, reason: url);
    }
  });

  test(
    'personal redirects can only reach a fork attachment or GitHub release CDN',
    () {
      final tagged = UpdateChannel.personalAsset(
        AppVersion.parse('2.0.3+36'),
        'latest.json',
      );
      final cdn = Uri.parse(
        'https://release-assets.githubusercontent.com/github-production-release-asset/42/asset?sig=test',
      );
      expect(
        UpdateUrlPolicy.allowsPersonalRedirect(personalManifest, tagged),
        isTrue,
      );
      expect(UpdateUrlPolicy.allowsPersonalRedirect(tagged, cdn), isTrue);
      for (final url in [
        UpdateChannel.personalAsset(
          AppVersion.parse('2.0.3+36'),
          'BaoCode.zip',
        ),
        Uri.parse(UpdateChannel.officialManifest),
        Uri.parse(
          'https://github.com/baocode-dev/baocode/releases/download/v2.0.3/latest.json',
        ),
        Uri.parse(
          'https://release-assets.githubusercontent.com.example/github-production-release-asset/42',
        ),
      ]) {
        expect(
          UpdateUrlPolicy.allowsPersonalRedirect(personalManifest, url),
          isFalse,
          reason: '$url',
        );
      }
      expect(
        UpdateUrlPolicy.allowsPersonalRedirect(cdn, personalManifest),
        isFalse,
      );
    },
  );

  test(
    'an empty personal feed is reported without fetching an alternative',
    () async {
      final backend = FakeBackend('')
        ..fetchError = const UpdateManifestNotFound();
      final service = UpdateService(
        current: AppVersion.parse('2.0.3+36'),
        platform: 'macos-arm64',
        backend: backend,
        installer: FakeInstaller(),
        channel: UpdateChannel.personal,
        manifestUrl: personalManifest,
      );
      addTearDown(service.dispose);
      expect(await service.check(manual: true), isA<UpdateNotPublished>());
      expect(backend.fetches, 1);
      expect(service.status, UpdateStatus.notPublished);
      expect(service.release, isNull);
      expect(service.installed, isNull);
      expect(service.error, isNull);
      expect(service.lastChecked, isNotNull);
    },
  );

  test(
    'a personal release with a non-personal signature is never offered',
    () async {
      final fake = FakeBackend(
        manifestOf('2.0.3+36').replaceAll(
          'https://baocode.dev/releases/2.0.3+36/',
          'https://github.com/payAgain/baocode/releases/download/v2.0.3+36/',
        ),
      );
      final service = _personalService(fake, FakeInstaller());
      addTearDown(service.dispose);
      final result = await service.check(manual: true);
      expect(
        result,
        isA<UpdateCheckFailed>().having(
          (failure) => failure.error,
          'error',
          isA<UpdateVerificationException>(),
        ),
      );
      expect(service.release, isNull);
      expect(fake.downloads, isEmpty);
    },
  );

  test('personal backend blocks disallowed redirects before making the next request', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.statusCode = HttpStatus.found;
      request.response.headers.set(
        HttpHeaders.locationHeader,
        UpdateChannel.officialManifest,
      );
      await request.response.close();
    });
    final requested = <Uri>[];
    final client = _MappedClient(server, requested);
    final backend = IoUpdateBackend(
      directory: 'unused',
      channel: UpdateChannel.personal,
      client: () => client,
    );
    await expectLater(
      backend.fetchManifest(personalManifest),
      throwsA(
        isA<HttpException>().having(
          (e) => e.message,
          'message',
          contains('redirect'),
        ),
      ),
    );
    expect(requested, [personalManifest]);
  });

  // Opt-in integration with a fixture signed by the release tool. Only the
  // signed manifest and fixture bytes are given to the client test.
  const fixturePath = String.fromEnvironment('BAOCODE_TEST_PERSONAL_MANIFEST');
  test(
    'real personal signature, redirect, cache and manual links',
    () async {
      final fixture = File(fixturePath);
      final text = await fixture.readAsString();
      final manifest = UpdateManifest.parse(
        text,
        policy: const UpdateUrlPolicy.personal(),
      );
      final asset = manifest.assetFor('macos-arm64')!;
      final contents = await File(p.join(fixture.parent.path, asset.fileName))
          .readAsBytes();
      final tagged = UpdateChannel.personalAsset(
        manifest.version,
        'latest.json',
      );
      final manifestCdn = Uri.parse(
        'https://release-assets.githubusercontent.com/github-production-release-asset/42/manifest',
      );
      final assetCdn = manifestCdn.replace(
        path: '/github-production-release-asset/42/installer',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      List<int> assetBody = contents;
      server.listen((request) async {
        final response = request.response;
        final path = request.uri.path;
        if (path == personalManifest.path) {
          response.statusCode = HttpStatus.found;
          response.headers.set(HttpHeaders.locationHeader, '$tagged');
        } else if (path == tagged.path) {
          response.statusCode = HttpStatus.found;
          response.headers.set(HttpHeaders.locationHeader, '$manifestCdn');
        } else if (path == manifestCdn.path) {
          response.add(utf8.encode(text));
        } else if (path == asset.url.path) {
          response.statusCode = HttpStatus.found;
          response.headers.set(HttpHeaders.locationHeader, '$assetCdn');
        } else if (path == assetCdn.path) {
          response.add(assetBody);
        } else {
          response.statusCode = HttpStatus.notFound;
        }
        await response.close();
      });
      final dir = await Directory(fixture.parent.path).createTemp('cache-');
      addTearDown(() => dir.delete(recursive: true));
      final requested = <Uri>[];
      final backend = IoUpdateBackend(
        directory: dir.path,
        channel: UpdateChannel.personal,
        client: () => _MappedClient(server, requested),
      );
      final installer = FakeInstaller()
        ..prepareError = const ManualUpdateRequired('read-only');
      final service = _personalService(backend, installer);
      addTearDown(service.dispose);
      final found = await service.check(manual: true) as UpdateFound;
      expect(requested, [personalManifest, tagged, manifestCdn]);
      final file = File(await service.download());
      expect(await file.readAsBytes(), contents);
      expect(requested, [
        personalManifest,
        tagged,
        manifestCdn,
        asset.url,
        assetCdn,
      ]);

      final release = found.offer.release;
      final official = IoUpdateBackend(directory: dir.path);
      expect(
        await official.verify(file, release),
        'The download is not signed by BaoCode',
      );
      final notifications = IdeNotifications();
      addTearDown(notifications.dispose);
      final opened = <Uri>[];
      final controller = UpdateController(
        service: service,
        openUrl: (url) async => opened.add(url),
        quit: () async => fail('manual update should keep the app running'),
      );
      final offer = controller.showOffer(
        notifications,
        englishLocalizations,
        found.offer,
      );
      offer.secondary.single.run();
      await controller.restart(notifications, englishLocalizations);
      notifications.notifications.first.primary.single.run();
      expect(opened.map((url) => '$url'), [
        'https://github.com/payAgain/baocode/releases/tag/v${manifest.version}',
        'https://github.com/payAgain/baocode/releases',
      ]);

      final altered = List<int>.of(contents)..[0] ^= 0xff;
      await file.writeAsBytes(altered);
      assetBody = altered;
      await expectLater(
        backend.download(release),
        throwsA(
          isA<UpdateVerificationException>().having(
            (e) => e.message,
            'message',
            contains('SHA-256'),
          ),
        ),
      );
      expect(await file.exists(), isFalse);
      expect(await File('${file.path}.part').exists(), isFalse);
    },
    skip: fixturePath.isEmpty
        ? 'Set BAOCODE_TEST_PERSONAL_MANIFEST to a signed test fixture'
        : false,
  );

  test('a withdrawn personal release cannot finish preparing', () async {
    final backend = FakeBackend(await File(fixturePath).readAsString());
    final installer = FakeInstaller();
    final service = _personalService(backend, installer);
    addTearDown(service.dispose);
    expect(await service.check(manual: true), isA<UpdateFound>());
    final gate = backend.gate = Completer<void>();
    final preparing = service.prepare();
    final rejected = expectLater(preparing, throwsStateError);
    backend.fetchError = const UpdateManifestNotFound();
    expect(await service.check(manual: true), isA<UpdateNotPublished>());
    gate.complete();
    await rejected;
    expect(installer.prepared, isEmpty);
    expect(service.status, UpdateStatus.notPublished);
  }, skip: fixturePath.isEmpty);

  test('live fork responds with no published version', () async {
    final backend = IoUpdateBackend(
      directory: 'unused',
      channel: UpdateChannel.personal,
      client: () => _RealHttp().createHttpClient(null),
    );
    final service = _personalService(backend, FakeInstaller());
    addTearDown(service.dispose);
    expect(await service.check(manual: true), isA<UpdateNotPublished>());
  }, skip: !const bool.fromEnvironment('BAOCODE_TEST_EMPTY_LIVE_FEED'));
}

UpdateService _personalService(
  UpdateBackend backend,
  UpdateInstaller installer,
) => UpdateService(
  current: AppVersion.parse('2.0.3+35'),
  platform: 'macos-arm64',
  channel: UpdateChannel.personal,
  backend: backend,
  installer: installer,
);

class _RealHttp extends HttpOverrides {}

/// Routes the expected HTTPS endpoints to a loopback server while keeping
/// Dart's real redirects, response streaming and request headers in play.
class _MappedClient implements HttpClient {
  _MappedClient(this.server, this.requested);

  final HttpServer server;
  final List<Uri> requested;
  final HttpClient _client = _RealHttp().createHttpClient(null);

  @override
  set connectionTimeout(Duration? value) => _client.connectionTimeout = value;

  @override
  set userAgent(String? value) => _client.userAgent = value;

  @override
  Future<HttpClientRequest> getUrl(Uri url) {
    requested.add(url);
    return _client.getUrl(
      Uri(scheme: 'http', host: '127.0.0.1', port: server.port, path: url.path),
    );
  }

  @override
  void close({bool force = false}) => _client.close(force: force);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
