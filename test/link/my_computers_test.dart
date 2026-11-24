import 'dart:convert';

import 'package:bao_link/bao_link.dart';
import 'package:baocode/keybindings/default_keybindings.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/link/desktop_host_page.dart';
import 'package:baocode/settings/app_locale.dart';
import 'package:baocode/settings/app_settings.dart';
import 'package:baocode/settings/settings_dialog.dart';
import 'package:baocode/settings/user_settings.dart';
import 'package:baocode/workbench.dart';
import 'package:baocode/workspace/window_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'desktop_mutual_pairing_test.dart' show Machine, machines;

void main() {
  final desktop = TargetPlatformVariant.only(TargetPlatform.macOS);

  testWidgets(
    'device details stay out of the workspace picker until requested',
    (tester) async {
      final (a, b) = await machines();
      await a.host.createComputerGroup();
      await admit(a, b);
      await pumpWorkbench(tester, b);
      await tap(tester, 'My computers');
      expect(find.text(a.host.fingerprint), findsNothing);
      expect(find.text('Remove ${a.name}'), findsNothing);
      expect(find.text('Open workspace').hitTestable(), findsOneWidget);
      await tester.tap(find.byKey(ValueKey(('computer-menu', a.host.id))));
      await tester.pumpAndSettle();
      await tap(tester, 'Device details');
      expect(find.text(a.host.fingerprint), findsOneWidget);
      await tap(tester, 'Close');
      expect(find.text('Open workspace').hitTestable(), findsOneWidget);
      expect(b.host.computerGroup!.active.containsKey(a.host.id), isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      await a.host.pauseGroupConnections();
      await b.host.pauseGroupConnections();
    },
    variant: desktop,
  );

  testWidgets('join review explains identity, code and workspace access', (
    tester,
  ) async {
    final (sponsor, joiner) = await machines();
    await sponsor.host.createComputerGroup();
    await pumpWorkbench(tester, joiner);
    await tap(tester, 'My computers');
    await tap(tester, 'Use invite');
    await tester.enterText(
      find.byKey(const ValueKey('computer-group-invite')),
      sponsor.host.createGroupInvite(),
    );
    await tester.pump();
    await tap(tester, 'Review invite');
    expect(find.text('Join the group through ${sponsor.name}'), findsOneWidget);
    expect(find.text('Verify this computer'), findsOneWidget);
    expect(find.text('Compare security code'), findsOneWidget);
    expect(find.text('Workspace access'), findsOneWidget);
    expect(find.text('Join and share workspace'), findsOneWidget);
    await tap(tester, 'Cancel join');
    await tester.pumpWidget(const SizedBox.shrink());
    await sponsor.host.pauseGroupConnections();
    await joiner.host.pauseGroupConnections();
  }, variant: desktop);

  testWidgets('the environment switcher offers one first-run setup', (
    tester,
  ) async {
    final (a, _) = await machines();
    await pumpWorkbench(tester, a);
    await tap(tester, 'My computers');
    expect(find.text('Create group'), findsOneWidget);
    expect(find.text('Use invite'), findsOneWidget);
    expect(a.host.computerGroup, isNull);

    await tap(tester, 'Create group');
    expect(find.textContaining('answer approvals'), findsOneWidget);
    expect(a.host.computerGroup, isNull);
    await tap(tester, 'Create and trust group');
    expect(a.host.computerGroup?.active.keys, [a.host.id]);
    expect(find.text(a.name), findsOneWidget);
    expect(find.text('This computer'), findsOneWidget);
    expect(find.text('Invite computer'), findsOneWidget);
    expect(find.text('Use invite'), findsNothing);
    expect(find.text('Create group'), findsNothing);
    expect(find.text('Add computer'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await a.host.pauseGroupConnections();
  }, variant: desktop);

  testWidgets('existing members open a workspace directly from settings', (
    tester,
  ) async {
    final (a, b) = await machines();
    await a.host.createComputerGroup();
    await admit(a, b);
    await pumpWorkbench(tester, b);
    WindowControls.menuCommandsOf(0)!.call(openSettingsCommandId);
    await tester.pumpAndSettle();
    await tap(tester, 'Mobile');
    await tap(tester, 'My computers');
    final remote = find.byKey(ValueKey(('open-computer', a.host.id)));
    expect(remote.hitTestable(), findsOneWidget);
    expect(find.text('Recently reachable'), findsOneWidget);
    expect(find.text('Use invite'), findsNothing);
    await tester.tap(remote);
    await tester.pumpAndSettle();
    expect(find.byType(SettingsDialog), findsNothing);
    expect(find.byType(DesktopHostPage), findsOneWidget);
    expect(b.client.peer?.remote, a.host.id);
    expect(find.byTooltip('Computers'), findsNothing);

    await tap(tester, 'Switch to local');
    expect(find.byType(DesktopHostPage), findsNothing);
    await tap(tester, 'My computers');
    expect(find.text('Workspace connected'), findsOneWidget);
    await tap(tester, 'Close');
    await tester.pumpWidget(const SizedBox.shrink());
    await a.host.pauseGroupConnections();
    await b.host.pauseGroupConnections();
  }, variant: desktop);

  testWidgets(
    'legacy-only records are not offered or promoted into membership',
    (tester) async {
      final (a, b) = await machines();
      final saved = jsonEncode({
        'identity': LinkIdentity.generate().toJson(),
        'name': b.name,
        'address': LinkAddress(b.host.id).toJson(),
        'direct': true,
      });
      await a.store.write('desktop_host_connection.v1', saved);
      await pumpWorkbench(tester, a);
      expect(find.byType(DesktopHostPage), findsNothing);
      await tap(tester, 'My computers');
      expect(find.text(b.name), findsNothing);
      expect(find.text('Pair a Host'), findsNothing);
      expect(find.text('Create group'), findsOneWidget);
      expect(a.host.computerGroup, isNull);
      expect(a.client.peer, isNull);
      expect(await a.store.read('desktop_host_connection.v1'), saved);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: desktop,
  );

  testWidgets('nearby discovery opens only inside Find computer', (
    tester,
  ) async {
    final (sponsor, joiner) = await machines();
    await sponsor.host.createComputerGroup();
    await pumpWorkbench(tester, joiner);
    await tap(tester, 'My computers');
    expect(joiner.adverts.hasListener, isFalse);
    await tap(tester, 'Find computer');
    expect(joiner.adverts.hasListener, isTrue);
    sponsor.host.createGroupInvite(nearby: true);
    await sponsor.host.advertising;
    final advert = sponsor.platform.advertised.single;
    joiner.adverts.add([
      LinkAdvert.parse(
        name: 'Unverified nearby name',
        port: advert.port,
        attributes: advert.attributes,
        addresses: const ['192.168.1.2'],
      )!,
    ]);
    await tester.pumpAndSettle();
    await tap(tester, 'Unverified nearby name');
    expect(find.text('Join the group through ${sponsor.name}'), findsOneWidget);
    expect(sponsor.host.pendingGroupApproval, isNull);
    expect(joiner.host.computerGroup, isNull);
    await tap(tester, 'Cancel join');
    await tap(tester, 'Close');
    expect(joiner.adverts.hasListener, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await sponsor.host.pauseGroupConnections();
    await joiner.host.pauseGroupConnections();
  }, variant: desktop);
  testWidgets('an unreachable member remains selectable for a workspace', (
    tester,
  ) async {
    final (a, b) = await machines();
    await a.host.createComputerGroup();
    await admit(a, b);
    a.network.unreachable.add(a.host.id);
    await pumpWorkbench(tester, b);
    await tap(tester, 'My computers');
    expect(find.text('Currently unreachable'), findsOneWidget);
    await tap(tester, 'Open workspace');
    expect(b.client.peer, isNull);
    await tap(tester, 'Switch to local');
    await tap(tester, 'My computers');
    expect(find.text('Currently unreachable'), findsOneWidget);
    expect(find.text('Online status unknown'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await b.host.pauseGroupConnections();
    await a.host.pauseGroupConnections();
  }, variant: desktop);

  testWidgets('closing the sponsor dialog ends its nearby invite window', (
    tester,
  ) async {
    final (sponsor, _) = await machines();
    await sponsor.host.createComputerGroup();
    await pumpWorkbench(tester, sponsor);
    await tap(tester, 'My computers');
    await tap(tester, 'Invite computer');
    expect(sponsor.host.invitingNearbyGroupMembers, isFalse);
    await tap(tester, 'Invite nearby');
    expect(sponsor.host.invitingNearbyGroupMembers, isTrue);
    await tap(tester, 'Close');
    expect(sponsor.host.invitingNearbyGroupMembers, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await sponsor.host.pauseGroupConnections();
  }, variant: desktop);
}

Future<void> admit(Machine sponsor, Machine joiner) async {
  final preview = await joiner.host.prepareGroupJoin(
    sponsor.host.createGroupInvite(),
  );
  final joining = joiner.host.confirmGroupJoin(preview);
  for (var n = 0; sponsor.host.pendingGroupApproval == null && n < 20; n++) {
    await Future<void>.value();
  }
  await sponsor.host.approveGroupJoin(sponsor.host.pendingGroupApproval!);
  await joining;
}

Future<void> pumpWorkbench(
  WidgetTester tester,
  Machine machine, {
  SettingsFiles? files,
}) async {
  tester.view.physicalSize = const Size(1440, 960);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final locale = AppLocale();
  addTearDown(locale.dispose);
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Workbench(
        workspace: machine.workspace,
        settings: AppSettings(locale: locale, link: machine.host, files: files),
        createDesktopHostConnection: () {
          machine.workbenchOwnsClient = true;
          return machine.client;
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> tap(WidgetTester tester, String label) async {
  await tester.tap(find.text(label).hitTestable());
  await tester.pumpAndSettle();
}
