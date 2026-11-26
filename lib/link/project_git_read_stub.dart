import 'package:bao_link/bao_link.dart';

const _unavailable = LinkRemoteException(
  LinkErrors.unsupported,
  'Project Git is unavailable on this host',
);

Future<String> projectGitRepositoryKey(String root) async => throw _unavailable;

Future<Object?> readProjectGit(
  String root,
  String method,
  Map<String, Object?> params, {
  void Function()? authorizeWrite,
}) async => throw _unavailable;
