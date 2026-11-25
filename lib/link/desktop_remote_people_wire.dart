part of 'desktop_remote_people.dart';

const _botText = ['name', 'gender', 'signature', 'identity', 'style'];
const _proactiveFields = ['perDay', 'quietFrom', 'quietTo'];
const _botFlags = ['chatOnly', 'writesFirst'];
const _groupOptions = ['passes', 'rules', 'gap'];
const _leadOption = 'lead';
const _imageTypes = {'image/png', 'image/jpeg', 'image/gif', 'image/webp'};

// Decoded models fill in defaults when a key is absent. Keep the raw rows
// to distinguish a wire advertisement from a local default.
class _PeopleCatalog {
  _PeopleCatalog(
    Map<String, Object?> json, {
    required Set<String> observedGroupOptions,
    required Set<String> observedBotFlags,
  }) : botRows = _rows(json, 'bots'),
       groupRows = _rows(json, 'groups') {
    if (json['device'] is! Map<String, Object?>) {
      throw _PeopleProblem.unavailable;
    }
    final advertisedGroupOptions =
        _stringList(json['groupOptions']) ?? const [];
    if (advertisedGroupOptions.contains(_leadOption) ||
        groups.any(
          (row) =>
              row.containsKey(_leadOption) &&
              (row[_leadOption] == null || _groupLead(row) != null),
        )) {
      observedGroupOptions.add(_leadOption);
    }
    for (final option in _groupOptions) {
      if (advertisedGroupOptions.contains(option) ||
          groups.any(
            (row) =>
                option == 'rules' ? row[option] is String : row[option] is int,
          )) {
        observedGroupOptions.add(option);
      }
    }
    for (final flag in _botFlags) {
      if (bots.any((row) => row[flag] is bool)) observedBotFlags.add(flag);
    }
    groupOptions = Set.unmodifiable(observedGroupOptions);
    botFlags = Set.unmodifiable(observedBotFlags);
    botMemoryOptions = Set.unmodifiable(
      _stringList(json['botMemoryOptions']) ?? const [],
    );
  }

  final Map<String, Map<String, Object?>> botRows;
  final Map<String, Map<String, Object?>> groupRows;
  late final Set<String> groupOptions;
  late final Set<String> botFlags;
  late final Set<String> botMemoryOptions;

  bool get hasBots => botRows.isNotEmpty;
  Iterable<Map<String, Object?>> get bots => botRows.values;
  Iterable<Map<String, Object?>> get groups => groupRows.values;
  bool botFlag(String key) => botFlags.contains(key);
  bool groupOption(String key) => groupOptions.contains(key);

  static Map<String, Map<String, Object?>> _rows(
    Map<String, Object?> json,
    String key,
  ) {
    final value = json[key];
    if (value == null) return {};
    if (value is! List) throw _PeopleProblem.unavailable;
    final result = <String, Map<String, Object?>>{};
    for (final item in value) {
      if (item is! Map<String, Object?> ||
          item['id'] is! String ||
          (item['id'] as String).isEmpty ||
          item['name'] is! String ||
          result.containsKey(item['id'])) {
        throw _PeopleProblem.unavailable;
      }
      result[item['id'] as String] = item;
    }
    return result;
  }
}

enum _PeopleProblem {
  offline,
  unavailable,
  conflict,
  invalid,
  badPicture,
  unconfirmed,
  stopped,
}

enum _PeopleKind { bot, group, profile, memory }

class _PeopleDraft {
  _PeopleDraft(this.kind, {this.id, this.base = const {}});

  final _PeopleKind kind;
  final String? id;
  Map<String, Object?> base;
  final text = <String, String>{};
  final flags = <String, bool>{};
  final abilities = <String>{};
  final members = <String>{};
  final groupOptions = <String>{};
  bool canEditLead = false;
  String? lead;
  List<String> get initialAbilities => _stringList(base['abilities']) ?? [];
  List<String> get initialMembers => _stringList(base['members']) ?? [];
  bool get selfAdvertised => base['self'] is String;
  bool get canEditBot => id == null || _validBotSettings(base);
  bool get canEditGroup => id == null || _stringList(base['members']) != null;
  bool get changedGroup =>
      id == null ||
      text['name']?.trim() != name ||
      !setEquals(members, initialMembers.toSet()) ||
      (canEditLead && lead != _groupLead(base)) ||
      groupOptions.any((key) => text[key] != '${_groupValue(base, key)}');
  bool get assistant => id == 'assistant' || base['assistant'] == true;
  String get name => _text(base, 'name');

  ImageAttachment? hostPicture;
  ImageAttachment? pickedPicture;
  bool replaceAvatar = false;
  int avatarFieldVersion = 0;

