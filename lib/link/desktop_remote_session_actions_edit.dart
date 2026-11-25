part of 'desktop_remote_session_actions.dart';

bool _canEdit(DesktopRemoteSessionSnapshot? snapshot) =>
    snapshot != null &&
    !snapshot.live &&
    snapshot.state['interaction'] == null &&
    _action(snapshot, 'edit') == true;

final _internalNote = RegExp(
  r'<(?:system-reminder|bao-event|task-notification|local-command-caveat)\b',
  caseSensitive: false,
);

String? _editableText(Object? raw) {
  if (raw case {'t': 'user', 'text': final String text}
      when raw['queued'] != true &&
          raw['agent'] == null &&
          raw['agentSession'] == null &&
          (raw['images'] == null ||
              (raw['images'] is List && (raw['images'] as List).isEmpty)) &&
          text.trim().isNotEmpty &&
          !_internalNote.hasMatch(text) &&
          !imageReferencePattern.hasMatch(text)) {
    return text;
  }
  return null;
}

class _InlineMessageEditor extends StatefulWidget {
  const _InlineMessageEditor({
    required this.initial,
    required this.scrollController,
    required this.onClose,
    required this.onReview,
  });

  final String initial;
  final ScrollController scrollController;
  final VoidCallback onClose;
  final Future<bool> Function(String) onReview;

  @override
  State<_InlineMessageEditor> createState() => _InlineMessageEditorState();
}

class _InlineMessageEditorState extends State<_InlineMessageEditor> {
  late final _controller = TextEditingController(text: widget.initial);
  bool _reviewing = false;

  Future<void> _review() async {
    if (_reviewing || !_canSubmitMessage(_controller.value)) return;
    setState(() => _reviewing = true);
    try {
      final submitted = await widget.onReview(_controller.text);
      if (submitted && mounted) widget.onClose();
    } finally {
      if (mounted) setState(() => _reviewing = false);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
    },
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.bubbleFill,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.bubbleBorder(focused: true)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _controller,
              scrollController: widget.scrollController,
              autofocus: true,
              readOnly: _reviewing,
              minLines: 1,
              maxLines: 8,
              decoration: const InputDecoration(border: InputBorder.none),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextFieldTapRegion(
                child: Wrap(
                  spacing: 6,
                  children: [
                    TextButton(
                      onPressed: widget.onClose,
                      child: Text(_text(context, 'Cancel', '取消')),
                    ),
                    ListenableBuilder(
                      listenable: _controller,
                      builder: (context, _) => OutlinedButton(
                        onPressed:
                            _reviewing || !_canSubmitMessage(_controller.value)
                            ? null
                            : _review,
                        child: Text(_text(context, 'Review edit', '查看编辑影响')),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

bool _canSubmitMessage(TextEditingValue value) =>
    value.text.trim().isNotEmpty &&
    !(value.isComposingRangeValid && !value.composing.isCollapsed);

class _MessageDialog extends StatefulWidget {
  const _MessageDialog({
    required this.initial,
    required this.title,
    required this.submit,
  });

  final String initial;
  final String title;
  final String submit;

  @override
  State<_MessageDialog> createState() => _MessageDialogState();
}

class _MessageDialogState extends State<_MessageDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  bool get _canSubmit => _canSubmitMessage(_controller.value);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 480,
      child: TextField(
        controller: _controller,
        autofocus: true,
        minLines: 3,
        maxLines: 8,
        decoration: InputDecoration(labelText: _text(context, 'Message', '消息')),
      ),
    ),
    actions: [
      _cancel(context),
      ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          return OutlinedButton(
            onPressed: !_canSubmit
                ? null
                : () {
                    if (_canSubmit) Navigator.pop(context, _controller.text);
                  },
            child: Text(widget.submit),
          );
        },
      ),
    ],
  );
}

class _RewindDialog extends StatelessWidget {
  const _RewindDialog({required this.review});

  final Object? review;

  @override
  Widget build(BuildContext context) {
    final files = switch (review) {
      {'files': final List files} => files,
      _ => null,
    };
    final valid =
        files != null &&
        files.every(
          (file) => switch (file) {
            {
              'name': final String name,
              'outcome': 'restore' || 'merge' || 'conflict',
            } =>
              name.isNotEmpty,
            _ => false,
          },
        );
    final canRestore =
        valid && files.any((file) => (file as Map)['outcome'] != 'conflict');
    return AlertDialog(
      title: Text(_text(context, 'Resend edited message?', '重新发送编辑后的消息？')),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _text(
                  context,
                  'This replaces the original message and discards subsequent turns on the host.',
                  '这会替换主机上的原始消息并丢弃其后的对话轮次。',
                ),
              ),
              const SizedBox(height: 8),
              if (!valid)
                Text(
                  _text(
                    context,
                    'A file preview is unavailable. You can keep the current files.',
                    '无法预览文件改动。你可以保留当前文件。',
                  ),
                )
              else if (files.isEmpty)
                Text(
                  _text(
                    context,
                    'The host reported no file changes to restore.',
                    '主机报告没有可还原的文件改动。',
                  ),
                )
              else
                for (final {'name': String name, 'outcome': String outcome}
                    in files)
                  SelectableText(
                    '$name — ${switch (outcome) {
                      'restore' => _text(context, 'restore', '还原'),
                      'merge' => _text(context, 'preserve other edits', '保留其他编辑'),
                      _ => _text(context, 'conflict; left unchanged', '冲突，不会改动'),
                    }}',
                  ),
            ],
          ),
        ),
      ),
      actions: [
        _cancel(context),
        OutlinedButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(_text(context, 'Keep files and resend', '保留文件并重发')),
        ),
        if (canRestore)
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(_text(context, 'Restore files and resend', '还原文件并重发')),
          ),
      ],
    );
  }
}
