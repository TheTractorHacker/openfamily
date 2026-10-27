import 'api_client.dart';

/// Whether the caller's location sharing is paused, and until when.
class SharingPause {
  const SharingPause({required this.paused, this.until});

  final bool paused;
  final DateTime? until;

  /// A pause whose end has passed is not a pause; the server enforces this
  /// too, this only keeps a stale cached value from being shown.
  bool activeAt(DateTime now) =>
      paused && (until == null || until!.isAfter(now));

  factory SharingPause.fromJson(Map<String, dynamic> json) {
    final Object? until = json['paused_until'];
    return SharingPause(
      paused: json['paused'] == true,
      until: until is String ? DateTime.tryParse(until)?.toLocal() : null,
    );
  }
}

/// One live-location share (either direction).
class LiveShare {
  const LiveShare({
    required this.id,
    required this.userId,
    required this.name,
    required this.expiresAt,
    this.paused = false,
    this.lat,
    this.lon,
  });

  final String id;

  /// The other party: the viewer of an outgoing share, the sharer of an
  /// incoming one.
  final String userId;
  final String name;
  final DateTime expiresAt;
  final bool paused;
  final double? lat;
  final double? lon;

  bool expiredAt(DateTime now) => !expiresAt.isAfter(now);

  factory LiveShare.fromJson(Map<String, dynamic> json) => LiveShare(
        id: json['id'] as String,
        userId: json['user_id'] as String,
        name: (json['name'] as String?) ?? '',
        expiresAt: DateTime.parse(json['expires_at'] as String).toLocal(),
        paused: json['paused'] == true,
        lat: (json['lat'] as num?)?.toDouble(),
        lon: (json['lon'] as num?)?.toDouble(),
      );
}

class LiveShares {
  const LiveShares({this.outgoing = const <LiveShare>[], this.incoming = const <LiveShare>[]});

  final List<LiveShare> outgoing;
  final List<LiveShare> incoming;

  factory LiveShares.fromJson(Map<String, dynamic> json) {
    List<LiveShare> parse(Object? v) => v is List
        ? <LiveShare>[
            for (final Object? e in v)
              if (e is Map<String, dynamic>) LiveShare.fromJson(e),
          ]
        : const <LiveShare>[];
    return LiveShares(
      outgoing: parse(json['outgoing']),
      incoming: parse(json['incoming']),
    );
  }

  /// Drops shares that ended while the list was on screen.
  LiveShares withoutExpired(DateTime now) => LiveShares(
        outgoing: outgoing.where((LiveShare s) => !s.expiredAt(now)).toList(),
        incoming: incoming.where((LiveShare s) => !s.expiredAt(now)).toList(),
      );
}

/// One active "anyone with the link" share. The secret URL is only known to
/// the response of [SharingService.createShareLink]; later listings carry no
/// token, so a lost link is stopped and re-created rather than recovered.
class ShareLink {
  const ShareLink({
    required this.id,
    required this.expiresAt,
    this.label = '',
    this.url,
  });

  final String id;
  final DateTime expiresAt;
  final String label;

  /// Present only on the freshly created link.
  final String? url;

  bool expiredAt(DateTime now) => !expiresAt.isAfter(now);

  factory ShareLink.fromJson(Map<String, dynamic> json) => ShareLink(
        id: json['id'] as String,
        expiresAt: DateTime.parse(json['expires_at'] as String).toLocal(),
        label: (json['label'] as String?) ?? '',
        url: json['url'] as String?,
      );
}

/// Longest a share link may live (the server enforces the same cap).
const int kMaxShareLinkMinutes = 72 * 60;

/// Local 7:00 the next calendar day: the "until tomorrow" pause end.
DateTime pauseUntilTomorrow(DateTime now) {
  final DateTime n = now.toLocal();
  return DateTime(n.year, n.month, n.day + 1, 7);
}

/// "2 h 5 min left", "45 min left", "less than a minute left".
String formatTimeLeft(Duration d) {
  if (d.inSeconds <= 0) return 'ended';
  if (d.inMinutes < 1) return 'less than a minute left';
  final int h = d.inHours;
  final int m = d.inMinutes % 60;
  if (h >= 24) return '${d.inDays} d ${h % 24} h left';
  if (h > 0) return m == 0 ? '$h h left' : '$h h $m min left';
  return '$m min left';
}

/// Thin wrapper over the check-in / pause / live-share endpoints
/// (docs/checkin-sharing.md). Screens take one so tests can fake it.
class SharingService {
  const SharingService();

  Future<SharingPause> pauseStatus() async =>
      SharingPause.fromJson(_map(await ApiClient.get('/sharing/pause')));

  Future<SharingPause> pause({int? minutes, DateTime? until}) async {
    assert((minutes == null) != (until == null));
    final dynamic r = await ApiClient.putJson('/sharing/pause',
        body: <String, dynamic>{
          if (minutes != null) 'minutes': minutes,
          if (until != null) 'until': until.toUtc().toIso8601String(),
        });
    return SharingPause.fromJson(_map(r));
  }

  Future<void> resume() async {
    await ApiClient.delete('/sharing/pause');
  }

  Future<void> checkIn({
    required List<String> recipientIds,
    String note = '',
    double? lat,
    double? lon,
  }) async {
    await ApiClient.post('/checkins', body: <String, dynamic>{
      'recipient_ids': recipientIds,
      'note': note,
      if (lat != null && lon != null) ...<String, dynamic>{'lat': lat, 'lon': lon},
    });
  }

  Future<LiveShares> liveShares() async =>
      LiveShares.fromJson(_map(await ApiClient.get('/live-shares')));

  Future<void> shareLive({required String viewerId, required int minutes}) async {
    await ApiClient.post('/live-shares',
        body: <String, dynamic>{'viewer_id': viewerId, 'minutes': minutes});
  }

  Future<void> endLiveShare(String id) async {
    await ApiClient.delete('/live-shares/$id');
  }

  Future<ShareLink> createShareLink({required int minutes, String label = ''}) async =>
      ShareLink.fromJson(_map(await ApiClient.post('/share-links',
          body: <String, dynamic>{'minutes': minutes, if (label.isNotEmpty) 'label': label})));

  Future<List<ShareLink>> shareLinks() async {
    final Object? v = _map(await ApiClient.get('/share-links'))['links'];
    return v is List
        ? <ShareLink>[
            for (final Object? e in v)
              if (e is Map<String, dynamic>) ShareLink.fromJson(e),
          ]
        : const <ShareLink>[];
  }

  Future<void> stopShareLink(String id) async {
    await ApiClient.delete('/share-links/$id');
  }

  static Map<String, dynamic> _map(dynamic v) =>
      v is Map<String, dynamic> ? v : <String, dynamic>{};
}

/// Friendly text for a failed sharing call.
String sharingErrorMessage(Object e, {String action = 'do that'}) {
  if (e is ApiException) {
    if (e.status == 429) return 'Please wait a minute before sending another check-in.';
    if (e.status == 404) return 'That person or link is no longer available.';
    if (e.status == 409) return 'You have too many active links. Stop one first.';
    if (e.status >= 500) return 'The server had a problem. Try again shortly.';
    if (e.message.isNotEmpty) return e.message;
  }
  return 'Could not $action. Check your connection and try again.';
}
