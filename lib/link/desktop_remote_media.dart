import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:bao_link/bao_link.dart';

import 'package:path/path.dart' as p;

import '../chat/chat_models.dart';
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
  _checkDownloadDestination(destination);
  final response = await peer.fetch(LinkMethods.download, {
    'project': project,
    'path': path,
    'pieces': true,
  });
  final Stream<Uint8List> bytes;
  if (response is LinkPieces) {
    bytes = response.bytes;
  } else {
    if (!isCurrent()) return false;
    bytes = Stream.value(decodeRemoteBytes(response, LinkLimits.download));
  }

  File? temporary;
  RandomAccessFile? output;
  try {
    // Start consuming pieces even if the action has gone stale. Returning
    // from inside the loop cancels the stream, as does a local write error.
    await for (final piece in bytes) {
      if (!isCurrent()) return false;
      if (output == null) {
        final file = temporary = await _downloadTemporary(destination);
        output = await file.open(mode: FileMode.write);
        if (!isCurrent()) return false;
      }
      await output.writeFrom(piece);
    }
    if (!isCurrent()) return false;
    if (output == null) {
      temporary = await _downloadTemporary(destination); // Empty file.
    } else {
      await output.flush();
      await output.close();
      output = null;
    }
    // Validate and rename without yielding after the final scope check.
    if (!isCurrent()) return false;
    _checkDownloadDestination(destination);
    temporary!.renameSync(destination);
    temporary = null;
    return true;
  } finally {
    try {
      await output?.close();
    } finally {
      try {
        await temporary?.delete();
      } on FileSystemException {
        // Preserve the original failure if the temporary file is inaccessible.
      }
    }
  }
}

void _checkDownloadDestination(String path) {
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  if (type != FileSystemEntityType.file &&
      type != FileSystemEntityType.notFound) {
    throw const FileSystemException('Destination is not a regular file');
  }
}

Future<File> _downloadTemporary(String destination) {
  final random = Random.secure();
  final suffix = List.generate(
    4,
    (_) => random.nextInt(1 << 30).toRadixString(36),
  ).join('-');
  return File(p.join(p.dirname(destination), '.baocode-download-$suffix'))
      .create(exclusive: true);
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

/// An image in a saved draft. Keep its authenticated conversation scope but
/// release the connection that originally supplied that scope.
class DesktopRemoteDraftImage {
  DesktopRemoteDraftImage._(
    DesktopRemoteMediaTarget target,
    this.name,
    this.type,
    Uint8List bytes,
  ) : _scope = _scopeOf(target),
      _bytes = Uint8List.fromList(bytes).asUnmodifiableView();

  final (String, String, String, String?) _scope;
  final String name;
  final String type;
  final Uint8List _bytes;

  late final ImageAttachment preview = ImageAttachment(
    bytes: _bytes,
    mediaType: type,
    name: name,
  );

  static (String, String, String, String?) _scopeOf(
    DesktopRemoteMediaTarget target,
  ) => (target.$1.remote, target.$2, target.$3, target.$4);

  DesktopRemotePickedImage? bind(DesktopRemoteMediaTarget target) =>
      target.$1.isClosed || _scopeOf(target) != _scope
      ? null
      : DesktopRemotePickedImage._(target, this);
}

class DesktopRemotePickedImage {
  DesktopRemotePickedImage._(this.target, this.snapshot);

  final DesktopRemoteMediaTarget target;
  final DesktopRemoteDraftImage snapshot;

  String get name => snapshot.name;
  String get type => snapshot.type;

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
    return DesktopRemotePickedImage._(
      target,
      DesktopRemoteDraftImage._(target, name, type, bytes),
    );
  }

  int get size => snapshot._bytes.length;
  Map<String, Object?> toWire() => {
    'name': name,
    'type': type,
    'data': base64Encode(snapshot._bytes),
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
  await _checkChosenFile(file);
  if (!isCurrent()) return null;
  final handle = await File(file).open();
  final params = {...scope, 'name': p.basename(file)};
  Object? response;
  try {
    final size = await handle.length();
    if (!isCurrent()) return null;
    try {
      response = await peer.callWithPieces(
        LinkMethods.uploadPieces,
        params,
        size,
        _chosenPieces(handle, size, isCurrent),
      );
    } on _RemoteUploadStale {
      return null;
    } on LinkRemoteException catch (error) {
      if (error.code != LinkErrors.unknown) rethrow;
      if (!isCurrent()) return null;
      // An old host explicitly declined this method. Never retry a failed
      // write or a lost reply: the host may already have saved the file.
      if (size > LinkLimits.upload) {
        throw const RemoteMediaTooLarge(LinkLimits.upload);
      }
      await handle.setPosition(0);
      if (!isCurrent()) return null;
      final bytes = await handle.read(LinkLimits.upload + 1);
      if (!isCurrent()) return null;
      if (bytes.length > LinkLimits.upload) {
        throw const RemoteMediaTooLarge(LinkLimits.upload);
      }
      response = await peer.call(LinkMethods.upload, {
        ...params,
        'data': base64Encode(bytes),
      });
    }
  } finally {
    await handle.close();
  }
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

class _RemoteUploadStale implements Exception {
  const _RemoteUploadStale();
}

Stream<Uint8List> _chosenPieces(
  RandomAccessFile handle,
  int size,
  bool Function() current,
) async* {
  var remaining = size;
  while (true) {
    if (!current()) throw const _RemoteUploadStale();
    if (remaining == 0) return;
    final piece = await handle.read(min(remaining, LinkLimits.piece));
    if (!current()) throw const _RemoteUploadStale();
    if (piece.isEmpty) return; // Link rejects a shortened upload.
    remaining -= piece.length;
    yield piece;
  }
}

Future<void> _checkChosenFile(String path) async {
  if (!p.isAbsolute(path) ||
      await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.file) {
    throw const FileSystemException('Selection is not a regular file');
  }
}

Future<Uint8List?> _readChosenFile(
  String path, {
  required int limit,
  required bool Function() current,
}) async {
  await _checkChosenFile(path);
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
