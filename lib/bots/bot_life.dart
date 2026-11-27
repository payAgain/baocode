import '../link/chat_codec.dart';

/// What a bot lives through, kept as files: one bot, one life, across its
/// chat with the user and its group chats. The app writes its timeline (all
/// it heard and said, everywhere, a line each) and the world it shares with
/// the others (WORLD.md); the bot keeps the rest (SELF.md, PEOPLE.md,
/// MEMORY.md). Its conversation is only what it has in mind now: lost to a
/// compaction or a new one, what it lived is still in its files.
abstract final class BotLife {
  /// The folder of its timeline, in its own: a file a day.
  static const timeline = 'timeline';

  /// What it thinks of each person it knows, a section each (`## name`).
  static const people = 'PEOPLE.md';

  /// The world the bots share, in the bots' folder: who everyone is, the
  /// groups, what each may do.
  static const world = 'WORLD.md';

  /// The longest line of another's words a timeline keeps: the rest is in
  /// the chat it points to.
  static const heard = 120;

  /// The longest of its own.
  static const said = 400;

  static String _two(int n) => n.toString().padLeft(2, '0');

  /// The timeline's file of [at]'s day, from the bot's folder.
  static String dayFile(DateTime at) =>
      '$timeline/${at.year}-${_two(at.month)}-${_two(at.day)}.md';

  /// A line of the timeline: at [at], in [place] (`私聊`, `群·name #seq`),
  /// [who] said [text], cut to [max].
  static String line(
    DateTime at,
    String place,
    String who,
    String text, {
    int max = heard,
  }) {
    final flat = text.replaceAll(RegExp(r'\s*\n\s*'), ' / ').trim();
    final cut = flat.length > max ? '${flat.substring(0, max)}…' : flat;
    return '- ${_two(at.hour)}:${_two(at.minute)} [$place] $who: $cut';
  }

  /// [text] (a day of a timeline) without its lines in any of [places]:
  /// null when it has none, empty when nothing else was said that day.
  static String? withoutPlaces(String text, Set<String> places) {
    final kept = <String>[];
    var dropped = false;
    var said = false;
    for (final line in text.split('\n')) {
      final place = RegExp(r'^- \d\d:\d\d \[([^\]]*)\]').firstMatch(line);
      if (place != null && places.contains(place[1])) {
        dropped = true;
        continue;
      }
      if (place != null) said = true;
      kept.add(line);
    }
    if (!dropped) return null;
    return said ? kept.join('\n') : '';
  }

  /// [text] (PEOPLE.md) without the sections of any of [names].
  static String withoutPeople(String text, Set<String> names) {
    final kept = <String>[];
    var skipping = false;
    for (final line in text.split('\n')) {
      if (line.startsWith('## ')) {
        skipping = names.contains(line.substring(3).trim());
      }
      if (!skipping) kept.add(line);
    }
    return kept.join('\n');
  }

  /// [text] (SELF.md) without its `Now:` line.
  static String withoutNow(String text) => [
    for (final line in text.trim().split('\n'))
      if (!line.startsWith('Now:')) line,
  ].join('\n').trim();

  /// The current state is intentionally separate from long-lived self facts.
  static String nowOf(String text) => [
    for (final line in text.trim().split('\n'))
      if (line.startsWith('Now:')) line,
  ].join('\n');

  static List<String> selfFacts(String text) =>
      _noteFragments(withoutNow(text));

  /// Parse headings in order, keeping repeated names as separate sections.
  /// An unlabelled preface and empty sections survive the migration as well.
  static List<({String? person, List<String> fragments})> peopleFacts(
    String text,
  ) {
    final sections = <({String? person, List<String> fragments})>[];
    final lines = <String>[];
    String? person;
    void finish() {
      final fragments = _noteFragments(lines.join('\n'));
      if (person != null || fragments.isNotEmpty) {
        sections.add((person: person, fragments: fragments));
      }
      lines.clear();
    }

    for (final line in text.trim().split('\n')) {
      if (line.startsWith('## ') && line.substring(3).trim().isNotEmpty) {
        finish();
        person = line.substring(3).trim();
      } else {
        lines.add(line);
      }
    }
    finish();
    return sections;
  }

  static List<String> _noteFragments(String text) {
    final notes = <String>[];
    final lines = <String>[];
    void finish() {
      final note = lines.join('\n').trim();
      if (note.isNotEmpty) notes.add(note);
      lines.clear();
    }

    final rawLines = text.split('\n');
    for (var i = 0; i < rawLines.length; i++) {
      final line = rawLines[i];
      if (line.startsWith('- ')) {
        finish();
        lines.add(line);
        continue;
      }
      if (line.trim().isEmpty) {
        if (lines.isNotEmpty && lines.first.startsWith('- ')) {
          var next = i + 1;
          while (next < rawLines.length && rawLines[next].trim().isEmpty) {
            next++;
          }
          if (next < rawLines.length && rawLines[next].startsWith('  ')) {
            lines.add('  ');
            continue;
          }
        }
        finish();
        continue;
      }
      lines.add(line);
    }
    finish();
    return notes;
  }

  /// A bot's reply [text] as its timeline has it: its messages, not its
  /// narration nor how they sound.
  static String saysOf(String text) => ChatCodec.botSays(text).join(' / ');

  /// [text] (PEOPLE.md) with [note] added under [who]'s section, made if
  /// it has none.
  static String withPersonNote(String text, String who, String note) {
    final name = who.trim();
    final line = '- ${note.trim()}';
    final lines = text.trimRight().isEmpty
        ? <String>[]
        : text.trimRight().split('\n');
    final heading = '## $name';
    final at = lines.indexWhere((l) => l.trim() == heading);
    if (at < 0) {
      return [...lines, if (lines.isNotEmpty) '', heading, line].join('\n');
    }
    var end = at + 1;
    while (end < lines.length && !lines[end].startsWith('## ')) {
      end++;
    }
    // After its last line, not the blank ones before the next.
    while (end > at + 1 && lines[end - 1].trim().isEmpty) {
      end--;
    }
    lines.insert(end, line);
    return lines.join('\n');
  }

  /// [text] (SELF.md) with its `Now:` line, how it is and what it is up to
  /// now, [now]: the one before gone, this one first.
  static String withNow(String text, String now) => [
    'Now: ${now.trim()}',
    for (final line in text.trim().split('\n'))
      if (line.trim().isNotEmpty && !line.startsWith('Now:')) line,
  ].join('\n');
}
