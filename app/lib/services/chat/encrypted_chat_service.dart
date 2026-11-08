import 'dart:async';
import 'dart:typed_data';

import '../../models/chat_message.dart';
import '../api_client.dart';
import '../chat_service.dart';
import '../e2ee/e2ee_crypto.dart';
import '../e2ee/private_channel.dart';
import '../e2ee/private_runtime.dart';
import 'chat_engine.dart';
import 'chat_store.dart';
import 'chat_wire.dart';

/// Transport for sealed attachments (opaque bytes on the server).
abstract class ChatBlobApi {
  Future<String> upload(String circleId, Uint8List sealed);
  Future<Uint8List> download(String circleId, String blobId);
}

class HttpChatBlobApi implements ChatBlobApi {
  const HttpChatBlobApi();

  @override
  Future<String> upload(String circleId, Uint8List sealed) async {
    final dynamic r = await ApiClient.postBytes('/circles/$circleId/e2ee/blobs', bytes: sealed, contentType: 'application/octet-stream');
    final Object? id = (r as Map<String, dynamic>)['id'];
    if (id is! String) throw const ChatException('The photo could not be stored.');
    return id;
  }

  @override
  Future<Uint8List> download(String circleId, String blobId) => ApiClient.getBytes('/circles/$circleId/e2ee/blobs/$blobId');
}

/// Chat of a Private circle: sealed on this phone, opened on the members' phones.
/// The server never sees text (docs/design/E2EE_CHAT.md).
class EncryptedChatService implements ChatService, ChatProtection {
  EncryptedChatService(this.runtime, {this.legacy, ChatBlobApi? blobs, DateTime Function()? now})
      : blobs = blobs ?? const HttpChatBlobApi(),
        _now = now ?? DateTime.now;

  final PrivateRuntime runtime;

  /// Plaintext service for history written before the circle turned private.
  final ChatService? legacy;
  final ChatBlobApi blobs;
  final DateTime Function() _now;

  final Map<String, Future<Uint8List>> _photoCache = <String, Future<Uint8List>>{};

  ChatStore get _store => runtime.chatStore;

  static const String _waiting = 'Waiting for the circle key. Open Orbitly on another phone of this circle, then try again.';

  Future<String> _me() async {
    final String? me = await runtime.myUserId();
    if (me == null) throw const ChatException(_waiting);
    return me;
  }

  ChatException _sealError(ItemRejected e) => e.reason == ItemRejection.malformed
      ? const ChatException('That message is too long to send. Shorten it.')
      : const ChatException(_waiting);

  @override
  Future<String> myUserId() => _me();

  Future<String> _nameOf(String circle, String user) async {
    for (final ChatMember m in await runtime.chat.directory.members(circle)) {
      if (m.userId == user) return m.name.isEmpty ? 'Someone' : m.name;
    }
    return 'Someone';
  }

  Future<ChatMessage> _toMessage(String circle, StoredChat m, String me) async =>
      chatMessageFromStored(m, circle, await _nameOf(circle, m.author), mine: m.author == me);

  /// Pending messages: the sealed item left the upload queue = sent, and the
  /// echo (the relay returning it) marks it delivered. No echo after ten
  /// minutes although it left the queue = failed, offer a retry.
  Future<void> _reconcilePending(String circle, String me) async {
    final List<StoredChat> pend = (await _store.all(circle)).where((StoredChat m) => m.author == me && m.seq >= ChatStore.pendingBase).toList();
    if (pend.isEmpty) return;
    final Set<String> queued = <String>{for (final WireItem i in await runtime.queue.peek()) '${i.deviceId}/${i.seq}'};
    for (final StoredChat m in pend) {
      final bool stillQueued = m.queued.isNotEmpty && queued.contains(m.queued);
      final Duration age = _now().difference(DateTime.fromMillisecondsSinceEpoch(m.tsMs));
      if (stillQueued) {
        if (m.state != ChatSendState.sending) await _store.setState(circle, m.key, ChatSendState.sending, queued: m.queued);
      } else if (age > const Duration(minutes: 10)) {
        if (m.state != ChatSendState.failed) await _store.setState(circle, m.key, ChatSendState.failed);
      } else if (m.state == ChatSendState.failed) {
        await _store.setState(circle, m.key, ChatSendState.sending, queued: m.queued);
      }
    }
  }

