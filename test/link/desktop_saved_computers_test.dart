import 'package:bao_link/bao_link.dart';
import 'package:bao_markdown/bao_markdown.dart';
import 'package:baocode/link/desktop_host_page.dart';
import 'package:baocode/platform/data_dir.dart';
import 'package:baocode/settings/user_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'desktop_mutual_pairing_test.dart' show Machine;
import 'my_computers_test.dart'
    show admit, leaveComputers, memberRow, pumpWorkbench, tap, tapMember;

void main() {
  const desktop = TargetPlatformVariant({
    TargetPlatform.macOS,
    TargetPlatform.windows,
  });

  testWidgets('same-name computers keep drafts separate when switching', (
    tester,
  ) async {
    final (viewer, first, second) = await computers();
    final files = _SettingsFiles();
    addTearDown(files.dispose);
    await pumpWorkbench(tester, viewer, files: files);
    await tap(tester, 'My computers');
    await tapMember(tester, first);
    final previous = viewer.client.peer!;
    expect(previous.remote, first.host.id);

    // Both synthetic workspaces advertise the same chat title.
    const title = 'Optimize virtual list scrolling';
    await tap(tester, title);
    final editor = find.byType(MarkdownEditor);
    await tester.tap(editor.hitTestable());
    await tester.pump();
    const draft = 'Unsent on the first computer';
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: draft,
        selection: TextSelection.collapsed(offset: draft.length),
      ),
    );
    await tester.pump();
    String text() => tester.state<MarkdownEditorState>(editor).controller.text;

    final toggle = find.byKey(const ValueKey('computer-group-toggle'));
    expect(find.text('Shared computer'), findsNWidgets(2));
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(memberRow(second), findsNothing);
    expect(viewer.client.peer, same(previous));
    expect(text(), draft);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await tapMember(tester, second);
    expect(viewer.client.peer?.remote, second.host.id);
    expect(previous.isClosed, isTrue);
    await tap(tester, title);
    expect(text(), isEmpty);

    await leaveComputers(tester);
    expect(find.byType(DesktopHostPage), findsNothing);
    await tap(tester, 'My computers');
    expect(viewer.client.peer?.remote, second.host.id);
    await tapMember(tester, first);
    expect(viewer.client.peer?.remote, first.host.id);
    expect(editor.hitTestable(), findsOneWidget);
    expect(text(), draft);
    await stop(tester, [viewer, first, second]);
  }, variant: desktop);

  testWidgets('removal names the exact computer and can leave sync pending', (
    tester,
  ) async {
    final (viewer, first, second) = await computers();
    await pumpWorkbench(tester, viewer);
    await tap(tester, 'My computers');
    Future<void> removeFirst() async {
      await tester.tap(find.byKey(ValueKey(('computer-menu', first.host.id))));
      await tester.pumpAndSettle();
      await tap(tester, 'Remove Shared computer');
      expect(find.textContaining('from the whole group?'), findsOneWidget);
      expect(find.text(first.host.fingerprint), findsOneWidget);
    }

    await removeFirst();
    await tap(tester, 'Cancel');
    expect(
      viewer.host.computerGroup!.active.keys,
      containsAll([first.host.id, second.host.id]),
    );
    viewer.network.unreachable.add(second.host.id);
    await removeFirst();
    await tap(tester, 'Remove from group');
    expect(viewer.host.computerGroup!.removed, contains(first.host.id));
    expect(viewer.host.computerGroup!.active.keys, contains(second.host.id));
    await tap(tester, 'Removed Shared computer');
    expect(find.textContaining('Awaiting acknowledgment'), findsOneWidget);
    viewer.network.unreachable.remove(second.host.id);
    await tapMember(tester, second);
    expect(find.byType(DesktopHostPage), findsOneWidget);
    expect(viewer.client.peer?.remote, second.host.id);
    await stop(tester, [viewer, first, second]);
  }, variant: desktop);
}

Future<(Machine, Machine, Machine)> computers() async {
  final network = MemoryLinkNetwork();
  final viewer = Machine(network, 'Viewer');
  final first = Machine(network, 'Shared computer');
  final second = Machine(network, 'Shared computer');
  for (final machine in [viewer, first, second]) {
    addTearDown(machine.close);
    await machine.host.load();
  }
  await viewer.host.createComputerGroup();
  await admit(viewer, first);
  await admit(viewer, second);
  return (viewer, first, second);
}

Future<void> stop(WidgetTester tester, List<Machine> machines) async {
  await tester.pumpWidget(const SizedBox.shrink());
  for (final machine in machines) {
    await machine.host.pauseGroupConnections();
  }
}

class _SettingsFiles extends SettingsFiles {
  _SettingsFiles() : super(const DataDirectory('/unused'));

  final _storage = _MemoryStorage();

  @override
  GlobalStorage get storage => _storage;
}

class _MemoryStorage extends GlobalStorage {
  _MemoryStorage() : super('/unused/storage.json');

  final _values = <String, Object?>{};

  @override
  bool get loaded => true;

  @override
  Object get value => _values;

  @override
  Future<void> set(String key, Object? value) async => _values[key] = value;
}
