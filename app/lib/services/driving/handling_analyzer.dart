import 'dart:math' as math;

import 'driving_config.dart';

/// Verdict for one analysis window of motion-sensor data.
class HandlingWindow {
  const HandlingWindow({
    required this.startMs,
    required this.endMs,
    required this.score,
    required this.handled,
    this.tiltRateRadPerSec = 0,
    this.accelStd = 0,
    this.hasGyro = true,
  });

  final int startMs;
  final int endMs;

  /// 0 = rigid/still, 1 = the handling threshold, above = clearly in a hand.
  final double score;
  final bool handled;

  /// RMS rotation rate about axes other than the vertical one (rad/s).
  final double tiltRateRadPerSec;

  /// Std-dev of the accelerometer magnitude (m/s^2).
  final double accelStd;
  final bool hasGyro;

  @override
  String toString() =>
      'HandlingWindow($startMs..$endMs score=${score.toStringAsFixed(2)} handled=$handled)';
}

/// Decides whether the phone is being physically handled (picked up, tilted,
/// jostled in a hand) versus lying still or rigidly mounted in a vehicle.
///
/// Pure and deterministic: feed it timestamped accelerometer / gyroscope
/// samples (the driving feed already samples them while a drive is active).
/// Samples are reduced to one verdict per [PhoneUseConfig.windowMs]; raw
/// samples are never stored.
///
/// Vehicle influence is reduced by (a) removing the rotation about the gravity
/// axis (a car turning yaws a mounted phone but does not tilt it) and (b)
/// requiring accelerometer deviation to be corroborated by rotation, so a
/// pothole alone is not "handling". Thresholds are unvalidated guesses.
///
/// Call [setActive] to gate processing: it should be on only while the screen
/// is lit or a call is active, so nothing is computed otherwise.
class HandlingAnalyzer {
  HandlingAnalyzer({
    this.config = const PhoneUseConfig(),
    this.onWindow,
  });

  final PhoneUseConfig config;
  final void Function(HandlingWindow w)? onWindow;

  bool _active = false;
  bool get active => _active;

  // Window accumulators.
  int? _winStart;
  int _accN = 0;
  double _accSum = 0, _accSumSq = 0;
  int _gyroN = 0;
  double _tiltSumSq = 0;

  // Running gravity direction estimate (low-pass of accelerometer).
  double _gx = 0, _gy = 0, _gz = 0;
  bool _gravityKnown = false;
  int _lastAccT = 0;

  /// Turns analysis on/off. Turning on starts fresh windows.
  void setActive(bool on) {
    if (on == _active) return;
    _active = on;
    _resetWindow();
    _gravityKnown = false;
  }

  void _resetWindow() {
    _winStart = null;
    _accN = 0;
    _accSum = 0;
    _accSumSq = 0;
    _gyroN = 0;
    _tiltSumSq = 0;
  }

  void onAccel(int tMs, double x, double y, double z) {
    if (!_active) return;
    if (!_gravityKnown) {
      _gx = x;
      _gy = y;
      _gz = z;
      _gravityKnown = true;
    } else {
      final double dt = math.max(1, tMs - _lastAccT).toDouble();
      final double k = dt / (config.gravityTauMs + dt);
      _gx += k * (x - _gx);
      _gy += k * (y - _gy);
      _gz += k * (z - _gz);
    }
    _lastAccT = tMs;
    _touch(tMs);
    final double m = math.sqrt(x * x + y * y + z * z);
    _accN++;
    _accSum += m;
    _accSumSq += m * m;
  }

  void onGyro(int tMs, double x, double y, double z) {
    if (!_active || !_gravityKnown) return;
    _touch(tMs);
    final double gm = math.sqrt(_gx * _gx + _gy * _gy + _gz * _gz);
    if (gm < 1e-6) return;
    final double ux = _gx / gm, uy = _gy / gm, uz = _gz / gm;
    final double along = x * ux + y * uy + z * uz; // yaw component
    final double hx = x - along * ux;
    final double hy = y - along * uy;
    final double hz = z - along * uz;
    _gyroN++;
    _tiltSumSq += hx * hx + hy * hy + hz * hz;
  }

  /// Opens a window on the first sample and closes finished ones. A long gap
  /// in the data discards the stale window instead of judging it.
  void _touch(int tMs) {
    final int? s = _winStart;
    if (s == null) {
      _winStart = tMs;
      return;
    }
    if (tMs - s >= config.windowMs * 3) {
      _resetWindow();
      _winStart = tMs;
      return;
    }
    if (tMs - s >= config.windowMs) {
      _close(s, tMs);
      _resetWindow();
      _winStart = tMs;
    }
  }

  void _close(int start, int end) {
    if (_accN < 5) return; // too little data to judge
    final double mean = _accSum / _accN;
    final double variance =
        math.max(0.0, _accSumSq / _accN - mean * mean);
    final double accStd = math.sqrt(variance);
    final bool hasGyro = _gyroN >= 5;
    final double tilt = hasGyro ? math.sqrt(_tiltSumSq / _gyroN) : 0;
    final double score;
    if (hasGyro) {
      final double strong = tilt / config.tiltRateRadPerSec;
      final double combined = math.min(
        tilt / config.tiltRateWeakRadPerSec,
        accStd / config.accelStdMps2,
      );
      score = math.max(strong, combined);
    } else {
      score = accStd / config.noGyroAccelStdMps2;
    }
    final HandlingWindow w = HandlingWindow(
      startMs: start,
      endMs: end,
      score: score,
      handled: score >= 1.0,
      tiltRateRadPerSec: tilt,
      accelStd: accStd,
      hasGyro: hasGyro,
    );
    onWindow?.call(w);
  }
}
