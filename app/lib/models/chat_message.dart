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
    this.hasImage = false,
  });

  final String id;

  /// Server-assigned, strictly increasing; the pagination and unread cursor.
  final int seq;
  final String circleId;
  final String senderId;
  final String senderName;
  final String body;
  final DateTime createdAt;

  /// True for a photo message (fetch the bytes via the chat photo endpoint).
  final bool hasImage;

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: json['id'] as String? ?? '',
      seq: (json['seq'] as num?)?.toInt() ?? 0,
      circleId: json['circle_id'] as String? ?? '',
      senderId: json['sender_id'] as String? ?? '',
      senderName: json['sender_name'] as String? ?? '',
      body: json['body'] as String? ?? '',
      hasImage: json['has_image'] == true,
      createdAt:
          DateTime.tryParse(json['created_at'] as String? ?? '')?.toLocal() ??
              DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

/// How far one member has read in a circle.
class ChatReader {
  const ChatReader({
    required this.userId,
    required this.name,
    required this.lastSeq,
  });

  final String userId;
  final String name;
  final int lastSeq;

  factory ChatReader.fromJson(Map<String, dynamic> json) => ChatReader(
        userId: json['user_id'] as String? ?? '',
        name: (json['name'] ?? json['user_name']) as String? ?? '',
        lastSeq: ((json['last_seq'] ?? json['seq']) as num?)?.toInt() ?? 0,
      );
}

/// "Seen by Sam, Ava" for the sender's last message; long lists are capped.
/// Returns null when nobody has seen it.
String? seenByLabel(Iterable<ChatReader> readers, ChatMessage last, String me,
    {int cap = 3}) {
  final List<String> names = <String>[
    for (final ChatReader r in readers)
      if (r.userId != me && r.lastSeq >= last.seq) r.name.isEmpty ? 'Someone' : r.name,
  ]..sort();
  if (names.isEmpty) return null;
  if (names.length <= cap) return 'Seen by ${names.join(', ')}';
  return 'Seen by ${names.take(cap).join(', ')} +${names.length - cap}';
}

/// A page of messages, newest first.
class ChatPage {
  const ChatPage(this.messages, this.nextBefore,
      [this.readers = const <ChatReader>[]]);

  /// Every member's read marker (for "Seen by").
  final List<ChatReader> readers;

  final List<ChatMessage> messages;

  /// Cursor for the next (older) page, or null at the start of history.
  final int? nextBefore;
}

/// Longest message the server accepts (characters).
const int kMaxChatLength = 2000;
