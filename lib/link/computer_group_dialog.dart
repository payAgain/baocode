import 'dart:async';

import 'package:bao_link/bao_link.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'computer_group.dart';
import 'link_host.dart';

class ComputerGroupButton extends StatelessWidget {
  const ComputerGroupButton({
    super.key,
    required this.host,
    this.open,
    this.compact = false,
  });

  final LinkHost host;
  final ValueChanged<String>? open;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final text = _Text(context);
    final label = open != null ? text.title : text.settings;
    void show() => unawaited(
      showDialog<void>(
        animationStyle: AnimationStyle.noAnimation,
        context: context,
        builder: (_) => _GroupDialog(host: host, open: open),
      ),
    );
    if (compact) {
      return IconButton(
        tooltip: label,
        onPressed: show,
        icon: const Icon(Icons.devices, size: 17),
      );
    }
    return TextButton.icon(
      onPressed: show,
      icon: const Icon(Icons.devices, size: 17),
      label: Text(label),
    );
  }
}

class _GroupDialog extends StatefulWidget {
  const _GroupDialog({required this.host, required this.open});
  final LinkHost host;
  final ValueChanged<String>? open;

  @override
  State<_GroupDialog> createState() => _GroupDialogState();
}

class _GroupDialogState extends State<_GroupDialog> {
  final _input = TextEditingController();
  bool _creating = false;
  bool _busy = false;
  bool _failed = false;
  bool _copied = false;
  String? _invite;
  String? _removing;
  ComputerGroupJoinPreview? _preview;

  LinkHost get _host => widget.host;

