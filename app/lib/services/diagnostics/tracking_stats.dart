import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

import 'tracking_health.dart';
import 'tracking_journal.dart';

/// Bounded per-hour counters of the location pipeline plus the last upload that
/// worked and the last problem, readable from both isolates.
///
/// Replaces the silent `catch (_) {}` of the background callbacks: a failure is
/// now counted and its exception TYPE (never its message, which may carry a
/// host or a coordinate) is kept with a time.
///
/// Cross-isolate safety: each isolate writes ONLY its own preferences key
/// (`tracking_stats_v1_app` / `_bg`), exactly like [TrackingJournal], so a
/// read-modify-write never overwrites the other isolate's numbers. The reader
/// reloads preferences and sums both. Increments are held in memory and
/// written at most every [flushEvery] (the background service hands over a fix
/// per second while driving), and on [flush] (the heartbeat tick calls it).
/// An isolate killed between two writes loses at most those few seconds.
class TrackingStats {
  TrackingStats({DateTime Function()? clock, this.flushEvery = const Duration(seconds: 15)})
      : _clock = clock ?? DateTime.now;

  static final TrackingStats instance = TrackingStats();

  static const String keyPrefix = 'tracking_stats_v1_';

  /// Hours of counters kept per isolate.
  static const int maxHours = 24;

  final DateTime Function() _clock;
  final Duration flushEvery;

  final Map<String, List<int>> _pendingHours = <String, List<int>>{};
  int? _pendingOk;
  Map<String, Object>? _pendingError;
  Map<String, Object>? _pendingSeal;
  DateTime? _lastFlushAt;
  Future<void> _chain = Future<void>.value();

  static String hourKey(DateTime t) {
    final DateTime u = t.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${u.year}-${two(u.month)}-${two(u.day)}T${two(u.hour)}';
  }

  /// Counts [n] of [c] in the current UTC hour. Never throws, never blocks.
  void count(TrackCounter c, [int n = 1]) {
    final DateTime now = _clock();
    final List<int> h = _pendingHours.putIfAbsent(hourKey(now), () => List<int>.filled(TrackCounter.values.length, 0));
    h[c.index] += n;
    _flushIfDue(now);
  }

  /// A report or batch the server accepted.
  void noteUploadOk() {
    final DateTime now = _clock();
    _pendingOk = now.toUtc().millisecondsSinceEpoch;
    _flushIfDue(now);
  }

  /// A failure in the pipeline: only [where] (a fixed tag) and the exception TYPE are kept.
  void noteError(String where, Object error) {
    _pendingError = _errorMap(where, error);
    _flushIfDue(_clock(), within: errorFlushEvery);
  }

  /// A fix that could not be sealed. [code] is the coarse class the sealer already uses (`unreadable`, `missing`, ...).
  void noteSealError(Object error, {String code = ''}) {
    _pendingSeal = _errorMap(code.isEmpty ? 'seal' : 'seal:$code', error);
    _flushIfDue(_clock(), within: errorFlushEvery);
  }

  Map<String, Object> _errorMap(String where, Object error) => <String, Object>{
        'at': _clock().toUtc().millisecondsSinceEpoch,
        'w': clipCode(where, 40),
        't': typeName(error),
      };

  /// The exception's runtime TYPE only, reduced to identifier characters.
  static String typeName(Object error) {
    final String t = error.runtimeType.toString().replaceAll(RegExp(r'[^A-Za-z0-9_<>?,. ]'), '');
    return t.isEmpty ? 'Unknown' : (t.length <= 48 ? t : t.substring(0, 48));
  }

  /// A problem is written sooner than a counter (the process may die right after it), but a callback that fails
  /// once a second must not write once a second either.
  static const Duration errorFlushEvery = Duration(seconds: 3);

  void _flushIfDue(DateTime now, {Duration? within}) {
    final DateTime? last = _lastFlushAt;
    if (last == null || now.difference(last) >= (within ?? flushEvery) || now.isBefore(last)) _flushNow();
  }

  void _flushNow() {
    _lastFlushAt = _clock();
    unawaited(flush());
  }

  /// Writes what is pending. Safe to call at any time; calls run one after the other.
  Future<void> flush() {
    final Map<String, List<int>> hours = Map<String, List<int>>.of(_pendingHours);
    final int? ok = _pendingOk;
    final Map<String, Object>? err = _pendingError;
    final Map<String, Object>? seal = _pendingSeal;
    if (hours.isEmpty && ok == null && err == null && seal == null) return _chain;
    _pendingHours.clear();
    _pendingOk = null;
    _pendingError = null;
    _pendingSeal = null;
    final String src = TrackingJournal.source;
    _chain = _chain.then((_) => _write(src, hours, ok, err, seal)).catchError((Object _) {});
    return _chain;
  }

