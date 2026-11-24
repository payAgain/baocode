import 'package:bao_link/bao_link.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'link_host.dart';

bool _zh(BuildContext context) =>
    Localizations.localeOf(context).languageCode == 'zh';
String admissionScope(bool zh) => zh
    ? '当前和未来的成员可以互相操作 BaoCode 工作区，包括运行智能体、处理审批、读取 BaoCode 可访问的项目外文件。每位成员都可以批准加入或从整个组移除其他成员。请仅与完全信任的电脑共享。'
    : 'Current and future members can operate one another’s BaoCode workspaces. They can run agents, answer approvals and read files BaoCode can access outside projects. Any member can approve new members or remove another computer from the whole group. Share only with computers you fully trust.';

class ComputerGroupAdmissionReview extends StatelessWidget {
  const ComputerGroupAdmissionReview({
    super.key,
    required this.title,
    required this.fingerprint,
    required this.code,
    required this.primaryLabel,
    required this.onPrimary,
    required this.secondaryLabel,
    required this.onSecondary,
    this.compact = false,
  });
  final String title, fingerprint, code, primaryLabel, secondaryLabel;
  final VoidCallback? onPrimary, onSecondary;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final zh = _zh(context);
    final label = TextStyle(
      fontSize: 12,
      color: AppColors.textMuted,
      fontWeight: FontWeight.w600,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.devices_outlined, size: 23, color: AppColors.textMuted),
            SizedBox(width: compact ? 8 : 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(zh ? '核对设备' : 'Verify this computer', style: label),
                  const SizedBox(height: 4),
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: compact ? 15 : 17,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  SelectableText(
                    fingerprint,
                    style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                  ),
                ],
              ),
            ),
          ],
        ),
        SizedBox(height: compact ? 10 : 16),
        _Code(code: code, compact: compact),
        SizedBox(height: compact ? 10 : 16),
        Text(zh ? '工作区权限' : 'Workspace access', style: label),
        const SizedBox(height: 4),
        Text(
          admissionScope(zh),
          style: TextStyle(color: AppColors.text, height: 1.4, fontSize: 13),
        ),
        SizedBox(height: compact ? 10 : 16),
        Wrap(
          alignment: compact ? WrapAlignment.start : WrapAlignment.end,
          spacing: 8,
          runSpacing: 4,
          children: [
            TextButton(onPressed: onSecondary, child: Text(secondaryLabel)),
            FilledButton(onPressed: onPrimary, child: Text(primaryLabel)),
          ],
        ),
      ],
    );
  }
}

class _Code extends StatelessWidget {
  const _Code({required this.code, this.compact = false});
  final bool compact;
  final String code;
  @override
  Widget build(BuildContext context) {
    final zh = _zh(context);
    return Container(
      padding: EdgeInsets.all(compact ? 8 : 14),
      decoration: BoxDecoration(
        color: AppColors.code,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.partBorder),
      ),
      child: Column(
        children: [
          Text(
            zh ? '两台电脑的校验码' : 'Compare security code',
            style: TextStyle(color: AppColors.textMuted, fontSize: 12),
          ),
          const SizedBox(height: 4),
          SelectableText(
            code,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFeatures: const [FontFeature.tabularFigures()],
              fontSize: 22,
              fontWeight: FontWeight.w600,
              letterSpacing: 2,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            zh
                ? '只有两边显示的校验码一致时才同意。'
                : 'Continue only if both computers show this code.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}

class ComputerAdmissionWaiting extends StatelessWidget {
  const ComputerAdmissionWaiting({
    super.key,
    required this.title,
    required this.code,
  });
  final String title, code;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Icon(Icons.hourglass_empty, color: AppColors.textMuted, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
                fontSize: 17,
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 6),
      Text(
        _zh(context)
            ? '申请已发送。你可以离开此处继续等待。'
            : 'Request sent. You can leave this view while you wait.',
        style: TextStyle(color: AppColors.textMuted),
      ),
      const SizedBox(height: 12),
      _Code(code: code),
    ],
  );
}

class ComputerApprovalPanel extends StatefulWidget {
  const ComputerApprovalPanel({
    super.key,
    required this.host,
    required this.request,
    this.onApproved,
    this.compact = false,
  });
  final LinkHost host;
  final ComputerGroupApproval request;
  final VoidCallback? onApproved;
  final bool compact;
  @override
  State<ComputerApprovalPanel> createState() => _ComputerApprovalPanelState();
}

class _ComputerApprovalPanelState extends State<ComputerApprovalPanel> {
  bool _busy = false;
  bool _error = false;
  @override
  void didUpdateWidget(ComputerApprovalPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.request, oldWidget.request)) {
      _error = false;
      _busy = false;
    }
  }

  Future<void> _approve(LinkHost host, ComputerGroupApproval request) async {
    if (_busy || !identical(host.pendingGroupApproval, request)) return;
    final onApproved = widget.onApproved;
    setState(() {
      _busy = true;
      _error = false;
    });
    try {
      await host.approveGroupJoin(request);
      if (host.computerGroup?.active.containsKey(request.member.id) == true) {
        onApproved?.call();
      }
    } on Object {
      if (mounted && identical(widget.request, request)) {
        setState(() => _error = true);
      }
    } finally {
      if (mounted && identical(widget.request, request)) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final zh = _zh(context);
    final host = widget.host, request = widget.request;
    final name = request.member.name;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ComputerGroupAdmissionReview(
          compact: widget.compact,
          title: zh ? '$name 申请加入「我的电脑」' : '$name requests to join the group',
          fingerprint: fingerprintOf(keyOfDeviceId(request.member.id)!),
          code: request.code,
          primaryLabel: zh ? '同意加入' : 'Approve group member',
          onPrimary: _busy ? null : () => _approve(host, request),
          secondaryLabel: zh ? '拒绝' : 'Decline group member',
          onSecondary: _busy ? null : () => host.denyGroupJoin(request),
        ),
        if (_error)
          Semantics(
            liveRegion: true,
            child: Text(
              zh
                  ? '未能批准，请检查连接后重试。'
                  : 'Approval failed. Check the connection and try again.',
            ),
          ),
      ],
    );
  }
}
