import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';

/// Sends one drained batch to the backend via the foreground API client
/// (Bearer token + 401→refresh path). The default [OutboxSend] for
/// foreground callers; the background isolate uses its own ingest-key sender
/// instead. Returns true only on 2xx — a session-expired redirect or any
/// failure keeps the queue untouched for the next drain.
Future<bool> sendOutboxBatchViaApi(List<Map<String, dynamic>> batch) async {
  try {
    await ApiClient.post(
      '/locations/batch',
      body: LocationOutbox.batchBody(batch),
    );
    return true;
  } catch (_) {
    return false;
  }
}

/// Sends one drained batch to the backend. MUST resolve `true` only when the
/// server accepted the batch (2xx); `false` on any failure (transport error,
/// 4xx, 5xx). Drained points are removed from the queue only on `true`, so a
/// crash between send and removal re-sends duplicates — the batch endpoint
/// dedupes by (device_id, ts), making retries idempotent.
typedef OutboxSend = Future<bool> Function(List<Map<String, dynamic>> points);

/// Prunes an outbox list to the queue limits: drops records older than
/// [maxAge], then evicts oldest-first while over [maxPoints]. Pure function,
/// exported for tests.
List<Map<String, dynamic>> locationOutboxPruneList(
  List<Map<String, dynamic>> points, {
  required DateTime now,
  int maxPoints = 720,
  Duration maxAge = const Duration(hours: 12),
}) {
  final List<Map<String, dynamic>> kept = <Map<String, dynamic>>[];
  for (final Map<String, dynamic> p in points) {
    final DateTime? ts = _parseTs(p['ts']);
    if (ts == null || now.difference(ts) > maxAge) {
      continue; // Missing or expired timestamp: drop permanently.
    }
    kept.add(p);
  }
  while (kept.length > maxPoints) {
    kept.removeAt(_oldestIndex(kept));
  }
  return kept;
}

/// Selects the next drain batch, newest first, so the freshest position is
/// delivered before history and the live map converges quickly. Pure
/// function, exported for tests.
List<Map<String, dynamic>> locationOutboxSelectBatch(
  List<Map<String, dynamic>> points,
  int maxPerCall,
) {
  final List<Map<String, dynamic>> sorted =
      List<Map<String, dynamic>>.of(points)..sort(_compareTsDesc);
  if (sorted.length <= maxPerCall) return sorted;
  return sorted.sublist(0, maxPerCall);
}

/// Records one failed send for every point in [batchTs] and returns the set
/// of timestamps that reached [maxAttempts] failures and must be dropped
/// (quarantined) so a permanently-rejected batch cannot pin the queue. Updates
/// [attempts] in place (dropped entries are removed from it). Pure function,
/// exported for tests.
Set<String> locationOutboxRegisterFailure(
  Map<String, int> attempts,
  Iterable<Object?> batchTs, {
  int maxAttempts = 8,
}) {
  final Set<String> dropped = <String>{};
  for (final Object? raw in batchTs) {
    if (raw is! String) continue;
    final int count = (attempts[raw] ?? 0) + 1;
    if (count >= maxAttempts) {
      attempts.remove(raw);
      dropped.add(raw);
    } else {
      attempts[raw] = count;
    }
  }
  return dropped;
}

int _compareTsDesc(Map<String, dynamic> a, Map<String, dynamic> b) {
  final DateTime? ta = _parseTs(a['ts']);
  final DateTime? tb = _parseTs(b['ts']);
  if (ta == null && tb == null) return 0;
  if (ta == null) return 1; // Unparseable entries drain last.
  if (tb == null) return -1;
  return tb.compareTo(ta); // Descending.
}

int _oldestIndex(List<Map<String, dynamic>> points) {
  int worst = 0;
  for (int i = 1; i < points.length; i++) {
    if (_compareTsDesc(points[worst], points[i]) < 0) {
      worst = i; // points[i] is older than the current worst.
    }
  }
  return worst;
}

