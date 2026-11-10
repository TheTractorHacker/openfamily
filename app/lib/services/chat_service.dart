import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/chat_message.dart';
import 'api_client.dart';
import 'chat/chat_engine.dart';
import 'chat/chat_store.dart';
import 'chat/encrypted_chat_service.dart';
import 'offline/offline_cache.dart';
import 'offline/offline_errors.dart';
import 'offline/offline_queue.dart';
import 'offline/offline_sync.dart';
import 'offline/server_reachability.dart';
import 'error_copy.dart';

/// A chat failure already worded for the user.
class ChatException implements Exception {
  const ChatException(this.message, {this.status = 0});

  final String message;
  final int status;

  @override
  String toString() => 'ChatException($status): $message';
}

ChatException describeChatError(Object error) {
  if (error is ChatException) return error;
  if (error is ApiException) {
    if (error.status == 429) {
      return const ChatException(
        'You are sending messages too fast. Wait a moment.',
        status: 429,
      );
    }
    if (error.status == 0) return ChatException(describeError(error).message);
    return ChatException(error.message, status: error.status);
  }
  return ChatException(describeError(error).message);
}

/// Chat operations used by the chat screen. Abstract so widget tests can
/// supply a fake.
abstract class ChatService {
  static ChatService instance = RoutingChatService(plain: ApiChatService());

  Future<String> myUserId();
  Future<ChatPage> messages(String circleId,
      {int? before, int? after, int limit = 50});

  /// [clientId] makes a retry idempotent: the server returns the already
  /// stored message instead of creating a duplicate.
  Future<ChatMessage> send(String circleId, String body, {String? clientId});

  /// Edits the caller's own message.
  Future<ChatMessage> edit(String circleId, String messageId, String body);

  /// Deletes the caller's own message (or any message, for a circle admin).
  Future<void> delete(String circleId, String messageId);
  Future<void> markRead(String circleId, {int? seq});

  /// Posts a JPEG/PNG photo message.
  Future<ChatMessage> sendPhoto(String circleId, Uint8List bytes,
      {String contentType = 'image/jpeg'});

  /// The bytes of a photo message.
  Future<Uint8List> photo(String circleId, String messageId);

  /// Unread counts per circle id.
  Future<Map<String, int>> unread();
}

/// Extra operations of encrypted chat. A service that does not implement this
/// (plaintext chat, test fakes) behaves as before.
abstract class ChatProtection {
  /// How the chat of this circle is protected and what the screen should say
  /// about it. Plaintext chat answers "not encrypted".
  Future<ChatCircleInfo> info(String circleId);

  /// Sends a failed message again (encrypted chat).
  Future<void> retry(String circleId, String messageId);

  /// Deletes the plaintext messages written before the circle turned private
  /// (circle admins). Returns how many were removed.
  Future<int> deleteLegacyHistory(String circleId);
}

/// The protection operations of [s], or null for plaintext services and fakes.
ChatProtection? protectionOf(ChatService s) => s is ChatProtection ? s as ChatProtection : null;

/// What the chat screen shows about the protection of one circle's chat.
class ChatCircleInfo {
  const ChatCircleInfo({
    this.encrypted = false,
    this.waitingForKey = false,
    this.outdatedMembers = const <String>[],
    this.hasLegacyHistory = false,
  });

  /// New messages are sealed phone to phone.
  final bool encrypted;

  /// No circle key reached this phone yet: sending and reading wait for it.
  final bool waitingForKey;

  /// Members whose app cannot read encrypted chat yet.
  final List<String> outdatedMembers;

  /// Old plaintext messages from before encryption are still on the server.
  final bool hasLegacyHistory;
}

