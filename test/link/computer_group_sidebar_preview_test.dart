import 'dart:io';
import 'dart:ui' as ui;

import 'package:bao_editor/monaco/vs/workbench/services/themes/common/color_theme_data.dart';
import 'package:bao_editor/monaco/vs/workbench/services/themes/common/workbench_theme_service.dart'
    show IThemeExtensionPoint;
import 'package:bao_editor/textmate/textmate_manifest.dart';
import 'package:bao_link/bao_link.dart';
import 'package:baocode/theme/app_theme.dart';
import 'package:baocode/theme/workbench_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'desktop_mutual_pairing_test.dart' show Machine;
import 'my_computers_test.dart' show admit, pumpWorkbench, tap, tapMember;

// Opt-in screenshots from the real workbench with isolated, in-memory peers.
const output = String.fromEnvironment('BAOCODE_GROUP_SIDEBAR_PREVIEW');

void main() {
  testWidgets(
    'render the Chinese computer sidebar and a narrow join review',
    (tester) async {
      await tester.runAsync(_loadPreviewThemeAndFonts);
      final surface = GlobalKey();
      final theme = buildAppTheme();
      final cjkTheme = theme.copyWith(
        textTheme: theme.textTheme.apply(
          fontFamily: 'Preview CJK',
          fontFamilyFallback: const ['Preview Unicode'],
        ),
        primaryTextTheme: theme.primaryTextTheme.apply(
          fontFamily: 'Preview CJK',
          fontFamilyFallback: const ['Preview Unicode'],
        ),
      );
      final network = MemoryLinkNetwork();
      final local = Machine(network, '随身 MacBook Air');
      final remote = Machine(network, '工作室 Mac mini');
      final offline = Machine(network, '家里的 Windows 电脑');
      final applicant = Machine(network, '新设备 MacBook Pro');
      final all = [local, remote, offline, applicant];
      for (final machine in all) {
        addTearDown(machine.close);
        await machine.host.load();
      }
      await local.host.createComputerGroup();
      await admit(local, remote);
      await admit(local, offline);
      network.unreachable.add(offline.host.id);
      final projects = remote.workspace.projects;
      for (final (project, name) in projects.indexed.map(
        (entry) => (entry.$2, ['团队工作台', '设计文档', '服务接口'][entry.$1]),
      )) {
        remote.workspace.renameProject(project, name);
      }
      await pumpWorkbench(
        tester,
        local,
        size: const Size(1240, 800),
        locale: const Locale('zh', 'CN'),
        theme: cjkTheme,
        surface: surface,
      );
      await tap(tester, '我的电脑');
      await tapMember(tester, remote);
      expect(find.text('团队工作台'), findsOneWidget);
      expect(find.text('工作区已连接'), findsOneWidget);
      expect(find.text('暂时无法连接'), findsOneWidget);
      await _capture(tester, surface, '电脑侧栏-zh-CN.png');

      final invite = local.host.createGroupInvite();
      await pumpWorkbench(
        tester,
        applicant,
        locale: const Locale('zh', 'CN'),
        theme: cjkTheme,
        surface: surface,
      );
      await tap(tester, '我的电脑');
      tester.view.physicalSize = const Size(400, 620);
      await tester.pumpAndSettle();
      await tap(tester, '使用邀请');
      await tester.enterText(
        find.byKey(const ValueKey('computer-group-invite')),
        invite,
      );
      await tester.pump();
      await tap(tester, '查看邀请');
      expect(find.text('核对设备'), findsOneWidget);
      expect(find.text('加入并共享工作区').hitTestable(), findsOneWidget);
      await _capture(tester, surface, '加入审批-zh-CN-窄窗口.png');
      await tap(tester, '取消加入');
      await tester.pumpWidget(const SizedBox.shrink());
      for (final machine in all) {
        await machine.host.pauseGroupConnections();
      }
    },
    skip: output.isEmpty,
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}

Future<void> _loadPreviewThemeAndFonts() async {
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
  Future<void> font(String family, Future<ByteData> data) =>
      (FontLoader(family)..addFont(data)).load();
  Future<ByteData> read(String path) async =>
      ByteData.sublistView(await File(path).readAsBytes());
  await Future.wait([
    font('Preview CJK', read('/System/Library/Fonts/Hiragino Sans GB.ttc')),
    font(
      'Preview Unicode',
      read('/System/Library/Fonts/Supplemental/Arial Unicode.ttf'),
    ),
    font('MaterialIcons', rootBundle.load('fonts/MaterialIcons-Regular.otf')),
    font('codicon', read('assets/codicons/codicon.ttf')),
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
    await Directory(output).create(recursive: true);
    final image = await boundary.toImage(pixelRatio: 2);
    try {
      final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      await File('$output/$name').writeAsBytes(png.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}
