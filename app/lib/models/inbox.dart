/// Received check-ins and live shares, merged into one feed (the "Activity"
/// inbox). Check-ins come from `GET /checkins`, shares from the `incoming`
/// side of `GET /live-shares` (docs/checkin-sharing.md).
enum InboxKind { checkIn, liveShare }

class InboxItem {
  const InboxItem({
    required this.id,
    required this.kind,
    required this.userId,
    required this.name,
    required this.at,
    this.note = '',
    this.lat,
    this.lon,
    this.expiresAt,
    this.paused = false,
  });

  /// Check-in id or live-share id.
  final String id;
  final InboxKind kind;

  /// The sender (check-in) or the person sharing with you (live share).
  final String userId;
  final String name;
  final DateTime at;
  final String note;
  final double? lat;
  final double? lon;
  final DateTime? expiresAt;

  /// A paused sharer's position is withheld by the server.
  final bool paused;

  bool get hasPin => lat != null && lon != null;

  bool expiredAt(DateTime now) => expiresAt != null && !expiresAt!.isAfter(now);

  factory InboxItem.fromCheckInJson(Map<String, dynamic> j) => InboxItem(
        id: j['id'] as String? ?? '',
        kind: InboxKind.checkIn,
        userId: j['user_id'] as String? ?? '',
        name: _name(j['name']),
        at: _time(j['created_at']) ?? DateTime.fromMillisecondsSinceEpoch(0),
        note: (j['note'] as String?)?.trim() ?? '',
        lat: (j['lat'] as num?)?.toDouble(),
        lon: (j['lon'] as num?)?.toDouble(),
        expiresAt: _time(j['expires_at']),
      );

  factory InboxItem.fromLiveShareJson(Map<String, dynamic> j) => InboxItem(
        id: j['id'] as String? ?? '',
        kind: InboxKind.liveShare,
        userId: j['user_id'] as String? ?? '',
        name: _name(j['name']),
        at: _time(j['created_at']) ?? DateTime.fromMillisecondsSinceEpoch(0),
        lat: (j['lat'] as num?)?.toDouble(),
        lon: (j['lon'] as num?)?.toDouble(),
        expiresAt: _time(j['expires_at']),
        paused: j['paused'] == true,
      );

  /// "Sam checked in: At school", "Sam is sharing their live location".
  String get title {
    switch (kind) {
      case InboxKind.checkIn:
        return note.isEmpty ? '$name checked in' : '$name checked in: $note';
      case InboxKind.liveShare:
        return '$name is sharing their live location';
    }
  }

  static String _name(Object? v) =>
      v is String && v.trim().isNotEmpty ? v.trim() : 'A family member';

  static DateTime? _time(Object? v) =>
      v is String ? DateTime.tryParse(v)?.toLocal() : null;
}

/// Newest first; ended live shares are dropped.
List<InboxItem> mergeInbox(
  Iterable<InboxItem> checkIns,
  Iterable<InboxItem> shares,
  DateTime now,
) {
  final List<InboxItem> all = <InboxItem>[
    ...checkIns,
    ...shares.where((InboxItem s) => !s.expiredAt(now)),
  ]..sort((InboxItem a, InboxItem b) => b.at.compareTo(a.at));
  return all;
}
