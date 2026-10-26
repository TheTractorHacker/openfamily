import 'dart:collection';
import 'dart:math' as math;

import 'driving_config.dart';
import 'driving_event.dart';

/// Pure-Dart hard-brake / rapid-acceleration detector working on raw
/// accelerometer (including gravity) and gyroscope samples plus 1 Hz GPS fixes.
///
/// Pipeline (all on the device, nothing here ever leaves the phone):
///  1. Gravity estimate: low-pass of the accelerometer, aided by the gyroscope
///     (the vector is rotated with the phone) so real braking does not leak
///     into "gravity". Linear acceleration = sample - gravity.
///  2. Horizontal projection onto the plane perpendicular to gravity.
///  3. Forward axis: learned from the car itself. During intervals where the
///     GPS speed changes by >= [DrivingConfig.axisMinAccelMps2] the mean
///     horizontal acceleration is voted along the sign of the speed change; the
///     weighted sum points forward. The axis is only trusted when the votes
///     agree (coherence) and is dropped when the phone is tilted or handled.
///  4. Signed forward acceleration is smoothed and run through a hysteresis
///     episode detector (>= threshold for >= [DrivingConfig.minDurationMs]).
///  5. Each candidate is cross-checked against the GPS speed change over the
///     event (right sign, plausible size) and the GPS speed gate; handling
///     jolts (gyro spikes, huge horizontal acceleration) discard candidates.
///  6. Same-kind events closer than [DrivingConfig.mergeGapMs] are merged.
///
/// All timestamps are epoch milliseconds from one consistent clock.
class DrivingMotionDetector {
  DrivingMotionDetector({this.config = const DrivingConfig()});

  final DrivingConfig config;

  // Gravity state.
  _V? _g;
  int _firstT = 0;
  int _lastT = 0;
  int _lastGyroT = -1000000;
  int _handlingUntil = -1;
  final List<int> _handlingTimes = <int>[];

  // Forward axis learning.
  bool _axisValid = false;
  _V _axis = const _V(0, 0, 0);
  _V? _axisGravity;
  _V _voteSum = const _V(0, 0, 0);
  double _voteAbs = 0;
  int _voteN = 0;
  _V _intervalSum = const _V(0, 0, 0);
  int _intervalN = 0;
  bool _intervalHandled = false;

  // Sample history for replay once the axis becomes known.
  final Queue<_S> _buffer = Queue<_S>();

  // GPS history.
  final List<_Fix> _fixes = <_Fix>[];

  // Episode detection.
  double _smooth = 0;
  final _Episode _accelEp = _Episode(1);
  final _Episode _brakeEp = _Episode(-1);
  final List<_Cand> _pending = <_Cand>[];
  final Map<DrivingEventKind, DrivingEvent> _held =
      <DrivingEventKind, DrivingEvent>{};
  final List<DrivingEvent> _out = <DrivingEvent>[];
  final Map<DrivingEventKind, int> _doneEnd = <DrivingEventKind, int>{};

  /// Whether a trusted forward axis is currently known.
  bool get hasForwardAxis => _axisValid;

  /// Clears all state (call when a driving session starts).
  void reset() {
    _g = null;
    _lastT = 0;
    _lastGyroT = -1000000;
    _handlingUntil = -1;
    _handlingTimes.clear();
    _invalidateAxis();
    _fixes.clear();
    _pending.clear();
    _held.clear();
    _out.clear();
    _doneEnd.clear();
    _resetEpisodes();
  }

  void _invalidateAxis() {
    _axisValid = false;
    _axisGravity = null;
    _voteSum = const _V(0, 0, 0);
    _voteAbs = 0;
    _voteN = 0;
    _intervalSum = const _V(0, 0, 0);
    _intervalN = 0;
    _buffer.clear();
  }

  void _resetEpisodes() {
    _smooth = 0;
    _accelEp.reset();
    _brakeEp.reset();
  }

