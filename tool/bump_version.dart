// Sets the app's version for a release: pubspec.yaml's `version:` and
// lib/update/version.dart's appVersionString, which have to agree
// (test/update/version_test.dart), with the build number one past the
// current one. Run from anywhere in the repository:
//
//   dart run tool/bump_version.dart patch     1.2.0+12 -> 1.2.1+13
//   dart run tool/bump_version.dart minor     1.2.0+12 -> 1.3.0+13
//   dart run tool/bump_version.dart major     1.2.0+12 -> 2.0.0+13
//   dart run tool/bump_version.dart 1.2.3     1.2.0+12 -> 1.2.3+13
//
// Personal builds use --personal to increment just the build number, or
// --personal v1.2.3 to reset it to zero after merging that upstream release.
//
// An update is offered when the manifest's version is newer than the app's
// own, with the build number breaking ties
// (docs/auto-update.md). It drafts the release's notes too
// (tool/draft_release_notes.dart). Rewrite them, make the site's changelog
// (tool/build_changelog.dart), then commit, and push the tag it prints: CI
// builds and publishes the release (.github/workflows/release.yml).
import 'dart:io';

import 'package:baocode/update/version.dart';

import 'draft_release_notes.dart';

Future<void> main(List<String> arguments) async {
  final personal = arguments.firstOrNull == '--personal';
  if (personal
      ? arguments.length > 2
      : arguments.length != 1 || arguments.first.startsWith('-')) {
    _fail(
      'Usage: dart run tool/bump_version.dart '
      '<patch|minor|major|x.y.z> | --personal [vX.Y.Z]',
    );
  }
  final root = File.fromUri(Platform.script).parent.parent.absolute;
  final pubspec = File('${root.path}/pubspec.yaml');
  final source = File('${root.path}/lib/update/version.dart');

  final pubspecPattern = RegExp(r'^version:\s*(\S+)', multiLine: true);
  final sourcePattern = RegExp(
    r"^const appVersionString = '([^']*)';",
    multiLine: true,
  );
  final pubspecText = pubspec.readAsStringSync();
  final sourceText = source.readAsStringSync();
  final currentText = pubspecPattern.firstMatch(pubspecText)?.group(1);
  if (currentText == null) _fail('No "version:" line in ${pubspec.path}');
  if (!sourcePattern.hasMatch(sourceText)) {
    _fail('No appVersionString in ${source.path}');
  }
  final current = AppVersion.parse(currentText);

  final upstreamTag = personal && arguments.length == 2 ? arguments[1] : null;
  if (upstreamTag != null &&
      !RegExp(r'^v\d+\.\d+\.\d+$').hasMatch(upstreamTag)) {
    _fail('Give the merged upstream release tag (vX.Y.Z).');
  }
  final argument = personal
      ? upstreamTag?.substring(1) ?? current.marketing
      : arguments.first;
  final marketing = switch (argument) {
    'patch' => '${current.major}.${current.minor}.${current.patch + 1}',
    'minor' => '${current.major}.${current.minor + 1}.0',
    'major' => '${current.major + 1}.0.0',
    _ => argument,
  };
  final parsed = AppVersion.tryParse(marketing);
  if (parsed == null ||
      parsed.build != 0 ||
      !RegExp(r'^\d+\.\d+\.\d+$').hasMatch(marketing)) {
    _fail('Not a version: $argument (give x.y.z, without a build number).');
  }
  final nextText = '$marketing+${upstreamTag == null ? current.build + 1 : 0}';
  final next = AppVersion.parse(nextText);
  if (next <= current) {
    _fail('$nextText would not be newer than $currentText.');
  }
  if (upstreamTag != null) {
    final ref = 'refs/tags/$upstreamTag';
    final tagged = Process.runSync('git', [
      'ls-remote',
      '--exit-code',
      '--sort=refname',
      'upstream',
      ref,
      '$ref^{}',
    ], workingDirectory: root.path);
    if (tagged.exitCode != 0) {
      _fail('Could not verify $upstreamTag on upstream.\n${tagged.stderr}');
    }
    // ls-remote lists the peeled commit last for an annotated tag.
    final commit = (tagged.stdout as String)
        .trim()
        .split('\n')
        .last
        .split('\t')
        .first;
    final merged = Process.runSync('git', [
      'merge-base',
      '--is-ancestor',
      commit,
      'HEAD',
    ], workingDirectory: root.path);
    if (merged.exitCode != 0) {
      _fail(
        'Fetch and merge upstream $upstreamTag before resetting the build.',
      );
    }
  }

  pubspec.writeAsStringSync(
    pubspecText.replaceFirst(pubspecPattern, 'version: $nextText'),
  );
  source.writeAsStringSync(
    sourceText.replaceFirst(
      sourcePattern,
      "const appVersionString = '$nextText';",
    ),
  );
  stdout
    ..writeln('$currentText -> $nextText')
    ..writeln('  ${pubspec.path}')
    ..writeln('  ${source.path}')
    ..writeln();
  if (personal) {
    stdout.writeln(
      upstreamTag == null
          ? 'Commit the version before building personal release v$nextText.'
          : 'Commit the reset. Run --personal without a tag for the first build.',
    );
    return;
  }
  draftReleaseNotes(Directory(root.path), next.marketing);
  stdout
    ..writeln()
    ..writeln('Then commit, and publish with:')
    ..writeln()
    ..writeln(
      '  git tag v${next.marketing} && git push origin v${next.marketing}',
    );
}

Never _fail(String message) {
  stderr.writeln(message);
  exit(1);
}
