import 'dart:async';

import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../ide/ide_hover.dart';
import '../../ide/ide_menu.dart';
import '../../l10n/l10n.dart';
import '../../theme/app_theme.dart';
import '../../theme/codicons.dart';
import '../../workspace/editor_launcher.dart' show openExternal;
import '../../workspace/window_controls.dart';
import '../chat_models.dart';
import '../side_panel/file_link_menu.dart';
import '../side_panel/shown_files.dart';
import 'hover_builder.dart';

/// Pictures attached to a message, small; a click shows one whole. With
/// [onRemove], each has a button to take it off (as in the composer).
/// One size in a message and in its editor, so editing does not resize
/// them.
class ImageThumbnails extends StatelessWidget {
  const ImageThumbnails({
    super.key,
    required this.images,
    this.onRemove,
    this.size = 48,
    this.memoryOnly = false,
    this.isPreviewCurrent,
  });

  final bool Function()? isPreviewCurrent;

  /// Attachment slots in message order, with null for an unreadable file.
  final List<ImageAttachment?> images;
  final ValueChanged<int>? onRemove;
  final double size;

  /// Remote images stay in memory and their preview closes with the thumbnail.
  final bool memoryOnly;

  @override
  Widget build(BuildContext context) {
    final galleryImages = onRemove == null ? images.nonNulls.toList() : null;
    var galleryIndex = 0;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final (i, slot) in images.indexed)
          if (slot case final image?)
            ImageThumbnail(
              // A new image at this position is a new thumbnail.
              key: ObjectKey(image),
              image: image,
              size: size,
              memoryOnly: memoryOnly,
              isPreviewCurrent: isPreviewCurrent,
              gallery: galleryImages == null || galleryImages.length < 2
                  ? null
                  : (
                      count: galleryImages.length,
                      index: galleryIndex++,
                      load: (index) => SynchronousFuture(galleryImages[index]),
                    ),
              onRemove: onRemove == null ? null : () => onRemove!(i),
            )
          else
            SizedBox(
              width: size,
              height: size,
              child: Icon(
                Icons.broken_image_outlined,
                size: 16,
                color: AppColors.textFaint,
              ),
            ),
      ],
    );
  }
}

class ImageThumbnail extends StatefulWidget {
  const ImageThumbnail({
    super.key,
    required this.image,
    this.size = 48,
    this.onRemove,
    this.memoryOnly = false,
    this.isPreviewCurrent,
    this.gallery,
  });

  final ({int count, int index, Future<ImageAttachment?> Function(int) load})?
  gallery;
  final ImageAttachment image;
  final double size;
  final VoidCallback? onRemove;
  final bool memoryOnly;
  final bool Function()? isPreviewCurrent;

  @override
  State<ImageThumbnail> createState() => _ImageThumbnailState();
}

class _ImageThumbnailState extends State<ImageThumbnail> {
  DialogRoute<void>? _preview;

  void _show() {
    if (widget.isPreviewCurrent?.call() == false || _preview != null) return;
    final image = widget.image;
    final gallery = widget.gallery;
    if (!widget.memoryOnly) {
      if (gallery == null) {
        showImagePreview(context, image);
      } else {
        showImageGallery(
          context,
          count: gallery.count,
          load: gallery.load,
          index: gallery.index,
        );
      }
      return;
    }
    final navigator = Navigator.of(context, rootNavigator: true);
    final isCurrent = widget.isPreviewCurrent;
    final route = DialogRoute<void>(
      context: context,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      barrierColor: Colors.black87,
      builder: (_) => _ImagePreview(
        count: gallery?.count ?? 1,
        load: (index) {
          if (!mounted || isCurrent?.call() == false) {
            return SynchronousFuture(null);
          }
          if (gallery == null || index == gallery.index) {
            return SynchronousFuture(image);
          }
          return gallery
              .load(index)
              .then(
                (next) => mounted && isCurrent?.call() != false ? next : null,
              );
        },
        index: gallery?.index ?? 0,
        memoryOnly: true,
      ),
    );
    _preview = route;
    unawaited(
      navigator.push(route).whenComplete(() {
        if (identical(_preview, route)) _preview = null;
      }),
    );
  }

