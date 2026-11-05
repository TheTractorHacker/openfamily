import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/driving/handling_analyzer.dart';

/// 50 Hz synthetic phone motion. Gravity points along device -z (lying flat /
/// held upright is not modelled separately: only relative motion matters).
class _Feed {
  _Feed(this.a);
  final HandlingAnalyzer a;
  int t = 1000000;
  int _seed = 7;

  double noise() {
    _seed = (_seed * 1103515245 + 12345) & 0x7fffffff;
    return (_seed / 0x7fffffff) * 2 - 1;
  }

  /// [accelNoise] is road vibration amplitude (m/s^2); [yaw] a constant turn
  /// rate about the vertical axis; [tilt] gives rotation about horizontal
  /// axes (rad/s) at time s; [jostle] extra accelerometer motion (m/s^2).
  void run(
    double seconds, {
    double accelNoise = 0.3,
    double yaw = 0,
    double Function(double s)? tilt,
    double Function(double s)? jostle,
    bool gyro = true,
  }) {
    final int n = (seconds * 50).round();
    for (int i = 0; i < n; i++) {
      final double s = i / 50.0;
      final double j = jostle?.call(s) ?? 0;
      a.onAccel(t, noise() * accelNoise + j, noise() * accelNoise,
          9.81 + noise() * accelNoise + j * 0.5);
      if (gyro) {
        final double w = tilt?.call(s) ?? 0;
        a.onGyro(t, w * 0.8 + noise() * 0.02, w * 0.6 + noise() * 0.02,
            yaw + noise() * 0.02);
      }
      t += 20;
    }
  }
}

void main() {
  late List<HandlingWindow> out;
  late HandlingAnalyzer an;
  late _Feed f;
  setUp(() {
    out = <HandlingWindow>[];
    an = HandlingAnalyzer(onWindow: out.add)..setActive(true);
    f = _Feed(an);
  });

  test('a phone lying still or rigidly mounted is not handled', () {
    f.run(20, accelNoise: 0.05);
    expect(out.length, greaterThanOrEqualTo(8));
    expect(out.every((HandlingWindow w) => !w.handled), isTrue);
    expect(out.every((HandlingWindow w) => w.score < 0.3), isTrue);
  });

  test('road vibration plus a long turn (yaw) on a mount is not handled', () {
    f.run(20, accelNoise: 0.5, yaw: 0.6);
    expect(out.every((HandlingWindow w) => !w.handled), isTrue);
  });

  test('picking up and tilting the phone is handled', () {
    f.run(4, accelNoise: 0.1);
    out.clear();
    f.run(10,
        accelNoise: 0.2,
        tilt: (double s) => 1.2 * math.sin(s * 5),
        jostle: (double s) => 1.5 * math.sin(s * 7));
    expect(out.length, greaterThan(3));
    // The first window may straddle the quiet period before.
    out.removeAt(0);
    expect(out.every((HandlingWindow w) => w.handled), isTrue);
    expect(out.first.tiltRateRadPerSec, greaterThan(0.35));
  });

  test('a single pothole is not handling', () {
    f.run(3);
    out.clear();
    // 0.1 s spike of 12 m/s^2 inside otherwise calm data.
    f.run(2.0, jostle: (double s) => (s > 0.5 && s < 0.6) ? 12 : 0);
    f.run(4);
    expect(out.where((HandlingWindow w) => w.handled), isEmpty);
  });

  test('phones without a gyroscope fall back to the accelerometer', () {
    f.run(8, accelNoise: 0.3, gyro: false);
    expect(out.every((HandlingWindow w) => !w.handled && !w.hasGyro), isTrue);
    out.clear();
    f.run(8,
        accelNoise: 0.3,
        gyro: false,
        jostle: (double s) => 12 * math.sin(s * 9));
    out.removeAt(0);
    expect(out.every((HandlingWindow w) => w.handled), isTrue);
  });

  test('nothing is computed or emitted while inactive; reactivation is fresh',
      () {
    an.setActive(false);
    f.run(10, tilt: (double s) => 2);
    expect(out, isEmpty);
    an.setActive(true);
    f.run(5, accelNoise: 0.05);
    expect(out, isNotEmpty);
    expect(out.every((HandlingWindow w) => !w.handled), isTrue);
  });

  test('a long gap in the data discards the stale window', () {
    f.run(1.5);
    f.t += 60000; // sensors went away
    f.run(1.0);
    expect(out, isEmpty);
  });
}
