import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../chat/side_panel/file_preview.dart' show ReadOnlyFileLines;
import '../../chat/side_panel/line_diff.dart' show diffLines;
import '../../l10n/l10n.dart';
import '../../theme/app_theme.dart' show AppColors;
import '../../theme/codicons.dart';
import '../ide_panes.dart' show IdePaneAction;

/// A unified Git patch received as text. No repository or file access.
class IdeGitPatchReader extends StatefulWidget {
  const IdeGitPatchReader({
    super.key,
    required this.patch,
    required this.emptyLabel,
    this.truncationLabel,
  });

  final String patch;
  final String emptyLabel;
  final String? truncationLabel;

  @override
  State<IdeGitPatchReader> createState() => _IdeGitPatchReaderState();
}

class _IdeGitPatchReaderState extends State<IdeGitPatchReader> {
  static final _hunkHeader = RegExp(r'^@@ -\d+(?:,\d+)? \+\d+(?:,\d+)? @@');
  late List<String> _lines;
  late List<int> _hunks;
  var _current = -1;
  var _reveal = 0;

  @override
  void initState() {
    super.initState();
    _parse();
  }

  @override
  void didUpdateWidget(IdeGitPatchReader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.patch != oldWidget.patch) _parse();
  }

  void _parse() {
    _lines = diffLines(widget.patch);
    _hunks = [
      for (final (index, line) in _lines.indexed)
        if (_hunkHeader.hasMatch(line)) index + 1,
    ];
    _current = -1;
    _reveal++;
  }

  void _jump(int index) => setState(() {
    _current = index;
    _reveal++;
  });

  (List<String>, Color, Color, Color, Color)? _colorKey;
  List<List<TextSpan>?> _coloredLines = const [];

  List<List<TextSpan>?> _colors() {
    final accent = AppColors.accent;
    final muted = AppColors.textMuted;
    final added = AppColors.added;
    final removed = AppColors.removed;
    final key = (_lines, accent, muted, added, removed);
    if (_colorKey == key) return _coloredLines;
    _colorKey = key;
    var inHunk = false;
    final colors = <List<TextSpan>?>[];
    for (final line in _lines) {
      final header = _hunkHeader.hasMatch(line);
      if (line.startsWith('diff --git ')) inHunk = false;
      if (header) inHunk = true;
      final color = switch (line) {
        _ when header => accent,
        _
            when !inHunk &&
                (line.startsWith('+++ ') || line.startsWith('--- ')) =>
          muted,
        _ when line.startsWith('+') => added,
        _ when line.startsWith('-') => removed,
        _ => null,
      };
      colors.add(
        color == null
            ? null
            : [
                TextSpan(
                  text: line.replaceAll('\t', '    '),
                  style: TextStyle(color: color),
                ),
              ],
      );
    }
    return _coloredLines = colors;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final target = _current < 0 ? null : _hunks[_current];
    return ColoredBox(
      color: AppColors.code,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_lines.isNotEmpty)
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (_hunks.isNotEmpty) ...[
                  IdePaneAction(
                    tooltip: l10n.cmdPreviousChange,
                    icon: Codicons.chevronUp,
                    onPressed: _current > 0 ? () => _jump(_current - 1) : null,
                  ),
                  IdePaneAction(
                    tooltip: l10n.cmdNextChange,
                    icon: Codicons.chevronDown,
                    onPressed: _current < _hunks.length - 1
                        ? () => _jump(_current + 1)
                        : null,
                  ),
                ],
                IdePaneAction(
                  tooltip: l10n.gitLogCopyPatch,
                  icon: Codicons.copy,
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: widget.patch)),
                ),
              ],
            ),
          if (widget.truncationLabel case final label?)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(label, style: TextStyle(color: AppColors.textMuted)),
            ),
          Expanded(
            child: _lines.isEmpty
                ? Center(child: Text(widget.emptyLabel))
                : ReadOnlyFileLines(
                    key: ValueKey(_lines),
                    lines: _lines,
                    colors: _colors(),
                    reveal: _reveal,
                    firstMarkedLine: target,
                    lastMarkedLine: target,
                  ),
          ),
        ],
      ),
    );
  }
}
