import 'dart:io';

import 'package:bao_link/bao_link.dart';
import 'package:bao_remote/local.dart'
    show IdeGitException, IdeGitOutput, runGit;
import 'package:path/path.dart' as p;

import '../ide/git/git_model.dart';
import 'desktop_remote_git_client.dart';

Future<Object?> readProjectGit(
  String root,
  String method,
  Map<String, Object?> params,
) async {
  final git = _ProjectGit(root);
  final path = switch (method) {
    LinkMethods.projectGitWorkingDiff ||
    LinkMethods.projectGitCommitDiff => _path(params['path']),
    _ => null,
  };
  final revision = switch (method) {
    LinkMethods.projectGitCommitFiles ||
    LinkMethods.projectGitCommitDiff => _revision(params['revision']),
    _ => null,
  };
  final limit = params['limit'] ?? 50;
  if (method == LinkMethods.projectGitHistory && (limit is! int || limit < 1)) {
    throw const LinkRemoteException('bad', 'Invalid Git history limit');
  }
  final staged = params['staged'] ?? false;
  if (method == LinkMethods.projectGitWorkingDiff && staged is! bool) {
    throw const LinkRemoteException('bad', 'Invalid Git diff group');
  }
  try {
    await git.checkRoot();
    return await (switch (method) {
      LinkMethods.projectGitStatus => git.status(),
      LinkMethods.projectGitHistory => git.history(
        (limit as int).clamp(1, 100),
      ),
      LinkMethods.projectGitCommitFiles => git.commitFiles(revision!),
      LinkMethods.projectGitWorkingDiff => git.workingDiff(
        path!,
        staged as bool,
      ),
      LinkMethods.projectGitCommitDiff => git.commitDiff(revision!, path!),
      _ => throw const LinkRemoteException(
        LinkErrors.unknown,
        'Unknown Git method',
      ),
    });
  } on IdeGitException {
    throw const LinkRemoteException(
      LinkErrors.gitRejected,
      'Could not read project Git data',
    );
  } on FormatException {
    throw const LinkRemoteException(
      LinkErrors.gitRejected,
      'Git returned invalid data',
    );
  } on FileSystemException {
    throw const LinkRemoteException(
      LinkErrors.gitRejected,
      'Could not read files in this repository',
    );
  }
}

final _oid = RegExp(r'^(?:[0-9a-f]{40}|[0-9a-f]{64})$');

String _revision(Object? value) {
  if (value is String &&
      (value.length == 40 || value.length == 64) &&
      _oid.hasMatch(value)) {
    return value;
  }
  throw const LinkRemoteException('bad', 'A full commit hash is required');
}

final _pathControls = RegExp(r'[\x00-\x1f\x7f\\:]');
final _windowsDevice = RegExp(
  r'^(?:con|prn|aux|nul|com[1-9¹²³]|lpt[1-9¹²³])(?:\.|$)',
  caseSensitive: false,
);

bool _validPath(String path) =>
    path.isNotEmpty &&
    path.length <= 4096 &&
    !_pathControls.hasMatch(path) &&
    path
        .split('/')
        .every(
          (part) =>
              part.isNotEmpty &&
              part != '.' &&
              part != '..' &&
              part.toLowerCase() != '.git' &&
              (!Platform.isWindows ||
                  (!part.endsWith('.') &&
                      !part.endsWith(' ') &&
                      part.toLowerCase() != 'git~1' &&
                      !_windowsDevice.hasMatch(part))),
        );

String _path(Object? value) {
  if (value is String && _validPath(value)) return value;
  throw const LinkRemoteException(
    'bad',
    'A repository-relative file path is required',
  );
}

class _ProjectGit {
  _ProjectGit(this.root);

  final String root;
  static const _dataBytes = 256 * 1024;
  static const _patchBytes = 256 * 1024;
  static const _fileLimit = 500;
  static const _diffOptions = [
    '--no-color',
    '--no-ext-diff',
    '--no-textconv',
    '--no-relative',
    '--src-prefix=a/',
    '--dst-prefix=b/',
    '--ignore-submodules=dirty',
    '--submodule=short',
    '--no-color-moved',
    '--unified=3',
  ];

  Future<IdeGitOutput> _run(
    List<String> arguments, {
    int maxBytes = _dataBytes,
    List<String> configs = const [],
  }) => runGit(
    [
      '--literal-pathspecs', '--no-replace-objects',
      '-c', 'core.untrackedCache=false',
      // Preserve only normal, local object reads in partial repositories.
      '-c', 'core.hooksPath=${Platform.isWindows ? 'NUL' : '/dev/null'}',
      for (final config in configs) ...['-c', config],
      ...arguments,
    ],
    workingDirectory: root,
    maxBytes: maxBytes,
    environment: const {'GIT_NO_LAZY_FETCH': '1', 'LC_ALL': 'C'},
  );

  Future<void> checkRoot() async {
    final output = await _run([
      'rev-parse',
      '--is-inside-work-tree',
      '--show-prefix',
    ], maxBytes: 8192);
    if (output.truncated ||
        output.exitCode != 0 ||
        output.stdout != 'true\n\n') {
      throw const LinkRemoteException(
        LinkErrors.unsupported,
        'Project Git requires a repository at the project root',
      );
    }
  }

