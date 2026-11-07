import 'dart:async';
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
  PrivateHistory({required this.kv, this.maxPointsPerMember = 6000, this.window = const Duration(days: 7), this.writeBehind, DateTime Function()? now})
      : _now = now ?? (() => DateTime.now().toUtc());

  final ChannelKv kv;
  final int maxPointsPerMember;
  final Duration window;

  /// null: every [add] rewrites the member's stored track at once (the original behaviour).
  /// Set: new points wait in memory and are merged into the stored track once per interval (or at
  /// [flushAtPoints]), so a burst of 300 items rewrites a 6000-point track once instead of 300 times.
  /// Reads ([range]) and [flush] always see the pending points. Call [flush] when the app is paused.
  final Duration? writeBehind;
  static const int flushAtPoints = 400;
  final Map<String, ({String circle, String user, List<TrackPoint> pts})> _pending =
      <String, ({String circle, String user, List<TrackPoint> pts})>{};
  Timer? _timer;
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
    if (writeBehind == null) return _writeNow(circleId, userId, points);
    final String k = _key(circleId, userId);
    final entry = _pending.putIfAbsent(k, () => (circle: circleId, user: userId, pts: <TrackPoint>[]));
    entry.pts.addAll(points);
    if (entry.pts.length >= flushAtPoints) {
      await _flushKey(k);
    } else {
      _timer ??= Timer(writeBehind!, () {
        _timer = null;
        unawaited(flush());
      });
    }
    return points.length;
  }

  /// Number of points waiting in memory (diagnostics and tests).
  int get pendingPoints => _pending.values.fold(0, (int a, e) => a + e.pts.length);

  Future<void> _flushKey(String k) async {
    final e = _pending.remove(k);
    if (e == null || e.pts.isEmpty) return;
    await _writeNow(e.circle, e.user, e.pts);
  }

  /// Writes everything that is waiting. Safe to call often.
  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    for (final String k in _pending.keys.toList()) {
      await _flushKey(k);
    }
  }

  Future<int> _writeNow(String circleId, String userId, Iterable<TrackPoint> points) async {
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
    await _flushKey(_key(circleId, userId));
    final int a = from.toUtc().millisecondsSinceEpoch, b = to.toUtc().millisecondsSinceEpoch;
    return (await _load(circleId, userId)).where((TrackPoint p) => p.tsMs >= a && p.tsMs < b).toList();
  }

  Future<void> clear(String circleId, String userId) async {
    _pending.remove(_key(circleId, userId));
    await kv.remove(_key(circleId, userId));
  }
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
