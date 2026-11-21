import 'package:baocode/bots/bot_folders.dart';
import 'package:baocode/bots/bots.dart';
import 'package:baocode/bots/desktop_bot_page.dart';
import 'package:baocode/link/link_host.dart';
import 'package:baocode/main.dart';
import 'package:baocode/settings/app_locale.dart';
import 'package:baocode/settings/app_settings.dart';
import 'package:baocode/sidebar/sidebar.dart';
import 'package:baocode/workspace/preference_store.dart';
import 'package:baocode/workspace/workspace.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'the Bot sidebar entry opens private chat and returns to the same project',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final workspace = Workspace.mock();
      final projectChat = workspace.current;
      final bots = Bots(
        workspace: workspace,
        folders: MemoryBotFolders(),
        store: MemoryPreferenceStore(),
        computer: () async => 'Test Mac',
      );
      await bots.start();
      final link = LinkHost(workspace: workspace, bots: bots);
      await tester.pumpWidget(
        BaoCodeApp(
          workspace: workspace,
          settings: AppSettings(locale: AppLocale(), link: link),
        ),
      );
      await tester.pump();
      final entry = find.descendant(
        of: find.byType(Sidebar),
        matching: find.text('Bot'),
      );
      expect(entry, findsOneWidget);
      await tester.tap(entry);
      await tester.pump();
      expect(find.byType(DesktopBotPage), findsOneWidget);
      expect(workspace.current, same(projectChat));
      final assistant = bots.bots.firstWhere((bot) => bot.assistant);
      expect(workspace.listsInSidebar(bots.threadFor(assistant)), isFalse);
      tester.widget<DesktopBotPage>(find.byType(DesktopBotPage)).onBack();
      await tester.pump();
      expect(find.byType(DesktopBotPage), findsNothing);
      expect(workspace.current, same(projectChat));
      await tester.pumpWidget(const SizedBox.shrink());
      bots.dispose();
      link.dispose();
    },
  );
}
