import 'dart:io';
import 'dart:ui' as ui;

import 'package:bao_editor/monaco/vs/workbench/services/themes/common/color_theme_data.dart';
import 'package:bao_editor/monaco/vs/workbench/services/themes/common/workbench_theme_service.dart'
    show IThemeExtensionPoint;
import 'package:bao_editor/textmate/textmate_manifest.dart';
import 'package:bao_link/bao_link.dart';
import 'package:baocode/chat/chat_models.dart';
import 'package:baocode/chat/widgets/conversation_card_header.dart';
import 'package:baocode/l10n/app_localizations.dart';
import 'package:baocode/link/chat_codec.dart';
import 'package:baocode/link/desktop_host_composer.dart';
import 'package:baocode/link/desktop_host_connection.dart';
import 'package:baocode/settings/app_locale.dart';
import 'package:baocode/settings/app_settings.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:baocode/theme/code_font.dart';
import 'package:baocode/theme/workbench_theme.dart';
import 'package:baocode/workbench.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'desktop_mutual_pairing_test.dart' show Machine;
import 'my_computers_test.dart' show admit, tap, tapMember;

const _output = String.fromEnvironment('BAOCODE_HOST_ACTIVITY_PREVIEW');
const _hostName = '工作室 Mac mini';
const _session = 'preview-session';
const _chatTitle = '整理发布检查清单';
const _prompt = '帮我查一下发布前还需要核对什么。';
const _project = ProjectInfo(id: 'docs', name: '团队工作台', path: '/fixture/docs');

