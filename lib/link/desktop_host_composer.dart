import 'dart:async';

import 'package:bao_link/bao_link.dart';
import 'package:bao_markdown/bao_markdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chat/chat_keys.dart';
import '../chat/composer/composer_presentation.dart';
import '../chat/floating/floating_registry.dart';
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

class _DesktopHostComposerState extends State<DesktopHostComposer>
    with ChatKeyTarget {
  final _focus = FocusNode(debugLabel: 'Host composer');
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
    super.dispose();
  }

  void _draftChanged() {
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

  KeyEventResult _handleKey(KeyEvent event) {
    if (!_draft.isComposing && event is! KeyUpEvent) {
      if (FloatingRegistry.handleKey(event) case final result?) return result;
    }
    final key = event.logicalKey;
    final keyboard = HardwareKeyboard.instance;
    if ((key != LogicalKeyboardKey.enter &&
            key != LogicalKeyboardKey.numpadEnter) ||
        event is KeyUpEvent ||
        _draft.isComposing ||
        keyboard.isShiftPressed ||
        keyboard.isAltPressed ||
        keyboard.isControlPressed ||
        keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent) unawaited(_send());
    return KeyEventResult.handled;
  }

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
    setState(() => _sendRequest = request);
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
        builder: (context, child) =>
            ComposerSurface(focused: _focus.hasFocus, child: child!),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Keep this slot even without media so Flutter never replaces the
            // editor (and its input connection) as the controls above it change.
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (online && choices != null) _mentionPicker(choices, zh),
                if (_images.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    child: ImageThumbnails(
                      key: ValueKey(online ? target : null),
                      memoryOnly: true,
                      isPreviewCurrent: () =>
                          target != null && _current(target),
                      images: [
                        for (final image in _images) image.snapshot.preview,
                      ],
                      onRemove: canChange
                          ? (index) => setState(() {
                              _images.removeAt(index);
                              _saveDraft();
                            })
                          : null,
                    ),
                  ),
              ],
            ),
            Padding(
              padding: composerEditorPadding,
              child: ClipRect(
                child: ConstrainedBox(
                  constraints: composerEditorConstraints(context),
                  child: Semantics(
                    label: widget.placeholder,
                    textField: true,
                    multiline: true,
                    child: MarkdownEditor(
                      controller: _draft,
                      focusNode: _focus,
                      shrinkWrap: true,
                      pastePlainText: true,
                      onPaste: target == null
                          ? null
                          : () => _pasteImages(target),
                      placeholder: widget.placeholder,
                      onKey: _handleKey,
                      style: composerEditorStyle(context),
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: composerToolbarPadding,
              child: Row(
                children: [
                  Expanded(
                    child: DesktopHostPickers(
                      controls: widget.controls,
                      focusNode: _focus,
                    ),
                  ),
                  const SizedBox(width: 8),
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
                  ListenableBuilder(
                    listenable: _draft,
                    builder: (context, _) {
                      final controls = widget.controls;
                      if (controls == null || !controls.showStop) {
                        return ComposerSendButton(
                          tooltip: widget.sendLabel,
                          onSend: _canSend ? _send : null,
                        );
                      }
                      return IgnorePointer(
                        ignoring: !controls.canStop,
                        child: Opacity(
                          opacity: controls.canStop ? 1 : .5,
                          child: ComposerSendButton(
                            tooltip: context.l10n.composerStop,
                            onSend: null,
                            onStop: () => unawaited(controls.stop()),
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
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
      ),
    );
  }
}
