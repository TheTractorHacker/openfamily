import 'dart:convert';

import 'private_channel.dart';

/// One point of a member's track, decrypted on this phone.
class TrackPoint {
  const TrackPoint(this.tsMs, this.lat, this.lon, [this.accuracy]);
  final int tsMs;
  final double lat;
  final double lon;
  final double? accuracy;

  List<dynamic> toJson() => <dynamic>[tsMs, lat, lon, accuracy];

  static TrackPoint? fromJson(Object? j) {
    if (j is! List || j.length < 3) return null;
    final Object? t = j[0], la = j[1], lo = j[2];
    if (t is! num || la is! num || lo is! num) return null;
    final double lat = la.toDouble(), lon = lo.toDouble();
    if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return null;
    return TrackPoint(t.toInt(), lat, lon, j.length > 3 && j[3] is num ? (j[3] as num).toDouble() : null);
  }
}

/// On-device history for the live window. A Private circle's server holds only
/// ciphertext, so the day view is built here from decrypted fixes and history
/// chunks. Bounded per member and by age.
class PrivateHistory {
  PrivateHistory({required this.kv, this.maxPointsPerMember = 6000, this.window = const Duration(days: 7), DateTime Function()? now})
      : _now = now ?? (() => DateTime.now().toUtc());

  final ChannelKv kv;
  final int maxPointsPerMember;
  final Duration window;
  final DateTime Function() _now;

  String _key(String circleId, String userId) => 'hist/$circleId/$userId';

  Future<List<TrackPoint>> _load(String circleId, String userId) async {
    final String? raw = await kv.get(_key(circleId, userId));
    if (raw == null || raw.isEmpty) return <TrackPoint>[];
    try {
      return (jsonDecode(raw) as List<dynamic>).map(TrackPoint.fromJson).whereType<TrackPoint>().toList();
    } catch (_) {
      return <TrackPoint>[];
    }
  }

  /// Merges [points] (deduplicated by timestamp) and trims to the window / cap.
  Future<int> add(String circleId, String userId, Iterable<TrackPoint> points) async {
    final Map<int, TrackPoint> byTs = <int, TrackPoint>{
      for (final TrackPoint p in await _load(circleId, userId)) p.tsMs: p,
    };
    final int before = byTs.length;
    for (final TrackPoint p in points) {
      byTs.putIfAbsent(p.tsMs, () => p);
    }
    final int cut = _now().subtract(window).millisecondsSinceEpoch;
    final List<TrackPoint> all = byTs.values.where((TrackPoint p) => p.tsMs >= cut).toList()
      ..sort((TrackPoint a, TrackPoint b) => a.tsMs.compareTo(b.tsMs));
    final List<TrackPoint> kept = all.length > maxPointsPerMember ? all.sublist(all.length - maxPointsPerMember) : all;
    await kv.set(_key(circleId, userId), jsonEncode(kept.map((TrackPoint p) => p.toJson()).toList()));
    return kept.length - before;
  }

  Future<List<TrackPoint>> range(String circleId, String userId, DateTime from, DateTime to) async {
    final int a = from.toUtc().millisecondsSinceEpoch, b = to.toUtc().millisecondsSinceEpoch;
    return (await _load(circleId, userId)).where((TrackPoint p) => p.tsMs >= a && p.tsMs < b).toList();
  }

  Future<void> clear(String circleId, String userId) => kv.remove(_key(circleId, userId));
}

/// Collects this phone's own fixes and cuts them into sealed `history` chunks,
/// so the circle (and later a re-installed phone) can rebuild the track for the
/// retention window while the server still sees only ciphertext.
class HistoryChunker {
  HistoryChunker({required this.kv, this.maxPoints = 300, this.maxAge = const Duration(minutes: 20), DateTime Function()? now})
      : _now = now ?? (() => DateTime.now().toUtc());

  final ChannelKv kv;
  final int maxPoints;
  final Duration maxAge;
  final DateTime Function() _now;

  String _key(String circleId) => 'histbuf/$circleId';

  Future<List<TrackPoint>> _load(String circleId) async {
    final String? raw = await kv.get(_key(circleId));
    if (raw == null || raw.isEmpty) return <TrackPoint>[];
    try {
      return (jsonDecode(raw) as List<dynamic>).map(TrackPoint.fromJson).whereType<TrackPoint>().toList();
    } catch (_) {
      return <TrackPoint>[];
    }
  }

  Future<void> add(String circleId, TrackPoint p) async {
    final List<TrackPoint> l = await _load(circleId)..add(p);
    await kv.set(_key(circleId), jsonEncode(l.map((TrackPoint x) => x.toJson()).toList()));
  }

  /// Returns the body of a chunk when enough points or time have accumulated
  /// (and removes them from the buffer); null otherwise.
  Future<Map<String, dynamic>?> takeIfDue(String circleId, {bool force = false}) async {
    final List<TrackPoint> l = await _load(circleId);
    if (l.isEmpty) return null;
    final bool due = force ||
        l.length >= maxPoints ||
        _now().millisecondsSinceEpoch - l.first.tsMs >= maxAge.inMilliseconds;
    if (!due) return null;
    final List<TrackPoint> take = l.length > maxPoints ? l.sublist(0, maxPoints) : l;
    final List<TrackPoint> rest = l.length > maxPoints ? l.sublist(maxPoints) : <TrackPoint>[];
    if (rest.isEmpty) {
      await kv.remove(_key(circleId));
    } else {
      await kv.set(_key(circleId), jsonEncode(rest.map((TrackPoint x) => x.toJson()).toList()));
    }
    return <String, dynamic>{'pts': take.map((TrackPoint p) => p.toJson()).toList()};
  }

  static List<TrackPoint> parse(Map<String, dynamic> body) {
    final Object? pts = body['pts'];
    if (pts is! List) return <TrackPoint>[];
    return pts.map(TrackPoint.fromJson).whereType<TrackPoint>().toList();
  }
}
