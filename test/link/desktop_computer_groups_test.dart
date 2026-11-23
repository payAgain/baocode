import 'dart:async';

import 'package:bao_link/bao_link.dart';
import 'package:baocode/link/computer_group.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/settings/app_locale.dart';
import 'package:baocode/settings/app_settings.dart';
import 'package:baocode/settings/pages/mobile_page.dart';
import 'package:baocode/workbench.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'desktop_mutual_pairing_test.dart' show Machine, machines;

void main() {
  test(
    'computer group sharing works with legacy Mobile connections off',
    () async {
      final (a, b) = await machines();
      final phone = LinkIdentity.generate();
      final mobile = await pairPhone(a, phone);
      expect(await mobile.call(LinkMethods.state), isA<Map>());
      await Future.wait([a.host.setEnabled(false), b.host.setEnabled(false)]);
      await Future.wait([
        a.host.enableGroupConnections(),
        b.host.enableGroupConnections(),
      ]);
      await a.host.createComputerGroup();
      await join(a, b);
      await a.restart();
      await b.restart();
      expect(a.host.enabled, isFalse);
      expect(b.host.enabled, isFalse);
      expect(a.host.phones, hasLength(1));
      expect(b.client.peer, isNull);
      await b.client.selectGroupMember(a.host.id);
      final peer = b.client.peer!;
      expect(await peer.call(LinkMethods.state), isA<Map>());
      expect(a.host.offer, isNull);
      await a.host.pauseGroupConnections();
      expect(peer.isClosed, isTrue);
      await a.restart();
      expect(a.host.groupConnectionsAvailable, isFalse);
      expect(a.host.computerGroup?.active, contains(b.host.id));
      await a.host.enableGroupConnections();
      await b.client.selectGroupMember(a.host.id);
      expect(await b.client.peer!.call(LinkMethods.state), isA<Map>());
    },
  );

  test('retired desktop selection cannot disrupt a group workspace', () async {
    final (a, b) = await machines();
    await a.host.createComputerGroup();
    await join(a, b);
    await b.client.selectGroupMember(a.host.id);
    final group = b.client.peer!;
    await b.client.selectHost(a.host.id);
    expect(b.client.peer, same(group));
    expect(await group.call(LinkMethods.state), isA<Map>());
  });

  test(
    'corrupt saved membership disables the group without changing Mobile Link',
    () async {
      final (a, b) = await machines();
      final phone = LinkIdentity.generate();
      await pairPhone(a, phone);
      await a.host.createComputerGroup();
      await join(a, b);
      final record = Map<String, Object?>.of(
        a.platform.keptComputerGroup! as Map<String, Object?>,
      );
      final saved = (record['history']! as List<Object?>).toList();
      final event = (saved.last! as List<Object?>).toList();
      event[5] = 'X' * 86;
      saved[saved.length - 1] = event;
      a.platform.keptComputerGroup = {...record, 'history': saved};
      await a.restart();
      expect(a.host.computerGroupStorageError, isTrue);
      expect(a.host.computerGroup, isNull);
      expect(a.host.phones.single.id, phone.id);
      await b.client.selectGroupMember(a.host.id);
      expect(b.client.peer, isNull);
      final mobile = await connectPhone(a, phone);
      await mobile.call(LinkMethods.hello);
      expect(await mobile.call(LinkMethods.state), isA<Map>());
    },
  );

  test(
    'a stale sponsor cannot introduce a member after known removal',
    () async {
      final (a, b) = await machines();
      await a.host.createComputerGroup();
      await join(a, b);
      final bSeed = b.platform.kept['identity']! as Map<String, Object?>;
      final bIdentity = LinkIdentity.fromJson(bSeed)!;
      final cIdentity = LinkIdentity.generate();
      final stale = b.host.computerGroup!;
      final consent = ComputerGroupConsent.sign(
        stale.id,
        b.host.id,
        encodeKey(randomBytes(16)),
        ComputerGroupMember(
          id: cIdentity.id,
          name: 'Stale addition',
          addrs: [],
          relays: [],
          direct: true,
        ),
        cIdentity,
      );
      final staleGrant = stale.admit(consent, bIdentity);
      await a.host.removeGroupMember(b.host.id);
      final merged = a.host.computerGroup!.merge(staleGrant.toJson());
      expect(merged.active, isNot(contains(cIdentity.id)));
      expect(merged.active, isNot(contains(bIdentity.id)));
      expect(merged.removed, contains(bIdentity.id));
      final transport = a.network.node(cIdentity.id);
      addTearDown(transport.close);
      final peer = await LinkPeer.connect(
        await transport.connect(LinkAddress(a.host.id)),
      );
      try {
        await expectLater(
          peer.call(ComputerGroupWire.sync, {'history': staleGrant.toJson()}),
          throwsA(isA<LinkRemoteException>()),
        );
        await expectLater(
          peer.call(ComputerGroupWire.open, {'group': stale.id}),
          throwsA(isA<LinkRemoteException>()),
        );
      } finally {
        await peer.close();
      }
    },
  );

  testWidgets('workspace and settings disclose and confirm a group join', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1550, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final (a, b) = await machines();
    final locale = AppLocale();
    String? clipboard;
    final channel = tester.binding.defaultBinaryMessenger;
    channel.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(
      () => channel.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    addTearDown(locale.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Row(
            children: [
              Expanded(
                child: Workbench(
                  workspace: a.workspace,
                  settings: AppSettings(locale: locale, link: a.host),
                  createDesktopHostConnection: () {
                    a.workbenchOwnsClient = true;
                    return a.client;
                  },
                ),
              ),
              Expanded(child: MobileSettingsPage(host: b.host)),
            ],
          ),
        ),
      ),
    );
    Future<void> tap(String text) async {
      await tester.tap(find.text(text).hitTestable());
      await tester.pumpAndSettle();
    }

    Future<void> entry(Type pane) async {
      await tester.tap(
        find
            .descendant(
              of: find.byType(pane),
              matching: find.text('My computers'),
            )
            .hitTestable(),
      );
      await tester.pumpAndSettle();
    }

    Future<void> settings() => entry(MobileSettingsPage);
    Future<void> workbench() => entry(Workbench);

    await settings();
    await tap('Create group');
    expect(find.textContaining('answer approvals'), findsWidgets);
    expect(b.host.computerGroup, isNull);
    await tap('Create and trust group');
    await tap('Invite computer');
    await tap('Copy invite');
    expect(clipboard, startsWith('baocode-group://join/'));
    final invite = clipboard!;
    await tap('Close');
    await workbench();
    await tap('Use invite');
    await tester.enterText(
      find.byKey(const ValueKey('computer-group-invite')),
      invite,
    );
    await tester.pump();
    await tap('Review invite');
    expect(find.textContaining('answer approvals'), findsWidgets);
    expect(a.host.computerGroup, isNull);
    expect(b.host.pendingGroupApproval, isNull);
    await tap('Join and share workspace');
    expect(b.host.pendingGroupApproval, isNotNull);
    await tap('Close and keep waiting');
    await settings();
    expect(find.textContaining('answer approvals'), findsWidgets);
    await tap('Approve group member');
    expect(
      a.host.computerGroup?.active.keys,
      unorderedEquals([a.host.id, b.host.id]),
    );
    await tap('Close');
    await workbench();
    await tap('Open workspace');
    final peer = a.client.peer!;
    expect(peer.remote, b.host.id);
    expect(await peer.call(LinkMethods.state), isA<Map>());
    await settings();
    await tester.tap(find.byKey(ValueKey(('computer-menu', a.host.id))));
    await tester.pumpAndSettle();
    await tap('Remove ${a.name}');
    expect(peer.isClosed, isFalse);
    await tap('Remove from group');
    expect(peer.isClosed, isTrue);
    expect(a.host.computerGroup?.removed, contains(a.host.id));
    await tester.pumpWidget(const SizedBox.shrink());
    unawaited(a.host.setEnabled(false));
    unawaited(b.host.setEnabled(false));
    await tester.pump();
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  test(
    'removal disconnects immediately and stays pending for an offline member',
    () async {
      final (a, b) = await machines();
      final c = Machine(a.network, 'Third Mac');
      addTearDown(c.close);
      await c.host.load();
      final unrelated = await pairPhone(a, LinkIdentity.generate());

      await a.host.createComputerGroup();
      await join(a, b);
      final old = b.host.createGroupInvite();
      await join(a, c);
      final staleHistory = b.host.computerGroup!.toJson();
      await b.client.selectGroupMember(a.host.id);
      final inbound = b.client.peer!;
      await a.client.selectGroupMember(b.host.id);
      final outbound = a.client.peer!;
      await c.host.setEnabled(false);

      // A non-founder (B) is removed. C is offline and still has its old log.
      await a.host.removeGroupMember(b.host.id);
      expect(a.client.peer, isNull);
      expect(inbound.isClosed, isTrue);
      expect(outbound.isClosed, isTrue);
      expect(unrelated.isClosed, isFalse);
      expect(await unrelated.call(LinkMethods.state), isA<Map>());
      expect(a.host.pendingGroupRemoval(b.host.id), {c.host.id});
      expect(b.host.computerGroup!.removed, contains(b.host.id));
      expect(c.host.computerGroup!.active, contains(b.host.id));
      expect(
        () => b.host.createGroupInvite(),
        throwsA(isA<LinkRemoteException>()),
      );
      expect(
        a.host.computerGroup!.merge(staleHistory).active.containsKey(b.host.id),
        isFalse,
      );

      await a.restart();
      expect(a.host.computerGroup!.removed, contains(b.host.id));
      await c.host.setEnabled(true);
      await a.host.syncComputerGroup();
      expect(a.host.pendingGroupRemoval(b.host.id), isEmpty);
      expect(c.host.computerGroup!.removed, contains(b.host.id));
      await b.client.selectGroupMember(c.host.id);
      expect(b.client.peer, isNull);
      // The old invite is still intrinsically well formed, but its issuer is
      // locally removed and cannot use the old log to regain workspace access.
      final e = Machine(a.network, 'New computer');
      addTearDown(e.close);
      await e.host.load();
      await expectLater(
        e.host.prepareGroupJoin(old),
        throwsA(isA<LinkRemoteException>()),
      );
      final outsider = e.platform.node!;
      final wire = await outsider.connect(LinkAddress(a.host.id));
      final peer = await LinkPeer.connect(wire);
      try {
        await expectLater(
          peer.call(ComputerGroupWire.sync, {'history': staleHistory}),
          throwsA(isA<LinkRemoteException>()),
        );
        await expectLater(
          peer.call(LinkMethods.state),
          throwsA(isA<LinkRemoteException>()),
        );
      } finally {
        await peer.close();
      }
    },
  );

  test(
    'a delegated member can remove the founder from the whole group',
    () async {
      final (founder, delegate) = await machines();
      await founder.host.createComputerGroup();
      await join(founder, delegate);
      await delegate.host.removeGroupMember(founder.host.id);
      expect(founder.host.computerGroup!.removed, contains(founder.host.id));
      expect(delegate.host.computerGroup!.active.keys, [delegate.host.id]);
    },
  );

  test(
    'a delegated join opens both direct workspaces with the sponsor offline',
    () async {
      final (a, b) = await machines();
      final c = Machine(a.network, 'Third Mac');
      addTearDown(c.close);
      await c.host.load();

      await a.host.createComputerGroup();
      await join(a, b);
      await join(b, c);
      await b.host.setEnabled(false);
      await a.restart();
      await c.restart();

      for (final (viewer, owner) in [(a, c), (c, a)]) {
        expect(viewer.host.computerGroup!.active.keys, contains(owner.host.id));
        expect(viewer.client.savedHosts, isEmpty);
        expect(owner.platform.kept['desktopGrants'], isEmpty);
        expect(owner.host.phones, isEmpty);
        await viewer.client.selectGroupMember(owner.host.id);
        final peer = viewer.client.peer;
        expect(peer?.remote, owner.host.id, reason: viewer.client.error);
        final state = LinkState.fromJson(
          (await peer!.call(LinkMethods.state))! as Map<String, Object?>,
        );
        final title = 'From ${viewer.name}';
        await peer.call(LinkMethods.rename, {
          'session': state.sessions.first.id,
          'title': title,
        });
        expect(owner.workspace.threads.any((t) => t.title == title), isTrue);
        expect(viewer.workspace.threads.any((t) => t.title == title), isFalse);
      }
    },
  );
}

