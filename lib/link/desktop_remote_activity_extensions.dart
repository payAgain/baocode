part of 'desktop_remote_activity.dart';

typedef _ExtensionInventory = ({List<LinkExtension> items, String? error});

Future<_ExtensionInventory> _loadExtensions(
  DesktopRemoteActivitySession session,
) async {
  try {
    // This host feature advertises one inventory, not a project RPC. Filter
    // before storing/rendering any rows in the active project's panel.
    final response = await session.peer.call(LinkMethods.extensions, {});
    if (response case {'items': final List<Object?> list}) {
      final items = <LinkExtension>[];
      for (final raw in list) {
        if (raw is! Map<String, Object?>) continue;
        try {
          final item = LinkExtension.fromJson(raw);
          final belongs =
              item.project == session.projectId ||
              item.project == null &&
                  (item.scope == 'user' || item.scope == 'plugin');
          if (belongs && item.name.isNotEmpty && item.kind.isNotEmpty) {
            items.add(item);
          }
        } on TypeError {
          // Skip records that cannot be rendered.
        }
      }
      return (items: items, error: null);
    }
    return (items: const <LinkExtension>[], error: 'failed');
  } on Object catch (error) {
    // Resolve with a value even if the tab closed before the reply.
    return (
      items: const <LinkExtension>[],
      error: error is LinkRemoteException ? error.code : 'failed',
    );
  }
}

extension _ExtensionsPane on _DesktopRemoteActivityState {
  Widget _extensionsPane(
    _ActivityText text,
  ) => FutureBuilder<_ExtensionInventory>(
    future: _extensions,
    builder: (context, snapshot) {
      final inventory = snapshot.connectionState == ConnectionState.done
          ? snapshot.data
          : null;
      final items = inventory?.items ?? const <LinkExtension>[];
      return ListView.separated(
        key: const ValueKey(_Section.extensions),
        primary: false,
        padding: const EdgeInsets.all(12),
        itemCount: items.length + 1,
        separatorBuilder: (_, _) => const Divider(),
        itemBuilder: (context, index) {
          if (index > 0) {
            final item = items[index - 1];
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.name, style: Theme.of(context).textTheme.titleSmall),
                Text(
                  [
                    text.extensionKind(item.kind),
                    text.extensionScope(item.scope),
                    if (item.enabled case final enabled?)
                      text.extensionEnabled(enabled),
                  ].join(' · '),
                ),
                if (item.description.isNotEmpty)
                  SelectableText(item.description),
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (inventory == null)
                Text(text.loading)
              else if (inventory.error case final error?)
                Text(
                  error == LinkErrors.unknown || error == LinkErrors.unsupported
                      ? text.extensionsUnsupported
                      : text.extensionsFailed,
                )
              else
                Text(items.isEmpty ? text.noExtensions : text.extensionDetails),
              if (inventory != null)
                TextButton.icon(
                  onPressed: () {
                    if (widget.session case final session?
                        when _active(session) &&
                            _section == _Section.extensions) {
                      _changeState(
                        () => _extensions = _loadExtensions(session),
                      );
                    }
                  },
                  icon: const Icon(Icons.refresh),
                  label: Text(text.refresh),
                ),
            ],
          );
        },
      );
    },
  );
}

extension _ExtensionText on _ActivityText {
  String get extensions => _zh ? '扩展' : 'Extensions';
  String get refresh => _zh ? '刷新' : 'Refresh';
  String get extensionDetails => _zh
      ? '主机上的 Claude Code 扩展（只读）'
      : 'Host Claude Code extensions (read-only)';
  String get noExtensions =>
      _zh ? '主机未报告所选项目的扩展。' : 'No host extensions reported for this project.';
  String get extensionsUnsupported => _zh
      ? '此主机不提供扩展列表。'
      : 'This host does not provide its extension inventory.';
  String get extensionsFailed =>
      _zh ? '无法加载主机扩展。' : 'Could not load host extensions.';

  String extensionKind(String kind) => switch (kind) {
    'skill' => _zh ? '技能' : 'Skill',
    'mcp' => _zh ? 'MCP 服务器' : 'MCP server',
    'plugin' => _zh ? '插件' : 'Plugin',
    'agent' => _zh ? '子智能体' : 'Subagent',
    _ => kind,
  };

  String extensionScope(String scope) => switch (scope) {
    'user' => _zh ? '用户' : 'User',
    'project' => _zh ? '项目' : 'Project',
    'local' => _zh ? '本地配置' : 'Local',
    'plugin' => _zh ? '插件' : 'Plugin',
    _ => scope,
  };

  String extensionEnabled(bool enabled) =>
      _zh ? (enabled ? '已启用' : '已禁用') : (enabled ? 'Enabled' : 'Disabled');
}