  @override
  Future<ChatPage> messages(String circleId, {int? before, int? after, int limit = 50}) async {
    final String me = await _me();
    if (before != null && before < 0) {
      // A cursor into the plaintext history from before encryption.
      return _legacyPage(circleId, before: -before, limit: limit, remaining: limit);
    }
    await _reconcilePending(circleId, me);
    final ({List<StoredChat> items, int? nextBefore}) p = await _store.page(circleId, before: before, after: after, limit: limit);
    final List<ChatMessage> out = <ChatMessage>[for (final StoredChat m in p.items) await _toMessage(circleId, m, me)];
    int? next = p.nextBefore;
    if (next == null && after == null && out.length < limit) {
      final ChatPage old = await _legacyPage(circleId, limit: limit - out.length, remaining: limit - out.length);
      out.addAll(old.messages);
      next = old.nextBefore;
    }
    return ChatPage(out, next);
  }

  Future<ChatPage> _legacyPage(String circleId, {int? before, required int limit, required int remaining}) async {
    final ChatService? l = legacy;
    if (l == null) return const ChatPage(<ChatMessage>[], null);
    try {
      final ChatPage p = await l.messages(circleId, before: before, limit: limit);
      return ChatPage(<ChatMessage>[for (final ChatMessage m in p.messages) m.asLegacy()], p.nextBefore == null ? null : -p.nextBefore!);
    } catch (_) {
      return const ChatPage(<ChatMessage>[], null);
    }
  }

  Future<ChatMessage> _queueMessage(String circleId, String me, String id, String text, ChatAttachment? att) async {
    final DateTime at = _now().toUtc();
    final ({WireItem item, String userId}) q;
    try {
      q = await runtime.queueSealed(circleId, ChannelPurpose.chat, ChatWire.message(id, text, attachment: att), at: at);
    } on ItemRejected catch (e) {
      throw _sealError(e);
    }
    final StoredChat m = await _store.addPending(
      circleId,
      StoredChat(
        author: me, id: id, text: text, tsMs: at.millisecondsSinceEpoch, seq: 0, attachment: att,
        state: ChatSendState.sending, queued: '${q.item.deviceId}/${q.item.seq}',
      ),
    );
    unawaited(runtime.flush().then((_) => _reconcilePending(circleId, me)).catchError((Object _) => 0));
    return _toMessage(circleId, m, me);
  }

  @override
  Future<ChatMessage> send(String circleId, String body, {String? clientId}) async {
    final String me = await _me();
    final String text = body.trim();
    if (text.isEmpty) throw const ChatException('Write a message first.');
    if (text.runes.length > kChatMaxText) throw const ChatException('That message is too long (max 2000 characters).');
    String id = clientId ?? E2ee.newUuid();
    if (!ChatWire.validId(id)) id = E2ee.newUuid();
    final StoredChat? existing = await _store.find(circleId, '$me:$id');
    if (existing != null) return _toMessage(circleId, existing, me); // a retry of the same send: idempotent
    return _queueMessage(circleId, me, id, text, null);
  }

  (String author, String id) _split(String key) {
    final int i = key.indexOf(':');
    if (i <= 0) throw const ChatException('Message not found.');
    return (key.substring(0, i), key.substring(i + 1));
  }

  @override
  Future<ChatMessage> edit(String circleId, String messageId, String body) async {
    final String me = await _me();
    final (String author, String id) = _split(messageId);
    if (author != me) throw const ChatException('You can only edit your own messages.');
    final String text = body.trim();
    if (text.runes.length > kChatMaxText) throw const ChatException('That message is too long (max 2000 characters).');
    final StoredChat? cur = await _store.find(circleId, messageId);
    if (cur == null) throw const ChatException('Message not found.');
    if (text.isEmpty && cur.attachment == null) throw const ChatException('Write a message first.');
    final DateTime at = _now().toUtc();
    final ({WireItem item, String userId}) q;
    try {
      q = await runtime.queueSealed(circleId, ChannelPurpose.chat, ChatWire.edit(id, text), at: at);
    } on ItemRejected catch (e) {
      throw _sealError(e);
    }
    await _store.applyEdit(circleId, me, ChatEvent(kind: ChatEventKind.edit, id: id, text: text),
        tsMs: at.millisecondsSinceEpoch, itemSeq: q.item.seq);
    unawaited(runtime.flush().catchError((Object _) => 0));
    return _toMessage(circleId, (await _store.find(circleId, messageId))!, me);
  }

