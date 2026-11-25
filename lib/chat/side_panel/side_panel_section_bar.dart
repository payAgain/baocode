import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../ide/ide_hover.dart';
import '../../ide/ide_list.dart';
import '../../keybindings/keybinding_service.dart';
import '../../theme/svg_icons.dart' show AppIcon;
import '../../workspace/islands.dart';

class SidePanelSectionEntry {
  const SidePanelSectionEntry({
    required this.key,
    required this.icon,
    required this.label,
    required this.onTap,
    required this.selected,
    this.command,
    this.count = 0,
  });

  final Key key;
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;
  final String? command;
  final int count;
}

/// Browser-style section tabs shared by the local and remote chat panels.
/// Each tab keeps its icon, badge and accessible label when space is short.
class SidePanelSectionBar extends StatelessWidget {
  const SidePanelSectionBar({
    super.key,
    required this.sections,
    required this.color,
    this.inset = 0,
    this.leading,
    this.trailing,
  });

  final List<SidePanelSectionEntry> sections;
  final Color color;
  final double inset;
  final Widget? leading;
  final Widget? trailing;

  double _tabsWidth(BuildContext context, {required bool compact}) {
    final inherited = DefaultTextStyle.of(context).style;
    final scaler = MediaQuery.textScalerOf(context);
    double measure(String text, TextStyle style) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: inherited.merge(style)),
        maxLines: 1,
        textDirection: Directionality.of(context),
        textScaler: scaler,
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width;
    }

    var width = 0.0;
    for (final section in sections) {
      width +=
          2 * _SectionTab.padding + _SectionTab.iconSize + _SectionTab.spacing;
      if (!compact) {
        width +=
            _SectionTab.gap + measure(section.label, _SectionTab.labelStyle);
      }
      if (section.count > 0) {
        width +=
            _SectionTab.gap +
            math.max(
              16,
              2 * 4 +
                  measure(
                    IdeTitleBadge.text(section.count),
                    IdeTitleBadge.style,
                  ),
            );
      }
    }
    return width;
  }

  @override
  Widget build(BuildContext context) {
    final padded = inset > 0 || leading != null;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: inset),
        if (leading case final leading?) ...[
          Center(child: leading),
          const SizedBox(width: 6),
        ],
        if (padded) const SizedBox(width: IslandTab.lead),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final room = constraints.maxWidth;
              final compact = room < _tabsWidth(context, compact: false);
              final tabs = Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (i, section) in sections.indexed) ...[
                    if (i > 0)
                      IslandTabSeparator(
                        shown: !section.selected && !sections[i - 1].selected,
                        width: _SectionTab.spacing,
                      ),
                    _SectionTab(
                      entry: section,
                      atStart: i == 0 && !padded,
                      color: color,
                      compact: compact,
                    ),
                  ],
                  const SizedBox(width: _SectionTab.spacing),
                ],
              );
              if (compact && room < _tabsWidth(context, compact: true)) {
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: tabs,
                );
              }
              return Align(
                alignment: AlignmentDirectional.centerStart,
                child: tabs,
              );
            },
          ),
        ),
        ?trailing,
      ],
    );
  }
}

class _SectionTab extends StatelessWidget {
  const _SectionTab({
    required this.entry,
    required this.atStart,
    required this.color,
    required this.compact,
  });

  final SidePanelSectionEntry entry;
  final bool atStart;
  final Color color;
  final bool compact;

  static const padding = 12.0;
  static const iconSize = 13.0;
  static const gap = 6.0;

  /// Room for the selected tab's foot and the divider between unselected tabs.
  static const spacing = 2.0;
  static const labelStyle = TextStyle(fontSize: 12);

  @override
  Widget build(BuildContext context) => IdeHover(
    message: switch (entry.command) {
      final command? => KeybindingService.instance.titleWithKeybinding(
        entry.label,
        command,
      ),
      null => entry.label,
    },
    child: Semantics(
      button: true,
      selected: entry.selected,
      label: entry.label,
      value: entry.count > 0 ? '${entry.count}' : null,
      onTap: entry.onTap,
      excludeSemantics: true,
      child: IslandTab(
        key: entry.key,
        active: entry.selected,
        atStart: atStart,
        color: color,
        onTap: entry.onTap,
        builder: (context, foreground) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: padding),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppIcon(entry.icon, size: iconSize, color: foreground),
              if (!compact) ...[
                const SizedBox(width: gap),
                Text(
                  entry.label,
                  maxLines: 1,
                  style: labelStyle.copyWith(color: foreground),
                ),
              ],
              if (entry.count > 0) ...[
                const SizedBox(width: gap),
                IdeTitleBadge(entry.count),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}
