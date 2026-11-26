import 'dart:async';

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
    this.state,
    required this.files,
    required this.truncated,
  });

  factory RemoteGitStatus.fromJson(Map<String, Object?> json) =>
      RemoteGitStatus(
        branch: json['branch'] as String?,
        head: json['head'] as String?,
        state: json['state'] as String?,
        files: _files(json),
        truncated: json['truncated'] as bool,
      );

  final String? branch;
  final String? head;
  final String? state;
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
  const RemoteGitHistory({
    required this.commits,
    required this.truncated,
    this.nextOffset,
  });

  factory RemoteGitHistory.fromJson(Map<String, Object?> json) =>
      RemoteGitHistory(
        commits: List.unmodifiable([
          for (final item in json['commits'] as List)
            RemoteGitCommit.fromJson(item as Map<String, Object?>),
        ]),
        truncated: json['truncated'] as bool,
        nextOffset: json['nextOffset'] as int?,
      );

  final List<RemoteGitCommit> commits;
  final bool truncated;
  final int? nextOffset;
}

class RemoteGitCapabilities {
  const RemoteGitCapabilities({
    required this.branches,
    required this.canWrite,
    required this.canPush,
  });

  factory RemoteGitCapabilities.fromJson(Map<String, Object?> json) =>
      RemoteGitCapabilities(
        branches: List<String>.unmodifiable(json['branches'] as List),
        canWrite: json['canWrite'] as bool,
        canPush: json['canPush'] as bool,
      );

  final List<String> branches;
  final bool canWrite;
  final bool canPush;
}

class RemoteGitStash {
  const RemoteGitStash({required this.id, required this.message, this.date});

  factory RemoteGitStash.fromJson(Map<String, Object?> json) => RemoteGitStash(
    id: json['id'] as String,
    message: json['message'] as String,
    date: DateTime.tryParse(json['date'] as String? ?? ''),
  );

  final String id;
  final String message;
  final DateTime? date;
}

class RemoteGitStashes {
  const RemoteGitStashes({required this.entries, required this.truncated});

  factory RemoteGitStashes.fromJson(Map<String, Object?> json) =>
      RemoteGitStashes(
        entries: List.unmodifiable([
          for (final item in json['entries'] as List)
            RemoteGitStash.fromJson(item as Map<String, Object?>),
        ]),
        truncated: json['truncated'] as bool,
      );

  final List<RemoteGitStash> entries;
  final bool truncated;
}

class RemoteGitCommitResult {
  const RemoteGitCommitResult({
    required this.head,
    required this.pushed,
    this.pushError,
  });

  factory RemoteGitCommitResult.fromJson(Map<String, Object?> json) =>
      RemoteGitCommitResult(
        head: json['head'] as String,
        pushed: json['pushed'] as bool,
        pushError: json['pushError'] as String?,
      );

  final String head;
  final bool pushed;
  final String? pushError;
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

/// Scoped project Git operations on an already authorized desktop peer.
class DesktopRemoteGitClient {
  const DesktopRemoteGitClient(this.peer);

  final LinkPeer peer;

  Future<RemoteGitStatus?> status(String project) => _call(
    LinkMethods.projectGitStatus,
    {'project': project},
    RemoteGitStatus.fromJson,
  );

  Future<RemoteGitCapabilities?> capabilities(String project) => _call(
    LinkMethods.projectGitCapabilities,
    {'project': project},
    RemoteGitCapabilities.fromJson,
  );

  Future<RemoteGitHistory?> history(
    String project, {
    int limit = 50,
    int offset = 0,
    String? branch,
    String? path,
    String? author,
    DateTime? since,
    DateTime? until,
    String? search,
  }) => _call(LinkMethods.projectGitHistory, {
    'project': project,
    'limit': limit,
    if (offset != 0) 'offset': offset,
    'branch': ?branch,
    'path': ?path,
    'author': ?author,
    'since': ?since?.toUtc().toIso8601String(),
    'until': ?until?.toUtc().toIso8601String(),
    'search': ?search,
  }, RemoteGitHistory.fromJson);

