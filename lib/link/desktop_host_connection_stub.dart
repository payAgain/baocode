import 'package:bao_link/bao_link.dart';

Future<LinkNode> bindDesktopHostClient(
  LinkIdentity identity,
  List<String> relays,
) async =>
    throw UnsupportedError('Desktop host connections require BaoCode desktop.');

Future<DeviceInfo> desktopHostClientDevice() async =>
    throw UnsupportedError('Desktop host connections require BaoCode desktop.');