class ApiChatService implements ChatService {
  Future<T> _wrap<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on SessionExpiredException {
      rethrow;
    } catch (e) {
      throw describeChatError(e);
    }
  }

  @override
  Future<String> myUserId() =>
      _wrap(() async => (await ApiClient.getProfile()).id);

  @override
  Future<ChatPage> messages(String circleId,
          {int? before, int? after, int limit = 50}) =>
      _wrap(() async {
        // Only the newest page is remembered: that is what opens the chat when the server is down.
        final bool latest = before == null && after == null;
        final String cacheKey = 'chat/$circleId';
        dynamic raw;
        try {
          raw = await ApiClient.get(
            '/circles/$circleId/chat',
            query: <String, String>{
              'limit': '$limit',
              if (before != null) 'before': '$before',
              if (after != null) 'after': '$after',
            },
          );
          if (latest) unawaited(OfflineCache.instance.write(cacheKey, raw));
        } catch (e) {
          if (!latest || !isOfflineError(e)) rethrow;
          final CacheEntry? c = await OfflineCache.instance.read(cacheKey);
          if (c == null || c.data is! Map) rethrow;
          raw = c.data;
        }
        final Map<String, dynamic> map = raw as Map<String, dynamic>;
        final List<ChatMessage> list = ((map['messages'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(ChatMessage.fromJson)
            .toList();
        final List<ChatReader> readers = ((map['readers'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(ChatReader.fromJson)
            .toList();
        if (latest) {
          // Messages written while the server was out of reach and still waiting on this phone
          // (also after a restart): shown as "waiting to send" at the end of the conversation.
          for (final QueuedItem q in await OfflineQueue.instance.items(kind: QueueKind.chat)) {
            if (q.meta['circle'] != circleId) continue;
            list.add(ChatMessage(
              id: 'local:${q.id}',
              seq: 1 << 40,
              circleId: circleId,
              senderId: ChatEvents.selfUserId ?? '',
              senderName: 'You',
              body: (q.meta['text'] as String?) ?? '',
              createdAt: DateTime.fromMillisecondsSinceEpoch(q.at),
              sendState: ChatSendState.sending,
            ));
          }
        }
        return ChatPage(list, (map['next_before'] as num?)?.toInt(), readers);
      });

  /// Sends a message. When the server cannot be reached the text is saved on the
  /// phone (it is never lost) and a local "waiting to send" message is returned;
  /// it is sent in order when the server is back, once, thanks to the client id.
  @override
  Future<ChatMessage> send(String circleId, String body, {String? clientId}) =>
      _wrap(() async {
        final String id = clientId ?? 'chat-${DateTime.now().microsecondsSinceEpoch}';
        final Submitted r = await OfflineQueue.instance.submit(
          QueuedItem(
            id: id,
            kind: QueueKind.chat,
            method: 'POST',
            path: '/circles/$circleId/chat',
            body: <String, dynamic>{'body': body, 'client_id': id},
            meta: <String, dynamic>{'circle': circleId, 'text': body},
          ),
          serverKnownDown: () => ServerReachability.instance.unreachable,
        );
        if (!r.queued) return ChatMessage.fromJson(r.response as Map<String, dynamic>);
        unawaited(OfflineSync.refreshPending());
        return ChatMessage(
          id: 'local:$id',
          seq: 1 << 40,
          circleId: circleId,
          senderId: ChatEvents.selfUserId ?? '',
          senderName: 'You',
          body: body,
          createdAt: DateTime.now(),
          sendState: ChatSendState.sending,
        );
      });

  @override
  Future<ChatMessage> edit(String circleId, String messageId, String body) =>
      _wrap(() async => ChatMessage.fromJson(await ApiClient.patch(
          '/circles/$circleId/chat/$messageId',
          body: <String, dynamic>{'body': body}) as Map<String, dynamic>));

  @override
  Future<void> delete(String circleId, String messageId) =>
      _wrap(() => ApiClient.delete('/circles/$circleId/chat/$messageId'));

  @override
  Future<ChatMessage> sendPhoto(String circleId, Uint8List bytes,
          {String contentType = 'image/jpeg'}) =>
      _wrap(() async => ChatMessage.fromJson(await ApiClient.postBytes(
          '/circles/$circleId/chat/photo',
          bytes: bytes,
          contentType: contentType) as Map<String, dynamic>));

  @override
  Future<Uint8List> photo(String circleId, String messageId) => _wrap(() =>
      ApiClient.getImageBytes('/circles/$circleId/chat/$messageId/photo'));

  @override
  Future<void> markRead(String circleId, {int? seq}) => _wrap(() =>
      ApiClient.post('/circles/$circleId/chat/read',
          body: <String, dynamic>{if (seq != null) 'seq': seq}));

  @override
  Future<Map<String, int>> unread() => _wrap(() async {
        final dynamic raw = await ApiClient.get('/chat/unread');
        final Object? circles = (raw as Map<String, dynamic>)['circles'];
        if (circles is! Map) return <String, int>{};
        return <String, int>{
          for (final MapEntry<dynamic, dynamic> e in circles.entries)
            e.key.toString(): (e.value as num?)?.toInt() ?? 0,
        };
      });
}

/// Live chat state shared by the WebSocket (producer) and the screens.
class ChatEvents {
  ChatEvents._();

  static final StreamController<(String, ChatMessage)> _localDelivered =
      StreamController<(String, ChatMessage)>.broadcast();

  /// A message that was waiting on the phone reached the server: (client id, the stored message).
  /// The open chat swaps its "waiting to send" bubble for the real one.
  static Stream<(String, ChatMessage)> get localDelivered => _localDelivered.stream;

  /// Hooked to [OfflineQueue.onDelivered] by [OfflineSync.start].
  static void handleQueueDelivered(QueuedItem item, dynamic response) {
    if (item.kind != QueueKind.chat || response is! Map<String, dynamic>) return;
    _localDelivered.add((item.id, ChatMessage.fromJson(response)));
  }

  static final StreamController<ChatMessage> _incoming =
      StreamController<ChatMessage>.broadcast();

  /// Every live message delivered to this device (including our own sends
  /// echoed by the server; consumers dedupe on [ChatMessage.id]).
  static Stream<ChatMessage> get incoming => _incoming.stream;

  static final StreamController<(String, ChatReader)> _reads =
      StreamController<(String, ChatReader)>.broadcast();

  /// Read-receipt frames: (circleId, reader).
  static Stream<(String, ChatReader)> get reads => _reads.stream;

  /// Handles a `chat_read` WebSocket frame.
  static bool handleReadFrame(Map<String, dynamic> frame) {
    final String circle = frame['circle_id'] as String? ?? '';
    final ChatReader r = ChatReader.fromJson(frame);
    if (circle.isEmpty || r.userId.isEmpty) return false;
    _reads.add((circle, r));
    return true;
  }

  static final StreamController<ChatMessage> _edits =
      StreamController<ChatMessage>.broadcast();

  /// A message was edited (live `chat_edit` frame).
  static Stream<ChatMessage> get edits => _edits.stream;

  static final StreamController<(String, String)> _deletes =
      StreamController<(String, String)>.broadcast();

  /// A message was deleted: (circleId, messageId).
  static Stream<(String, String)> get deletes => _deletes.stream;

  static final StreamController<void> _reconnects =
      StreamController<void>.broadcast();

  /// Fires when the live socket (re)connects, so an open chat can fetch what
  /// it missed.
  static Stream<void> get reconnects => _reconnects.stream;
  static void notifyReconnected() => _reconnects.add(null);

  /// A change of the encrypted chat (applied locally after decrypting).
  static void handleEngineChange(ChatChange change, String authorName, String me) {
    switch (change.kind) {
      case ChatChangeKind.added:
        final StoredChat m = change.message!;
        _incoming.add(chatMessageFromStored(m, change.circleId, authorName, mine: m.author == me));
        if (m.author != me && change.circleId != viewingCircleId) unawaited(refreshUnread());
      case ChatChangeKind.delivered:
        final StoredChat m = change.message!;
        _edits.add(chatMessageFromStored(m, change.circleId, authorName, mine: m.author == me));
      case ChatChangeKind.edited:
        final StoredChat m = change.message!;
        _edits.add(chatMessageFromStored(m, change.circleId, authorName, mine: m.author == me));
      case ChatChangeKind.deleted:
        _deletes.add((change.circleId, change.key));
        unawaited(refreshUnread());
    }
  }

  static bool handleEditFrame(Map<String, dynamic> frame) {
    final Object? raw = frame['message'];
    if (raw is! Map<String, dynamic>) return false;
    final ChatMessage msg = ChatMessage.fromJson(raw);
    if (msg.id.isEmpty) return false;
    _edits.add(msg);
    return true;
  }

  static bool handleDeleteFrame(Map<String, dynamic> frame) {
    final String circle = frame['circle_id'] as String? ?? '';
    final String id = frame['id'] as String? ?? '';
    if (circle.isEmpty || id.isEmpty) return false;
    _deletes.add((circle, id));
    // Whatever was unread may have just vanished; the server knows.
    unawaited(refreshUnread());
    return true;
  }

  /// Unread messages across all circles, for the badge on the Circle tab.
  static final ValueNotifier<int> unreadTotal = ValueNotifier<int>(0);

  /// The circle whose chat screen is open, so its messages are not counted.
  static String? viewingCircleId;

  /// Our own user id, so our own messages never count as unread.
  static String? selfUserId;

  /// Handles a `chat` WebSocket frame.
  static bool handleFrame(Map<String, dynamic> frame) {
    final Object? raw = frame['message'];
    if (raw is! Map<String, dynamic>) return false;
    final ChatMessage msg = ChatMessage.fromJson(raw);
    if (msg.id.isEmpty) return false;
    if (msg.circleId != viewingCircleId && msg.senderId != selfUserId) {
      unreadTotal.value++;
    }
    _incoming.add(msg);
    return true;
  }

  /// Re-reads the server's unread counts (cross-device source of truth).
  static Future<void> refreshUnread() async {
    try {
      final Map<String, int> counts = await ChatService.instance.unread();
      unreadTotal.value = counts.values.fold(0, (int a, int b) => a + b);
    } catch (_) {
      // Keep the last known badge.
    }
  }
}
