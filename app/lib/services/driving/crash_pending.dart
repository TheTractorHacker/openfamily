import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Where a probable crash is in its life cycle.
enum CrashPhase {
  /// The "Are you OK?" countdown is running.
  counting,

  /// The countdown ended (or help was requested) and the alert is being sent.
  sending,

  /// The alert reached the server.
  sent,

  /// The user said they are fine before the countdown ended. Nothing was sent.
  cancelled,
}

/// A probable crash waiting for the user's answer. Shared between the
/// background isolate (which detects it and sends the alert) and the UI
/// isolate (which shows the countdown) through SharedPreferences.
class CrashPending {
  const CrashPending({
    required this.occurredAtMs,
    required this.deadlineMs,
    required this.peakG,
    required this.speedBeforeMps,
    required this.speedAfterMps,
    this.lat,
    this.lon,
    this.helpRequested = false,
    this.cancelled = false,
    this.sentId,
  });

  static const Duration countdown = Duration(seconds: 30);

  /// Pending records older than this are ignored (stale state after a restart).
  static const Duration staleAfter = Duration(minutes: 10);

  factory CrashPending.start({
    required int occurredAtMs,
    required int nowMs,
    required double peakG,
    required double speedBeforeMps,
    required double speedAfterMps,
    double? lat,
    double? lon,
    Duration countdown = CrashPending.countdown,
  }) =>
      CrashPending(
        occurredAtMs: occurredAtMs,
        deadlineMs: nowMs + countdown.inMilliseconds,
        peakG: peakG,
        speedBeforeMps: speedBeforeMps,
        speedAfterMps: speedAfterMps,
        lat: lat,
        lon: lon,
      );

  final int occurredAtMs;
  final int deadlineMs;
  final double peakG;
  final double speedBeforeMps;
  final double speedAfterMps;
  final double? lat;
  final double? lon;
  final bool helpRequested;
  final bool cancelled;

  /// Server id of the stored crash report, once the alert went out.
  final String? sentId;

  CrashPending copyWith({bool? helpRequested, bool? cancelled, String? sentId}) =>
      CrashPending(
        occurredAtMs: occurredAtMs,
        deadlineMs: deadlineMs,
        peakG: peakG,
        speedBeforeMps: speedBeforeMps,
        speedAfterMps: speedAfterMps,
        lat: lat,
        lon: lon,
        helpRequested: helpRequested ?? this.helpRequested,
        cancelled: cancelled ?? this.cancelled,
        sentId: sentId ?? this.sentId,
      );

  CrashPhase phase(int nowMs) {
    if (cancelled) return CrashPhase.cancelled;
    if (sentId != null) return CrashPhase.sent;
    if (helpRequested || nowMs >= deadlineMs) return CrashPhase.sending;
    return CrashPhase.counting;
  }

  /// Whole seconds left on the countdown, never negative.
  int secondsLeft(int nowMs) {
    final int ms = deadlineMs - nowMs;
    return ms <= 0 ? 0 : (ms / 1000).ceil();
  }

  /// True while the user still has a decision to make or the alert is in
  /// flight, so the UI should keep showing the screen.
  bool isLive(int nowMs) =>
      !cancelled &&
      nowMs - occurredAtMs < staleAfter.inMilliseconds &&
      sentId == null;

  /// Body of `POST /crash-alerts`.
  Map<String, dynamic> toRequestBody() => <String, dynamic>{
        'occurred_at':
            DateTime.fromMillisecondsSinceEpoch(occurredAtMs, isUtc: true)
                .toIso8601String(),
        if (lat != null) 'lat': lat,
        if (lon != null) 'lon': lon,
        'peak_g': peakG,
        'speed_before_mps': speedBeforeMps,
        'speed_after_mps': speedAfterMps,
        'help_requested': helpRequested,
      };

  Map<String, dynamic> toJson() => <String, dynamic>{
        't': occurredAtMs,
        'd': deadlineMs,
        'g': peakG,
        'b': speedBeforeMps,
        'a': speedAfterMps,
        if (lat != null) 'lat': lat,
        if (lon != null) 'lon': lon,
        'h': helpRequested,
        'c': cancelled,
        if (sentId != null) 's': sentId,
      };

  static CrashPending? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? t = raw['t'], d = raw['d'];
    if (t is! num || d is! num) return null;
    double n(Object? v) => v is num ? v.toDouble() : 0;
    return CrashPending(
      occurredAtMs: t.toInt(),
      deadlineMs: d.toInt(),
      peakG: n(raw['g']),
      speedBeforeMps: n(raw['b']),
      speedAfterMps: n(raw['a']),
      lat: raw['lat'] is num ? (raw['lat'] as num).toDouble() : null,
      lon: raw['lon'] is num ? (raw['lon'] as num).toDouble() : null,
      helpRequested: raw['h'] == true,
      cancelled: raw['c'] == true,
      sentId: raw['s'] is String ? raw['s'] as String : null,
    );
  }
}

/// SharedPreferences-backed holder of the single [CrashPending] record.
class CrashPendingStore {
  CrashPendingStore._();

  static const String key = 'driving_crash_pending';

  static Future<CrashPending?> load({bool reload = true}) async {
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      if (reload) await p.reload();
      final String? raw = p.getString(key);
      if (raw == null) return null;
      return CrashPending.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(CrashPending c) async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.setString(key, jsonEncode(c.toJson()));
  }

  static Future<void> clear() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.remove(key);
  }

  /// "I'm OK": stops the countdown. Never overrides an alert already sent.
  static Future<CrashPending?> cancel() async {
    final CrashPending? c = await load();
    if (c == null || c.sentId != null) return c;
    final CrashPending next = c.copyWith(cancelled: true);
    await save(next);
    return next;
  }

  /// "I need help": ends the countdown now and sends immediately.
  static Future<CrashPending?> requestHelp() async {
    final CrashPending? c = await load();
    if (c == null || c.cancelled) return c;
    final CrashPending next = c.copyWith(helpRequested: true);
    await save(next);
    return next;
  }

  static Future<void> markSent(String id) async {
    final CrashPending? c = await load();
    if (c == null || c.cancelled) return;
    await save(c.copyWith(sentId: id));
  }
}
