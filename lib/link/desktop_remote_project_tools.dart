import 'dart:convert';
import 'dart:typed_data';

import 'package:bao_link/bao_link.dart' show LinkMethods, LinkPeer, ProjectInfo;
import 'package:flutter/material.dart';
import 'package:xml/xml_events.dart';

import '../icons/icon_library.dart';
import '../icons/project_icon.dart';
import '../icons/project_icon_view.dart';
import '../l10n/l10n.dart';
import '../settings/pages/settings_widgets.dart'
    show SettingsColors, SettingsText;
import '../sidebar/sidebar_menu.dart';
import '../sidebar/sidebar_rows.dart';
import '../theme/app_theme.dart' show AppColors;
import 'desktop_remote_dialog.dart';

/// Checks the live connection and catalog, not the snapshots used to build a row.
typedef DesktopRemoteProjectGuard = bool Function(
  LinkPeer peer,
  String projectId,
);

enum _ProjectAction { pin, unpin, hide }

/// Actions for an advertised folder on the authenticated host. The host's next
/// catalog, not the RPC acknowledgement, supplies the new pin/removal state.
class DesktopRemoteProjectActions extends StatefulWidget {
  const DesktopRemoteProjectActions({
    super.key,
    required this.peer,
    required this.project,
    required this.hostName,
    required this.isCurrent,
    this.enabled = true,
    this.onError,
    this.builder,
  });

  final LinkPeer peer;
  final ProjectInfo project;
  final String hostName;
  final DesktopRemoteProjectGuard isCurrent;
  final bool enabled;
  final ValueChanged<String>? onError;
  final Widget Function(List<SidebarMenuItem> Function()? items)? builder;

  @override
  State<DesktopRemoteProjectActions> createState() =>
      _DesktopRemoteProjectActionsState();
}

class _DesktopRemoteProjectActionsState
    extends State<DesktopRemoteProjectActions> {
  Object? _pending;

  @override
  void didUpdateWidget(DesktopRemoteProjectActions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.peer, widget.peer) ||
        oldWidget.project.id != widget.project.id) {
      _pending = null;
    }
  }

  bool _current(LinkPeer peer, String id) =>
      mounted &&
      identical(widget.peer, peer) &&
      widget.project.id == id &&
      !peer.isClosed &&
      widget.isCurrent(peer, id);

  Future<void> _manage(LinkPeer peer, String id, _ProjectAction action) async {
    if (!_current(peer, id) || !widget.enabled || _pending != null) return;
    final pinned = action == _ProjectAction.pin;
    final hiding = action == _ProjectAction.hide;
    if (!hiding && (widget.project.pinned == true) == pinned) return;
    final request = Object();
    setState(() => _pending = request);
    try {
      if (hiding) {
        final confirmed = await _confirmHide();
        if (confirmed != true ||
            !_current(peer, id) ||
            !widget.enabled ||
            !identical(_pending, request)) {
          return;
        }
      }
      await peer.call(
        hiding ? LinkMethods.hideProject : LinkMethods.pinProject,
        {'project': id, if (!hiding) 'pinned': pinned},
      );
    } on Exception {
      if (mounted && _current(peer, id) && identical(_pending, request)) {
        final message = Localizations.localeOf(context).languageCode == 'zh'
            ? '无法更新主机上的项目。'
            : 'Could not update the project on the host.';
        if (widget.onError case final report?) {
          report(message);
        } else {
          ScaffoldMessenger.maybeOf(context)
              ?.showSnackBar(SnackBar(content: Text(message)));
        }
      }
    } finally {
      if (mounted && identical(_pending, request)) {
        setState(() => _pending = null);
      }
    }
  }

  Future<bool?> _confirmHide() {
    final strings = context.l10n;
    final project = widget.project;
    final name = project.name;
    final host = widget.hostName;
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    return showDialog<bool>(
      context: context,
      builder: (dialog) => RemoteActionDialog(
        icon: Icons.visibility_off_outlined,
        title: strings.sidebarRemoveFromList,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              zh
                  ? '从「$host」的项目列表移除「$name」？项目文件和聊天会保留。'
                  : 'Remove “$name” from the project list on “$host”? '
                        'The project files and chats will be kept.',
            ),
            if (project.path.isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: AppColors.code,
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(color: SettingsColors.stroke),
                ),
                child: SelectableText(project.path, style: SettingsText.path),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            style: remoteDialogSecondaryButtonStyle(dialog),
            onPressed: () => Navigator.pop(dialog, false),
            child: Text(strings.commonCancel),
          ),
          TextButton(
            style: remoteDialogPrimaryButtonStyle(dialog),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(strings.sidebarRemoveFromList),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final peer = widget.peer;
    final id = widget.project.id;
    final pinned = widget.project.pinned == true;
    final strings = context.l10n;
    final enabled = widget.enabled && _pending == null && _current(peer, id);
    if (widget.builder case final build?) {
      return build(
        enabled
            ? () => [
                SidebarRowMenuItems.pin(
                  strings,
                  pinned,
                  () => _manage(
                    peer,
                    id,
                    pinned ? _ProjectAction.unpin : _ProjectAction.pin,
                  ),
                ),
                SidebarRowMenuItems.removeProject(
                  strings,
                  () => _manage(peer, id, _ProjectAction.hide),
                ),
              ]
            : null,
      );
    }
    return SizedBox.square(
      dimension: 28,
      child: PopupMenuButton<_ProjectAction>(
        key: ValueKey((peer, id)),
        tooltip: Localizations.localeOf(context).languageCode == 'zh'
            ? '项目操作'
            : 'Project actions',
        enabled: enabled,
        padding: EdgeInsets.zero,
        iconSize: 16,
        onSelected: (action) => _manage(peer, id, action),
        itemBuilder: (_) => [
          PopupMenuItem(
            value: pinned ? _ProjectAction.unpin : _ProjectAction.pin,
            child: Text(pinned ? strings.sidebarUnpin : strings.sidebarPin),
          ),
          PopupMenuItem(
            value: _ProjectAction.hide,
            child: Text(strings.sidebarRemoveFromList),
          ),
        ],
      ),
    );
  }
}

