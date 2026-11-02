import 'dart:math' as math;

/// Thresholds for [CrashDetector]. Deliberately conservative: a missed
/// detection costs the user one tap on the SOS button, a false alarm costs the
/// whole circle a scare (and the user is always given a countdown to cancel).
class CrashConfig {
  const CrashConfig({
    this.spikeG = 4.0,
    this.minPreSpeedMps = 25 / 3.6,
    this.nearZeroMps = 2.0,
    this.holdMaxMps = 3.0,
    this.preFixMaxAgeMs = 2500,
    this.dropWithinMs = 6000,
    this.stillHoldMs = 3000,
    this.cooldownMs = 5 * 60 * 1000,
    this.gpsKeepMs = 15000,
  });

  /// Acceleration magnitude (including gravity), in g, that counts as an
  /// impact. Hard braking peaks around 0.5-1 g and potholes / phone drops are
  /// short; a real crash is well above this.
  final double spikeG;

  /// GPS speed just before the impact must be at least this (25 km/h).
  final double minPreSpeedMps;

  /// A fix at or below this speed (7.2 km/h) after the impact means "stopped".
  final double nearZeroMps;

  /// While confirming, every fix must stay at or below this.
  final double holdMaxMps;

  /// The last fix before the impact must be at most this old.
  final int preFixMaxAgeMs;

  /// The speed must reach [nearZeroMps] within this long after the impact.
  final int dropWithinMs;

  /// The vehicle must then stay stopped for this long before we conclude.
  final int stillHoldMs;

  /// After a probable crash no further one is reported for this long.
  final int cooldownMs;

  /// GPS history kept (only the last fix before an impact is needed).
  final int gpsKeepMs;
}

/// A probable crash found by [CrashDetector].
class CrashSignal {
  const CrashSignal({
    required this.tMs,
    required this.peakG,
    required this.speedBeforeMps,
    required this.speedAfterMps,
    this.lat,
    this.lon,
  });

  /// Time of the impact (the sample clock of the feed).
  final int tMs;
  final double peakG;
  final double speedBeforeMps;
  final double speedAfterMps;
  final double? lat;
  final double? lon;
}

class _Fix {
  _Fix(this.tMs, this.speedMps, this.lat, this.lon);
  final int tMs;
  final double speedMps;
  final double lat;
  final double lon;
}

class _Pending {
  _Pending(this.tMs, this.peakG, this.before);
  final int tMs;
  double peakG;
  final _Fix before;
  int? stoppedAt;
  double lastSpeed = 0;
}

/// Pure-Dart crash heuristic, fed raw accelerometer samples (m/s^2 including
/// gravity) and GPS speed fixes. No clocks, no plugins: callers pass the
/// sample time, so it is fully unit-testable.
///
/// A probable crash needs ALL of:
///  1. an acceleration magnitude of at least [CrashConfig.spikeG],
///  2. a GPS fix at driving speed (>= 25 km/h) immediately before it,
///  3. the speed falling to near zero within a few seconds after it, and
///  4. staying near zero for [CrashConfig.stillHoldMs].
/// Potholes and dropped phones fail (3); hard braking fails (1); a phone
/// dropped after a normal stop fails (2).
class CrashDetector {
  CrashDetector({this.config = const CrashConfig()});

  final CrashConfig config;
  static const double _g = 9.80665;

  final List<_Fix> _fixes = <_Fix>[];
  _Pending? _pending;
  CrashSignal? _signal;
  int _cooldownUntil = -1;
  int _now = 0;

  /// Forget everything (a new drive started).
  void reset() {
    _fixes.clear();
    _pending = null;
    _signal = null;
    _cooldownUntil = -1;
  }

  /// Returns the probable crash found since the last call, once.
  CrashSignal? takeSignal() {
    final CrashSignal? s = _signal;
    _signal = null;
    return s;
  }

  void onAccel(int tMs, double x, double y, double z) {
    _now = math.max(_now, tMs);
    if (tMs < _cooldownUntil || _signal != null) return;
    final double g = math.sqrt(x * x + y * y + z * z) / _g;
    if (g.isNaN || g < config.spikeG) return;
    final _Pending? p = _pending;
    if (p != null) {
      if (g > p.peakG) p.peakG = g;
      return;
    }
    // Last fix before the impact, recent enough, at driving speed.
    _Fix? before;
    for (final _Fix f in _fixes) {
      if (f.tMs <= tMs) before = f;
    }
    if (before == null ||
        tMs - before.tMs > config.preFixMaxAgeMs ||
        before.speedMps < config.minPreSpeedMps) {
      return;
    }
    _pending = _Pending(tMs, g, before);
  }

  void onGps(int tMs, double speedMps, double lat, double lon) {
    _now = math.max(_now, tMs);
    if (speedMps.isNaN || speedMps < 0) return;
    _fixes.add(_Fix(tMs, speedMps, lat, lon));
    _fixes.removeWhere((_Fix f) => tMs - f.tMs > config.gpsKeepMs);
    final _Pending? p = _pending;
    if (p != null && tMs > p.tMs) {
      p.lastSpeed = speedMps;
      if (p.stoppedAt == null) {
        if (speedMps <= config.nearZeroMps) {
          p.stoppedAt = tMs;
        }
      } else if (speedMps > config.holdMaxMps) {
        _pending = null; // rolled or kept going: not a crash
        return;
      }
    }
    tick(tMs);
  }

  /// Time-driven resolution; call regularly (the runtime does every few
  /// seconds) so a lost GPS signal cannot leave a candidate hanging.
  void tick(int nowMs) {
    _now = math.max(_now, nowMs);
    final _Pending? p = _pending;
    if (p == null) return;
    final int? stopped = p.stoppedAt;
    if (stopped == null) {
      if (_now - p.tMs > config.dropWithinMs) _pending = null; // kept moving
      return;
    }
    if (stopped - p.tMs > config.dropWithinMs) {
      _pending = null;
      return;
    }
    if (_now - stopped >= config.stillHoldMs) {
      _pending = null;
      _cooldownUntil = _now + config.cooldownMs;
      final _Fix last = _fixes.isNotEmpty ? _fixes.last : p.before;
      _signal = CrashSignal(
        tMs: p.tMs,
        peakG: p.peakG,
        speedBeforeMps: p.before.speedMps,
        speedAfterMps: p.lastSpeed,
        lat: last.lat,
        lon: last.lon,
      );
    }
  }
}
