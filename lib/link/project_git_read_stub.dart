import 'package:bao_link/bao_link.dart';

Future<Object?> readProjectGit(
  String root,
  String method,
  Map<String, Object?> params,
) async => throw const LinkRemoteException(
  LinkErrors.unsupported,
  'Project Git is unavailable on this host',
);