  @override
  void dispose() {
    if (_preview case final preview?) _host.cancelGroupJoin(preview);
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

  String _fingerprint(String id) => fingerprintOf(keyOfDeviceId(id)!);

  @override
  Widget build(BuildContext context) {
    final text = _Text(context);
    return ListenableBuilder(
      listenable: _host,
      builder: (context, _) {
        final group = _host.computerGroup;
        final waiting = _host.confirmingGroupJoin;
        final request = _host.pendingGroupApproval;
        final removing = group?.active[_removing];
        final memberHere = group?.active.containsKey(_host.id) == true;
        final share = _host.groupConnectionsAvailable;
        final preview = _preview;
        final openMember = widget.open;
        final children = <Widget>[
          if (_host.computerGroupStorageError)
            Text(text.storage)
          else if (!share) ...[
            Text(text.listener),
            FilledButton(
              onPressed: _busy
                  ? null
                  : () => _run(_host.enableGroupConnections),
              child: Text(text.enable),
            ),
          ] else if (waiting != null) ...[
            Text(text.waiting(waiting.sponsor.name)),
            Text(waiting.code),
            TextButton(
              onPressed: () => _host.cancelGroupJoin(waiting),
              child: Text(text.cancelJoin),
            ),
          ] else if (preview != null) ...[
            Text(text.joinVia(preview.sponsor.name)),
            Text(_fingerprint(preview.group.id)),
            Text(text.compare),
            Text(preview.code),
            Text(text.scope),
            FilledButton(
              onPressed: _busy
                  ? null
                  : () {
                      setState(() => _preview = null);
                      unawaited(_run(() => _host.confirmGroupJoin(preview)));
                    },
              child: Text(text.confirmJoin),
            ),
            TextButton(
              onPressed: _busy
                  ? null
                  : () {
                      _host.cancelGroupJoin(preview);
                      setState(() => _preview = null);
                    },
              child: Text(text.cancelJoin),
            ),
          ] else if (group == null && _creating) ...[
            Text(text.scope),
            FilledButton(
              onPressed: _busy ? null : () => _run(_host.createComputerGroup),
              child: Text(text.confirmCreate),
            ),
          ] else if (group == null) ...[
            OutlinedButton(
              onPressed: _busy ? null : () => setState(() => _creating = true),
              child: Text(text.create),
            ),
            TextField(
              key: const ValueKey('computer-group-invite'),
              controller: _input,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(labelText: text.invite),
            ),
            FilledButton(
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                      final reviewed = await _host.prepareGroupJoin(
                        _input.text,
                      );
                      if (mounted) {
                        setState(() => _preview = reviewed);
                      } else {
                        _host.cancelGroupJoin(reviewed);
                      }
                    }),
              child: Text(text.review),
            ),
          ] else if (!memberHere) ...[
            Text(text.youRemoved),
          ] else if (removing != null) ...[
            Text(text.removePrompt(removing.name)),
            Text(_fingerprint(removing.id)),
            FilledButton(
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                      await _host.removeGroupMember(removing.id);
                      if (mounted) setState(() => _removing = null);
                    }),
              child: Text(text.confirmRemove),
            ),
            TextButton(
              onPressed: _busy ? null : () => setState(() => _removing = null),
              child: Text(text.cancel),
            ),
          ] else if (request != null) ...[
            Text(text.approving(request.member.name)),
            Text(_fingerprint(request.member.id)),
            Text(text.compare),
            Text(request.code),
            Text(text.scope),
            FilledButton(
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                      await _host.approveGroupJoin(request);
                      if (mounted) setState(() => _invite = null);
                    }),
              child: Text(text.approve),
            ),
            TextButton(
              onPressed: _busy ? null : () => _host.denyGroupJoin(request),
              child: Text(text.decline),
            ),
          ] else ...[
            Text(text.groupKey),
            Text(_fingerprint(group.id)),
            Text(text.scope),
            if (group.canAdmit)
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _run(() {
                        final invite = _host.createGroupInvite();
                        setState(() {
                          _invite = invite;
                          _copied = false;
                        });
                      }),
                child: Text(text.createInvite),
              ),
            if (_invite case final invite?) ...[
              Text(text.share),
              TextButton(
                onPressed: _busy
                    ? null
                    : () => _run(() async {
                        await Clipboard.setData(ClipboardData(text: invite));
                        if (mounted) setState(() => _copied = true);
                      }),
                child: Text(_copied ? text.copied : text.copy),
              ),
            ],
            for (final member in group.active.values)
              _member(text, member, openMember),
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
            TextButton(
              onPressed: _busy ? null : () => _run(_host.syncComputerGroup),
              child: Text(text.sync),
            ),
            TextButton(
              onPressed: _busy ? null : () => _run(_host.pauseGroupConnections),
              child: Text(text.pause),
            ),
          ],
          if (_failed || (_host.groupJoinFailed && group == null))
            Semantics(liveRegion: true, child: Text(text.failed)),
        ];
        return Dialog(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    header: true,
                    child: Text(
                      text.title,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Flexible(
                    child: SingleChildScrollView(
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
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(
                        waiting == null ? text.close : text.keepWaiting,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _member(
    _Text text,
    ComputerGroupMember member,
    ValueChanged<String>? open,
  ) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          member.id == _host.id ? text.thisComputer(member.name) : member.name,
        ),
        Text(_fingerprint(member.id)),
        if (member.id != _host.id) ...[
          Text(
            _host.groupWorkspaceConnected(member.id)
                ? text.connected
                : text.statusUnknown,
          ),
          Wrap(
            children: [
              if (open != null)
                TextButton(
                  onPressed: _busy || !_host.permitsGroupWorkspace(member.id)
                      ? null
                      : () {
                          Navigator.pop(context);
                          open(member.id);
                        },
                  child: Text(text.open(member.name)),
                ),
              TextButton(
                onPressed: _busy || !_host.permitsGroupWorkspace(member.id)
                    ? null
                    : () => setState(() => _removing = member.id),
                child: Text(text.remove(member.name)),
              ),
            ],
          ),
        ],
      ],
    ),
  );
}

