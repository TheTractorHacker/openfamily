import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/location_outbox.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Anchor to the real wall clock: enqueue() prunes with DateTime.now(), so a
  // fixed fixture date would silently expire points as real time passes.
  final DateTime now = DateTime.now().toUtc();

  Map<String, dynamic> point(String ts, {int lat = 47}) =>
      <String, dynamic>{
        'device_id': 'dev-1',
        'ts': ts,
        'lat': lat,
        'lon': 11.0,
        'source': 'background',
      };

  Future<SharedPreferences> prefsWith(List<Map<String, dynamic>> points) async {
    final Map<String, Object> initial = <String, Object>{
      'location_outbox_v1': jsonEncode(points),
    };
    SharedPreferences.setMockInitialValues(initial);
    return SharedPreferences.getInstance();
  }

  Future<List<Map<String, dynamic>>> readQueue() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final Object? raw = prefs.get('location_outbox_v1');
    if (raw is! String) return <Map<String, dynamic>>[];
    return (jsonDecode(raw) as List)
        .cast<Map>()
        .map((Map e) => e.cast<String, dynamic>())
        .toList();
  }

  group('enqueue', () {
    test('persists a failed report', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await LocationOutbox.enqueue(point(now.toIso8601String()));
      expect(await readQueue().then((q) => q.length), 1);
    });

    test('deduplicates by timestamp', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await LocationOutbox.enqueue(point(now.toIso8601String()));
      await LocationOutbox.enqueue(point(now.toIso8601String()));
      expect(await readQueue().then((q) => q.length), 1);
    });

    test('drops records older than the age cap', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await LocationOutbox.enqueue(
        point(now.subtract(const Duration(hours: 13)).toIso8601String()),
      );
      await LocationOutbox.enqueue(point(now.toIso8601String()));
      final List<Map<String, dynamic>> queue = await readQueue();
      expect(queue.length, 1);
      expect(queue.single['ts'], now.toIso8601String());
    });

    test('evicts oldest beyond the hard cap', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      for (int i = 0; i < 730; i++) {
        await LocationOutbox.enqueue(
          point(now.subtract(Duration(seconds: 730 - i)).toIso8601String()),
        );
      }
      final List<Map<String, dynamic>> queue = await readQueue();
      expect(queue.length, 720);
      // The ten oldest were evicted; the newest record survives.
      expect(
        queue.map((p) => p['ts']),
        contains(now.subtract(const Duration(seconds: 1)).toIso8601String()),
      );
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('drain', () {
    test('newest-first, respects maxPerCall, removes only what was sent',
        () async {
      final List<Map<String, dynamic>> queued = <Map<String, dynamic>>[
        for (int i = 0; i < 5; i++)
          point(now.subtract(Duration(minutes: 4 - i)).toIso8601String()),
      ]; // ts order: oldest first in storage.
      await prefsWith(queued);

      final List<List<Map<String, dynamic>>> sent = <List<Map<String, dynamic>>>[];
      final int removed = await LocationOutbox.drain(
        send: (batch) async {
          sent.add(batch);
          return false; // Simulate a failed batch.
        },
        maxPerCall: 3,
      );
      expect(removed, 0);
      expect(sent.length, 1);
      // Newest first: the current point leads even though storage had it last.
      expect(
        sent.single.first['ts'],
        now.toIso8601String(),
      );

      final int removedOk = await LocationOutbox.drain(
        send: (batch) async => true,
        maxPerCall: 3,
      );
      expect(removedOk, 3);
      final List<Map<String, dynamic>> remaining = await readQueue();
      expect(remaining.length, 2);
      // The three freshest records were drained first; the two oldest remain.
      final Set<String> remainingTs = remaining
          .map((Map<String, dynamic> p) => p['ts'] as String)
          .toSet();
      expect(
        remainingTs,
        <String>{
          now.subtract(const Duration(minutes: 3)).toIso8601String(),
          now.subtract(const Duration(minutes: 4)).toIso8601String(),
        },
      );
    });

    test('keeps the queue untouched when the send fails', () async {
      await prefsWith(<Map<String, dynamic>>[point(now.toIso8601String())]);
      await LocationOutbox.drain(send: (batch) async => false);
      expect(await readQueue().then((q) => q.length), 1);
    });

    test('returns 0 for an empty queue', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      expect(
        await LocationOutbox.drain(send: (batch) async => true),
        0,
      );
    });

    test('preserves points enqueued while the send is in flight', () async {
      await prefsWith(<Map<String, dynamic>>[
        point(now.subtract(const Duration(minutes: 5)).toIso8601String()),
      ]);
      final String lateTs =
          now.subtract(const Duration(minutes: 1)).toIso8601String();
      final int removed = await LocationOutbox.drain(
        send: (batch) async {
          await LocationOutbox.enqueue(point(lateTs));
          return true;
        },
      );
      expect(removed, 1);
      final List<Map<String, dynamic>> queue = await readQueue();
      expect(queue.length, 1);
      expect(queue.single['ts'], lateTs);
    });

    test('quarantines a batch that keeps failing so it cannot pin the queue',
        () async {
      final String badTs =
          now.subtract(const Duration(minutes: 5)).toIso8601String();
      await prefsWith(<Map<String, dynamic>>[point(badTs)]);
      for (int i = 0; i < LocationOutbox.maxAttempts - 1; i++) {
        expect(await LocationOutbox.drain(send: (batch) async => false), 0);
        expect(await LocationOutbox.size(), 1);
      }
      // The final strike drops the poisoned point.
      expect(await LocationOutbox.drain(send: (batch) async => false), 1);
      expect(await LocationOutbox.size(), 0);
    });

    test('removes the storage entry entirely when the queue empties',
        () async {
      // Exactly one record + maxPerCall large enough: one send, all removed.
      await prefsWith(<Map<String, dynamic>>[point(now.toIso8601String())]);
      await LocationOutbox.drain(
        send: (batch) async => true,
        maxPerCall: 10,
      );
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.get('location_outbox_v1'), isNull);
    });
  });

  group('clear', () {
    test('empties the queue and removes the storage entry', () async {
      await prefsWith(<Map<String, dynamic>>[
        point(now.toIso8601String()),
        point(now.toIso8601String(), lat: 48),
      ]);
      await LocationOutbox.clear();
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.get('location_outbox_v1'), isNull);
      expect(await LocationOutbox.size(), 0);
    });

    test('is safe to call repeatedly and on an empty queue', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await LocationOutbox.clear();
      await LocationOutbox.clear();
      expect(await LocationOutbox.size(), 0);
    });
  });

  group('pure helpers', () {
    test('locationOutboxPruneList drops expired and evicts oldest', () {
      final List<Map<String, dynamic>> points = <Map<String, dynamic>>[
        point(now.subtract(const Duration(hours: 13)).toIso8601String()),
        point(now.subtract(const Duration(hours: 1)).toIso8601String()),
        point(now.toIso8601String()),
      ];
      final List<Map<String, dynamic>> pruned = locationOutboxPruneList(
        points,
        now: now,
      );
      expect(pruned.length, 2);

      final List<Map<String, dynamic>> over = <Map<String, dynamic>>[
        for (int i = 0; i < 750; i++)
          point(
            now.subtract(Duration(seconds: 750 - i)).toIso8601String(),
            lat: i,
          ),
      ];
      expect(locationOutboxPruneList(over, now: now).length, 720);
    });

    test('locationOutboxRegisterFailure drops points at the attempt cap', () {
      final Map<String, int> attempts = <String, int>{};
      expect(
        locationOutboxRegisterFailure(attempts, <Object?>['a'], maxAttempts: 2),
        isEmpty,
      );
      expect(attempts['a'], 1);
      expect(
        locationOutboxRegisterFailure(attempts, <Object?>['a'], maxAttempts: 2),
        <String>{'a'},
      );
      expect(attempts.containsKey('a'), isFalse);
    });

    test('locationOutboxSelectBatch sorts newest first and slices', () {
      final List<Map<String, dynamic>> points = <Map<String, dynamic>>[
        point(now.subtract(const Duration(minutes: 2)).toIso8601String()),
        point(now.toIso8601String()),
        point(now.subtract(const Duration(minutes: 1)).toIso8601String()),
      ];
      final List<Map<String, dynamic>> batch =
          locationOutboxSelectBatch(points, 2);
      expect(batch.length, 2);
      expect(batch[0]['ts'], now.toIso8601String());
      expect(batch[1]['ts'],
          now.subtract(const Duration(minutes: 1)).toIso8601String());
    });
  });
}