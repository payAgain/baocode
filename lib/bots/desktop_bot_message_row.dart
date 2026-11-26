import 'package:flutter/material.dart';

import '../chat/widgets/assistant_text.dart' show inlineCodeSpan;
import '../chat/widgets/inline_code.dart';
import '../settings/pages/settings_widgets.dart' show SettingsText;
import '../theme/app_theme.dart';

/// Presentation only: each transcript supplies already-admitted text, media
/// and actions. In particular this row does not interpret a host path or follow.
class DesktopBotMessageRow extends StatelessWidget {
  const DesktopBotMessageRow({
    super.key,
    required this.mine,
    required this.content,
    this.sender,
    this.avatar,
    this.sentAt,
    this.quote,
    this.reply,
    this.media,
  });

  final bool mine;
  final String? sender;
  final Widget? avatar;
  final DateTime? sentAt;
  final Widget? quote;
  final Widget? reply;
  final List<Widget> content;
  final Widget? media;

  @override
  Widget build(BuildContext context) {
    final alignment = mine
        ? AlignmentDirectional.centerEnd
        : AlignmentDirectional.centerStart;
    final name = sender;
    final date = sentAt?.toLocal();
    final small = Theme.of(context).textTheme.labelMedium
        ?.copyWith(color: AppColors.textMuted);
    final time = date == null
        ? null
        : MaterialLocalizations.of(context).formatTimeOfDay(
            TimeOfDay.fromDateTime(date),
            alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
          );
    return Align(
      alignment: alignment,
      child: FractionallySizedBox(
        widthFactor: .88,
        alignment: alignment,
        child: Align(
          alignment: alignment,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: mine ? AppColors.bubbleFill : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (name != null && name.isNotEmpty)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        avatar ?? DesktopBotMessageAvatar(sender: name),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            name,
                            style: small,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (time != null) ...[
                          const SizedBox(width: 8),
                          Text(time, style: small),
                        ],
                        ?reply,
                      ],
                    )
                  else if (time != null)
                    Text(time, style: small),
                  ?quote,
                  ...content,
                  ?media,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// An emoji/avatar already available to this view, or initials. A remote
/// avatar filename is not a local file and is never passed to this widget.
class DesktopBotMessageAvatar extends StatelessWidget {
  const DesktopBotMessageAvatar({super.key, required this.sender, this.emoji});

  final String sender;
  final String? emoji;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: CircleAvatar(
      radius: 9,
      backgroundColor: AppColors.surfaceRaised,
      foregroundColor: AppColors.textMuted,
      child: Text(
        emoji ?? sender.characters.firstOrNull?.toUpperCase() ?? '',
        maxLines: 1,
        style: const TextStyle(fontSize: 10),
      ),
    ),
  );
}

class DesktopBotMessageText extends StatelessWidget {
  const DesktopBotMessageText(
    this.text, {
    super.key,
    this.narration = false,
    this.inlineCode = false,
  });

  final String text;
  final bool narration;

  /// Style backticks without interpreting links, images, or other Markdown.
  final bool inlineCode;

  @override
  Widget build(BuildContext context) {
    final style = (Theme.of(context).textTheme.bodyMedium ?? const TextStyle())
        .copyWith(
          color: narration ? AppColors.textMuted : AppColors.text,
          fontStyle: narration ? FontStyle.italic : null,
        );
    return inlineCode && text.contains('`')
        ? InlineCodeText(inlineCodeSpan(text, style))
        : Text(text, style: style);
  }
}

class DesktopGroupQuoteBanner extends StatelessWidget {
  const DesktopGroupQuoteBanner({
    super.key,
    required this.label,
    required this.preview,
    this.trailing,
  });

  final String label;
  final String preview;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsetsDirectional.fromSTEB(12, 4, 8, 4),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.format_quote, size: 16),
        const SizedBox(width: 8),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: SettingsText.heading,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (preview.isNotEmpty)
                Text(
                  preview,
                  style: SettingsText.description,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
        ?trailing,
      ],
    ),
  );
}
