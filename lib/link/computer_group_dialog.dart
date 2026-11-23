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

Future<String?> showMyComputers(
  BuildContext context, {
  required LinkHost? host,
  DesktopHostConnection? connection,
}) => trackManualComputerReview(
  host,
  () => showDialog<String>(
    animationStyle: AnimationStyle.noAnimation,
    context: context,
    builder: (context) => host == null || !host.supported
        ? AlertDialog(
            title: Text(context.l10n.myComputers),
            content: Text(context.l10n.myComputersUnavailable),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(context.l10n.commonClose),
              ),
            ],
          )
        : _GroupDialog(host: host, connection: connection),
  ),
);

class _GroupDialog extends StatefulWidget {
  const _GroupDialog({required this.host, this.connection});

  final LinkHost host;
  final DesktopHostConnection? connection;

  @override
  State<_GroupDialog> createState() => _GroupDialogState();
}

enum _Setup { create, invite, nearby }

class _GroupDialogState extends State<_GroupDialog> {
  final _input = TextEditingController();
  _Setup? _setup;
  bool _busy = false;
  bool _failed = false;
  bool _copied = false;
  bool _showInviteOptions = false;
  bool _browsing = false;
  bool _invitingNearby = false;
  (String, String)? _removing;
  ComputerGroupJoinPreview? _preview;

  LinkHost get _host => widget.host;
  DesktopHostConnection? get _connection => widget.connection;

