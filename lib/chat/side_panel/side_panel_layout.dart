import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/workbench_theme.dart' show themeColors;
import '../../workspace/islands.dart';
import '../chat_column.dart';

/// Positions a conversation and its secondary side panel. The owner keeps the
/// requested visibility and width; the layout can temporarily give way to the
/// conversation when the panel no longer fits beside it.
class SidePanelLayout extends StatefulWidget {
  const SidePanelLayout({
    super.key,
    required this.wanted,
    required this.requests,
    required this.width,
    required this.onWidthChanged,
    required this.onClose,
    required this.focusNode,
    required this.mainBuilder,
    required this.panelBuilder,
    this.onResizeEnd,
    this.onGaveWayChanged,
    this.atLeft = false,
    this.roomComing = false,
    this.bottom = 0,
    this.rail,
    this.railTop = 0,
    this.railInset = 0,
    this.keepPanelMounted = false,
    this.hideOverlayForMain = false,
    this.minWidth = 280,
    this.defaultWidth = initialWidth,
    this.maxWidth = 1400,
  });

  static const initialWidth = 640.0;
  static const minChat = 360.0;
  static const sashWidth = Islands.gap;
  static const overlayDelay = Duration(milliseconds: 260);

  final bool wanted;

  /// Changes on each explicit request to open the panel, even while it is
  /// already wanted. On a narrow window that request can open an overlay.
  final int requests;
  final double width;
  final ValueChanged<double> onWidthChanged;
  final VoidCallback? onResizeEnd;
  final VoidCallback onClose;
  final ValueChanged<bool>? onGaveWayChanged;
  final FocusNode focusNode;
  final bool atLeft;
  final bool roomComing;
  final double bottom;
  final double minWidth;
  final double defaultWidth;
  final double maxWidth;
  final Widget Function(
    BuildContext context,
    ({bool shown, bool overlay, bool short}) layout,
  )
  mainBuilder;
  final WidgetBuilder panelBuilder;
  final Widget? rail;
  final double railTop;
  final double railInset;

  /// Keep the panel subtree alive after it has first been shown. Offstage
  /// content cannot take focus or tick animations.
  final bool keepPanelMounted;

  /// A preview in the main slot can cover the chat without competing for the
  /// same narrow space as an overlaid panel. A docked panel stays in place.
  final bool hideOverlayForMain;

  @override
  State<SidePanelLayout> createState() => _SidePanelLayoutState();
}

class _SidePanelLayoutState extends State<SidePanelLayout> {
  ({double x, double width})? _dragStart;
  bool _overlay = false;
  bool _gaveWay = false;
  bool _askedShort = false;
  bool _hasShown = false;
  late int _requestsSeen = widget.requests;
  Timer? _short;
  Timer? _young;
  final ChatRail _rail = ChatRail();

  @override
  void initState() {
    super.initState();
    _young = Timer(SidePanelLayout.overlayDelay, () => _young = null);
  }

  @override
  void dispose() {
    if (_gaveWay) _tellGaveWay();
    _short?.cancel();
    _young?.cancel();
    _rail.dispose();
    super.dispose();
  }

  void _roomShort(bool short) {
    final requests = widget.requests;
    final asked = requests != _requestsSeen;
    _requestsSeen = requests;
    if (!short) {
      _short?.cancel();
      _short = null;
      _overlay = false;
      _askedShort = false;
      _setGaveWay(false);
      return;
    }
    if (asked) _askedShort = true;
    if (_overlay) return;
    if (_gaveWay) {
      if (_askedShort) {
        _setGaveWay(false);
        _overlay = true;
      }
      return;
    }
    if (_short != null) return;
    // Allow the window or its other sidebar time to settle before covering
    // the conversation or giving way to it.
    if (!widget.roomComing && _young == null) return _settle();
    _short = Timer(SidePanelLayout.overlayDelay, () {
      _short = null;
      if (mounted) setState(_settle);
    });
  }

  void _settle() {
    if (_askedShort) {
      _overlay = true;
    } else {
      _setGaveWay(true);
    }
  }

  void _setGaveWay(bool value) {
    if (value == _gaveWay) return;
    _gaveWay = value;
    _tellGaveWay();
  }

