import 'dart:async';

import 'package:bao_link/bao_link.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chat/widgets/hover_builder.dart';
import '../l10n/l10n.dart';
import '../settings/pages/settings_widgets.dart' show SettingsColors, SettingsText;
import '../theme/app_theme.dart';
import '../theme/codicons.dart';
import '../theme/workbench_theme.dart' show themeColors;
import 'computer_admission_prompt.dart';
import 'computer_admission_review.dart';
import 'computer_group.dart';
import 'desktop_host_connection.dart';
import 'desktop_remote_dialog.dart';
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
        final selectedIndicator = selected == null
            ? null
            : _connection.peer?.remote == selected.id ||
                  _host.groupWorkspaceConnected(selected.id)
            ? AppColors.added
            : _connection.busy
            ? AppColors.accent
            : switch (_host.computerGroupPresence(selected.id)) {
                ComputerGroupPresence.reachable => AppColors.added,
                _ => SettingsColors.textQuaternary,
              };
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    expanded: expanded,
                    child: _ComputerSectionHeader(
                      key: const ValueKey('computer-group-toggle'),
                      expanded: expanded,
                      label: context.l10n.myComputers,
                      onTap: widget.onToggle,
                      trailing: !expanded && request != null
                          ? Tooltip(
                              message: text.pendingReview,
                              child: Container(
                                width: 6,
                                height: 6,
                                decoration: BoxDecoration(
                                  color: AppColors.accent,
                                  shape: BoxShape.circle,
                                ),
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
                    style: _compactHeaderIconStyle(),
                    icon: Icon(
                      Icons.keyboard_return_rounded,
                      size: 14,
                      color: SettingsColors.iconTertiary,
                    ),
                  ),
              ],
            ),
            if (!expanded && selected != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 2, 4, 4),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: SettingsColors.hover,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    children: [
                      if (selectedIndicator != null) ...[
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: selectedIndicator,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 7),
                      ],
                      Expanded(
                        child: Text(
                          selected.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AppColors.text,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (expanded) ...[
              const SizedBox(height: 2),
              _localRow(text, group == null ? null : local),
              if (group != null)
                for (final member in group.active.values)
                  if (member.id != local!.id) _member(text, group, member),
              ..._controls(
                text,
                supported,
                history,
                group,
                share,
                request,
              ),
            ],
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 4, 2),
              child: SizedBox(
                height: 1,
                child: ColoredBox(color: SettingsColors.stroke),
              ),
            ),
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
    if (!supported) {
      return [_panelCard([_mutedCopy(context.l10n.myComputersUnavailable)])];
    }
    if (_host.computerGroupStorageError) {
      return [_panelCard([_mutedCopy(text.storage)])];
    }
    if (history != null && group == null) {
      return [_panelCard([_mutedCopy(text.youRemoved)])];
    }
    final waiting = _host.confirmingGroupJoin;
    final preview = _preview;
    return [
      if (waiting != null)
        _panelCard([
          ComputerAdmissionWaiting(
            title: text.waiting(waiting.sponsor.name),
            code: waiting.code,
          ),
          TextButton(
            style: _secondaryTextButtonStyle(),
            onPressed: () => _host.cancelGroupJoin(waiting),
            child: Text(text.cancelJoin),
          ),
        ])
      else if (preview != null)
        _panelCard(compact: true, [
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
        ])
      else if (group == null)
        _panelCard(_setupWidgets(text))
      else if (!share)
        _panelCard([
          _mutedCopy(text.paused),
          FilledButton(
            style: _compactFilledButtonStyle(),
            onPressed: _busy
                ? null
                : () => _run(() async {
                    await _host.enableGroupConnections();
                    if (mounted) _refreshPresence();
                  }),
            child: Text(text.enable),
          ),
        ])
      else if (request != null && _canReview)
        _panelCard(compact: true, [
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
        ])
      else if (group.canAdmit) ...[
        Padding(
          padding: const EdgeInsets.only(top: 3),
          child: _InviteAction(
            icon: _showInviteOptions
                ? Icons.expand_less_rounded
                : Icons.add_rounded,
            label: text.createInvite,
            expanded: _showInviteOptions,
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
        ),
        if (_showInviteOptions) _panelCard(_inviteWidgets(text)),
      ],
      if (group != null)
        for (final id in group.removed)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Material(
              color: SettingsColors.card,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: BorderSide(color: SettingsColors.stroke),
              ),
              clipBehavior: Clip.antiAlias,
              child: ExpansionTile(
                tilePadding: const EdgeInsets.symmetric(horizontal: 10),
                childrenPadding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                title: Text(
                  text.removed(group.known[id]!.name),
                  style: SettingsText.label.copyWith(fontSize: 12.5),
                ),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(
                    _fingerprint(id),
                    style: SettingsText.path.copyWith(fontSize: 11.5),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    switch (_host.pendingGroupRemoval(id)) {
                      final pending when pending.isNotEmpty => text.pending(
                        pending.map((id) => group.known[id]!.name).join(', '),
                      ),
                      _ => text.delivered,
                    },
                    style: SettingsText.description.copyWith(fontSize: 11.5),
                  ),
                ],
              ),
            ),
          ),
      if (_failed || (_host.groupJoinFailed && group == null))
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 4, 6, 2),
          child: Semantics(
            liveRegion: true,
            child: Text(
              text.failed,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
        ),
    ];
  }

  Widget _panelCard(List<Widget> children, {bool compact = false}) => Padding(
    padding: compact
        ? const EdgeInsets.only(top: 4)
        : const EdgeInsets.fromLTRB(2, 6, 2, 2),
    child: Container(
      padding: EdgeInsets.all(compact ? 8 : 10),
      decoration: BoxDecoration(
        color: SettingsColors.card,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: SettingsColors.stroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) SizedBox(height: compact ? 6 : 8),
            children[i],
          ],
        ],
      ),
    ),
  );

  Widget _mutedCopy(String copy) => Text(
    copy,
    style: SettingsText.description.copyWith(fontSize: 12, height: 1.45),
  );

  ButtonStyle _compactHeaderIconStyle() => IconButton.styleFrom(
    minimumSize: const Size(24, 24),
    fixedSize: const Size(24, 24),
    padding: EdgeInsets.zero,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    foregroundColor: SettingsColors.iconTertiary,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
  );

  ButtonStyle _compactFilledButtonStyle() => FilledButton.styleFrom(
    minimumSize: const Size(0, 28),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    textStyle: Theme.of(context).textTheme.labelMedium?.copyWith(
      fontSize: 12,
      fontWeight: FontWeight.w500,
    ),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
  );

  ButtonStyle _compactOutlinedButtonStyle() => OutlinedButton.styleFrom(
    minimumSize: const Size(0, 28),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    foregroundColor: SettingsColors.textPrimary,
    side: BorderSide(color: SettingsColors.stroke),
    textStyle: Theme.of(context).textTheme.labelMedium?.copyWith(
      fontSize: 12,
      fontWeight: FontWeight.w500,
    ),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
  );

  ButtonStyle _secondaryTextButtonStyle() => TextButton.styleFrom(
    minimumSize: const Size(0, 28),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    foregroundColor: SettingsColors.textSecondary,
    textStyle: Theme.of(context).textTheme.labelMedium?.copyWith(
      fontSize: 12,
      fontWeight: FontWeight.w500,
    ),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
  );

  Widget _settings(_Text text, ComputerGroup group, bool share) =>
      PopupMenuButton<_SettingsAction>(
        tooltip: text.settings,
        style: _compactHeaderIconStyle(),
        color: AppColors.surfaceRaised,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: SettingsColors.stroke),
        ),
        icon: Icon(
          Icons.tune_rounded,
          size: 14,
          color: SettingsColors.iconTertiary,
        ),
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
            child: _menuItemLabel(
              Icons.verified_user_outlined,
              text.access,
            ),
          ),
          if (share && group.removed.isNotEmpty)
            PopupMenuItem(
              value: _SettingsAction.sync,
              enabled: !_busy,
              child: _menuItemLabel(Icons.sync_rounded, text.sync),
            ),
          if (share)
            PopupMenuItem(
              value: _SettingsAction.pause,
              enabled: !_busy,
              child: _menuItemLabel(
                Icons.pause_circle_outline_rounded,
                text.pause,
              ),
            ),
        ],
      );

  List<Widget> _setupWidgets(_Text text) => switch (_setup) {
    _Setup.create => [
      _mutedCopy(text.scope),
      FilledButton(
        style: _compactFilledButtonStyle(),
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
        style: SettingsText.label.copyWith(fontSize: 12.5),
        decoration: InputDecoration(
          labelText: text.invite,
          labelStyle: TextStyle(
            fontSize: 12,
            color: SettingsColors.textSecondary,
          ),
          isDense: true,
          filled: true,
          fillColor: AppColors.code,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 9,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: BorderSide(color: SettingsColors.stroke),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: BorderSide(color: SettingsColors.stroke),
          ),
        ),
      ),
      ValueListenableBuilder(
        valueListenable: _input,
        builder: (context, value, _) => FilledButton(
          style: _compactFilledButtonStyle(),
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
      _mutedCopy(text.findHint),
      if (_connection.discoveryError != null)
        _mutedCopy(text.findFailed)
      else if (_connection.nearbyGroupHosts.isEmpty)
        _mutedCopy(text.searching)
      else
        for (final advert in _connection.nearbyGroupHosts)
          OutlinedButton.icon(
            style: _compactOutlinedButtonStyle(),
            icon: const Icon(Icons.computer, size: 15),
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
      _mutedCopy(text.welcome),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          FilledButton(
            style: _compactFilledButtonStyle(),
            onPressed: _busy
                ? null
                : () => setState(() => _setup = _Setup.create),
            child: Text(text.create),
          ),
          OutlinedButton(
            style: _compactOutlinedButtonStyle(),
            onPressed: _busy
                ? null
                : () => setState(() => _setup = _Setup.invite),
            child: Text(text.useInvite),
          ),
          if (_connection.discoverySupported)
            OutlinedButton.icon(
              style: _compactOutlinedButtonStyle(),
              icon: const Icon(Icons.radar, size: 14),
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
    style: _secondaryTextButtonStyle(),
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
      _mutedCopy(
        _host.invitingNearbyGroupMembers
            ? text.invitingNearby
            : text.inviteExpired,
      ),
      TextButton(
        style: _secondaryTextButtonStyle(),
        onPressed: _busy
            ? null
            : () {
                _host.cancelGroupInvite();
                setState(() => _invitingNearby = false);
              },
        child: Text(text.stopInviting),
      ),
    ] else ...[
      _mutedCopy(text.share),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          FilledButton(
            style: _compactFilledButtonStyle(),
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
            style: _compactOutlinedButtonStyle(),
            icon: const Icon(Icons.radar, size: 14),
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
      builder: (context) => RemoteActionDialog(
        icon: Icons.info_outline_rounded,
        title: title,
        body: content,
        actions: [
          TextButton(
            style: remoteDialogSecondaryButtonStyle(context),
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
    icon: Codicons.deviceDesktop,
    tooltip: text.returnLocal,
    isLocal: member != null,
    onTap: widget.onLocal,
    menuBuilder: member == null
        ? null
        : (onOpened, onClosed) => _deviceMenu(
            text,
            member,
            onOpened: onOpened,
            onClosed: onClosed,
          ),
  );

  Widget _member(_Text text, ComputerGroup group, ComputerGroupMember member) {
    final selected = _connection.selectedHostId == member.id;
    final online = selected && _connection.peer?.remote == member.id;
    final allowed = _host.permitsGroupWorkspace(member.id);
    final connecting = selected && _connection.busy;
    final presence = _host.computerGroupPresence(member.id);
    final (status, indicator, statusMuted) = switch (presence) {
      _ when online || _host.groupWorkspaceConnected(member.id) => (
        text.connected,
        AppColors.added,
        false,
      ),
      _ when connecting => (text.connecting, AppColors.accent, false),
      ComputerGroupPresence.reachable => (text.reachable, AppColors.added, false),
      ComputerGroupPresence.unreachable => (
        text.unreachable,
        SettingsColors.textQuaternary,
        true,
      ),
      ComputerGroupPresence.unknown => (
        text.statusUnknown,
        SettingsColors.textQuaternary,
        true,
      ),
    };
    return _DeviceRow(
      key: ValueKey(('open-computer', member.id)),
      name: member.name,
      status: status,
      icon: Icons.devices_rounded,
      tooltip: member.name,
      selected: selected,
      indicator: indicator,
      statusMuted: statusMuted,
      onTap: allowed && !_connection.busy && !online
          ? () => widget.onSelect(member.id)
          : null,
      menuBuilder: (onOpened, onClosed) => _deviceMenu(
        text,
        member,
        group: group,
        online: online,
        canReconnect: selected && allowed && !_connection.busy && !online,
        onOpened: onOpened,
        onClosed: onClosed,
      ),
    );
  }

  Widget _deviceMenu(
    _Text text,
    ComputerGroupMember member, {
    ComputerGroup? group,
    bool online = false,
    bool canReconnect = false,
    VoidCallback? onOpened,
    VoidCallback? onClosed,
  }) => PopupMenuButton<_DeviceAction>(
    key: ValueKey(('computer-menu', member.id)),
    tooltip: text.options(member.name),
    style: _compactHeaderIconStyle(),
    color: AppColors.surfaceRaised,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(8),
      side: BorderSide(color: SettingsColors.stroke),
    ),
    icon: Icon(Icons.more_horiz_rounded, color: AppColors.textMuted, size: 16),
    onOpened: onOpened,
    onCanceled: onClosed,
    onSelected: (value) {
      onClosed?.call();
      switch (value) {
        case _DeviceAction.details:
          _info(
            member.name,
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(text.fingerprint, style: SettingsText.heading),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.code,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: SettingsColors.stroke),
                  ),
                  child: SelectableText(
                    _fingerprint(member.id),
                    style: SettingsText.path,
                  ),
                ),
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
      PopupMenuItem(
        value: _DeviceAction.details,
        child: _menuItemLabel(Icons.info_outline_rounded, text.details),
      ),
      if (online)
        PopupMenuItem(
          value: _DeviceAction.connectionInfo,
          child: _menuItemLabel(Icons.lan_outlined, text.connectionInfo),
        ),
      if (canReconnect)
        PopupMenuItem(
          value: _DeviceAction.reconnect,
          child: _menuItemLabel(Icons.refresh_rounded, text.reconnect),
        ),
      if (group != null)
        PopupMenuItem(
          value: _DeviceAction.remove,
          enabled: !_busy && _host.permitsGroupWorkspace(member.id),
          child: _menuItemLabel(
            Icons.person_remove_outlined,
            text.remove(member.name),
            color: Theme.of(context).colorScheme.error,
          ),
        ),
    ],
  );

  Widget _menuItemLabel(IconData icon, String label, {Color? color}) => Row(
    children: [
      Icon(icon, size: 15, color: color ?? AppColors.textMuted),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          label,
          style: color == null ? null : TextStyle(color: color),
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
      builder: (context) => RemoteActionDialog(
        icon: Icons.person_remove_outlined,
        destructive: true,
        title: text.remove(member.name),
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(text.removePrompt(member.name)),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.code,
                borderRadius: BorderRadius.circular(7),
                border: Border.all(color: SettingsColors.stroke),
              ),
              child: SelectableText(
                _fingerprint(member.id),
                style: SettingsText.path,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            style: remoteDialogSecondaryButtonStyle(context),
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.commonCancel),
          ),
          TextButton(
            style: remoteDialogDangerButtonStyle(context),
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

class _ComputerSectionHeader extends StatelessWidget {
  const _ComputerSectionHeader({
    super.key,
    required this.expanded,
    required this.label,
    required this.onTap,
    this.trailing,
  });

  final bool expanded;
  final String label;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => HoverBuilder(
    cursor: SystemMouseCursors.click,
    builder: (context, hovered) => GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          color: hovered ? AppColors.hover : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            AnimatedRotation(
              turns: expanded ? 0.25 : 0,
              duration: const Duration(milliseconds: 150),
              child: Icon(
                Icons.chevron_right_rounded,
                size: 14,
                color: hovered ? AppColors.textMuted : AppColors.textFaint,
              ),
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: hovered
                      ? SettingsColors.textPrimary
                      : SettingsColors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.2,
                ),
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 6), trailing!],
          ],
        ),
      ),
    ),
  );
}

class _InviteAction extends StatelessWidget {
  const _InviteAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.expanded = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool expanded;

  @override
  Widget build(BuildContext context) => HoverBuilder(
    cursor: onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
    builder: (context, hovered) => GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: hovered || expanded ? AppColors.hover : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 15,
              color: hovered || expanded
                  ? SettingsColors.textPrimary
                  : SettingsColors.iconTertiary,
            ),
            const SizedBox(width: 7),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: hovered || expanded
                      ? SettingsColors.textPrimary
                      : SettingsColors.textSecondary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _DeviceRow extends StatefulWidget {
  const _DeviceRow({
    super.key,
    required this.name,
    required this.status,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.selected = false,
    this.isLocal = false,
    this.statusMuted = false,
    this.indicator,
    this.menuBuilder,
  });

  final String name, status, tooltip;
  final IconData icon;
  final VoidCallback? onTap;
  final bool selected;
  final bool isLocal;
  final bool statusMuted;
  final Color? indicator;
  final Widget Function(VoidCallback onOpened, VoidCallback onClosed)?
  menuBuilder;

  @override
  State<_DeviceRow> createState() => _DeviceRowState();
}

class _DeviceRowState extends State<_DeviceRow> {
  bool _hovered = false;
  bool _menuOpen = false;
  bool _menuFocused = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final showMenu = _hovered || _menuOpen || _menuFocused;
    final fill = selected
        ? Color.alphaBlend(
            AppColors.accent.withValues(alpha: 0.10),
            SettingsColors.hover,
          )
        : _hovered
        ? AppColors.hover
        : Colors.transparent;
    final borderColor = selected
        ? (themeColors.highContrast
              ? SettingsColors.stroke
              : AppColors.accent.withValues(alpha: 0.24))
        : Colors.transparent;
    final statusColor = selected
        ? (widget.statusMuted
              ? SettingsColors.textSecondary
              : AppColors.added.withValues(alpha: 0.92))
        : widget.statusMuted
        ? SettingsColors.textQuaternary
        : SettingsColors.textTertiary;

    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: MouseRegion(
        cursor: widget.onTap == null
            ? MouseCursor.defer
            : SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: borderColor),
          ),
          child: Stack(
            alignment: AlignmentDirectional.centerStart,
            children: [
              Semantics(
                selected: selected,
                button: widget.onTap != null || selected,
                enabled: widget.onTap != null,
                child: Tooltip(
                  message: widget.tooltip,
                  excludeFromSemantics: widget.tooltip == widget.name,
                  child: Material(
                    type: MaterialType.transparency,
                    child: InkWell(
                      onTap: widget.onTap,
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                      padding: EdgeInsetsDirectional.fromSTEB(
                        7,
                        6,
                        widget.menuBuilder != null && showMenu ? 30 : 8,
                        6,
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 26,
                            height: 26,
                            decoration: BoxDecoration(
                              color: selected
                                  ? AppColors.accent.withValues(alpha: 0.16)
                                  : SettingsColors.hover,
                              borderRadius: BorderRadius.circular(6.5),
                            ),
                            alignment: Alignment.center,
                            child: Icon(
                              widget.icon,
                              size: widget.isLocal ? 14 : 14.5,
                              color: selected
                                  ? AppColors.accent
                                  : SettingsColors.iconTertiary,
                            ),
                          ),
                          const SizedBox(width: 9),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  widget.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontWeight: selected
                                        ? FontWeight.w600
                                        : FontWeight.w500,
                                    fontSize: 12.5,
                                    height: 1.25,
                                    color: selected
                                        ? AppColors.textPrimary
                                        : AppColors.text,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                if (widget.isLocal)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 5,
                                      vertical: 1,
                                    ),
                                    decoration: BoxDecoration(
                                      color: SettingsColors.hover,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      widget.status,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: SettingsColors.textSecondary,
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w500,
                                        height: 1.2,
                                      ),
                                    ),
                                  )
                                else
                                  Row(
                                    children: [
                                      if (widget.indicator case final dot?) ...[
                                        Container(
                                          width: 6,
                                          height: 6,
                                          decoration: BoxDecoration(
                                            color: dot,
                                            shape: BoxShape.circle,
                                          ),
                                        ),
                                        const SizedBox(width: 5),
                                      ],
                                      Expanded(
                                        child: Text(
                                          widget.status,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: statusColor,
                                            fontSize: 11,
                                            height: 1.25,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
              if (widget.menuBuilder case final buildMenu?)
                Positioned.directional(
                  textDirection: Directionality.of(context),
                  end: 4,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: Focus(
                      canRequestFocus: false,
                      skipTraversal: true,
                      onFocusChange: (focused) {
                        if (focused != _menuFocused) {
                          setState(() => _menuFocused = focused);
                        }
                      },
                      child: AnimatedOpacity(
                        opacity: showMenu ? 1.0 : 0.0,
                        duration: const Duration(milliseconds: 120),
                        child: buildMenu(
                          () => setState(() => _menuOpen = true),
                          () {
                            if (mounted) setState(() => _menuOpen = false);
                          },
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    return row;
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