class _Text {
  _Text(BuildContext context)
    : zh = Localizations.localeOf(context).languageCode == 'zh';
  final bool zh;
  String get title => zh ? '电脑信任组' : 'Computer group';
  String get settings => zh ? '电脑信任组设置' : 'Computer group settings';
  String get scope => zh
      ? '当前和未来的成员可以互相操作 BaoCode 工作区，包括运行智能体、处理审批、读取 BaoCode 可访问的项目外文件。每位成员都可以批准加入或从整个组移除其他成员。请仅与完全信任的电脑共享。'
      : 'Current and future members can operate one another’s BaoCode workspaces. They can run agents, answer approvals and read files BaoCode can access outside projects. Any member can approve new members or remove another computer from the whole group. Share only with computers you fully trust.';
  String get listener => zh
      ? '先启用电脑组连接。此操作不会启用手机或已有的一对一配对，也不会共享工作区，直到你确认创建或加入组。'
      : 'Enable computer group connections first. This does not enable phones, existing one-to-one pairings or workspace access before you confirm creating or joining a group.';
  String get enable => zh ? '启用电脑组连接' : 'Enable computer group connections';
  String get storage => zh
      ? '无法验证已保存的信任组。组访问已停用。'
      : 'Could not verify saved group history. Group access is disabled.';
  String get groupKey => zh ? '组指纹' : 'Group fingerprint';
  String get create => zh ? '创建电脑信任组' : 'Create computer group';
  String get confirmCreate => zh ? '创建并信任组成员' : 'Create and trust group';
  String get createInvite => zh ? '创建组邀请' : 'Create group invite';
  String get invite => zh ? '电脑信任组邀请' : 'Computer group invite';
  String get review => zh ? '查看组邀请' : 'Review group invite';
  String get compare => zh
      ? '请核对两台电脑上的校验码。只有一致时才继续。'
      : 'Compare this code on both computers. Continue only if the codes match.';
  String get share => zh
      ? '仅将此一次性邀请发给要加入的电脑。邀请会过期。'
      : 'Share this short-lived, one-time invite only with the joining computer.';
  String get copy => zh ? '复制邀请' : 'Copy invite';
  String get copied => zh ? '已复制邀请' : 'Invite copied';
  String get confirmJoin => zh ? '加入并共享工作区' : 'Join and share workspace';
  String get cancelJoin => zh ? '取消加入' : 'Cancel join';
  String get approve => zh ? '批准加入组' : 'Approve group member';
  String get decline => zh ? '拒绝加入' : 'Decline group member';
  String get keepWaiting => zh ? '关闭窗口并继续等待' : 'Close and keep waiting';
  String get close => zh ? '关闭' : 'Close';
  String get cancel => zh ? '取消' : 'Cancel';
  String get confirmRemove => zh ? '从组中移除' : 'Remove from group';
  String get youRemoved => zh
      ? '这台电脑已被移出组。本机已关闭组访问。'
      : 'This computer was removed from the group. Group access is disabled here.';
  String get connected => zh ? '工作区已连接' : 'Workspace connected';
  String get statusUnknown =>
      zh ? '没有工作区连接，在线状态未知' : 'No workspace connection. Online status unknown.';
  String get sync => zh ? '同步成员变更' : 'Sync membership changes';
  String get pause =>
      zh ? '暂停本机的电脑组连接' : 'Pause group connections on this computer';
  String get failed => zh
      ? '无法完成组操作。请检查邀请、网络及两台电脑的组状态。'
      : 'The group action could not be completed. Check the invite, connection and group status on both computers.';
  String get delivered =>
      zh ? '已收到已知相关电脑的确认。' : 'Acknowledged by the known affected computers.';
  String open(String name) => zh ? '打开 $name' : 'Open $name';
  String remove(String name) => zh ? '移除 $name' : 'Remove $name';
  String removed(String name) => zh ? '已移除 $name' : 'Removed $name';
  String thisComputer(String name) =>
      zh ? '$name（本机）' : '$name (this computer)';
  String joinVia(String name) =>
      zh ? '通过 $name 加入组' : 'Join the group through $name';
  String waiting(String name) =>
      zh ? '等待 $name 批准' : 'Waiting for $name to approve';
  String approving(String name) =>
      zh ? '$name 请求加入组' : '$name requests to join the group';
  String pending(String names) => zh
      ? '尚未收到确认（电脑可能离线）：$names'
      : 'Awaiting acknowledgment from $names. These computers may be offline.';
  String removePrompt(String name) => zh
      ? '从整个组中移除 $name？本机立即结束访问，其他电脑在收到变更后才会终止访问。此操作无法撤销。'
      : 'Remove $name from the whole group? Access ends on this computer immediately. Other computers enforce the removal when they receive it. This cannot be undone.';
}
