// Shared by the app and the release tool. The channel is fixed at build time.
import 'update_signature.dart';
import 'version.dart';

enum UpdateChannel {
  official,
  personal;

  static final build = UpdateChannel.values.byName(
    const String.fromEnvironment(
      'BAOCODE_UPDATE_CHANNEL',
      defaultValue: 'personal',
    ),
  );

  static const officialManifest = 'https://dl.baocode.dev/releases/latest.json';
  static const personalReleases =
      'https://github.com/payAgain/baocode/releases';
  static const personalManifest =
      '$personalReleases/latest/download/latest.json';

  String get manifest => this == personal ? personalManifest : officialManifest;
  String get publicKey =>
      this == personal ? personalUpdatePublicKey : updatePublicKey;

  Uri get downloadPage => Uri.parse(
    this == personal ? personalReleases : 'https://baocode.dev/download',
  );

  Uri releaseNotes(String languageCode, {AppVersion? version}) {
    if (this == personal) {
      if (version == null) return downloadPage;
      return Uri.parse('$personalReleases/tag/${personalTag(version)}');
    }
    return Uri.parse(
      'https://baocode.dev/${languageCode.startsWith('zh') ? 'zh/' : ''}'
      'changelog${version == null ? '' : '#v${version.marketing}'}',
    );
  }

  static String personalTag(AppVersion version) => 'v$version';

  static Uri personalAsset(AppVersion version, String name) => Uri.https(
    'github.com',
    '/payAgain/baocode/releases/download/${personalTag(version)}/$name',
  );
}