  Future<RemoteGitCommitFiles?> commitFiles(
    String project,
    String revision, {
    String? branch,
  }) => _call(LinkMethods.projectGitCommitFiles, {
    'project': project,
    'revision': revision,
    'branch': ?branch,
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
    String path, {
    String? branch,
  }) => _call(LinkMethods.projectGitCommitDiff, {
    'project': project,
    'revision': revision,
    'path': path,
    'branch': ?branch,
  }, RemoteGitDiff.fromJson);

  Future<RemoteGitStatus?> stage(
    String project,
    List<RemoteGitFile> files, {
    required String expectedState,
  }) => _write(LinkMethods.projectGitStage, project, expectedState, {
    'files': files.map((file) => file.toJson()).toList(),
  });

  Future<RemoteGitStatus?> unstage(
    String project,
    List<RemoteGitFile> files, {
    required String expectedState,
  }) => _write(LinkMethods.projectGitUnstage, project, expectedState, {
    'files': files.map((file) => file.toJson()).toList(),
  });

  Future<RemoteGitStashes?> stashes(String project) => _call(
    LinkMethods.projectGitStashes,
    {'project': project},
    RemoteGitStashes.fromJson,
  );

  Future<RemoteGitCommitFiles?> stashFiles(String project, String id) => _call(
    LinkMethods.projectGitStashFiles,
    {'project': project, 'id': id},
    RemoteGitCommitFiles.fromJson,
  );

  Future<RemoteGitDiff?> stashDiff(String project, String id, String path) =>
      _call(LinkMethods.projectGitStashDiff, {
        'project': project,
        'id': id,
        'path': path,
      }, RemoteGitDiff.fromJson);

  Future<RemoteGitStatus?> createStash(
    String project, {
    required String expectedState,
    String? message,
    bool includeUntracked = false,
  }) => _write(LinkMethods.projectGitCreateStash, project, expectedState, {
    'message': ?message,
    'includeUntracked': includeUntracked,
  });

  Future<RemoteGitStatus?> applyStash(
    String project,
    String id, {
    required String expectedState,
  }) => _write(LinkMethods.projectGitApplyStash, project, expectedState, {
    'id': id,
  });

  Future<RemoteGitStatus?> popStash(
    String project,
    String id, {
    required String expectedState,
  }) => _write(LinkMethods.projectGitPopStash, project, expectedState, {
    'id': id,
  });

  Future<RemoteGitStatus?> dropStash(
    String project,
    String id, {
    required String expectedState,
  }) => _write(LinkMethods.projectGitDropStash, project, expectedState, {
    'id': id,
  });

  Future<RemoteGitCommitResult?> commit(
    String project, {
    required String expectedState,
    required String message,
    required List<RemoteGitFile> files,
    bool push = false,
  }) => _call(
    LinkMethods.projectGitCommit,
    {
      'project': project,
      'expectedState': expectedState,
      'message': message,
      'files': files.map((file) => file.toJson()).toList(),
      'push': push,
    },
    RemoteGitCommitResult.fromJson,
    mutation: true,
  );

  Future<RemoteGitStatus?> _write(
    String method,
    String project,
    String expectedState,
    Map<String, Object?> args,
  ) => _call(
    method,
    {'project': project, 'expectedState': expectedState, ...args},
    RemoteGitStatus.fromJson,
    mutation: true,
  );

  static const _outcomeUnknown = LinkRemoteException(
    LinkErrors.gitOutcomeUnknown,
    'The Git operation may have completed. Refresh the repository before retrying.',
  );

  Future<T?> _call<T>(
    String method,
    Map<String, Object?> params,
    T Function(Map<String, Object?>) decode, {
    bool mutation = false,
  }) async {
    try {
      final result = mutation
          ? await peer.call(method, params, const Duration(minutes: 4))
          : await peer.call(method, params);
      return decode(result as Map<String, Object?>);
    } on TimeoutException {
      if (mutation) throw _outcomeUnknown;
      rethrow;
    } on LinkClosedException {
      if (mutation) throw _outcomeUnknown;
      rethrow;
    } on LinkRemoteException catch (error) {
      if (error.code == LinkErrors.unknown ||
          error.code == LinkErrors.unsupported) {
        return null;
      }
      rethrow;
    }
  }
}
