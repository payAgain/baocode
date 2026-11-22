import 'update_channel.dart';
import 'update_service.dart';

/// No updates where there is no dart:io (the web).
PlatformUpdates? platformUpdates({
  required String updatesDirectory,
  UpdateChannel? channel,
  bool releaseMode = false,
  Map<String, String>? environment,
}) => null;

/// What updates the app where it runs (installer_io.dart's).
class PlatformUpdates {
  const PlatformUpdates({
    required this.platform,
    required this.manifestUrl,
    required this.channel,
    required this.backend,
    required this.installer,
  });

  final String platform;
  final Uri manifestUrl;
  final UpdateChannel channel;
  final UpdateBackend backend;
  final UpdateInstaller installer;
}
