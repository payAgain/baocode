import 'dart:async';

import 'package:bao_link/bao_link.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';
import '../theme/app_theme.dart';
import 'computer_admission_prompt.dart';
import 'computer_admission_review.dart';
import 'computer_group.dart';
import 'desktop_host_connection.dart';
import 'link_host.dart';

/// The single trust group and workspace switcher at the top of remote navigation.
class ComputerGroupSidebar extends StatefulWidget {
  const ComputerGroupSidebar({
    super.key,
    required this.host,
    required this.connection,
    required this.expanded,
    required this.onToggle,
    required this.onLocal,
    required this.onSelect,
    required this.onConnectionInfo,
    this.reviewVisible = true,
  });

  final LinkHost? host;
  final DesktopHostConnection connection;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback onLocal;
  final ValueChanged<String> onSelect;
  final ValueChanged<String> onConnectionInfo;
  final bool reviewVisible;

  @override
  State<ComputerGroupSidebar> createState() => _ComputerGroupSidebarState();
}

enum _Setup { create, invite, nearby }

enum _DeviceAction { details, connectionInfo, reconnect, remove }

enum _SettingsAction { permissions, sync, pause }

class _ComputerGroupSidebarState extends State<ComputerGroupSidebar> {
  final _input = TextEditingController();
  final _reviewAnchor = GlobalKey();
  _Setup? _setup;
  bool _busy = false;
  bool _failed = false;
  bool _copied = false;
  bool _showInviteOptions = false;
  bool _browsing = false;
  bool _invitingNearby = false;
  ComputerGroupJoinPreview? _preview;
  ComputerGroupApproval? _revealedRequest;
  VoidCallback? _releaseReview;
  int _viewEpoch = 0;

  LinkHost get _host => widget.host!;
  DesktopHostConnection get _connection => widget.connection;
  bool get _canReview => widget.expanded && widget.reviewVisible;

  @override
  void initState() {
    super.initState();
    _bindReview();
    _refreshPresence();
  }

