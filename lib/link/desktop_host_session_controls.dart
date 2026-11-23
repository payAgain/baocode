import 'package:bao_link/bao_link.dart';

import '../kernel/kernel_types.dart';

/// Choices/actions for a single open host follow. Only session snapshots
/// change what is selected; an RPC acknowledgement carries no selection.
class DesktopHostSessionControls {
  DesktopHostSessionControls({
    required this.peer,
    required this.session,
    required this.kind,
    required this.isCurrent,
    required this.onChanged,
  });

  final LinkPeer peer;
  final String session;
  final String kind;
  final bool Function() isCurrent;
  final void Function() onChanged;

  Map<String, LinkChoice> _choices = const {};
  Map<String, LinkChoice> get choices => _choices;
  Object? _wireChoices;
  Object? _wireContext;
  ContextUsage? _context;
  ContextUsage? get context => _context;
  bool _choosing = false;
  ({String? previous, String requested})? _pendingModel;
  bool get modelSettingsReady => !_choosing && _pendingModel == null;
  bool _choiceFailed = false;
  bool get choiceFailed => _choiceFailed;

  bool _live = false;
  bool get live => _live;
  bool _stopUnsupported = false;
  Object? _stopRequest;
  bool _stopFailed = false;
  bool get stopFailed => _stopFailed;
  bool get showStop => _live && !_stopUnsupported;
  bool get canStop => showStop && _stopRequest == null;

  void apply(Map<String, Object?> update) {
    _live = update['live'] == true;
    if (!_live) {
      _stopRequest = null;
      _stopFailed = false;
    }
    final context = update['context'];
    if (!identical(context, _wireContext)) {
      _wireContext = context;
      _context = _parseContext(context);
    }
    final choices = update['choices'];
    if (identical(choices, _wireChoices)) return;
    _wireChoices = choices;
    final next = <String, LinkChoice>{};
    if (choices is List<Object?>) {
      for (final raw in choices) {
        if (raw is! Map<String, Object?>) continue;
        try {
          final choice = LinkChoice.fromJson(raw);
          final supported = switch (choice.kind) {
            'mode' || 'permission' => kind == 'project',
            'model' || 'effort' || 'context' => kind != 'group',
            _ => false,
          };
          if (!supported) continue;
          if (choice.options.any((option) => option.id.isNotEmpty)) {
            next[choice.kind] = choice;
          }
        } on TypeError {
          // An invalid choice cannot break the transcript or other controls.
        }
      }
    }
    _choices = Map.unmodifiable(next);
    if (_pendingModel case final pending?) {
      final model = _choices['model'];
      if (model == null ||
          model.selected != pending.previous ||
          !model.options.any((option) => option.id == pending.requested)) {
        _pendingModel = null;
      }
    }
  }

  static ContextUsage? _parseContext(Object? value) {
    if (value case final Map<String, Object?> map) {
      final window = map['window'];
      final used = map['used'];
      if (window is! int || used is! int || window <= 0 || used < 0) {
        return null;
      }
      final segments = <ContextSegment>[
        if (map['parts'] case final List<Object?> parts)
          for (final part in parts)
            if (part
                case {'part': final String label, 'tokens': final int tokens}
                when label.isNotEmpty && tokens > 0)
              ContextSegment(label, tokens),
      ];
      return ContextUsage(
        window: window,
        used: used,
        segments: List.unmodifiable(segments),
        detail: switch (map['compactAt']) {
          final int threshold when threshold > 0 => ContextDetail(
            autoCompactAt: threshold,
          ),
          _ => null,
        },
      );
    }
    return null;
  }

  Future<void> choose(LinkChoice choice, String option) async {
    final isModelSetting = choice.kind == 'effort' || choice.kind == 'context';
    if (!isCurrent() ||
        peer.isClosed ||
        _choosing ||
        (isModelSetting && !modelSettingsReady) ||
        !identical(choices[choice.kind], choice) ||
        option.isEmpty ||
        option == choice.selected ||
        !choice.options.any((candidate) => candidate.id == option)) {
      return;
    }
    _choosing = true;
    _choiceFailed = false;
    // The setting request has no model ID. Wait for the follow to tell us
    // which model is active after a model request.
    final priorModel = _pendingModel;
    final modelChange = choice.kind == 'model'
        ? (previous: choice.selected, requested: option)
        : null;
    if (modelChange != null) _pendingModel = modelChange;
    onChanged();
    try {
      if (!isCurrent() ||
          peer.isClosed ||
          !identical(choices[choice.kind], choice)) {
        if (modelChange != null && _pendingModel == modelChange) {
          _pendingModel = priorModel;
        }
        return;
      }
      await peer.call(LinkMethods.choose, {
        'session': session,
        'kind': choice.kind,
        'option': option,
      });
    } on Object catch (error) {
      if (!isCurrent()) return;
      // A transport failure (or the host's generic failure) does not say
      // whether it applied the choice. Keep model settings guarded then.
      if (modelChange != null &&
          _pendingModel == modelChange &&
          error is LinkRemoteException &&
          error.code != 'failed') {
        _pendingModel = priorModel;
      }
      _choiceFailed = choices[choice.kind]?.selected != option;
    } finally {
      _choosing = false;
      if (isCurrent()) onChanged();
    }
  }

  Future<void> stop() async {
    if (!isCurrent() || peer.isClosed || !canStop) return;
    final request = _stopRequest = Object();
    _stopFailed = false;
    onChanged();
    bool current() => isCurrent() && identical(_stopRequest, request);
    try {
      if (!current() || peer.isClosed) return;
      await peer.call(LinkMethods.stop, {'session': session});
      // The host's live update, not the acknowledgement, ends the turn.
    } on Object catch (error) {
      if (!current()) return;
      _stopUnsupported =
          error is LinkRemoteException &&
          (error.code == LinkErrors.unknown ||
              error.code == LinkErrors.unsupported);
      _stopFailed = true;
      _stopRequest = null;
      onChanged();
    }
  }
}