  Future<void> _write(
    String src,
    Map<String, List<int>> hours,
    int? ok,
    Map<String, Object>? err,
    Map<String, Object>? seal,
  ) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      try {
        await prefs.reload();
      } catch (_) {}
      final Map<String, dynamic> stored = _decode(prefs.getString('$keyPrefix$src'));
      final Map<String, dynamic> h = (stored['h'] is Map) ? (stored['h'] as Map).cast<String, dynamic>() : <String, dynamic>{};
      hours.forEach((String k, List<int> d) {
        final List<int> cur = (h[k] is List)
            ? (h[k] as List).map((Object? v) => v is num ? v.toInt() : 0).toList()
            : <int>[];
        while (cur.length < d.length) {
          cur.add(0);
        }
        for (int i = 0; i < d.length; i++) {
          cur[i] += d[i];
        }
        h[k] = cur;
      });
      if (h.length > maxHours) {
        final List<String> keys = h.keys.toList()..sort();
        for (final String k in keys.sublist(0, keys.length - maxHours)) {
          h.remove(k);
        }
      }
      stored['h'] = h;
      if (ok != null) stored['ok'] = ok;
      if (err != null) stored['err'] = err;
      if (seal != null) stored['seal'] = seal;
      await prefs.setString('$keyPrefix$src', jsonEncode(stored));
    } catch (_) {
      // Counting must never disturb tracking.
    }
  }

  static Map<String, dynamic> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return <String, dynamic>{};
    try {
      final Object? d = jsonDecode(raw);
      return d is Map ? d.cast<String, dynamic>() : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  /// Both isolates' numbers summed, once this isolate's pending writes landed.
  Future<StatsSnapshot> read() async {
    await flush();
    await _chain;
    final Map<String, List<int>> sum = <String, List<int>>{};
    DateTime? okAt;
    String okSrc = '';
    StatsError? lastErr, lastSeal;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      try {
        await prefs.reload();
      } catch (_) {}
      for (final String src in const <String>['app', 'bg']) {
        final Map<String, dynamic> m = _decode(prefs.getString('$keyPrefix$src'));
        final Object? h = m['h'];
        if (h is Map) {
          h.forEach((Object? k, Object? v) {
            if (k is! String || v is! List) return;
            final List<int> cur = sum.putIfAbsent(k, () => List<int>.filled(TrackCounter.values.length, 0));
            for (int i = 0; i < v.length && i < cur.length; i++) {
              final Object? x = v[i];
              if (x is num) cur[i] += x.toInt();
            }
          });
        }
        final Object? ok = m['ok'];
        if (ok is num) {
          final DateTime t = DateTime.fromMillisecondsSinceEpoch(ok.toInt(), isUtc: true);
          if (okAt == null || t.isAfter(okAt)) {
            okAt = t;
            okSrc = src;
          }
        }
        final StatsError? e = _error(m['err'], src);
        if (e != null && (lastErr == null || e.at.isAfter(lastErr.at))) lastErr = e;
        final StatsError? s = _error(m['seal'], src);
        if (s != null && (lastSeal == null || s.at.isAfter(lastSeal.at))) lastSeal = s;
      }
    } catch (_) {}
    final List<String> keys = sum.keys.toList()..sort();
    return StatsSnapshot(
      hours: <HourCounts>[for (final String k in keys) HourCounts(k, sum[k]!)],
      lastUploadOkAt: okAt,
      lastUploadOkSource: okSrc,
      lastError: lastErr,
      lastSealError: lastSeal,
    );
  }

  static StatsError? _error(Object? o, String src) {
    if (o is! Map) return null;
    final Object? at = o['at'];
    if (at is! num) return null;
    return StatsError(
      at: DateTime.fromMillisecondsSinceEpoch(at.toInt(), isUtc: true),
      where: clipCode('${o['w'] ?? ''}', 40),
      type: clipCode('${o['t'] ?? ''}', 48),
      source: src,
    );
  }

  @visibleForTesting
  void resetForTest() {
    _pendingHours.clear();
    _pendingOk = null;
    _pendingError = null;
    _pendingSeal = null;
    _lastFlushAt = null;
    _chain = Future<void>.value();
  }
}
