import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bao_link/bao_link.dart';
import 'package:baocode/icons/project_icon.dart';
import 'package:baocode/icons/project_icon_view.dart';
import 'package:baocode/l10n/l10n.dart';
import 'package:baocode/link/desktop_host_chats.dart';
import 'package:baocode/link/desktop_remote_project_tools.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _projectId = 'host-project';
const _host = 'Synthetic Host';
const _asset = {'type': 'image', 'id': 'host-asset'};
const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==';
const _gif = 'R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7';

Map<String, Object?> _svg(String source) => {
  'kind': 'svg',
  'data': base64Encode(utf8.encode(source)),
};

ProjectInfo _project({bool? pinned, Map<String, Object?>? icon}) => ProjectInfo(
  id: _projectId,
  name: 'Synthetic Project',
  path: '/synthetic/project',
  pinned: pinned,
  icon: icon,
);

typedef _Request = ({String method, Map<String, Object?> params});

class _Pair {
  _Pair(this.client, this.host, this.requests);

  final LinkPeer client;
  final LinkPeer host;
  final List<_Request> requests;

  static Future<_Pair> connect(
    LinkRequestHandler handle, {
    String hostId = 'synthetic-host',
  }) async {
    final requests = <_Request>[];
    final (a, b) = MemoryLinkConnection.pair(a: 'synthetic-client', b: hostId);
    final accept = LinkPeer.accept(
      b,
      onRequest: (method, params) {
        requests.add((method: method, params: params));
        return handle(method, params);
      },
    );
    return _Pair(await LinkPeer.connect(a), await accept, requests);
  }

  Future<void> close() async {
    await client.close();
    await host.close();
  }
}

Widget _app(Widget child) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  locale: const Locale('en'),
  home: Scaffold(
    body: Align(alignment: Alignment.topLeft, child: child),
  ),
);

