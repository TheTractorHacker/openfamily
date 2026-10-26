import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:openfamily/services/marker_motion.dart';

const Distance _d = Distance(roundResult: false);
final DateTime _t0 = DateTime.utc(2026, 1, 1, 12);
const LatLng _start = LatLng(40.0, -100.0);

DateTime at(double s) =>
    _t0.add(Duration(microseconds: (s * 1e6).round()));

/// A fix [s] seconds after t0, [meters] east of the start.
TrackFix eastFix(double s, double meters,
        {double? speed = 20, double? heading = 90, double? acc = 5}) =>
    TrackFix(
      position: _d.offset(_start, meters, 90),
      ts: at(s),
      speedMps: speed,
      headingDeg: heading,
      accuracyM: acc,
    );

double meters(LatLng a, LatLng b) => _d.as(LengthUnit.Meter, a, b);

/// East-west coordinate of [p] in metres from the start.
double eastOf(LatLng p) {
  final double sign = p.longitude >= _start.longitude ? 1 : -1;
  return sign * meters(LatLng(_start.latitude, _start.longitude),
      LatLng(_start.latitude, p.longitude));
}

void main() {
  group('steady 1 Hz drive', () {
    test('moves continuously with a bounded per-frame step', () {
      final MarkerMotion m = MarkerMotion();
      const double v = 20; // m/s east
      double? prevEast;
      double maxStep = 0;
      double minStepAfterWarmup = double.infinity;
      int frames = 0;
      for (int f = 0; f <= 30 * 60; f++) {
        final double t = f / 60.0;
        // A fix arrives on every whole second.
        if (f % 60 == 0) {
          m.addFix(eastFix(t, v * t), now: at(t));
        }
        final MotionSample s = m.sample(at(t));
        final double e = eastOf(s.position);
        if (prevEast != null) {
          final double step = e - prevEast;
          expect(step, greaterThanOrEqualTo(-1e-6), reason: 'never backwards');
          if (t > 2) {
            maxStep = step > maxStep ? step : maxStep;
            minStepAfterWarmup =
                step < minStepAfterWarmup ? step : minStepAfterWarmup;
          }
        }
        prevEast = e;
        frames++;
      }
      // 20 m/s at 60 fps is 0.333 m per frame.
      expect(maxStep, lessThan(0.45));
      expect(minStepAfterWarmup, greaterThan(0.2),
          reason: 'no stalls between fixes');
      expect(frames, greaterThan(1800));
    });

    test('renders about one fix behind real time, never ahead', () {
      final MarkerMotion m = MarkerMotion();
      for (int s = 0; s <= 10; s++) {
        m.addFix(eastFix(s.toDouble(), 20.0 * s), now: at(s.toDouble()));
        final MotionSample smp = m.sample(at(s.toDouble()));
        final double truth = 20.0 * s;
        expect(eastOf(smp.position), lessThanOrEqualTo(truth + 0.5));
        expect(eastOf(smp.position), greaterThan(truth - 45));
      }
    });
  });

  group('late and out-of-order fixes', () {
    test('coasts along the heading for at most ~3 s, then holds', () {
      final MarkerMotion m = MarkerMotion();
      for (int s = 0; s <= 5; s++) {
        m.addFix(eastFix(s.toDouble(), 20.0 * s), now: at(s.toDouble()));
        for (int f = 0; f < 60; f++) {
          m.sample(at(s + f / 60));
        }
      }
      // Last fix at t=5 (100 m). No more fixes. Sample past the glide.
      final double lastTruth = 100;
      double prev = eastOf(m.sample(at(6.0)).position);
      double e6 = prev;
      for (double t = 6.0; t < 14; t += 1 / 60) {
        final double e = eastOf(m.sample(at(t)).position);
        expect(e, greaterThanOrEqualTo(prev - 1e-3));
        prev = e;
      }
      final double held = prev;
      // Coasts forward some, but never beyond 3 s of travel past the fix.
      expect(held, greaterThan(e6 - 1e-6));
      expect(held, lessThanOrEqualTo(lastTruth + 20 * 3 + 1));
      // And is completely still afterwards.
      final double later = eastOf(m.sample(at(30)).position);
      expect(later, closeTo(held, 1e-6));
      expect(m.sample(at(30)).animating, isFalse);
    });

    test('a fix behind the coasting pin never drags it backwards', () {
      final MarkerMotion m = MarkerMotion();
      for (int s = 0; s <= 4; s++) {
        m.addFix(eastFix(s.toDouble(), 20.0 * s), now: at(s.toDouble()));
        for (int f = 0; f < 60; f++) {
          m.sample(at(s + f / 60));
        }
      }
      // Fix 5 arrives 2.5 s late but real position is only a bit ahead.
      double prev = eastOf(m.sample(at(6.5)).position);
      m.addFix(eastFix(5, 100), now: at(6.5));
      for (double t = 6.5; t < 12; t += 1 / 60) {
        final double e = eastOf(m.sample(at(t)).position);
        expect(e, greaterThanOrEqualTo(prev - 1e-3));
        prev = e;
      }
    });

    test('out-of-order and duplicate fixes are ignored', () {
      final MarkerMotion m = MarkerMotion();
      expect(m.addFix(eastFix(10, 200), now: at(10)), isTrue);
      expect(m.addFix(eastFix(11, 220), now: at(11)), isTrue);
      expect(m.addFix(eastFix(9, 180), now: at(11.1)), isFalse);
      expect(m.addFix(eastFix(11, 500), now: at(11.2)), isFalse);
      expect(m.lastFix!.ts, at(11));
      final MotionSample s = m.sample(at(12.5));
      expect(eastOf(s.position), closeTo(220, 25));
    });
  });

  group('teleport', () {
    test('a jump over 500 m snaps with no animation', () {
      final MarkerMotion m = MarkerMotion();
      m.addFix(eastFix(0, 0), now: at(0));
      m.addFix(eastFix(1, 20), now: at(1));
      final TrackFix far = eastFix(2, 2500);
      m.addFix(far, now: at(2));
      final MotionSample s = m.sample(at(2));
      expect(meters(s.position, far.position), lessThan(1));
    });

    test('a gap over 2 minutes snaps even for a short hop', () {
      final MarkerMotion m = MarkerMotion();
      m.addFix(eastFix(0, 0, speed: 0), now: at(0));
      final TrackFix later = eastFix(150, 80, speed: 0, acc: 5);
      m.addFix(later, now: at(150));
      expect(meters(m.sample(at(150)).position, later.position), lessThan(1));
    });
  });

  group('stationary jitter', () {
    test('fixes inside the accuracy circle do not move a parked pin', () {
      final MarkerMotion m = MarkerMotion();
      m.addFix(eastFix(0, 0, speed: 0, heading: null, acc: 15), now: at(0));
      final LatLng home = m.sample(at(0)).position;
      final List<double> wobble = <double>[6, -7, 9, -4, 11, -10, 5];
      for (int i = 0; i < wobble.length; i++) {
        final double t = 1.0 + i * 5;
        m.addFix(eastFix(t, wobble[i], speed: 0.1, heading: null, acc: 15),
            now: at(t));
        for (int f = 0; f < 30; f++) {
          final MotionSample s = m.sample(at(t + f / 60));
          expect(meters(s.position, home), lessThan(0.01));
        }
      }
    });

    test('a stationary fix outside the accuracy circle does move it', () {
      final MarkerMotion m = MarkerMotion();
      m.addFix(eastFix(0, 0, speed: 0, heading: null, acc: 10), now: at(0));
      m.addFix(eastFix(5, 60, speed: 0, heading: null, acc: 10), now: at(5));
      final MotionSample s = m.sample(at(8));
      expect(eastOf(s.position), closeTo(60, 1));
    });
  });

  group('heading', () {
    test('359 -> 1 takes the short arc, never swinging through 180', () {
      final MarkerMotion m = MarkerMotion();
      m.addFix(eastFix(0, 0, speed: 10, heading: 359), now: at(0));
      m.sample(at(0));
      m.addFix(eastFix(1, 10, speed: 10, heading: 1), now: at(1));
      double? last;
      for (double t = 1; t < 3; t += 1 / 60) {
        final double h = m.sample(at(t)).headingDeg!;
        // Stays within the 359..360 / 0..1 neighbourhood.
        final double fromNorth = h > 180 ? 360 - h : h;
        expect(fromNorth, lessThan(2.0), reason: 'heading $h');
        last = h;
      }
      final double fromNorth = last! > 180 ? 360 - last : last;
      expect(fromNorth, lessThan(1.5));
    });

    test('heading is held, not zeroed, when the fix stops reporting it', () {
      final MarkerMotion m = MarkerMotion();
      m.addFix(eastFix(0, 0, speed: 10, heading: 90), now: at(0));
      m.addFix(eastFix(1, 10, speed: 0, heading: null), now: at(1));
      for (double t = 1; t < 4; t += 0.1) {
        expect(m.sample(at(t)).headingDeg, closeTo(90, 1));
      }
    });
  });

  group('speed', () {
    test('rises quickly toward the newest speed and never overshoots it', () {
      final MarkerMotion m = MarkerMotion();
      m.addFix(eastFix(0, 0, speed: 5), now: at(0));
      m.addFix(eastFix(1, 5, speed: 15), now: at(1));
      final double? s = m.speedAt(at(1));
      expect(s, greaterThan(12));
      expect(s, lessThanOrEqualTo(15));
    });

    test('falls gently and equals the fix once settled', () {
      final MarkerMotion m = MarkerMotion();
      for (int i = 0; i < 6; i++) {
        m.addFix(eastFix(i.toDouble(), 20.0 * i, speed: 20), now: at(i.toDouble()));
      }
      m.addFix(eastFix(6, 120, speed: 10), now: at(6));
      final double s = m.speedAt(at(6))!;
      expect(s, inExclusiveRange(10, 20));
      for (int i = 7; i < 14; i++) {
        m.addFix(eastFix(i.toDouble(), 120 + 10.0 * (i - 6), speed: 10),
            now: at(i.toDouble()));
      }
      expect(m.speedAt(at(13)), closeTo(10, 0.01));
    });

    test('below 0.5 m/s is exactly 0, and 0 is a value, not unknown', () {
      final MarkerMotion m = MarkerMotion();
      m.addFix(eastFix(0, 0, speed: 12), now: at(0));
      m.addFix(eastFix(1, 12, speed: 0.3), now: at(1));
      expect(m.speedAt(at(1)), 0);
      expect(m.speedAt(at(1)), isNotNull);
    });

    test('goes to 0 when the newest fix is older than 15 s', () {
      final MarkerMotion m = MarkerMotion();
      m.addFix(eastFix(0, 0, speed: 20), now: at(0));
      m.addFix(eastFix(1, 20, speed: 20), now: at(1));
      expect(m.speedAt(at(10)), greaterThan(15));
      expect(m.speedAt(at(17)), 0);
    });

    test('unknown speed stays null', () {
      final MarkerMotion m = MarkerMotion();
      m.addFix(eastFix(0, 0, speed: null), now: at(0));
      expect(m.speedAt(at(0)), isNull);
    });

    test('an old fix on first load does not show its stale speed', () {
      final MarkerMotion m = MarkerMotion();
      m.addFix(eastFix(0, 0, speed: 25), now: at(600));
      expect(m.speedAt(at(600)), 0);
    });
  });
}
