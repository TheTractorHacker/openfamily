import 'dart:math' as math;

/// Fix sanity checks and speed fields shared by the foreground and background
/// reporters. Pure Dart; never logs or stores coordinates beyond the last
/// accepted fix held in memory.

class FixQualityConfig {
  const FixQualityConfig({
    this.maxMovingAccuracyM = 50,
    this.movingSpeedMps = 1.0,
    this.maxImpliedSpeedMps = 70,
    this.maxConsecutiveJumpRejects = 3,
    this.goodAccuracyForZeroSpeedM = 30,
    this.maxPlausibleSpeedMps = 120,
  });

  /// A fix worse than this is dropped while the user is moving.
  final double maxMovingAccuracyM;

  /// Speed above which the user counts as moving for the accuracy rule.
  final double movingSpeedMps;

  /// A fix that implies a faster jump from the previous accepted one is bad.
  final double maxImpliedSpeedMps;

  /// After this many consecutive jump rejections the new position is accepted
  /// as the new baseline (a real teleport: tunnel exit, airplane mode).
  final int maxConsecutiveJumpRejects;

  /// A reported speed of exactly 0 is only trusted (sent) when the horizontal
  /// accuracy is at least this good.
  final double goodAccuracyForZeroSpeedM;

  /// Speeds above this are treated as garbage and omitted.
  final double maxPlausibleSpeedMps;
}

enum FixVerdict { ok, stale, poorAccuracy, jump }

/// Stateful fix filter: one instance per reporter.
class FixQualityFilter {
  FixQualityFilter({this.config = const FixQualityConfig()});

  final FixQualityConfig config;

  DateTime? _lastTs;
  double? _lastLat;
  double? _lastLon;
  double _lastSpeed = 0;
  int _jumpRejects = 0;

  /// Evaluates a fix. [lastSentTs] is the newest timestamp already delivered
  /// (older or equal fixes are stale). Accepted fixes update the baseline.
  FixVerdict check({
    required DateTime ts,
    required double lat,
    required double lon,
    required double accuracyM,
    double? speedMps,
    DateTime? lastSentTs,
  }) {
    final DateTime t = ts.toUtc();
    if (lastSentTs != null && !t.isAfter(lastSentTs)) return FixVerdict.stale;
    if (_lastTs != null && !t.isAfter(_lastTs!)) return FixVerdict.stale;

    final double speed = (speedMps != null && speedMps >= 0) ? speedMps : _lastSpeed;
    final bool moving = speed > config.movingSpeedMps;
    if (moving && accuracyM > config.maxMovingAccuracyM) {
      return FixVerdict.poorAccuracy;
    }

    if (_lastTs != null && _lastLat != null && _lastLon != null) {
      final double dt =
          math.max(1.0, t.difference(_lastTs!).inMilliseconds / 1000.0);
      final double d = distanceMeters(_lastLat!, _lastLon!, lat, lon);
      if (d / dt > config.maxImpliedSpeedMps) {
        _jumpRejects++;
        if (_jumpRejects <= config.maxConsecutiveJumpRejects) {
          return FixVerdict.jump;
        }
        // Persistent: the device really relocated. Re-baseline.
      }
    }
    _jumpRejects = 0;
    _lastTs = t;
    _lastLat = lat;
    _lastLon = lon;
    if (speedMps != null && speedMps >= 0) _lastSpeed = speedMps;
    return FixVerdict.ok;
  }

  void reset() {
    _lastTs = null;
    _lastLat = null;
    _lastLon = null;
    _lastSpeed = 0;
    _jumpRejects = 0;
  }

  /// Haversine distance in meters.
  static double distanceMeters(
      double lat1, double lon1, double lat2, double lon2) {
    const double r = 6371000;
    double rad(double d) => d * math.pi / 180;
    final double dLat = rad(lat2 - lat1);
    final double dLon = rad(lon2 - lon1);
    final double a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(rad(lat1)) *
            math.cos(rad(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    return 2 * r * math.asin(math.min(1, math.sqrt(a)));
  }
}

/// The speed-related fields of a `POST /locations` body.
///
/// `speed_mps` is the GPS Doppler speed as reported, INCLUDING 0 when the
/// receiver says 0 and accuracy is good. A zero with poor / unknown accuracy
/// may just mean "no speed available" and is omitted. `speed_accuracy` is
/// sent when the platform provides a positive value.
Map<String, dynamic> speedFields({
  required double speedMps,
  required double speedAccuracyMps,
  required double accuracyM,
  FixQualityConfig config = const FixQualityConfig(),
}) {
  final Map<String, dynamic> out = <String, dynamic>{};
  if (speedMps.isNaN || speedMps.isInfinite || speedMps < 0) return out;
  if (speedMps > config.maxPlausibleSpeedMps) return out;
  final bool goodAccuracy =
      accuracyM > 0 && accuracyM <= config.goodAccuracyForZeroSpeedM;
  if (speedMps > 0 || goodAccuracy) {
    out['speed_mps'] = speedMps;
    if (speedAccuracyMps.isFinite && speedAccuracyMps > 0) {
      out['speed_accuracy'] = speedAccuracyMps;
    }
  }
  return out;
}
