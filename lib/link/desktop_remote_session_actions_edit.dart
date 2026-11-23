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

typedef _EditTarget = ({int index, String text});

List<_EditTarget> _editTargets(DesktopRemoteSessionSnapshot snapshot) {
  final messages = <_EditTarget>[];
  // Count raw wire entries, including invisible assistant and system rows.
  for (final (index, raw) in snapshot.items.indexed) {
    if (raw case {'t': 'user', 'text': final String text}
        when raw['queued'] != true &&
            raw['agent'] == null &&
            raw['agentSession'] == null &&
            (raw['images'] == null ||
                (raw['images'] is List && (raw['images'] as List).isEmpty)) &&
            text.trim().isNotEmpty &&
            !_internalNote.hasMatch(text) &&
            !imageReferencePattern.hasMatch(text)) {
      messages.add((index: index, text: text));
    }
  }
  return messages.reversed.toList();
}

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

  bool get _canSubmit {
    final value = _controller.value;
    return value.text.trim().isNotEmpty &&
        !(value.isComposingRangeValid && !value.composing.isCollapsed);
  }

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
