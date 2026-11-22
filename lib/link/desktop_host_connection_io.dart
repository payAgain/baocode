import 'package:bao_link/bao_link_io.dart';

import 'link_platform.dart';

Future<LinkNode> bindDesktopHostClient(
  LinkIdentity identity,
  List<String> relays,
) => IrohLinkNode.bind(identity: identity, relays: relays);

Future<DeviceInfo> desktopHostClientDevice() =>
    LinkPlatform.current()!.device();
