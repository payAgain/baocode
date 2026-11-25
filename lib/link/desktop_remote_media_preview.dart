import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:bao_link/bao_link.dart';
import 'package:flutter/material.dart';
import 'package:markdown/markdown.dart' as md;

import '../l10n/l10n.dart';
import 'desktop_host_chats.dart';
import 'desktop_remote_media.dart';

/// A preview supplied by the host's typed attachments, a relative Markdown
/// image, or a group message's image ID. No URLs or local file providers.
class DesktopRemoteImage {
  const DesktopRemoteImage._(this._source, this._value, this.label);

  final _Source _source;
  final Object _value;
  final String? label;

  static List<DesktopRemoteImage> group(Iterable<String> ids) => [
    for (final id in ids.take(32).toSet())
      if (id.length <= 255 && remoteFileName(id))
        DesktopRemoteImage._(_Source.group, id, null),
  ];

  /// Use only on a message already admitted to this transcript. Never scan
  /// the raw bot session, which can also contain private group turns.
  static List<DesktopRemoteImage> message({
    Object? images,
    String? markdown,
    String? toolImage,
  }) {
    final result = <DesktopRemoteImage>[];
    if (images is List) {
      for (final entry in images.take(16)) {
        if (entry case {'type': final String type, 'data': final String data}
            when const {
                  'image/png',
                  'image/jpeg',
                  'image/gif',
                  'image/webp',
                }.contains(type) &&
                data.length <= ((LinkLimits.image + 2) ~/ 3) * 4) {
          final rawName = entry['name'];
          final name = rawName is String
              ? rawName.split(RegExp(r'[/\\]')).last
              : null;
          result.add(
            DesktopRemoteImage._(
              _Source.inline,
              entry,
              name != null && remoteFileName(name) ? name : null,
            ),
          );
        }
      }
    }
    final paths = <String>{};
    if (toolImage != null) paths.add(toolImage);
    if (markdown != null &&
        markdown.length <= 64 * 1024 &&
        markdown.contains('![')) {
      // Parse as markup (not with media providers); images in inline or fenced
      // code and HTML never become explicit host actions.
      void visit(md.Node node) {
        if (node is! md.Element || paths.length >= 16) return;
        if (node.tag == 'img') {
          if (node.attributes['src'] case final String src) paths.add(src);
        }
        for (final child in node.children ?? const <md.Node>[]) {
          visit(child);
        }
      }

      try {
        for (final node in md.Document().parse(markdown)) {
          visit(node);
        }
      } on Object {
        // A nonstandard image reference stays inert in the transcript.
      }
    }
    for (final path in paths) {
      if (path.length <= 4096 &&
          remoteRelativePath(path) &&
          remoteImageType(path) != null) {
        result.add(
          DesktopRemoteImage._(_Source.relative, path, path.split('/').last),
        );
      }
    }
    return result;
  }
}

enum _Source { inline, relative, group }

Future<Uint8List> _imageBytes(Object? response, {String? expectedType}) async {
  final bytes = decodeRemoteBytes(response, LinkLimits.image);
  if (response case {'type': final String type}
      when (expectedType == null || expectedType == type) &&
          remoteImageSignature(bytes, type)) {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    try {
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      try {
        // Refuse inputs that would require unusually large decoded surfaces.
        if (descriptor.width * descriptor.height > 24 * 1024 * 1024) {
          throw const RemoteUnsupportedImage();
        }
      } finally {
        descriptor.dispose();
      }
    } finally {
      buffer.dispose();
    }
    return bytes;
  }
  throw const RemoteUnsupportedImage();
}

Future<Uint8List> previewRemoteFileImage(
  LinkPeer peer,
  String project,
  String path, {
  bool Function()? isCurrent,
}) async {
  final expected = remoteImageType(path);
  if (!remoteRelativePath(path) || expected == null) {
    throw const RemoteUnsupportedImage();
  }
  final response = await peer.call(LinkMethods.image, {
    'project': project,
    'path': path,
  });
  if (isCurrent?.call() == false) throw const _PreviewClosed();
  return _imageBytes(response, expectedType: expected);
}

class _PreviewClosed implements Exception {
  const _PreviewClosed();
}

/// Wrap a message bubble with the images belonging to that message.
/// Selection and preview are inline so changing chats cannot leave a modal
/// open on the wrong host. Rendering this widget never fetches or decodes.
class DesktopRemoteMessageImages extends StatefulWidget {
  const DesktopRemoteMessageImages({
    super.key,
    required this.peer,
    required this.chat,
    required this.images,
    required this.child,
    this.trailing = false,
    this.isCurrent,
  });

  final LinkPeer? peer;
  final DesktopHostChat chat;
  final List<DesktopRemoteImage> images;
  final Widget child;
  final bool trailing;
  final bool Function()? isCurrent;

  @override
  State<DesktopRemoteMessageImages> createState() =>
      _DesktopRemoteMessageImagesState();
}

