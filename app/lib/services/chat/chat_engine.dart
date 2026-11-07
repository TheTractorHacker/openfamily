import 'dart:async';

import '../../models/chat_message.dart';
import '../e2ee/e2ee_api.dart';
import '../e2ee/e2ee_crypto.dart';
import '../e2ee/e2ee_models.dart';
import '../e2ee/private_channel.dart';
import 'chat_store.dart';
import 'chat_wire.dart';

/// A circle member as the chat needs to know them.
class ChatMember {
  const ChatMember({required this.userId, required this.name, required this.isAdmin, required this.canReadChat});
  final String userId;
  final String name;
  final bool isAdmin;

  /// False when none of the member's active phones declared `chat2`.
  final bool canReadChat;
}

/// Who is in the circle (from the circle's key state: roles, names, phones).
abstract class ChatDirectory {
  /// [refresh] bypasses the cache.
  Future<List<ChatMember>> members(String circleId, {bool refresh = false});
}

class StateChatDirectory implements ChatDirectory {
  StateChatDirectory(this.api, {this.ttl = const Duration(minutes: 2), DateTime Function()? now}) : _now = now ?? DateTime.now;
  final E2eeApi api;
  final Duration ttl;
  final DateTime Function() _now;
  final Map<String, ({DateTime at, List<ChatMember> members})> _cache = <String, ({DateTime at, List<ChatMember> members})>{};

  @override
  Future<List<ChatMember>> members(String circleId, {bool refresh = false}) async {
    final ({DateTime at, List<ChatMember> members})? c = _cache[circleId];
    if (c != null && !(refresh && _now().difference(c.at) > const Duration(seconds: 20)) && _now().difference(c.at) < ttl) {
      return c.members;
    }
    try {
      final CircleE2eeState st = await api.circleState(circleId);
      final List<ChatMember> l = <ChatMember>[
        for (final CircleE2eeMember m in st.members)
          ChatMember(
            userId: m.userId,
            name: m.name,
            isAdmin: m.role == 'admin',
            canReadChat: m.devices.any((DeviceKey d) => d.isActive && d.kind == 'device' && d.supportsChat),
          ),
      ];
      _cache[circleId] = (at: _now(), members: l);
      return l;
    } catch (_) {
      return c?.members ?? const <ChatMember>[];
    }
  }
}

/// Applies verified `chat` items to the local [ChatStore]. All authorization
/// that the server cannot do (it cannot read chat) happens here.
class ChatEngine {
  ChatEngine({required this.store, required this.directory, DateTime Function()? now}) : _now = now ?? DateTime.now;

  final ChatStore store;
  final ChatDirectory directory;
  final DateTime Function() _now;

  /// Called after a change with (change, author name, my user id).
  void Function(ChatChange change, String authorName, String me)? onChange;

  /// Local notification (title, body). Text is shown only here, after decrypting.
  Future<void> Function(String title, String body)? notify;

  /// True while the chat of [circleId] is on screen (no notification then).
  bool Function(String circleId)? isViewing;

  /// Items refused since start (diagnostics, never content).
  int ignored = 0;

  Future<bool> _mayDelete(String circle, String signer, String author) async {
    if (signer == author) return true;
    for (final bool refresh in <bool>[false, true]) {
      for (final ChatMember m in await directory.members(circle, refresh: refresh)) {
        if (m.userId == signer && m.isAdmin) return true;
      }
    }
    return false;
  }

  Future<String> _name(String circle, String user) async {
    for (final ChatMember m in await directory.members(circle)) {
      if (m.userId == user) return m.name.isEmpty ? 'Someone' : m.name;
    }
    return 'Someone';
  }

  /// Applies [r]. [me] is this account's user id.
  Future<ChatChange?> apply(ReceivedItem r, {required String me}) async {
    // Chat lives on the phone key line only; a server-line chat item is refused
    // even if a hostile relay produced one.
    if (r.purpose != ChannelPurpose.chat || r.line != E2ee.linePhone) {
      ignored++;
      return null;
    }
    final ChatEvent? e = ChatWire.parse(r.body);
    if (e == null) {
      ignored++;
      return null;
    }
    final int tsMs = r.ts.millisecondsSinceEpoch;
    final int cursor = r.cursor ?? 0;
    ChatChange? change;
    switch (e.kind) {
      case ChatEventKind.message:
        change = await store.applyMessage(r.circleId, r.userId, e, tsMs: tsMs, cursor: cursor);
      case ChatEventKind.edit:
        change = await store.applyEdit(r.circleId, r.userId, e, tsMs: tsMs, itemSeq: r.seq);
      case ChatEventKind.delete:
        if (!await _mayDelete(r.circleId, r.userId, e.author!)) {
          ignored++;
          return null;
        }
        change = await store.applyDelete(r.circleId, e.author!, e.id, tsMs: tsMs);
    }
    if (change == null) return null;
    final String name = await _name(r.circleId, r.userId);
    onChange?.call(change, change.message == null ? '' : await _name(r.circleId, change.message!.author), me);
    if (change.kind == ChatChangeKind.added && r.userId != me && _now().difference(r.ts) < const Duration(minutes: 30)) {
      if (!(isViewing?.call(r.circleId) ?? false)) {
        final String text = e.text.isEmpty ? 'sent a photo' : e.text;
        await notify?.call(name, text);
      }
    }
    return change;
  }
}

/// The screen model of one stored message.
ChatMessage chatMessageFromStored(StoredChat m, String circleId, String authorName, {bool mine = false}) => ChatMessage(
      id: m.key,
      seq: m.seq,
      circleId: circleId,
      senderId: m.author,
      senderName: mine ? 'You' : authorName,
      body: m.text,
      hasImage: m.attachment != null,
      createdAt: DateTime.fromMillisecondsSinceEpoch(m.tsMs),
      editedAt: m.editedMs == null ? null : DateTime.fromMillisecondsSinceEpoch(m.editedMs!),
      sendState: m.state,
      encrypted: true,
    );
