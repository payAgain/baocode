import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bao_link/bao_link.dart';

import 'package:path/path.dart' as p;

import '../chat/composer/composer_files.dart';
import '../l10n/l10n.dart';
import '../workspace/window_controls.dart';

// Wire paths use `/` even for Windows hosts. Never interpret them locally.
final _unsafeSegment = RegExp(r'[/\\:\x00-\x1f\x7f]');
final _dotSegment = RegExp(r'^[. ]+$');

bool remoteFileName(String name) {
  final trimmed = name.trimRight();
  return trimmed.isNotEmpty &&
      !_dotSegment.hasMatch(trimmed) &&
      !_unsafeSegment.hasMatch(name);
}

bool remoteRelativePath(String path) =>
    path.length <= 4096 && path.split('/').every(remoteFileName);

String? remoteImageType(String name) =>
    switch (p.posix.extension(name).toLowerCase()) {
      '.png' => 'image/png',
      '.jpg' || '.jpeg' => 'image/jpeg',
      '.gif' => 'image/gif',
      '.webp' => 'image/webp',
      _ => null,
    };

class RemoteMediaTooLarge implements Exception {
  const RemoteMediaTooLarge(this.limit);

  final int limit;
}

String remoteMediaError(AppLocalizations l10n, Object error) {
  final zh = l10n.localeName.startsWith('zh');
  return switch (error) {
    RemoteMediaTooLarge(:final limit) =>
      zh
          ? '文件超过 ${limit ~/ (1024 * 1024)} MB 上限。'
          : 'The file exceeds the ${limit ~/ (1024 * 1024)} MB limit.',
    LinkRemoteException(code: LinkErrors.notFound) => l10n.placeholderNotFound,
    LinkRemoteException(code: LinkErrors.unknown || LinkErrors.unsupported) =>
      zh ? '此主机不支持此操作。' : 'This host does not support this action.',
    RemoteTooManyImages() =>
      zh
          ? '每条消息最多附加 $remoteAttachmentCount 张图片。'
          : 'Attach up to $remoteAttachmentCount images per message.',
    RemoteUnsupportedImage() =>
      zh
          ? '无法预览此图片，或图片格式不受支持。'
          : 'This image is unsupported or could not be decoded.',
    _ => zh ? '无法完成文件操作。' : 'Could not complete the file action.',
  };
}

Uint8List decodeRemoteBytes(Object? response, int limit) {
  if (response case {'tooLarge': true}) throw RemoteMediaTooLarge(limit);
  if (response case {'data': final String data}) {
    if (data.length > ((limit + 2) ~/ 3) * 4) {
      throw RemoteMediaTooLarge(limit);
    }
    final bytes = base64Decode(data);
    if (bytes.length > limit) throw RemoteMediaTooLarge(limit);
    return bytes;
  }
  throw const FormatException('Invalid host media');
}

/// Pick a local destination before any request. Only the returned native
/// chooser path can be written, and only while this action is still current.
Future<bool> downloadRemoteFile({
  required LinkPeer peer,
  required String project,
  required String path,
  required bool Function() isCurrent,
}) async {
  if (!remoteRelativePath(path) || !isCurrent()) return false;
  final destination = await WindowControls.pickSaveFile(
    name: path.split('/').last,
  );
  if (destination == null || !isCurrent()) return false;
  if (!p.isAbsolute(destination)) {
    throw const FormatException('Invalid save destination');
  }
  final response = await peer.call(LinkMethods.download, {
    'project': project,
    'path': path,
  });
  if (!isCurrent()) return false;
  final bytes = decodeRemoteBytes(response, LinkLimits.download);
  final type = await FileSystemEntity.type(destination, followLinks: false);
  if (type != FileSystemEntityType.file &&
      type != FileSystemEntityType.notFound) {
    throw const FileSystemException('Destination is not a regular file');
  }
  if (!isCurrent()) return false;
  await File(destination).writeAsBytes(bytes, flush: true);
  return isCurrent();
}

