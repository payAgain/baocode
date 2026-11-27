import 'dart:async';

import 'package:flutter/gestures.dart' show PointerEnterEvent;
import 'package:flutter/material.dart';

import '../base/give_way_row.dart';
import '../chat/chat_keys.dart';
import '../chat/floating/floating_placement.dart';
import '../chat/widgets/hover_builder.dart';
import '../chat/widgets/pixel_loader.dart';
import '../ide/ide_hover.dart';
import '../ide/ide_list.dart';
import '../ide/ide_speed_search.dart';
import '../ide/ide_spinning.dart';
import '../l10n/l10n.dart';
import '../theme/app_theme.dart';
import '../theme/svg_icons.dart';
import '../theme/workbench_theme.dart' show themeColors;
import '../workspace/workspace.dart' show ThreadStatus;
import 'sidebar_menu.dart';

/// `now`, `5m`, `3h`, `2d`, `3w`, then the date, in [l10n]'s language.
String relativeTime(DateTime time, DateTime now, [AppLocalizations? l10n]) {
  final strings = l10n ?? englishLocalizations;
  final elapsed = now.difference(time);
  if (elapsed.inMinutes < 1) return strings.sidebarTimeNow;
  if (elapsed.inHours < 1) return strings.sidebarTimeMinutes(elapsed.inMinutes);
  if (elapsed.inDays < 1) return strings.sidebarTimeHours(elapsed.inHours);
  if (elapsed.inDays < 7) return strings.sidebarTimeDays(elapsed.inDays);
  if (elapsed.inDays < 35) return strings.sidebarTimeWeeks(elapsed.inDays ~/ 7);
  return strings.sidebarMonthDay('${time.month}', time.day);
}

/// Common localized menu items. The caller owns all mutations and guards.
abstract final class SidebarRowMenuItems {
  static SidebarMenuItem newAgent(AppLocalizations l10n, VoidCallback action) =>
      SidebarMenuItem(
        l10n.sidebarNewAgentHere,
        icon: Icons.add_rounded,
        onSelected: action,
      );

  static SidebarMenuItem pin(
    AppLocalizations l10n,
    bool pinned,
    VoidCallback action,
  ) => SidebarMenuItem(
    pinLabel(l10n, pinned),
    icon: pinIcon(pinned),
    onSelected: action,
  );

  static String pinLabel(AppLocalizations l10n, bool pinned) =>
      pinned ? l10n.sidebarUnpin : l10n.sidebarPin;

  static IconData pinIcon(bool pinned) =>
      pinned ? Icons.push_pin : Icons.push_pin_outlined;

  static SidebarMenuItem removeProject(
    AppLocalizations l10n,
    VoidCallback action,
  ) => SidebarMenuItem(
    l10n.sidebarRemoveFromList,
    icon: Icons.visibility_off_outlined,
    onSelected: action,
  );
}

/// The common single-session actions. Null callbacks are not offered.
class SidebarSessionActions {
  const SidebarSessionActions({
    this.pinned = false,
    this.archived = false,
    this.onRename,
    this.onPin,
    this.onArchive,
    this.onDelete,
  });

  final bool pinned;
  final bool archived;
  final VoidCallback? onRename;
  final VoidCallback? onPin;
  final VoidCallback? onArchive;
  final VoidCallback? onDelete;

  bool get isEmpty =>
      onRename == null &&
      onPin == null &&
      onArchive == null &&
      onDelete == null;

  String _archiveLabel(AppLocalizations l10n) =>
      archived ? l10n.sidebarUnarchive : l10n.sidebarArchive;

  List<SidebarMenuItem> items(
    AppLocalizations l10n, {
    List<SidebarMenuItem> before = const [],
    List<SidebarMenuItem> afterArchive = const [],
  }) => [
    ...before,
    if (onRename case final action?)
      SidebarMenuItem(
        l10n.commonRename,
        icon: Icons.edit_outlined,
        onSelected: action,
      ),
    if (onPin case final action?) SidebarRowMenuItems.pin(l10n, pinned, action),
    if (onArchive case final action?)
      SidebarMenuItem(
        _archiveLabel(l10n),
        icon: Icons.inventory_2_outlined,
        onSelected: action,
      ),
    ...afterArchive,
    if (onDelete case final action?)
      SidebarMenuItem(
        l10n.commonDelete,
        icon: Icons.delete_outline_rounded,
        destructive: true,
        onSelected: action,
      ),
  ];
}

