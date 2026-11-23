import 'package:bao_markdown/bao_markdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chat/chat_keys.dart';
import '../chat/composer/composer_presentation.dart';

/// The normal chat editor and send controls for a host conversation.
/// Draft storage and delivery belong to the caller. Key the composer by
/// conversation so a different conversation can supply its own [initialDraft].
class DesktopHostComposer extends StatefulWidget {
  const DesktopHostComposer({
    super.key,
    required this.initialDraft,
    required this.busy,
    required this.placeholder,
    required this.sendLabel,
    required this.onChanged,
    required this.onSend,
  });

  final String initialDraft;
  final bool busy;
  final String placeholder;
  final String sendLabel;
  final ValueChanged<String> onChanged;

  /// True only for a confirmed send in the current host conversation.
  /// Report failed and uncertain delivery to the caller's UI and return false.
  final Future<bool> Function(String) onSend;

  @override
  State<DesktopHostComposer> createState() => _DesktopHostComposerState();
}

class _DesktopHostComposerState extends State<DesktopHostComposer>
    with ChatKeyTarget {
  final _focus = FocusNode(debugLabel: 'Host composer');
  late final MarkdownController _draft;
  int _savedVersion = 0;
  bool _sending = false;

  @override
  bool get chatComposing => _draft.isComposing;

  @override
  void initState() {
    super.initState();
    final text = widget.initialDraft;
    _draft = MarkdownController(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
      plain: true,
    )..addListener(_draftChanged);
  }

  @override
  void dispose() {
    _draft.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _draftChanged() {
    final version = _draft.textVersion;
    if (version == _savedVersion) return;
    _savedVersion = version;
    widget.onChanged(_draft.text);
  }

  bool get _canSend =>
      !widget.busy &&
      !_sending &&
      !_draft.isComposing &&
      _draft.text.trim().isNotEmpty;

  KeyEventResult _handleKey(KeyEvent event) {
    final key = event.logicalKey;
    final keyboard = HardwareKeyboard.instance;
    if ((key != LogicalKeyboardKey.enter &&
            key != LogicalKeyboardKey.numpadEnter) ||
        event is KeyUpEvent ||
        _draft.isComposing ||
        keyboard.isShiftPressed ||
        keyboard.isAltPressed ||
        keyboard.isControlPressed ||
        keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent) _send();
    // Consume key repeats and Enter on an empty draft without adding a line.
    return KeyEventResult.handled;
  }

  Future<void> _send() async {
    if (!_canSend) return;
    final version = _draft.textVersion;
    setState(() => _sending = true);
    try {
      if (await widget.onSend(_draft.text) &&
          mounted &&
          _draft.textVersion == version &&
          !_draft.isComposing) {
        _draft
          ..forgetUndo()
          ..replaceUnrecorded(0, _draft.length, '');
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: ListenableBuilder(
      listenable: _focus,
      builder: (context, child) =>
          ComposerSurface(focused: _focus.hasFocus, child: child!),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: composerEditorPadding,
            child: ClipRect(
              child: ConstrainedBox(
                constraints: composerEditorConstraints(context),
                child: Semantics(
                  label: widget.placeholder,
                  textField: true,
                  multiline: true,
                  child: MarkdownEditor(
                    controller: _draft,
                    focusNode: _focus,
                    shrinkWrap: true,
                    pastePlainText: true,
                    placeholder: widget.placeholder,
                    onKey: _handleKey,
                    style: composerEditorStyle(context),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: composerToolbarPadding,
            child: Align(
              alignment: AlignmentDirectional.centerEnd,
              child: ListenableBuilder(
                listenable: _draft,
                builder: (context, _) => ComposerSendButton(
                  tooltip: widget.sendLabel,
                  onSend: _canSend ? _send : null,
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
