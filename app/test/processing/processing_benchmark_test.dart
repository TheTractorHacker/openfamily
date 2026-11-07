import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/processing/processing.dart';

/// Dart VM micro-benchmarks (JIT, desktop CPU, NOT a phone, NOT a release/AOT
/// build, NO battery measurement). Numbers are printed for
/// docs/design/PROCESSING_ON_DEVICE.md; assertions are only coarse guards
/// (bounded memory, no quadratic blow-up).
List<Fix> _day(int dayIndex, {required int driveIntervalS, required int idleIntervalS, int drives = 2}) {
  final math.Random rng = math.Random(dayIndex + 1);
  final List<Fix> out = <Fix>[];
  final int base = DateTime.utc(2026, 10, 19 + dayIndex).microsecondsSinceEpoch;
  double y = 0, x = 0;
  int t = 0; // seconds into the day
  void still(int seconds, double jitter) {
    final double bx = x, by = y;
    for (int e = idleIntervalS; e <= seconds; e += idleIntervalS) {
      t += idleIntervalS;
      x = bx + (rng.nextDouble() * 2 - 1) * jitter;
      y = by + (rng.nextDouble() * 2 - 1) * jitter;
      out.add(_fix(base, t, x, y, 0, idleIntervalS));
    }
    x = bx;
    y = by;
  }

  void drive(int seconds, double v) {
    for (int e = driveIntervalS; e <= seconds; e += driveIntervalS) {
      t += driveIntervalS;
      final double sp = v + 3 * math.sin(e / 20);
      y += sp * driveIntervalS;
      out.add(_fix(base, t, x, y, sp, driveIntervalS));
    }
  }

  const int day = 86400;
  still(7 * 3600, 8);
  for (int d = 0; d < drives; d++) {
    drive(30 * 60, 17);
    still(4 * 3600, 8);
  }
  still(day - t > 0 ? day - t : 0, 8);
  return out;
}

Fix _fix(int base, int tSec, double x, double y, double speed, int interval) => Fix(
  tsUs: base + tSec * 1000000,
  lat: 40.0 + y / 111195,
  lon: -75.0 + x / (111195 * 0.766),
  speedMps: speed,
  accuracyM: 8,
  deviceId: 'bench',
);

void main() {
  test('benchmark: one week, 2 drives/day, 2 s while driving, 60 s idle', () {
    final List<Fix> fixes = <Fix>[
      for (int d = 0; d < 7; d++) ..._day(d, driveIntervalS: 2, idleIntervalS: 60),
    ];
    final TripSegmenter seg = TripSegmenter();
    final List<int> perFixNs = <int>[];
    int maxBuf = 0;
    final int rss0 = ProcessInfo.currentRss;
    int rssMax = rss0;
    final Stopwatch total = Stopwatch()..start();
    final Stopwatch sw = Stopwatch();
    for (final Fix f in fixes) {
      sw
        ..reset()
        ..start();
      seg.add(f);
      sw.stop();
      perFixNs.add(sw.elapsedMicroseconds);
      if (seg.bufferedFixes > maxBuf) maxBuf = seg.bufferedFixes;
    }
    final SegmentResult r = seg.finish();
    total.stop();
    rssMax = math.max(rssMax, ProcessInfo.currentRss);
    perFixNs.sort();
    // ignore: avoid_print
    print(
      'BENCH week: fixes=${fixes.length} trips=${r.trips.length} stops=${r.stops.length} '
      'total=${total.elapsedMilliseconds}ms '
      'mean=${(total.elapsedMicroseconds / fixes.length).toStringAsFixed(2)}us/fix '
      'p50=${perFixNs[perFixNs.length ~/ 2]}us p99=${perFixNs[(perFixNs.length * 0.99).floor()]}us '
      'max=${perFixNs.last}us maxBufferedFixes=$maxBuf rssDelta=${((rssMax - rss0) / 1024).round()}KiB',
    );
    expect(r.trips.where((ProcessedTrip t) => t.mode == kModeDriving).length, 14);
    expect(maxBuf, lessThan(3000), reason: 'buffer must stay bounded by the longest stop/trip');
  });

  test('benchmark: worst case 1 Hz for 24 h (86400 fixes), stationary + 2 drives', () {
    final List<Fix> fixes = _day(0, driveIntervalS: 1, idleIntervalS: 1);
    final TripSegmenter seg = TripSegmenter();
    int maxBuf = 0;
    final Stopwatch total = Stopwatch()..start();
    for (final Fix f in fixes) {
      seg.add(f);
      if (seg.bufferedFixes > maxBuf) maxBuf = seg.bufferedFixes;
    }
    final SegmentResult r = seg.finish();
    total.stop();
    // ignore: avoid_print
    print(
      'BENCH 1Hz-24h: fixes=${fixes.length} trips=${r.trips.length} total=${total.elapsedMilliseconds}ms '
      'mean=${(total.elapsedMicroseconds / fixes.length).toStringAsFixed(2)}us/fix maxBufferedFixes=$maxBuf',
    );
    expect(r.trips.length, 2);
    expect(maxBuf, lessThan(5000));
  });

  test('benchmark: weekly aggregation of 1000 trips + 3000 events', () {
    final List<TripSummary> trips = <TripSummary>[
      for (int i = 0; i < 1000; i++)
        TripSummary(
          startedAtUs: DateTime.utc(2026, 10, 19).microsecondsSinceEpoch + i * 600 * 1000000,
          endedAtUs: DateTime.utc(2026, 10, 19).microsecondsSinceEpoch + (i * 600 + 500) * 1000000,
          distanceM: 5000,
          maxSpeedMps: 25,
          mode: kModeDriving,
          id: '$i',
        ),
    ];
    final List<DrivingEvent> ev = <DrivingEvent>[
      for (int i = 0; i < 3000; i++)
        DrivingEvent(
          kind: kEventHardBrake,
          startedAtUs: DateTime.utc(2026, 10, 19).microsecondsSinceEpoch + i * 200 * 1000000,
          endedAtUs: 0,
          magnitude: 4,
          lat: 0,
          lon: 0,
        ),
    ];
    final ReportPeriod per = computeReportPeriod('week', '2026-10-19', 0, 0);
    final Stopwatch sw = Stopwatch()..start();
    final Map<String, dynamic> m = weeklyMemberJson(trips, ev, per);
    sw.stop();
    // ignore: avoid_print
    print('BENCH weekly aggregation: ${sw.elapsedMicroseconds}us');
    expect(m['current'], isNotNull);
  });
}
