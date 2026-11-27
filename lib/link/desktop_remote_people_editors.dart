part of 'desktop_remote_people.dart';

class _PeopleEditors {
  _PeopleEditors(this.state);

  final _DesktopRemotePeopleManagerState state;
  bool get _busy => state._busy;
  String _tr(String en, String zh) => state._tr(en, zh);
  bool _can(String method) => !_busy && !state._unsupported.contains(method);
  void _run(Future<void> Function(LinkPeer) action) =>
      unawaited(state._run(action));
  void _edit(VoidCallback change) => state._edit(change);

  Widget list(_PeopleCatalog catalog) {
    final context = state.context;
    Widget divider() => Container(
      height: 1,
      margin: const EdgeInsets.symmetric(horizontal: 6),
      color: SettingsColors.divider,
    );
    return _section([
      if (!catalog.hasBots)
        BotEditorNotice(
          message: _tr('This host does not advertise Bots.', '此主机未提供机器人目录。'),
          tone: BotEditorTone.warning,
        ),
      BotEditorSection(
        title: _tr('Bots', '机器人'),
        children: [
          if (catalog.bots.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Text(
                _tr('No Bots configured on this host.', '此主机上还没有机器人。'),
                style: TextStyle(
                  fontSize: 12.5,
                  color: SettingsColors.textSecondary,
                ),
              ),
            )
          else
            Column(
              children: [
                for (final (i, bot) in catalog.bots.indexed) ...[
                  if (i > 0) divider(),
                  Builder(
                    builder: (context) {
                      final name = bot['name'] as String;
                      final signature = bot['signature'] as String?;
                      final assistant = bot['assistant'] == true;
                      final avatar = bot['avatar'] as String?;
                      final emoji =
                          avatar != null &&
                              avatar.isNotEmpty &&
                              !isAvatarImage(avatar)
                          ? avatar
                          : null;
                      return BotEditorNavTile(
                        icon: assistant
                            ? Icons.assistant
                            : Icons.smart_toy_outlined,
                        leading: BotAvatarBadge(
                          label: name,
                          emoji: emoji,
                          icon: assistant ? Icons.smart_toy_outlined : null,
                          accent: assistant,
                          size: 34,
                        ),
                        title: name,
                        subtitle: signature != null && signature.isNotEmpty
                            ? signature
                            : null,
                        onTap: _busy
                            ? null
                            : () => _run(
                                (peer) => state._openBot(
                                  peer,
                                  _PeopleDraft.bot(catalog, bot['id'] as String),
                                ),
                              ),
                      );
                    },
                  ),
                ],
              ],
            ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton.icon(
              style: botEditorOutlinedButtonStyle(context),
              onPressed: !catalog.hasBots || !_can(LinkMethods.saveBot)
                  ? null
                  : () => state._changeView(
                      () => state._draft = _PeopleDraft.bot(catalog),
                    ),
              icon: const Icon(Icons.add, size: 16),
              label: Text(_tr('New Bot', '新建机器人')),
            ),
          ),
        ],
      ),
      BotEditorSection(
        title: _tr('Groups', '群聊'),
        children: [
          if (catalog.groups.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Text(
                _tr('No groups configured on this host.', '此主机上还没有群聊。'),
                style: TextStyle(
                  fontSize: 12.5,
                  color: SettingsColors.textSecondary,
                ),
              ),
            )
          else
            Column(
              children: [
                for (final (i, group) in catalog.groups.indexed) ...[
                  if (i > 0) divider(),
                  Builder(
                    builder: (context) {
                      final name = group['name'] as String;
                      return BotEditorNavTile(
                        icon: Icons.groups_outlined,
                        leading: BotAvatarBadge(
                          label: name,
                          icon: Icons.groups_outlined,
                          size: 34,
                        ),
                        title: name,
                        onTap: _busy
                            ? null
                            : () => state._changeView(
                                () => state._draft = _PeopleDraft.group(
                                  catalog,
                                  group['id'] as String,
                                ),
                              ),
                      );
                    },
                  ),
                ],
              ],
            ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton.icon(
              style: botEditorOutlinedButtonStyle(context),
              onPressed: !catalog.hasBots || !_can(LinkMethods.saveGroup)
                  ? null
                  : () => state._changeView(
                      () => state._draft = _PeopleDraft.group(catalog),
                    ),
              icon: const Icon(Icons.add, size: 16),
              label: Text(_tr('New group', '新建群聊')),
            ),
          ),
        ],
      ),
      BotEditorSection(
        title: _tr('Host account', '主机账号'),
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                style: botEditorOutlinedButtonStyle(context),
                onPressed: !catalog.hasBots || !_can(LinkMethods.setMe)
                    ? null
                    : () => state._changeView(
                        () => state._draft = _PeopleDraft(_PeopleKind.profile),
                      ),
                icon: const Icon(Icons.person_outline, size: 16),
                label: Text(_tr('My host profile', '我的主机资料')),
              ),
              TextButton.icon(
                style: botEditorGhostButtonStyle(context),
                onPressed: _busy
                    ? null
                    : () => _run((peer) async {
                        await state._readCatalog(peer);
                      }),
                icon: const Icon(Icons.refresh, size: 16),
                label: Text(_tr('Refresh', '刷新')),
              ),
            ],
          ),
        ],
      ),
    ]);
  }

  Widget buildDraft(_PeopleDraft draft, _PeopleCatalog catalog) =>
      switch (draft.kind) {
        _PeopleKind.bot => _bot(draft),
        _PeopleKind.group => _group(draft, catalog),
        _PeopleKind.profile => _profile(draft),
        _PeopleKind.memory => _memory(draft),
      };

  Widget _actions({String? label, VoidCallback? onSave}) => BotEditorActions(
    children: [
      OutlinedButton(
        style: botEditorOutlinedButtonStyle(state.context),
        onPressed: _busy ? null : state._back,
        child: Text(_tr('Back', '返回')),
      ),
      if (label != null)
        FilledButton(
          style: botEditorButtonStyle(state.context),
          onPressed: onSave,
          child: Text(label),
        ),
    ],
  );

  Widget _field(
    _PeopleDraft draft,
    String key,
    String label, {
    int lines = 1,
    bool numeric = false,
    bool editable = true,
    String? hint,
    Object? version,
    void Function(String)? onChanged,
  }) => BotEditorInsetField(
    key: ValueKey((key, version)),
    initialValue: draft.text[key] ?? '',
    label: label,
    hint: hint,
    multiline: lines > 1,
    minLines: lines,
    maxLines: lines == 1 ? 1 : lines + 2,
    keyboardType: numeric ? TextInputType.number : null,
    textInputAction: lines == 1
        ? TextInputAction.next
        : TextInputAction.newline,
    enabled: editable && !_busy,
    onChanged: (value) => _edit(() {
      draft.text[key] = value;
      onChanged?.call(value);
    }),
  );

  Widget _name(_PeopleDraft draft, {bool editable = true}) =>
      _field(draft, 'name', _tr('Name', '名称'), editable: editable);

  Widget _gender(_PeopleDraft draft, {bool editable = true}) =>
      _field(draft, 'gender', _tr('Gender', '性别'), editable: editable);

  Widget _signature(_PeopleDraft draft, {bool editable = true}) =>
      _field(draft, 'signature', _tr('Signature', '签名'), editable: editable);

  Widget _toolAccess() => BotEditorSection(
    title: _tr('Tool access', '工具权限'),
    children: [
      Text(
        _tr(
          'On up-to-date hosts, private chats and Bot groups have full access '
              'to the host’s files, shell, browser, agent sessions, and other BaoCode tools, '
              'including configured MCP tools, within the host’s OS permissions. '
              'Older hosts may still enforce their existing tool restrictions.',
          '在使用新版 BaoCode 的主机上，私聊和 Bot 群聊都可以完整使用主机文件、终端、浏览器、'
              '智能体会话及其他 BaoCode 工具，包括已配置的 MCP 工具，访问范围受主机的操作系统权限约束。'
              '旧版主机可能仍会执行原有的工具限制。',
        ),
        style: TextStyle(
          fontSize: 12.5,
          height: 1.5,
          color: SettingsColors.textSecondary,
        ),
      ),
    ],
  );

  Widget _bot(_PeopleDraft draft) {
    final editable = draft.canEditBot && _can(LinkMethods.saveBot);
    final hasSettings = draft.canEditBot;
    final id = draft.id;
    final picture =
        draft.pickedPicture ?? (draft.replaceAvatar ? null : draft.hostPicture);
    final emoji = draft.text['avatar'] ?? '';
    return state._editor(
      title: id == null
          ? _tr('New Bot', '新建机器人')
          : _tr('Bot settings', '机器人设置'),
      name: id == null ? null : draft.name,
      icon: Icons.smart_toy_outlined,
      avatar: picture != null
          ? _picturePreview(picture)
          : emoji.isNotEmpty
          ? Text(emoji, maxLines: 1, style: const TextStyle(fontSize: 22))
          : null,
      actions: _actions(
        label: hasSettings ? _tr('Save', '保存') : null,
        onSave: !editable || !draft.changedBot ? null : () => _saveBot(draft),
      ),
      body: _section([
        if (!hasSettings)
          BotEditorNotice(
            message: _tr(
              'This host did not provide the full Bot settings.',
              '此主机未提供完整的机器人设置。',
            ),
            tone: BotEditorTone.neutral,
          ),
        BotEditorSection(
          title: _tr('Profile', '基本资料'),
          children: [
            _name(draft, editable: editable),
            _gender(draft, editable: editable),
            _signature(draft, editable: editable),
            if (hasSettings) ...[
              _field(
                draft,
                'avatar',
                _tr('Avatar emoji', '头像表情'),
                editable: editable,
                version: draft.avatarFieldVersion,
                onChanged: (_) {
                  draft.replaceAvatar = true;
                  draft.pickedPicture = null;
                },
              ),
              _picture(draft, editable: editable, preview: false),
            ],
          ],
        ),
        if (hasSettings) ...[
          BotEditorSection(
            title: _tr('Persona', '角色设定'),
            children: [
              _field(
                draft,
                'identity',
                _tr('Identity', '身份设定'),
                lines: 2,
                editable: editable,
              ),
              _field(
                draft,
                'style',
                _tr('Speaking style', '说话风格'),
                lines: 2,
                editable: editable,
              ),
            ],
          ),
          _toolAccess(),
          BotEditorSection(
            title: _tr('Messaging', '消息设置'),
            children: [
              BotEditorSwitchTile(
                title: _tr('React to agent activity', '响应智能体活动'),
                subtitle: _tr(
                  'Can receive agent updates and notify your linked phone.',
                  '可以接收智能体动态并通知已连接的手机。',
                ),
                value: draft.abilities.contains(BotAbility.proactive.name),
                onChanged: !editable
                    ? null
                    : (on) => _edit(() {
                        if (on) {
                          draft.abilities.add(BotAbility.proactive.name);
                        } else {
                          draft.abilities.remove(BotAbility.proactive.name);
                        }
                      }),
              ),
              if (draft.flags['writesFirst'] case final writesFirst?)
                BotEditorSwitchTile(
                  title: _tr('May write first', '可以主动发消息'),
                  subtitle: _tr(
                    'Allows private messages from a group without a recent message from you.',
                    '即使你最近没有发消息，也可以从群聊主动私信你。',
                  ),
                  value: writesFirst,
                  onChanged: !editable
                      ? null
                      : (value) =>
                            _edit(() => draft.flags['writesFirst'] = value),
                ),
            ],
          ),
          if (draft.abilities.contains(BotAbility.proactive.name))
            BotEditorSection(
              title: _tr('Proactive messages', '主动消息'),
              children: [
                _field(
                  draft,
                  'perDay',
                  _tr('Proactive messages per day', '每日主动消息上限'),
                  numeric: true,
                  editable: editable,
                ),
                _field(
                  draft,
                  'quietFrom',
                  _tr('Quiet hours start', '免打扰开始'),
                  numeric: true,
                  editable: editable,
                  hint: _tr(
                    'Minutes since midnight on the host (0–1439)',
                    '主机当地时间从午夜起的分钟数（0–1439）',
                  ),
                ),
                _field(
                  draft,
                  'quietTo',
                  _tr('Quiet hours end', '免打扰结束'),
                  numeric: true,
                  editable: editable,
                  hint: _tr(
                    'Same as start disables quiet hours',
                    '与开始时间相同即关闭免打扰',
                  ),
                ),
              ],
            ),
        ],
        if (id != null) ...[
          BotEditorSection(
            title: _tr('Memory', '记忆'),
            children: [
              Column(
                children: [
                  if (state._catalog?.botMemoryOptions.contains(
                        LinkMethods.botMemoryEntries,
                      ) ==
                      true) ...[
                    BotEditorNavTile(
                      icon: Icons.auto_stories_outlined,
                      tint: AppColors.accent,
                      title: _tr('Memory and review', '记忆与审核'),
                      subtitle: _tr(
                        'View preferences, facts, skills, and review proposals',
                        '查看偏好、事实、技能与复盘提案',
                      ),
                      onTap: _busy
                          ? null
                          : () => state._openStructuredMemory(draft),
                    ),
                    Container(
                      height: 1,
                      margin: const EdgeInsets.symmetric(horizontal: 6),
                      color: SettingsColors.divider,
                    ),
                  ],
                  BotEditorNavTile(
                    icon: Icons.notes_outlined,
                    tint: const Color(0xFF56B6C2),
                    title: _tr('Memory & self notes', '记忆和自我笔记'),
                    subtitle: _tr(
                      'Edit raw Markdown memory and self notes',
                      '直接编辑原始 Markdown 记忆与自我笔记',
                    ),
                    onTap: !_can(LinkMethods.botMemory)
                        ? null
                        : () => _run((peer) => state._openMemory(peer, draft)),
                  ),
                ],
              ),
            ],
          ),
          BotEditorSection(
            title: _tr('Destructive actions', '危险操作'),
            danger: true,
            children: [
              BotEditorDangerButton(
                onPressed:
                    !_can(LinkMethods.clearBotChat) ||
                        draft.base['session'] is! String
                    ? null
                    : () => _remove(draft, clearChat: true),
                icon: Icons.delete_sweep_outlined,
                label: _tr('Clear chat', '清空聊天'),
              ),
              if (!draft.assistant)
                BotEditorDangerButton(
                  onPressed: !_can(LinkMethods.deleteBot)
                      ? null
                      : () => _remove(draft),
                  icon: Icons.delete_outline,
                  label: _tr('Delete Bot', '删除机器人'),
                ),
            ],
          ),
        ],
      ]),
    );
  }

  void _saveBot(_PeopleDraft draft) {
    if (!draft.replaceAvatar || !isAvatarImage(_text(draft.base, 'avatar'))) {
      _run((peer) => state._saveEntry(peer, draft));
      return;
    }
    final removing =
        draft.pickedPicture == null &&
        (draft.text['avatar'] ?? '').trim().isEmpty;
    final name = draft.name;
    _confirm(
      removing
          ? _tr('Remove the picture for $name?', '移除 $name 的头像？')
          : _tr('Replace the picture for $name?', '更换 $name 的头像？'),
      _tr(
        'Saving will remove the current picture from this Bot on the host.',
        '保存后，主机将移除此机器人的旧头像。',
      ),
      (peer) => state._saveEntry(peer, draft),
      action: removing
          ? _tr('Remove picture', '移除头像')
          : _tr('Replace picture', '更换头像'),
      icon: Icons.image_outlined,
    );
  }

  Widget _group(_PeopleDraft draft, _PeopleCatalog catalog) {
    final editable = draft.canEditGroup && _can(LinkMethods.saveGroup);
    return state._editor(
      title: draft.id == null
          ? _tr('Create group', '创建群聊')
          : _tr('Group settings', '群聊设置'),
      name: draft.id == null ? null : draft.name,
      icon: Icons.groups_outlined,
      actions: _actions(
        label: draft.canEditGroup ? _tr('Save', '保存') : null,
        onSave: !editable || !draft.changedGroup
            ? null
            : () => _run((peer) => state._saveEntry(peer, draft)),
      ),
      body: _section([
        BotEditorSection(
          title: _tr('Group details', '群聊资料'),
          children: [_name(draft, editable: editable)],
        ),
        _toolAccess(),
        if (draft.canEditGroup) ...[
          BotEditorSection(
            title: _tr('Members', '成员'),
            children: [
              for (final bot in catalog.bots)
                BotEditorMemberTile(
                  member: (
                    id: bot['id'] as String,
                    name: bot['name'] as String,
                  ),
                  selected: draft.members.contains(bot['id']),
                  onChanged: !editable
                      ? null
                      : (on) => _edit(() {
                          final id = bot['id'] as String;
                          if (on == true) {
                            draft.members.add(id);
                          } else {
                            draft.members.remove(id);
                            if (draft.canEditLead && draft.lead == id) {
                              draft.lead = null;
                            }
                          }
                        }),
                ),
              if (draft.canEditLead) _groupLeadPicker(draft, catalog, editable),
            ],
          ),
          if (draft.groupOptions.isNotEmpty)
            BotEditorSection(
              title: _tr('Conversation', '对话设置'),
              children: [
                if (draft.groupOptions.contains('passes'))
                  _field(
                    draft,
                    'passes',
                    _tr('Conversation passes', '转交次数上限'),
                    numeric: true,
                    editable: editable,
                    hint: _tr(
                      '0 for unlimited, or at least 2',
                      '0 表示不限，否则至少为 2',
                    ),
                  ),
                if (draft.groupOptions.contains('rules'))
                  _field(
                    draft,
                    'rules',
                    _tr('Rules', '规则'),
                    lines: 2,
                    editable: editable,
                  ),
                if (draft.groupOptions.contains('gap'))
                  _field(
                    draft,
                    'gap',
                    _tr('Reply delay (seconds)', '回复间隔（秒）'),
                    numeric: true,
                    editable: editable,
                    hint: _tr(
                      'Time between Bot replies. 0 for no delay.',
                      '机器人回复之间的间隔，0 表示立即回复。',
                    ),
                  ),
              ],
            ),
          if (draft.groupOptions.length < _groupOptions.length)
            BotEditorNotice(
              message: _tr(
                'Additional group settings appear when the host advertises them.',
                '主机提供更多群聊设置时，这里会显示相应选项。',
              ),
            ),
        ] else
          BotEditorNotice(
            message: _tr(
              'This host did not provide group membership.',
              '此主机未提供群成员信息。',
            ),
          ),
        if (draft.id != null)
          BotEditorSection(
            title: _tr('Destructive actions', '危险操作'),
            danger: true,
            children: [
              BotEditorDangerButton(
                onPressed: !_can(LinkMethods.deleteGroup)
                    ? null
                    : () => _remove(draft),
                icon: Icons.delete_outline,
                label: _tr('Delete group', '删除群聊'),
              ),
            ],
          ),
      ]),
    );
  }

  Widget _groupLeadPicker(
    _PeopleDraft draft,
    _PeopleCatalog catalog,
    bool editable,
  ) => BotEditorLeadPicker(
    pickerKey: const ValueKey('remote-group-lead'),
    label: _tr('Default lead', '默认领队'),
    defaultLabel: _tr('Automatic', '自动'),
    members: [
      for (final bot in catalog.bots)
        if (draft.members.contains(bot['id']))
          (id: bot['id'] as String, name: bot['name'] as String),
    ],
    lead: draft.lead,
    onChanged: editable ? (id) => _edit(() => draft.lead = id) : null,
  );

  Widget _memory(_PeopleDraft draft) => state._editor(
    title: _tr('Memory & self notes', '记忆和自我笔记'),
    name: state._returnToBot?.name,
    icon: Icons.notes_outlined,
    actions: _actions(),
    body: _section([
      for (final key in ['text', if (draft.selfAdvertised) 'self'])
        BotEditorSection(
          title: key == 'text'
              ? _tr('Memory', '记忆')
              : _tr('Self notes', '自我笔记'),
          children: [
            _field(
              draft,
              key,
              key == 'text' ? _tr('Memory', '记忆') : _tr('Self notes', '自我笔记'),
              lines: 4,
              editable: _can(
                key == 'text'
                    ? LinkMethods.setBotMemory
                    : LinkMethods.setBotSelf,
              ),
            ),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: FilledButton(
                style: botEditorButtonStyle(state.context),
                onPressed:
                    !_can(
                          key == 'text'
                              ? LinkMethods.setBotMemory
                              : LinkMethods.setBotSelf,
                        ) ||
                        draft.text[key] == draft.base[key]
                    ? null
                    : () {
                        if (draft.text[key]!.trim().isNotEmpty) {
                          _run((peer) => state._saveMemory(peer, draft, key));
                        } else {
                          _confirm(
                            key == 'text'
                                ? _tr('Clear memory?', '要清空记忆吗？')
                                : _tr('Clear self notes?', '要清空自我笔记吗？'),
                            key == 'text'
                                ? _tr(
                                    'This removes the Bot’s memory and saved impressions of you on the host.',
                                    '这会删除主机上此机器人对你的记忆和已保存的印象。',
                                  )
                                : _tr(
                                    'This removes the Bot’s self notes on the host.',
                                    '这会删除主机上此机器人的自我笔记。',
                                  ),
                            (peer) => state._saveMemory(peer, draft, key),
                            action: key == 'text'
                                ? _tr('Clear memory', '清空记忆')
                                : _tr('Clear self notes', '清空自我笔记'),
                            icon: Icons.delete_sweep_outlined,
                          );
                        }
                      },
                child: Text(
                  key == 'text'
                      ? _tr('Save memory', '保存记忆')
                      : _tr('Save self notes', '保存自我笔记'),
                ),
              ),
            ),
          ],
        ),
    ]),
  );

  Widget _profile(_PeopleDraft draft) => state._editor(
    title: _tr('My host profile', '我的主机资料'),
    icon: Icons.person_outline,
    body: _section([
      BotEditorNotice(
        message: _tr(
          'The host does not share your current profile. Enter the complete replacement that its Bots should see.',
          '主机不会共享你当前的资料。请填写要让主机机器人看到的完整新资料。',
        ),
      ),
      BotEditorSection(
        title: _tr('Profile', '基本资料'),
        children: [
          _name(draft, editable: _can(LinkMethods.setMe)),
          _gender(draft, editable: _can(LinkMethods.setMe)),
          _signature(draft, editable: _can(LinkMethods.setMe)),
          _picture(draft, editable: _can(LinkMethods.setMe)),
        ],
      ),
    ]),
    actions: _actions(
      label: _tr('Review replacement', '检查替换内容'),
      onSave: !_can(LinkMethods.setMe)
          ? null
          : () => _confirm(
              _tr('Replace the host profile?', '替换主机上的个人资料？'),
              draft.pickedPicture == null
                  ? _tr(
                      'This replaces all profile fields and will remove the existing picture, if any. Empty fields are cleared.',
                      '这会替换全部个人资料字段并删除已有头像（如有）。留空的字段将被清除。',
                    )
                  : _tr(
                      'This replaces all profile fields and the picture. Empty fields are cleared.',
                      '这会替换全部个人资料字段及头像。留空的字段将被清除。',
                    ),
              (peer) => state._replaceProfile(peer, draft),
              action: _tr('Replace profile', '替换资料'),
              icon: Icons.person_outline,
            ),
    ),
  );

  Widget _picturePreview(ImageAttachment image) => Image.memory(
    image.bytes,
    width: 42,
    height: 42,
    fit: BoxFit.cover,
    cacheWidth: 84,
    errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined),
    semanticLabel: _tr('Avatar', '头像'),
  );

  Widget _picture(
    _PeopleDraft draft, {
    required bool editable,
    bool preview = true,
  }) {
    final context = state.context;
    final image =
        draft.pickedPicture ?? (draft.replaceAvatar ? null : draft.hostPicture);
    final hostPicture =
        !draft.replaceAvatar &&
        draft.base['avatar'] is String &&
        isAvatarImage(draft.base['avatar'] as String);
    final clear =
        draft.pickedPicture != null ||
        hostPicture ||
        (draft.text['avatar'] ?? '').isNotEmpty;
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (preview && image != null)
          ClipOval(child: _picturePreview(image))
        else if (hostPicture && image == null)
          Tooltip(
            message: _tr('Host picture kept', '保留主机头像'),
            child: Icon(
              Icons.image_outlined,
              size: 18,
              color: SettingsColors.textSecondary,
            ),
          ),
        OutlinedButton(
          style: botEditorOutlinedButtonStyle(context),
          onPressed:
              editable &&
                  (state.widget.options.pickImage != null ||
                      WindowControls.canPickFiles)
              ? () => _run((peer) => state._pick(peer, draft))
              : null,
          child: Text(_tr('Choose picture', '选择图片')),
        ),
        if (clear)
          TextButton(
            style: botEditorGhostButtonStyle(context, destructive: true),
            onPressed: !editable
                ? null
                : () => _edit(() {
                    draft.replaceAvatar = true;
                    draft.pickedPicture = null;
                    draft.text['avatar'] = '';
                    draft.avatarFieldVersion++;
                  }),
            child: Text(_tr('Remove avatar', '移除头像')),
          ),
        if (draft.kind == _PeopleKind.bot &&
            draft.replaceAvatar &&
            draft.id != null)
          TextButton(
            style: botEditorGhostButtonStyle(context),
            onPressed: !editable
                ? null
                : () => _edit(() {
                    final value = draft.base['avatar'];
                    draft.replaceAvatar = false;
                    draft.pickedPicture = null;
                    draft.text['avatar'] =
                        value is String && !isAvatarImage(value) ? value : '';
                    draft.avatarFieldVersion++;
                  }),
            child: Text(_tr('Keep original avatar', '保留原有头像')),
          ),
      ],
    );
  }

  void _confirm(
    String title,
    String detail,
    Future<void> Function(LinkPeer) run, {
    required String action,
    required IconData icon,
  }) {
    final offset = state._scroll.hasClients ? state._scroll.offset : 0.0;
    state._changeView(
      () => state._confirm = (
        title: title,
        detail: detail,
        run: run,
        action: action,
        icon: icon,
        previousOffset: offset,
      ),
    );
  }

  void _remove(_PeopleDraft draft, {bool clearChat = false}) {
    final bot = draft.kind == _PeopleKind.bot;
    final name = draft.name;
    final title = clearChat
        ? _tr('Clear the chat with $name?', '要清空与 $name 的聊天吗？')
        : _tr('Delete $name?', '要删除 $name 吗？');
    final detail = clearChat
        ? _tr(
            'The host will delete this private conversation. The Bot’s settings and memory stay.',
            '主机会删除这段私聊。机器人的设置和记忆将保留。',
          )
        : bot
        ? _tr(
            'The host will delete this Bot, its private chat and its memory.',
            '主机会删除此机器人、它的私聊和记忆。',
          )
        : _tr(
            'The host will delete this group and its messages.',
            '主机会删除此群聊及其消息。',
          );
    _confirm(
      title,
      detail,
      (peer) => state._remove(peer, draft, clearChat: clearChat),
      action: clearChat ? _tr('Clear chat', '清空聊天') : _tr('Delete', '删除'),
      icon: clearChat ? Icons.delete_sweep_outlined : Icons.delete_outline,
    );
  }
}