typedef DesktopRemoteMediaTarget = (
  LinkPeer peer,
  String kind,
  String id,
  String? project,
);

class DesktopRemoteAttachments {
  DesktopRemoteAttachments(
    this.target,
    Iterable<DesktopRemotePickedImage> images,
    Iterable<DesktopRemoteMention> mentions,
  ) : images = List.unmodifiable(images),
      mentions = List.unmodifiable(mentions);

  final DesktopRemoteMediaTarget target;
  final List<DesktopRemotePickedImage> images;
  final List<DesktopRemoteMention> mentions;

  bool get isEmpty => images.isEmpty && mentions.isEmpty;
}

class DesktopRemoteMention {
  const DesktopRemoteMention._(this.target, this.path);

  final DesktopRemoteMediaTarget target;
  final String path;

  String get reference {
    final text = fileReferenceText(path);
    return parseFileReference(text, 0)?.path == path ? text : '@"$path"';
  }
}

List<DesktopRemoteMention> remoteMentionsIn(
  String text,
  DesktopRemoteMediaTarget target,
  Iterable<DesktopRemoteMention> approved,
) {
  final byPath = {
    for (final mention in approved)
      if (mention.target == target) mention.path: mention,
  };
  if (byPath.isEmpty) return const [];
  final found = <DesktopRemoteMention>{};
  for (
    var offset = text.indexOf('@');
    offset >= 0;
    offset = text.indexOf('@', offset + 1)
  ) {
    if (offset != 0 && !RegExp(r'[\s([{]').hasMatch(text[offset - 1])) continue;
    final reference = parseFileReference(text, offset);
    if (reference == null || reference.directory) continue;
    if (byPath[reference.path] case final mention?) found.add(mention);
    offset = reference.end - 1;
  }
  return found.toList();
}

Future<({List<DesktopRemoteMention> entries, bool truncated})>
remoteProjectMentions(DesktopRemoteMediaTarget target) async {
  final (peer, kind, _, project) = target;
  if (kind != 'project' || project == null || project.isEmpty) {
    throw const FormatException('No host project');
  }
  final result = await peer.call(LinkMethods.files, {'project': project});
  if (result case {'paths': final List<Object?> paths}) {
    return (
      entries: [
        for (final path
            in paths.take(LinkLimits.files).whereType<String>().toSet())
          if (remoteRelativePath(path) && !path.contains('"'))
            DesktopRemoteMention._(target, path),
      ],
      truncated:
          (result as Map)['truncated'] == true ||
          paths.length > LinkLimits.files,
    );
  }
  throw const FormatException('Invalid host file list');
}

const remoteAttachmentLimit = LinkLimits.image;
const remoteAttachmentCount = 8;

class DesktopRemotePickedImage {
  DesktopRemotePickedImage._(this.target, this.name, this.type, this._bytes);

  final DesktopRemoteMediaTarget target;
  final String name;
  final String type;
  final Uint8List _bytes;

  factory DesktopRemotePickedImage.checked({
    required DesktopRemoteMediaTarget target,
    required String name,
    required String type,
    required Uint8List bytes,
    required int availableBytes,
  }) {
    if (bytes.length > availableBytes) {
      throw const RemoteMediaTooLarge(remoteAttachmentLimit);
    }
    if (!remoteImageSignature(bytes, type)) {
      throw const RemoteUnsupportedImage();
    }
    return DesktopRemotePickedImage._(target, name, type, bytes);
  }

  int get size => _bytes.length;
  Map<String, Object?> toWire() => {
    'name': name,
    'type': type,
    'data': base64Encode(_bytes),
  };
}

