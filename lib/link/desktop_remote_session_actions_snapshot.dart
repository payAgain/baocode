import '../kernel/kernel_types.dart';

/// The host's rendered update and wire-indexed item window for one follow.
class DesktopRemoteSessionSnapshot {
  const DesktopRemoteSessionSnapshot({
    required this.follow,
    required this.state,
    required this.items,
    required this.live,
    required this.busy,
  });

  final Object follow;
  final Map<String, Object?> state;
  final List<Object?> items;
  final bool live;
  final bool busy;
}

/// Decode host interaction data without enabling persistent permission grants
/// or creating link and file affordances for the preview.
InteractionRequest? decodeRemoteInteraction(Object? raw) {
  if (raw is! Map<String, Object?> ||
      raw['id'] is! String ||
      (raw['id'] as String).isEmpty) {
    return null;
  }
  final id = raw['id'] as String;
  final title = _string(raw['title']);
  switch (raw['t']) {
    case 'question':
      final questions = raw['questions'];
      if (questions is! List || questions.isEmpty) return null;
      final decoded = <Question>[];
      for (final question in questions) {
        if (question is! Map || question['prompt'] is! String) return null;
        final options = question['options'];
        final other = question['other'];
        if (options is! List || (options.isEmpty && other is! String)) {
          return null;
        }
        if (options.any((o) => o is! Map || o['label'] is! String)) return null;
        decoded.add(
          Question(
            prompt: question['prompt'] as String,
            header: _string(question['header']),
            allowMultiple: question['multiple'] == true,
            allowOther: other is String,
            otherLabel: other is String && other.isNotEmpty ? other : null,
            options: [
              for (final o in options.cast<Map>())
                QuestionOption(
                  o['label'] as String,
                  description: _string(o['description']),
                ),
            ],
          ),
        );
      }
      return QuestionRequest(id: id, title: title, questions: decoded);
    case 'approval':
      final tool = raw['tool'];
      if (tool is! String || tool.isEmpty) return null;
      return ApprovalRequest(
        id: id,
        title: title,
        toolName: tool,
        reason: _string(raw['reason']),
        preview: switch (raw['preview']) {
          {'t': 'command', 'command': final String cmd} => TextPreview(
            [
              if (raw['preview'] case {'description': final String description})
                description,
              cmd,
            ].join('\n'),
          ),
          {'t': 'text', 'text': final String text} => TextPreview(text),
          {'t': 'diff', 'path': final String path, 'lines': final List lines} =>
            TextPreview(
              [
                path,
                for (final line in lines)
                  if (line case [
                    final int _,
                    final int number,
                    final String text,
                  ])
                    '$number  $text',
              ].join('\n'),
            ),
          _ => null,
        },
      );
    default:
      return null;
  }
}

String _string(Object? value) => value is String ? value : '';
