import 'dart:async';

import 'package:bao_link/bao_link.dart';
import 'package:bao_markdown/bao_markdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chat/chat_keys.dart';
import '../chat/composer/composer_mock_data.dart';
import '../chat/composer/composer_presentation.dart';
import '../chat/composer/suggestion_menu.dart';
import '../chat/widgets/image_thumbnails.dart';
import '../l10n/l10n.dart';
import '../workspace/window_controls.dart';
import 'desktop_host_chats.dart';
import 'desktop_host_controls.dart';
import 'desktop_host_session_controls.dart';
import 'desktop_remote_media.dart';

/// An in-memory snapshot without a live input connection or peer.
class DesktopHostDraft {
  DesktopHostDraft(
    this.text, {
    TextSelection? selection,
    Iterable<DesktopRemoteDraftImage> images = const [],
  }) : selection = selection ?? TextSelection.collapsed(offset: text.length),
       images = List.unmodifiable(images);

  final String text;
  final TextSelection selection;
  final List<DesktopRemoteDraftImage> images;

  bool get isEmpty => text.isEmpty && images.isEmpty;
}

/// The normal chat editor and send controls for a host conversation.
/// Key the composer by conversation so it can supply its own initial draft.
class DesktopHostComposer extends StatefulWidget {
  const DesktopHostComposer({
    super.key,
    required this.initialDraft,
    required this.busy,
    required this.placeholder,
    required this.sendLabel,
    required this.onChanged,
    required this.onSend,
    this.controls,
    this.peer,
    this.chat,
    this.isMediaCurrent,
    this.onSendWithAttachments,
    this.deliveryMenu,
  });

  final DesktopHostDraft initialDraft;
  final bool busy;
  final String placeholder;
  final String sendLabel;
  final ValueChanged<DesktopHostDraft> onChanged;
  final Widget? deliveryMenu;
  final DesktopHostSessionControls? controls;
  final LinkPeer? peer;
  final DesktopHostChat? chat;
  final bool Function()? isMediaCurrent;
  final Future<bool> Function(String, DesktopRemoteAttachments)?
  onSendWithAttachments;

  /// True only for a confirmed send in the current host conversation.
  final Future<bool> Function(String) onSend;

  @override
  State<DesktopHostComposer> createState() => _DesktopHostComposerState();
}

typedef _CompletionAnchor = ({SuggestionKind kind, int start});
typedef _CompletionTrigger = ({
  _CompletionAnchor anchor,
  int end,
  String query,
});