Future<DesktopRemotePickedImage?> pickRemoteAttachment({
  required DesktopRemoteMediaTarget target,
  required int availableBytes,
  required bool Function() isCurrent,
}) async {
  final selected = await WindowControls.pickOpenFiles(multiple: false);
  if (selected.isEmpty || !isCurrent()) return null;
  final path = selected.single;
  final name = p.basename(path);
  final type = remoteImageType(name);
  if (type == null) throw const RemoteUnsupportedImage();
  final bytes = await _readChosenFile(
    path,
    limit: remoteAttachmentLimit,
    current: isCurrent,
  );
  if (bytes == null) return null;
  return DesktopRemotePickedImage.checked(
    target: target,
    name: name,
    type: type,
    bytes: bytes,
    availableBytes: availableBytes,
  );
}

class RemoteTooManyImages implements Exception {
  const RemoteTooManyImages();
}

class RemoteUnsupportedImage implements Exception {
  const RemoteUnsupportedImage();
}

bool remoteImageSignature(Uint8List bytes, String type) {
  bool containsAt(List<int> prefix, [int offset = 0]) =>
      bytes.length >= offset + prefix.length &&
      prefix.indexed.every((pair) => bytes[offset + pair.$1] == pair.$2);
  return switch (type) {
    'image/png' => containsAt(const [137, 80, 78, 71, 13, 10, 26, 10]),
    'image/jpeg' => containsAt(const [255, 216, 255]),
    'image/gif' =>
      containsAt('GIF87a'.codeUnits) || containsAt('GIF89a'.codeUnits),
    'image/webp' =>
      containsAt('RIFF'.codeUnits) && containsAt('WEBP'.codeUnits, 8),
    _ => false,
  };
}

Future<DesktopRemoteMention?> uploadRemoteFile({
  required DesktopRemoteMediaTarget target,
  required bool Function() isCurrent,
}) async {
  final (peer, kind, id, project) = target;
  final scope = switch (kind) {
    'project' when project != null && project.isNotEmpty => {
      'project': project,
    },
    'bot' when id.isNotEmpty => {'bot': id},
    _ => null,
  };
  if (scope == null || !isCurrent()) return null;
  final selected = await WindowControls.pickOpenFiles(multiple: false);
  if (selected.isEmpty || !isCurrent()) return null;
  final file = selected.single;
  final bytes = await _readChosenFile(
    file,
    limit: LinkLimits.upload,
    current: isCurrent,
  );
  if (bytes == null || !isCurrent()) return null;
  final response = await peer.call(LinkMethods.upload, {
    ...scope,
    'name': p.basename(file),
    'data': base64Encode(bytes),
  });
  if (!isCurrent()) return null;
  if (response case {'tooLarge': true}) {
    throw const RemoteMediaTooLarge(LinkLimits.upload);
  }
  if (response case {'path': final String path} when _remoteUploadPath(path)) {
    return DesktopRemoteMention._(target, path);
  }
  throw const FormatException('Invalid host upload path');
}

bool _remoteUploadPath(String path) =>
    path.length <= 4096 &&
    (p.posix.isAbsolute(path) || p.windows.isAbsolute(path)) &&
    !RegExp(r'["\x00-\x1f\x7f]').hasMatch(path) &&
    !path
        .split(RegExp(r'[/\\]'))
        .any((name) => name.trimRight() == '.' || name.trimRight() == '..') &&
    !path.endsWith('/') &&
    !path.endsWith(r'\');

Future<Uint8List?> _readChosenFile(
  String path, {
  required int limit,
  required bool Function() current,
}) async {
  if (!p.isAbsolute(path) ||
      await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.file) {
    throw const FileSystemException('Selection is not a regular file');
  }
  if (!current()) return null;
  final handle = await File(path).open();
  try {
    if (!current()) return null;
    if (await handle.length() > limit) throw RemoteMediaTooLarge(limit);
    if (!current()) return null;
    final bytes = await handle.read(limit + 1);
    if (bytes.length > limit) throw RemoteMediaTooLarge(limit);
    return current() ? bytes : null;
  } finally {
    await handle.close();
  }
}
