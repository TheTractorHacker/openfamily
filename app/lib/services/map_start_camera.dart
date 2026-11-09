import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/member.dart';

/// Where the map camera came from, in priority order: a later, better source
/// may replace an earlier, weaker one, never the other way round.
enum StartSource { none, members, cachedOwn, freshOwn }

/// Decides where the home map starts and whether it may still move on its own.
///
/// The order is: your last known position (from disk, so it is there on a
/// cold start before anything else has loaded) -> a fresh fix of this phone ->
/// only when neither exists, the circle's members. Once the user has taken
/// the camera (pan, pinch, a tapped member, recenter, a circle switch) nothing
/// automatic moves it again.
///
/// Before this, the map started on a hard-coded default (San Francisco) and
/// later fitted ALL members' positions. In a Private circle the server roster
/// carries no positions, so the fit often had nothing (the default stayed) or
/// one remembered member far away: the map opened "somewhere random".
class StartCamera {
  StartSource _placed = StartSource.none;
  bool _userTookOver = false;

  StartSource get placedBy => _placed;
  bool get userTookOver => _userTookOver;

  /// The user moved the camera (or asked for a specific view): automatic
  /// placement stops for this screen's lifetime.
  void takeOver() => _userTookOver = true;

  /// Offers this phone's own position. Returns true when the camera should
  /// go there now. [fresh]: a fix just taken (beats a remembered one).
  bool offerOwn(LatLng p, {required bool fresh}) {
    if (_userTookOver || !isPlausible(p)) return false;
    final StartSource s = fresh ? StartSource.freshOwn : StartSource.cachedOwn;
    if (_placed.index >= s.index) return false;
    _placed = s;
    return true;
  }

  /// Members to frame when no own position is known yet, or null when the
  /// camera must stay where it is. Only recent, plausible points count: a
  /// position remembered from days ago (or a 0,0 placeholder) never decides
  /// where the map opens.
  List<LatLng>? membersToFit(List<Member> members, {DateTime? now}) {
    if (_userTookOver || _placed != StartSource.none) return null;
    final List<LatLng> pts = fitPoints(members, now: now);
    if (pts.isEmpty) return null;
    _placed = StartSource.members;
    return pts;
  }

  /// How old a member's fix may be to count when framing the circle.
  static const Duration fitMaxAge = Duration(hours: 24);

  /// Recent, plausible member positions (for the initial fit and for an
  /// explicit circle switch).
  static List<LatLng> fitPoints(List<Member> members, {DateTime? now}) {
    final DateTime t = (now ?? DateTime.now()).toUtc();
    return <LatLng>[
      for (final Member m in members)
        if (m.position != null &&
            isPlausible(m.position!) &&
            _recent(m, t))
          m.position!,
    ];
  }

  static bool _recent(Member m, DateTime now) {
    final DateTime? at = m.fixTime ?? m.lastSeen;
    // No timestamp at all: the server sent it as current.
    if (at == null) return true;
    return now.difference(at.toUtc()) <= fitMaxAge;
  }

  /// Rejects NaN, out-of-range and the 0,0 "null island" placeholder.
  static bool isPlausible(LatLng p) {
    final double lat = p.latitude, lon = p.longitude;
    if (lat.isNaN || lon.isNaN) return false;
    if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return false;
    return !(lat.abs() < 1e-6 && lon.abs() < 1e-6);
  }
}

/// This phone's last known position, kept on disk so the map can open on it
/// immediately on a cold start (before the roster, the WebSocket or a GPS fix).
class OwnPositionCache {
  OwnPositionCache._();

  static const String _key = 'map.own_last_fix.v1';

  static LatLng? _value;
  static int _savedAtMs = 0;
  static bool _loaded = false;

  /// The remembered position (null until [load] ran or when there is none).
  static LatLng? get value => _value;

  /// Reads the stored position once (cheap; call before the first frame).
  static Future<void> load() async {
    if (_loaded) return;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString(_key);
      _loaded = true;
      if (raw == null) return;
      final List<String> parts = raw.split(',');
      if (parts.length < 2) return;
      final double? lat = double.tryParse(parts[0]);
      final double? lon = double.tryParse(parts[1]);
      if (lat == null || lon == null) return;
      final LatLng p = LatLng(lat, lon);
      if (!StartCamera.isPlausible(p)) return;
      _value = p;
      if (parts.length > 2) _savedAtMs = int.tryParse(parts[2]) ?? 0;
    } catch (_) {
      // No position: the map falls back to the next source.
    }
  }

  /// Remembers [p], a fix taken at [at] (default: now). A fix older than the
  /// remembered one never replaces it (a roster can carry your last REPORT,
  /// older than the fix this phone just took). Writes are skipped while the
  /// position barely changed and the last write is recent, so a stream of
  /// fixes costs almost nothing.
  static Future<void> save(LatLng p, {DateTime? at, DateTime? now}) async {
    if (!StartCamera.isPlausible(p)) return;
    final int t = (at ?? now ?? DateTime.now()).millisecondsSinceEpoch;
    if (t < _savedAtMs) return;
    final LatLng? prev = _value;
    if (prev != null &&
        const Distance().as(LengthUnit.Meter, prev, p) < 50 &&
        t - _savedAtMs < const Duration(minutes: 10).inMilliseconds) {
      return;
    }
    _value = p;
    _savedAtMs = t;
    _loaded = true;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, '${p.latitude},${p.longitude},$t');
    } catch (_) {}
  }

  /// Forgets the position (sign-out).
  static Future<void> clear() async {
    _value = null;
    _savedAtMs = 0;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    } catch (_) {}
  }

  @visibleForTesting
  static void debugReset() {
    _value = null;
    _savedAtMs = 0;
    _loaded = false;
  }
}
