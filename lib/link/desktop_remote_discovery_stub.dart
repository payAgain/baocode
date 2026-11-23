import 'package:bao_link/bao_link.dart';

bool get desktopRemoteDiscoverySupported => false;

Stream<List<LinkAdvert>> discoverDesktopRemoteHosts() => const Stream.empty();
