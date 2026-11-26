import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'links/terminal_link_resolver.dart';
import 'links/terminal_links.dart';
import 'pty.dart';
import 'terminal_colors.dart' show editorTerminalColorTheme;
import 'terminal_instance.dart';
import 'terminal_view.dart';

/// An ANSI output snapshot rendered on the same screen as a local task.
/// The default view has no process, shell input, or link resolution.
class TerminalOutputView extends StatefulWidget {
  const TerminalOutputView({super.key, required this.text, this.background})
    : _local = false,
      _root = '',
      _linkStat = null,
      _skipShell = const [],
      _onKill = null,
      _onOpenLink = null;

  /// Local previews retain their terminal keys, task control, and file links.
  const TerminalOutputView.local({
    super.key,
    required this.text,
    this.background,
    this._root = '',
    this._linkStat,
    this._skipShell = const [],
    this._onKill,
    this._onOpenLink,
  }) : _local = true;

  final String text;
  final Color? background;
  final bool _local;
  final String _root;
  final TerminalLinkStat? _linkStat;
  final List<ShortcutActivator> _skipShell;
  final VoidCallback? _onKill;
  final ValueChanged<TerminalLink>? _onOpenLink;

  @override
  State<TerminalOutputView> createState() => _TerminalOutputViewState();
}

class _TerminalOutputViewState extends State<TerminalOutputView> {
  late final _OutputPty? _pty = widget._local ? _OutputPty() : null;
  late final _terminal = TerminalInstance(
    id: 0,
    root: widget._root,
    outputOnly: !widget._local,
    backend: _pty == null
        ? const TerminalBackend()
        : TerminalBackend(
            launch: (
              root, {
              columns = 80,
              rows = 24,
              shell,
              environment,
            }) async => PtyLaunch(executable: '', workingDirectory: root),
            start: (_) async => _pty,
            linkStat: widget._linkStat,
          ),
    colorTheme: editorTerminalColorTheme,
  );

  String? _shown;
  static const _printLimit = 200000;

  @override
  void initState() {
    super.initState();
    // Files end lines in LF, without a PTY's conversion to CRLF.
    _terminal.xterm.options
      ..convertEol = true
      ..scrollback = 10000;
    _print();
  }

  @override
  void didUpdateWidget(TerminalOutputView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _print();
  }

  /// Append only new data. On replacement (including a rolling tail), replay
  /// from a reset screen, cancelling any unfinished escape sequence first.
  void _print() {
    final screen = widget.text;
    final shown = _shown;
    if (screen == shown) return;
    _shown = screen;
    String data;
    if (shown != null && screen.startsWith(shown)) {
      data = screen.substring(shown.length);
    } else {
      var text = screen;
      if (text.length > _printLimit) {
        final cut = text.indexOf('\n', text.length - _printLimit);
        text = text.substring(cut < 0 ? text.length - _printLimit : cut + 1);
      }
      data = '${shown == null ? '' : '\x18\x1bc'}\x1b[?25l$text';
    }
    if (_pty case final pty?) {
      pty.print(data);
    } else {
      _terminal.printOutput(data);
    }
  }

  @override
  Widget build(BuildContext context) => TerminalView(
    _terminal,
    skipShell: widget._skipShell,
    onKill: widget._onKill,
    onOpenLink: widget._onOpenLink,
    background: widget.background,
  );

  @override
  void dispose() {
    _terminal.dispose();
    _pty?.kill();
    super.dispose();
  }
}

/// The local preview's output adapter. Nothing typed reaches the command.
class _OutputPty extends Pty {
  final _output = StreamController<Uint8List>();

  void print(String text) {
    if (text.isNotEmpty && !_output.isClosed) _output.add(utf8.encode(text));
  }

  @override
  int get pid => 0;

  @override
  Stream<Uint8List> get output => _output.stream;

  @override
  void write(Uint8List data) {}

  @override
  void resize(int columns, int rows) {}

  @override
  void kill([PtySignal signal = PtySignal.hangup]) =>
      unawaited(_output.close());

  /// The task's status says how the command did.
  @override
  Future<int> get exitCode => Completer<int>().future;
}