  /// Gyroscope sample (rad/s).
  void onGyro(int tMs, double x, double y, double z) {
    final _V w = _V(x, y, z);
    final _V? g = _g;
    final int dt = (tMs - _lastGyroT).clamp(0, 100);
    if (g != null && _lastGyroT > 0 && dt > 0) {
      // dg/dt = -w x g (the world rotates against the device frame).
      final _V rotated = g - w.cross(g) * (dt / 1000.0);
      final double n = rotated.norm;
      _g = n > 1e-6 ? rotated * (g.norm / n) : g;
    }
    _lastGyroT = tMs;
    final double rate = w.norm;
    if (rate >= config.gyroSpikeRadPerSec) {
      _markHandling(tMs);
      if (rate >= 2.5) _invalidateAxis();
    }
  }

  void _markHandling(int tMs) {
    _handlingUntil = math.max(_handlingUntil, tMs + config.handlingHoldMs);
    _handlingTimes.add(tMs);
    while (_handlingTimes.isNotEmpty &&
        tMs - _handlingTimes.first > config.bufferMs) {
      _handlingTimes.removeAt(0);
    }
  }

  /// Raw accelerometer sample including gravity (m/s^2).
  void onAccel(int tMs, double x, double y, double z) {
    final _V a = _V(x, y, z);
    final _V? g0 = _g;
    if (g0 == null) {
      _g = a;
      _firstT = tMs;
      _lastT = tMs;
      return;
    }
    final int dt = (tMs - _lastT).clamp(1, 200);
    _lastT = tMs;
    final bool warm = tMs - _firstT >= 3000;
    final bool gyroAlive = tMs - _lastGyroT < 1000;
    final bool handling = tMs < _handlingUntil;

    final double preMag = (a - g0).norm;
    // Reorientation / drop: not plausible vehicle acceleration.
    if (preMag > config.reorientMps2) _markHandling(tMs);

    double tau;
    if (!warm) {
      tau = 700;
    } else if (handling || tMs < _handlingUntil) {
      tau = 300;
    } else if (gyroAlive) {
      tau = 30000;
    } else {
      tau = preMag > config.gravityFreezeMps2
          ? 8000
          : config.gravityTauMs.toDouble();
    }
    final _V g = g0 + (a - g0) * (dt / (tau + dt));
    _g = g;
    final _V lin = a - g;

    // Tilt away from the axis calibration invalidates the forward axis.
    final _V? ag = _axisGravity;
    if (_axisValid && ag != null) {
      if (_angleDeg(ag, g) > config.gravityTiltInvalidateDeg) {
        _invalidateAxis();
      }
    }

    final _V gh = g.unit;
    final _V horiz = lin - gh * lin.dot(gh);
    if (tMs < _handlingUntil) _intervalHandled = true;
    _intervalSum = _intervalSum + horiz;
    _intervalN++;

    final bool jolt = horiz.norm > config.jerkCapMps2;
    if (jolt) _markHandling(tMs);

    final _S s = _S(tMs, dt, lin, g, warm, tMs < _handlingUntil);
    _buffer.add(s);
    while (_buffer.isNotEmpty && tMs - _buffer.first.t > config.bufferMs) {
      _buffer.removeFirst();
    }
    if (_axisValid) _detect(s);
    _releaseHeld(tMs);
  }

  /// GPS fix: [speedMps] ground speed. Call at ~1 Hz while driving.
  void onGps(int tMs, double speedMps, double lat, double lon) {
    final _Fix? prev = _fixes.isEmpty ? null : _fixes.last;
    _fixes.add(_Fix(tMs, speedMps, lat, lon));
    while (_fixes.isNotEmpty && tMs - _fixes.first.t > 90000) {
      _fixes.removeAt(0);
    }
    if (prev != null && _g != null) {
      final int gap = tMs - prev.t;
      if (gap >= 500 && gap <= 2500 && _intervalN >= 5 && !_intervalHandled) {
        final double d = (speedMps - prev.speed) / (gap / 1000.0);
        if (d.abs() >= config.axisMinAccelMps2) {
          _vote(_intervalSum * (1.0 / _intervalN), d);
        }
      }
    }
    _intervalSum = const _V(0, 0, 0);
    _intervalN = 0;
    _intervalHandled = false;
    _resolvePending(tMs);
  }