class _DesktopRemoteMessageImagesState
    extends State<DesktopRemoteMessageImages> {
  (DesktopRemoteImage, Future<Uint8List>)? _preview;

  (LinkPeer?, String, String, String?) _target(DesktopRemoteMessageImages w) =>
      (w.peer, w.chat.kind, w.chat.id, w.chat.projectId);
  bool get _current =>
      widget.peer?.isClosed == false && (widget.isCurrent?.call() ?? true);

  @override
  void didUpdateWidget(DesktopRemoteMessageImages oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_target(oldWidget) != _target(widget) || !_current) {
      _preview = null;
    } else if (_preview case (final selected, _)
        when !widget.images.any(
          (image) =>
              image._source == selected._source &&
              image._value == selected._value,
        )) {
      _preview = null;
    }
  }

  bool _canShow(DesktopRemoteImage image) => switch (image._source) {
    _Source.group => widget.chat.kind == 'group',
    _Source.inline => const {'project', 'bot'}.contains(widget.chat.kind),
    _Source.relative =>
      widget.chat.kind == 'bot' ||
          (widget.chat.kind == 'project' &&
              widget.chat.projectId?.isNotEmpty == true),
  };

  void _show(DesktopRemoteImage image) {
    if (!_current || !_canShow(image)) return;
    final peer = widget.peer!;
    final chat = widget.chat;
    late final Future<Uint8List> result;
    bool current() => mounted && _current && identical(_preview?.$2, result);
    result = () async {
      switch (image._source) {
        case _Source.inline:
          return _imageBytes(image._value);
        case _Source.group:
          final response = await peer.call(LinkMethods.groupImage, {
            'group': chat.id,
            'image': image._value,
          });
          if (!current()) throw const _PreviewClosed();
          return _imageBytes(response);
        case _Source.relative:
          final path = image._value as String;
          if (chat.kind == 'project') {
            return previewRemoteFileImage(
              peer,
              chat.projectId!,
              path,
              isCurrent: current,
            );
          }
          final response = await peer.call(LinkMethods.image, {
            'bot': chat.id,
            'path': path,
          });
          if (!current()) throw const _PreviewClosed();
          return _imageBytes(response, expectedType: remoteImageType(path));
      }
    }();
    result.ignore();
    setState(() => _preview = (image, result));
  }

  @override
  Widget build(BuildContext context) {
    final images = _current
        ? widget.images.where(_canShow).toList()
        : const <DesktopRemoteImage>[];
    if (images.isEmpty) return widget.child;
    final l10n = context.l10n;
    final preview = _preview;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        widget.child,
        Wrap(
          alignment: widget.trailing ? WrapAlignment.end : WrapAlignment.start,
          spacing: 4,
          children: [
            for (final (index, image) in images.indexed)
              TextButton(
                onPressed: () => _show(image),
                child: Text(
                  switch (image.label) {
                    final name? => l10n.agentImageTitle(name),
                    _ => l10n.imageChip(index + 1),
                  },
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
        if (preview != null)
          Row(
            children: [
              Expanded(
                child: FutureBuilder<Uint8List>(
                  key: ObjectKey(preview.$2),
                  future: preview.$2,
                  builder: (context, snapshot) {
                    if (!_current) return const SizedBox.shrink();
                    if (snapshot.hasError) {
                      return Text(remoteMediaError(l10n, snapshot.error!));
                    }
                    if (snapshot.data case final bytes?) {
                      return SizedBox(
                        height:
                            MediaQuery.sizeOf(context).height.clamp(200, 800) *
                            .30,
                        child: DesktopRemoteImagePixels(bytes),
                      );
                    }
                    return Text(l10n.langLoading);
                  },
                ),
              ),
              IconButton(
                tooltip: l10n.sidePanelCloseTab,
                icon: const Icon(Icons.close),
                onPressed: () => setState(() => _preview = null),
              ),
            ],
          ),
      ],
    );
  }
}

/// In-memory only. Evict this specific decode when its preview disappears.
class DesktopRemoteImagePixels extends StatefulWidget {
  const DesktopRemoteImagePixels(this.bytes, {super.key});
  final Uint8List bytes;

  @override
  State<DesktopRemoteImagePixels> createState() =>
      _DesktopRemoteImagePixelsState();
}

class _DesktopRemoteImagePixelsState extends State<DesktopRemoteImagePixels> {
  late ImageProvider _provider = _image(widget.bytes);

  ImageProvider _image(Uint8List bytes) =>
      ResizeImage(MemoryImage(bytes), width: 1600, allowUpscaling: false);

  @override
  void didUpdateWidget(DesktopRemoteImagePixels oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bytes != widget.bytes) {
      unawaited(_provider.evict());
      _provider = _image(widget.bytes);
    }
  }

  @override
  void dispose() {
    unawaited(_provider.evict());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Image(
    image: _provider,
    fit: BoxFit.contain,
    errorBuilder: (context, _, _) => Text(context.l10n.placeholderUnexpected),
  );
}
