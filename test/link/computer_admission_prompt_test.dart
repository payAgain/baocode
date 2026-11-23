import 'package:bao_link/bao_link.dart';
import 'package:baocode/keybindings/default_keybindings.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/link/computer_admission_review.dart';
import 'package:baocode/link/link_host.dart';
import 'package:baocode/settings/app_locale.dart';
import 'package:baocode/settings/app_settings.dart';
import 'package:baocode/settings/settings_dialog.dart';
import 'package:baocode/workbench.dart';
import 'package:baocode/workspace/window_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'desktop_mutual_pairing_test.dart' show Machine, machines;
import 'my_computers_test.dart' show pumpWorkbench, tap;

void main() {
  final desktop = TargetPlatformVariant({
    TargetPlatform.macOS,
    TargetPlatform.windows,
  });
  final panel = find.byType(ComputerApprovalPanel);

  testWidgets(
    'the workbench reviews an incoming join before granting access',
    (tester) => _withSponsor(tester, (sponsor, joiner) async {
      final preview = await _prepare(sponsor, joiner);
      await tester.pumpAndSettle();
      expect(sponsor.host.pendingGroupApproval, isNull);
      expect(panel, findsNothing);

      final result = _confirm(joiner.host, preview);
      await tester.pumpAndSettle();
      expect(sponsor.host.pendingGroupApproval?.member.id, joiner.host.id);
      expect(sponsor.host.permitsGroupWorkspace(joiner.host.id), isFalse);
      expect(joiner.host.computerGroup, isNull);
      expect(panel, findsOneWidget);
      expect(find.textContaining(joiner.name), findsWidgets);
      expect(find.text(preview.code), findsOneWidget);
      expect(find.textContaining('answer approvals'), findsOneWidget);

      await tap(tester, 'Approve group member');
      expect(await result, isNull);
      expect(panel, findsNothing);
      expect(sponsor.host.pendingGroupApproval, isNull);
      expect(sponsor.host.permitsGroupWorkspace(joiner.host.id), isTrue);
      await joiner.client.selectGroupMember(sponsor.host.id);
      expect(await joiner.client.peer!.call(LinkMethods.state), isA<Map>());
    }),
    variant: desktop,
  );

  testWidgets(
    'Later defers only the exact request',
    (tester) => _withSponsor(tester, (sponsor, joiner) async {
      final preview = await _prepare(sponsor, joiner);
      final result = _confirm(joiner.host, preview);
      await tester.pumpAndSettle();
      final original = sponsor.host.pendingGroupApproval;
      expect(original, isNotNull);
      expect(panel, findsOneWidget);

      await tap(tester, 'Later');
      expect(panel, findsNothing);
      expect(sponsor.host.pendingGroupApproval, same(original));
      expect(joiner.host.computerGroup, isNull);

      joiner.host.cancelGroupJoin(preview);
      expect(await result, isNotNull);
      await tester.pumpAndSettle();
      expect(sponsor.host.pendingGroupApproval, isNull);
      expect(panel, findsNothing);

      final replacement = await _prepare(sponsor, joiner);
      expect(replacement.code, preview.code);
      final replacementResult = _confirm(joiner.host, replacement);
      await tester.pumpAndSettle();
      expect(sponsor.host.pendingGroupApproval, isNot(same(original)));
      expect(panel, findsOneWidget);
      expect(find.text(replacement.code), findsOneWidget);
      await tap(tester, 'Decline group member');
      expect(await replacementResult, isA<LinkRemoteException>());
      expect(panel, findsNothing);
      expect(sponsor.host.pendingGroupApproval, isNull);
      expect(joiner.host.computerGroup, isNull);
    }),
    variant: desktop,
  );

  testWidgets(
    'withdrawal removes its own route beneath Settings',
    (tester) => _withSponsor(tester, (sponsor, joiner) async {
      final preview = await _prepare(sponsor, joiner);
      final result = _confirm(joiner.host, preview);
      await tester.pumpAndSettle();
      expect(panel, findsOneWidget);

      await _openSettings(tester);
      final settings = find.byType(SettingsDialog);
      final settingsRoute = ModalRoute.of(tester.element(settings));
      expect(settingsRoute?.isCurrent, isTrue);
      expect(panel, findsOneWidget);

      joiner.host.cancelGroupJoin(preview);
      expect(await result, isNotNull);
      await tester.pumpAndSettle();
      expect(settings, findsOneWidget);
      expect(settingsRoute?.isCurrent, isTrue);
      expect(sponsor.host.pendingGroupApproval, isNull);
      expect(panel, findsNothing);
    }),
    variant: desktop,
  );

  testWidgets(
    'My computers in Settings owns an incoming review inline',
    (tester) => _withSponsor(tester, (sponsor, joiner) async {
      await _openSettings(tester);
      await tap(tester, 'Mobile');
      await tap(tester, 'My computers');

      final preview = await _prepare(sponsor, joiner);
      final result = _confirm(joiner.host, preview);
      await tester.pumpAndSettle();
      expect(panel, findsOneWidget);
      expect(find.text(preview.code), findsOneWidget);
      expect(find.text('Later'), findsNothing);

      await tap(tester, 'Close');
      expect(find.byType(SettingsDialog), findsOneWidget);
      expect(panel, findsNothing);
      expect(sponsor.host.pendingGroupApproval, isNotNull);
      expect(sponsor.host.permitsGroupWorkspace(joiner.host.id), isFalse);

      await tap(tester, 'My computers');
      expect(panel, findsOneWidget);
      await tap(tester, 'Decline group member');
      expect(await result, isA<LinkRemoteException>());
      expect(sponsor.host.pendingGroupApproval, isNull);
      expect(joiner.host.computerGroup, isNull);
      expect(panel, findsNothing);
      expect(find.text('Trusted computers · 1'), findsOneWidget);
      await tap(tester, 'Close');
      expect(find.byType(SettingsDialog), findsOneWidget);
    }),
    variant: desktop,
  );

  testWidgets('a separate workbench does not own this host’s request', (
    tester,
  ) async {
    final (sponsor, joiner) = await machines();
    await sponsor.host.createComputerGroup();
    final locale = AppLocale();
    final showSponsor = ValueNotifier(true);
    addTearDown(locale.dispose);
    addTearDown(showSponsor.dispose);
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Workbench workbench(Machine machine) => Workbench(
      key: ValueKey(machine.host.id),
      workspace: machine.workspace,
      settings: AppSettings(locale: locale, link: machine.host),
    );
    try {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Row(
            children: [
              Expanded(
                child: ValueListenableBuilder(
                  valueListenable: showSponsor,
                  builder: (context, show, _) =>
                      show ? workbench(sponsor) : const SizedBox.shrink(),
                ),
              ),
              Expanded(child: workbench(joiner)),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find
            .descendant(
              of: find.byKey(ValueKey(joiner.host.id)),
              matching: find.text('My computers'),
            )
            .hitTestable(),
      );
      await tester.pumpAndSettle();
      final manual = ModalRoute.of(tester.element(find.text('Use invite')));
      expect(manual?.isCurrent, isTrue);

      final preview = await _prepare(sponsor, joiner);
      final result = _confirm(joiner.host, preview);
      await tester.pumpAndSettle();
      final request = sponsor.host.pendingGroupApproval;
      expect(request, isNotNull);
      expect(
        tester.widget<ComputerApprovalPanel>(panel).host,
        same(sponsor.host),
      );

      showSponsor.value = false;
      await tester.pumpAndSettle();
      expect(panel, findsNothing);
      expect(manual?.isCurrent, isTrue);
      expect(sponsor.host.pendingGroupApproval, same(request));

      showSponsor.value = true;
      await tester.pumpAndSettle();
      expect(panel, findsOneWidget);
      expect(
        tester.widget<ComputerApprovalPanel>(panel).request,
        same(request),
      );
      await tap(tester, 'Decline group member');
      expect(await result, isA<LinkRemoteException>());
      expect(manual?.isCurrent, isTrue);
      expect(panel, findsNothing);
    } finally {
      await _finish(tester, sponsor, joiner);
    }
  }, variant: desktop);
}

Future<void> _withSponsor(
  WidgetTester tester,
  Future<void> Function(Machine sponsor, Machine joiner) exercise,
) async {
  final (sponsor, joiner) = await machines();
  await sponsor.host.createComputerGroup();
  await pumpWorkbench(tester, sponsor);
  try {
    await exercise(sponsor, joiner);
  } finally {
    await _finish(tester, sponsor, joiner);
  }
}

Future<void> _finish(
  WidgetTester tester,
  Machine sponsor,
  Machine joiner,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await sponsor.host.pauseGroupConnections();
  await joiner.host.pauseGroupConnections();
  await tester.pump();
}

Future<ComputerGroupJoinPreview> _prepare(Machine sponsor, Machine joiner) =>
    joiner.host.prepareGroupJoin(sponsor.host.createGroupInvite());

Future<Object?> _confirm(LinkHost host, ComputerGroupJoinPreview preview) =>
    host
        .confirmGroupJoin(preview)
        .then<Object?>((_) => null, onError: (Object error) => error);

Future<void> _openSettings(WidgetTester tester) async {
  WindowControls.menuCommandsOf(0)!.call(openSettingsCommandId);
  await tester.pumpAndSettle();
}