  @override
  Future<void> delete(String circleId, String messageId) async {
    if (!messageId.contains(':')) {
      // A plaintext message from before encryption.
      final ChatService? l = legacy;
      if (l == null) throw const ChatException('Message not found.');
      return l.delete(circleId, messageId);
    }
    final String me = await _me();
    final (String author, String id) = _split(messageId);
    // Whether an admin may delete someone else's message is decided by every
    // receiver from the signed member roles; refuse early here too.
    if (author != me) {
      final bool admin = (await runtime.chat.directory.members(circleId)).any((ChatMember m) => m.userId == me && m.isAdmin);
      if (!admin) throw const ChatException('Only a circle admin can delete other people\'s messages.');
    }
    final DateTime at = _now().toUtc();
    try {
      await runtime.queueSealed(circleId, ChannelPurpose.chat, ChatWire.delete(id, author), at: at);
    } on ItemRejected catch (e) {
      throw _sealError(e);
    }
    await _store.applyDelete(circleId, author, id, tsMs: at.millisecondsSinceEpoch);
    unawaited(runtime.flush().catchError((Object _) => 0));
  }

  @override
  Future<void> markRead(String circleId, {int? seq}) async {
    // Old plaintext history (from before encryption) has its own server read marker.
    try {
      await legacy?.markRead(circleId);
    } catch (_) {}
    final int newest = seq ?? await _store.newestCursor(circleId);
    if (newest <= 0) return;
    await _store.markRead(circleId, newest);
    // The server keeps only an item-id cursor (metadata) for its own badge.
    try {
      await ApiClient.post('/circles/$circleId/chat/read', body: <String, dynamic>{'item_id': newest});
    } catch (_) {}
  }

  @override
  Future<ChatMessage> sendPhoto(String circleId, Uint8List bytes, {String contentType = 'image/jpeg'}) async {
    final String me = await _me();
    if (bytes.isEmpty || bytes.length > 5 * 1024 * 1024) throw const ChatException('That photo is too large (max 5 MB).');
    final String mime = (bytes.length > 3 && bytes[0] == 0x89 && bytes[1] == 0x50) ? 'image/png' : 'image/jpeg';
    final Uint8List key = ChatBlobCrypto.newKey();
    final Uint8List sealed = await ChatBlobCrypto.encrypt(bytes, key, circleId);
    final String blob;
    try {
      blob = await blobs.upload(circleId, sealed);
    } catch (e) {
      throw describeChatError(e);
    }
    final ChatAttachment att = ChatAttachment(blobId: blob, key: E2ee.b64(key), mime: mime, size: sealed.length);
    final String id = E2ee.newUuid();
    _photoCache['$me:$id'] = Future<Uint8List>.value(bytes);
    return _queueMessage(circleId, me, id, '', att);
  }

  @override
  Future<Uint8List> photo(String circleId, String messageId) {
    if (!messageId.contains(':')) {
      final ChatService? l = legacy;
      if (l == null) throw const ChatException('Photo not found.');
      return l.photo(circleId, messageId);
    }
    return _photoCache.putIfAbsent(messageId, () async {
      try {
        final StoredChat? m = await _store.find(circleId, messageId);
        final ChatAttachment? a = m?.attachment;
        if (a == null) throw const ChatException('Photo not found.');
        final Uint8List sealed = await blobs.download(circleId, a.blobId);
        return await ChatBlobCrypto.decrypt(sealed, E2ee.unb64(a.key), circleId);
      } catch (e) {
        _photoCache.remove(messageId);
        if (e is E2eeAuthException || e is E2eeFormatException) {
          throw const ChatException('This photo could not be opened.');
        }
        throw describeChatError(e);
      }
    });
  }

  @override
  Future<Map<String, int>> unread() async {
    final Set<String> priv = await runtime.privateCircles();
    final String? me = await runtime.myUserId();
    final Map<String, int> out = <String, int>{};
    for (final String c in priv) {
      out[c] = me == null ? 0 : await _store.unread(c, me);
    }
    return out;
  }

  @override
  Future<ChatCircleInfo> info(String circleId) async {
    final bool waiting = await runtime.keys.latestEpoch(circleId) < 1;
    final String? me = await runtime.myUserId();
    final List<ChatMember> members = await runtime.chat.directory.members(circleId, refresh: true);
    final List<String> old = <String>[
      for (final ChatMember m in members)
        if (!m.canReadChat && m.userId != me) (m.name.isEmpty ? 'Someone' : m.name),
    ];
    bool hasLegacy = false;
    final ChatService? l = legacy;
    if (l != null) {
      try {
        hasLegacy = (await l.messages(circleId, limit: 1)).messages.isNotEmpty;
      } catch (_) {}
    }
    return ChatCircleInfo(encrypted: true, waitingForKey: waiting, outdatedMembers: old, hasLegacyHistory: hasLegacy);
  }

