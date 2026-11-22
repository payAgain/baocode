import 'dart:async';

import 'package:flutter/foundation.dart';

import '../settings/user_settings.dart';
import 'update_channel.dart';
import 'update_service.dart';

/// What the updates keep across runs, in the app's global storage
/// (state/storage.json): the version the user skipped, when the app last
/// looked, and the version an install was started for as it quit.
class GlobalUpdateStore implements UpdateStore {
  GlobalUpdateStore(this.storage, {this.channel = UpdateChannel.official});

  final GlobalStorage storage;
  final UpdateChannel channel;

  static const skippedKey = 'update.skippedVersion';
  static const lastCheckedKey = 'update.lastChecked';
  static const installingKey = 'update.installingVersion';

  String _key(String base) =>
      channel == UpdateChannel.personal ? '$base.personal' : base;

  @override
  String? get skippedVersion => storage.get<String>(_key(skippedKey));

  @override
  set skippedVersion(String? version) => _set(_key(skippedKey), version);

  @override
  DateTime? get lastChecked =>
      switch (storage.get<String>(_key(lastCheckedKey))) {
        final text? => DateTime.tryParse(text)?.toLocal(),
        null => null,
      };

  @override
  set lastChecked(DateTime? time) =>
      _set(_key(lastCheckedKey), time?.toUtc().toIso8601String());

  @override
  String? get installingVersion => storage.get<String>(_key(installingKey));

  @override
  Future<void> setInstallingVersion(String? version) =>
      storage.set(_key(installingKey), version);

  void _set(String key, Object? value) => unawaited(
    storage.set(key, value).catchError((Object error) {
      debugPrint('$key not kept: $error');
    }),
  );
}