void main() {
  testWidgets('pin and unpin use confirmed host catalog state', (tester) async {
    final ack = Completer<Object?>();
    Map<String, Object?> catalog(bool pinned) => LinkState(
      device: const DeviceInfo(name: _host, kind: 'windows', system: 'Windows'),
      projects: [_project(pinned: pinned)],
      sessions: const [],
    ).toJson();
    final pair = await _Pair.connect(
      (method, params) => switch (method) {
        LinkMethods.state => catalog(false),
        LinkMethods.pinProject when params['pinned'] == true => ack.future,
        _ => null,
      },
    );
    final chats = DesktopHostChats()..bind(pair.client);
    await tester.pumpWidget(
      _app(
        ListenableBuilder(
          listenable: chats,
          builder: (context, _) => chats.projects.isEmpty
              ? const SizedBox()
              : DesktopRemoteProjectActions(
                  peer: pair.client,
                  project: chats.projects.single,
                  hostName: _host,
                  isCurrent: (peer, id) =>
                      identical(peer, pair.client) &&
                      chats.projects.any((project) => project.id == id),
                ),
        ),
      ),
    );
    Future<void> menu() async {
      await tester.tap(find.byTooltip('Project actions'));
      await tester.pumpAndSettle();
    }

    await tester.pumpAndSettle();
    await menu();
    await tester.tap(find.text('Pin'));
    await tester.pumpAndSettle();
    expect(pair.requests.last.method, LinkMethods.pinProject);
    expect(pair.requests.last.params, {'project': _projectId, 'pinned': true});
    expect(
      tester
          .widget<PopupMenuButton>(
            find.byWidgetPredicate((widget) => widget is PopupMenuButton),
          )
          .enabled,
      isFalse,
    );

    ack.complete();
    await tester.pumpAndSettle();
    await menu();
    expect(find.text('Pin'), findsOneWidget);
    expect(find.text('Unpin'), findsNothing);
    await tester.tapAt(const Offset(400, 300));
    await tester.pumpAndSettle();

    pair.host.emit(LinkEvents.state, catalog(true));
    await tester.pumpAndSettle();
    await menu();
    await tester.tap(find.text('Unpin'));
    await tester.pumpAndSettle();
    expect(pair.requests.map((request) => request.method), [
      LinkMethods.state,
      LinkMethods.pinProject,
      LinkMethods.pinProject,
    ]);
    expect(pair.requests.last.method, LinkMethods.pinProject);
    expect(pair.requests.last.params, {'project': _projectId, 'pinned': false});
    await tester.pumpWidget(const SizedBox());
    chats.dispose();
    await pair.close();
  });

  testWidgets('remove requires confirmation for the named host and project', (
    tester,
  ) async {
    final pair = await _Pair.connect((_, _) => null);
    var current = true;
    Future<void> show() => tester.pumpWidget(
      _app(
        DesktopRemoteProjectActions(
          peer: pair.client,
          project: _project(),
          hostName: _host,
          isCurrent: (peer, id) =>
              current && identical(peer, pair.client) && id == _projectId,
        ),
      ),
    );
    await show();

    Future<void> openConfirmation() async {
      await tester.tap(find.byTooltip('Project actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove from List'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.textContaining('Synthetic Project'), findsOneWidget);
      expect(find.textContaining(_host), findsOneWidget);
      expect(find.text('/synthetic/project'), findsOneWidget);
      expect(pair.requests, isEmpty);
    }

    final confirm = find.widgetWithText(TextButton, 'Remove from List');
    await openConfirmation();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(pair.requests, isEmpty);

    await openConfirmation();
    current = false; // The parent switched before the row rebuilt.
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(pair.requests, isEmpty);

    current = true;
    await show();
    await openConfirmation();
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(pair.requests.single.method, LinkMethods.hideProject);
    expect(pair.requests.single.params, {'project': _projectId});

    await tester.pumpWidget(const SizedBox());
    await pair.close();
  });

  testWidgets('renders the advertised asset bytes from the host peer', (
    tester,
  ) async {
    const svg =
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 2 2">'
        '<rect width="2" height="2" fill="red"/></svg>';
    final pair = await _Pair.connect((_, _) => _svg(svg));
    await tester.pumpWidget(
      _app(
        DesktopRemoteProjectIcon(
          peer: pair.client,
          project: _project(icon: _asset),
          size: 22,
          isCurrent: (peer, id) =>
              identical(peer, pair.client) && id == _projectId,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(pair.requests.single.method, LinkMethods.icon);
    expect(pair.requests.single.params, {'id': 'host-asset'});
    final image = tester.widget<IconImageView>(find.byType(IconImageView));
    expect(image.size, 22 * ProjectIconView.imageScale);
    expect(utf8.decode(image.image.bytes), svg);

    await tester.pumpWidget(const SizedBox());
    await pair.close();
  });

  testWidgets('renders valid PNG and GIF bytes from the host peer', (
    tester,
  ) async {
    const payloads = {'png': _png, 'gif': _gif};
    final pair = await _Pair.connect((_, params) {
      final id = params['id'];
      return {'kind': id, 'data': payloads[id]};
    });
    for (final entry in payloads.entries) {
      await tester.pumpWidget(
        _app(
          DesktopRemoteProjectIcon(
            peer: pair.client,
            project: _project(icon: {'type': 'image', 'id': entry.key}),
            size: 22,
            isCurrent: (peer, id) =>
                identical(peer, pair.client) && id == _projectId,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final image = tester
          .widget<IconImageView>(find.byType(IconImageView))
          .image;
      expect(image.kind.name, entry.key);
      expect(image.bytes, base64Decode(entry.value));
    }
    await tester.pumpWidget(const SizedBox());
    await pair.close();
  });

  testWidgets('rejects unbounded or external image payloads before rendering', (
    tester,
  ) async {
    final png = Uint8List.fromList([
      137,
      80,
      78,
      71,
      13,
      10,
      26,
      10,
      0,
      0,
      0,
      13,
      73,
      72,
      68,
      82,
      0,
      0,
      255,
      255,
      0,
      0,
      255,
      255,
      8,
      6,
      0,
      0,
      0,
    ]);
    // A tiny logical screen with a frame claiming a much larger size.
    final oversizedFrame = base64Decode(_gif)..[33] = 16;
    final invalid = <Object?>[
      {'kind': 'jpg', 'data': 'AAAA'},
      {'kind': 'png', 'data': '%%%invalid'},
      {'kind': 'png', 'data': base64Encode(png)},
      {'kind': 'gif', 'data': base64Encode(oversizedFrame)},
      _svg(
        '<svg viewBox="0 0 1 1"><image href="https://example.invalid/no"/></svg>',
      ),
      _svg(
        '<svg viewBox="0 0 1 1"><use href="file:///synthetic/no.svg#x"/></svg>',
      ),
      _svg('<svg viewBox="0 0 1 1">${' ' * (300 * 1024)}</svg>'),
    ];
    final pair = await _Pair.connect(
      (_, params) => invalid[int.parse(params['id']! as String)],
    );
    for (var i = 0; i < invalid.length; i++) {
      await tester.pumpWidget(
        _app(
          DesktopRemoteProjectIcon(
            peer: pair.client,
            project: _project(icon: {'type': 'image', 'id': '$i'}),
            size: 22,
            isCurrent: (peer, id) =>
                identical(peer, pair.client) && id == _projectId,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byIcon(Icons.folder_outlined),
        findsOneWidget,
        reason: 'payload $i',
      );
      expect(find.byType(IconImageView), findsNothing);
    }
    expect(pair.requests, hasLength(invalid.length));
    await tester.pumpWidget(const SizedBox());
    await pair.close();
  });

  testWidgets(
    'locally bundled icon kinds use the native presenter without RPCs',
    (tester) async {
      final pair = await _Pair.connect((_, _) => null);
      final cases = <(Map<String, Object?>, ProjectIcon?)>[
        ({'type': 'emoji', 'emoji': '🚀'}, const EmojiIcon('🚀')),
        (
          {'type': 'codicon', 'name': 'folder', 'color': 'charts.red'},
          const CodiconIcon('folder', color: 'charts.red'),
        ),
        ({'type': 'brand', 'name': 'openai'}, const BrandIcon('openai')),
        ({'type': 'codicon', 'name': 'folder', 'color': 42}, null),
        ({'type': 'image', 'id': 'file:///synthetic/no.svg'}, null),
        ({'type': 'url', 'url': 'https://example.invalid/no'}, null),
      ];
      for (final (icon, expected) in cases) {
        await tester.pumpWidget(
          _app(
            DesktopRemoteProjectIcon(
              peer: pair.client,
              project: _project(icon: icon),
              size: 22,
              isCurrent: (peer, id) =>
                  identical(peer, pair.client) && id == _projectId,
            ),
          ),
        );
        expect(
          tester.widget<ProjectIconView>(find.byType(ProjectIconView)).icon,
          expected,
        );
      }
      expect(pair.requests, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await pair.close();
    },
  );

  testWidgets(
    'late asset cannot paint after replacing the peer for the same project and asset IDs',
    (tester) async {
      final late = Completer<Object?>();
      final previous = await _Pair.connect(
        (_, _) => late.future,
        hostId: 'old-host',
      );
      const newSvg =
          '<svg viewBox="0 0 1 1"><rect width="1" height="1"/></svg>';
      final next = await _Pair.connect(
        (_, _) => _svg(newSvg),
        hostId: 'new-host',
      );
      var selected = previous.client;
      Future<void> show() => tester.pumpWidget(
        _app(
          DesktopRemoteProjectIcon(
            peer: selected,
            project: _project(icon: _asset),
            size: 22,
            isCurrent: (peer, id) =>
                identical(peer, selected) && id == _projectId,
          ),
        ),
      );

      await show();
      await tester.pumpAndSettle();
      expect(previous.requests.single.params, {'id': 'host-asset'});
      expect(find.byIcon(Icons.folder_outlined), findsOneWidget);

      selected = next.client;
      await show();
      await tester.pumpAndSettle();
      expect(next.requests.single.params, {'id': 'host-asset'});
      late.complete(_svg('<svg viewBox="0 0 4 4"/>'));
      await tester.pumpAndSettle();
      final image = tester.widget<IconImageView>(find.byType(IconImageView));
      expect(utf8.decode(image.image.bytes), newSvg);

      await tester.pumpWidget(const SizedBox());
      await previous.close();
      await next.close();
    },
  );
}
