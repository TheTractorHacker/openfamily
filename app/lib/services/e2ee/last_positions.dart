import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'e2ee_vault.dart';

/// The newest position this phone ever received for one member of one Private circle.
class LastPosition {
  const LastPosition({
    required this.circleId,
    required this.userId,
    required this.tsMs,
    required this.lat,
    required this.lon,
    this.acc,
    this.bat,
    this.spd,
    this.hdg,
    this.mo,
    this.chg,
  });
  final String circleId;
  final String userId;
  final int tsMs;
  final double lat, lon;
  final double? acc;
  final num? bat, spd, hdg;
  final String? mo;

  /// The phone was charging (sealed `chg`, apps from 0.26.14); null when the
  /// sender did not say.
  final bool? chg;

  DateTime get at => DateTime.fromMillisecondsSinceEpoch(tsMs, isUtc: true);

  /// A synthetic `location` frame (the shape the map pipeline already understands). It carries the fix time only,
  /// so the member shows as "last seen <age>" instead of being refreshed to "just now".
  Map<String, dynamic> toFrame({DateTime? heardAt}) => <String, dynamic>{
        'type': 'location',
        'user_id': userId,
        'circle_id': circleId,
        'lat': lat,
        'lon': lon,
        'ts': at.toIso8601String(),
        if (heardAt != null) 'last_seen_at': heardAt.toIso8601String(),
        'accuracy_meters': acc,
        'battery_pct': bat,
        'speed_mps': spd,
        'heading_deg': hdg,
        'motion_state': mo,
        if (chg != null) 'charging': chg,
      };

  List<dynamic> toJson() => <dynamic>[circleId, userId, tsMs, lat, lon, acc, bat, spd, hdg, mo, if (chg != null) chg];

  static LastPosition? fromJson(Object? j) {
    if (j is! List || j.length < 5) return null;
    try {
      final double lat = (j[3] as num).toDouble(), lon = (j[4] as num).toDouble();
      if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return null;
      return LastPosition(
        circleId: j[0] as String,
        userId: j[1] as String,
        tsMs: (j[2] as num).toInt(),
        lat: lat,
        lon: lon,
        acc: j.length > 5 ? (j[5] as num?)?.toDouble() : null,
        bat: j.length > 6 ? j[6] as num? : null,
        spd: j.length > 7 ? j[7] as num? : null,
        hdg: j.length > 8 ? j[8] as num? : null,
        mo: j.length > 9 ? j[9] as String? : null,
        chg: j.length > 10 && j[10] is bool ? j[10] as bool : null,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Last known position per (circle, member), kept in memory and written to the E2EE vault (Android Keystore wrapped,
/// like the circle keys), so a cold start is never empty and the file is never readable as plain text.
/// Never discarded for being old: an old position with its age is more useful than a blank.
class LastPositionBook {
  LastPositionBook({required this.vault, this.writeBehind = const Duration(seconds: 3), this.maxEntries = 400});
  final E2eeVault vault;
  final Duration writeBehind;
  final int maxEntries;
  static const String vaultName = 'lastpos/v1';

  final Map<String, LastPosition> _m = <String, LastPosition>{};
  Future<void>? _loading;
  bool _dirty = false;
  Timer? _timer;

  bool get loaded => _loaded;
  bool _loaded = false;

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final Uint8List? raw = await vault.read(vaultName);
      if (raw != null) {
        for (final dynamic e in jsonDecode(utf8.decode(raw)) as List<dynamic>) {
          final LastPosition? p = LastPosition.fromJson(e);
          if (p != null) _keepNewer(p);
        }
      }
    } catch (_) {
      // unreadable: start empty, the next received fix repopulates it
    }
    _loaded = true;
  }

  String _k(String c, String u) => '$c/$u';

  bool _keepNewer(LastPosition p) {
    final LastPosition? old = _m[_k(p.circleId, p.userId)];
    if (old != null && old.tsMs >= p.tsMs) return false;
    _m[_k(p.circleId, p.userId)] = p;
    return true;
  }

  /// Remembers [p] if it is newer than what is held. Returns whether it changed.
  bool note(LastPosition p) {
    if (!_keepNewer(p)) return false;
    _dirty = true;
    _timer ??= Timer(writeBehind, () {
      _timer = null;
      unawaited(flush());
    });
    return true;
  }

  /// The newest position of [userId] over all circles, or null if none was ever received.
  LastPosition? of(String userId) {
    LastPosition? best;
    for (final LastPosition p in _m.values) {
      if (p.userId == userId && (best == null || p.tsMs > best.tsMs)) best = p;
    }
    return best;
  }

  LastPosition? ofIn(String circleId, String userId) => _m[_k(circleId, userId)];

  List<LastPosition> all() => _m.values.toList();

  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    if (!_dirty) return;
    _dirty = false;
    try {
      List<LastPosition> l = all();
      if (l.length > maxEntries) {
        l.sort((LastPosition a, LastPosition b) => b.tsMs.compareTo(a.tsMs));
        l = l.sublist(0, maxEntries);
      }
      await vault.write(vaultName, Uint8List.fromList(utf8.encode(jsonEncode(l.map((LastPosition p) => p.toJson()).toList()))));
    } catch (_) {
      _dirty = true;
    }
  }

  Future<void> clear() async {
    _m.clear();
    _dirty = false;
    _timer?.cancel();
    _timer = null;
    try {
      await vault.delete(vaultName);
    } catch (_) {}
  }
}
