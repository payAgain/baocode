part of 'desktop_remote_activity.dart';

/// An output view owns one watch, not a session follow. Serialize watch leases
/// for a peer/session/task so a late unwatch cannot cancel a replacement.
class _TaskOutput extends ChangeNotifier {
  _TaskOutput(this.session, this.task);

  final DesktopRemoteActivitySession session;
  final LinkTask task;

  static final _leases = Expando<Map<(String, String), Future<void>>>();
  final _early = <LinkOutput>[];
  final _released = Completer<void>();
  StreamSubscription<LinkEvent>? _events;
  bool _disposed = false;
  int? _offset;
  bool loading = true;
  bool failed = false;
  String tail = '';

  bool get advertised {
    final latest = session._tasks[task.id];
    return latest?.output == true && latest?.startedAt == task.startedAt;
  }

  bool get _current => !_disposed && session._available && advertised;
  LinkPeer get _peer => session.peer;
  Map<String, Object?> get _params => {
    'session': session.session,
    'task': task.id,
  };

  Future<void> load() async {
    try {
      if (!_current) return;
      if (task.status == 'running') {
        try {
          await _watch();
          return;
        } on LinkRemoteException catch (error) {
          if (error.code != LinkErrors.unknown) rethrow;
          // Old hosts can still supply a one-shot output snapshot.
        }
      }
      if (!_current) return;
      final reply = await _peer.call(LinkMethods.output, _params);
      if (!_current) return;
      if (reply case {'text': final String text}) {
        tail = _tail(text);
      } else {
        throw const FormatException('Invalid host output');
      }
    } on Object {
      failed = true;
    } finally {
      loading = false;
      if (_current) notifyListeners();
    }
  }

  Future<void> _watch() async {
    final key = (session.session, task.id);
    final leases = _leases[_peer] ??= {};
    final previous = leases[key];
    final done = Completer<void>();
    leases[key] = done.future;
    var cleanUp = false;
    try {
      if (previous != null) await previous;
      if (!_current) return;
      _events = _peer.events.listen(_onEvent, onDone: _release);
      cleanUp = true;
      final Object? reply;
      try {
        reply = await _peer.call(LinkMethods.watchOutput, _params);
      } on LinkRemoteException catch (error) {
        if (error.code == LinkErrors.unknown) cleanUp = false;
        rethrow;
      }
      if (!_current) return;
      if (reply case {'text': final String text, 'offset': final int offset}
          when offset >= text.length) {
        _offset = offset;
        tail = _tail(text);
        for (final update in _early) {
          if (!_merge(update)) {
            throw const FormatException('Host output has a gap');
          }
        }
        _early.clear();
      } else {
        throw const FormatException('Invalid host output watch');
      }
      // Publish the snapshot now; the lease remains until the view closes.
      loading = false;
      notifyListeners();
      await _released.future;
    } finally {
      unawaited(_events?.cancel());
      _events = null;
      _early.clear();
      if (cleanUp && !_peer.isClosed) {
        try {
          await _peer.call(LinkMethods.unwatchOutput, _params);
        } on Object {
          // Cleanup is best effort. Disconnect also clears the host watch.
        }
      }
      if (identical(leases[key], done.future)) leases.remove(key);
      done.complete();
    }
  }

  void _onEvent(LinkEvent event) {
    if (!_current || failed || event.name != LinkEvents.output) return;
    final update = LinkOutput.fromJson(event.data);
    if (update == null ||
        update.session != session.session ||
        update.task != task.id) {
      return;
    }
    if (_offset == null) {
      if (_early.length < 16) {
        _early.add(update);
        return;
      }
    } else if (_merge(update)) {
      notifyListeners();
      return;
    }
    // Without all preceding characters the host's tail cannot be reconstructed.
    failed = true;
    loading = false;
    _release();
    notifyListeners();
  }

  bool _merge(LinkOutput update) {
    final start = update.offset - update.text.length;
    if (start < 0) return false;
    if (update.reset) {
      tail = _tail(update.text);
    } else {
      final offset = _offset!;
      if (update.offset <= offset) return true;
      if (start != offset) return false;
      tail = _tail(tail + update.text);
    }
    _offset = update.offset;
    return true;
  }

  static String _tail(String text) => text.length <= LinkLimits.output
      ? text
      : text.substring(text.length - LinkLimits.output);

  void _release() {
    if (!_released.isCompleted) _released.complete();
    unawaited(_events?.cancel());
    _events = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _release();
    super.dispose();
  }
}
