import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:shared_preferences/shared_preferences.dart';

import 'driving_event.dart';

/// Outcome of one upload attempt of a batch.
enum DrivingSendOutcome {
  /// Server accepted (2xx): remove from the queue.
  ok,

  /// Transient failure (offline, 5xx, 401/403): keep and retry later.
  retry,

  /// Permanent rejection (other 4xx): drop the batch.
  drop,
}

typedef DrivingBatchSend = Future<DrivingSendOutcome> Function(
    List<Map<String, dynamic>> events);

/// Merges [added] into [existing], de-duplicating on (kind, started_at) — the
/// same key the server uses for idempotency. Pure, exported for tests.
List<Map<String, dynamic>> drivingOutboxMerge(
  List<Map<String, dynamic>> existing,
  List<Map<String, dynamic>> added,
) {
  final Set<String> seen = <String>{};
  final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
  for (final Map<String, dynamic> e in <Map<String, dynamic>>[
    ...existing,
    ...added,
  ]) {
    if (seen.add(drivingOutboxKey(e))) out.add(e);
  }
  return out;
}

String drivingOutboxKey(Map<String, dynamic> e) =>
    '${e['kind']}|${e['started_at']}';

/// Drops expired entries and evicts the oldest over [maxEvents]. Pure.
List<Map<String, dynamic>> drivingOutboxPrune(
  List<Map<String, dynamic>> events, {
  required DateTime now,
  int maxEvents = 500,
  Duration maxAge = const Duration(days: 3),
}) {
  final List<Map<String, dynamic>> kept = events.where((e) {
    final DateTime? t = DateTime.tryParse('${e['started_at']}');
    return t != null && now.difference(t.toUtc()) <= maxAge;
  }).toList()
    ..sort((a, b) => '${a['started_at']}'.compareTo('${b['started_at']}'));
  while (kept.length > maxEvents) {
    kept.removeAt(0);
  }
  return kept;
}

/// Store-and-forward queue for detected driving events (SharedPreferences,
/// readable from the background isolate). Only event summaries are stored,
/// never raw sensor samples.
class DrivingEventOutbox {
  DrivingEventOutbox._();

  static const String _key = 'driving_event_outbox_v1';

  /// Max events per request (server limit).
  static const int batchSize = 100;

  /// A batch that failed this many times in a row is dropped.
  static const int maxAttempts = 8;

  static int _failures = 0;
  static Future<void> _lock = Future<void>.value();

  /// Tests run each case in its own zone; a lock future left from an earlier
  /// case would never complete.
  @visibleForTesting
  static void resetLockForTest() => _lock = Future<void>.value();

  static Future<T> _serial<T>(Future<T> Function() fn) {
    final Future<T> r = _lock.then((_) => fn());
    _lock = r.then<void>((_) {}, onError: (_) {});
    return r;
  }

  static Future<List<Map<String, dynamic>>> _read(SharedPreferences p) async {
    await p.reload();
    final String? raw = p.getString(_key);
    if (raw == null || raw.isEmpty) return <Map<String, dynamic>>[];
    try {
      return (jsonDecode(raw) as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .toList();
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  static Future<void> _write(
      SharedPreferences p, List<Map<String, dynamic>> v) async {
    if (v.isEmpty) {
      await p.remove(_key);
    } else {
      await p.setString(_key, jsonEncode(v));
    }
  }

  static Future<void> enqueue(List<DrivingEvent> events, {DateTime? now}) {
    if (events.isEmpty) return Future<void>.value();
    return _serial<void>(() async {
      final SharedPreferences p = await SharedPreferences.getInstance();
      final List<Map<String, dynamic>> cur = await _read(p);
      await _write(
        p,
        drivingOutboxPrune(
          drivingOutboxMerge(cur, events.map((e) => e.toJson()).toList()),
          now: (now ?? DateTime.now()).toUtc(),
        ),
      );
    });
  }

  static Future<int> pendingCount() => _serial<int>(() async {
        final SharedPreferences p = await SharedPreferences.getInstance();
        return (await _read(p)).length;
      });

  /// Removes everything (on opt-out: nothing recorded may be uploaded later).
  static Future<void> clear() => _serial<void>(() async {
        final SharedPreferences p = await SharedPreferences.getInstance();
        await p.remove(_key);
        _failures = 0;
      });

  /// Sends queued events oldest-first in batches of <= [batchSize]. Stops at
  /// the first transient failure. Returns the number of events removed.
  static Future<int> drain({required DrivingBatchSend send}) {
    return _serial<int>(() async {
      final SharedPreferences p = await SharedPreferences.getInstance();
      int removed = 0;
      while (true) {
        final List<Map<String, dynamic>> all = await _read(p);
        if (all.isEmpty) return removed;
        all.sort((a, b) => '${a['started_at']}'.compareTo('${b['started_at']}'));
        final List<Map<String, dynamic>> batch = all.take(batchSize).toList();
        DrivingSendOutcome outcome;
        try {
          outcome = await send(batch);
        } catch (_) {
          outcome = DrivingSendOutcome.retry;
        }
        if (outcome == DrivingSendOutcome.retry) {
          _failures++;
          if (_failures < maxAttempts) return removed;
          outcome = DrivingSendOutcome.drop; // Poisoned batch: quarantine.
        }
        _failures = 0;
        final Set<String> gone = batch.map(drivingOutboxKey).toSet();
        final List<Map<String, dynamic>> rest = (await _read(p))
            .where((e) => !gone.contains(drivingOutboxKey(e)))
            .toList();
        await _write(p, rest);
        if (outcome == DrivingSendOutcome.ok) removed += batch.length;
      }
    });
  }
}
