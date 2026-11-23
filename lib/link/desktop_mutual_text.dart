import 'package:flutter/widgets.dart';

/// Copy shared by the two ends of the consent screen.
class DesktopMutualText {
  DesktopMutualText(BuildContext context)
    : _zh = Localizations.localeOf(context).languageCode == 'zh';

  final bool _zh;
  String get option => _zh ? '配对并互相访问工作区' : 'Pair with mutual workspace access';
  String get enableLocally => _zh
      ? '请先在这台电脑的「设置 → 手机」打开连接，再返回此处配对。'
      : 'First allow connections in Settings → Mobile on this computer, then return here to pair.';
  String get risk => _zh
      ? '这不是只读共享。双方都能使用 BaoCode 工作区操作，包括运行 Agent、处理批准请求和访问项目之外的文件。只与完全信任的人配对。'
      : 'This is not read-only. Both computers can use BaoCode workspace operations, including running agents, responding to approvals, and accessing files outside projects. Pair only with someone you fully trust.';
  String get forward => _zh ? '发起连接校验码' : 'Initial connection code';
  String get reverse => _zh ? '反向连接校验码' : 'Return connection code';
  String get approve => _zh ? '信任双方电脑' : 'Trust both computers';
  String get confirm =>
      _zh ? '校验码一致，信任双方电脑' : 'Codes match, trust both computers';
  String get compare => _zh
      ? '请核对两台电脑上对应的两组校验码，双方都须确认。'
      : 'Compare both matching codes on the two computers. Both owners must confirm.';
  String get connecting =>
      _zh ? '正在完成双向连接…' : 'Finishing the mutual connection…';
  String get waiting => _zh
      ? '等待另一台电脑确认并完成连接…'
      : 'Waiting for the other computer to confirm and finish connecting…';
  String get ready => _zh ? '双向工作区访问已就绪' : 'Mutual workspace access is ready';
  String get incomplete => _zh
      ? '双向配对未完成，或无法确认权限已保存或撤销。请检查两台电脑的共享权限，再重试。'
      : 'Mutual pairing did not finish, or an access change could not be verified. Check sharing on both computers before retrying.';
  String get cancelled => _zh ? '已取消双向配对。' : 'Mutual pairing cancelled.';
  String get shares => _zh ? '电脑工作区访问' : 'Computer workspace access';
  String get target => _zh
      ? '连接这台电脑：远程工作区 → 电脑。取消此处的共享只会移除对本机的访问。'
      : 'To open the other computer, choose it in Remote workspace → Computers. Removing sharing here only revokes access to this computer.';
  String get inbound =>
      _zh ? '可以访问这台电脑的工作区' : 'Can access this computer’s workspace';
  String get revoke => _zh ? '停止共享' : 'Stop sharing';
  String request(String name) =>
      _zh ? '$name 请求互相访问工作区' : '$name requests mutual workspace access';
}