void main() {
  testWidgets(
    'capture host activity in the Chinese workbench',
    (tester) async {
      final initialTheme = WorkbenchThemeService.instance;
      final initialCodeFonts = CodeFont.families.value;
      await tester.runAsync(_loadPreviewTheme);
      CodeFont.families.value = const ['Menlo'];
      addTearDown(() {
        CodeFont.families.value = initialCodeFonts;
        WorkbenchThemeService.instance.dispose();
        WorkbenchThemeService.instance = initialTheme;
      });
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1400, 850);
      addTearDown(tester.view.reset);
      final network = MemoryLinkNetwork();
      final viewer = Machine(network, '随身 MacBook Air');
      final owner = Machine(network, _hostName);
      addTearDown(viewer.close);
      addTearDown(owner.close);
      await viewer.host.load();
      await owner.host.load();
      await viewer.host.createComputerGroup();
      await admit(viewer, owner);

      final (clientWire, hostWire) = MemoryLinkConnection.pair(
        a: viewer.host.id,
        b: owner.host.id,
      );
      final methods = <String>[];
      final fixture = _Fixture();
      final accepting = LinkPeer.accept(
        hostWire,
        onRequest: (method, args) {
          methods.add(method);
          return fixture.reply(method, args);
        },
      );
      final peer = await LinkPeer.connect(
        clientWire,
        mirror: LinkSessionMirror(),
      );
      final host = await accepting;
      final theme = buildAppTheme();
      TextTheme localized(TextTheme text) => text.apply(
        fontFamily: 'Activity CJK',
        fontFamilyFallback: const ['Activity Unicode'],
      );
      final surface = GlobalKey();
      final appLocale = AppLocale();
      addTearDown(appLocale.dispose);

      final catalog = find.byKey(const ValueKey('host-catalog'));
      final close = find.byTooltip('关闭项目侧栏');
      final composer = find.byType(DesktopHostComposer);
      final header = find.byType(ConversationCardHeader);
      final activity = find.byTooltip('项目侧栏');
      final semantics = tester.ensureSemantics();

      try {
        await tester.pumpWidget(
          RepaintBoundary(
            key: surface,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              locale: const Locale('zh', 'CN'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              theme: theme.copyWith(
                textTheme: localized(theme.textTheme),
                primaryTextTheme: localized(theme.primaryTextTheme),
              ),
              home: Workbench(
                workspace: viewer.workspace,
                settings: AppSettings(locale: appLocale, link: viewer.host),
                createDesktopHostConnection: () => _FixtureConnection(peer),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tap(tester, '我的电脑');
        await tapMember(tester, owner);
        await tap(tester, _chatTitle);
        expect(find.text(_prompt).hitTestable(), findsOneWidget);
        final composerState = tester.state(composer);
        await tester.tap(activity.hitTestable());
        await tester.pumpAndSettle();
        final sidebar = find.byKey(
          const ValueKey('desktop-remote-project-sidebar'),
        );
        expect(sidebar, findsOneWidget);
        await tap(tester, 'checklist.txt');
        expect(find.text('只读文件预览').hitTestable(), findsOneWidget);
        await tap(tester, '任务');
        expect(find.text('此会话没有任务。').hitTestable(), findsOneWidget);
        expect(
          tester.getRect(catalog).right,
          lessThan(tester.getRect(header).left),
        );
        expect(
          tester.getRect(header).right,
          lessThan(tester.getRect(close).left),
        );
        expect(tester.state(composer), same(composerState));
        expect(
          tester
              .getSemantics(find.bySemanticsLabel('任务'))
              .flagsCollection
              .isSelected,
          ui.Tristate.isTrue,
        );
        await _capture(tester, surface, 'wide-empty-tasks.png');

        await tap(tester, '更改');
        expect(find.text('此会话没有待处理的更改。').hitTestable(), findsOneWidget);
        expect(
          tester
              .getSemantics(find.bySemanticsLabel('更改'))
              .flagsCollection
              .isSelected,
          ui.Tristate.isTrue,
        );
        await _capture(tester, surface, 'wide-empty-changes.png');
        await tap(tester, '文件');
        expect(find.text('只读文件预览').hitTestable(), findsOneWidget);
        expect(
          methods.where((method) => method == LinkMethods.read),
          hasLength(1),
        );
        await tap(tester, '扩展');
        expect(find.text('主机未报告所选项目的扩展。').hitTestable(), findsOneWidget);
        await _capture(tester, surface, 'wide-empty-extensions.png');

        fixture.populated = true;
        host.emit(LinkEvents.session, fixture.update());
        await tester.pumpAndSettle();
        await tap(tester, '刷新');
        expect(find.text('发布检查技能').hitTestable(), findsOneWidget);
        await _capture(tester, surface, 'wide-extensions.png');
        await tap(tester, '更改');
        expect(
          find.text('docs/release-checklist.md').hitTestable(),
          findsOneWidget,
        );
        await _capture(tester, surface, 'wide-changes.png');
        await tap(tester, '任务');
        expect(find.text('执行发布前检查').hitTestable(), findsOneWidget);
        await _capture(tester, surface, 'wide-tasks.png');

        tester.view.physicalSize = const Size(520, 730);
        await tester.pumpAndSettle();
        expect(composer.hitTestable(), findsNothing);
        expect(close.hitTestable(), findsOneWidget);
        expect(find.text('执行发布前检查').hitTestable(), findsOneWidget);
        await _capture(tester, surface, 'narrow-tasks.png');
        await tap(tester, '查看输出');
        expect(find.text('检查通过：文档索引已更新。').hitTestable(), findsOneWidget);
        await _capture(tester, surface, 'narrow-output.png');
        await tester.tap(close.hitTestable());
        await tester.pumpAndSettle();
        expect(close, findsNothing);
        expect(tester.state(composer), same(composerState));
        expect(
          methods.where((method) => method == LinkMethods.open),
          hasLength(1),
        );
      } finally {
        semantics.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await peer.close();
        await host.close();
        await viewer.host.pauseGroupConnections();
        await owner.host.pauseGroupConnections();
      }
    },
    skip: _output.isEmpty,
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}

class _Fixture {
  final _slimmer = LinkSessionSlimmer();
  bool populated = false;

  Object? reply(String method, Map<String, Object?> args) => switch (method) {
    LinkMethods.state => LinkState(
      device: const DeviceInfo(name: _hostName, kind: 'mac', system: 'macOS'),
      projects: const [
        _project,
        ProjectInfo(id: 'design', name: '设计文档', path: '/fixture/design'),
      ],
      sessions: [
        SessionSummary(
          id: _session,
          project: _project.id,
          title: _chatTitle,
          updatedAt: DateTime(2026, 11, 24),
        ),
        SessionSummary(
          id: 'other',
          project: _project.id,
          title: '检查文档目录',
          updatedAt: DateTime(2026, 11, 23),
        ),
      ],
    ).toJson(),
    LinkMethods.open when args['session'] == _session => update(full: true),
    LinkMethods.folder => {
      'files': ['checklist.txt'],
      'folders': [],
    },
    LinkMethods.read when args['path'] == 'checklist.txt' => {'text': '只读文件预览'},
    LinkMethods.extensions => {
      'items': [
        if (populated) ...[
          const LinkExtension(
            kind: 'skill',
            scope: 'project',
            project: 'docs',
            name: '发布检查技能',
            description: '核对版本、文档和发布记录。',
          ).toJson(),
          const LinkExtension(
            kind: 'mcp',
            scope: 'user',
            name: '文档索引',
            enabled: true,
            description: '供主机查阅项目文档。',
          ).toJson(),
        ],
      ],
    },
    LinkMethods.watchOutput => {'text': '检查通过：文档索引已更新。', 'offset': 42},
    LinkMethods.unwatchOutput || LinkMethods.close || LinkMethods.away => null,
    _ => throw StateError('Unexpected preview method: $method'),
  };

  Map<String, Object?> update({bool full = false}) => _slimmer.encode(
    LinkSessionUpdate(
      session: _session,
      start: 0,
      count: 2,
      items: const <ChatItem>[
        UserMessageItem(text: _prompt),
        AssistantTextItem(
          '发布前请核对这三项：\n\n- 文档中的版本号与发布记录一致。\n- 检查清单覆盖新增功能。\n- 在发布前运行测试并记录结果。',
        ),
      ].map(ChatCodec.encode).toList(),
      tasks: populated
          ? [
              LinkTask(
                id: 'check',
                kind: 'command',
                status: 'running',
                description: '执行发布前检查',
                startedAt: DateTime(2026, 11, 24),
                command: 'dart run tool/check_release.dart',
                output: true,
              ),
              LinkTask(
                id: 'review',
                kind: 'agent',
                status: 'succeeded',
                description: '核对文档目录',
                startedAt: DateTime(2026, 11, 24),
                summary: '已核对发布说明和文档索引。',
              ),
            ]
          : const [],
      changes: populated
          ? const [
              {
                'path': 'docs/release-checklist.md',
                'added': 14,
                'removed': 2,
                'revision': 'fixture-1',
                'preview': true,
              },
              {'path': 'docs/index.md', 'added': 3, 'removed': 1},
            ]
          : const [],
    ),
    full: full,
  );
}

class _FixtureConnection extends ChangeNotifier
    implements DesktopHostConnection {
  _FixtureConnection(this.peer);

  @override
  final LinkPeer peer;
  @override
  String? selectedHostId;
  @override
  String get hostName => _hostName;
  @override
  bool get groupSelected => selectedHostId != null;
  @override
  bool get busy => false;
  @override
  String? get error => null;
  @override
  Future<void> load() async {}
  @override
  Future<void> stopDiscovery() async {}
  @override
  Future<void> selectGroupMember(String id) async {
    if (id != peer.remote) throw StateError('Unexpected fixture host');
    selectedHostId = id;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _loadPreviewTheme() async {
  const path = 'themes/theme-bao/themes/bao-dark-color-theme.json';
  final theme = ColorThemeData.fromExtensionTheme(
    const IThemeExtensionPoint(
      id: 'Bao Dark',
      label: 'Bao Dark',
      path: path,
      uiTheme: 'vs-dark',
    ),
    path,
    extensionId: 'baocode.theme-bao',
  );
  await theme.ensureLoaded(
    (file) => File('$textMateAssetRoot/$file').readAsString(),
  );
  WorkbenchThemeService.instance = WorkbenchThemeService(initial: theme);
  Future<void> load(String family, Future<ByteData> data) =>
      (FontLoader(family)..addFont(data)).load();
  Future<ByteData> read(String path) async =>
      ByteData.sublistView(await File(path).readAsBytes());
  await Future.wait([
    load('Activity CJK', read('/System/Library/Fonts/Hiragino Sans GB.ttc')),
    load('Menlo', read('/System/Library/Fonts/Menlo.ttc')),
    load(
      'Activity Unicode',
      read('/System/Library/Fonts/Supplemental/Arial Unicode.ttf'),
    ),
    load('MaterialIcons', rootBundle.load('fonts/MaterialIcons-Regular.otf')),
    load('codicon', read('assets/codicons/codicon.ttf')),
  ]);
}

Future<void> _capture(
  WidgetTester tester,
  GlobalKey surface,
  String name,
) async {
  expect(tester.takeException(), isNull);
  final boundary =
      surface.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    await Directory(_output).create(recursive: true);
    final image = await boundary.toImage(pixelRatio: 2);
    try {
      final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      await File('$_output/$name').writeAsBytes(png.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}