Future<void> join(Machine sponsor, Machine joiner) async {
  final invite = sponsor.host.createGroupInvite();
  final preview = await joiner.host.prepareGroupJoin(invite);
  expect(preview.sponsor.name, sponsor.name);
  expect(joiner.host.computerGroup, isNull);
  expect(sponsor.host.computerGroup!.active, isNot(contains(joiner.host.id)));
  final requested = Completer<void>();
  void onChange() {
    if (!requested.isCompleted && sponsor.host.pendingGroupApproval != null) {
      requested.complete();
    }
  }

  sponsor.host.addListener(onChange);
  final joining = joiner.host.confirmGroupJoin(preview);
  try {
    await requested.future.timeout(const Duration(seconds: 5));
  } finally {
    sponsor.host.removeListener(onChange);
  }
  final pending = sponsor.host.pendingGroupApproval!;
  expect(pending.member.id, joiner.host.id);
  expect(pending.code, preview.code);
  expect(sponsor.host.computerGroup!.active, isNot(contains(joiner.host.id)));
  await sponsor.host.approveGroupJoin(pending);
  await joining;
}

Future<LinkPeer> connectPhone(Machine owner, LinkIdentity identity) async {
  final node = owner.network.node(identity.id);
  addTearDown(node.close);
  final peer = await LinkPeer.connect(
    await node.connect(LinkAddress(owner.host.id)),
  );
  addTearDown(peer.close);
  return peer;
}

Future<LinkPeer> pairPhone(Machine owner, LinkIdentity identity) async {
  final offer = (await owner.host.beginPairing())!;
  final phone = await connectPhone(owner, identity);
  await phone.call(LinkMethods.hello, {
    'token': encodeKey(offer.token),
    'system': 'iOS 26.1',
    'name': 'iPhone',
  });
  await phone.call(LinkMethods.confirm);
  return phone;
}
