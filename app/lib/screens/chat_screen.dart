import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../models/chat_message.dart';
import '../services/chat_service.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';

/// Family chat for one circle: the message list (newest at the bottom), a
/// composer, and live delivery from the shared WebSocket.
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.circleId,
    required this.circleName,
    this.service,
    this.incoming,
    this.reads,
    this.picker,
    this.edits,
    this.deletes,
    this.reconnects,
    this.isAdmin = false,
  });

  final String circleId;
  final String circleName;

  /// Overrides [ChatService.instance] (tests).
  final ChatService? service;

  /// Overrides [ChatEvents.incoming] (tests).
  final Stream<ChatMessage>? incoming;

  /// Overrides [ChatEvents.reads] (tests).
  final Stream<(String, ChatReader)>? reads;

  /// Overrides the photo picker (tests): returns JPEG/PNG bytes or null.
  final Future<Uint8List?> Function(ImageSource source)? picker;

  /// Overrides [ChatEvents.edits] / [ChatEvents.deletes] /
  /// [ChatEvents.reconnects] (tests).
  final Stream<ChatMessage>? edits;
  final Stream<(String, String)>? deletes;
  final Stream<void>? reconnects;

  /// Circle admins may delete anyone's message (moderation).
  final bool isAdmin;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _text = TextEditingController();
  final ScrollController _scroll = ScrollController();

  /// Newest first (matches a reversed ListView).
  final List<ChatMessage> _messages = <ChatMessage>[];
  final Set<String> _ids = <String>{};
  StreamSubscription<ChatMessage>? _sub;
  StreamSubscription<(String, ChatReader)>? _readSub;
  StreamSubscription<ChatMessage>? _editSub;
  StreamSubscription<(String, String)>? _delSub;
  StreamSubscription<void>? _reconnectSub;
  StreamSubscription<(String, ChatMessage)>? _deliveredSub;
  String? _clientId;
  String? _clientIdBody;
  ChatMessage? _editing;
  final Map<String, ChatReader> _readers = <String, ChatReader>{};
  final Map<String, Future<Uint8List>> _photos = <String, Future<Uint8List>>{};
  String? _me;
  int? _nextBefore;
  bool _loading = true;
  bool _loadingMore = false;
  bool _sending = false;
  String? _error;
  String? _sendError;
  ChatCircleInfo _info = const ChatCircleInfo();

  ChatService get _svc => widget.service ?? ChatService.instance;

  @override
  void initState() {
    super.initState();
    ChatEvents.viewingCircleId = widget.circleId;
    _sub = (widget.incoming ?? ChatEvents.incoming).listen(_onIncoming);
    _readSub = (widget.reads ?? ChatEvents.reads).listen(((String, ChatReader) e) {
      if (e.$1 != widget.circleId || !mounted) return;
      final ChatReader? old = _readers[e.$2.userId];
      if (old != null && old.lastSeq >= e.$2.lastSeq) return;
      setState(() => _readers[e.$2.userId] = e.$2);
    });
    _editSub = (widget.edits ?? ChatEvents.edits).listen((ChatMessage m) {
      if (m.circleId != widget.circleId || !mounted) return;
      _replace(m);
    });
    _delSub = (widget.deletes ?? ChatEvents.deletes).listen(((String, String) e) {
      if (e.$1 != widget.circleId || !mounted) return;
      _remove(e.$2);
    });
    _reconnectSub =
        (widget.reconnects ?? ChatEvents.reconnects).listen((_) => _catchUp());
    _deliveredSub = ChatEvents.localDelivered.listen(((String, ChatMessage) e) {
      if (e.$2.circleId != widget.circleId || !mounted) return;
      // A message that waited on the phone reached the server: swap the bubble for the stored one.
      _remove('local:${e.$1}');
      setState(() => _addAll(<ChatMessage>[e.$2]));
    });
    _scroll.addListener(_onScroll);
    _text.addListener(() => setState(() {}));
    unawaited(_load());
  }

  @override
  void dispose() {
    if (ChatEvents.viewingCircleId == widget.circleId) {
      ChatEvents.viewingCircleId = null;
    }
    _sub?.cancel();
    _readSub?.cancel();
    _editSub?.cancel();
    _delSub?.cancel();
    _reconnectSub?.cancel();
    _deliveredSub?.cancel();
    _scroll.dispose();
    _text.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final String me = await _svc.myUserId();
      final ChatPage page = await _svc.messages(widget.circleId);
      ChatCircleInfo info = const ChatCircleInfo();
      try {
        final ChatProtection? prot = protectionOf(_svc);
        if (prot != null) info = await prot.info(widget.circleId);
      } catch (_) {
        // The banner is informational; the chat itself still works.
      }
      if (!mounted) return;
      setState(() {
        _info = info;
        _me = me;
        ChatEvents.selfUserId = me;
        _messages.clear();
        _ids.clear();
        _addAll(page.messages);
        _nextBefore = page.nextBefore;
        _readers
          ..clear()
          ..addEntries(page.readers
              .map((ChatReader r) => MapEntry<String, ChatReader>(r.userId, r)));
        _loading = false;
      });
      unawaited(_markRead());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = describeChatError(e).message;
      });
    }
  }

  void _addAll(Iterable<ChatMessage> msgs) {
    for (final ChatMessage m in msgs) {
      if (_ids.add(m.id)) _messages.add(m);
    }
    _messages.sort((ChatMessage a, ChatMessage b) => b.seq.compareTo(a.seq));
  }

  Future<void> _markRead() async {
    try {
      await _svc.markRead(widget.circleId);
    } catch (_) {
      // The badge corrects itself on the next refresh.
    }
    await ChatEvents.refreshUnread();
  }

  void _replace(ChatMessage m) {
    final int i = _messages.indexWhere((ChatMessage x) => x.id == m.id);
    if (i < 0) return;
    setState(() {
      _messages[i] = m;
      _messages.sort((ChatMessage a, ChatMessage b) => b.seq.compareTo(a.seq));
    });
  }

  void _remove(String id) {
    if (!_ids.remove(id)) return;
    setState(() => _messages.removeWhere((ChatMessage x) => x.id == id));
  }

  /// After the socket (re)connects, fetch whatever arrived while it was down.
  Future<void> _catchUp() async {
    if (_loading || _error != null || !mounted) return;
    try {
      final int newest = _messages.isEmpty ? 0 : _messages.first.seq;
      final ChatPage page = await _svc.messages(widget.circleId, after: newest);
      if (!mounted) return;
      final bool fresh = page.messages.any((ChatMessage m) => !_ids.contains(m.id));
      setState(() {
        _addAll(page.messages);
        for (final ChatReader r in page.readers) {
          _readers[r.userId] = r;
        }
      });
      if (fresh) unawaited(_markRead());
    } catch (_) {
      // The next reconnect or reopening the chat retries.
    }
  }

  void _onIncoming(ChatMessage m) {
    if (m.circleId != widget.circleId || !_ids.add(m.id)) return;
    setState(() {
      _messages.add(m);
      _messages.sort((ChatMessage a, ChatMessage b) => b.seq.compareTo(a.seq));
    });
    if (m.senderId != _me) unawaited(_markRead());
  }

  void _onScroll() {
    if (_nextBefore != null &&
        !_loadingMore &&
        _scroll.position.pixels >= _scroll.position.maxScrollExtent - 200) {
      unawaited(_loadMore());
    }
  }

  Future<void> _loadMore() async {
    final int? cursor = _nextBefore;
    if (cursor == null) return;
    setState(() => _loadingMore = true);
    try {
      final ChatPage page =
          await _svc.messages(widget.circleId, before: cursor);
      if (!mounted) return;
      setState(() {
        _addAll(page.messages);
        _nextBefore = page.nextBefore;
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  bool get _canSend =>
      !_sending &&
      _text.text.trim().isNotEmpty &&
      _text.text.characters.length <= kMaxChatLength;

  Future<void> _send() async {
    final String body = _text.text.trim();
    if (body.isEmpty || _sending) return;
    final ChatMessage? editing = _editing;
    // A retry of the same text reuses its client id so the server cannot
    // store it twice if the first attempt got through.
    if (_clientId == null || _clientIdBody != body) {
      _clientId = '${DateTime.now().microsecondsSinceEpoch}-${body.hashCode}';
      _clientIdBody = body;
    }
    setState(() {
      _sending = true;
      _sendError = null;
    });
    try {
      if (editing != null) {
        final ChatMessage upd =
            await _svc.edit(widget.circleId, editing.id, body);
        if (!mounted) return;
        setState(() {
          _sending = false;
          _editing = null;
          _text.clear();
        });
        _replace(upd);
        return;
      }
      final ChatMessage sent =
          await _svc.send(widget.circleId, body, clientId: _clientId);
      if (!mounted) return;
      setState(() {
        _sending = false;
        _clientId = null;
        _text.clear();
        _addAll(<ChatMessage>[sent]);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _sendError = describeChatError(e).message; // draft is kept
      });
    }
  }

  void _messageActions(ChatMessage m) {
    final bool mine = m.senderId == _me;
    if (m.sendState == ChatSendState.failed && mine) {
      unawaited(_retry(m));
      return;
    }
    if (!mine && !widget.isAdmin) return;
    showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (mine && !m.legacy)
              ListTile(
                key: const Key('chat-action-edit'),
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Edit'),
                onTap: () {
                  Navigator.pop(ctx);
                  setState(() {
                    _editing = m;
                    _sendError = null;
                    _text.text = m.body;
                    _text.selection =
                        TextSelection.collapsed(offset: m.body.length);
                  });
                },
              ),
            ListTile(
              key: const Key('chat-action-delete'),
              leading: const Icon(Icons.delete_outline),
              title: Text(mine ? 'Delete' : 'Delete (admin)'),
              onTap: () {
                Navigator.pop(ctx);
                unawaited(_confirmDelete(m));
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _retry(ChatMessage m) async {
    try {
      await protectionOf(_svc)?.retry(widget.circleId, m.id);
      if (mounted) {
        _replace(ChatMessage(
            id: m.id, seq: m.seq, circleId: m.circleId, senderId: m.senderId, senderName: m.senderName, body: m.body,
            createdAt: m.createdAt, hasImage: m.hasImage, editedAt: m.editedAt, encrypted: true, sendState: ChatSendState.sending));
      }
    } catch (e) {
      if (mounted) setState(() => _sendError = describeChatError(e).message);
    }
  }

  Future<void> _deleteLegacy() async {
    final bool? yes = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Delete old unencrypted messages?'),
        content: const Text(
            'Messages written before this circle was encrypted are still stored readable on the server. '
            'This removes all of them for everyone. New encrypted messages are not affected.'),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
              key: const Key('chat-legacy-confirm'),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    try {
      await protectionOf(_svc)?.deleteLegacyHistory(widget.circleId);
      if (!mounted) return;
      setState(() {
        _messages.removeWhere((ChatMessage x) => x.legacy);
        _ids.removeWhere((String id) => !_messages.any((ChatMessage x) => x.id == id));
        _info = ChatCircleInfo(
            encrypted: _info.encrypted, waitingForKey: _info.waitingForKey, outdatedMembers: _info.outdatedMembers);
      });
    } catch (e) {
      if (mounted) setState(() => _sendError = describeChatError(e).message);
    }
  }

  Widget _banner(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final List<Widget> rows = <Widget>[
      Row(children: <Widget>[
        Icon(Icons.lock_outline, size: 16, color: cs.primary),
        const SizedBox(width: 6),
        const Expanded(
          child: Text('Encrypted. Only people in this circle can read this.',
              key: Key('chat-encrypted-banner')),
        ),
      ]),
      if (_info.waitingForKey)
        const Padding(
          padding: EdgeInsets.only(top: 4),
          child: Text('Waiting for the circle key. Messages will appear once this phone has it.',
              key: Key('chat-waiting-key')),
        ),
      for (final String n in _info.outdatedMembers)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('$n needs to update Orbitly to read encrypted chat.', key: Key('chat-outdated-$n')),
        ),
      if (_info.hasLegacyHistory)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(children: <Widget>[
            const Expanded(child: Text('Older messages were sent before encryption and are marked.', key: Key('chat-legacy-note'))),
            if (widget.isAdmin)
              TextButton(
                key: const Key('chat-legacy-delete'),
                onPressed: _deleteLegacy,
                child: const Text('Delete them'),
              ),
          ]),
        ),
    ];
    return Material(
      color: cs.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: AppSpace.xs),
        child: DefaultTextStyle.merge(
          style: AppType.secondary,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows),
        ),
      ),
    );
  }

  Future<void> _confirmDelete(ChatMessage m) async {
    final bool? yes = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Delete message?'),
        content: const Text('It is removed for everyone in this circle.'),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              key: const Key('chat-delete-confirm'),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    try {
      await _svc.delete(widget.circleId, m.id);
      if (mounted) _remove(m.id);
    } catch (e) {
      if (mounted) setState(() => _sendError = describeChatError(e).message);
    }
  }

  Future<Uint8List?> _pick(ImageSource source) async {
    if (widget.picker != null) return widget.picker!(source);
    // image_picker downsizes to ~1600px and re-encodes as JPEG (which also
    // drops EXIF/GPS); the server re-encodes again regardless.
    final XFile? f = await ImagePicker().pickImage(
      source: source,
      maxWidth: 1600,
      maxHeight: 1600,
      imageQuality: 85,
      requestFullMetadata: false,
    );
    if (f == null) return null;
    return f.readAsBytes();
  }

  Future<void> _sendPhoto(ImageSource source) async {
    if (_sending) return;
    try {
      final Uint8List? bytes = await _pick(source);
      if (bytes == null || bytes.isEmpty || !mounted) return;
      if (bytes.length > 5 * 1024 * 1024) {
        setState(() => _sendError = 'That photo is too large (max 5 MB).');
        return;
      }
      setState(() {
        _sending = true;
        _sendError = null;
      });
      final ChatMessage sent = await _svc.sendPhoto(widget.circleId, bytes);
      if (!mounted) return;
      _photos[sent.id] = Future<Uint8List>.value(bytes);
      setState(() {
        _sending = false;
        _addAll(<ChatMessage>[sent]);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _sendError = describeChatError(e).message;
      });
    }
  }

  void _attachMenu() {
    showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              key: const Key('chat-attach-gallery'),
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () {
                Navigator.pop(ctx);
                unawaited(_sendPhoto(ImageSource.gallery));
              },
            ),
            ListTile(
              key: const Key('chat-attach-camera'),
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo'),
              onTap: () {
                Navigator.pop(ctx);
                unawaited(_sendPhoto(ImageSource.camera));
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<Uint8List> _photoBytes(String id) => _photos.putIfAbsent(
      id,
      () => _svc.photo(widget.circleId, id).catchError((Object e) {
            _photos.remove(id);
            throw e;
          }));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.circleName)),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            if (_info.encrypted) _banner(context),
            Expanded(child: _body()),
            if (_sendError != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpace.lg,
                  vertical: AppSpace.xs,
                ),
                child: Text(
                  _sendError!,
                  key: const Key('chat-send-error'),
                  style: AppType.secondary
                      .copyWith(color: Theme.of(context).colorScheme.error),
                ),
              ),
            _composer(context),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return DsErrorState(message: _error!, onRetry: _load);
    }
    if (_messages.isEmpty) {
      return const DsEmptyState(
        icon: Icons.chat_bubble_outline,
        title: 'No messages yet',
        message: 'Say hello to your circle.',
      );
    }
    return ListView.builder(
      key: const Key('chat-list'),
      controller: _scroll,
      reverse: true,
      padding: const EdgeInsets.all(AppSpace.md),
      itemCount: _messages.length,
      itemBuilder: (BuildContext context, int i) {
        final ChatMessage m = _messages[i];
        final ChatMessage? older = i + 1 < _messages.length ? _messages[i + 1] : null;
        // Older neighbour (next index) decides grouping and the day header.
        final bool sameAsOlder = older != null &&
            older.senderId == m.senderId &&
            _sameDay(older.createdAt, m.createdAt);
        final bool newDay = older == null || !_sameDay(older.createdAt, m.createdAt);
        final bool mine = m.senderId == _me;
        String? seen;
        if (mine && _me != null && identical(m, _lastMine)) {
          seen = seenByLabel(_readers.values, m, _me!);
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (newDay)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
                child: Center(
                  child: Text(
                    chatDayLabel(m.createdAt),
                    key: Key('chat-day-${m.seq}'),
                    style: AppType.secondary,
                  ),
                ),
              ),
            Padding(
              padding: EdgeInsets.only(top: sameAsOlder || newDay ? 0 : AppSpace.sm),
              child: _Bubble(
                message: m,
                mine: mine,
                showName: !sameAsOlder,
                onLongPress: () => _messageActions(m),
                onRetry: m.sendState == ChatSendState.failed ? () => _retry(m) : null,
                photo: m.hasImage ? _photoBytes(m.id) : null,
              ),
            ),
            if (seen != null)
              Padding(
                padding: const EdgeInsets.only(right: 4, top: 2),
                child: Text(
                  seen,
                  key: const Key('chat-seen'),
                  textAlign: TextAlign.right,
                  style: AppType.secondary.copyWith(fontSize: 11),
                ),
              ),
          ],
        );
      },
    );
  }

  /// The newest message sent by this user (the one that shows "Seen by").
  ChatMessage? get _lastMine {
    for (final ChatMessage m in _messages) {
      if (m.senderId == _me) return m;
    }
    return null;
  }

  Widget _composer(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final int len = _text.text.characters.length;
    final bool tooLong = len > kMaxChatLength;
    return Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
      if (_editing != null)
        ListTile(
          key: const Key('chat-editing'),
          dense: true,
          leading: const Icon(Icons.edit_outlined),
          title: const Text('Editing message'),
          trailing: IconButton(
            key: const Key('chat-editing-cancel'),
            tooltip: 'Cancel editing',
            icon: const Icon(Icons.close),
            onPressed: () => setState(() {
              _editing = null;
              _text.clear();
            }),
          ),
        ),
      _composerRow(context, cs, len, tooLong),
    ]);
  }

  Widget _composerRow(
      BuildContext context, ColorScheme cs, int len, bool tooLong) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpace.md, AppSpace.xs, AppSpace.xs, AppSpace.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          IconButton(
            key: const Key('chat-attach'),
            tooltip: 'Send a photo',
            constraints: const BoxConstraints(
                minWidth: kMinTarget, minHeight: kMinTarget),
            onPressed: _sending || _editing != null ? null : _attachMenu,
            icon: const Icon(Icons.add_photo_alternate_outlined),
          ),
          Expanded(
            child: TextField(
              key: const Key('chat-input'),
              controller: _text,
              minLines: 1,
              maxLines: 5,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                hintText: 'Message',
                errorText: tooLong
                    ? 'Too long ($len/$kMaxChatLength)'
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                ),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: AppSpace.md, vertical: AppSpace.sm),
              ),
            ),
          ),
          IconButton(
            key: const Key('chat-send'),
            tooltip: _editing != null ? 'Save edit' : 'Send',
            constraints: const BoxConstraints(
                minWidth: kMinTarget, minHeight: kMinTarget),
            onPressed: _canSend ? _send : null,
            icon: Icon(Icons.send, color: _canSend ? cs.primary : null),
          ),
        ],
      ),
    );
  }
}

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// 'Today' / 'Yesterday' / 'Mar 4' for a day separator.
String chatDayLabel(DateTime d, [DateTime? now]) {
  final DateTime n = now ?? DateTime.now();
  if (_sameDay(d, n)) return 'Today';
  if (_sameDay(d, n.subtract(const Duration(days: 1)))) return 'Yesterday';
  const List<String> mon = <String>[
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return d.year == n.year
      ? '${mon[d.month - 1]} ${d.day}'
      : '${mon[d.month - 1]} ${d.day}, ${d.year}';
}


class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.message,
    required this.mine,
    required this.showName,
    this.photo,
    this.onLongPress,
    this.onRetry,
  });

  final VoidCallback? onLongPress;
  final VoidCallback? onRetry;
  final ChatMessage message;
  final bool mine;
  final bool showName;
  final Future<Uint8List>? photo;

  static String _time(DateTime t) {
    final String h = t.hour.toString().padLeft(2, '0');
    final String m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Color bg = mine ? cs.primaryContainer : cs.surfaceContainerHighest;
    final Color fg = mine ? cs.onPrimaryContainer : cs.onSurface;
    final String who = mine ? 'You' : message.senderName;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Semantics(
        container: true,
        label: '$who, ${message.hasImage ? 'photo, ' : ''}${message.body}, '
            '${_time(message.createdAt)}${message.editedAt != null ? ', edited' : ''}',
        onLongPress: onLongPress,
        excludeSemantics: true,
        child: GestureDetector(
        onLongPress: onLongPress,
        child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        constraints:
            BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.md, vertical: AppSpace.sm),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (!mine && showName)
              Text(
                message.senderName,
                style: AppType.secondary
                    .copyWith(color: cs.primary, fontWeight: FontWeight.w600),
              ),
            if (photo != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: _PhotoThumb(photo: photo!),
              ),
            if (message.body.isNotEmpty)
              Text(message.body, style: AppType.body.copyWith(color: fg)),
            Text(
              <String>[
                _time(message.createdAt),
                if (message.editedAt != null) 'edited',
                if (message.sendState == ChatSendState.sending) message.id.startsWith('local:') ? 'waiting to send' : 'sending',
              ].join(' · '),
              key: message.sendState == ChatSendState.sending ? const Key('chat-sending') : null,
              style: AppType.secondary
                  .copyWith(color: fg.withValues(alpha: 0.7), fontSize: 11),
            ),
            if (message.legacy)
              Text('Sent before encryption',
                  key: const Key('chat-legacy-label'),
                  style: AppType.secondary.copyWith(color: fg.withValues(alpha: 0.7), fontSize: 11)),
            if (message.sendState == ChatSendState.failed)
              GestureDetector(
                key: const Key('chat-retry'),
                onTap: onRetry,
                child: Text('Not sent. Tap to try again.',
                    style: AppType.secondary
                        .copyWith(color: Theme.of(context).colorScheme.error, fontSize: 11)),
              ),
          ],
        ),
      ),
      ),
      ),
    );
  }
}

class _PhotoThumb extends StatelessWidget {
  const _PhotoThumb({required this.photo});

  final Future<Uint8List> photo;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: photo,
      builder: (BuildContext context, AsyncSnapshot<Uint8List> snap) {
        Widget child;
        if (snap.hasData) {
          child = GestureDetector(
            key: const Key('chat-photo'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => _PhotoViewer(bytes: snap.data!),
            )),
            child: Image.memory(snap.data!,
                width: 220, height: 220, fit: BoxFit.cover, cacheWidth: 660),
          );
        } else if (snap.hasError) {
          child = const Center(child: Icon(Icons.broken_image_outlined));
        } else {
          child = const Center(
              child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2)));
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: SizedBox(width: 220, height: 220, child: child),
        );
      },
    );
  }
}

class _PhotoViewer extends StatelessWidget {
  const _PhotoViewer({required this.bytes});

  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: Center(
        child: InteractiveViewer(
          maxScale: 5,
          child: Image.memory(bytes, key: const Key('chat-photo-full')),
        ),
      ),
    );
  }
}