  void _vote(_V meanHoriz, double d) {
    _voteSum = _voteSum * 0.95 + meanHoriz * d;
    _voteAbs = _voteAbs * 0.95 + meanHoriz.norm * d.abs();
    _voteN++;
    final bool wasValid = _axisValid;
    final double coherence = _voteAbs > 1e-6 ? _voteSum.norm / _voteAbs : 0;
    if (_voteN >= config.axisMinIntervals &&
        coherence >= config.axisMinCoherence &&
        _voteSum.norm > 1e-6) {
      _axis = _voteSum.unit;
      _axisGravity = _g;
      _axisValid = true;
      if (!wasValid) _replay();
    } else if (wasValid && coherence < config.axisMinCoherence) {
      _axisValid = false;
    }
  }

  /// Re-runs detection over the buffered history now that the axis is known,
  /// so the launch that taught the axis is still evaluated.
  void _replay() {
    _resetEpisodes();
    for (final _S s in _buffer) {
      _detect(s);
    }
    _resolvePending(_lastT);
  }

  // ---- detection ---------------------------------------------------------

  void _detect(_S s) {
    if (!s.warm) {
      _smooth = 0;
      return;
    }
    final _V gh = s.g.unit;
    _V f = _axis - gh * _axis.dot(gh);
    if (f.norm < 0.3) return;
    f = f.unit;
    final double raw = s.lin.dot(f);
    final double alpha = s.dt / (config.smoothingTauMs + s.dt);
    _smooth += (raw - _smooth) * alpha;
    _step(_accelEp, config.rapidAccelMps2, DrivingEventKind.rapidAccel, s);
    _step(_brakeEp, config.hardBrakeMps2, DrivingEventKind.hardBrake, s);
  }

  void _step(_Episode ep, double thr, DrivingEventKind kind, _S s) {
    final double v = ep.dir * _smooth;
    final double exit = thr * config.hysteresisFactor;
    if (v >= thr) {
      if (!ep.active) {
        ep.active = true;
        ep.startT = s.t;
        ep.aboveMs = 0;
        ep.sum = 0;
        ep.tainted = false;
      }
      ep.lastAboveT = s.t;
      ep.aboveMs += s.dt;
      ep.sum += v * s.dt;
      ep.belowSince = null;
      if (s.handling) ep.tainted = true;
    } else if (ep.active) {
      if (s.handling) ep.tainted = true;
      if (v >= exit) {
        ep.belowSince = null;
      } else {
        ep.belowSince ??= s.t;
        if (s.t - ep.belowSince! > config.gapToleranceMs) {
          _finish(ep, kind);
        }
      }
    }
  }

  void _finish(_Episode ep, DrivingEventKind kind) {
    final bool longEnough = ep.aboveMs >= config.minDurationMs;
    final bool handled = _handlingTimes.any(
        (int h) => h >= ep.startT - 500 && h <= ep.lastAboveT + 500);
    if (longEnough && !ep.tainted && !handled) {
      _pending.add(_Cand(kind, ep.dir, ep.startT, ep.lastAboveT,
          ep.sum / ep.aboveMs, ep.aboveMs / 1000.0));
    }
    ep.active = false;
    ep.belowSince = null;
  }

  // ---- GPS cross-check ---------------------------------------------------

  void _resolvePending(int nowMs) {
    final List<_Cand> keep = <_Cand>[];
    for (final _Cand c in _pending) {
      _Fix? before;
      _Fix? after;
      for (final _Fix fx in _fixes) {
        if (fx.t <= c.startT) before = fx;
        if (fx.t >= c.endT && after == null) after = fx;
      }
      if (after == null && nowMs - c.endT <= config.fixMaxGapMs + 1000) {
        keep.add(c); // Wait for the next fix.
        continue;
      }
      if (before == null ||
          after == null ||
          c.startT - before.t > config.fixMaxGapMs ||
          after.t - c.endT > config.fixMaxGapMs) {
        continue;
      }
      if (math.max(before.speed, after.speed) < config.minSpeedMps) continue;
      final double dv = after.speed - before.speed;
      if (dv * c.dir <= 0) continue; // Wrong sign: not braking/accelerating.
      if (dv.abs() < 0.4 * c.mag * c.durS) continue; // Implausibly small.
      _emit(DrivingEvent(
        kind: c.kind,
        startedAtMs: c.startT,
        endedAtMs: c.endT,
        magnitude: c.mag,
        lat: before.lat,
        lon: before.lon,
      ));
    }
    _pending
      ..clear()
      ..addAll(keep);
  }