  static IdeGitOutput _checked(
    IdeGitOutput result, {
    bool allowDifference = false,
  }) {
    if (result.exitCode != 0 && !(allowDifference && result.exitCode == 1)) {
      throw const IdeGitException('Git read failed');
    }
    return result;
  }

  Future<String?> _head() async {
    final result = await _run([
      'rev-parse',
      '--verify',
      '-q',
      'HEAD^{commit}',
    ], maxBytes: 256);
    if (result.exitCode == 1) return null;
    final oid = _checked(result).stdout.trim();
    return _revision(oid);
  }

  // Git may run clean/process filters even during status when checking file
  // content. Mask every configured driver before worktree operations.
  Future<List<String>> _worktreeConfigs() async {
    final output = await _run([
      'config',
      '--name-only',
      '--null',
      '--get-regexp',
      r'^filter\..*\.(clean|process|required)$',
    ], maxBytes: 4096);
    if (output.exitCode == 1) return const [];
    if (output.truncated) {
      throw const IdeGitException('Too many Git filter definitions');
    }
    final drivers = <String>{};
    for (final key in _records(_checked(output))) {
      final driver = key.substring(0, key.lastIndexOf('.'));
      if (!RegExp(r'^filter\.[a-zA-Z0-9_.-]+$').hasMatch(driver)) {
        throw const IdeGitException('Invalid Git filter name');
      }
      drivers.add(driver);
    }
    return [
      for (final driver in drivers) ...[
        '$driver.clean=',
        '$driver.process=',
        '$driver.required=false',
      ],
    ];
  }

  static List<String> _records(IdeGitOutput output) {
    final last = output.stdout.lastIndexOf('\x00');
    return last < 0 ? const [] : output.stdout.substring(0, last).split('\x00');
  }

  String? _relative(String absolute) {
    if (!p.isWithin(root, absolute)) return null;
    final relative = p.split(p.relative(absolute, from: root)).join('/');
    return _validPath(relative) ? relative : null;
  }

  Future<RemoteGitStatus> _status(List<String> configs) async {
    final result = _checked(
      await _run([
        'status',
        '--porcelain=v1',
        '-z',
        '--branch',
        '--no-ahead-behind',
        '--untracked-files=all',
        '--find-renames',
        '--ignore-submodules=dirty',
      ], configs: configs),
    );
    final last = result.stdout.lastIndexOf('\x00');
    final status = parseGitStatus(
      root,
      last < 0 ? '' : result.stdout.substring(0, last + 1),
      truncated: result.truncated,
    );
    final files = <RemoteGitFile>[];
    for (final resource in status.resources.take(_fileLimit)) {
      final path = _relative(resource.path);
      if (path == null) continue;
      files.add(
        RemoteGitFile(
          path: path,
          originalPath: resource.originalPath == null
              ? null
              : _relative(resource.originalPath!),
          status: resource.status.isConflict ? 'U' : resource.status.letter,
          group: switch (resource.group) {
            IdeGitGroup.staged => 'index',
            IdeGitGroup.merge => 'merge',
            IdeGitGroup.workingTree =>
              resource.status == IdeGitStatus.untracked
                  ? 'untracked'
                  : 'workingTree',
          },
        ),
      );
    }
    return RemoteGitStatus(
      files: files,
      branch: status.head.branch,
      head: status.head.unborn ? null : await _head(),
      truncated: status.didHitLimit || status.resources.length > _fileLimit,
    );
  }

  Future<Map<String, Object?>> status() async {
    final status = await _status(await _worktreeConfigs());
    return {
      'branch': ?status.branch,
      'head': ?status.head,
      'files': [for (final file in status.files) file.toJson()],
      'truncated': status.truncated,
    };
  }

  Future<Map<String, Object?>> history(int limit) async {
    final head = await _head();
    if (head == null) return {'commits': [], 'truncated': false};
    final output = _checked(
      await _run([
        'log',
        '--topo-order',
        '--decorate=full',
        '--no-notes',
        '--no-show-signature',
        '-z',
        '--format=tformat:%H%x00%P%x00%an%x00%aI%x00%D%x00%s',
        '--max-count=${limit + 1}',
        head,
        '--',
      ]),
    );
    const width = 6;
    final records = _records(output);
    final commits = <Map<String, Object?>>[];
    for (
      var i = 0;
      i + width <= records.length && commits.length < limit;
      i += width
    ) {
      final hash = _revision(records[i]);
      commits.add(
        RemoteGitCommit(
          hash: hash,
          shortHash: hash.substring(0, 7),
          parentIds: records[i + 1].isEmpty
              ? const []
              : records[i + 1].split(' '),
          authorName: records[i + 2],
          authorDate: DateTime.tryParse(records[i + 3]),
          refs: records[i + 4].isEmpty ? const [] : records[i + 4].split(', '),
          subject: records[i + 5],
        ).toJson(),
      );
    }
    return {
      'commits': commits,
      'truncated': output.truncated || records.length > limit * width,
    };
  }

