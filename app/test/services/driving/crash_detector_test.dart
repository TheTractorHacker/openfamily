import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/driving/crash_detector.dart';

const double g = 9.80665;

/// Feeds a synthetic trace: 50 Hz accelerometer (resting 1 g on z) with
/// [spikes] (time ms -> g) and 1 Hz GPS from [speed] (second -> m/s).
CrashSignal? run({
  required Map<int, double> spikes,
  required double Function(int sec) speed,
  int seconds = 40,
  CrashDetector? detector,
}) {
  final CrashDetector d = detector ?? CrashDetector();
  CrashSignal? found;
  for (int ms = 0; ms <= seconds * 1000; ms += 20) {
    if (ms % 1000 == 0) {
      d.onGps(ms, speed(ms ~/ 1000), 52.0, 4.0);
    }
    final double sg = spikes[ms] ?? 1.0;
    d.onAccel(ms, 0.2, 0.1, sg * g);
    if (ms % 1000 == 500) d.tick(ms);
    found ??= d.takeSignal();
  }
  return found;
}

void main() {
  group('crash', () {
    test('big spike then sudden stop from 60 km/h is detected', () {
      final CrashSignal? s = run(
        spikes: <int, double>{20000: 9.0, 20020: 6.0},
        // 60 km/h until 20 s, stopped from 21 s.
        speed: (int t) => t <= 20 ? 16.7 : 0.0,
      );
      expect(s, isNotNull);
      expect(s!.peakG, closeTo(9.0, 0.01));
      expect(s.speedBeforeMps, closeTo(16.7, 0.01));
      expect(s.speedAfterMps, lessThan(2.0));
      expect(s.lat, 52.0);
    });

    test('spike and drop to 3 m/s then 0 within a few seconds is detected',
        () {
      final CrashSignal? s = run(
        spikes: <int, double>{20000: 5.0},
        speed: (int t) => t <= 20 ? 14.0 : (t == 21 ? 1.5 : 0.0),
      );
      expect(s, isNotNull);
    });

    test('reported only once (cooldown)', () {
      final CrashDetector d = CrashDetector();
      int n = 0;
      for (int ms = 0; ms <= 60000; ms += 20) {
        if (ms % 1000 == 0) {
          d.onGps(ms, ms <= 20000 ? 16.0 : 0.0, 52, 4);
        }
        d.onAccel(ms, 0, 0, ((ms == 20000 || ms == 40000) ? 8.0 : 1.0) * g);
        if (ms % 1000 == 500) d.tick(ms);
        if (d.takeSignal() != null) n++;
      }
      expect(n, 1);
    });
  });

  group('must not trigger', () {
    test('pothole at speed (spike, speed unchanged)', () {
      expect(
        run(
          spikes: <int, double>{20000: 6.0, 20040: 5.0},
          speed: (int t) => 16.0,
        ),
        isNull,
      );
    });

    test('phone dropped while driving (spike, speed unchanged)', () {
      expect(
        run(
          spikes: <int, double>{15000: 12.0},
          speed: (int t) => 20.0,
        ),
        isNull,
      );
    });

    test('phone dropped while parked', () {
      expect(
        run(spikes: <int, double>{15000: 10.0}, speed: (int t) => 0.0),
        isNull,
      );
    });

    test('phone dropped at walking pace', () {
      expect(
        run(spikes: <int, double>{15000: 10.0}, speed: (int t) => 1.4),
        isNull,
      );
    });

    test('hard braking to a stop (no spike)', () {
      // 100 km/h to 0 in 3 s is ~0.95 g: far below the impact threshold.
      expect(
        run(
          spikes: <int, double>{for (int ms = 20000; ms < 23000; ms += 20) ms: 1.4},
          speed: (int t) => t < 20 ? 27.0 : (t == 20 ? 18.0 : (t == 21 ? 9.0 : 0.0)),
        ),
        isNull,
      );
    });

    test('phone dropped after having already stopped', () {
      expect(
        run(
          // Stopped at 12 s, phone falls off the dash at 20 s.
          spikes: <int, double>{20000: 9.0},
          speed: (int t) => t < 10 ? 15.0 : 0.0,
        ),
        isNull,
      );
    });

    test('spike then speed keeps going above the hold level', () {
      expect(
        run(
          spikes: <int, double>{20000: 7.0},
          // Brief dip to 1 m/s (GPS glitch) then back to 15 m/s.
          speed: (int t) => t == 21 ? 1.0 : (t < 21 ? 15.0 : 15.0),
        ),
        isNull,
      );
    });

    test('collision-like spike but car slows only to 10 m/s', () {
      expect(
        run(
          spikes: <int, double>{20000: 7.0},
          speed: (int t) => t <= 20 ? 20.0 : 10.0,
        ),
        isNull,
      );
    });

    test('below the speed threshold (20 km/h) does not trigger', () {
      expect(
        run(
          spikes: <int, double>{20000: 8.0},
          speed: (int t) => t <= 20 ? 5.5 : 0.0,
        ),
        isNull,
      );
    });

    test('stale GPS before the spike does not count as driving', () {
      final CrashDetector d = CrashDetector();
      d.onGps(0, 20.0, 52, 4);
      d.onAccel(10000, 0, 0, 9 * g); // last fix 10 s old
      for (int t = 11000; t < 20000; t += 1000) {
        d.onGps(t, 0, 52, 4);
        d.tick(t);
      }
      expect(d.takeSignal(), isNull);
    });

    test('a spike just below the threshold is ignored', () {
      expect(
        run(
          spikes: <int, double>{20000: 3.9},
          speed: (int t) => t <= 20 ? 16.7 : 0.0,
        ),
        isNull,
      );
    });
  });

  test('reset clears a pending candidate', () {
    final CrashDetector d = CrashDetector();
    d.onGps(0, 20.0, 52, 4);
    d.onAccel(500, 0, 0, 9 * g);
    d.reset();
    d.onGps(1500, 0, 52, 4);
    d.tick(10000);
    expect(d.takeSignal(), isNull);
  });
}
