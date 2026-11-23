part of 'desktop_remote_session_actions.dart';

String? _nonBlank(Object? value) =>
    value is String && value.trim().isNotEmpty ? value : null;

String? _goalCondition(DesktopRemoteSessionSnapshot snapshot) =>
    switch (snapshot.state['goal']) {
      {'condition': final condition} => _nonBlank(condition),
      _ => null,
    };

Widget? _goalDetails(
  BuildContext context,
  DesktopRemoteSessionSnapshot snapshot,
) {
  final condition = _goalCondition(snapshot);
  final goal = snapshot.state['goal'];
  if (condition == null || goal is! Map) return null;
  final l10n = context.l10n;
  final state = switch (goal['state']) {
    'active' => l10n.goalWorking,
    'met' => l10n.goalMet,
    'failed' => l10n.goalFailed,
    _ => null,
  };
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SelectableText(condition),
      const SizedBox(height: 12),
      if (state != null) Text(state),
      if (goal['checks'] case final int checks when checks > 0)
        Text(l10n.goalChecks(checks)),
      if (_nonBlank(goal['reason']) case final reason?) ...[
        Text(l10n.goalLastCheck),
        SelectableText(reason),
      ],
      if (_hostDateTime(context, goal['setAt']) case final date?)
        Text('${_text(context, 'Set at', '设定时间')} $date'),
      if (goal['duration'] case final int ms when ms >= 0)
        Text(
          '${_text(context, 'Duration:', '耗时：')} '
          '${AgentStep.formatDuration(Duration(milliseconds: ms), l10n: l10n)}',
        ),
      if (goal['tokens'] case final int tokens when tokens >= 0)
        Text('${_text(context, 'Tokens:', '令牌数：')} $tokens'),
    ],
  );
}

String? _hostDateTime(BuildContext context, Object? ms) {
  const maxEpochMs = 8640000000000000;
  if (ms is! int || ms < -maxEpochMs || ms > maxEpochMs) return null;
  final time = DateTime.fromMillisecondsSinceEpoch(ms);
  final localizations = MaterialLocalizations.of(context);
  return '${localizations.formatShortDate(time)} '
      '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(time))}';
}

Widget? _quotaDetails(
  BuildContext context,
  DesktopRemoteSessionSnapshot snapshot,
) {
  final quota = snapshot.state['quota'];
  if (quota is! Map) return null;
  final accounts = quota['accounts'];
  final children = <Widget>[
    if (_nonBlank(quota['provider']) case final provider?)
      Text(provider, style: Theme.of(context).textTheme.titleSmall),
    if (_hostDateTime(context, quota['back']) case final back?)
      Text(context.l10n.quotaBarBackAt(back)),
    if (accounts is List)
      for (final account in accounts.whereType<Map<String, Object?>>())
        if (_quotaAccount(context, account) case final details?) ...[
          const Divider(height: 20),
          details,
        ],
  ];
  return children.isEmpty
      ? null
      : Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        );
}

Widget? _quotaAccount(BuildContext context, Map<String, Object?> account) {
  final l10n = context.l10n;
  final windows = account['windows'];
  final children = <Widget>[
    if (_nonBlank(account['name']) case final name?)
      Text(name, style: Theme.of(context).textTheme.titleSmall),
    if (_nonBlank(account['plan']) case final plan?) Text(plan),
    if (account['current'] == true) Text(l10n.quotaBarThisChat),
    if (account['off'] == true) Text(_text(context, 'Unavailable', '不可用')),
    if (_hostDateTime(context, account['until']) case final until?)
      Text('${_text(context, 'Limited until', '受限至')} $until'),
    if (windows is List)
      for (final window in windows.whereType<Map<String, Object?>>())
        if (_quotaWindow(context, window) case final details?) Text(details),
    if (_nonBlank(account['error']) case final error?) SelectableText(error),
    if (_hostDateTime(context, account['at']) case final updated?)
      Text(l10n.modelsQuotaLastUpdated(updated)),
  ];
  return children.isEmpty
      ? null
      : Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        );
}

String? _quotaWindow(BuildContext context, Map<String, Object?> window) {
  final l10n = context.l10n;
  final period = switch (window['minutes']) {
    10080 => l10n.modelsQuotaWeek,
    final int min when min > 0 && min % 1440 == 0 => l10n.modelsQuotaDays(
      min ~/ 1440,
    ),
    final int min when min > 0 && min % 60 == 0 => l10n.modelsQuotaHours(
      min ~/ 60,
    ),
    final int min when min > 0 => _text(context, '$min min', '$min 分钟'),
    _ => null,
  };
  final parts = [
    ?_nonBlank(window['name']),
    ?period,
    if (window['left'] case final int left when left >= 0 && left <= 100)
      l10n.modelsQuotaRemaining(left),
    if (_hostDateTime(context, window['resets']) case final resets?)
      l10n.modelsQuotaResetsAt(resets),
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}