  @override
  void didUpdateWidget(ComputerGroupSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.expanded && !widget.expanded) _closeTransient();
    _bindReview();
    if (!oldWidget.expanded && widget.expanded) _refreshPresence();
  }

  void _bindReview() {
    final host = widget.host;
    if (_canReview && host?.supported == true) {
      _releaseReview ??= ownInlineComputerReview(host!);
    } else {
      _releaseReview?.call();
      _releaseReview = null;
    }
  }

  void _refreshPresence() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.expanded) {
        unawaited(widget.host?.refreshComputerGroupPresence());
      }
    });
  }

  /// A pending consent has already been sent and can finish in the background.
  /// Only browsing, advertising, and *unconfirmed* previews belong to this UI.
  void _closeTransient() {
    _viewEpoch++;
    final preview = _preview;
    final host = widget.host;
    final connection = _connection;
    final browsing = _browsing;
    final inviting = _invitingNearby;
    _preview = null;
    _setup = null;
    _showInviteOptions = _copied = _browsing = _invitingNearby = _failed =
        false;
    _revealedRequest = null;
    if (preview == null && !browsing && !inviting) return;
    // LinkHost and the connection can notify ancestors that are still building.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (preview != null) host?.cancelGroupJoin(preview);
      if (browsing) unawaited(connection.stopDiscovery());
      if (inviting) host?.cancelGroupInvite();
    });
  }

  @override
  void dispose() {
    _releaseReview?.call();
    _closeTransient();
    _input.dispose();
    super.dispose();
  }

  Future<void> _run(FutureOr<void> Function() action) async {
    if (_busy) return;
    final epoch = _viewEpoch;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      await action();
    } on Object {
      if (mounted && epoch == _viewEpoch) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _prepare(
    Future<ComputerGroupJoinPreview> Function() prepare,
  ) async {
    final host = _host;
    final epoch = _viewEpoch;
    if (!host.groupConnectionsAvailable) await host.enableGroupConnections();
    if (!mounted || epoch != _viewEpoch) return;
    final preview = await prepare();
    if (mounted && epoch == _viewEpoch) {
      _stopBrowse();
      setState(() => _preview = preview);
    } else {
      host.cancelGroupJoin(preview);
    }
  }

  void _stopBrowse() {
    if (!_browsing) return;
    _browsing = false;
    unawaited(_connection.stopDiscovery());
  }

  String _fingerprint(String id) => fingerprintOf(keyOfDeviceId(id)!);

  void _revealReview(ComputerGroupApproval? request) {
    if (identical(request, _revealedRequest)) return;
    _revealedRequest = request;
    if (request == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final anchor = _reviewAnchor.currentContext;
      if (mounted &&
          _canReview &&
          identical(_revealedRequest, request) &&
          anchor != null) {
        // Keep consent and the permission text readable from the beginning.
        if (Scrollable.maybeOf(anchor) != null) {
          unawaited(Scrollable.ensureVisible(anchor));
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = _Text(context);
    return ListenableBuilder(
      listenable: Listenable.merge([widget.host, _connection]),
      builder: (context, _) {
        final host = widget.host;
        final supported = host?.supported == true;
        final history = host?.computerGroup;
        final local = history?.active[host?.id];
        final group =
            local == null || !supported || host!.computerGroupStorageError
            ? null
            : history;
        final share = group != null && host!.groupConnectionsAvailable;
        final request = host?.pendingGroupApproval;
        final selected = group?.active[_connection.selectedHostId];
        final expanded = widget.expanded;
        _revealReview(_canReview ? request : null);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    expanded: expanded,
                    child: _SidebarAction(
                      key: const ValueKey('computer-group-toggle'),
                      icon: expanded ? Icons.expand_more : Icons.chevron_right,
                      label: context.l10n.myComputers,
                      onTap: widget.onToggle,
                      trailing: !expanded && request != null
                          ? Tooltip(
                              message: text.pendingReview,
                              child: Icon(
                                Icons.circle,
                                size: 7,
                                color: AppColors.accent,
                              ),
                            )
                          : null,
                    ),
                  ),
                ),
                if (expanded && group != null) _settings(text, group, share),
                if (!expanded)
                  IconButton(
                    tooltip: text.returnLocal,
                    onPressed: widget.onLocal,
                    icon: const Icon(Icons.keyboard_return, size: 16),
                  ),
              ],
            ),
            if (!expanded && selected != null)
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 28, bottom: 8),
                child: Text(
                  selected.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                ),
              ),
            if (expanded) ...[
              _localRow(text, group == null ? null : local),
              if (group != null)
                for (final member in group.active.values)
                  if (member.id != local!.id) _member(text, group, member),
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(8, 4, 8, 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final child in _controls(
                      text,
                      supported,
                      history,
                      group,
                      share,
                      request,
                    ))
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: child,
                      ),
                  ],
                ),
              ),
            ],
            Divider(height: 1, color: AppColors.partBorder),
          ],
        );
      },
    );
  }

  List<Widget> _controls(
    _Text text,
    bool supported,
    ComputerGroup? history,
    ComputerGroup? group,
    bool share,
    ComputerGroupApproval? request,
  ) {
    if (!supported) return [Text(context.l10n.myComputersUnavailable)];
    if (_host.computerGroupStorageError) return [Text(text.storage)];
    if (history != null && group == null) return [Text(text.youRemoved)];
    final waiting = _host.confirmingGroupJoin;
    final preview = _preview;
    return [
      if (waiting != null) ...[
        ComputerAdmissionWaiting(
          title: text.waiting(waiting.sponsor.name),
          code: waiting.code,
        ),
        TextButton(
          onPressed: () => _host.cancelGroupJoin(waiting),
          child: Text(text.cancelJoin),
        ),
      ] else if (preview != null) ...[
        ComputerGroupAdmissionReview(
          title: text.joinVia(preview.sponsor.name),
          fingerprint: _fingerprint(preview.sponsor.id),
          code: preview.code,
          compact: true,
          primaryLabel: text.confirmJoin,
          onPrimary: _busy
              ? null
              : () {
                  setState(() {
                    _preview = null;
                    _setup = null;
                    _input.clear();
                  });
                  unawaited(_run(() => _host.confirmGroupJoin(preview)));
                },
          secondaryLabel: text.cancelJoin,
          onSecondary: _busy
              ? null
              : () {
                  _host.cancelGroupJoin(preview);
                  setState(() {
                    _preview = null;
                    _setup = null;
                    _input.clear();
                  });
                },
        ),
      ] else if (group == null) ...[
        ..._setupWidgets(text),
      ] else if (!share) ...[
        Text(text.paused),
        FilledButton(
          onPressed: _busy
              ? null
              : () => _run(() async {
                  await _host.enableGroupConnections();
                  if (mounted) _refreshPresence();
                }),
          child: Text(text.enable),
        ),
      ] else if (request != null && _canReview) ...[
        ComputerApprovalPanel(
          key: _reviewAnchor,
          compact: true,
          host: _host,
          request: request,
          onApproved: () {
            if (!mounted) return;
            setState(() => _invitingNearby = _showInviteOptions = false);
          },
        ),
      ] else if (group.canAdmit) ...[
        _SidebarAction(
          icon: _showInviteOptions ? Icons.expand_less : Icons.add,
          label: text.createInvite,
          onTap: _busy
              ? null
              : () {
                  if (_invitingNearby) _host.cancelGroupInvite();
                  setState(() {
                    _showInviteOptions = !_showInviteOptions;
                    _copied = _invitingNearby = false;
                  });
                },
        ),
        if (_showInviteOptions) ..._inviteWidgets(text),
      ],
      if (group != null)
        for (final id in group.removed)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(bottom: 8),
            title: Text(text.removed(group.known[id]!.name)),
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(_fingerprint(id)),
              Text(switch (_host.pendingGroupRemoval(id)) {
                final pending when pending.isNotEmpty => text.pending(
                  pending.map((id) => group.known[id]!.name).join(', '),
                ),
                _ => text.delivered,
              }),
            ],
          ),
      if (_failed || (_host.groupJoinFailed && group == null))
        Semantics(liveRegion: true, child: Text(text.failed)),
    ];
  }

  Widget _settings(_Text text, ComputerGroup group, bool share) =>
      PopupMenuButton<_SettingsAction>(
        tooltip: text.settings,
        icon: Icon(Icons.tune, size: 16, color: AppColors.textMuted),
        onSelected: (value) {
          if (_host.computerGroup?.id != group.id) return;
          switch (value) {
            case _SettingsAction.permissions:
              _info(text.access, Text(text.scope));
            case _SettingsAction.sync:
              unawaited(_run(_host.syncComputerGroup));
            case _SettingsAction.pause:
              unawaited(
                _run(() async {
                  if (_invitingNearby) _host.cancelGroupInvite();
                  setState(() => _invitingNearby = _showInviteOptions = false);
                  await _host.pauseGroupConnections();
                }),
              );
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem(
            value: _SettingsAction.permissions,
            child: Text(text.access),
          ),
          if (share && group.removed.isNotEmpty)
            PopupMenuItem(
              value: _SettingsAction.sync,
              enabled: !_busy,
              child: Text(text.sync),
            ),
          if (share)
            PopupMenuItem(
              value: _SettingsAction.pause,
              enabled: !_busy,
              child: Text(text.pause),
            ),
        ],
      );

  List<Widget> _setupWidgets(_Text text) => switch (_setup) {
    _Setup.create => [
      Text(text.scope),
      FilledButton(
        onPressed: _busy
            ? null
            : () => _run(() async {
                if (!_host.groupConnectionsAvailable) {
                  await _host.enableGroupConnections();
                }
                if (mounted) await _host.createComputerGroup();
              }),
        child: Text(text.confirmCreate),
      ),
      _back(),
    ],
    _Setup.invite => [
      TextField(
        key: const ValueKey('computer-group-invite'),
        controller: _input,
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
        decoration: InputDecoration(labelText: text.invite, isDense: true),
      ),
      ValueListenableBuilder(
        valueListenable: _input,
        builder: (context, value, _) => FilledButton(
          onPressed: _busy || value.text.trim().isEmpty
              ? null
              : () => _run(
                  () =>
                      _prepare(() => _host.prepareGroupJoin(value.text.trim())),
                ),
          child: Text(text.review),
        ),
      ),
      _back(),
    ],
    _Setup.nearby => [
      Text(text.findHint),
      if (_connection.discoveryError != null)
        Text(text.findFailed)
      else if (_connection.nearbyGroupHosts.isEmpty)
        Text(text.searching)
      else
        for (final advert in _connection.nearbyGroupHosts)
          OutlinedButton.icon(
            icon: const Icon(Icons.computer),
            label: Text(advert.name),
            onPressed: _busy
                ? null
                : () => _run(
                    () => _prepare(
                      () => _connection.prepareNearbyGroup(advert.id),
                    ),
                  ),
          ),
      _back(),
    ],
    null => [
      Text(text.welcome),
      Wrap(
        spacing: 8,
        children: [
          FilledButton(
            onPressed: _busy
                ? null
                : () => setState(() => _setup = _Setup.create),
            child: Text(text.create),
          ),
          OutlinedButton(
            onPressed: _busy
                ? null
                : () => setState(() => _setup = _Setup.invite),
            child: Text(text.useInvite),
          ),
          if (_connection.discoverySupported)
            OutlinedButton.icon(
              icon: const Icon(Icons.radar, size: 16),
              onPressed: _busy
                  ? null
                  : () {
                      setState(() {
                        _setup = _Setup.nearby;
                        _browsing = true;
                        _failed = false;
                      });
                      _connection.startDiscovery();
                    },
              label: Text(text.find),
            ),
        ],
      ),
    ],
  };

  Widget _back() => TextButton(
    onPressed: _busy
        ? null
        : () {
            _stopBrowse();
            setState(() {
              _setup = null;
              _failed = false;
            });
          },
    child: Text(context.l10n.commonCancel),
  );

  List<Widget> _inviteWidgets(_Text text) => [
    if (_invitingNearby) ...[
      Text(
        _host.invitingNearbyGroupMembers
            ? text.invitingNearby
            : text.inviteExpired,
      ),
      TextButton(
        onPressed: _busy
            ? null
            : () {
                _host.cancelGroupInvite();
                setState(() => _invitingNearby = false);
              },
        child: Text(text.stopInviting),
      ),
    ] else ...[
      Text(text.share),
      Wrap(
        spacing: 8,
        children: [
          FilledButton(
            onPressed: _busy
                ? null
                : () => _run(() async {
                    final invite = _host.createGroupInvite();
                    await Clipboard.setData(ClipboardData(text: invite));
                    if (mounted && _showInviteOptions) {
                      setState(() => _copied = true);
                    }
                  }),
            child: Text(_copied ? text.copied : text.copy),
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.radar, size: 16),
            onPressed: _busy
                ? null
                : () => _run(() {
                    _host.createGroupInvite(nearby: true);
                    setState(() {
                      _invitingNearby = true;
                      _copied = false;
                    });
                  }),
            label: Text(text.inviteNearby),
          ),
        ],
      ),
    ],
  ];

  void _info(String title, Widget content) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: content,
        scrollable: true,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.commonClose),
          ),
        ],
      ),
    );
  }

  Widget _localRow(_Text text, ComputerGroupMember? member) => _DeviceRow(
    key: const ValueKey('local-computer'),
    name: member?.name ?? text.local,
    status: member == null ? text.returnLocal : text.local,
    icon: Icons.desktop_windows_outlined,
    tooltip: text.returnLocal,
    onTap: widget.onLocal,
    menu: member == null ? null : _deviceMenu(text, member),
  );

  Widget _member(_Text text, ComputerGroup group, ComputerGroupMember member) {
    final selected = _connection.selectedHostId == member.id;
    final online = selected && _connection.peer?.remote == member.id;
    final allowed = _host.permitsGroupWorkspace(member.id);
    final connecting = selected && _connection.busy;
    final presence = _host.computerGroupPresence(member.id);
    final (status, indicator) = switch (presence) {
      _ when online || _host.groupWorkspaceConnected(member.id) => (
        text.connected,
        AppColors.added,
      ),
      _ when connecting => (text.connecting, AppColors.accent),
      ComputerGroupPresence.reachable => (text.reachable, AppColors.added),
      ComputerGroupPresence.unreachable => (
        text.unreachable,
        AppColors.textFaint,
      ),
      ComputerGroupPresence.unknown => (
        text.statusUnknown,
        AppColors.textFaint,
      ),
    };
    return _DeviceRow(
      key: ValueKey(('open-computer', member.id)),
      name: member.name,
      status: status,
      icon: Icons.devices_outlined,
      tooltip: member.name,
      selected: selected,
      indicator: indicator,
      onTap: allowed && !_connection.busy && !online
          ? () => widget.onSelect(member.id)
          : null,
      menu: _deviceMenu(
        text,
        member,
        group: group,
        online: online,
        canReconnect: selected && allowed && !_connection.busy && !online,
      ),
    );
  }

  Widget _deviceMenu(
    _Text text,
    ComputerGroupMember member, {
    ComputerGroup? group,
    bool online = false,
    bool canReconnect = false,
  }) => PopupMenuButton<_DeviceAction>(
    key: ValueKey(('computer-menu', member.id)),
    tooltip: text.options(member.name),
    icon: Icon(Icons.more_horiz, color: AppColors.textMuted, size: 18),
    onSelected: (value) {
      switch (value) {
        case _DeviceAction.details:
          _info(
            member.name,
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(text.fingerprint),
                const SizedBox(height: 8),
                SelectableText(_fingerprint(member.id)),
              ],
            ),
          );
        case _DeviceAction.connectionInfo:
          widget.onConnectionInfo(member.id);
        case _DeviceAction.reconnect:
          if (_connection.selectedHostId == member.id) {
            widget.onSelect(member.id);
          }
        case _DeviceAction.remove:
          if (group != null) unawaited(_confirmRemove(text, group, member));
      }
    },
    itemBuilder: (context) => [
      PopupMenuItem(value: _DeviceAction.details, child: Text(text.details)),
      if (online)
        PopupMenuItem(
          value: _DeviceAction.connectionInfo,
          child: Text(text.connectionInfo),
        ),
      if (canReconnect)
        PopupMenuItem(
          value: _DeviceAction.reconnect,
          child: Text(text.reconnect),
        ),
      if (group != null)
        PopupMenuItem(
          value: _DeviceAction.remove,
          enabled: !_busy && _host.permitsGroupWorkspace(member.id),
          child: Text(
            text.remove(member.name),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
    ],
  );

  Future<void> _confirmRemove(
    _Text text,
    ComputerGroup group,
    ComputerGroupMember member,
  ) async {
    bool stillAllowed() =>
        mounted &&
        !_busy &&
        _host.computerGroup?.id == group.id &&
        _host.permitsGroupWorkspace(member.id);
    if (!stillAllowed()) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(text.remove(member.name)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(text.removePrompt(member.name)),
            const SizedBox(height: 8),
            SelectableText(_fingerprint(member.id)),
          ],
        ),
        scrollable: true,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.commonCancel),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(text.confirmRemove),
          ),
        ],
      ),
    );
    if (confirmed == true && stillAllowed()) {
      await _run(() => _host.removeGroupMember(member.id));
    }
  }
}