  factory _PeopleDraft.bot(_PeopleCatalog catalog, [String? id]) {
    final base = id == null
        ? const <String, Object?>{}
        : catalog.botRows[id] ?? (throw _PeopleProblem.conflict);
    final draft = _PeopleDraft(_PeopleKind.bot, id: id, base: base);
    for (final key in _botText) {
      draft.text[key] = _text(base, key);
    }
    final avatar = base['avatar'];
    draft.text['avatar'] = avatar is String && !isAvatarImage(avatar)
        ? avatar
        : '';
    draft.abilities.addAll(draft.initialAbilities);
    final proactive = _proactive(base);
    for (final key in _proactiveFields) {
      draft.text[key] = '${proactive[key]}';
    }
    for (final key in _botFlags) {
      if (catalog.botFlag(key)) draft.flags[key] = _flag(base, key);
    }
    return draft;
  }

  factory _PeopleDraft.group(_PeopleCatalog catalog, [String? id]) {
    final base = id == null
        ? const <String, Object?>{}
        : catalog.groupRows[id] ?? (throw _PeopleProblem.conflict);
    final draft = _PeopleDraft(_PeopleKind.group, id: id, base: base);
    draft.text['name'] = draft.name;
    draft.members.addAll(draft.initialMembers);
    draft.canEditLead = catalog.groupOption(_leadOption);
    draft.lead = _groupLead(base);
    for (final key in _groupOptions) {
      if (catalog.groupOption(key)) {
        draft.groupOptions.add(key);
        draft.text[key] = '${_groupValue(base, key)}';
      }
    }
    return draft;
  }

  factory _PeopleDraft.memory(String id, Map<String, Object?> base) {
    final draft = _PeopleDraft(_PeopleKind.memory, id: id, base: base);
    draft.text['text'] = _text(base, 'text');
    if (draft.selfAdvertised) draft.text['self'] = _text(base, 'self');
    return draft;
  }

  Map<String, Object?> get profile => {
    for (final key in ['name', 'gender', 'signature'])
      key: (text[key] ?? '').trim(),
    if (pickedPicture case final picture?) 'picture': _pictureJson(picture),
  };

  bool get changedBot =>
      id == null ||
      _botText.any((key) => (text[key] ?? '').trim() != _text(base, key)) ||
      replaceAvatar ||
      !setEquals(abilities, initialAbilities.toSet()) ||
      flags.entries.any((entry) => entry.value != _flag(base, entry.key)) ||
      _proactiveFields.any((key) => text[key] != '${_proactive(base)[key]}');

  Map<String, Object?> botParams(_PeopleCatalog fresh) {
    if (!fresh.hasBots) throw _PeopleProblem.unavailable;
    final latest = id == null
        ? const <String, Object?>{}
        : fresh.botRows[id] ?? (throw _PeopleProblem.conflict);
    if (id != null && !_validBotSettings(latest)) {
      throw _PeopleProblem.unavailable;
    }
    final params = <String, Object?>{if (id != null) 'bot': id};
    for (final key in _botText) {
      final before = _text(base, key);
      final now = _text(latest, key);
      final value = (text[key] ?? '').trim();
      final merged = _merge(before, now, value);
      if (id == null || latest.containsKey(key) || merged.isNotEmpty) {
        params[key] = merged;
      }
    }
    if (params['name'] == '') throw _PeopleProblem.invalid;
    final beforeAbilities = initialAbilities.toSet();
    final latestAbilities = _stringList(latest['abilities']) ?? [];
    // Apply only the toggles the user changed. Keep newer/unknown abilities.
    params['abilities'] = [
      for (final ability in latestAbilities)
        if (!beforeAbilities.contains(ability) || abilities.contains(ability))
          ability,
      for (final ability in abilities.difference(beforeAbilities))
        if (!latestAbilities.contains(ability)) ability,
    ];
    final before = _proactive(base);
    final current = _proactive(latest);
    params['proactive'] = <String, Object?>{
      ...current,
      for (final key in _proactiveFields)
        if (text[key] != '${before[key]}')
          key: _merge(
            before[key],
            current[key],
            _number(text[key], max: key == 'perDay' ? null : 1439),
          ),
    };
    for (final entry in flags.entries) {
      if (entry.value == _flag(base, entry.key)) continue;
      if (!fresh.botFlag(entry.key)) throw _PeopleProblem.unavailable;
      params[entry.key] = entry.value;
    }
    if (!replaceAvatar) {
      if (latest['avatar'] case final String token) params['avatar'] = token;
    } else {
      if (latest['avatar'] != base['avatar']) throw _PeopleProblem.conflict;
      if (pickedPicture case final picture?) {
        params['avatarImage'] = _pictureJson(picture);
      } else {
        final avatar = (text['avatar'] ?? '').trim();
        if (isAvatarImage(avatar)) throw _PeopleProblem.invalid;
        // Empty is intentional: the host removes its old picture or emoji.
        params['avatar'] = avatar;
      }
    }
    return params;
  }