  @override
  void dispose() {
    if (_preview case final route?) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (route.isActive) route.navigator?.removeRoute(route);
      });
    }
    if (widget.memoryOnly) {
      unawaited(_thumbnailProvider(widget.image, widget.size).evict());
    }
    super.dispose();
  }

  ImageProvider _thumbnailProvider(ImageAttachment image, double size) {
    final limit = (size * 3).round();
    return widget.memoryOnly
        ? ResizeImage(
            MemoryImage(image.bytes),
            width: limit,
            height: limit,
            policy: ResizeImagePolicy.fit,
          )
        : ResizeImage(MemoryImage(image.bytes), width: limit);
  }

  @override
  Widget build(BuildContext context) {
    final ImageThumbnail(:image, :size, :onRemove, :memoryOnly) = widget;
    return HoverBuilder(
      cursor: SystemMouseCursors.click,
      builder: (context, hovered) => Stack(
        clipBehavior: Clip.none,
        children: [
          _picture(context, image, size, hovered, memoryOnly),
          if (onRemove case final remove? when hovered)
            Positioned(
              top: -5,
              right: -5,
              child: GestureDetector(
                onTap: remove,
                child: Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: AppColors.surfaceRaised,
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.borderStrong),
                  ),
                  child: Icon(
                    Icons.close_rounded,
                    size: 11,
                    color: AppColors.text,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _picture(
    BuildContext context,
    ImageAttachment image,
    double size,
    bool hovered,
    bool memoryOnly,
  ) {
    final clickable = Listener(
      onPointerDown: (_) => PreviewPressScope._press(context),
      child: GestureDetector(
        onTap: _show,
        child: IdeHover(
          message: image.name ?? '',
          child: Container(
            width: size,
            height: size,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(6),
            ),
            foregroundDecoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: hovered ? AppColors.textFaint : AppColors.borderStrong,
              ),
            ),
            child: Image(
              image: _thumbnailProvider(image, size),
              fit: BoxFit.cover,
              gaplessPlayback: !memoryOnly,
              errorBuilder: (context, error, stack) => Icon(
                Icons.broken_image_outlined,
                size: 16,
                color: AppColors.textFaint,
              ),
            ),
          ),
        ),
      ),
    );
    return memoryOnly
        ? clickable
        : FileLinkMenuRegion(menu: ImageMenu(image), child: clickable);
  }
}

/// Shows [image] whole, over the window. A click closes it; a right click
/// offers [menu] (a file's, say), else [ImageMenu]'s; ⌘C and Ctrl+C copy
/// it.
void showImagePreview(
  BuildContext context,
  ImageAttachment image, {
  ChatItemMenu? menu,
}) => showImageGallery(
  context,
  count: 1,
  load: (_) => SynchronousFuture(image),
  menu: menu == null ? null : (_) => menu,
);

/// Shows images whole, as [showImagePreview] does, [count] of them (read
/// by [load] as they show), from the one at [index]: the arrows at its
/// sides, ← and →, go from one to the next. [menu] is a right click's on
/// each, if not [ImageMenu]'s.
void showImageGallery(
  BuildContext context, {
  required int count,
  required Future<ImageAttachment?> Function(int index) load,
  int index = 0,
  ChatItemMenu? Function(int index)? menu,
}) {
  if (count < 1) return;
  showDialog<void>(
    context: context,
    // Black, not the theme's: as upstream's modal backdrops.
    barrierColor: Colors.black87,
    builder: (context) => _ImagePreview(
      count: count,
      load: load,
      index: index.clamp(0, count - 1),
      menu: menu,
    ),
  );
}

/// What a right click on an image of a message offers: to show it whole,
/// to copy it, and on this machine to open it in its app or show it in the
/// file manager (as a file of its own, see [ShownFiles.bytes]).
class ImageMenu implements ChatItemMenu {
  const ImageMenu(this.image);

  final ImageAttachment image;

  @override
  Future<void> show(BuildContext context, Offset position) {
    final l10n = context.l10n;
    return showIdeMenu(
      context,
      position: position,
      entries: ideMenuGroups([
        [
          IdeMenuAction(
            l10n.fileLinkPreview,
            onSelected: () => showImagePreview(context, image),
          ),
          if (WindowControls.canOpenInDefaultApp)
            IdeMenuAction(
              l10n.openInDefaultApp,
              onSelected: () {
                if (_imageFile(image, l10n) case final path?) {
                  unawaited(openExternal(path));
                }
              },
            ),
        ],
        [
          IdeMenuAction(
            l10n.imageCopy,
            onSelected: () =>
                unawaited(WindowControls.writePasteboardImage(image)),
          ),
        ],
        [
          if (WindowControls.canRevealInFileManager)
            IdeMenuAction(
              l10n.revealInFileManager,
              onSelected: () {
                if (_imageFile(image, l10n) case final path?) {
                  unawaited(WindowControls.revealInFileManager(path));
                }
              },
            ),
        ],
      ]),
    );
  }
}

/// [image] as a file, to open in its app or show in the file manager;
/// null where it cannot be one.
String? _imageFile(ImageAttachment image, AppLocalizations l10n) {
  final name = image.name ?? l10n.shownImage;
  final extension = switch (image.mediaType) {
    'image/jpeg' => '.jpg',
    'image/gif' => '.gif',
    'image/webp' => '.webp',
    'image/bmp' => '.bmp',
    _ => '.png',
  };
  return ShownFiles.bytes(
    image.bytes,
    name: p.extension(name).isEmpty ? '$name$extension' : name,
  );
}

class _ImagePreview extends StatefulWidget {
  const _ImagePreview({
    required this.count,
    required this.load,
    required this.index,
    this.menu,
    this.memoryOnly = false,
  });

  final int count;
  final Future<ImageAttachment?> Function(int index) load;
  final int index;
  final ChatItemMenu? Function(int index)? menu;
  final bool memoryOnly;

  @override
  State<_ImagePreview> createState() => _ImagePreviewState();
}

class _ImagePreviewState extends State<_ImagePreview> {
  late int _index = widget.index;

  /// Those read, by their index; null for one that could not be.
  final Map<int, ImageAttachment?> _read = {};

  ImageAttachment? get _image => _read[_index];

  ImageProvider _previewProvider(ImageAttachment image) => widget.memoryOnly
      ? ResizeImage(
          MemoryImage(image.bytes),
          width: 1600,
          height: 1600,
          policy: ResizeImagePolicy.fit,
        )
      : MemoryImage(image.bytes);

  @override
  void dispose() {
    if (widget.memoryOnly) {
      for (final image in _read.values.nonNulls) {
        unawaited(_previewProvider(image).evict());
      }
    }
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _load(_index);
  }

  /// Shows the [index]th.
  void _show(int index) {
    setState(() => _index = index);
    _load(index);
  }

  /// Reads the [index]th, once, and the ones beside it, for the arrows to
  /// go at once.
  void _load(int index) {
    for (final at in {index, index + 1, index - 1}) {
      if (at < 0 || at >= widget.count || _read.containsKey(at)) continue;
      void read(ImageAttachment? image) {
        if (!mounted) return;
        // Given at once, as it starts (an image given, not read): no
        // frame to ask for.
        if (!_started) {
          _read[at] = image;
        } else {
          setState(() => _read[at] = image);
        }
      }

      unawaited(widget.load(at).then(read, onError: (Object _) => read(null)));
    }
    _started = true;
  }

  bool _started = false;

  void _step(int by) {
    final next = _index + by;
    if (next >= 0 && next < widget.count) _show(next);
  }

  void _copy() {
    if (_image case final image?) {
      unawaited(WindowControls.writePasteboardImage(image));
    }
  }

  Future<void> _showMenu(BuildContext context, Offset position) async {
    final image = _image;
    if (image == null) return;
    if (widget.menu?.call(_index) case final menu?) {
      return menu.show(context, position);
    }
    final l10n = context.l10n;
    final open = WindowControls.canOpenInDefaultApp;
    final reveal = WindowControls.canRevealInFileManager;
    final chosen = await WindowControls.showContextMenu(position, [
      NativeMenuItem('copyImage', l10n.imageCopy, key: 'c'),
      if (open || reveal) const NativeMenuItem.separator(),
      if (open) NativeMenuItem('open', l10n.openInDefaultApp),
      if (reveal) NativeMenuItem('reveal', l10n.revealInFileManager),
    ]);
    switch (chosen) {
      case 'copyImage':
        _copy();
      case 'open':
        if (_imageFile(image, l10n) case final path?) {
          await openExternal(path);
        }
      case 'reveal':
        if (_imageFile(image, l10n) case final path?) {
          await WindowControls.revealInFileManager(path);
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    final several = widget.count > 1;
    return CallbackShortcuts(
      bindings: {
        if (!widget.memoryOnly) ...{
          const SingleActivator(LogicalKeyboardKey.keyC, meta: true): _copy,
          const SingleActivator(LogicalKeyboardKey.keyC, control: true): _copy,
        },
        if (several) ...{
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _step(-1),
          const SingleActivator(LogicalKeyboardKey.arrowRight): () => _step(1),
        },
      },
      child: Focus(
        autofocus: true,
        child: GestureDetector(
          onTap: () => Navigator.of(context).pop(),
          child: Stack(
            children: [
              Positioned.fill(
                child: !_read.containsKey(_index)
                    ? const SizedBox.shrink()
                    : image == null
                    ? Center(
                        child: Icon(
                          Codicons.fileMedia,
                          size: 32,
                          color: Colors.white54,
                        ),
                      )
                    // The whole window, not the picture's own size: zoomed,
                    // it fills the window, not clipped to where it was.
                    : InteractiveViewer(
                        // Each anew: not zoomed as the one before.
                        key: ValueKey(_index),
                        maxScale: 6,
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: several ? 72 : 40,
                            vertical: 40,
                          ),
                          child: Center(
                            child: GestureDetector(
                              onSecondaryTapUp: widget.memoryOnly
                                  ? null
                                  : (details) => _showMenu(
                                      context,
                                      details.globalPosition,
                                    ),
                              child: Image(
                                image: _previewProvider(image),
                                fit: BoxFit.contain,
                                errorBuilder: (_, _, _) => const Icon(
                                  Icons.broken_image_outlined,
                                  color: Colors.white54,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
              ),
              if (several) ...[
                Positioned(
                  left: 16,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: _PageArrow(
                      key: const ValueKey('image-previous'),
                      icon: Codicons.chevronLeft,
                      onTap: _index > 0 ? () => _step(-1) : null,
                    ),
                  ),
                ),
                Positioned(
                  right: 16,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: _PageArrow(
                      key: const ValueKey('image-next'),
                      icon: Codicons.chevronRight,
                      onTap: _index < widget.count - 1 ? () => _step(1) : null,
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 12,
                  child: Center(
                    child: Text(
                      '${_index + 1} / ${widget.count}',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// An arrow at a side of [_ImagePreview], to the image before or after;
/// faded where there is none.
class _PageArrow extends StatelessWidget {
  const _PageArrow({super.key, required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => HoverBuilder(
    cursor: onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
    builder: (context, hovered) => GestureDetector(
      // Not the backdrop's tap, which closes it.
      behavior: HitTestBehavior.opaque,
      onTap: onTap ?? () {},
      child: Opacity(
        opacity: onTap == null ? .3 : 1,
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: hovered ? .22 : .12),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 20, color: Colors.white),
        ),
      ),
    ),
  );
}

/// [child], which a click shows [image] whole from (see [showImagePreview]).
class ImagePreviewClick extends StatelessWidget {
  const ImagePreviewClick({
    super.key,
    required this.image,
    required this.child,
  });

  final ImageAttachment image;
  final Widget child;

  @override
  Widget build(BuildContext context) => PreviewClick(
    onOpen: () => showImagePreview(context, image),
    child: child,
  );
}

/// [child], a tag for something shown shortened (an image, a long paste),
/// which a click opens whole ([onOpen]). Hears the click itself rather
/// than through a gesture, so a selection of the text around it (in an
/// editor, a message) goes on as it would.
class PreviewClick extends StatefulWidget {
  const PreviewClick({super.key, required this.onOpen, required this.child});

  final VoidCallback onOpen;
  final Widget child;

  @override
  State<PreviewClick> createState() => _PreviewClickState();
}

class _PreviewClickState extends State<PreviewClick> {
  /// Where a primary press went down; null for other presses.
  Offset? _pressedAt;

  void _handleDown(PointerDownEvent event) {
    final primary =
        event.kind != PointerDeviceKind.mouse ||
        event.buttons == kPrimaryMouseButton;
    // Shift extends a selection.
    if (!primary || HardwareKeyboard.instance.isShiftPressed) return;
    _pressedAt = event.position;
    PreviewPressScope._press(context);
  }

  void _handleUp(PointerUpEvent event) {
    final pressedAt = _pressedAt;
    _pressedAt = null;
    // A click, not the end of a drag selection.
    if (pressedAt == null ||
        (event.position - pressedAt).distance > kTouchSlop) {
      return;
    }
    widget.onOpen();
  }

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.click,
    child: Listener(
      onPointerDown: _handleDown,
      onPointerUp: _handleUp,
      onPointerCancel: (_) => _pressedAt = null,
      child: widget.child,
    ),
  );
}

/// Tells what is around images and tags a press on one of them (which opens
/// it whole, see [PreviewClick]) from a press on the rest of it: [onPress]
/// hears it first.
class PreviewPressScope extends InheritedWidget {
  const PreviewPressScope({
    super.key,
    required this.onPress,
    required super.child,
  });

  final VoidCallback onPress;

  static void _press(BuildContext context) =>
      context.getInheritedWidgetOfExactType<PreviewPressScope>()?.onPress();

  @override
  bool updateShouldNotify(PreviewPressScope oldWidget) => false;
}
