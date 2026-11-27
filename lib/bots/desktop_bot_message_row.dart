import 'package:flutter/material.dart';

import '../chat/widgets/assistant_text.dart' show inlineCodeSpan;
import '../chat/widgets/inline_code.dart';
import '../settings/pages/settings_widgets.dart' show SettingsColors;
import '../theme/app_theme.dart';
import 'desktop_bot_editor_ui.dart';

/// Groups consecutive turns sent by the same participant within five minutes.
bool shouldGroupBotMessage({
  required bool sameSender,
  required DateTime? previousAt,
  required DateTime? currentAt,
}) {
  if (!sameSender) return false;
  if (previousAt == null || currentAt == null) {
    return previousAt == null && currentAt == null;
  }
  return currentAt.difference(previousAt).abs() <= const Duration(minutes: 5);
}

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
    this.grouped = false,
    this.bare = false,
  });

  final bool mine;
  final String? sender;
  final Widget? avatar;
  final DateTime? sentAt;
  final Widget? quote;
  final Widget? reply;
  final List<Widget> content;
  final Widget? media;
  final bool grouped;
  final bool bare;

  String? _formatTime(BuildContext context) {
    final date = sentAt?.toLocal();
    if (date == null) return null;
    return MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(date),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
  }

  @override
  Widget build(BuildContext context) {
    final name = sender?.trim();
    final hasName = name != null && name.isNotEmpty;
    final time = _formatTime(context);
    final labelStyle = Theme.of(context).textTheme.labelMedium;
    final nameStyle = labelStyle?.copyWith(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      color: SettingsColors.textPrimary,
    );
    final timeStyle = labelStyle?.copyWith(
      fontSize: 11,
      color: SettingsColors.textQuaternary,
    );
    final alignment = mine
        ? AlignmentDirectional.centerEnd
        : AlignmentDirectional.centerStart;

    Widget bubbleContainer(Widget child, {required BorderRadiusGeometry radius}) =>
        bare
        ? child
        : DecoratedBox(
            decoration: BoxDecoration(
              color: mine ? AppColors.bubbleFill : SettingsColors.card,
              borderRadius: radius,
              border: Border.all(
                color: mine ? AppColors.bubbleBorder() : SettingsColors.stroke,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
              child: child,
            ),
          );

    final bodyColumn = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: mine && bare
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      spacing: 6,
      children: [?quote, ...content, ?media],
    );

    if (mine) {
      final showHeader = !grouped && (hasName || time != null || reply != null);
      final bubble = bubbleContainer(
        bodyColumn,
        radius: BorderRadiusDirectional.only(
          topStart: const Radius.circular(14),
          topEnd: Radius.circular(grouped ? 6 : 14),
          bottomStart: const Radius.circular(14),
          bottomEnd: const Radius.circular(4),
        ),
      );
      return Padding(
        padding: EdgeInsets.only(top: grouped ? 2 : 10, bottom: 2),
        child: Align(
          alignment: alignment,
          child: FractionallySizedBox(
            widthFactor: 0.78,
            alignment: alignment,
            child: Align(
              alignment: alignment,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (showHeader) ...[
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (reply != null) ...[
                          reply!,
                          const SizedBox(width: 4),
                        ],
                        if (hasName)
                          Flexible(
                            child: Text(
                              name,
                              style: nameStyle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        if (hasName && time != null) const SizedBox(width: 6),
                        if (time != null) Text(time, style: timeStyle),
                      ],
                    ),
                    const SizedBox(height: 4),
                  ],
                  if (grouped && reply != null)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        reply!,
                        const SizedBox(width: 4),
                        Flexible(child: bubble),
                      ],
                    )
                  else
                    bubble,
                ],
              ),
            ),
          ),
        ),
      );
    }

    final hasAvatarGutter = hasName || avatar != null;
    final showHeader = !grouped && (hasName || time != null || reply != null);
    final card = bubbleContainer(
      bodyColumn,
      radius: BorderRadiusDirectional.only(
        topStart: Radius.circular(grouped ? 6 : 4),
        topEnd: const Radius.circular(14),
        bottomStart: const Radius.circular(14),
        bottomEnd: const Radius.circular(14),
      ),
    );
    final rightColumn = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showHeader) ...[
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hasName)
                Flexible(
                  child: Text(
                    name,
                    style: nameStyle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              if (hasName && time != null) const SizedBox(width: 7),
              if (time != null) Text(time, style: timeStyle),
              if (reply != null) ...[const SizedBox(width: 4), reply!],
            ],
          ),
          const SizedBox(height: 4),
        ],
        if (grouped && reply != null)
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Flexible(child: card),
              const SizedBox(width: 4),
              reply!,
            ],
          )
        else
          card,
      ],
    );

    return Padding(
      padding: EdgeInsets.only(top: grouped ? 2 : 10, bottom: 2),
      child: Align(
        alignment: alignment,
        child: FractionallySizedBox(
          widthFactor: 0.84,
          alignment: alignment,
          child: Align(
            alignment: alignment,
            child: hasAvatarGutter
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 28,
                        child: grouped
                            ? const SizedBox.shrink()
                            : (avatar ??
                                  DesktopBotMessageAvatar(sender: name ?? '')),
                      ),
                      const SizedBox(width: 10),
                      Flexible(child: rightColumn),
                    ],
                  )
                : rightColumn,
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
  Widget build(BuildContext context) =>
      BotAvatarBadge(label: sender, emoji: emoji, size: 28);
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
          fontSize: 13.5,
          height: 1.52,
          color: narration
              ? SettingsColors.textSecondary
              : SettingsColors.textPrimary,
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
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: AppColors.code,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: SettingsColors.stroke),
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Stack(
        children: [
          PositionedDirectional(
            start: 0,
            top: 0,
            bottom: 0,
            width: 3,
            child: ColoredBox(color: AppColors.accent.withValues(alpha: 0.78)),
          ),
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(11, 6, 8, 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: SettingsColors.textSecondary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (preview.isNotEmpty) ...[
                        const SizedBox(height: 1),
                        Text(
                          preview,
                          style: TextStyle(
                            fontSize: 12,
                            color: AppColors.textMuted,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: 6),
                  trailing!,
                ],
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
