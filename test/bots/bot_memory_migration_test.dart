import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bao_agent/bao_agent.dart' show SessionStore;
import 'package:baocode/bots/bot.dart';
import 'package:baocode/bots/bot_folders.dart';
import 'package:baocode/bots/bot_legacy_diary.dart';
import 'package:baocode/bots/bot_memory.dart';
import 'package:baocode/bots/bot_memory_migration.dart';
import 'package:baocode/bots/bots.dart';
import 'package:baocode/kernel/agent_kernel.dart';
import 'package:baocode/kernel/claude_code/claude_storage_io.dart';
import 'package:baocode/kernel/claude_code/managed_transcripts_io.dart';
import 'package:baocode/kernel/mock/mock_kernels.dart';
import 'package:baocode/platform/data_dir.dart';
import 'package:baocode/remote/remote_claude.dart' show ClaudeCatalog;
import 'package:baocode/search/memory_history.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter_test/flutter_test.dart';

const _bot = Bot(id: 'b', name: 'Example', folder: '/bots/b');
const _dm = MemoryHistoryScope.dm('b');
const _group = MemoryHistoryScope.group('b', 'room-1');
const _owner = MemoryHistoryScope.bot('b');
const _day = '/bots/b/timeline/2026-11-25.md';
const _source = '/bots/b/MEMORY.md';
const _backup = '/bots/runtime/b/memory-migration';