  void _emit(DrivingEvent e) {
    // A replay can re-detect an event that was already reported.
    if (e.endedAtMs <= (_doneEnd[e.kind] ?? -1)) return;
    final DrivingEvent? h = _held[e.kind];
    if (h != null && e.startedAtMs - h.endedAtMs <= config.mergeGapMs) {
      _held[e.kind] = h.copyWith(
        endedAtMs: math.max(h.endedAtMs, e.endedAtMs),
        magnitude: math.max(h.magnitude, e.magnitude),
      );
      return;
    }
    if (h != null) _release(h);
    _held[e.kind] = e;
  }

  void _releaseHeld(int nowMs) {
    for (final DrivingEventKind k in _held.keys.toList()) {
      if (nowMs - _held[k]!.endedAtMs > config.mergeGapMs) {
        _release(_held.remove(k)!);
      }
    }
  }

  void _release(DrivingEvent e) {
    _out.add(e);
    _doneEnd[e.kind] = math.max(_doneEnd[e.kind] ?? -1, e.endedAtMs);
  }

  /// Returns (and clears) the finished events. Pass [flush] to also release
  /// events still waiting for a possible merge (end of a session).
  List<DrivingEvent> takeEvents({bool flush = false}) {
    if (flush) {
      _resolvePending(_lastT + config.fixMaxGapMs + 5000);
      for (final DrivingEvent e in _held.values.toList()) {
        _release(e);
      }
      _held.clear();
    }
    final List<DrivingEvent> r = List<DrivingEvent>.of(_out)
      ..sort((DrivingEvent a, DrivingEvent b) =>
          a.startedAtMs.compareTo(b.startedAtMs));
    _out.clear();
    return r;
  }
}

class _Episode {
  _Episode(this.dir);
  final int dir;
  bool active = false;
  int startT = 0;
  int lastAboveT = 0;
  int? belowSince;
  int aboveMs = 0;
  double sum = 0;
  bool tainted = false;

  void reset() {
    active = false;
    belowSince = null;
    aboveMs = 0;
    sum = 0;
    tainted = false;
  }
}

class _Cand {
  _Cand(this.kind, this.dir, this.startT, this.endT, this.mag, this.durS);
  final DrivingEventKind kind;
  final int dir;
  final int startT;
  final int endT;
  final double mag;
  final double durS;
}

class _Fix {
  const _Fix(this.t, this.speed, this.lat, this.lon);
  final int t;
  final double speed;
  final double lat;
  final double lon;
}

class _S {
  const _S(this.t, this.dt, this.lin, this.g, this.warm, this.handling);
  final int t;
  final int dt;
  final _V lin;
  final _V g;
  final bool warm;
  final bool handling;
}

class _V {
  const _V(this.x, this.y, this.z);
  final double x;
  final double y;
  final double z;

  _V operator +(_V o) => _V(x + o.x, y + o.y, z + o.z);
  _V operator -(_V o) => _V(x - o.x, y - o.y, z - o.z);
  _V operator *(double k) => _V(x * k, y * k, z * k);
  double dot(_V o) => x * o.x + y * o.y + z * o.z;
  _V cross(_V o) =>
      _V(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x);
  double get norm => math.sqrt(dot(this));
  _V get unit {
    final double n = norm;
    return n < 1e-9 ? this : this * (1 / n);
  }
}

double _angleDeg(_V a, _V b) {
  final double c = (a.unit.dot(b.unit)).clamp(-1.0, 1.0);
  return math.acos(c) * 180 / math.pi;
}
