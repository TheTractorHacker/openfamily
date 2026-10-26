import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/driving/driving_event.dart';
import 'package:openfamily/services/driving/motion_detector.dart';

import '../../support/drive_sim.dart';

/// Standard preamble: 4 s standing (gravity warm-up), gentle launch to ~15 m/s
/// (also teaches the forward axis), 10 s cruise.
void gentleStart(DriveSim sim) {
  sim.profile(<List<double>>[
    <double>[4, 0],
    <double>[10, 1.5],
    <double>[10, 0],
  ]);
}

void main() {
  late DrivingMotionDetector det;
  late DriveSim sim;

  setUp(() {
    det = DrivingMotionDetector();
    sim = DriveSim(det);
  });

  List<DrivingEvent> finish() => det.takeEvents(flush: true);

  test('smooth drive produces no events and learns the forward axis', () {
    gentleStart(sim);
    sim.profile(<List<double>>[
      <double>[8, -1.5],
      <double>[5, 0],
      <double>[3, 1.2],
      <double>[10, 0],
      <double>[6, -2.0],
    ]);
    expect(det.hasForwardAxis, isTrue);
    expect(finish(), isEmpty);
  });

  test('hard stop is reported once as hard_brake with GPS position', () {
    gentleStart(sim);
    sim.profile(<List<double>>[
      <double>[2.4, -5.0],
      <double>[1, -1.0],
      <double>[5, 0],
    ]);
    final List<DrivingEvent> ev = finish();
    expect(ev, hasLength(1));
    expect(ev.single.kind, DrivingEventKind.hardBrake);
    expect(ev.single.magnitude, inInclusiveRange(4.0, 5.6));
    expect(ev.single.lat, isNotNull);
    expect(ev.single.endedAtMs - ev.single.startedAtMs,
        inInclusiveRange(1500, 2600));
  });

  test('rapid launch from standstill is reported as rapid_accel', () {
    sim.profile(<List<double>>[
      <double>[4, 0],
      <double>[3, 4.2],
      <double>[10, 0],
    ]);
    final List<DrivingEvent> ev = finish();
    expect(ev, hasLength(1));
    expect(ev.single.kind, DrivingEventKind.rapidAccel);
    expect(ev.single.magnitude, inInclusiveRange(3.5, 4.8));
  });

  test('moderate braking below the threshold is not an event', () {
    gentleStart(sim);
    sim.profile(<List<double>>[
      <double>[4, -3.0],
      <double>[5, 0],
    ]);
    expect(finish(), isEmpty);
  });

  test('pothole spikes (short, mostly vertical) are not events', () {
    gentleStart(sim);
    for (int i = 0; i < 4; i++) {
      sim.run(3, extra: (double s) {
        final bool hit = s > 1.0 && s < 1.1;
        return hit ? <double>[5, 3, 28] : <double>[0, 0, 0];
      });
    }
    expect(finish(), isEmpty);
  });

  test('phone picked up and dropped is not an event', () {
    gentleStart(sim);
    final Rot start = sim.rot;
    final Rot tilted = Rot.euler(40, 70, 20);
    // Pick up: ~120 degrees over 0.7 s with a lift acceleration.
    sim.run(
      0.7,
      extra: (double s) => <double>[3, -2, 2],
      orient: (double s) => Rot.lerp(start, tilted, s / 0.7),
      gyro: (double s) => <double>[2.5, 1.5, 1.0],
    );
    sim.run(3);
    // Drop: huge short jolt with tumbling.
    sim.run(
      0.6,
      extra: (double s) =>
          s < 0.06 ? <double>[-25, 12, 18] : <double>[0, 0, 0],
      gyro: (double s) => <double>[6, -4, 5],
    );
    sim.run(6);
    expect(finish(), isEmpty);
  });

  test('pickup without gyro data is still not an event (tilt fallback)', () {
    gentleStart(sim);
    final Rot start = sim.rot;
    sim.run(
      0.8,
      extra: (double s) => <double>[3, -2, 0],
      orient: (double s) => Rot.lerp(start, Rot.euler(0, 75, 10), s / 0.8),
      gyro: (double s) => null, // device without a gyroscope
    );
    sim.run(8);
    expect(finish(), isEmpty);
  });

  for (final List<double> o in <List<double>>[
    <double>[0, 0, 0], // flat
    <double>[90, 35, 0], // mounted, portrait, tilted
    <double>[200, 70, 90], // landscape-ish, rotated
    <double>[0, 0, 180], // face down
    <double>[-50, -30, 140],
  ]) {
    test('orientation ${o.join('/')} still detects a hard stop', () {
      sim = DriveSim(det, rot: Rot.euler(o[0], o[1], o[2]));
      gentleStart(sim);
      sim.profile(<List<double>>[
        <double>[2.4, -5.0],
        <double>[1, -1.0],
        <double>[4, 0],
      ]);
      final List<DrivingEvent> ev = finish();
      expect(ev, hasLength(1));
      expect(ev.single.kind, DrivingEventKind.hardBrake);
      expect(ev.single.magnitude, inInclusiveRange(3.8, 5.8));
    });
  }

  test('stop-and-go traffic has no events; the one hard stop is found', () {
    gentleStart(sim);
    for (int i = 0; i < 4; i++) {
      sim.profile(<List<double>>[
        <double>[3, -2.0],
        <double>[2, 0],
        <double>[3, 1.2],
      ]);
    }
    sim.profile(<List<double>>[
      <double>[5, 0],
      <double>[3.2, -4.5],
      <double>[5, 0],
    ]);
    final List<DrivingEvent> ev = finish();
    expect(ev, hasLength(1));
    expect(ev.single.kind, DrivingEventKind.hardBrake);
  });

  test('crawling below the speed gate never counts', () {
    sim.profile(<List<double>>[
      <double>[4, 0],
      <double>[1.5, 2.6], // up to ~3.9 m/s with 2.6 m/s^2... below threshold
      <double>[4, 0],
      <double>[1.0, -3.9],
      <double>[4, 0],
    ]);
    expect(finish(), isEmpty);
  });

  test('two pulses of the same braking are merged into one event', () {
    gentleStart(sim);
    sim.profile(<List<double>>[
      <double>[1.0, -4.5],
      <double>[0.5, 0],
      <double>[1.0, -4.5],
      <double>[4, 0],
    ]);
    final List<DrivingEvent> ev = finish();
    expect(ev, hasLength(1));
    expect(ev.single.kind, DrivingEventKind.hardBrake);
  });

  test('an accelerating trace never yields braking and vice versa', () {
    gentleStart(sim);
    sim.profile(<List<double>>[
      <double>[2.0, 4.5],
      <double>[3, 0],
      <double>[2.0, -4.5],
      <double>[3, 0],
    ]);
    final List<DrivingEvent> ev = finish();
    expect(ev.map((DrivingEvent e) => e.kind).toList(), <DrivingEventKind>[
      DrivingEventKind.rapidAccel,
      DrivingEventKind.hardBrake,
    ]);
  });
}
