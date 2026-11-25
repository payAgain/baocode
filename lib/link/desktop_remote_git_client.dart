import 'package:bao_link/bao_link.dart';

class RemoteGitFile {
  const RemoteGitFile({
    required this.path,
    this.originalPath,
    required this.status,
    required this.group,
  });

  factory RemoteGitFile.fromJson(Map<String, Object?> json) => RemoteGitFile(
    path: json['path'] as String,
    originalPath: json['originalPath'] as String?,
    status: json['status'] as String,
    group: json['group'] as String,
  );

  final String path;
  final String? originalPath;
  final String status;
  final String group;

  Map<String, Object?> toJson() => {
    'path': path,
    'originalPath': ?originalPath,
    'status': status,
    'group': group,
  };
}

class RemoteGitStatus {
  const RemoteGitStatus({
    this.branch,
    this.head,
    required this.files,
    required this.truncated,
  });

  factory RemoteGitStatus.fromJson(Map<String, Object?> json) =>
      RemoteGitStatus(
        branch: json['branch'] as String?,
        head: json['head'] as String?,
        files: _files(json),
        truncated: json['truncated'] as bool,
      );

  final String? branch;
  final String? head;
  final List<RemoteGitFile> files;
  final bool truncated;
}

class RemoteGitCommit {
  const RemoteGitCommit({
    required this.hash,
    required this.shortHash,
    required this.subject,
    required this.authorName,
    this.authorDate,
    this.parentIds = const [],
    this.refs = const [],
  });

  factory RemoteGitCommit.fromJson(Map<String, Object?> json) =>
      RemoteGitCommit(
        hash: json['hash'] as String,
        shortHash: json['shortHash'] as String,
        subject: json['subject'] as String,
        authorName: json['authorName'] as String,
        authorDate: DateTime.tryParse(json['authorDate'] as String? ?? ''),
        parentIds: List<String>.unmodifiable(json['parentIds'] as List),
        refs: List<String>.unmodifiable(json['refs'] as List),
      );

  final String hash;
  final String shortHash;
  final String subject;
  final String authorName;
  final DateTime? authorDate;
  final List<String> parentIds;
  final List<String> refs;

  Map<String, Object?> toJson() => {
    'hash': hash,
    'shortHash': shortHash,
    'subject': subject,
    'authorName': authorName,
    'authorDate': ?authorDate?.toIso8601String(),
    'parentIds': parentIds,
    'refs': refs,
  };
}

class RemoteGitHistory {
  const RemoteGitHistory({required this.commits, required this.truncated});

  factory RemoteGitHistory.fromJson(Map<String, Object?> json) =>
      RemoteGitHistory(
        commits: List.unmodifiable([
          for (final item in json['commits'] as List)
            RemoteGitCommit.fromJson(item as Map<String, Object?>),
        ]),
        truncated: json['truncated'] as bool,
      );

  final List<RemoteGitCommit> commits;
  final bool truncated;
}

class RemoteGitCommitFiles {
  const RemoteGitCommitFiles({required this.files, required this.truncated});

  factory RemoteGitCommitFiles.fromJson(Map<String, Object?> json) =>
      RemoteGitCommitFiles(
        files: _files(json),
        truncated: json['truncated'] as bool,
      );

  final List<RemoteGitFile> files;
  final bool truncated;
}

List<RemoteGitFile> _files(Map<String, Object?> json) => List.unmodifiable([
  for (final item in json['files'] as List)
    RemoteGitFile.fromJson(item as Map<String, Object?>),
]);

class RemoteGitDiff {
  const RemoteGitDiff({required this.text, required this.truncated});

  factory RemoteGitDiff.fromJson(Map<String, Object?> json) => RemoteGitDiff(
    text: json['text'] as String,
    truncated: json['truncated'] as bool,
  );

  final String text;
  final bool truncated;
}

/// The read-only project Git methods on an already authorized desktop peer.
class DesktopRemoteGitClient {
  const DesktopRemoteGitClient(this.peer);

  final LinkPeer peer;

  Future<RemoteGitStatus?> status(String project) => _call(
    LinkMethods.projectGitStatus,
    {'project': project},
    RemoteGitStatus.fromJson,
  );

  Future<RemoteGitHistory?> history(String project, {int limit = 50}) => _call(
    LinkMethods.projectGitHistory,
    {'project': project, 'limit': limit},
    RemoteGitHistory.fromJson,
  );

  Future<RemoteGitCommitFiles?> commitFiles(String project, String revision) =>
      _call(LinkMethods.projectGitCommitFiles, {
        'project': project,
        'revision': revision,
      }, RemoteGitCommitFiles.fromJson);

  Future<RemoteGitDiff?> workingDiff(
    String project,
    String path, {
    bool staged = false,
  }) => _call(LinkMethods.projectGitWorkingDiff, {
    'project': project,
    'path': path,
    'staged': staged,
  }, RemoteGitDiff.fromJson);

  Future<RemoteGitDiff?> commitDiff(
    String project,
    String revision,
    String path,
  ) => _call(LinkMethods.projectGitCommitDiff, {
    'project': project,
    'revision': revision,
    'path': path,
  }, RemoteGitDiff.fromJson);

  Future<T?> _call<T>(
    String method,
    Map<String, Object?> params,
    T Function(Map<String, Object?>) decode,
  ) async {
    try {
      final result = await peer.call(method, params);
      return decode(result as Map<String, Object?>);
    } on LinkRemoteException catch (error) {
      if (error.code == LinkErrors.unknown ||
          error.code == LinkErrors.unsupported) {
        return null;
      }
      rethrow;
    }
  }
}