DateTime? _parseTs(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  return DateTime.tryParse(raw)?.toUtc();
}

/// A bounded store-and-forward queue for location reports that could not be
/// delivered while the device was offline (hikes, tunnels, road trips).
///
/// Failed reports are kept on-device and replayed via `POST /locations/batch`
/// once connectivity returns, so the family's history shows the actual track
/// through the dead zone instead of a hole.
///
/// Participation model:
/// - the background isolate (`background_location_service.dart`) enqueues any
///   fix whose POST fails and drains whenever a report succeeds;
/// - the foreground reporter (`location_reporter.dart`) does the same for its
///   own stream, using the same storage;
/// - the map screen drains opportunistically when the OS reports the network
///   back.
///
/// Storage is one JSON list under a `shared_preferences` key: small enough
/// for the cap (≤720 records ≈ low hundreds of KB), readable from both
/// isolates with no extra plugins, and last-write-wins. The queue is
/// plaintext (encrypting it needs a new dependency, so it is bounded to 12h /
/// 720 points instead; MOB-004). Drain re-reads the queue after the network
/// call, so points enqueued during a send are not lost; only a same-instant
/// cross-isolate write inside the final read-modify-write (microseconds) can
/// still lose or duplicate a point, and the backend dedupes duplicates.
/// Cross-isolate staleness of the per-isolate prefs cache is mitigated by
/// reloading before every read; the residual race window is milliseconds
/// wide and self-healing.
///
/// Every method is deliberately non-throwing: reporting paths must never
/// crash because the repair queue misbehaved.
class LocationOutbox {
  LocationOutbox._();

  static const String _key = 'location_outbox_v1';
  static const String _attemptsKey = 'location_outbox_attempts_v1';

  /// A point whose batch failed this many times is dropped so one bad batch
  /// (e.g. a record the server rejects with 4xx) cannot pin the queue.
  static const int maxAttempts = 8;

  /// In-process guard so two drains in the same isolate never send the same
  /// batch concurrently.
  static bool _draining = false;

  /// Hard cap on queued records (~12h of 60s background fixes). Keeps prefs
  /// writes small and limits the amount of plaintext location history kept on
  /// disk (MOB-004).
  static const int maxPoints = 720;

  /// Hard age limit, consistent with [maxPoints] at the 60s cadence (720 x
  /// 60s = 12h): records older than this are dropped on enqueue and on drain
  /// (MOB-017). The server accepts up to 7 days, so this is purely a
  /// client-side privacy/size bound.
  static const Duration maxAge = Duration(hours: 12);

  static const int defaultMaxPerCall = 100;