  @override
  Future<void> retry(String circleId, String messageId) async {
    final String me = await _me();
    final StoredChat? m = await _store.find(circleId, messageId);
    if (m == null || m.author != me) return;
    final DateTime at = _now().toUtc();
    try {
      final ({WireItem item, String userId}) q = await runtime.queueSealed(
          circleId, ChannelPurpose.chat, ChatWire.message(m.id, m.text, attachment: m.attachment), at: at);
      await _store.setState(circleId, m.key, ChatSendState.sending, queued: '${q.item.deviceId}/${q.item.seq}');
    } on ItemRejected catch (e) {
      throw _sealError(e);
    }
    unawaited(runtime.flush().then((_) => _reconcilePending(circleId, me)).catchError((Object _) => 0));
  }

  @override
  Future<int> deleteLegacyHistory(String circleId) async {
    try {
      final dynamic r = await ApiClient.delete('/circles/$circleId/chat/history');
      return r is Map<String, dynamic> ? (r['deleted'] as num?)?.toInt() ?? 0 : 0;
    } catch (e) {
      throw describeChatError(e);
    }
  }
}

/// Picks the encrypted or the plaintext implementation per circle: Private
/// circles chat sealed, every other circle is unchanged.
class RoutingChatService implements ChatService, ChatProtection {
  RoutingChatService({required this.plain, EncryptedChatService? encrypted, PrivateRuntime Function()? runtime})
      : _runtime = runtime ?? (() => PrivateRuntime.instance),
        _encrypted = encrypted;

  final ChatService plain;
  final PrivateRuntime Function() _runtime;
  EncryptedChatService? _encrypted;

  Future<ChatService> _for(String circleId) async {
    try {
      final PrivateRuntime rt = _runtime();
      if ((await rt.privateCircles()).contains(circleId)) {
        return _encrypted ??= EncryptedChatService(rt, legacy: plain);
      }
    } catch (_) {
      // No private runtime (tests, first start): plaintext behaviour.
    }
    return plain;
  }

  @override
  Future<String> myUserId() async {
    try {
      final String? me = await _runtime().myUserId();
      if (me != null) return me;
    } catch (_) {}
    return plain.myUserId();
  }

  @override
  Future<ChatPage> messages(String circleId, {int? before, int? after, int limit = 50}) async =>
      (await _for(circleId)).messages(circleId, before: before, after: after, limit: limit);

  @override
  Future<ChatMessage> send(String circleId, String body, {String? clientId}) async =>
      (await _for(circleId)).send(circleId, body, clientId: clientId);

  @override
  Future<ChatMessage> edit(String circleId, String messageId, String body) async =>
      (await _for(circleId)).edit(circleId, messageId, body);

  @override
  Future<void> delete(String circleId, String messageId) async => (await _for(circleId)).delete(circleId, messageId);

  @override
  Future<void> markRead(String circleId, {int? seq}) async => (await _for(circleId)).markRead(circleId, seq: seq);

  @override
  Future<ChatMessage> sendPhoto(String circleId, Uint8List bytes, {String contentType = 'image/jpeg'}) async =>
      (await _for(circleId)).sendPhoto(circleId, bytes, contentType: contentType);

  @override
  Future<Uint8List> photo(String circleId, String messageId) async => (await _for(circleId)).photo(circleId, messageId);

  @override
  Future<Map<String, int>> unread() async {
    Map<String, int> counts = <String, int>{};
    try {
      counts = await plain.unread();
    } catch (_) {}
    try {
      final PrivateRuntime rt = _runtime();
      if ((await rt.privateCircles()).isNotEmpty) {
        // The server's count for a Private circle is a metadata upper bound (it
        // cannot tell a message from an edit); the phone knows the exact number.
        counts.addAll(await (_encrypted ??= EncryptedChatService(rt, legacy: plain)).unread());
      }
    } catch (_) {}
    return counts;
  }

  @override
  Future<ChatCircleInfo> info(String circleId) async => (protectionOf(await _for(circleId)))?.info(circleId) ?? const ChatCircleInfo();

  @override
  Future<void> retry(String circleId, String messageId) async => protectionOf(await _for(circleId))?.retry(circleId, messageId);

  @override
  Future<int> deleteLegacyHistory(String circleId) async => (protectionOf(await _for(circleId))?.deleteLegacyHistory(circleId)) ?? Future<int>.value(0);
}