/// A host project's advertised icon. Host image IDs never go through the local
/// icon library or file system; their bytes come from the bound Link peer only.
class DesktopRemoteProjectIcon extends StatelessWidget {
  const DesktopRemoteProjectIcon({
    super.key,
    required this.peer,
    required this.project,
    required this.size,
    required this.isCurrent,
    this.fallback = Icons.folder_outlined,
    this.color,
  });

  final LinkPeer? peer;
  final ProjectInfo project;
  final double size;
  final DesktopRemoteProjectGuard isCurrent;
  final IconData fallback;
  final Color? color;

  static final _emptyLibrary = IconLibrary();

  @override
  Widget build(BuildContext context) {
    final icon = _parseIcon(project.icon);
    final folder = ProjectIconView(
      icon: icon is LibraryIcon ? null : icon,
      library: _emptyLibrary,
      size: size,
      color: color,
      fallback: fallback,
    );
    final host = peer;
    if (icon is! LibraryIcon ||
        host == null ||
        host.isClosed ||
        !isCurrent(host, project.id)) {
      return folder;
    }
    return _RemoteIconAsset(
      key: ValueKey((host, project.id, icon.id)),
      peer: host,
      projectId: project.id,
      assetId: icon.id,
      isCurrent: isCurrent,
      size: size,
      folder: folder,
    );
  }
}

ProjectIcon? _parseIcon(Map<String, Object?>? json) {
  if (json == null) return null;
  final color = json['color'];
  switch (json) {
    case {'type': 'emoji', 'emoji': final String emoji} when emoji.length <= 64:
    case {'type': 'codicon', 'name': final String name}
        when name.length <= 128 &&
            (color == null || (color is String && color.length <= 128)):
    case {'type': 'brand', 'name': final String name} when name.length <= 128:
    case {'type': 'image', 'id': final String id} when _assetId.hasMatch(id):
      return ProjectIcon.fromJson(json);
    default:
      return null;
  }
}

final _assetId = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

/// Replaced (rather than updated in place) when the host, project or asset
/// changes, so even A → B → A cannot reuse an old in-flight reply.
class _RemoteIconAsset extends StatefulWidget {
  const _RemoteIconAsset({
    super.key,
    required this.peer,
    required this.projectId,
    required this.assetId,
    required this.isCurrent,
    required this.size,
    required this.folder,
  });

  final LinkPeer peer;
  final String projectId;
  final String assetId;
  final DesktopRemoteProjectGuard isCurrent;
  final double size;
  final Widget folder;

  @override
  State<_RemoteIconAsset> createState() => _RemoteIconAssetState();
}

class _RemoteIconAssetState extends State<_RemoteIconAsset> {
  late final Future<IconImage?> _image = _read();

  bool get _current =>
      mounted &&
      !widget.peer.isClosed &&
      widget.isCurrent(widget.peer, widget.projectId);

