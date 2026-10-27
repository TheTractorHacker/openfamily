/// One family-chat message, from `GET /circles/{id}/chat` or a live `chat`
/// WebSocket frame.
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.seq,
    required this.circleId,
    required this.senderId,
    required this.senderName,
    required this.body,
    required this.createdAt,
  });

  final String id;

  /// Server-assigned, strictly increasing; the pagination and unread cursor.
  final int seq;
  final String circleId;
  final String senderId;
  final String senderName;
  final String body;
  final DateTime createdAt;

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: json['id'] as String? ?? '',
      seq: (json['seq'] as num?)?.toInt() ?? 0,
      circleId: json['circle_id'] as String? ?? '',
      senderId: json['sender_id'] as String? ?? '',
      senderName: json['sender_name'] as String? ?? '',
      body: json['body'] as String? ?? '',
      createdAt:
          DateTime.tryParse(json['created_at'] as String? ?? '')?.toLocal() ??
              DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

/// A page of messages, newest first.
class ChatPage {
  const ChatPage(this.messages, this.nextBefore);

  final List<ChatMessage> messages;

  /// Cursor for the next (older) page, or null at the start of history.
  final int? nextBefore;
}

/// Longest message the server accepts (characters).
const int kMaxChatLength = 2000;