  @override
  void dispose() {
    final preview = _preview;
    final host = _host;
    final connection = _connection;
    final browsing = _browsing;
    final inviting = _invitingNearby;
    if (preview != null || browsing || inviting) {
      // These notifiers can rebuild widgets outside the dialog.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (preview != null) host.cancelGroupJoin(preview);
        if (browsing) unawaited(connection?.stopDiscovery());
        if (inviting) host.cancelGroupInvite();
      });
    }
    _input.dispose();
    super.dispose();
  }

  Future<void> _run(FutureOr<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      await action();
    } on Object {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _prepare(
    Future<ComputerGroupJoinPreview> Function() prepare,
  ) async {
    if (!_host.groupConnectionsAvailable) await _host.enableGroupConnections();
    if (!mounted) return;
    final preview = await prepare();
    if (mounted) {
      _stopBrowse();
      setState(() => _preview = preview);
    } else {
      _host.cancelGroupJoin(preview);
    }
  }

  void _stopBrowse() {
    if (!_browsing) return;
    _browsing = false;
    unawaited(_connection?.stopDiscovery());
  }

  String _fingerprint(String id) => fingerprintOf(keyOfDeviceId(id)!);

  @override
  Widget build(BuildContext context) {
    final text = _Text(context);
    return ListenableBuilder(
      listenable: Listenable.merge([_host, _connection]),
      builder: (context, _) {
        final group = _host.computerGroup;
        final waiting = _host.confirmingGroupJoin;
        final request = _host.pendingGroupApproval;
        final removing = _removing?.$1 == group?.id
            ? group?.active[_removing?.$2]
            : null;
        final share = _host.groupConnectionsAvailable;
        final preview = _preview;
        final children = <Widget>[
          if (_host.computerGroupStorageError)
            Text(text.storage)
          else if (waiting != null) ...[
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
              primaryLabel: text.confirmJoin,
              onPrimary: _busy
                  ? null
                  : () {
                      setState(() {
                        _preview = null;
                        _setup = null;
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
                      });
                    },
            ),
          ] else if (group == null) ...[
            ..._setupWidgets(text),
          ] else if (!group.active.containsKey(_host.id)) ...[
            Text(text.youRemoved),
          ] else if (removing != null) ...[
            Text(text.removePrompt(removing.name)),
            Text(_fingerprint(removing.id)),
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
              onPressed: _busy || !share
                  ? null
                  : () => _run(() async {
                      if (_host.computerGroup?.id != group.id ||
                          !_host.permitsGroupWorkspace(removing.id)) {
                        return;
                      }
                      await _host.removeGroupMember(removing.id);
                      if (mounted) setState(() => _removing = null);
                    }),
              child: Text(text.confirmRemove),
            ),
            TextButton(
              onPressed: _busy ? null : () => setState(() => _removing = null),
              child: Text(context.l10n.commonCancel),
            ),
          ] else if (request != null) ...[
            ComputerApprovalPanel(
              host: _host,
              request: request,
              onApproved: () {
                if (!mounted) return;
                setState(() {
                  _invitingNearby = false;
                  _showInviteOptions = false;
                });
              },
            ),
          ] else ...[
            _roster(text, group),
            if (!share) ...[
              Text(text.paused),
              FilledButton(
                onPressed: _busy
                    ? null
                    : () => _run(_host.enableGroupConnections),
                child: Text(text.enable),
              ),
            ] else if (_showInviteOptions)
              ..._inviteWidgets(text),
            for (final id in group.removed)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(text.removed(group.known[id]!.name)),
                    Text(_fingerprint(id)),
                    Text(switch (_host.pendingGroupRemoval(id)) {
                      final pending when pending.isNotEmpty => text.pending(
                        pending.map((id) => group.known[id]!.name).join(', '),
                      ),
                      _ => text.delivered,
                    }),
                  ],
                ),
              ),
          ],
          if (_failed || (_host.groupJoinFailed && group == null))
            Semantics(liveRegion: true, child: Text(text.failed)),
        ];
        final roster =
            !_host.computerGroupStorageError &&
            group != null &&
            group.active.containsKey(_host.id) &&
            waiting == null &&
            preview == null &&
            removing == null &&
            request == null;
        final invite = roster && share && group.canAdmit && !_showInviteOptions;
        return Dialog(
          backgroundColor: AppColors.surface,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 20,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: AppColors.partBorder),
          ),
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 16, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          context.l10n.myComputers,
                          style: TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                      if (invite)
                        TextButton.icon(
                          icon: const Icon(Icons.add, size: 17),
                          label: Text(text.createInvite),
                          onPressed: _busy
                              ? null
                              : () => setState(() => _showInviteOptions = true),
                        ),
                    ],
                  ),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final child in children)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: child,
                          ),
                      ],
                    ),
                  ),
                ),
                Divider(height: 1, color: AppColors.partBorder),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  child: Row(
                    children: [
                      if (roster && share)
                        PopupMenuButton<String>(
                          tooltip: text.settings,
                          onSelected: (value) {
                            if (value == 'access') {
                              _info(text.access, Text(text.scope));
                            } else if (value == 'sync') {
                              unawaited(_run(_host.syncComputerGroup));
                            } else if (value == 'pause') {
                              unawaited(_run(_host.pauseGroupConnections));
                            }
                          },
                          itemBuilder: (_) => [
                            PopupMenuItem(
                              value: 'access',
                              child: Text(text.access),
                            ),
                            if (group.removed.isNotEmpty)
                              PopupMenuItem(
                                value: 'sync',
                                enabled: !_busy,
                                child: Text(text.sync),
                              ),
                            PopupMenuItem(
                              value: 'pause',
                              enabled: !_busy,
                              child: Text(text.pause),
                            ),
                          ],
                          child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.tune,
                                  size: 16,
                                  color: AppColors.textMuted,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  text.settings,
                                  style: TextStyle(color: AppColors.textMuted),
                                ),
                                Icon(
                                  Icons.arrow_drop_down,
                                  size: 16,
                                  color: AppColors.textMuted,
                                ),
                              ],
                            ),
                          ),
                        ),
                      const Spacer(),
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: Text(
                          waiting == null
                              ? context.l10n.commonClose
                              : text.keepWaiting,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

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
        decoration: InputDecoration(labelText: text.invite),
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
      if (_connection!.discoveryError != null)
        Text(text.findFailed)
      else if (_connection!.nearbyGroupHosts.isEmpty)
        Text(text.searching)
      else
        for (final advert in _connection!.nearbyGroupHosts)
          OutlinedButton.icon(
            icon: const Icon(Icons.computer),
            label: Text(advert.name),
            onPressed: _busy
                ? null
                : () => _run(
                    () => _prepare(
                      () => _connection!.prepareNearbyGroup(advert.id),
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
          if (_connection?.discoverySupported == true)
            OutlinedButton.icon(
              icon: const Icon(Icons.radar),
              onPressed: _busy
                  ? null
                  : () {
                      setState(() {
                        _setup = _Setup.nearby;
                        _browsing = true;
                        _failed = false;
                      });
                      _connection!.startDiscovery();
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
                    if (mounted) setState(() => _copied = true);
                  }),
            child: Text(_copied ? text.copied : text.copy),
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.radar),
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

  Widget _roster(_Text text, ComputerGroup group) {
    final members = [
      group.active[_host.id]!,
      ...group.active.values.where((m) => m.id != _host.id),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          text.members(members.length),
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: AppColors.textMuted,
          ),
        ),
        const SizedBox(height: 8),
        DecoratedBox(
          decoration: BoxDecoration(
            color: AppColors.code,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.partBorder),
          ),
          child: Column(
            children: [
              for (final member in members) ...[
                if (member != members.first)
                  Divider(
                    indent: 12,
                    endIndent: 12,
                    height: 1,
                    color: AppColors.partBorder,
                  ),
                _member(text, group, member),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _member(_Text text, ComputerGroup group, ComputerGroupMember member) {
    final here = member.id == _host.id;
    final canUse = !_busy && _host.permitsGroupWorkspace(member.id);
    final connection = _connection;
    final selected = connection?.selectedHostId == member.id;
    final status = switch (connection) {
      _
          when _host.groupWorkspaceConnected(member.id) ||
              connection?.peer?.remote == member.id =>
        text.connected,
      final current? when selected && current.busy => text.connecting,
      final current?
          when selected &&
              current.error != null &&
              _host.permitsGroupWorkspace(member.id) =>
        text.unreachable,
      _ => text.statusUnknown,
    };
    final menu = PopupMenuButton<String>(
      key: ValueKey(('computer-menu', member.id)),
      tooltip: text.options(member.name),
      icon: Icon(Icons.more_horiz, color: AppColors.textMuted, size: 18),
      onSelected: (value) {
        if (value == 'details') {
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
        } else if (canUse && !here) {
          setState(() => _removing = (group.id, member.id));
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(value: 'details', child: Text(text.details)),
        if (!here)
          PopupMenuItem(
            value: 'remove',
            enabled: canUse,
            child: Text(
              text.remove(member.name),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    );
    final action = here || connection == null
        ? null
        : FilledButton(
            key: ValueKey(('open-computer', member.id)),
            style: FilledButton.styleFrom(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(6),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
            onPressed: canUse && !connection.busy
                ? () => Navigator.pop(context, member.id)
                : null,
            child: Text(text.open),
          );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final stacked =
              constraints.maxWidth < 340 ||
              MediaQuery.textScalerOf(context).scale(14) > 19;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    here
                        ? Icons.desktop_windows_outlined
                        : Icons.devices_outlined,
                    size: 23,
                    color: AppColors.textMuted,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Tooltip(
                          message: member.name,
                          child: Text(
                            member.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppColors.textPrimary,
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          here ? text.local : status,
                          style: TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (action != null && !stacked) ...[
                    const SizedBox(width: 8),
                    action,
                  ],
                  menu,
                ],
              ),
              if (action != null && stacked)
                Padding(
                  padding: const EdgeInsets.only(left: 35, top: 6),
                  child: action,
                ),
            ],
          );
        },
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
      ? '请在另一台电脑上选择「查找电脑」。关闭此窗口将停止附近邀请。'
      : 'Choose Find computer on the other computer. Closing this window stops the nearby invite.';
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
  String get keepWaiting => zh ? '关闭窗口并继续等待' : 'Close and keep waiting';
  String get confirmRemove => zh ? '从组中移除' : 'Remove from group';
  String get youRemoved => zh
      ? '这台电脑已被移出组。本机已关闭组访问。'
      : 'This computer was removed from the group. Group access is disabled here.';
  String get connected => zh ? '工作区已连接' : 'Workspace connected';
  String get connecting => zh ? '正在连接…' : 'Connecting…';
  String get unreachable =>
      zh ? '工作区连接不可用' : 'Workspace connection unavailable';
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
  String get open => zh ? '打开工作区' : 'Open workspace';
  String remove(String name) => zh ? '移除 $name' : 'Remove $name';
  String removed(String name) => zh ? '已移除 $name' : 'Removed $name';
  String get local => zh ? '本机' : 'This computer';
  String get settings => zh ? '连接设置' : 'Connection settings';
  String get details => zh ? '设备详情' : 'Device details';
  String get fingerprint => zh ? '设备指纹' : 'Device fingerprint';
  String members(int n) => zh ? '受信任的电脑 · $n' : 'Trusted computers · $n';
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