  Future<IconImage?> _read() async {
    if (!_current) return null;
    try {
      final reply = await widget.peer.call(LinkMethods.icon, {
        'id': widget.assetId,
      });
      if (!_current) return null;
      return _decodeImage(widget.assetId, reply);
    } on Exception {
      // Missing asset, older host, malformed bytes, or disconnected peer.
      return null;
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<IconImage?>(
    future: _image,
    builder: (context, snapshot) {
      final image = snapshot.data;
      if (image == null || !_current) return widget.folder;
      return SizedBox.square(
        dimension: widget.size,
        child: Center(
          child: IconImageView(
            image,
            size: widget.size * ProjectIconView.imageScale,
          ),
        ),
      );
    },
  );
}

IconImage? _decodeImage(String id, Object? reply) {
  if (reply case {'kind': final String kind, 'data': final String data}) {
    final type = IconImageKind.values.asNameMap()[kind];
    // Raster decoders have a dimension limit below. Vector parsing also has a
    // tighter byte and structure budget because it runs before rasterization.
    final maxBytes = type == IconImageKind.svg
        ? 256 * 1024
        : IconLibrary.maxBytes;
    final maxEncodedLength = ((maxBytes + 2) ~/ 3) * 4;
    if (type == null || data.isEmpty || data.length > maxEncodedLength) {
      return null;
    }
    final bytes = base64Decode(data);
    if (bytes.isEmpty || bytes.length > maxBytes) return null;
    final valid = switch (type) {
      IconImageKind.png => _boundedPng(bytes),
      IconImageKind.gif => _boundedGif(bytes),
      IconImageKind.svg => _selfContainedSvg(utf8.decode(bytes)),
    };
    if (!valid) return null;
    return IconImage(id: id, kind: type, name: '', bytes: bytes);
  }
  return null;
}

bool _boundedPng(Uint8List bytes) {
  if (bytes.length < 33) return false;
  final header = ByteData.sublistView(bytes);
  return header.getUint32(0) == 0x89504e47 &&
      header.getUint32(4) == 0x0d0a1a0a &&
      header.getUint32(8) == 13 &&
      header.getUint32(12) == 0x49484452 && // IHDR
      _smallRaster(header.getUint32(16), header.getUint32(20));
}

bool _boundedGif(Uint8List bytes) {
  if (bytes.length < 14) return false;
  final header = ByteData.sublistView(bytes);
  final width = header.getUint16(6, Endian.little);
  final height = header.getUint16(8, Endian.little);
  if (header.getUint32(0) != 0x47494638 || // GIF8
      (header.getUint16(4) != 0x3761 && header.getUint16(4) != 0x3961) ||
      !_smallRaster(width, height)) {
    return false;
  }
  int colorTableBytes(int flags) =>
      flags & 0x80 == 0 ? 0 : 3 * (2 << (flags & 7));
  var offset = 13 + colorTableBytes(bytes[10]);
  var frames = 0;
  while (offset < bytes.length) {
    switch (bytes[offset++]) {
      case 0x3b: // Trailer.
        return frames > 0 && offset == bytes.length;
      case 0x21: // Extension label, then data sub-blocks.
        offset++;
      case 0x2c: // Image descriptor, optional palette, LZW code size.
        if (++frames > 512 || offset + 9 > bytes.length) return false;
        final left = header.getUint16(offset, Endian.little);
        final top = header.getUint16(offset + 2, Endian.little);
        final w = header.getUint16(offset + 4, Endian.little);
        final h = header.getUint16(offset + 6, Endian.little);
        if (w == 0 || h == 0 || left + w > width || top + h > height) {
          return false;
        }
        offset += 10 + colorTableBytes(bytes[offset + 8]);
      default:
        return false;
    }
    // Both extensions and image data end in a zero-length sub-block.
    while (offset < bytes.length && bytes[offset] != 0) {
      offset += 1 + bytes[offset];
    }
    offset++;
  }
  return false;
}

bool _smallRaster(int width, int height) =>
    width > 0 && width <= 1024 && height > 0 && height <= 1024;

final _urlStart = RegExp(r'url\s*\(', caseSensitive: false);
final _localUrl = RegExp(
  r'''url\(\s*['"]?#[\w:.-]+['"]?\s*\)''',
  caseSensitive: false,
);
final _fragment = RegExp(r'^#[\w:.-]+$');

bool _selfContainedSvg(String source) {
  var elements = 0;
  var depth = 0;
  for (final event in parseEvents(
    source,
    validateNesting: true,
    validateDocument: true,
  )) {
    switch (event) {
      case XmlDoctypeEvent() || XmlProcessingEvent():
        return false;
      case XmlStartElementEvent(
        :final name,
        :final attributes,
        :final isSelfClosing,
      ):
        final tag = name.split(':').last.toLowerCase();
        if (++elements > 2048 ||
            depth >= 32 ||
            (elements == 1 && tag != 'svg')) {
          return false;
        }
        if (!isSelfClosing) depth++;
        // Inline vectors only. Linked resources, embedded raster decodes and
        // recursive SVG reuse are outside this renderer's work budget.
        if (const {
          'image',
          'feimage',
          'use',
          'foreignobject',
          'script',
          'style',
          'pattern',
        }.contains(tag)) {
          return false;
        }
        for (final attribute in attributes) {
          final name = attribute.name.split(':').last.toLowerCase();
          final value = attribute.value.trim();
          if (name == 'base' || name.startsWith('on')) return false;
          if (name == 'href' && !_fragment.hasMatch(value)) return false;
          if (name == 'style' &&
              (value.contains('@') || value.contains('\\'))) {
            return false;
          }
          if (_urlStart.hasMatch(value.replaceAll(_localUrl, ''))) return false;
        }
      case XmlEndElementEvent():
        depth--;
      default:
        break;
    }
  }
  return elements > 0;
}