  Map<String, Object?> groupParams(_PeopleCatalog fresh) {
    if (!fresh.hasBots) throw _PeopleProblem.unavailable;
    final latest = id == null
        ? const <String, Object?>{}
        : fresh.groupRows[id] ?? (throw _PeopleProblem.conflict);
    final oldMembers = id == null
        ? const <String>[]
        : _stringList(latest['members']) ?? (throw _PeopleProblem.unavailable);
    final current = [
      for (final member in oldMembers)
        if (!initialMembers.contains(member) || members.contains(member))
          member,
      for (final member in members)
        if (!initialMembers.contains(member) && !oldMembers.contains(member))
          member,
    ];
    if (current.any((member) => !fresh.botRows.containsKey(member))) {
      throw _PeopleProblem.conflict;
    }
    final name = _merge(this.name, _text(latest, 'name'), text['name']!.trim());
    if (name.isEmpty || (id == null && current.isEmpty)) {
      throw _PeopleProblem.invalid;
    }
    final params = <String, Object?>{
      if (id != null) 'group': id,
      'name': name,
      'members': current,
    };
    for (final key in groupOptions) {
      final before = _groupValue(base, key);
      final value = key == 'rules'
          ? text[key]!.trim()
          : _number(text[key], max: key == 'passes' ? 1 << 20 : null);
      if (key == 'passes' && value is int && value == 1) {
        throw _PeopleProblem.invalid;
      }
      if (value == before) continue;
      if (!fresh.groupOption(key)) throw _PeopleProblem.unavailable;
      params[key] = _merge(before, _groupValue(latest, key), value);
    }
    final beforeLead = _groupLead(base);
    if (canEditLead && lead != beforeLead) {
      if (!fresh.groupOption(_leadOption)) throw _PeopleProblem.unavailable;
      final next = _merge(beforeLead, _groupLead(latest), lead);
      if (next != null && !current.contains(next)) {
        throw _PeopleProblem.conflict;
      }
      params[_leadOption] = next;
    }
    return params;
  }
}

// Intact settings, not just a summary row. Sending saveBot without these
// would cause the host to replace identity, abilities and proactive policy.
bool _validBotSettings(Map<String, Object?> row) =>
    row['name'] is String &&
    row['identity'] is String &&
    _stringList(row['abilities']) != null &&
    row['proactive'] is Map<String, Object?> &&
    _proactiveFields.every(
      (key) => (row['proactive'] as Map<String, Object?>)[key] is int,
    ) &&
    [
      'avatar',
      'gender',
      'signature',
      'style',
    ].every((key) => row[key] == null || row[key] is String);

String _text(Map<String, Object?> row, String key) => switch (row[key]) {
  final String value => value,
  _ => '',
};

List<String>? _stringList(Object? value) =>
    value is List && value.every((element) => element is String)
    ? List<String>.from(value)
    : null;

Map<String, Object?> _proactive(Map<String, Object?> row) =>
    switch (row['proactive']) {
      final Map<String, Object?> value => {
        ...const BotProactive().toJson(),
        ...value,
      },
      _ => const BotProactive().toJson(),
    };

bool _flag(Map<String, Object?> row, String key) =>
    key == 'chatOnly' ? row[key] == true : row[key] != false;

Object _groupValue(Map<String, Object?> row, String key) => switch (key) {
  'rules' => _text(row, key),
  'passes' => row[key] is int ? row[key]! : linkGroupPasses,
  _ => row[key] is int ? row[key]! : 0,
};

String? _groupLead(Map<String, Object?> row) => switch (row[_leadOption]) {
  final String id when id.isNotEmpty => id,
  _ => null,
};

T _merge<T>(T before, T current, T requested) {
  if (before == requested) return current;
  if (before != current && current != requested) throw _PeopleProblem.conflict;
  return requested;
}

int _number(String? input, {int? max}) {
  final value = int.tryParse(input?.trim() ?? '');
  if (value == null || value < 0 || (max != null && value > max)) {
    throw _PeopleProblem.invalid;
  }
  return value;
}

bool _validPicture(ImageAttachment picture) =>
    _imageTypes.contains(picture.mediaType) &&
    picture.bytes.isNotEmpty &&
    picture.bytes.length <= LinkLimits.avatar;

Map<String, Object?> _pictureJson(ImageAttachment picture) {
  if (!_validPicture(picture)) throw _PeopleProblem.badPicture;
  return {'type': picture.mediaType, 'data': base64Encode(picture.bytes)};
}

ImageAttachment? _decodePicture(Object? value) {
  if (value case {'type': final String type, 'data': final String data}
      when _imageTypes.contains(type) &&
          data.length <= ((LinkLimits.avatar + 2) ~/ 3) * 4) {
    try {
      final picture = ImageAttachment(
        bytes: base64Decode(data),
        mediaType: type,
      );
      if (_validPicture(picture)) return picture;
    } on FormatException {
      // Nothing is displayed from a malformed host response.
    }
  }
  return null;
}