  /// Queues one failed report body (the exact `POST /locations` JSON body).
  /// Dedupes by `ts` so a flapping connection cannot grow the queue with
  /// retries of the same fix.
  static Future<void> enqueue(Map<String, dynamic> point) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final List<Map<String, dynamic>> points = _decode(prefs.getString(_key));
      final Object? ts = point['ts'];
      points.removeWhere((Map<String, dynamic> p) => p['ts'] == ts);
      points.add(point);
      await prefs.setString(
        _key,
        jsonEncode(
          locationOutboxPruneList(points, now: DateTime.now().toUtc()),
        ),
      );
    } catch (_) {
      // Storage failure must never break the reporting path.
    }
  }

  /// Drains up to [maxPerCall] records through [send], newest first. Returns
  /// the number of records removed (delivered or quarantined as undeliverable).
  ///
  /// Removal happens only after [send] resolves `true`, and it is applied to a
  /// FRESH read of the queue taken after the send: points enqueued (by this or
  /// the other isolate) during the network call are preserved (MOB-007). A
  /// later crash re-sends a duplicate that the backend drops idempotently.
  ///
  /// On failure each point in the batch gets a strike; after [maxAttempts]
  /// strikes it is dropped so a poisoned batch cannot block newer data.
  static Future<int> drain({
    required OutboxSend send,
    int maxPerCall = defaultMaxPerCall,
  }) async {
    if (_draining) return 0;
    _draining = true;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final List<Map<String, dynamic>> points = locationOutboxPruneList(
        _decode(prefs.getString(_key)),
        now: DateTime.now().toUtc(),
      );
      if (points.isEmpty) return 0;
      final List<Map<String, dynamic>> batch =
          locationOutboxSelectBatch(points, maxPerCall);
      final bool ok = await send(batch);
      final Set<Object?> batchTs =
          batch.map((Map<String, dynamic> p) => p['ts']).toSet();

      // Re-read: the queue may have changed while the request was in flight.
      await prefs.reload();
      final Map<String, int> attempts = _decodeAttempts(
        prefs.getString(_attemptsKey),
      );
      final Set<Object?> removeTs;
      if (ok) {
        removeTs = batchTs;
        for (final Object? t in batchTs) {
          attempts.remove(t);
        }
      } else {
        removeTs = locationOutboxRegisterFailure(
          attempts,
          batchTs,
          maxAttempts: maxAttempts,
        ).cast<Object?>();
      }
      final List<Map<String, dynamic>> current = locationOutboxPruneList(
        _decode(prefs.getString(_key)),
        now: DateTime.now().toUtc(),
      );
      final List<Map<String, dynamic>> remaining = current
          .where((Map<String, dynamic> p) => !removeTs.contains(p['ts']))
          .toList();
      final Set<Object?> liveTs =
          remaining.map((Map<String, dynamic> p) => p['ts']).toSet();
      attempts.removeWhere((String k, int _) => !liveTs.contains(k));
      if (remaining.isEmpty) {
        // Remove the storage entry entirely rather than leaving a tombstone
        // JSON list: a fully-delivered queue occupies no space at all.
        await prefs.remove(_key);
      } else {
        await prefs.setString(_key, jsonEncode(remaining));
      }
      if (attempts.isEmpty) {
        await prefs.remove(_attemptsKey);
      } else {
        await prefs.setString(_attemptsKey, jsonEncode(attempts));
      }
      return current.length - remaining.length;
    } catch (_) {
      return 0; // Network/backend failures keep the queue untouched.
    } finally {
      _draining = false;
    }
  }

  /// Current queue depth (for UI affordances and debugging). Best-effort: a
  /// storage failure reports 0.
  static Future<int> size() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      return _decode(prefs.getString(_key)).length;
    } catch (_) {
      return 0;
    }
  }

  /// Empties the queue and removes the storage entry entirely.
  ///
  /// Called on full session teardown (logout / force-expired session): queued
  /// points are bound to the device identity they were reported under, and
  /// replaying them after a logout or device re-registration would pin the
  /// queue — mixed-device batches are rejected, and dead-device points age
  /// out only after the server's freshness window. Wiping the queue here
  /// keeps the cache lifecycle tied to the session it was created in.
  static Future<void> clear() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
      await prefs.remove(_attemptsKey);
    } catch (_) {
      // Storage failure must never break the teardown path.
    }
  }

  /// Builds the batch endpoint request body.
  static Map<String, dynamic> batchBody(List<Map<String, dynamic>> points) =>
      <String, dynamic>{'points': points};

  static Map<String, int> _decodeAttempts(String? raw) {
    if (raw == null || raw.isEmpty) return <String, int>{};
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, int>{};
      final Map<String, int> out = <String, int>{};
      decoded.forEach((Object? k, Object? v) {
        if (k is String && v is int) out[k] = v;
      });
      return out;
    } catch (_) {
      return <String, int>{};
    }
  }

  static List<Map<String, dynamic>> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return <Map<String, dynamic>>[];
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) return <Map<String, dynamic>>[];
      return decoded
          .whereType<Map>()
          .map((Map e) => e.cast<String, dynamic>())
          .toList();
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }
}