/// A foldable project header. The caller supplies its icon, optional badges
/// and actions; this widget is independent of the project's source.
class SidebarProjectRow extends StatelessWidget {
  const SidebarProjectRow({
    super.key,
    required this.title,
    this.collapsed = false,
    this.onToggle,
    this.icon,
    this.pinned = false,
    this.hiddenCount = 0,
    this.labelDetails,
    this.hiddenStatus,
    this.decorateLabel,
    this.onCreate,
    this.createButtonKey,
    this.createTooltip,
    this.wrapCreateButton,
    this.menuItems,
    this.alwaysShowActions = false,
    this.fadeActionsWhenIdle = false,
    this.keyboardFocusableActions = false,
    this.isProject = true,
    this.light = false,
    this.highlighted = false,
    this.speedMatch = const [],
  });

  static const extent = 40.0;
  static const _topGap = 8.0;

  final String title;
  final bool collapsed;
  final VoidCallback? onToggle;
  final Widget? icon;
  final bool pinned;
  final int hiddenCount;
  final Widget? labelDetails;
  final Widget? hiddenStatus;
  final Widget Function(Widget label)? decorateLabel;
  final VoidCallback? onCreate;
  final Key? createButtonKey;
  final String? createTooltip;
  final Widget Function(Widget button)? wrapCreateButton;
  final List<SidebarMenuItem> Function()? menuItems;
  final bool alwaysShowActions;
  final bool fadeActionsWhenIdle;
  final bool keyboardFocusableActions;
  final bool isProject;
  final bool light;
  final bool highlighted;
  final List<int> speedMatch;

  @override
  Widget build(BuildContext context) => Semantics(
    button: onToggle == null ? null : true,
    child: _withRowMenu(menuItems, _build),
  );

