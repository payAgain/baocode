import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:bao_link/bao_link.dart';
import 'package:crypto/crypto.dart';
import 'package:bao_remote/local.dart'
    show IdeGitException, IdeGitOutput, runGit;
import 'package:path/path.dart' as p;

import '../ide/git/git_model.dart';
import 'desktop_remote_git_client.dart';

Future<String> projectGitRepositoryKey(String root) async {
  final git = _ProjectGit(root);
  await git.checkRoot();
  final output = _ProjectGit._checked(
    await git._run(['rev-parse', '--git-common-dir'], maxBytes: 8192),
  );
  final path = output.stdout.trimRight();
  return Directory(p.normalize(p.join(root, path))).resolveSymbolicLinks();
}

Future<Object?> readProjectGit(
  String root,
  String method,
  Map<String, Object?> params, {
  void Function()? authorizeWrite,
}) async {
  final git = _ProjectGit(root);
  try {
    await git.checkRoot();
    return await (switch (method) {
      LinkMethods.projectGitStatus => git.status(),
      LinkMethods.projectGitCapabilities => git.capabilities(),
      LinkMethods.projectGitHistory => git.history(_HistoryQuery.parse(params)),
      LinkMethods.projectGitCommitFiles => git.commitFiles(
        _revision(params['revision']),
        _branch(params['branch']),
      ),
      LinkMethods.projectGitWorkingDiff => git.workingDiff(
        _path(params['path']),
        _flag(params['staged']),
      ),
      LinkMethods.projectGitCommitDiff => git.commitDiff(
        _revision(params['revision']),
        _path(params['path']),
        _branch(params['branch']),
      ),
      LinkMethods.projectGitStashes => git.stashes(),
      LinkMethods.projectGitStashFiles => git.stashFiles(
        _revision(params['id']),
      ),
      LinkMethods.projectGitStashDiff => git.stashDiff(
        _revision(params['id']),
        _path(params['path']),
      ),
      LinkMethods.switchProjectBranch => git.switchBranch(
        params,
        authorizeWrite!,
      ),
      _ when authorizeWrite != null => git.write(
        method,
        params,
        authorizeWrite,
      ),
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

const _badArgument = LinkRemoteException(
  'bad',
  'Invalid Git operation arguments',
);

bool _flag(Object? value) => switch (value) {
  null => false,
  bool flag => flag,
  _ => throw _badArgument,
};

String? _text(Object? value, {int max = 256, bool multiline = false}) {
  if (value == null) return null;
  if (value is! String ||
      value.length > max ||
      value.contains('\x00') ||
      (!multiline && RegExp(r'[\x00-\x1f\x7f]').hasMatch(value))) {
    throw _badArgument;
  }
  return value;
}

String? _branch(Object? value) => _text(value, max: 240);

DateTime? _date(Object? value) {
  final text = _text(value, max: 40);
  if (text == null) return null;
  final date = DateTime.tryParse(text);
  if (date == null) throw _badArgument;
  return date.toUtc();
}

class _HistoryQuery {
  _HistoryQuery.parse(Map<String, Object?> params)
    : branch = _branch(params['branch']),
      path = params['path'] == null ? null : _path(params['path']),
      author = _text(params['author']),
      since = _date(params['since']),
      until = _date(params['until']),
      search = _text(params['search']) {
    final requestedLimit = params['limit'] ?? 50;
    final requestedOffset = params['offset'] ?? 0;
    if (requestedLimit is! int ||
        requestedLimit < 1 ||
        requestedOffset is! int ||
        requestedOffset < 0 ||
        requestedOffset > maxOffset ||
        (since != null && until != null && since!.isAfter(until!))) {
      throw _badArgument;
    }
    limit = requestedLimit.clamp(1, 100);
    offset = requestedOffset;
  }

  static const maxOffset = 10000;
  late final int limit;
  late final int offset;
  final String? branch;
  final String? path;
  final String? author;
  final DateTime? since;
  final DateTime? until;
  final String? search;
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
    Map<String, String> environment = const {},
    bool global = false,
  }) => runGit(
    [
      '--no-pager',
      // Stash generates its own magic pathspecs to remove stashed untracked
      // files. Stash arguments here contain no caller-provided pathspecs.
      if (arguments.firstOrNull != 'stash') '--literal-pathspecs',
      '--no-replace-objects',
      ...arguments.isNotEmpty && arguments.first == 'config'
          ? []
          : [
              '-c',
              'core.untrackedCache=false',
              '-c',
              'core.hooksPath=$_nullDevice',
              '-c',
              'gc.auto=0',
              '-c',
              'maintenance.auto=false',
              '-c',
              'protocol.allow=never',
            ],
      for (final config in configs) ...['-c', config],
      ...arguments,
    ],
    workingDirectory: root,
    maxBytes: maxBytes,
    environment: {
      'GIT_NO_LAZY_FETCH': '1',
      // Per-transport config otherwise overrides protocol.allow. This also
      // blocks lazy fetch on Git versions without GIT_NO_LAZY_FETCH.
      'GIT_ALLOW_PROTOCOL': '',
      'GIT_ATTR_NOSYSTEM': '1',
      'LC_ALL': 'C',
      'GIT_CONFIG_NOSYSTEM': '1',
      if (!global) 'GIT_CONFIG_GLOBAL': _nullDevice,
      ...environment,
    },
  );

  static String get _nullDevice => Platform.isWindows ? 'NUL' : '/dev/null';

  Future<void> checkRoot() async {
    final output = await _run([
      'rev-parse',
      '--is-inside-work-tree',
      '--show-prefix',
    ], maxBytes: 8192);
    final top = await _run(['rev-parse', '--show-toplevel'], maxBytes: 8192);
    if (output.truncated ||
        output.exitCode != 0 ||
        output.stdout != 'true\n\n' ||
        top.truncated ||
        top.exitCode != 0 ||
        !p.equals(
          await Directory(root).resolveSymbolicLinks(),
          await Directory(top.stdout.trimRight()).resolveSymbolicLinks(),
        )) {
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
      final original = resource.originalPath;
      final originalPath = original == null ? null : _relative(original);
      if (path == null || (original != null && originalPath == null)) continue;
      files.add(
        RemoteGitFile(
          path: path,
          originalPath: originalPath,
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
      truncated: status.didHitLimit || status.resources.length != files.length,
    );
  }

  Future<Map<String, Object?>> status() async {
    final status = await _status(await _worktreeConfigs());
    final state = status.truncated ? null : await _state(status);
    return {
      'branch': ?status.branch,
      'head': ?status.head,
      'files': [for (final file in status.files) file.toJson()],
      'truncated': status.truncated,
      'state': ?state,
    };
  }

  // Keep the token opaque even when config or changed files contain secrets.
  static final _stateKey = List<int>.generate(32, (_) => _random.nextInt(256));
  static final _random = Random.secure();

  // Include index changes and the contents of changed paths, even when Git's
  // status letters stay the same. Refuse tokens past the bounded snapshot.
  Future<String?> _state(RemoteGitStatus status) async {
    final index = _checked(
      await _run(['ls-files', '--stage', '-z'], maxBytes: 4 * 1024 * 1024),
    );
    final stash = _checked(await _stashLog());
    final config = await _repositoryConfig();
    if (index.truncated || stash.truncated || config.truncated) return null;
    final entries = <Object?>[
      root,
      status.head,
      status.branch,
      index.stdout,
      stash.stdout,
      config.stdout,
    ];
    var bytesLeft = 32 * 1024 * 1024;
    final paths = {
      for (final file in status.files)
        if (file.group != 'index') file.path,
    };
    for (final path in paths) {
      try {
        _checkWorktreePath(path, untracked: false);
        final absolute = p.join(root, path);
        final type = await FileSystemEntity.type(absolute, followLinks: false);
        if (type == FileSystemEntityType.notFound) continue;
        if (type == FileSystemEntityType.link) {
          entries.add([path, await Link(absolute).target()]);
        } else if (type == FileSystemEntityType.file) {
          final file = File(absolute);
          final stat = await file.stat();
          // Some platforms classify other filesystem nodes as files too.
          if ((!Platform.isWindows && (stat.mode & 0xf000) != 0x8000) ||
              stat.size > bytesLeft)
            return null;
          bytesLeft -= stat.size;
          final digest = await sha256.bind(file.openRead(0, stat.size)).first;
          final after = await file.stat();
          if (after.size != stat.size ||
              after.modified != stat.modified ||
              after.mode != stat.mode)
            return null;
          entries.add([path, stat.mode, digest.toString()]);
        } else {
          return null;
        }
      } on FileSystemException {
        return null;
      } on LinkRemoteException {
        return null;
      }
    }
    entries.add([for (final file in status.files) file.toJson()]);
    return Hmac(
      sha256,
      _stateKey,
    ).convert(utf8.encode(jsonEncode(entries))).toString();
  }

  Future<List<String>> _branches() async =>
      _checked(
            await _run([
              'for-each-ref',
              '--count=500',
              '--format=%(refname:lstrip=2)',
              'refs/heads/',
            ]),
          ).stdout
          .split('\n')
          .where((branch) => branch.isNotEmpty && branch.length <= 240)
          .toList();

  Future<Map<String, Object?>> capabilities() async {
    final branch = await _symbolicBranch();
    final canWrite = await _safeToWrite();
    return {
      'branches': await _branches(),
      'canWrite': canWrite,
      'canPush': canWrite && await _pushTarget(branch) != null,
    };
  }

  Future<List<String>> _configValues(String key, {bool global = false}) async {
    final result = await _run(
      ['config', '--null', '--get-all', key],
      maxBytes: 8192,
      global: global,
    );
    if (result.exitCode == 1 || result.truncated) return const [];
    return _records(_checked(result));
  }

  Future<List<String>> _identity() async => [
    for (final key in ['user.name', 'user.email'])
      if ((await _configValues(key, global: true)).lastOrNull case final value?)
        '$key=$value',
  ];

  Future<({String url, String ref, bool local})?> _pushTarget(
    String? branch,
  ) async {
    if (branch == null) return null;
    final remotes = await _configValues('branch.$branch.remote');
    final refs = await _configValues('branch.$branch.merge');
    if (remotes.length != 1 || refs.length != 1) return null;
    final remote = remotes.single;
    final ref = refs.single;
    if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$').hasMatch(remote) ||
        !ref.startsWith('refs/heads/') ||
        ref.length > 256 ||
        (await _run(['check-ref-format', ref], maxBytes: 256)).exitCode != 0)
      return null;
    var urls = await _configValues('remote.$remote.pushurl');
    if (urls.isEmpty) urls = await _configValues('remote.$remote.url');
    if (urls.length != 1 ||
        (await _configValues('remote.$remote.receivepack')).isNotEmpty ||
        (await _configValues('remote.$remote.vcs')).isNotEmpty)
      return null;
    final url = urls.single;
    if (url.length > 4096 || RegExp(r'[\x00-\x1f\x7f]').hasMatch(url))
      return null;
    final uri = Uri.tryParse(url);
    if (url.startsWith('https://') &&
        uri != null &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        !uri.hasQuery &&
        !uri.hasFragment &&
        !url.contains('\\')) {
      return (url: url, ref: ref, local: false);
    }
    if (!p.isAbsolute(url) || url.startsWith('//') || url.startsWith(r'\\'))
      return null;
    try {
      final target = await Directory(url).resolveSymbolicLinks();
      if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(target)) return null;
      final bare = _ProjectGit(target);
      final result = await bare._run([
        'rev-parse',
        '--is-bare-repository',
      ], maxBytes: 256);
      if (result.exitCode != 0 || result.stdout != 'true\n') return null;
      // The local receive-pack process loads its own repository config.
      // Permit ordinary bare metadata and receive policy settings only.
      final config = await bare._run([
        'config',
        '--null',
        '--name-only',
        '--list',
      ], maxBytes: 8192);
      if (config.exitCode != 0 ||
          config.truncated ||
          _records(config).any(
            (key) => !const {
              'core.repositoryformatversion',
              'core.filemode',
              'core.fsmonitor', // Overridden when launching the receiver.
              'core.bare',
              'core.logallrefupdates',
              'core.ignorecase',
              'core.precomposeunicode',
              'core.hookspath',
              'extensions.objectformat',
              'receive.denynonfastforwards',
              'receive.denydeletes',
              'receive.fsckobjects',
            }.contains(key),
          ))
        return null;
      return (url: target, ref: ref, local: true);
    } on FileSystemException {
      return null;
    } on IdeGitException {
      return null;
    }
  }

  Future<String?> _push(
    String? branch,
    ({String url, String ref, bool local})? target,
    String head,
    void Function() authorize,
  ) async {
    Directory? temp;
    try {
      if (target == null) return 'No supported Git push upstream is configured';
      final source = _checked(
        await _run(['rev-parse', '--git-path', 'objects'], maxBytes: 8192),
      );
      final objects = await Directory(
        p.normalize(p.join(root, source.stdout.trimRight())),
      ).resolveSymbolicLinks();
      if (RegExp(r'[\x00-\x1f\x7f]').hasMatch(objects))
        return 'Git push is unavailable for this repository path';
      final folder = temp = await Directory.systemTemp.createTemp(
        'baocode-git-push-',
      );
      final sender = _ProjectGit(folder.path);
      _checked(
        await sender._run([
          'init',
          '--bare',
          '--quiet',
          '--template=',
          if (head.length == 64) '--object-format=sha256',
        ]),
      );
      await File(p.join(folder.path, 'objects', 'info', 'alternates'))
          .writeAsString('$objects\n');
      if (await _pushTarget(branch) != target ||
          await _symbolicBranch() != branch ||
          await _head() != head) {
        return 'Git HEAD or its push upstream changed after the commit';
      }
      authorize();
      final result = await sender._run(
        [
          'push',
          '--porcelain',
          '--no-verify',
          '--no-follow-tags',
          '--recurse-submodules=no',
          // Git clears repository-specific environment for a local receiver.
          // This fixed command keeps the receiver's hooks disabled as well.
          if (target.local)
            '--receive-pack=git -c core.hooksPath=$_nullDevice -c core.fsmonitor=false -c gc.auto=0 -c maintenance.auto=false receive-pack',
          '--',
          target.url,
          '$head:${target.ref}',
        ],
        configs: const ['http.followRedirects=false', 'credential.helper='],
        environment: {
          'GIT_ALLOW_PROTOCOL': target.local ? 'file' : 'https',
          'GIT_ASKPASS': '',
          'SSH_ASKPASS': '',
          'GIT_CONFIG_COUNT': '0',
        },
      );
      return result.exitCode == 0 && !result.truncated
          ? null
          : 'Git push failed or was rejected';
    } on IdeGitException {
      return 'Could not confirm the Git push; check the upstream before retrying';
    } on FileSystemException {
      return 'Could not prepare the Git push';
    } finally {
      try {
        await temp?.delete(recursive: true);
      } on FileSystemException {
        // An interrupted subprocess may still have files open on Windows.
      }
    }
  }

  Future<String?> _symbolicBranch() async {
    final output = await _run(['symbolic-ref', '-q', 'HEAD'], maxBytes: 8192);
    if (output.exitCode == 1) return null;
    final name = _checked(output).stdout.trimRight();
    return name.startsWith('refs/heads/') ? name.substring(11) : null;
  }

  Future<IdeGitOutput> _repositoryConfig({bool global = false}) async =>
      _checked(
        await _run(
          ['config', '--null', '--list'],
          maxBytes: 64 * 1024,
          global: global,
        ),
      );

  Future<bool> _safeToWrite() async {
    // Refuse writes rather than silently dropping Git LFS or other configured
    // file transformations, including drivers set in the host user's config.
    final configs = await _repositoryConfig(global: true);
    if (configs.truncated) return false;
    for (final entry in _records(configs)) {
      final newline = entry.indexOf('\n');
      final key = newline < 0 ? entry : entry.substring(0, newline);
      if (RegExp(r'^filter\..*\.(clean|smudge|process|required)$')
              .hasMatch(key) ||
          RegExp(r'^merge\..*\.driver$').hasMatch(key) ||
          key.startsWith('hook.') ||
          key == 'core.alternaterefscommand' ||
          key == 'extensions.partialclone' ||
          RegExp(r'^remote\..*\.promisor$').hasMatch(key))
        return false;
    }
    return true;
  }

  static const _writeConfigs = [
    'commit.gpgSign=false',
    'commit.status=false',
    'commit.verbose=false',
    'submodule.recurse=false',
    'core.splitIndex=false',
    'merge.renormalize=false',
  ];

  static const _stale = LinkRemoteException(
    'stale',
    'The host Git state changed',
  );
  static const _unsafe = LinkRemoteException(
    LinkErrors.gitRejected,
    'Remote Git writes require a repository without external filters, merge drivers, or lazy fetch',
  );
  static const _missingStash = LinkRemoteException(
    LinkErrors.notFound,
    'No such project stash',
  );

  Future<IdeGitOutput> _stashLog() => _run([
    'stash',
    'list',
    '-z',
    '--max-count=101',
    '--no-show-signature',
    '--no-notes',
    '--format=tformat:%H%x00%cI%x00%gs',
  ]);

  Future<Map<String, Object?>> stashes() async {
    final output = _checked(await _stashLog());
    final fields = _records(output);
    return {
      'entries': [
        for (var i = 0; i + 2 < fields.length && i < 300; i += 3)
          {
            'id': _revision(fields[i]),
            'date': fields[i + 1],
            'message': fields[i + 2],
          },
      ],
      'truncated': output.truncated || fields.length > 300,
    };
  }

  Future<int> _stashPosition(String id, {bool unique = false}) async {
    final fields = _records(_checked(await _stashLog()));
    final positions = [
      for (var i = 0; i + 2 < fields.length && i < 300; i += 3)
        if (fields[i] == id) i ~/ 3,
    ];
    if (positions.isEmpty) throw _missingStash;
    if (unique && positions.length != 1)
      throw const LinkRemoteException(
        LinkErrors.gitRejected,
        'Several stash entries have this identifier',
      );
    return positions.first;
  }

  Future<List<String>> _stashComparison(String id) async {
    await _stashPosition(id);
    final parent = _checked(
      await _run(['rev-parse', '--verify', '$id^1'], maxBytes: 256),
    );
    return [_revision(parent.stdout.trim()), id];
  }

  Future<String?> _stashUntracked(String id) async {
    final result = await _run([
      'rev-parse',
      '--verify',
      '-q',
      '$id^3',
    ], maxBytes: 256);
    return result.exitCode == 1
        ? null
        : _revision(_checked(result).stdout.trim());
  }

  Future<Map<String, Object?>> stashFiles(String id) async {
    final files = await _commitFiles(await _stashComparison(id));
    final untracked = await _stashUntracked(id);
    if (untracked == null) return _filesResponse(files);
    final extras = await _commitFiles([untracked]);
    final all = [...files.files, ...extras.files];
    return _filesResponse(
      RemoteGitCommitFiles(
        files: all.take(_fileLimit).toList(),
        truncated:
            files.truncated || extras.truncated || all.length > _fileLimit,
      ),
    );
  }

  Future<Map<String, Object?>> stashDiff(String id, String path) async {
    final comparison = await _stashComparison(id);
    final files = await _commitFiles(comparison);
    if (files.files.any((file) => file.path == path))
      return _treeDiff(comparison, path);
    final untracked = await _stashUntracked(id);
    if (untracked == null) throw _noChange;
    return _treeDiff([untracked], path);
  }

  static const _writeFailed = LinkRemoteException(
    LinkErrors.gitRejected,
    'Git rejected the operation; refresh to check the repository state',
  );

  List<RemoteGitFile> _selection(
    Object? input,
    RemoteGitStatus status,
    Set<String> groups,
  ) {
    if (input is! List || input.isEmpty || input.length > 100)
      throw _badArgument;
    final files = <RemoteGitFile>[];
    var pathBytes = 0;
    for (final row in input) {
      if (row is! Map<String, Object?>) throw _badArgument;
      final path = _path(row['path']);
      final original = row['originalPath'] == null
          ? null
          : _path(row['originalPath']);
      final file = status.files
          .where(
            (file) =>
                file.path == path &&
                file.originalPath == original &&
                file.status == row['status'] &&
                file.group == row['group'],
          )
          .firstOrNull;
      if (file == null) throw _stale;
      if (!groups.contains(file.group)) throw _badArgument;
      pathBytes +=
          utf8.encode(path).length +
          (original == null ? 0 : utf8.encode(original).length);
      if (pathBytes > 12 * 1024) throw _badArgument;
      _checkWorktreePath(path, untracked: false);
      if (original != null) _checkWorktreePath(original, untracked: false);
      files.add(file);
    }
    return files;
  }

  Future<Object?> write(
    String method,
    Map<String, Object?> params,
    void Function() authorize,
  ) async {
    final expected = params['expectedState'];
    if (expected is! String ||
        expected.length != 64 ||
        !_oid.hasMatch(expected))
      throw _badArgument;
    if (!await _safeToWrite()) throw _unsafe;
    Future<RemoteGitStatus> checkExpected() async {
      final status = await _status(await _worktreeConfigs());
      if (status.truncated || await _state(status) != expected) throw _stale;
      return status;
    }

    final status = await checkExpected();
    final configs = [..._writeConfigs, ...await _identity()];
    Future<void> mutate(
      List<String> args, {
      bool first = true,
      Future<void> Function()? lastCheck,
      Map<String, String> environment = const {},
      List<String> extraConfigs = const [],
    }) async {
      if (!await _safeToWrite()) throw _unsafe;
      if (first) await checkExpected();
      if (lastCheck != null) await lastCheck();
      authorize();
      final result = await _run(
        args,
        configs: [...configs, ...extraConfigs],
        environment: environment,
      );
      if (result.exitCode != 0 || result.truncated) throw _writeFailed;
    }

    switch (method) {
      case LinkMethods.projectGitStage:
      case LinkMethods.projectGitUnstage:
      case LinkMethods.projectGitCommit:
        final groups = switch (method) {
          LinkMethods.projectGitStage => const {
            'workingTree',
            'untracked',
            'merge',
          },
          LinkMethods.projectGitUnstage => const {'index'},
          _ => const {'index', 'workingTree', 'untracked'},
        };
        final files = _selection(params['files'], status, groups);
        final paths = {
          for (final file in files) ...[file.path, ?file.originalPath],
        };
        if (method == LinkMethods.projectGitStage) {
          await mutate(['add', '-A', '--', ...paths]);
        } else if (method == LinkMethods.projectGitUnstage) {
          await mutate(
            status.head == null
                ? ['rm', '--cached', '-f', '-q', '--', ...paths]
                : ['reset', '-q', 'HEAD', '--', ...paths],
          );
        } else {
          final message = _text(params['message'], max: 4096, multiline: true);
          final push = _flag(params['push']);
          if (message == null || message.trim().isEmpty) throw _badArgument;
          // Match IdeGitRepository.commitResources / IdeGitService.commitPaths:
          // prime untracked paths and commit the working copies of only the
          // selected files (including both sides of renames).
          final untracked = {
            for (final file in files)
              if (file.group == 'untracked') file.path,
          };
          final branch = await _symbolicBranch();
          final target = push ? await _pushTarget(branch) : null;
          Future<void> checkHead() async {
            if (await _symbolicBranch() != branch ||
                await _head() != status.head) {
              throw _stale;
            }
          }

          if (untracked.isNotEmpty) {
            await mutate([
              'add',
              '-N',
              '--',
              ...untracked,
            ], lastCheck: checkHead);
          }
          final marker =
              'baocode-remote-${List.generate(16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
          await mutate(
            [
              'commit',
              '--quiet',
              '--no-gpg-sign',
              '--no-verify',
              '--cleanup=verbatim',
              '-m',
              message,
              '--only',
              '--',
              ...paths,
            ],
            first: untracked.isEmpty,
            lastCheck: checkHead,
            environment: {'GIT_REFLOG_ACTION': marker},
            extraConfigs: const ['core.logAllRefUpdates=true'],
          );
          final head = await _committedHead(branch, status.head, marker);
          final pushError = push
              ? await _push(branch, target, head, authorize)
              : null;
          return {
            'head': head,
            'pushed': push && pushError == null,
            'pushError': ?pushError,
          };
        }
      case LinkMethods.projectGitCreateStash:
        final message = _text(params['message'], max: 1024);
        final includeUntracked = _flag(params['includeUntracked']);
        if (status.head == null ||
            !status.files.any(
              (file) => includeUntracked || file.group != 'untracked',
            )) {
          throw _writeFailed;
        }
        await mutate([
          'stash',
          'push',
          '--quiet',
          if (includeUntracked) '--include-untracked',
          if (message != null && message.isNotEmpty) ...['-m', message],
        ]);
      case LinkMethods.projectGitApplyStash:
      case LinkMethods.projectGitPopStash:
      case LinkMethods.projectGitDropStash:
        final id = _revision(params['id']);
        final deletes = method != LinkMethods.projectGitApplyStash;
        final position = await _stashPosition(id, unique: deletes);
        final dropOnly = method == LinkMethods.projectGitDropStash;
        Future<void> checkPosition() async {
          if (await _stashPosition(id, unique: deletes) != position)
            throw _stale;
        }
        if (!dropOnly) {
          await mutate([
            'stash',
            'apply',
            '--index',
            '--quiet',
            id,
          ], lastCheck: checkPosition);
        }
        if (deletes) {
          await mutate(
            ['stash', 'drop', '--quiet', 'stash@{$position}'],
            first: dropOnly,
            lastCheck: checkPosition,
          );
        }
      default:
        throw const LinkRemoteException(
          LinkErrors.unknown,
          'Unknown Git operation',
        );
    }
    return this.status();
  }

  Future<String> _committedHead(
    String? branch,
    String? parent,
    String marker,
  ) async {
    const unknown = LinkRemoteException(
      LinkErrors.gitOutcomeUnknown,
      'Git completed but the new commit could not be verified. Refresh before retrying.',
    );
    try {
      // Use the exact reflog entry created by this invocation. Reading HEAD
      // alone can return someone else's concurrent local commit or checkout.
      final log = await _run([
        'reflog',
        'show',
        '-z',
        '--max-count=32',
        '--no-notes',
        '--no-show-signature',
        '--format=tformat:%H%x00%gs',
        branch == null ? 'HEAD' : 'refs/heads/$branch',
        '--',
      ]);
      if (log.exitCode != 0) throw unknown;
      final records = _records(log);
      final matches = [
        for (var i = 0; i + 1 < records.length; i += 2)
          if (records[i + 1].startsWith('$marker: ')) _revision(records[i]),
      ];
      if (matches.length != 1) throw unknown;
      final head = matches.single;
      final commit = await _run([
        'cat-file',
        'commit',
        head,
      ], maxBytes: 32 * 1024);
      final headers = commit.stdout.split('\n\n').first;
      final parents = headers
          .split('\n')
          .where((line) => line.startsWith('parent '));
      if (commit.exitCode != 0 ||
          commit.truncated ||
          !(parent == null
              ? parents.isEmpty
              : parents.length == 1 && parents.single == 'parent $parent')) {
        throw unknown;
      }
      return head;
    } on IdeGitException {
      throw unknown;
    }
  }

  Future<Object?> switchBranch(
    Map<String, Object?> params,
    void Function() authorize,
  ) async {
    final branch = _branch(params['branch']);
    if (branch == null || branch.isEmpty)
      throw const LinkRemoteException(LinkErrors.notFound, 'No branch named');
    try {
      await _historyTip(branch);
    } on LinkRemoteException {
      throw const LinkRemoteException(
        LinkErrors.gitRejected,
        'No such local Git branch',
      );
    }
    if (!await _safeToWrite()) throw _unsafe;
    if (await _head() != params['expectedHead'] ||
        await _symbolicBranch() != params['expectedBranch'])
      throw _stale;
    authorize();
    final result = await _run([
      'switch',
      '--no-guess',
      '--no-recurse-submodules',
      '--',
      branch,
    ], configs: _writeConfigs);
    if (result.exitCode != 0) throw _writeFailed;
    return null;
  }

  Future<String?> _historyTip(String? branch) async {
    if (branch == null) return _head();
    final input = 'refs/heads/$branch';
    final checked = await _run(['check-ref-format', input], maxBytes: 256);
    if (checked.exitCode != 0) throw _badArgument;
    final output = await _run([
      'show-ref',
      '--verify',
      '--hash',
      '--',
      input,
    ], maxBytes: 256);
    if (output.exitCode != 0) {
      throw const LinkRemoteException(
        LinkErrors.notFound,
        'No such local Git branch',
      );
    }
    return _revision(output.stdout.trim());
  }

  Future<Map<String, Object?>> history(_HistoryQuery query) async {
    final head = await _historyTip(query.branch);
    if (head == null) return {'commits': [], 'truncated': false};
    final limit = query.limit;
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
        '--skip=${query.offset}',
        '--fixed-strings',
        '--regexp-ignore-case',
        if (query.author case final author?) '--author=$author',
        if (query.search case final search?) '--grep=$search',
        if (query.since case final since?) '--since=${since.toIso8601String()}',
        if (query.until case final until?) '--until=${until.toIso8601String()}',
        head,
        '--',
        ?query.path,
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
    final truncated = output.truncated || records.length > limit * width;
    final next = query.offset + commits.length;
    return {
      'commits': commits,
      'truncated': truncated,
      if (truncated && commits.isNotEmpty && next <= _HistoryQuery.maxOffset)
        'nextOffset': next,
    };
  }

  Future<List<String>> _commitComparison(
    String revision,
    String? branch,
  ) async {
    const missing = LinkRemoteException(
      LinkErrors.notFound,
      'Commit is not in the project history',
    );
    final head = await _historyTip(branch);
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

  static Map<String, Object?> _filesResponse(RemoteGitCommitFiles files) => {
    'files': [for (final file in files.files) file.toJson()],
    'truncated': files.truncated,
  };

  Future<Map<String, Object?>> commitFiles(
    String revision,
    String? branch,
  ) async => _filesResponse(
    await _commitFiles(await _commitComparison(revision, branch)),
  );

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

  Future<Map<String, Object?>> commitDiff(
    String revision,
    String path,
    String? branch,
  ) async => _treeDiff(await _commitComparison(revision, branch), path);

  Future<Map<String, Object?>> _treeDiff(
    List<String> revisions,
    String path,
  ) async {
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