class _DesktopHostComposerState extends State<DesktopHostComposer>
    with ChatKeyTarget {
  final _focus = FocusNode(debugLabel: 'Host composer');
  final _scroll = ScrollController();
  late final MarkdownController _draft;
  int _savedVersion = 0;
  late TextSelection _savedSelection;
  Object? _sendRequest;
  bool get _sending => _sendRequest != null;
  final _images = <DesktopRemotePickedImage>[];
  final _mentions = <DesktopRemoteMention>[];
  Object? _mediaRequest;
  List<DesktopRemoteMention>? _choices;
  bool _truncated = false;
  String _query = '';
  String? _mediaError;
  _CompletionTrigger? _trigger;
  _CompletionAnchor? _dismissed;
  Object? _completionRequest;
  Map<Suggestion, DesktopRemoteMention?> _options = const {};
  List<SuggestionMatch> _matches = const [];
  int _highlighted = 0;

  DesktopRemoteMediaTarget? _targetOf(DesktopHostComposer composer) {
    final peer = composer.peer;
    final chat = composer.chat;
    if (peer == null ||
        chat == null ||
        composer.onSendWithAttachments == null ||
        !const {'project', 'bot', 'group'}.contains(chat.kind)) {
      return null;
    }
    return (peer, chat.kind, chat.id, chat.projectId);
  }

  DesktopRemoteMediaTarget? get _target => _targetOf(widget);

  bool _current(DesktopRemoteMediaTarget target) =>
      mounted &&
      _target == target &&
      !target.$1.isClosed &&
      (widget.isMediaCurrent?.call() ?? true);

  @override
  bool get chatComposing => _draft.isComposing;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialDraft;
    final target = _target;
    if (target != null) {
      _images.addAll(
        initial.images.map((image) => image.bind(target)).nonNulls,
      );
    }
    _draft = MarkdownController(
      text: initial.text,
      selection: initial.selection,
      plain: true,
    )..addListener(_draftChanged);
    _savedSelection = _draft.selection;
    _focus.addListener(_syncCompletion);
  }

  @override
  void didUpdateWidget(DesktopHostComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    final target = _target;
    final initial = widget.initialDraft;
    if (_targetOf(oldWidget) != target) {
      _images.clear();
      if (target != null) {
        _images.addAll(
          initial.images.map((image) => image.bind(target)).nonNulls,
        );
      }
      _mentions.clear();
      _clearCompletion();
      _dismissed = null;
      _choices = null;
      _mediaRequest = null;
      _mediaError = null;
      _sendRequest = null;
    }
    // A suggested reply can fill an empty draft without replacing its images.
    if (initial.text.isEmpty ||
        initial.text == _draft.text ||
        identical(initial, oldWidget.initialDraft)) {
      return;
    }
    if (_draft.isComposing || _draft.text.trim().isNotEmpty) {
      _saveDraft();
      return;
    }
    _draft.replace(
      0,
      _draft.length,
      initial.text,
      selection: initial.selection,
    );
    _focus.requestFocus();
  }

  @override
  void dispose() {
    _draft.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _draftChanged() {
    // Composition can change without changing the text or caret.
    _syncCompletion();
    final version = _draft.textVersion;
    final selection = _draft.selection;
    if (version == _savedVersion && selection == _savedSelection) return;
    _savedVersion = version;
    _savedSelection = selection;
    _saveDraft();
  }

  void _saveDraft() => widget.onChanged(
    DesktopHostDraft(
      _draft.text,
      selection: _draft.selection,
      images: _images.map((image) => image.snapshot),
    ),
  );

  bool get _canSend =>
      !widget.busy &&
      widget.controls?.live != true &&
      !_sending &&
      _mediaRequest == null &&
      !_draft.isComposing &&
      (_draft.text.trim().isNotEmpty || _images.isNotEmpty) &&
      (_target == null || _current(_target!));

  static final _mentionBoundary = RegExp(r'[\s(\[{]');
  static final _commandName = RegExp(r'^[a-zA-Z0-9_:.\-]+$');

  _CompletionTrigger? _typedTrigger(DesktopRemoteMediaTarget target) {
    if (target.$2 != 'project' ||
        !_current(target) ||
        !_focus.hasFocus ||
        _draft.isComposing ||
        _mediaRequest != null ||
        _choices != null) {
      return null;
    }
    final selection = _draft.selection;
    final text = _draft.text;
    final end = selection.baseOffset;
    if (!selection.isCollapsed ||
        end < 1 ||
        end > text.length ||
        text[end - 1].trim().isEmpty ||
        (end < text.length && text[end].trim().isNotEmpty)) {
      return null;
    }
    var start = end - 1;
    while (start > 0 && !_mentionBoundary.hasMatch(text[start - 1])) {
      start--;
    }
    final query = text.substring(start + 1, end);
    final kind = switch (text[start]) {
      '@' when (target.$4?.isNotEmpty ?? false) && !query.contains('"') =>
        SuggestionKind.file,
      '/'
          when text.substring(0, start).trim().isEmpty &&
              (query.isEmpty || _commandName.hasMatch(query)) =>
        SuggestionKind.command,
      _ => null,
    };
    return kind == null
        ? null
        : (anchor: (kind: kind, start: start), end: end, query: query);
  }

  void _clearCompletion() {
    _trigger = null;
    _completionRequest = null;
    _options = const {};
    _matches = const [];
    _highlighted = 0;
  }

  void _dismissCompletion() {
    _dismissed = _trigger?.anchor ?? _dismissed;
    _clearCompletion();
  }

  void _syncCompletion() {
    final target = _target;
    final trigger = target == null ? null : _typedTrigger(target);
    if (trigger?.anchor != _dismissed) _dismissed = null;
    if (trigger == null || trigger.anchor == _dismissed) {
      if (_trigger != null) setState(_clearCompletion);
      return;
    }
    if (trigger == _trigger) return;
    final newAnchor = trigger.anchor != _trigger?.anchor;
    setState(() {
      if (newAnchor) _clearCompletion();
      _trigger = trigger;
      _updateMatches(trigger.query);
    });
    if (newAnchor) unawaited(_loadCompletion(target!, trigger.anchor.kind));
  }

  void _updateMatches(String query) {
    _matches = rankSuggestions(
      _options.keys.toList(),
      query,
    ).take(100).toList();
    _highlighted = 0;
  }

  Future<void> _loadCompletion(
    DesktopRemoteMediaTarget target,
    SuggestionKind kind,
  ) async {
    final request = _completionRequest = Object();
    final Map<Suggestion, DesktopRemoteMention?> options;
    try {
      if (kind == SuggestionKind.file) {
        final result = await remoteProjectMentions(target);
        options = {
          for (final mention in result.entries)
            Suggestion(kind: kind, label: mention.path): mention,
        };
      } else {
        options = {
          for (final command in await _sessionCommands(target)) command: null,
        };
      }
    } on Object {
      // Suggestions are optional. Older hosts and unavailable file lists
      // leave the typed text usable, including while the request is pending.
      if (identical(_completionRequest, request)) _completionRequest = null;
      return;
    }
    final trigger = _trigger;
    if (!identical(_completionRequest, request) ||
        trigger == null ||
        _typedTrigger(target) != trigger) {
      return;
    }
    setState(() {
      _completionRequest = null;
      _options = options;
      _updateMatches(trigger.query);
    });
  }

  Future<List<Suggestion>> _sessionCommands(
    DesktopRemoteMediaTarget target,
  ) async {
    final result = await target.$1.call(LinkMethods.sessionCommands, {
      'session': target.$3,
    });
    if (result case {'commands': final List<Object?> commands}) {
      return [
        for (final command in commands)
          if (command case {'name': final String name}
              when _commandName.hasMatch(name) &&
                  !const {'btw', 'fork'}.contains(name.toLowerCase()))
            Suggestion(
              kind: SuggestionKind.command,
              label: name,
              detail: [
                if (command case {'argumentHint': final String hint}
                    when hint.isNotEmpty)
                  hint,
                if (command case {'description': final String text}
                    when text.isNotEmpty)
                  text,
              ].join('  '),
            ),
      ];
    }
    return const [];
  }

  void _acceptCompletion(_CompletionTrigger trigger, Suggestion suggestion) {
    final target = _target;
    if (target == null ||
        _trigger != trigger ||
        _typedTrigger(target) != trigger ||
        !_options.containsKey(suggestion)) {
      return;
    }
    final mention = _options[suggestion];
    final text = mention?.reference ?? '/${suggestion.label}';
    // Reuse a space already in the draft so replacing a query in the middle
    // keeps the rest of the text and puts the caret after the reference.
    final hasSpace = _draft.text.startsWith(' ', trigger.end);
    setState(() {
      _dismissCompletion();
      if (mention != null) _mentions.add(mention);
      _draft.replace(
        trigger.anchor.start,
        trigger.end,
        hasSpace ? text : '$text ',
        selection: TextSelection.collapsed(
          offset: trigger.anchor.start + text.length + 1,
        ),
      );
    });
    _focus.requestFocus();
  }

  KeyEventResult? _completionKey(KeyEvent event) {
    final trigger = _trigger;
    final target = _target;
    if (trigger == null || target == null || _typedTrigger(target) != trigger) {
      return null;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape &&
        (_matches.isNotEmpty || _completionRequest != null)) {
      setState(_dismissCompletion);
      return KeyEventResult.handled;
    }
    if (_matches.isEmpty) return null;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isShiftPressed ||
        keyboard.isAltPressed ||
        keyboard.isControlPressed ||
        keyboard.isMetaPressed) {
      return null;
    }
    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown) {
      final delta = key == LogicalKeyboardKey.arrowUp ? -1 : 1;
      setState(() => _highlighted = (_highlighted + delta) % _matches.length);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.tab) {
      if (event is KeyDownEvent) {
        _acceptCompletion(trigger, _matches[_highlighted].suggestion);
      }
      return KeyEventResult.handled;
    }
    return handleComposerEnter(
      event,
      () => _acceptCompletion(trigger, _matches[_highlighted].suggestion),
    );
  }

  KeyEventResult _handleKey(KeyEvent event) => handleComposerKey(
    event,
    composing: _draft.isComposing,
    dispatch: (event) =>
        _completionKey(event) ?? handleComposerEnter(event, _submit),
  );

  void _submit() => unawaited(_send());

  Future<void> _send() async {
    if (!_canSend) return;
    final version = _draft.textVersion;
    final target = _target;
    final text = _draft.text;
    final outgoing = target == null
        ? null
        : DesktopRemoteAttachments(
            target,
            _images,
            remoteMentionsIn(text, target, _mentions),
          );
    final request = Object();
    setState(() {
      _dismissCompletion();
      _sendRequest = request;
    });
    try {
      final confirmed = await (outgoing == null || outgoing.isEmpty
          ? widget.onSend(text)
          : widget.onSendWithAttachments!(text, outgoing));
      if (confirmed &&
          mounted &&
          identical(_sendRequest, request) &&
          (target == null || _current(target))) {
        if (outgoing != null) _images.removeWhere(outgoing.images.contains);
        if (_draft.textVersion == version && !_draft.isComposing) {
          _mentions.clear();
          _draft.forgetUndo();
          if (text.isNotEmpty) {
            _draft.replaceUnrecorded(0, _draft.length, '');
            return; // The text listener saves the remaining images with it.
          }
        }
        if (outgoing != null && outgoing.images.isNotEmpty) _saveDraft();
      }
    } finally {
      if (mounted && identical(_sendRequest, request)) {
        setState(() => _sendRequest = null);
      }
    }
  }

  Future<void> _mediaAction(
    DesktopRemoteMediaTarget target,
    Future<void> Function(bool Function()) action,
  ) async {
    if (!_current(target) ||
        widget.busy ||
        _sending ||
        _mediaRequest != null ||
        _draft.isComposing) {
      return;
    }
    final l10n = context.l10n;
    final request = Object();
    bool current() => _current(target) && identical(_mediaRequest, request);
    setState(() {
      _dismissCompletion();
      _mediaRequest = request;
      _mediaError = null;
      _choices = null;
    });
    try {
      await action(current);
    } on Object catch (error) {
      if (current()) _mediaError = remoteMediaError(l10n, error);
    } finally {
      if (mounted && identical(_mediaRequest, request)) {
        setState(() => _mediaRequest = null);
      }
    }
  }

  void _insertMention(DesktopRemoteMention mention) {
    if (!_current(mention.target) || _draft.isComposing) return;
    final selection = _draft.selection;
    final start = selection.isValid ? selection.start : _draft.length;
    final end = selection.isValid ? selection.end : _draft.length;
    final prefix = start == 0 || _draft.text[start - 1].trim().isEmpty
        ? ''
        : ' ';
    setState(() {
      _choices = null;
      _mentions.add(mention);
      _draft.replace(start, end, '$prefix${mention.reference} ');
    });
    _focus.requestFocus();
  }

  int get _availableImageBytes =>
      remoteAttachmentLimit -
      _images.fold<int>(0, (sum, image) => sum + image.size);

  void _pickImage(DesktopRemoteMediaTarget target) => unawaited(
    _mediaAction(target, (current) async {
      final image = await pickRemoteAttachment(
        target: target,
        availableBytes: _availableImageBytes,
        isCurrent: current,
      );
      if (image != null && current()) {
        _images.add(image);
        _saveDraft();
      }
    }),
  );

  Future<bool> _pasteImages(DesktopRemoteMediaTarget target) async {
    var handled = false;
    await _mediaAction(target, (current) async {
      final images = await WindowControls.readPasteboardImages();
      if (!current() || images.isEmpty) return;
      handled = true;
      if (_images.length + images.length > remoteAttachmentCount) {
        throw const RemoteTooManyImages();
      }
      var remaining = _availableImageBytes;
      final attachments = <DesktopRemotePickedImage>[];
      for (final image in images) {
        final extension = switch (image.mediaType) {
          'image/png' => 'png',
          'image/jpeg' => 'jpg',
          'image/gif' => 'gif',
          'image/webp' => 'webp',
          _ => throw const RemoteUnsupportedImage(),
        };
        final name = image.name;
        final attachment = DesktopRemotePickedImage.checked(
          target: target,
          name: name != null && remoteFileName(name)
              ? name
              : 'image.$extension',
          type: image.mediaType,
          bytes: image.bytes,
          availableBytes: remaining,
        );
        remaining -= attachment.size;
        attachments.add(attachment);
      }
      _images.addAll(attachments);
      _saveDraft();
    });
    return handled || !_current(target);
  }

  void _upload(DesktopRemoteMediaTarget target) => unawaited(
    _mediaAction(target, (current) async {
      final mention = await uploadRemoteFile(
        target: target,
        isCurrent: current,
      );
      if (mention != null && current()) _insertMention(mention);
    }),
  );

  void _listMentions(DesktopRemoteMediaTarget target) {
    if (_choices != null) {
      setState(() => _choices = null);
      return;
    }
    unawaited(
      _mediaAction(target, (current) async {
        final result = await remoteProjectMentions(target);
        if (!current()) return;
        _query = '';
        _choices = result.entries;
        _truncated = result.truncated;
      }),
    );
  }

  Widget _mentionPicker(List<DesktopRemoteMention> choices, bool zh) {
    final matches = choices
        .where((entry) => entry.path.toLowerCase().contains(_query))
        .take(100)
        .toList();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            decoration: InputDecoration(
              isDense: true,
              hintText: zh ? '查找主机项目文件' : 'Find a host project file',
            ),
            onChanged: (value) => setState(() => _query = value.toLowerCase()),
          ),
          if (_truncated)
            Text(zh ? '主机仅返回了部分文件。' : 'The host returned a partial file list.'),
          if (matches.isEmpty) Text(context.l10n.remoteBrowserEmpty),
          if (matches.isNotEmpty)
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * .20,
              ),
              child: ListView.builder(
                primary: false,
                shrinkWrap: true,
                itemCount: matches.length,
                itemBuilder: (context, index) => Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => _insertMention(matches[index]),
                    child: Text(
                      matches[index].path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget? _completionPicker(DesktopRemoteMediaTarget? target) {
    final trigger = _trigger;
    if (target == null ||
        trigger == null ||
        _matches.isEmpty ||
        _typedTrigger(target) != trigger) {
      return null;
    }
    final matches = _matches;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .25,
          ),
          child: SuggestionMenu(
            title: trigger.anchor.kind == SuggestionKind.file
                ? context.l10n.composerMentions
                : context.l10n.composerCommands,
            matches: matches,
            highlighted: _highlighted,
            onHighlight: (index) {
              if (identical(_matches, matches)) {
                setState(() => _highlighted = index);
              }
            },
            onSelect: (index) =>
                _acceptCompletion(trigger, matches[index].suggestion),
          ),
        ),
      ),
    );
  }

  Widget _mediaButton(
    String key,
    IconData icon,
    String name,
    VoidCallback? onPressed,
  ) => IconButton(
    key: ValueKey(key),
    tooltip: name,
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints.tightFor(width: 28, height: 32),
    icon: Icon(icon, size: 17),
    onPressed: onPressed,
  );

  @override
  Widget build(BuildContext context) {
    final target = _target;
    final online = target != null && _current(target);
    final canChange =
        online && !widget.busy && !_sending && _mediaRequest == null;
    final hasProject =
        target?.$2 == 'project' && (target?.$4?.isNotEmpty ?? false);
    final choices = _choices;
    final zh = context.l10n.localeName.startsWith('zh');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: ListenableBuilder(
        listenable: _focus,
        builder: (context, child) => ComposerLayout(
          focused: _focus.hasFocus,
          aboveEditor: [
            if (online && choices != null) _mentionPicker(choices, zh),
            ?_completionPicker(target),
            if (_images.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: ImageThumbnails(
                  key: ValueKey(online ? target : null),
                  memoryOnly: true,
                  isPreviewCurrent: () => target != null && _current(target),
                  images: [for (final image in _images) image.snapshot.preview],
                  onRemove: canChange
                      ? (index) => setState(() {
                          _images.removeAt(index);
                          _saveDraft();
                        })
                      : null,
                ),
              ),
          ],
          editor: child!,
          toolbar: ComposerToolbar(
            pickers: DesktopHostPickers(
              controls: widget.controls,
              focusNode: _focus,
            ),
            actions: [
              if (online && WindowControls.canPickFiles) ...[
                if (hasProject || target.$2 == 'bot')
                  _mediaButton(
                    'desktop-remote-upload',
                    Icons.upload_file,
                    zh ? '上传文件到主机' : 'Upload file to host',
                    canChange ? () => _upload(target) : null,
                  ),
                _mediaButton(
                  'desktop-remote-attach-image',
                  Icons.add_photo_alternate_outlined,
                  zh ? '添加图片' : 'Attach image',
                  canChange && _images.length < remoteAttachmentCount
                      ? () => _pickImage(target)
                      : null,
                ),
              ],
              if (online && hasProject)
                _mediaButton(
                  'desktop-remote-mention',
                  Icons.alternate_email,
                  zh ? '引用主机项目文件' : 'Mention a host project file',
                  canChange ? () => _listMentions(target) : null,
                ),
              ?widget.deliveryMenu,
            ],
            submit: ListenableBuilder(
              listenable: _draft,
              builder: (context, _) {
                final controls = widget.controls;
                final showStop = controls?.showStop == true;
                return ComposerSendButton(
                  tooltip: showStop
                      ? context.l10n.composerStop
                      : widget.sendLabel,
                  onSend: !showStop && _canSend ? _submit : null,
                  showStop: showStop,
                  onStop: controls != null && controls.canStop
                      ? () => unawaited(controls.stop())
                      : null,
                );
              },
            ),
          ),
          status: [
            if (_mediaRequest != null)
              const LinearProgressIndicator(minHeight: 2),
            if (_mediaError case final error?)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                child: Text(error),
              ),
            if (widget.controls case final controls?
                when controls.choiceFailed || controls.stopFailed)
              DesktopHostActionError(controls: controls),
          ],
        ),
        child: ComposerEditorViewport(
          controller: _scroll,
          child: Semantics(
            label: widget.placeholder,
            textField: true,
            multiline: true,
            child: MarkdownEditor(
              controller: _draft,
              focusNode: _focus,
              scrollController: _scroll,
              shrinkWrap: true,
              pastePlainText: true,
              onPaste: target == null ? null : () => _pasteImages(target),
              placeholder: widget.placeholder,
              onKey: _handleKey,
              style: composerEditorStyle(context),
            ),
          ),
        ),
      ),
    );
  }
}
