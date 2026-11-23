import 'dart:async';
import 'dart:convert';

import 'package:bao_link/bao_link.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../chat/chat_models.dart';
import '../chat/panels/interaction_panel.dart';
import '../chat/widgets/agent_step.dart' show AgentStep;
import '../kernel/kernel_types.dart';
import '../l10n/l10n.dart';
import 'chat_codec.dart';
import 'desktop_host_chats.dart';
import 'desktop_remote_session_actions_snapshot.dart';
import 'interaction_codec.dart';

part 'desktop_remote_session_actions_edit.dart';
part 'desktop_remote_session_inspection.dart';

/// Host-owned actions for the selected paired project conversation.
class DesktopRemoteSessionActions extends StatefulWidget {
  const DesktopRemoteSessionActions({
    super.key,
    required this.peer,
    required this.chat,
    required this.chats,
    this.enabled = true,
  });

  final LinkPeer? peer;
  final DesktopHostChat chat;
  final DesktopHostChats chats;
  final bool enabled;

  @override
  State<DesktopRemoteSessionActions> createState() =>
      _DesktopRemoteSessionActionsState();
}

class _DesktopRemoteSessionActionsState
    extends State<DesktopRemoteSessionActions> {
  Object? _follow;
  Object? _operation;
  String? _answered;
  String? _started;
  List<Object?>? _editedItems;
  String? _failure;
  bool _queueAccepted = false;
  final _unsupported = <String>{};

  DesktopRemoteSessionSnapshot? get _snapshot =>
      widget.chats.remoteActionSnapshot(widget.peer, widget.chat);

  bool _current(DesktopRemoteSessionSnapshot old) =>
      mounted && identical(_snapshot?.follow, old.follow);

  bool _available(DesktopRemoteSessionSnapshot old) =>
      _current(old) && widget.enabled && _snapshot?.busy == false;

  String? _interactionKey(DesktopRemoteSessionSnapshot? snapshot) {
    final raw = snapshot?.state['interaction'];
    return raw != null ? jsonEncode(raw) : null;
  }

  Future<void> _run(
    DesktopRemoteSessionSnapshot snapshot,
    String method,
    bool Function() valid,
    Future<void> Function(LinkPeer, String) action,
  ) async {
    final peer = widget.peer;
    final session = widget.chat.id;
    if (peer == null ||
        !_available(snapshot) ||
        _operation != null ||
        !valid()) {
      return;
    }
    final operation = Object();
    setState(() {
      _operation = operation;
      _failure = null;
      _queueAccepted = false;
    });
    try {
      await action(peer, session);
    } on LinkRemoteException catch (error) {
      if (!_current(snapshot) || !valid()) return;
      final unavailable =
          error.code == LinkErrors.unknown ||
          error.code == LinkErrors.unsupported;
      if (unavailable) _unsupported.add(method);
      _failure = unavailable ? 'unsupported' : 'rejected';
    } on Object {
      if (_current(snapshot) && valid()) _failure = 'uncertain';
    } finally {
      if (mounted && identical(_operation, operation)) {
        setState(() => _operation = null);
      }
    }
  }

  void _reviewRequest(
    DesktopRemoteSessionSnapshot snapshot,
    InteractionRequest request,
    String revision,
  ) {
    bool valid() => _interactionKey(_snapshot) == revision;
    unawaited(
      _run(snapshot, LinkMethods.answer, valid, (peer, id) async {
        final answer = await _ask<InteractionAnswer>(
          snapshot,
          valid,
          (context) => switch (request) {
            QuestionRequest() => _QuestionDialog(request: request),
            ApprovalRequest() => _ApprovalDialog(request: request),
          },
        );
        if (answer == null || !_available(snapshot) || !valid()) return;
        final payload = switch (answer) {
          QuestionAnswer(:final picks, :final skipped) => <String, Object?>{
            't': 'question',
            if (skipped) 'skipped': true else 'picks': picks,
          },
          ApprovalAnswer(:final decision, :final message)
              when decision != ApprovalDecision.allowAlways =>
            <String, Object?>{
              't': 'approval',
              'decision': decision.name,
              'message': ?message,
            },
          _ => null,
        };
        if (payload == null || InteractionCodec.decodeAnswer(payload) == null) {
          return;
        }
        await peer.call(LinkMethods.answer, {
          'session': id,
          'request': request.id,
          'answer': payload,
        });
        if (_current(snapshot) && valid()) _answered = revision;
      }),
    );
  }

  void _startPlan(DesktopRemoteSessionSnapshot snapshot, _PendingPlan plan) {
    bool valid() => _waitingPlan(_snapshot)?.revision == plan.revision;
    unawaited(
      _run(snapshot, LinkMethods.startPlan, valid, (peer, id) async {
        final confirm = await _ask<bool>(
          snapshot,
          valid,
          (context) => AlertDialog(
            title: Text(_text(context, 'Start host plan?', '开始执行主机计划？')),
            content: SizedBox(
              width: 480,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (plan.item.title case final title?) Text(title),
                    if (plan.item.text case final text?) SelectableText(text),
                    Text(
                      _text(
                        context,
                        'This leaves Plan mode and runs the displayed plan on the host using its current permissions.',
                        '这将在主机上退出计划模式，并按当前权限执行此计划。',
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              _cancel(context),
              OutlinedButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(_text(context, 'Start plan', '执行计划')),
              ),
            ],
          ),
        );
        if (confirm != true || !_available(snapshot) || !valid()) return;
        await peer.call(LinkMethods.startPlan, {
          'session': id,
          'expectedPlan': plan.revision,
        });
        if (_current(snapshot) && valid()) _started = plan.revision;
      }),
    );
  }

  void _refreshQuota(DesktopRemoteSessionSnapshot snapshot) {
    bool valid() => _snapshot?.state['quota'] is Map;
    unawaited(
      _run(snapshot, LinkMethods.quota, valid, (peer, id) async {
        await peer.call(LinkMethods.quota, {'session': id});
      }),
    );
  }

  void _deliver(DesktopRemoteSessionSnapshot snapshot, {required bool now}) {
    final turn = _action(snapshot, 'turn');
    bool valid() =>
        _canDeliver(_snapshot) && (!now || _action(_snapshot, 'turn') == turn);
    unawaited(
      _run(snapshot, LinkMethods.send, valid, (peer, id) async {
        final message = await _ask<String>(
          snapshot,
          valid,
          (context) => _MessageDialog(
            initial: '',
            title: now
                ? _text(context, 'Send now', '立即发送')
                : _text(context, 'Queue message', '消息排队'),
            submit: now
                ? _text(context, 'Review interrupt', '查看中断操作')
                : _text(context, 'Add to queue', '加入队列'),
          ),
        );
        if (message == null || !_available(snapshot) || !valid()) return;
        if (now) {
          final confirmed = await _ask<bool>(
            snapshot,
            valid,
            (context) => AlertDialog(
              title: Text(_text(context, 'Interrupt host turn?', '中断主机当前任务？')),
              content: Text(
                _text(
                  context,
                  'The host will stop the current turn and send your message immediately.',
                  '主机将停止当前轮次并立即发送你的消息。',
                ),
              ),
              actions: [
                _cancel(context),
                OutlinedButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(_text(context, 'Interrupt and send', '中断并发送')),
                ),
              ],
            ),
          );
          if (confirmed != true || !_available(snapshot) || !valid()) return;
        }
        final result = await peer.call(LinkMethods.send, {
          'session': id,
          'id': base64Url.encode(randomBytes(16)),
          'text': message,
          'now': now,
          'duringTurn': true,
          if (now) 'expectedTurn': ?turn,
        });
        if (result is! Map || result['session'] != id) {
          throw const FormatException('The host did not confirm this session');
        }
        if (!now && _current(snapshot)) _queueAccepted = true;
      }),
    );
  }

  void _edit(
    DesktopRemoteSessionSnapshot snapshot,
    List<_EditTarget> messages,
  ) {
    bool valid() {
      final current = _snapshot;
      return _canEdit(current) && listEquals(current!.items, snapshot.items);
    }

    unawaited(
      _run(snapshot, LinkMethods.edit, valid, (peer, id) async {
        final target = await _ask<_EditTarget>(
          snapshot,
          valid,
          (context) => AlertDialog(
            title: Text(_text(context, 'Edit old message', '编辑旧消息')),
            content: SizedBox(
              width: 480,
              height: 260,
              child: ListView.builder(
                itemCount: messages.length,
                itemBuilder: (context, index) {
                  final message = messages[index];
                  return ListTile(
                    title: Text(
                      message.text,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => Navigator.pop(context, message),
                  );
                },
              ),
            ),
            actions: [_cancel(context)],
          ),
        );
        if (target == null || !_available(snapshot) || !valid()) return;
        final text = await _ask<String>(
          snapshot,
          valid,
          (context) => _MessageDialog(
            initial: target.text,
            title: _text(context, 'Edit old message', '编辑旧消息'),
            submit: _text(context, 'Review edit', '查看编辑影响'),
          ),
        );
        if (text == null || !_available(snapshot) || !valid()) return;
        final params = {
          'session': id,
          'index': target.index,
          'expectedWindow': linkDigest(snapshot.items),
        };
        Object? review;
        try {
          review = await peer.call(LinkMethods.rewindPlan, params);
        } on LinkRemoteException catch (error) {
          // Older hosts can edit the conversation but cannot preview files.
          if (error.code != LinkErrors.unknown) rethrow;
        }
        if (!_available(snapshot) || !valid()) return;
        final restore = await _ask<bool>(
          snapshot,
          valid,
          (context) => _RewindDialog(review: review),
        );
        if (restore == null || !_available(snapshot) || !valid()) return;
        await peer.call(LinkMethods.edit, {
          ...params,
          'text': text,
          'revertFiles': restore,
        });
        if (_current(snapshot) && valid()) _editedItems = snapshot.items;
      }),
    );
  }

  /// Recheck the live model in the route as well as immediately after it
  /// returns. The dialog can outlive this widget or the session it opened on.
  Future<T?> _ask<T>(
    DesktopRemoteSessionSnapshot snapshot,
    bool Function() valid,
    WidgetBuilder builder,
  ) {
    final chats = widget.chats;
    return showDialog<T>(
      context: context,
      builder: (context) {
        return ListenableBuilder(
          listenable: chats,
          builder: (context, _) =>
              _current(snapshot) && valid() ? builder(context) : _StaleDialog(),
        );
      },
    );
  }

  void _inspect(
    DesktopRemoteSessionSnapshot snapshot,
    String Function(BuildContext) title,
    Widget? Function(BuildContext, DesktopRemoteSessionSnapshot) details,
  ) {
    if (!_current(snapshot)) return;
    final chats = widget.chats;
    final follow = snapshot.follow;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title(context)),
        content: SizedBox(
          width: 440,
          child: ListenableBuilder(
            listenable: chats,
            builder: (context, _) {
              final current = mounted ? _snapshot : null;
              final body = current != null && identical(current.follow, follow)
                  ? details(context, current)
                  : null;
              return SingleChildScrollView(
                child:
                    body ??
                    Text(
                      _text(
                        context,
                        'No details available for this conversation.',
                        '此对话没有可用的详情。',
                      ),
                    ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(MaterialLocalizations.of(context).closeButtonLabel),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.chats,
    builder: (context, _) {
      final snapshot = _snapshot;
      if (!identical(_follow, snapshot?.follow)) {
        _follow = snapshot?.follow;
        _operation = null;
        _answered = null;
        _started = null;
        _editedItems = null;
        _failure = null;
        _queueAccepted = false;
        _unsupported.clear();
      }
      if (snapshot == null) return const SizedBox.shrink();
      final raw = snapshot.state['interaction'];
      final request = decodeRemoteInteraction(raw);
      final revision = _interactionKey(snapshot);
      if (_answered != revision) _answered = null;
      final plan = _waitingPlan(snapshot);
      if (_started != plan?.revision) _started = null;
      final quota = snapshot.state['quota'];
      final delivery =
          _canDeliver(snapshot) && !_unsupported.contains(LinkMethods.send);
      if (!listEquals(_editedItems, snapshot.items)) _editedItems = null;
      final messages =
          _canEdit(snapshot) && !_unsupported.contains(LinkMethods.edit)
          ? _editTargets(snapshot)
          : const <_EditTarget>[];
      final ready = widget.enabled && !snapshot.busy && _operation == null;
      final children = <Widget>[
        if (request != null &&
            revision != null &&
            !_unsupported.contains(LinkMethods.answer))
          TextButton.icon(
            onPressed: ready && _answered != revision
                ? () => _reviewRequest(snapshot, request, revision)
                : null,
            icon: const Icon(Icons.question_answer_outlined, size: 16),
            label: Text(_text(context, 'Review host request', '查看主机请求')),
          ),
        if (plan != null && !_unsupported.contains(LinkMethods.startPlan))
          TextButton.icon(
            onPressed: ready && _started != plan.revision
                ? () => _startPlan(snapshot, plan)
                : null,
            icon: const Icon(Icons.play_arrow_outlined, size: 16),
            label: Text(_text(context, 'Start host plan', '执行主机计划')),
          ),
        if (_goalCondition(snapshot) != null)
          TextButton.icon(
            onPressed: () => _inspect(
              snapshot,
              (context) => _text(context, 'Goal details', '目标详情'),
              _goalDetails,
            ),
            icon: const Icon(Icons.flag_outlined, size: 16),
            label: Text(_text(context, 'Host goal', '主机目标')),
          ),
        if (quota is Map<String, Object?>) ...[
          if (_quotaSummary(context, quota) case final summary?) Text(summary),
          TextButton.icon(
            onPressed: () => _inspect(
              snapshot,
              (context) => _text(context, 'Account quota', '账户用量'),
              _quotaDetails,
            ),
            icon: const Icon(Icons.bar_chart_outlined, size: 16),
            label: Text(_text(context, 'Host quota details', '主机用量详情')),
          ),
          if (!_unsupported.contains(LinkMethods.quota))
            TextButton.icon(
              onPressed: ready ? () => _refreshQuota(snapshot) : null,
              icon: const Icon(Icons.refresh, size: 16),
              label: Text(_text(context, 'Refresh host quota', '刷新主机用量')),
            ),
        ],
      ];
      if (messages.isNotEmpty) {
        children.add(
          TextButton.icon(
            onPressed: ready && _editedItems == null
                ? () => _edit(snapshot, messages)
                : null,
            icon: const Icon(Icons.edit_outlined, size: 16),
            label: Text(_text(context, 'Edit old message', '编辑旧消息')),
          ),
        );
      }
      if (delivery) {
        children.addAll([
          TextButton.icon(
            onPressed: ready ? () => _deliver(snapshot, now: false) : null,
            icon: const Icon(Icons.schedule, size: 16),
            label: Text(_text(context, 'Queue message', '消息排队')),
          ),
          if (_action(snapshot, 'turn') is int)
            TextButton.icon(
              onPressed: ready ? () => _deliver(snapshot, now: true) : null,
              icon: const Icon(Icons.send_outlined, size: 16),
              label: Text(_text(context, 'Send now', '立即发送')),
            ),
        ]);
      }
      if (_queueAccepted) {
        children.add(
          Semantics(
            liveRegion: true,
            child: Text(
              _text(context, 'Host accepted the queued message.', '主机已接收排队消息。'),
            ),
          ),
        );
      }
      if (_failure case final failure?) {
        children.add(
          Text(switch (failure) {
            'unsupported' => _text(
              context,
              'This action is unavailable on the host.',
              '主机不支持此操作。',
            ),
            'rejected' => _text(
              context,
              'The host rejected the action.',
              '主机拒绝了此操作。',
            ),
            _ => _text(
              context,
              'The host did not confirm the action. Check the conversation before retrying.',
              '主机未确认此操作。请先查看对话再重试。',
            ),
          }),
        );
      }
      if (children.isEmpty) return const SizedBox.shrink();
      return Wrap(
        spacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: children,
      );
    },
  );
}

typedef _PendingPlan = ({PlanItem item, String revision});

Object? _action(DesktopRemoteSessionSnapshot? snapshot, String key) {
  final actions = snapshot?.state['actions'];
  return actions is Map ? actions[key] : null;
}

bool _canDeliver(DesktopRemoteSessionSnapshot? snapshot) =>
    snapshot != null &&
    snapshot.live &&
    snapshot.state['interaction'] == null &&
    _action(snapshot, 'queue') == true;

_PendingPlan? _waitingPlan(DesktopRemoteSessionSnapshot? snapshot) {
  if (snapshot == null ||
      snapshot.live ||
      snapshot.state['interaction'] != null) {
    return null;
  }
  if (_action(snapshot, 'startPlan') != true) return null;
  // Match ChatSession.awaitingPlan: only the latest plan in the latest turn.
  for (final raw in snapshot.items.reversed) {
    if (raw is! Map<String, Object?>) continue;
    if (raw['t'] == 'user') return null;
    if (raw['t'] != 'plan') continue;
    if (ChatCodec.decode(raw, hostTranscript: true) case final PlanItem item
        when item.status == PlanStatus.awaiting) {
      return (item: item, revision: linkDigest(raw));
    }
    return null;
  }
  return null;
}

String? _quotaSummary(BuildContext context, Map<String, Object?> quota) {
  final accounts = quota['accounts'];
  if (accounts is! List) return null;
  final ordered = accounts.whereType<Map>().where((a) => a['off'] != true);
  final selected =
      ordered.where((a) => a['current'] == true).firstOrNull ??
      ordered.firstOrNull;
  final provider = quota['provider'];
  final windows = selected?['windows'];
  if (windows is List) {
    final values = [
      for (final window in windows)
        if (window case {'left': final int left} when left >= 0 && left <= 100)
          [
            if (window case {'name': final String name} when name.isNotEmpty)
              name,
            if (window case {'minutes': 300}) _text(context, '5h', '5 小时'),
            if (window case {'minutes': 10080}) _text(context, 'Weekly', '每周'),
            '$left%',
          ].join(' '),
    ];
    if (values.isNotEmpty) {
      return [if (provider is String) provider, ...values].join(' · ');
    }
  }
  return provider is String ? provider : null;
}

class _QuestionDialog extends StatelessWidget {
  const _QuestionDialog({required this.request});
  final QuestionRequest request;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(request.title),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: InteractionPanel(
          key: ValueKey(request.id),
          request: request,
          onAnswer: (answer) => Navigator.pop(context, answer),
        ),
      ),
    ),
    actions: [_cancel(context)],
  );
}

class _ApprovalDialog extends StatelessWidget {
  const _ApprovalDialog({required this.request});
  final ApprovalRequest request;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(request.title.isEmpty ? request.toolName : request.title),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (request.title != request.toolName) Text(request.toolName),
            if (request.reason case final reason? when reason.isNotEmpty)
              SelectableText(reason),
            if (request.preview case TextPreview(:final text))
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SelectableText(text),
              ),
          ],
        ),
      ),
    ),
    actions: [
      _cancel(context),
      TextButton(
        onPressed: () =>
            Navigator.pop(context, const ApprovalAnswer(ApprovalDecision.deny)),
        child: Text(_text(context, 'Deny', '拒绝')),
      ),
      OutlinedButton(
        onPressed: () => Navigator.pop(
          context,
          const ApprovalAnswer(ApprovalDecision.allowOnce),
        ),
        child: Text(_text(context, 'Allow once', '仅允许一次')),
      ),
    ],
  );
}

class _StaleDialog extends StatelessWidget {
  @override
  Widget build(BuildContext context) => AlertDialog(
    content: Text(
      _text(
        context,
        'The host conversation changed. Reopen the action to continue.',
        '主机对话已变化。请重新打开操作。',
      ),
    ),
    actions: [_cancel(context)],
  );
}

Widget _cancel(BuildContext context) => TextButton(
  onPressed: () => Navigator.pop(context),
  child: Text(_text(context, 'Cancel', '取消')),
);

String _text(BuildContext context, String en, String zh) =>
    Localizations.localeOf(context).languageCode == 'zh' ? zh : en;
