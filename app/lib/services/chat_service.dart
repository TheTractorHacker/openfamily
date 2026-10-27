import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/chat_message.dart';
import 'api_client.dart';

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
    return ChatException(error.message, status: error.status);
  }
  return const ChatException(
    'Can\'t reach the server. Check your connection and try again.',
  );
}

/// Chat operations used by the chat screen. Abstract so widget tests can
/// supply a fake.
abstract class ChatService {
  static ChatService instance = ApiChatService();

  Future<String> myUserId();
  Future<ChatPage> messages(String circleId, {int? before, int limit = 50});
  Future<ChatMessage> send(String circleId, String body);
  Future<void> markRead(String circleId, {int? seq});

  /// Unread counts per circle id.
  Future<Map<String, int>> unread();
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
  Future<ChatPage> messages(String circleId, {int? before, int limit = 50}) =>
      _wrap(() async {
        final dynamic raw = await ApiClient.get(
          '/circles/$circleId/chat',
          query: <String, String>{
            'limit': '$limit',
            if (before != null) 'before': '$before',
          },
        );
        final Map<String, dynamic> map = raw as Map<String, dynamic>;
        final List<ChatMessage> list = ((map['messages'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(ChatMessage.fromJson)
            .toList();
        return ChatPage(list, (map['next_before'] as num?)?.toInt());
      });

  @override
  Future<ChatMessage> send(String circleId, String body) => _wrap(() async =>
      ChatMessage.fromJson(await ApiClient.post('/circles/$circleId/chat',
          body: <String, dynamic>{'body': body}) as Map<String, dynamic>));

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

  static final StreamController<ChatMessage> _incoming =
      StreamController<ChatMessage>.broadcast();

  /// Every live message delivered to this device (including our own sends
  /// echoed by the server; consumers dedupe on [ChatMessage.id]).
  static Stream<ChatMessage> get incoming => _incoming.stream;

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
