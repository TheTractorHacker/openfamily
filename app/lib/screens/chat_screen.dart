import 'dart:async';

import 'package:flutter/material.dart';

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
  });

  final String circleId;
  final String circleName;

  /// Overrides [ChatService.instance] (tests).
  final ChatService? service;

  /// Overrides [ChatEvents.incoming] (tests).
  final Stream<ChatMessage>? incoming;

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
  String? _me;
  int? _nextBefore;
  bool _loading = true;
  bool _loadingMore = false;
  bool _sending = false;
  String? _error;
  String? _sendError;

  ChatService get _svc => widget.service ?? ChatService.instance;

  @override
  void initState() {
    super.initState();
    ChatEvents.viewingCircleId = widget.circleId;
    _sub = (widget.incoming ?? ChatEvents.incoming).listen(_onIncoming);
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
      if (!mounted) return;
      setState(() {
        _me = me;
        ChatEvents.selfUserId = me;
        _messages.clear();
        _ids.clear();
        _addAll(page.messages);
        _nextBefore = page.nextBefore;
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
    setState(() {
      _sending = true;
      _sendError = null;
    });
    try {
      final ChatMessage sent = await _svc.send(widget.circleId, body);
      if (!mounted) return;
      setState(() {
        _sending = false;
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.circleName)),
      body: SafeArea(
        child: Column(
          children: <Widget>[
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
        // Older neighbour (next index) decides whether to repeat the name.
        final bool sameAsOlder =
            i + 1 < _messages.length && _messages[i + 1].senderId == m.senderId;
        return _Bubble(message: m, mine: m.senderId == _me, showName: !sameAsOlder);
      },
    );
  }

  Widget _composer(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final int len = _text.text.characters.length;
    final bool tooLong = len > kMaxChatLength;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpace.md, AppSpace.xs, AppSpace.xs, AppSpace.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
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
            tooltip: 'Send',
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

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.message,
    required this.mine,
    required this.showName,
  });

  final ChatMessage message;
  final bool mine;
  final bool showName;

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
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        constraints:
            BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
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
            Text(message.body, style: AppType.body.copyWith(color: fg)),
            Text(
              _time(message.createdAt),
              style: AppType.secondary
                  .copyWith(color: fg.withValues(alpha: 0.7), fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}