  Future<List<String>> _commitComparison(String revision) async {
    const missing = LinkRemoteException(
      LinkErrors.notFound,
      'Commit is not in the project history',
    );
    final head = await _head();
    if (head == null) throw missing;
    final type = await _run(['cat-file', '-t', revision], maxBytes: 256);
    if (type.exitCode != 0 || type.stdout != 'commit\n') throw missing;
    final ancestor = await _run([
      'merge-base',
      '--is-ancestor',
      revision,
      head,
    ], maxBytes: 256);
    if (ancestor.exitCode != 0) throw missing;
    final parent = await _run([
      'rev-parse',
      '--verify',
      '-q',
      '$revision^1',
    ], maxBytes: 256);
    return [
      if (parent.exitCode == 0) _revision(parent.stdout.trim()),
      revision,
    ];
  }

  Future<RemoteGitCommitFiles> _commitFiles(List<String> revisions) async {
    final output = _checked(
      await _run([
        'diff-tree',
        '--root',
        '--no-commit-id',
        '-r',
        '-M',
        '--name-status',
        '-z',
        '--no-ext-diff',
        '--no-textconv',
        ...revisions,
        '--',
      ]),
    );
    final fields = _records(output);
    final files = <RemoteGitFile>[];
    var i = 0;
    while (i + 1 < fields.length && files.length < _fileLimit) {
      final code = fields[i++];
      if (code.isEmpty) {
        throw const FormatException('Missing Git status letter');
      }
      final status = code[0];
      final first = fields[i++];
      String? original;
      if (status == 'R' || status == 'C') {
        if (i == fields.length) break;
        if (_validPath(first)) original = first;
      }
      final path = status == 'R' || status == 'C' ? fields[i++] : first;
      if (_validPath(path)) {
        files.add(
          RemoteGitFile(
            path: path,
            originalPath: original,
            status: status,
            group: 'commit',
          ),
        );
      }
    }
    return RemoteGitCommitFiles(
      files: files,
      truncated: output.truncated || i < fields.length,
    );
  }

  Future<Map<String, Object?>> commitFiles(String revision) async {
    final files = await _commitFiles(await _commitComparison(revision));
    return {
      'files': [for (final file in files.files) file.toJson()],
      'truncated': files.truncated,
    };
  }

  static const _noChange = LinkRemoteException(
    LinkErrors.notFound,
    'No Git change for this file',
  );

  static Map<String, Object?> _patch(IdeGitOutput output) {
    var patch = output.stdout;
    if (output.truncated) {
      final end = patch.lastIndexOf('\n');
      if (end >= 0) patch = patch.substring(0, end + 1);
    }
    return {'text': patch, 'truncated': output.truncated};
  }

  Future<Map<String, Object?>> commitDiff(String revision, String path) async {
    final revisions = await _commitComparison(revision);
    final files = await _commitFiles(revisions);
    final file = files.files.where((file) => file.path == path).firstOrNull;
    if (file == null) throw _noChange;
    return _patch(
      _checked(
        await _run([
          'diff-tree',
          '--root',
          '--no-commit-id',
          '-r',
          '-M',
          '-p',
          ..._diffOptions,
          ...revisions,
          '--',
          file.path,
          ?file.originalPath,
        ], maxBytes: _patchBytes),
      ),
    );
  }

  // Only actual directories may be used as path ancestors. Never pass a
  // working-tree directory to Git's pathspec or no-index modes.
  void _checkWorktreePath(String path, {required bool untracked}) {
    var full = root;
    final parts = path.split('/');
    for (final part in parts.take(parts.length - 1)) {
      full = p.join(full, part);
      final type = FileSystemEntity.typeSync(full, followLinks: false);
      if (type == FileSystemEntityType.notFound && !untracked) return;
      if (type != FileSystemEntityType.directory) throw _noChange;
    }
    final type = FileSystemEntity.typeSync(
      p.join(full, parts.last),
      followLinks: false,
    );
    if (untracked
        ? type != FileSystemEntityType.file
        : type == FileSystemEntityType.directory) {
      throw _noChange;
    }
  }

  Future<Map<String, Object?>> workingDiff(String path, bool staged) async {
    final configs = await _worktreeConfigs();
    final status = await _status(configs);
    final file = status.files
        .where((file) => file.path == path && (file.group == 'index') == staged)
        .firstOrNull;
    if (file == null) throw _noChange;
    final untracked = file.group == 'untracked';
    if (!staged) {
      _checkWorktreePath(path, untracked: untracked);
      if (file.originalPath case final original?) {
        _checkWorktreePath(original, untracked: false);
      }
    }
    return _patch(
      _checked(
        await _run(
          [
            'diff',
            ..._diffOptions,
            if (untracked) ...[
              '--no-index',
              '--',
              '/dev/null',
              file.path,
            ] else ...[
              if (staged) '--cached',
              '-M',
              '--',
              file.path,
              ?file.originalPath,
            ],
          ],
          maxBytes: _patchBytes,
          configs: configs,
        ),
        allowDifference: untracked,
      ),
    );
  }
}
