import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'tracking_cadence.dart';

/// Live boost: a viewer is watching this member right now, so report at 1 Hz
/// for a short while.
///
/// Sources:
///  * the `{"type":"live_boost","ttl_s":60}` direct-push command;
///  * `"live": true` in the `POST /locations` response.
///
/// Parsing is deliberately tolerant: unknown / missing / malformed fields mean
/// "no boost", never an exception.
class LiveBoost {
  LiveBoost._();

  /// Parses a direct-push command payload. Returns the TTL (clamped to
  /// [1, max]) when it is a live_boost command, null otherwise. A missing or
  /// invalid `ttl_s` falls back to [defaultTtl].
  static Duration? parseCommand(
    String raw, {
    Duration max = const Duration(seconds: 120),
    Duration defaultTtl = const Duration(seconds: 60),
  }) {
    try {
      final dynamic j = jsonDecode(raw);
      if (j is! Map || j['type'] != 'live_boost') return null;
      final Object? t = j['ttl_s'];
      int secs = defaultTtl.inSeconds;
      if (t is num && t.isFinite && t > 0) secs = t.round();
      if (secs < 1) secs = 1;
      final Duration d = Duration(seconds: secs);
      return d > max ? max : d;
    } catch (_) {
      return null;
    }
  }

  /// True when a `POST /locations` response body carries `"live": true`.
  /// Accepts an already-decoded map or a JSON string.
  static bool responseIsLive(Object? body) {
    try {
      Object? v = body;
      if (v is String) {
        if (v.isEmpty) return false;
        v = jsonDecode(v);
      }
      return v is Map && v['live'] == true;
    } catch (_) {
      return false;
    }
  }

  static const String _prefsKey = 'live_boost_until_ms_v1';

  /// Persists the boost deadline so the other isolate (foreground UI vs the
  /// background locator) can honour a command that only reached one of them.
  /// Never throws.
  static Future<void> persist(DateTime until) async {
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      await p.setInt(_prefsKey, until.toUtc().millisecondsSinceEpoch);
    } catch (_) {}
  }

  /// Reads a persisted deadline still in the future, else null. Never throws.
  static Future<DateTime?> readActive(DateTime now) async {
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      await p.reload();
      final int? ms = p.getInt(_prefsKey);
      if (ms == null) return null;
      final DateTime until =
          DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
      return until.isAfter(now.toUtc()) ? until : null;
    } catch (_) {
      return null;
    }
  }

  /// Per-isolate policy instances register here so an incoming command can
  /// boost whichever reporters live in this isolate.
  static final List<TrackingCadence> _listeners = <TrackingCadence>[];
  static final Map<TrackingCadence, void Function()> _hooks =
      <TrackingCadence, void Function()>{};

  /// [onBoost] is invoked after the boost was applied so the owner can
  /// reconfigure its GPS source immediately.
  static void register(TrackingCadence c, {void Function()? onBoost}) {
    if (!_listeners.contains(c)) _listeners.add(c);
    if (onBoost != null) _hooks[c] = onBoost;
  }

  static void unregister(TrackingCadence c) {
    _listeners.remove(c);
    _hooks.remove(c);
  }

  /// Applies a boost of [ttl] (capped by each policy's config) to every
  /// registered policy and persists it. Returns false when [ttl] <= 0.
  static Future<bool> apply(Duration ttl, {DateTime? now}) async {
    if (ttl <= Duration.zero) return false;
    final DateTime n = (now ?? DateTime.now()).toUtc();
    for (final TrackingCadence c in List<TrackingCadence>.of(_listeners)) {
      c.startBoost(ttl, n);
      try {
        _hooks[c]?.call();
      } catch (_) {}
    }
    final Duration cap = _listeners.isEmpty
        ? const Duration(seconds: 120)
        : _listeners.first.config.maxBoost;
    await persist(n.add(ttl > cap ? cap : ttl));
    return true;
  }
}

/// Cross-isolate "the foreground reporter is alive" marker. While the app is
/// open its own reporter posts at the active cadence, so the background
/// isolate skips fast-tier posts instead of doubling the request rate.
class ForegroundPresence {
  ForegroundPresence._();

  static const String _key = 'fg_reporter_alive_ms_v1';

  static Future<void> mark(DateTime now) async {
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      await p.setInt(_key, now.toUtc().millisecondsSinceEpoch);
    } catch (_) {}
  }

  static Future<void> clear() async {
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      await p.remove(_key);
    } catch (_) {}
  }

  static Future<bool> isFresh(DateTime now,
      {Duration within = const Duration(seconds: 12)}) async {
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      await p.reload();
      final int? ms = p.getInt(_key);
      if (ms == null) return false;
      return now.toUtc().millisecondsSinceEpoch - ms <= within.inMilliseconds;
    } catch (_) {
      return false;
    }
  }
}
