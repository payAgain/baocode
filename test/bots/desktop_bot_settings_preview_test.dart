import 'dart:io';
import 'dart:ui' as ui;

import 'package:bao_editor/monaco/vs/workbench/services/themes/common/color_theme_data.dart';
import 'package:bao_editor/monaco/vs/workbench/services/themes/common/workbench_theme_service.dart'
    show IThemeExtensionPoint;
import 'package:bao_editor/textmate/textmate_manifest.dart';
import 'package:bao_link/bao_link.dart';
import 'package:baocode/bots/bot_folders.dart';
import 'package:baocode/bots/bots.dart';
import 'package:baocode/bots/desktop_bot_settings.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/link/desktop_remote_people.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:baocode/theme/workbench_theme.dart';
import 'package:baocode/workspace/preference_store.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// Opt-in captures of production widgets with fixture data and the Bao Dark theme.
const _output = String.fromEnvironment('BAOCODE_BOT_PROFILE_PREVIEW');
const _name = '纸鹤笔记助手';
const _signature = '把零散想法整理成笔记';
const _identity = '帮我整理会议纪要、待办和阅读笔记。';
const _style = '先给结论，再列出需要跟进的事项。';

void main() {
  testWidgets(
    'capture the Chinese local and paired Bot editors and reviews',
    (tester) async {
      await tester.runAsync(_loadThemeAndFonts);
      final theme = buildAppTheme();
      final previewTheme = theme.copyWith(
        textTheme: theme.textTheme.apply(
          fontFamily: 'Preview CJK',
          fontFamilyFallback: const ['Preview Unicode'],
        ),
        primaryTextTheme: theme.primaryTextTheme.apply(
          fontFamily: 'Preview CJK',
          fontFamilyFallback: const ['Preview Unicode'],
        ),
      );
      final workspace = Workspace(
        preferences: MemoryPreferenceStore(),
        drafts: MemoryPreferenceStore(),
      );
      final bots = Bots(
        workspace: workspace,
        folders: MemoryBotFolders(),
        store: MemoryPreferenceStore(),
      );
      addTearDown(workspace.dispose);
      addTearDown(bots.dispose);
      final bot = bots.save(
        name: _name,
        signature: _signature,
        identity: _identity,
        style: _style,
        chatOnly: true,
        abilities: {},
      );
      final (clientWire, hostWire) = MemoryLinkConnection.pair();
      final pending = LinkPeer.accept(
        hostWire,
        onRequest: (method, args) => switch (method) {
          LinkMethods.state => {
            'device': const DeviceInfo(
              name: '测试主机',
              kind: 'mac',
              system: '',
            ).toJson(),
            'bots': [
              const LinkBot(
                id: 'fixture',
                name: _name,
                avatar: 'avatar-fixture.png',
                signature: _signature,
                identity: _identity,
                style: _style,
                chatOnly: true,
                writesFirst: false,
              ).toJson(),
            ],
            'groups': [],
          },
          LinkMethods.botAvatar => null,
          _ => throw StateError('Preview sent an unexpected request: $method'),
        },
      );
      final peer = await LinkPeer.connect(clientWire);
      final host = await pending;
      final surface = GlobalKey();
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      Future<void> mount(Widget child) async {
        await tester.pumpWidget(
          RepaintBoundary(
            key: surface,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: previewTheme,
              locale: const Locale('zh', 'CN'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(body: child),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      for (final (label, size) in [
        ('normal', const Size(416, 780)),
        ('narrow', const Size(236, 540)),
      ]) {
        tester.view.physicalSize = size;
        await mount(
          DesktopBotSettings(bots: bots, bot: bot, drawer: true, onBack: () {}),
        );
        expect(find.text('基本资料').hitTestable(), findsOneWidget);
        expect(find.text('保存').hitTestable(), findsOneWidget);
        await _capture(tester, surface, 'local-edit-$label.png');
        final delete = find.text('删除 Bot');
        await tester.ensureVisible(delete);
        await tester.pump();
        await tester.tap(delete);
        await tester.pumpAndSettle();
        expect(find.text('删除 $_name？').hitTestable(), findsOneWidget);
        await _capture(tester, surface, 'local-delete-$label.png');
        await tester.tap(find.text('取消').hitTestable());
        await tester.pumpAndSettle();

        await mount(
          DesktopRemotePeopleManager(
            peer: peer,
            initialBotId: 'fixture',
            onClose: () {},
          ),
        );
        expect(find.text('基本资料').hitTestable(), findsOneWidget);
        await _capture(tester, surface, 'remote-edit-$label.png');
        final avatar = find.widgetWithText(TextFormField, '头像表情');
        await tester.ensureVisible(avatar);
        await tester.enterText(avatar, '纸鹤');
        await tester.pumpAndSettle();
        await tester.tap(find.text('保存').hitTestable());
        await tester.pumpAndSettle();
        expect(find.text('更换 $_name 的头像？').hitTestable(), findsOneWidget);
        await _capture(tester, surface, 'remote-replace-$label.png');
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await peer.close();
      await host.close();
    },
    skip: _output.isEmpty,
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}

Future<void> _loadThemeAndFonts() async {
  const path = 'themes/theme-bao/themes/bao-dark-color-theme.json';
  final dark = ColorThemeData.fromExtensionTheme(
    const IThemeExtensionPoint(
      id: 'Bao Dark',
      label: 'Bao Dark',
      path: path,
      uiTheme: 'vs-dark',
    ),
    path,
    extensionId: 'baocode.theme-bao',
  );
  await dark.ensureLoaded(
    (file) => File('$textMateAssetRoot/$file').readAsString(),
  );
  WorkbenchThemeService.instance = WorkbenchThemeService(initial: dark);
  Future<void> load(String family, Future<ByteData> data) =>
      (FontLoader(family)..addFont(data)).load();
  Future<ByteData> read(String path) async =>
      ByteData.sublistView(await File(path).readAsBytes());
  await Future.wait([
    load('Preview CJK', read('/System/Library/Fonts/Hiragino Sans GB.ttc')),
    load(
      'Preview Unicode',
      read('/System/Library/Fonts/Supplemental/Arial Unicode.ttf'),
    ),
    load('MaterialIcons', rootBundle.load('fonts/MaterialIcons-Regular.otf')),
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
