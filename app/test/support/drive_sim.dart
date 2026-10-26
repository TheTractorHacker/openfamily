import 'dart:math' as math;

import 'package:openfamily/services/driving/motion_detector.dart';

/// 3x3 rotation, device -> world (columns are device axes in world coords).
class Rot {
  const Rot(this.m);
  final List<List<double>> m;

  static const Rot identity = Rot(<List<double>>[
    <double>[1, 0, 0],
    <double>[0, 1, 0],
    <double>[0, 0, 1],
  ]);

  /// Z-Y-X Euler (yaw, pitch, roll) in degrees.
  factory Rot.euler(double yawDeg, double pitchDeg, double rollDeg) {
    final double y = yawDeg * math.pi / 180;
    final double p = pitchDeg * math.pi / 180;
    final double r = rollDeg * math.pi / 180;
    final double cy = math.cos(y), sy = math.sin(y);
    final double cp = math.cos(p), sp = math.sin(p);
    final double cr = math.cos(r), sr = math.sin(r);
    return Rot(<List<double>>[
      <double>[cy * cp, cy * sp * sr - sy * cr, cy * sp * cr + sy * sr],
      <double>[sy * cp, sy * sp * sr + cy * cr, sy * sp * cr - cy * sr],
      <double>[-sp, cp * sr, cp * cr],
    ]);
  }

  /// R^T * v (world -> device).
  List<double> toDevice(List<double> v) => <double>[
        m[0][0] * v[0] + m[1][0] * v[1] + m[2][0] * v[2],
        m[0][1] * v[0] + m[1][1] * v[1] + m[2][1] * v[2],
        m[0][2] * v[0] + m[1][2] * v[1] + m[2][2] * v[2],
      ];

  static Rot lerp(Rot a, Rot b, double k) {
    // Component-wise blend is fine for a test trace (gravity stays ~9.8).
    return Rot(<List<double>>[
      for (int i = 0; i < 3; i++)
        <double>[
          for (int j = 0; j < 3; j++) a.m[i][j] * (1 - k) + b.m[i][j] * k,
        ],
    ]);
  }
}

/// Deterministic synthetic car + phone simulator feeding a detector at 50 Hz
/// (accelerometer + gyroscope) and 1 Hz (GPS).
class DriveSim {
  DriveSim(this.det, {this.heading = 0.7, this.rot = Rot.identity});

  final DrivingMotionDetector det;
  final double heading; // rad, world frame
  Rot rot;

  int t = 1700000000000;
  double speed = 0;
  double tSec = 0;
  int _nextFix = 0;
  int _seed = 12345;
  double lat = 48.0;
  double lon = 11.0;

  double _noise() {
    _seed = (_seed * 1103515245 + 12345) & 0x7fffffff;
    return (_seed / 0x7fffffff) * 2 - 1; // [-1, 1]
  }

  /// Runs [seconds]. [accel] is the forward acceleration (m/s^2) as a function
  /// of seconds since this call's start. [extra] adds a world-frame
  /// acceleration (potholes, lifts); [orient] overrides the phone rotation;
  /// [gyro] gives device-frame angular rate (rad/s).
  void run(
    double seconds, {
    double Function(double s)? accel,
    List<double> Function(double s)? extra,
    Rot Function(double s)? orient,
    List<double>? Function(double s)? gyro,
  }) {
    const int stepMs = 20;
    final int n = (seconds * 1000 / stepMs).round();
    final double fx = math.cos(heading), fy = math.sin(heading);
    for (int i = 0; i < n; i++) {
      final double s = i * stepMs / 1000.0;
      final double a = accel == null ? 0 : accel(s);
      speed = math.max(0, speed + a * stepMs / 1000.0);
      lat += fy * speed * stepMs / 1000.0 / 111000;
      lon += fx * speed * stepMs / 1000.0 / 74000;
      final List<double> ex = extra == null ? <double>[0, 0, 0] : extra(s);
      if (orient != null) rot = orient(s);
      final double vib = 0.35 * math.sin(2 * math.pi * 17 * tSec);
      final List<double> world = <double>[
        fx * a + ex[0] + 0.1 * _noise(),
        fy * a + ex[1] + 0.1 * _noise(),
        9.81 + ex[2] + vib,
      ];
      final List<double> d = rot.toDevice(world);
      det.onAccel(t, d[0] + 0.12 * _noise(), d[1] + 0.12 * _noise(),
          d[2] + 0.12 * _noise());
      final List<double>? w = gyro == null
          ? <double>[0.02 * _noise(), 0.02 * _noise(), 0.02 * _noise()]
          : gyro(s);
      if (w != null) det.onGyro(t, w[0], w[1], w[2]);
      if (t >= _nextFix) {
        det.onGps(t, math.max(0, speed + 0.08 * _noise()), lat, lon);
        _nextFix = t + 1000;
      }
      t += stepMs;
      tSec += stepMs / 1000.0;
    }
  }

  /// Piecewise-constant acceleration profile: [(seconds, accel), ...].
  void profile(List<List<double>> phases,
      {Rot Function(double s)? orient}) {
    for (final List<double> p in phases) {
      run(p[0], accel: (_) => p[1], orient: orient);
    }
  }
}