  void _tellGaveWay() {
    final callback = widget.onGaveWayChanged;
    if (callback == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      callback(mounted && _gaveWay);
    });
  }

  double _most(double room) => _overlay
      ? math.max(0.0, room - 48)
      : math.max(
          0.0,
          room - SidePanelLayout.minChat - SidePanelLayout.sashWidth,
        );

  double _shownWidth(double room) => math.min(widget.width, _most(room));

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final room = constraints.maxWidth;
      final short = room - widget.minWidth < SidePanelLayout.minChat;
      _roomShort(widget.wanted && short);
      final shown =
          widget.wanted && !_gaveWay && !(short && widget.hideOverlayForMain);
      final overlay = shown && _overlay;
      final beside = shown && !overlay;
      final atLeft = widget.atLeft;
      final rail = !shown && widget.rail != null;
      final width = _shownWidth(room);
      final sashWidth = SidePanelLayout.sashWidth;
      if (shown) _hasShown = true;
      if (!shown && _dragStart != null) {
        _dragStart = null;
        // The sash may be removed before it can deliver a drag end.
        final onResizeEnd = widget.onResizeEnd;
        if (onResizeEnd != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) => onResizeEnd());
        }
      }
      // Key the slots so neither the chat nor the panel moves to a new
      // element when the scrim, rail or drag cursor appears.
      return Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            key: const ValueKey('chat'),
            top: 0,
            bottom: 0,
            left: beside && atLeft ? width + sashWidth : 0,
            right: beside && !atLeft ? width + sashWidth : 0,
            child: ChatColumnInset(
              right: rail && !atLeft ? widget.railInset : 0,
              left: rail && atLeft ? widget.railInset : 0,
              rail: rail ? _rail : null,
              child: widget.mainBuilder(context, (
                shown: shown,
                overlay: overlay,
                short: short,
              )),
            ),
          ),
          if (rail)
            Positioned(
              key: const ValueKey('rail'),
              left: atLeft ? Islands.inset : null,
              right: atLeft ? null : Islands.inset,
              top: widget.railTop,
              child: ChatRailReport(rail: _rail, child: widget.rail!),
            ),
          if (overlay)
            Positioned.fill(
              key: const ValueKey('scrim'),
              child: GestureDetector(
                onTap: widget.onClose,
                child: const ColoredBox(color: Color(0x33000000)),
              ),
            ),
          if (shown || widget.keepPanelMounted && _hasShown)
            Positioned(
              key: const ValueKey('panel'),
              top: 0,
              bottom: overlay || IslandFootHosted.of(context)
                  ? 0
                  : widget.bottom,
              left: atLeft ? 0 : null,
              right: atLeft ? null : 0,
              width: width + sashWidth,
              child: Offstage(
                offstage: !shown,
                child: ExcludeFocus(
                  excluding: !shown,
                  child: TickerMode(
                    enabled: shown,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: overlay ? AppColors.background : null,
                        boxShadow: overlay
                            ? [
                                BoxShadow(
                                  color: themeColors['widget.shadow'],
                                  blurRadius: 24,
                                ),
                              ]
                            : null,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        textDirection: atLeft
                            ? TextDirection.rtl
                            : TextDirection.ltr,
                        children: [
                          _sash(atLeft: atLeft, room: room, width: width),
                          Expanded(
                            // Clip during transitions so the panel's children
                            // never receive less than their minimum width.
                            child: ClipRect(
                              child: OverflowBox(
                                alignment: Alignment.centerLeft,
                                minWidth: math.max(width, widget.minWidth),
                                maxWidth: math.max(width, widget.minWidth),
                                child: Listener(
                                  onPointerDown: (_) {
                                    if (!widget.focusNode.hasFocus) {
                                      widget.focusNode.requestFocus();
                                    }
                                  },
                                  child: Focus(
                                    focusNode: widget.focusNode,
                                    child: widget.panelBuilder(context),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (_dragStart != null)
            Positioned.fill(
              key: const ValueKey('drag-cursor'),
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (_) => _endDrag(),
                child: const MouseRegion(
                  cursor: SystemMouseCursors.resizeColumn,
                ),
              ),
            ),
        ],
      );
    },
  );

  Widget _sash({
    required bool atLeft,
    required double room,
    required double width,
  }) => MouseRegion(
    cursor: SystemMouseCursors.resizeColumn,
    child: GestureDetector(
      key: const ValueKey('side-panel-sash'),
      behavior: HitTestBehavior.opaque,
      dragStartBehavior: DragStartBehavior.down,
      // Drag from the displayed width even if constrained by the room.
      onHorizontalDragStart: (details) => setState(() {
        _dragStart = (x: details.globalPosition.dx, width: width);
      }),
      onHorizontalDragUpdate: (details) {
        final start = _dragStart;
        if (start == null) return;
        final moved = details.globalPosition.dx - start.x;
        final max = _most(room).clamp(widget.minWidth, widget.maxWidth);
        widget.onWidthChanged(
          (start.width + (atLeft ? moved : -moved)).clamp(widget.minWidth, max),
        );
      },
      onHorizontalDragEnd: (_) => _endDrag(),
      onHorizontalDragCancel: _endDrag,
      onDoubleTap: () {
        widget.onWidthChanged(widget.defaultWidth);
        widget.onResizeEnd?.call();
      },
      child: SizedBox(
        width: SidePanelLayout.sashWidth,
        child: Islands.sashLine(
          dragging: _dragStart != null,
          axis: Axis.horizontal,
        ),
      ),
    ),
  );

  void _endDrag() {
    if (!mounted || _dragStart == null) return;
    setState(() => _dragStart = null);
    widget.onResizeEnd?.call();
  }
}