class _SidebarAction extends StatelessWidget {
  const _SidebarAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.trailing,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(6),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 16, color: AppColors.textMuted),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 6), trailing!],
        ],
      ),
    ),
  );
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    super.key,
    required this.name,
    required this.status,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.selected = false,
    this.indicator,
    this.menu,
  });
  final String name, status, tooltip;
  final IconData icon;
  final VoidCallback? onTap;
  final bool selected;
  final Color? indicator;
  final Widget? menu;

  @override
  Widget build(BuildContext context) {
    final shape = BorderRadius.circular(7);
    return Material(
      color: selected
          ? AppColors.accent.withValues(alpha: 0.14)
          : Colors.transparent,
      borderRadius: shape,
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              selected: selected,
              button: onTap != null || selected,
              enabled: onTap != null,
              child: Tooltip(
                message: tooltip,
                excludeFromSemantics: tooltip == name,
                child: InkWell(
                  onTap: onTap,
                  borderRadius: shape,
                  child: Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(8, 6, 2, 6),
                    child: Row(
                      children: [
                        Icon(
                          icon,
                          size: 17,
                          color: selected
                              ? AppColors.accent
                              : AppColors.textMuted,
                        ),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                  color: AppColors.textPrimary,
                                ),
                              ),
                              Row(
                                children: [
                                  if (indicator != null) ...[
                                    Icon(
                                      Icons.circle,
                                      size: 6,
                                      color: indicator,
                                    ),
                                    const SizedBox(width: 5),
                                  ],
                                  Expanded(
                                    child: Text(
                                      status,
                                      style: TextStyle(
                                        color: AppColors.textMuted,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        if (selected)
                          Icon(Icons.check, size: 14, color: AppColors.accent),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          ?menu,
        ],
      ),
    );
  }
}

class _Text {
  _Text(BuildContext context)
    : zh = Localizations.localeOf(context).languageCode == 'zh';
  final bool zh;
  String get welcome => zh
      ? '创建一个可信电脑组，或使用另一台电脑发出的邀请。'
      : 'Create a group for your trusted computers or use an invite from another computer.';
  String get scope => admissionScope(zh);
  String get paused =>
      zh ? '这台电脑的组连接已暂停。' : 'Group connections are paused on this computer.';
  String get enable => zh ? '恢复连接' : 'Resume connections';
  String get storage => zh
      ? '无法验证已保存的信任组。组访问已停用。'
      : 'Could not verify saved group history. Group access is disabled.';
  String get create => zh ? '创建组' : 'Create group';
  String get confirmCreate => zh ? '创建并信任组成员' : 'Create and trust group';
  String get createInvite => zh ? '邀请电脑' : 'Invite computer';
  String get useInvite => zh ? '使用邀请' : 'Use invite';
  String get find => zh ? '查找电脑' : 'Find computer';
  String get findHint => zh
      ? '在另一台电脑上打开「我的电脑」，然后选择「邀请电脑 → 邀请附近的电脑」。'
      : 'On the other computer, open My computers and choose Invite computer → Invite nearby.';
  String get findFailed => zh
      ? '无法搜索局域网。请改用邀请链接。'
      : 'Could not search the local network. Use an invite link instead.';
  String get searching => zh
      ? '正在查找附近接受邀请的电脑…'
      : 'Looking for nearby computers accepting requests…';
  String get inviteNearby => zh ? '邀请附近的电脑' : 'Invite nearby';
  String get invitingNearby => zh
      ? '请在另一台电脑上选择「查找电脑」。离开设备列表将停止附近邀请。'
      : 'Choose Find computer on the other computer. Leaving the computer list stops the nearby invite.';
  String get inviteExpired =>
      zh ? '附近邀请已过期。' : 'The nearby invite has expired.';
  String get stopInviting => zh ? '停止附近邀请' : 'Stop inviting nearby';
  String get invite => zh ? '邀请链接' : 'Invite link';
  String get review => zh ? '查看邀请' : 'Review invite';
  String get share => zh
      ? '仅将此一次性邀请发给要加入的电脑。邀请会过期。'
      : 'Share this short-lived, one-time invite only with the joining computer.';
  String get copy => zh ? '复制邀请' : 'Copy invite';
  String get copied => zh ? '已复制邀请' : 'Invite copied';
  String get confirmJoin => zh ? '加入并共享工作区' : 'Join and share workspace';
  String get cancelJoin => zh ? '取消加入' : 'Cancel join';
  String get confirmRemove => zh ? '从组中移除' : 'Remove from group';
  String get youRemoved => zh
      ? '这台电脑已被移出组。本机已关闭组访问。'
      : 'This computer was removed from the group. Group access is disabled here.';
  String get connected => zh ? '工作区已连接' : 'Workspace connected';
  String get connecting => zh ? '正在连接…' : 'Connecting…';
  String get reachable => zh ? '最近可连接' : 'Recently reachable';
  String get unreachable => zh ? '暂时无法连接' : 'Currently unreachable';
  String get statusUnknown => zh ? '在线状态未知' : 'Online status unknown';
  String get access => zh ? '工作区权限' : 'Workspace permissions';
  String get sync => zh ? '同步成员变更' : 'Sync membership changes';
  String get pause =>
      zh ? '暂停本机的电脑组连接' : 'Pause group connections on this computer';
  String get failed => zh
      ? '无法完成组操作。请检查邀请、网络及两台电脑的组状态。'
      : 'The group action could not be completed. Check the invite, connection and group status on both computers.';
  String get delivered =>
      zh ? '已收到已知相关电脑的确认。' : 'Acknowledged by the known affected computers.';
  String get returnLocal => zh ? '切回本地' : 'Switch to local';
  String get connectionInfo => zh ? '连接信息' : 'Connection info';
  String get reconnect => zh ? '重新连接' : 'Reconnect';
  String get pendingReview => zh ? '有待处理的加入申请' : 'Join request pending';
  String remove(String name) => zh ? '移除 $name' : 'Remove $name';
  String removed(String name) => zh ? '已移除 $name' : 'Removed $name';
  String get local => zh ? '本机' : 'This computer';
  String get settings => zh ? '连接设置' : 'Connection settings';
  String get details => zh ? '设备详情' : 'Device details';
  String get fingerprint => zh ? '设备指纹' : 'Device fingerprint';
  String options(String name) => zh ? '$name 的更多操作' : 'More actions for $name';
  String joinVia(String name) =>
      zh ? '通过 $name 加入组' : 'Join the group through $name';
  String waiting(String name) =>
      zh ? '等待 $name 批准' : 'Waiting for $name to approve';
  String pending(String names) => zh
      ? '尚未收到确认（电脑可能离线）：$names'
      : 'Awaiting acknowledgment from $names. These computers may be offline.';
  String removePrompt(String name) => zh
      ? '从整个组中移除 $name？本机立即结束访问，其他电脑在收到变更后才会终止访问。此操作无法撤销。'
      : 'Remove $name from the whole group? Access ends on this computer immediately. Other computers enforce the removal when they receive it. This cannot be undone.';
}