void main() {
  test(
    'managed deletion blocks on a legacy diary copy before erasing the source',
    () async {
      final temporary = Directory.systemTemp.createTempSync(
        'bot-diary-delete-',
      );
      final previous = DataDirectory.current;
      DataDirectory.current = DataDirectory(temporary.path);
      addTearDown(() {
        DataDirectory.current = previous;
        temporary.deleteSync(recursive: true);
      });
      final mock = MockKernels.claudeCode;
      final workspace = Workspace(
        kernels: [
          KernelDescriptor(
            id: mock.id,
            label: mock.label,
            icon: mock.icon,
            description: mock.description,
            create: mock.create,
            catalog: ClaudeCatalog(
              local: ClaudeStorage(configDir: '${temporary.path}/isolated'),
            ),
          ),
        ],
      );
      addTearDown(workspace.dispose);
      final at = DateTime(2026, 11, 25, 9);
      final folders = MemoryBotFolders('${temporary.path}/bots');
      final bots = Bots(
        workspace: workspace,
        folders: folders,
        clock: () => at,
      );
      addTearDown(bots.dispose);
      await bots.start();
      final bot = bots.save(name: 'Diary fixture', identity: '', abilities: {});
      final cwd = bots.runtimeFolder(bot);
      Directory(cwd).createSync(recursive: true);
      const session = 'dcaab80f-725a-4219-9ae1-56033d166455';
      const target = 'd4b3c471-e776-4121-8d38-b1bd0e3dde01';
      const secret = 'A unique private diary message';
      final transcript = ManagedTranscripts.transcriptPath(cwd, session);
      SessionStore(sessionId: session, cwd: cwd, file: transcript).append({
        'type': 'user',
        'uuid': target,
        'message': {'role': 'user', 'content': secret},
      });
      final ref = MemoryHistoryReference(
        scope: MemoryHistoryScope.dm(bot.id),
        sessionId: session,
        messageId: target,
      );
      final diary = BotLegacyDiary(folders, bot);
      final day = bots.timelineFile(bot);
      const copy = '- 09:00 [private] Former name: $secret';
      const linked = '- 09:00 [private] Current name: $secret';
      const unrelated = '- 09:00 [private] Current name: A surviving note';
      diary.append(at, linked, original: ref);
      final withLinked = utf8.decode(folders.readFile(day)!);
      folders.writeFile(day, utf8.encode('$withLinked$unrelated\n$copy\n'));
      await workspace.load();
      expect(bots.canDeleteManagedOriginal(ref), isTrue);
      await expectLater(
        bots.deleteManagedOriginal(ref),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('possible copy'),
          ),
        ),
      );
      expect(File(transcript).readAsStringSync(), contains(secret));
      expect(utf8.decode(folders.readFile(day)!), contains(linked));
      folders.writeFile(day, utf8.encode('$withLinked$unrelated\n'));
      await bots.deleteManagedOriginal(ref);
      expect(File(transcript).readAsStringSync(), isNot(contains(secret)));
      expect(utf8.decode(folders.readFile(day)!), isNot(contains(secret)));
      expect(
        diary.messages(MemoryHistoryScope.bot(bot.id)).single.text,
        contains('A surviving note'),
      );
    },
  );

  test('backup preserves exact original bytes across edits and retries', () {
    final folders = MemoryBotFolders();
    final original = Uint8List.fromList([
      0xef,
      0xbb,
      0xbf,
      0x2d,
      0x20,
      0xff,
      13,
      10,
    ]);
    folders.writeFile(_source, original);
    final saved = _archive(folders)!;
    expect(saved.source, 'MEMORY.md');
    expect(saved.bytes, original);
    expect(saved.possiblyMirrored, isFalse);
    folders.writeFile(_source, utf8.encode('- changed meanwhile\n'));
    final retry = _archive(folders, authorityExists: true)!;
    expect(retry.bytes, original);
    expect(retry.digest, saved.digest);
    expect(retry.possiblyMirrored, isFalse);
    expect(utf8.decode(folders.readFile(_source)!), '- changed meanwhile\n');
  });

  test('backup is retryable and never overwrites a corrupt record', () {
    final folders = _InterruptedFolders();
    expect(_archive(folders), isNull);
    final source = utf8.encode('pre-mirror bytes\r\n\r\n');
    folders.writeFile(_source, source);
    folders.fail = true;
    expect(() => _archive(folders), throwsA(isA<FileSystemException>()));
    expect(folders.readFile('$_backup/memory.json'), isNull);
    expect(folders.readFile(_source), source);
    folders.fail = false;
    expect(_archive(folders, authorityExists: true)!.possiblyMirrored, isTrue);
    final path = '$_backup/memory.json';
    final decoded = jsonDecode(utf8.decode(folders.readFile(path)!)) as Map;
    decoded['bytes'] = base64Encode(utf8.encode('corrupt'));
    final corrupt = utf8.encode(jsonEncode(decoded));
    folders.writeFile(path, corrupt);
    expect(() => _archive(folders), throwsFormatException);
    expect(folders.readFile(path), corrupt);
    expect(folders.readFile(_source), source);
  });

  group('Owner migration', () {
    late Bots bots;
    late Bot bot;
    late MemoryBotFolders folders;
    late String memoryPath;
    const memory = BotMemoryMirror.memory;

    setUp(() async {
      final workspace = Workspace(kernels: [MockKernels.claudeCode]);
      addTearDown(workspace.dispose);
      folders = MemoryBotFolders();
      bots = Bots(workspace: workspace, folders: folders);
      addTearDown(bots.dispose);
      await bots.start();
      bot = bots.save(name: 'Migration fixture', identity: '', abilities: {});
      memoryPath = '${bot.folder}/MEMORY.md';
    });

    test('archives malformed MEMORY bytes before automatic parsing fails', () {
      final malformed = Uint8List.fromList([45, 32, 0xff, 13, 10]);
      folders.writeFile(memoryPath, malformed);
      expect(
        () => bots.userMemory(bot, keepLegacyIds: true),
        throwsFormatException,
      );
      expect(bots.ownerMemoryBackup(bot, memory)!.bytes, malformed);
      expect(folders.readFile(memoryPath), malformed);
      expect(folders.readFile('${bot.folder}/memory.json'), isNull);
    });

    test('restoring CRLF preferences preserves the legacy entries', () {
      final original = utf8.encode('- First  \r\n- Second\r\n');
      folders.writeFile(memoryPath, original);
      final saved = bots.userMemory(bot, keepLegacyIds: true);
      final authority = '${bot.folder}/memory.json';
      final before = folders.readFile(authority);
      for (var i = 0; i < 2; i++) {
        final preview = bots.previewOwnerMemoryMigration(
          bot,
          memory,
          restore: true,
        );
        expect(preview.hasChanges, isFalse);
        bots.applyOwnerMemoryMigration(preview);
        expect(folders.readFile(authority), before);
      }
      expect(saved.entries.map((entry) => entry.id), [1, 2]);
      expect(bots.ownerMemoryBackup(bot, memory)!.bytes, original);
    });

    test(
      'restoring CRLF facts does not duplicate an existing multiline note',
      () {
        const self = BotMemoryMirror.self;
        const people = BotMemoryMirror.people;
        final selfOriginal = utf8.encode(
          'Now: drafting\r\n- A fact\r\n  continued\r\n',
        );
        final peopleOriginal = utf8.encode(
          '## Lina\r\n- A note\r\n  continued\r\n',
        );
        folders.writeFile('${bot.folder}/SELF.md', selfOriginal);
        folders.writeFile('${bot.folder}/PEOPLE.md', peopleOriginal);
        final before = bots.privateFactMemory(bot).entries;
        for (final source in [self, people, self, people]) {
          final preview = bots.previewOwnerMemoryMigration(
            bot,
            source,
            restore: true,
          );
          expect(preview.hasChanges, isFalse);
          bots.applyOwnerMemoryMigration(preview);
        }
        expect(
          bots.privateFactMemory(bot).entries.map((entry) => entry.toJson()),
          before.map((entry) => entry.toJson()),
        );
        expect(bots.ownerMemoryBackup(bot, self)!.bytes, selfOriginal);
        expect(bots.ownerMemoryBackup(bot, people)!.bytes, peopleOriginal);
      },
    );

    test('preserves external edits and rejects stale confirmation', () {
      final original = utf8.encode('- Kept note\r\n');
      folders.writeFile(memoryPath, original);
      final kept = bots.userMemory(bot, keepLegacyIds: true).entries.single;
      final firstEdit = utf8.encode('- Kept note\n- External note\n');
      folders.writeFile(memoryPath, firstEdit);
      final stale = bots.previewOwnerMemoryMigration(bot, memory);
      bots.pinUserMemory(bot, kept.id, kept.revision, true);
      expect(folders.readFile(memoryPath), firstEdit);
      expect(bots.ownerMemoryMirrorChanged(bot, memory), isTrue);
      expect(() => bots.applyOwnerMemoryMigration(stale), throwsStateError);

      final preview = bots.previewOwnerMemoryMigration(bot, memory);
      expect(preview.added, 1);
      expect(preview.removed, 0);
      final laterEdit = utf8.encode('- Kept note\n- Later note\n');
      folders.writeFile(memoryPath, laterEdit);
      expect(() => bots.applyOwnerMemoryMigration(preview), throwsStateError);
      expect(folders.readFile(memoryPath), laterEdit);
      bots.applyOwnerMemoryMigration(
        bots.previewOwnerMemoryMigration(bot, memory),
      );
      expect(bots.ownerMemoryMirrorChanged(bot, memory), isFalse);
      final entries = bots.userMemory(bot).entries;
      expect(entries.map((entry) => entry.text), ['Kept note', 'Later note']);
      expect(entries.first.id, kept.id);
      expect(entries.first.revision, kept.revision + 1);
      expect(entries.first.pinned, isTrue);
      expect(bots.ownerMemoryBackup(bot, memory)!.bytes, original);
    });

    test(
      'restores missing archive notes as new entries and respects withdrawals',
      () {
        final original = utf8.encode('- Old note\r\n');
        folders.writeFile(memoryPath, original);
        final authority = '${bot.folder}/memory.json';
        folders.writeFile(
          authority,
          utf8.encode(
            jsonEncode(BotMemory.fromMarkdown('- Current note').toJson()),
          ),
        );
        final current = bots.userMemory(bot).entries.single;
        bots.pinUserMemory(bot, current.id, current.revision, true);
        final preview = bots.previewOwnerMemoryMigration(
          bot,
          memory,
          restore: true,
        );
        expect(preview.removed, 0);
        expect(preview.added, 1);
        bots.applyOwnerMemoryMigration(preview);
        final active = bots.userMemory(bot).entries;
        expect(active.first.pinned, isTrue);
        expect(active.first.id, current.id);
        expect(active.last.revision, 1);
        expect(active.last.id, isNot(current.id));
        expect(folders.readFile(memoryPath), original);
        final export =
            jsonDecode(utf8.decode(bots.ownerMemoryExport(bot, memory))) as Map;
        expect(
          export.keys,
          unorderedEquals(['version', 'scope', 'source', 'entries']),
        );
        expect(
          (export['entries'] as List).map(
            (entry) => (entry as Map)['markdown'],
          ),
          ['- Current note', '- Old note'],
        );
        bots.changeUserMemory(bot, [
          (
            action: BotMemoryAction.remove,
            id: active.last.id,
            revision: active.last.revision,
            text: null,
          ),
        ]);
        expect(
          () => bots.previewOwnerMemoryMigration(bot, memory, restore: true),
          throwsStateError,
        );
        expect(bots.userMemory(bot).entries.single.text, 'Current note');
      },
    );

    test('checks import budgets and keeps SELF and PEOPLE independent', () {
      const self = BotMemoryMirror.self;
      final selfPath = '${bot.folder}/SELF.md';
      final peoplePath = '${bot.folder}/PEOPLE.md';
      folders.writeFile(selfPath, utf8.encode('Now: planning\n- Knows Dart\n'));
      folders.writeFile(peoplePath, utf8.encode('## Lina\n- Likes tea\n'));
      final before = bots.privateFactMemory(bot).entries;
      final selfEdit = utf8.encode('Now: chatting\n- Knows Dart\n');
      folders.writeFile(selfPath, selfEdit);
      final tooLarge = utf8.encode('## Lina\n- ${'茶' * 2200}\n');
      folders.writeFile(peoplePath, tooLarge);
      expect(
        () => bots.previewOwnerMemoryMigration(bot, BotMemoryMirror.people),
        throwsStateError,
      );
      bots.applyOwnerMemoryMigration(
        bots.previewOwnerMemoryMigration(bot, self),
      );
      expect(bots.selfNow(bot), 'Now: chatting');
      expect(
        bots.privateFactMemory(bot).entries.map((entry) => entry.id),
        before.map((entry) => entry.id),
      );
      expect(folders.readFile(peoplePath), tooLarge);
      expect(
        bots.ownerMemoryMirrorChanged(bot, BotMemoryMirror.people),
        isTrue,
      );
    });
  });

  test('ambiguous legacy copies block deletion without editing the diary', () {
    final folders = MemoryBotFolders();
    final diary = BotLegacyDiary(folders, _bot);
    const original = MemoryHistoryReference(
      scope: _dm,
      sessionId: 'chat',
      messageId: 'saved',
    );
    const linked = '- 09:00 [private] Me: Target message';
    const unlinked = '- 09:01 [私聊] A former display name: Target message';
    const unaffected = '- 09:02 [private] Me: A different message';
    const header = '# 2026-11-25\r\n\r\n';
    final before = utf8.encode('$header$linked\r\n$unlinked\r\n$unaffected');
    folders.writeFile(_day, before);
    diary.bookmark(_day, 2, linked, _dm, original: original);
    expect(
      () => diary.redactOriginal(original, legacyText: ['Target message']),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('2026-11-25.md'),
        ),
      ),
    );
    expect(folders.readFile(_day), before);
    // The owner removed the ambiguous row while keeping the others intact.
    folders.writeFile(_day, utf8.encode('$header$linked\r\n\r\n$unaffected'));
    diary.redactOriginal(original, legacyText: ['Target message']);
    expect(folders.readFile(_day), utf8.encode('$header\r\n\r\n$unaffected'));
    expect(diary.messages(_owner).single.text, contains('A different message'));
  });

  test(
    'a replacement in the same diary slot receives its own source bookmark',
    () {
      final folders = MemoryBotFolders();
      final diary = BotLegacyDiary(folders, _bot);
      final date = DateTime(2026, 11, 25, 9);
      const line = '- 09:00 [private] Me: Same words';
      const original = MemoryHistoryReference(
        scope: _dm,
        sessionId: 'chat',
        messageId: 'old',
      );
      const next = MemoryHistoryReference(
        scope: _dm,
        sessionId: 'chat',
        messageId: 'new',
      );
      diary.append(date, line, original: original);
      final oldBytes = folders.readFile(_day)!;
      diary.redactOriginal(original);
      expect(folders.readFile(_day), isNull);
      diary.append(date, line, original: next);
      diary.redactOriginal(original);
      expect(folders.readFile(_day), isNotNull);
      diary.redactOriginal(next);
      expect(folders.readFile(_day), isNull);
      folders.writeFile(_day, oldBytes);
      expect(diary.messages(_owner), isEmpty);
    },
  );

  test(
    'only host bookmarks confer scope and source locators bind exact lines',
    () async {
      final folders = MemoryBotFolders();
      final diary = BotLegacyDiary(folders, _bot);
      const ambiguous = '- 09:01 [private] Me: owner-only secret 红茶';
      const groupSummary = '- 09:02 [group·same name #4] Me: archived 红茶';
      const attached = '- 09:03 [group·same name #7] Me: clipped 红茶…';
      folders.writeFile(
        _day,
        utf8.encode('# 2026-11-25\n\n$ambiguous\n$groupSummary\n$attached\n'),
      );
      diary.bookmark(
        _day,
        3,
        groupSummary,
        _group,
        role: MemoryHistoryRole.user,
      );
      const ref = MemoryHistoryReference(
        scope: _group,
        sessionId: 'room-1',
        messageId: '7',
      );
      diary.bookmark(_day, 4, attached, _group, original: ref);
      final original = MemoryHistoryMessage(
        reference: ref,
        role: MemoryHistoryRole.user,
        text: 'clipped 红茶 with the entire original text',
        time: DateTime(2026, 11, 25, 9, 3),
        sequence: 7,
      );
      var current = <MemoryHistoryMessage>[original];
      Future<List<MemoryHistoryMessage>> load(MemoryHistoryScope scope) async =>
          [
            ...diary.messages(scope),
            ...current.where((message) => message.reference.scope == scope),
          ];
      final index = MemoryHistoryIndex(
        source: MemoryHistorySource(
          load: load,
          read: (ref) async =>
              (await load(ref.scope))
                  .where((m) => m.reference == ref)
                  .firstOrNull,
        ),
      );
      MemoryHistoryAccess access(MemoryHistoryScope scope) =>
          MemoryHistoryAccess(
            current: scope,
            isAuthorized: (candidate) => candidate == scope,
          );
      const query = MemoryHistoryQuery(text: '红茶');
      expect((await index.search(access(_dm), query)).hits, isEmpty);
      final remote = MemoryHistoryAccess(
        current: _dm,
        isAuthorized: (scope) => scope.kind != MemoryHistoryScopeKind.bot,
        allowed: [_owner],
      );
      expect(
        (await index.search(
          remote,
          const MemoryHistoryQuery(text: '红茶', scope: _owner),
        )).hits,
        isEmpty,
      );
      final ownerHit = (await index.search(access(_owner), query)).hits.single;
      expect(ownerHit.snippet, contains('owner-only'));
      expect(ownerHit.kind, MemoryHistoryKind.diarySummary);
      expect(ownerHit.role, MemoryHistoryRole.unknown);
      expect(await index.locate(access(_dm), ownerHit.reference), isNull);
      final both = (await index.search(access(_group), query)).hits;
      expect(both.map((hit) => hit.kind), [
        MemoryHistoryKind.original,
        MemoryHistoryKind.diarySummary,
      ]);
      expect(both.first.reference, ref);
      final bookmark = both.last.reference;
      expect(
        (await index.browse(access(_group), bookmark))?.anchor.text,
        'archived 红茶',
      );
      current = [];
      final oldDiaryBytes = folders.readFile(_day)!;
      diary.redactOriginal(ref);
      expect(utf8.decode(folders.readFile(_day)!), isNot(contains(attached)));
      expect(
        (await index.search(access(_group), query)).hits.single.reference,
        bookmark,
      );
      folders.writeFile(_day, oldDiaryBytes);
      expect((await index.search(access(_owner), query)).hits, hasLength(1));
      expect(
        (await index.search(access(_group), query)).hits.single.reference,
        bookmark,
      );
      diary.forgetPrivate();
      expect((await index.search(access(_owner), query)).hits, isEmpty);
      expect(
        (await index.search(access(_group), query)).hits.single.reference,
        bookmark,
      );
      folders.writeFile(
        _day,
        utf8.encode(
          utf8
              .decode(folders.readFile(_day)!)
              .replaceFirst('archived', 'changed'),
        ),
      );
      expect(await index.locate(access(_group), bookmark), isNull);
      expect((await index.search(access(_group), query)).hits, isEmpty);
    },
  );
}

BotLegacyMarkdownBackup? _archive(
  MemoryBotFolders folders, {
  bool authorityExists = false,
}) => backupBotLegacyMarkdown(
  folders,
  backupFolder: _backup,
  sourcePath: _source,
  sourceKind: 'memory',
  authorityExists: authorityExists,
);

class _InterruptedFolders extends MemoryBotFolders {
  bool fail = false;

  @override
  void writeFileAtomically(String path, Uint8List bytes) {
    if (fail) throw FileSystemException('Simulated failure', path);
    super.writeFileAtomically(path, bytes);
  }
}