  Widget _build(BuildContext context, SidebarMenuState? menu) {
    final label = Text.rich(
      ideSpeedSpan(title, speedMatch),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: isProject ? AppColors.text : AppColors.textMuted,
        fontSize: isProject ? 13 : 11.5,
        fontWeight: isProject ? FontWeight.w600 : FontWeight.w500,
      ),
    );
    final l10n = context.l10n;
    return HoverBuilder(
      cursor: onToggle == null ? MouseCursor.defer : SystemMouseCursors.click,
      builder: (context, hovered) {
        final active = hovered || (menu?.isOpen ?? false);
        final mountActions = active || alwaysShowActions;
        final create = mountActions && onCreate != null
            ? SidebarIconButton(
                key: createButtonKey,
                icon: Icons.add_rounded,
                tooltip: createTooltip ?? l10n.sidebarNewAgentIn(title),
                size: 20,
                keyboardFocusable: keyboardFocusableActions,
                onTap: onCreate!,
              )
            : null;
        final menuButton = mountActions && menu != null
            ? SidebarIconButton(
                icon: Icons.more_horiz_rounded,
                tooltip: l10n.sidebarMoreActions,
                size: 20,
                keyboardFocusable: keyboardFocusableActions,
                onTap: menu.open,
              )
            : null;
        final wrappedCreate = create == null
            ? null
            : wrapCreateButton?.call(create) ?? create;

        Widget buildRow(BuildContext context, bool actionsVisible) {
          final reservedActionsWidth =
              alwaysShowActions && fadeActionsWhenIdle && actionsVisible
              ? (menuButton != null ? 22.0 : 0.0) +
                    (wrappedCreate != null ? 22.0 : 0.0)
              : 0.0;
          final showCount =
              collapsed &&
              !light &&
              hiddenCount > 0 &&
              !(alwaysShowActions && fadeActionsWhenIdle && actionsVisible);
          return Container(
            height: extent - _topGap,
            margin: const EdgeInsets.only(top: _topGap),
            padding: EdgeInsets.only(left: light ? 6 : 4, right: 2),
            decoration: BoxDecoration(
              color: (active || highlighted) && isProject
                  ? AppColors.hover
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                if (!light) ...[
                  AnimatedRotation(
                    turns: collapsed ? 0 : 0.25,
                    duration: const Duration(milliseconds: 150),
                    child: Icon(
                      Icons.chevron_right_rounded,
                      size: 15,
                      color: hovered
                          ? AppColors.textMuted
                          : AppColors.textFaint,
                    ),
                  ),
                  const SizedBox(width: 2),
                ],
                if (icon case final icon?) ...[icon, const SizedBox(width: 4)],
                Expanded(
                  child: Row(
                    children: [
                      Flexible(child: decorateLabel?.call(label) ?? label),
                      ?labelDetails,
                      if (pinned) ...[
                        const SizedBox(width: 4),
                        Icon(
                          Icons.push_pin,
                          size: 11,
                          color: AppColors.textFaint,
                        ),
                      ],
                      if (collapsed && hiddenStatus != null) ...[
                        const SizedBox(width: 6),
                        hiddenStatus!,
                      ],
                    ],
                  ),
                ),
                if (showCount)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Text(
                      '$hiddenCount',
                      style: TextStyle(
                        color: AppColors.textFaint,
                        fontSize: 11,
                      ),
                    ),
                  ),
                if (alwaysShowActions && fadeActionsWhenIdle)
                  SizedBox(width: reservedActionsWidth)
                else ...[
                  ?menuButton,
                  ?wrappedCreate,
                ],
              ],
            ),
          );
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onToggle,
          onSecondaryTapUp: menu == null
              ? null
              : (details) => menu.open(details.globalPosition),
          child:
              alwaysShowActions &&
                  fadeActionsWhenIdle &&
                  (menuButton != null || wrappedCreate != null)
              ? _FocusAwareReveal(
                  visible: active,
                  builder: (context, actionsVisible) => Stack(
                    alignment: AlignmentDirectional.center,
                    children: [
                      buildRow(context, actionsVisible),
                      Positioned.directional(
                        textDirection: Directionality.of(context),
                        end: 2,
                        top: _topGap,
                        bottom: 0,
                        child: Center(
                          child: AnimatedOpacity(
                            opacity: actionsVisible ? 1.0 : 0.0,
                            duration: const Duration(milliseconds: 120),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                ?menuButton,
                                ?wrappedCreate,
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              : buildRow(context, active),
        );
      },
    );
  }
}

/// A conversation row with the same selection, status, title and actions in
/// both catalogs. Optional slots add details without making this widget own
/// either catalog, selection model or action implementation.
class SidebarSessionRow extends StatelessWidget {
  const SidebarSessionRow({
    super.key,
    required this.title,
    this.selected = false,
    this.onTap,
    this.onDoubleTap,
    this.focusedItem,
    this.focused = false,
    this.status = ThreadStatus.idle,
    this.emphasized = false,
    this.unreadCount = 0,
    this.updatedAt,
    this.showTime = false,
    this.suppressTimestamp = false,
    this.actions = const SidebarSessionActions(),
    this.showMenuButton = false,
    this.fadeMenuButtonWhenIdle = false,
    this.showPinnedMarker = false,
    this.showSelectionOutline = true,
    this.menuButtonKey,
    this.menuTooltip,
    this.menuItems,
    this.onContextMenu,
    this.leadingPadding = 16.0,
    this.extraIndent = 0,
    this.titleSuffix = const [],
    this.editor,
    this.hoverContent,
    this.leading,
    this.trailing,
  });

  static const extent = 32.0;

  final String title;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;
  final bool? focusedItem;
  final bool focused;
  final ThreadStatus status;
  final bool emphasized;
  final int unreadCount;
  final DateTime? updatedAt;
  final bool showTime;
  final bool suppressTimestamp;
  final SidebarSessionActions actions;
  final bool showMenuButton;
  final bool fadeMenuButtonWhenIdle;
  final bool showPinnedMarker;
  final bool showSelectionOutline;
  final Key? menuButtonKey;
  final String? menuTooltip;
  final List<SidebarMenuItem> Function()? menuItems;
  final VoidCallback? onContextMenu;
  final double leadingPadding;
  final double extraIndent;
  final List<InlineSpan> titleSuffix;
  final Widget? editor;
  final WidgetBuilder? hoverContent;
  final Widget? Function(BuildContext context, bool active)? leading;
  final List<GiveWay> Function(
    BuildContext context,
    bool active,
    Color foreground,
  )?
  trailing;

  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    button: onTap == null || editor != null ? null : true,
    child: _withRowMenu(
      menuItems ?? (actions.isEmpty ? null : () => actions.items(context.l10n)),
      _build,
    ),
  );

  Widget _build(BuildContext context, SidebarMenuState? menu) => IdeListRow(
    height: extent,
    selected: selected,
    focusedItem: focusedItem,
    focused: focused,
    keepSelectionActive: true,
    showSelectionOutline: showSelectionOutline,
    onTap: editor == null ? onTap : null,
    onDoubleTap: editor == null ? onDoubleTap : null,
    onContextMenu: menu == null
        ? null
        : (position) {
            onContextMenu?.call();
            menu.open(position);
          },
    builder: (context, hovered) {
      final active = hovered || (menu?.isOpen ?? false);
      final foreground = selected
          ? IdeListColors.activeSelectionForeground
          : hovered
          ? IdeListColors.hoverForeground
          : IdeListColors.foreground;
      final l10n = context.l10n;
      final menuOverlay = showMenuButton && fadeMenuButtonWhenIdle && menu != null;

      Widget buildRowContent(bool menuVisible) => Padding(
        padding: EdgeInsets.only(left: leadingPadding + extraIndent, right: 4),
        // Keep the title legible in a narrow sidebar before showing details.
        child: GiveWayRow(
          children: [
            GiveWay(
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: SizedBox(
                  width: 14,
                  child: Center(
                    child:
                        leading?.call(context, active) ??
                        _statusIndicator(l10n),
                  ),
                ),
              ),
            ),
            GiveWay.fill(
              minWidth: editor == null ? 80 : 0,
              editor ??
                  SidebarRowHover(
                    content: hoverContent ?? _defaultHover,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: _title(foreground),
                    ),
                  ),
            ),
            if (editor == null) ...[
              ...?trailing?.call(context, active, foreground),
              if (unreadCount > 0)
                GiveWay(
                  priority: 2,
                  _gap(
                    Semantics(
                      label: '${l10n.sidebarUnread} $unreadCount',
                      excludeSemantics: true,
                      child: Text(
                        '$unreadCount',
                        style: TextStyle(color: foreground, fontSize: 11),
                      ),
                    ),
                  ),
                ),
              if (active &&
                  (actions.onPin != null || actions.onArchive != null))
                GiveWay(
                  _gap(
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (actions.onPin case final pin?)
                          SidebarIconButton(
                            icon: SidebarRowMenuItems.pinIcon(actions.pinned),
                            tooltip: SidebarRowMenuItems.pinLabel(
                              l10n,
                              actions.pinned,
                            ),
                            size: 20,
                            onTap: pin,
                          ),
                        if (actions.onArchive case final archive?)
                          SidebarIconButton(
                            icon: actions.archived
                                ? Icons.unarchive_outlined
                                : Icons.inventory_2_outlined,
                            tooltip: actions._archiveLabel(l10n),
                            size: 20,
                            onTap: archive,
                          ),
                      ],
                    ),
                  ),
                )
              else if (updatedAt case final time? when showTime)
                GiveWay(
                  priority: 1,
                  _gap(
                    ConstrainedBox(
                      constraints: const BoxConstraints(minWidth: 26),
                      child: Text(
                        suppressTimestamp
                            ? ''
                            : relativeTime(time, DateTime.now(), l10n),
                        textAlign: TextAlign.right,
                        maxLines: 1,
                        style: TextStyle(
                          color: AppColors.textFaint,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ),
                ),
              if (showPinnedMarker && actions.pinned)
                GiveWay(
                  priority: 2,
                  _gap(
                    Semantics(
                      label: l10n.sidebarPinned,
                      child: Icon(
                        Icons.push_pin_outlined,
                        size: 12,
                        color: foreground,
                      ),
                    ),
                  ),
                ),
              if (menuOverlay) ...[
                if (menuVisible) const GiveWay(SizedBox(width: 24)),
              ] else if (showMenuButton && menu != null)
                GiveWay(
                  _gap(
                    SidebarIconButton(
                      key: menuButtonKey,
                      icon: Icons.more_horiz_rounded,
                      tooltip: menuTooltip ?? l10n.sidebarMoreActions,
                      size: 20,
                      keyboardFocusable: true,
                      onTap: menu.open,
                    ),
                  ),
                ),
              const GiveWay(SizedBox(width: 2)),
            ],
          ],
        ),
      );

      if (!menuOverlay) return buildRowContent(false);
      return _FocusAwareReveal(
        visible: active,
        builder: (context, menuVisible) => Stack(
          alignment: AlignmentDirectional.centerStart,
          children: [
            buildRowContent(menuVisible),
            if (editor == null)
              Positioned.directional(
                textDirection: Directionality.of(context),
                end: 4,
                top: 0,
                bottom: 0,
                child: Center(
                  child: AnimatedOpacity(
                    opacity: menuVisible ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 120),
                    child: SidebarIconButton(
                      key: menuButtonKey,
                      icon: Icons.more_horiz_rounded,
                      tooltip: menuTooltip ?? l10n.sidebarMoreActions,
                      size: 20,
                      keyboardFocusable: true,
                      onTap: menu.open,
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );

  static Widget _gap(Widget child) =>
      Padding(padding: const EdgeInsets.only(left: 6), child: child);

  Widget _title(Color foreground) => Text.rich(
    TextSpan(text: title, children: titleSuffix),
    maxLines: 1,
    softWrap: false,
    overflow: TextOverflow.ellipsis,
    // Keep line metrics stable as hover actions change available width.
    strutStyle: const StrutStyle(
      fontSize: 12.5,
      height: 1.4,
      forceStrutHeight: true,
    ),
    style: TextStyle(
      color: foreground,
      fontSize: 12.5,
      fontWeight: emphasized || unreadCount > 0
          ? FontWeight.w600
          : !showSelectionOutline && selected
          ? FontWeight.w500
          : FontWeight.normal,
    ),
  );

  String? _statusLabel(AppLocalizations l10n) => switch (status) {
    ThreadStatus.running => l10n.sidebarRunning,
    ThreadStatus.needsInput => l10n.sidebarNeedsInput,
    ThreadStatus.unread => l10n.sidebarUnread,
    ThreadStatus.idle => null,
  };

  Widget _statusIndicator(AppLocalizations l10n) {
    final indicator = StatusIndicator(status);
    final label = _statusLabel(l10n);
    if (label == null) return indicator;
    return SidebarRowHover(
      content: (_) => Text(label),
      child: Semantics(label: label, container: true, child: indicator),
    );
  }

  Widget _defaultHover(BuildContext context) {
    final l10n = context.l10n;
    final detail = [
      if (status != ThreadStatus.unread || unreadCount == 0)
        ?_statusLabel(l10n),
      if (unreadCount > 0) '${l10n.sidebarUnread} $unreadCount',
      if (updatedAt case final time?) relativeTime(time, DateTime.now(), l10n),
    ].join(' · ');
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
          if (detail.isNotEmpty)
            Text(
              detail,
              style: TextStyle(color: AppColors.textMuted, fontSize: 12),
            ),
        ],
      ),
    );
  }
}

Widget _withRowMenu(
  List<SidebarMenuItem> Function()? items,
  Widget Function(BuildContext context, SidebarMenuState? menu) builder,
) => items == null
    ? Builder(builder: (context) => builder(context, null))
    : SidebarMenu(
        items: items,
        placement: (side: FloatingSide.bottom, align: FloatingAlign.end),
        builder: builder,
      );

/// A workbench hover with its own overlay entry. An [IdeHover] (using an
/// OverlayPortal) within the row menu's OverlayPortal can leave stale
/// semantics behind when it hides.
class SidebarRowHover extends StatefulWidget {
  const SidebarRowHover({
    super.key,
    required this.content,
    required this.child,
  });

  final WidgetBuilder content;
  final Widget child;

  @override
  State<SidebarRowHover> createState() => _SidebarRowHoverState();
}

class _SidebarRowHoverState extends State<SidebarRowHover> {
  Timer? _timer;
  OverlayEntry? _entry;

  /// Where the pointer last moved over the target, in the target.
  Offset _mouse = Offset.zero;

  void _enter(PointerEnterEvent event) {
    _mouse = event.localPosition;
    _timer?.cancel();
    _timer = Timer(ideHoverDelay, _show);
  }

  void _hide() {
    _timer?.cancel();
    _timer = null;
    _entry
      ?..remove()
      ..dispose();
    _entry = null;
  }

  void _show() {
    final box = context.findRenderObject();
    final overlay = Overlay.maybeOf(context);
    final overlayBox = overlay?.context.findRenderObject();
    if (overlay == null ||
        box is! RenderBox ||
        !box.attached ||
        overlayBox is! RenderBox) {
      return;
    }
    final target =
        box.localToGlobal(Offset.zero, ancestor: overlayBox) & box.size;
    final x = target.left + _mouse.dx + 10;
    final entry = _entry = OverlayEntry(
      builder: (context) => CustomSingleChildLayout(
        delegate: _BelowMouse(target, x),
        child: IgnorePointer(
          child: ExcludeSemantics(
            child: Material(
              type: MaterialType.transparency,
              child: IdeHoverBox(
                compact: false,
                child: widget.content(context),
              ),
            ),
          ),
        ),
      ),
    );
    overlay.insert(entry);
  }

  @override
  void dispose() {
    _hide();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (_) => _hide(),
    onPointerSignal: (_) => _hide(),
    child: MouseRegion(
      onEnter: _enter,
      onHover: (event) => _mouse = event.localPosition,
      onExit: (_) => _hide(),
      child: widget.child,
    ),
  );
}

/// Below the target (above where there is no room), from [x]; inside the overlay.
class _BelowMouse extends SingleChildLayoutDelegate {
  const _BelowMouse(this.target, this.x);

  final Rect target;
  final double x;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final y = target.bottom + childSize.height > size.height
        ? target.top - childSize.height
        : target.bottom - 2;
    return clampHoverOffset(Offset(x, y), childSize, size);
  }

  @override
  bool shouldRelayout(_BelowMouse oldDelegate) =>
      oldDelegate.target != target || oldDelegate.x != x;
}

/// What an agent needs: a spinner while it runs, an amber dot when it
/// waits on a question, a blue dot when it finished unseen.
class StatusIndicator extends StatelessWidget {
  const StatusIndicator(this.status, {super.key});

  /// As the agent sessions list shows an agent waiting on the user.
  static Color get needsInputColor => themeColors['list.warningForeground'];

  final ThreadStatus status;

  @override
  Widget build(BuildContext context) => switch (status) {
    ThreadStatus.running => const PixelLoader.agent(size: 12),
    ThreadStatus.needsInput => _dot(needsInputColor),
    ThreadStatus.unread => _dot(AppColors.accent),
    ThreadStatus.idle => const SizedBox.shrink(),
  };

  static Widget _dot(Color color) => Container(
    width: 7,
    height: 7,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

/// Small square icon button with a hover fill.
class SidebarIconButton extends StatelessWidget {
  const SidebarIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.size = 24,
    this.keyboardFocusable = false,
    this.command,
    this.keyContext = ChatKeys.chatLayout,
    this.spinning = false,
  });

  final IconData icon;

  /// Its icon turning: what it started still goes on.
  final bool spinning;

  /// What it does: its label, and its hover's text.
  final String tooltip;
  final VoidCallback onTap;
  final double size;
  final bool keyboardFocusable;

  /// The command it runs, if a keybinding can run it too: its hover adds
  /// the key, as the keybindings have it now (`Hide sidebar (⌘B)`).
  final String? command;

  /// The context keys where it is, which pick the keybinding shown: the
  /// chat layout's by default.
  final Map<String, Object> keyContext;

  @override
  Widget build(BuildContext context) {
    final message = switch (command) {
      final command? => ChatKeys.titleWithKey(tooltip, command, keyContext),
      null => tooltip,
    };
    if (keyboardFocusable) {
      // A tooltip portal nested inside the menu's portal can leave stale
      // semantics when keyboard focus moves between the button and the menu.
      return SidebarRowHover(
        content: (_) => Text(message),
        child: Semantics(
          label: tooltip,
          child: IconButton(
            onPressed: onTap,
            padding: EdgeInsets.zero,
            style: IconButton.styleFrom(
              minimumSize: Size.square(size),
              fixedSize: Size.square(size),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.standard,
              foregroundColor: AppColors.textMuted,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(5),
              ),
            ),
            icon: _icon(),
          ),
        ),
      );
    }
    return IdeHover(
      message: message,
      excludeFromSemantics: true,
      child: Semantics(
        button: true,
        label: tooltip,
        child: HoverBuilder(
          cursor: SystemMouseCursors.click,
          builder: (context, hovered) => GestureDetector(
            onTap: onTap,
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: hovered
                    ? themeColors['toolbar.hoverBackground']
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(5),
              ),
              child: _icon(hovered ? AppColors.text : AppColors.textMuted),
            ),
          ),
        ),
      ),
    );
  }

  Widget _icon([Color? color]) {
    final graphic = AppIcon(icon, size: size * 0.65, color: color);
    return spinning ? IdeSpinning(graphic) : graphic;
  }
}

/// Reveals hover-only row actions when the pointer hovers the row OR any
/// action inside receives keyboard focus, without blocking hit testing at rest.
class _FocusAwareReveal extends StatefulWidget {
  const _FocusAwareReveal({required this.visible, required this.builder});

  final bool visible;
  final Widget Function(BuildContext context, bool shown) builder;

  @override
  State<_FocusAwareReveal> createState() => _FocusAwareRevealState();
}

class _FocusAwareRevealState extends State<_FocusAwareReveal> {
  bool _hasFocus = false;

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onFocusChange: (focused) {
      if (focused != _hasFocus) setState(() => _hasFocus = focused);
    },
    child: widget.builder(context, widget.visible || _hasFocus),
  );
}
