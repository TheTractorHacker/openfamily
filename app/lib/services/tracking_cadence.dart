/// Adaptive reporting cadence ("drive mode") for location sharing.
///
/// Pure Dart, no plugins, no clock of its own: every method that depends on
/// time takes `now`, so the policy is fully unit-testable. See
/// docs/live-tracking-client.md for the policy table.
///
/// The policy never sees coordinates, only speed / accuracy / state flags.
library;

/// Tunable constants. Everything the policy decides is derived from these.
class CadenceConfig {
  const CadenceConfig({
    this.driveEnterSpeedMps = 3.0,
    this.driveEnterFixes = 2,
    this.driveEnterInstantSpeedMps = 8.0,
    this.driveExitSpeedMps = 1.0,
    this.driveExitHold = const Duration(seconds: 60),
    this.walkEnterSpeedMps = 0.8,
    this.walkExitSpeedMps = 0.4,
    this.walkExitHold = const Duration(seconds: 30),
    this.speedSmoothing = 0.5,
    this.fixStaleAfter = const Duration(seconds: 120),
    this.fastGpsInterval = const Duration(seconds: 1),
    this.fastMinPost = const Duration(milliseconds: 850),
    this.sosGpsInterval = const Duration(seconds: 2),
    this.sosMinPost = const Duration(seconds: 2),
    this.walkGpsInterval = const Duration(seconds: 5),
    this.walkMinPost = const Duration(seconds: 5),
    this.stationaryForegroundDistanceM = 10,
    this.stationaryForegroundMinPost = const Duration(seconds: 5),
    this.stationaryBackgroundGpsInterval = const Duration(seconds: 60),
    this.stationaryBackgroundMinPost = const Duration(seconds: 10),
    this.lowBatteryPct = 15,
    this.lowBatteryWalkInterval = const Duration(seconds: 15),
    this.lowBatteryDriveInterval = const Duration(seconds: 5),
    this.maxBoost = const Duration(seconds: 120),
    this.liveFlagBoost = const Duration(seconds: 10),
    this.minApplyGap = const Duration(seconds: 20),
    this.reassertAfter = const Duration(minutes: 5),
  });

  /// Smoothed speed at/above which drive mode can start...
  final double driveEnterSpeedMps;

  /// ...when sustained for this many consecutive fixes.
  final int driveEnterFixes;

  /// A single raw fix at/above this speed starts drive mode immediately
  /// (background fixes can be 60 s apart; waiting for two would cost minutes).
  final double driveEnterInstantSpeedMps;

  /// Drive mode ends only after smoothed speed stays below this for
  /// [driveExitHold] (red lights and traffic jams keep drive mode).
  final double driveExitSpeedMps;
  final Duration driveExitHold;

  final double walkEnterSpeedMps;
  final double walkExitSpeedMps;
  final Duration walkExitHold;

  /// EMA factor for speed smoothing (1 = no smoothing).
  final double speedSmoothing;

  /// Without any fix for this long the speed history is discarded and the
  /// policy falls back to the slow profile.
  final Duration fixStaleAfter;

  final Duration fastGpsInterval;

  /// Post gate for 1 Hz profiles. Slightly under 1 s so GPS timing jitter
  /// does not drop every other fix; the 1 Hz request interval is what bounds
  /// the real rate.
  final Duration fastMinPost;

  final Duration sosGpsInterval;
  final Duration sosMinPost;
  final Duration walkGpsInterval;
  final Duration walkMinPost;
  final double stationaryForegroundDistanceM;
  final Duration stationaryForegroundMinPost;
  final Duration stationaryBackgroundGpsInterval;
  final Duration stationaryBackgroundMinPost;

  final int lowBatteryPct;
  final Duration lowBatteryWalkInterval;
  final Duration lowBatteryDriveInterval;

  /// Upper bound for a requested live boost.
  final Duration maxBoost;

  /// Boost granted each time a POST /locations response says `"live": true`.
  final Duration liveFlagBoost;

  /// Minimum time between two profile changes applied to the GPS source.
  final Duration minApplyGap;

  /// A non-stationary profile is re-sent to the GPS source this often even
  /// if unchanged, in case the native side was reset (re-registration,
  /// service restart).
  final Duration reassertAfter;
}

enum CadenceTier { stationary, walking, driving, boosted, sos }

/// What the GPS source and the post gate should do right now.
class CadenceProfile {
  const CadenceProfile({
    required this.tier,
    required this.gpsInterval,
    required this.distanceFilterM,
    required this.minPostInterval,
    required this.highAccuracy,
    this.lowBatteryBackoff = false,
  });

  final CadenceTier tier;

  /// Requested interval between GPS fixes.
  final Duration gpsInterval;

  /// Displacement filter in meters (0 = none).
  final double distanceFilterM;

  /// Minimum time between POSTs.
  final Duration minPostInterval;
  final bool highAccuracy;
  final bool lowBatteryBackoff;

  /// True for profiles that deliver at ~1 Hz.
  bool get isFast => gpsInterval <= const Duration(seconds: 2);

  /// Whether the GPS source must be re-requested to move from this profile to
  /// [other] (post-gate-only differences never need a restart).
  bool gpsDiffersFrom(CadenceProfile other) =>
      gpsInterval != other.gpsInterval ||
      distanceFilterM != other.distanceFilterM ||
      highAccuracy != other.highAccuracy;

  String get label => lowBatteryBackoff ? '${tier.name}+lowbat' : tier.name;

  @override
  String toString() =>
      'CadenceProfile($label, gps=${gpsInterval.inMilliseconds}ms, '
      'df=${distanceFilterM}m, post=${minPostInterval.inMilliseconds}ms)';
}

/// Chooses the [CadenceProfile] from speed, motion state, boost / SOS,
/// battery and foreground / background.
class TrackingCadence {
  TrackingCadence({this.config = const CadenceConfig()});

  final CadenceConfig config;

  double? _smoothed;
  int _fastStreak = 0;
  bool _driving = false;
  DateTime? _driveBelowSince;
  bool _walking = false;
  DateTime? _walkBelowSince;
  DateTime? _lastFixAt;
  bool _motionActive = false;

  DateTime? _boostUntil;
  bool _sos = false;
  int? _batteryPct;
  bool _charging = false;
  bool _background = false;

  /// Smoothed speed in m/s, or null before any speed-bearing fix.
  double? get smoothedSpeed => _smoothed;
  bool get isDriving => _driving;

  /// Motion states from activity recognition that mean "the person is
  /// moving": used as evidence for the walking tier (never for drive mode,
  /// which needs measured speed).
  static bool isMovingMotionState(String state) {
    switch (state) {
      case 'walking':
      case 'running':
      case 'cycling':
      case 'driving':
        return true;
      default:
        return false;
    }
  }

  void setBackground(bool background) => _background = background;

  void setBattery(int? pct, {bool charging = false}) {
    _batteryPct = pct;
    _charging = charging;
  }

  void setSos(bool active) => _sos = active;

  bool isBoosted(DateTime now) => _boostUntil != null && now.isBefore(_boostUntil!);

  /// Starts (or extends, never shortens) a live boost. [ttl] is capped at
  /// [CadenceConfig.maxBoost]; non-positive TTLs are ignored.
  void startBoost(Duration ttl, DateTime now) {
    if (ttl <= Duration.zero) return;
    final Duration capped = ttl > config.maxBoost ? config.maxBoost : ttl;
    final DateTime until = now.add(capped);
    if (_boostUntil == null || until.isAfter(_boostUntil!)) _boostUntil = until;
  }

  void stopBoost() => _boostUntil = null;

  /// Feeds one accepted GPS fix. [speedMps] null / negative / NaN means the
  /// fix carried no speed (it is then ignored for smoothing).
  void onFix({
    required DateTime now,
    double? speedMps,
    String motionState = '',
  }) {
    _lastFixAt = now;
    _motionActive = isMovingMotionState(motionState);
    if (speedMps == null || speedMps.isNaN || speedMps < 0) return;

    final double a = config.speedSmoothing;
    final double prev = _smoothed ?? speedMps;
    final double s = _smoothed == null ? speedMps : a * speedMps + (1 - a) * prev;
    _smoothed = s;

    // Drive mode.
    if (s >= config.driveEnterSpeedMps) {
      _fastStreak++;
    } else {
      _fastStreak = 0;
    }
    if (!_driving &&
        (_fastStreak >= config.driveEnterFixes ||
            speedMps >= config.driveEnterInstantSpeedMps)) {
      _driving = true;
      _driveBelowSince = null;
    } else if (_driving) {
      if (s < config.driveExitSpeedMps) {
        _driveBelowSince ??= now;
        if (now.difference(_driveBelowSince!) >= config.driveExitHold) {
          _driving = false;
          _driveBelowSince = null;
          _fastStreak = 0;
        }
      } else {
        _driveBelowSince = null;
      }
    }

    // Walking tier (only meaningful when not driving).
    final bool evidence = s >= config.walkEnterSpeedMps ||
        (_walking && s >= config.walkExitSpeedMps) ||
        _motionActive;
    if (evidence) {
      _walking = true;
      _walkBelowSince = null;
    } else if (_walking) {
      _walkBelowSince ??= now;
      if (now.difference(_walkBelowSince!) >= config.walkExitHold) {
        _walking = false;
        _walkBelowSince = null;
      }
    }
  }

  /// Time-driven bookkeeping (stale-fix reset, hold timers that elapse with
  /// no new fix). Called by [profile].
  void _tick(DateTime now) {
    final DateTime? last = _lastFixAt;
    if (last != null && now.difference(last) >= config.fixStaleAfter) {
      _driving = false;
      _walking = false;
      _smoothed = null;
      _fastStreak = 0;
      _driveBelowSince = null;
      _walkBelowSince = null;
      _motionActive = false;
      _lastFixAt = null;
    }
  }

  CadenceTier tier(DateTime now) {
    _tick(now);
    if (_sos) return CadenceTier.sos;
    if (isBoosted(now)) return CadenceTier.boosted;
    if (_driving) return CadenceTier.driving;
    if (_walking) return CadenceTier.walking;
    return CadenceTier.stationary;
  }

  /// The profile that should be active at [now].
  CadenceProfile profile(DateTime now) {
    final CadenceTier t = tier(now);
    switch (t) {
      case CadenceTier.sos:
        return CadenceProfile(
          tier: t,
          gpsInterval: config.sosGpsInterval,
          distanceFilterM: 0,
          minPostInterval: config.sosMinPost,
          highAccuracy: true,
        );
      case CadenceTier.boosted:
        return CadenceProfile(
          tier: t,
          gpsInterval: config.fastGpsInterval,
          distanceFilterM: 0,
          minPostInterval: config.fastMinPost,
          highAccuracy: true,
        );
      case CadenceTier.driving:
        if (_lowBattery) {
          return CadenceProfile(
            tier: t,
            gpsInterval: config.lowBatteryDriveInterval,
            distanceFilterM: 0,
            minPostInterval: config.lowBatteryDriveInterval,
            highAccuracy: true,
            lowBatteryBackoff: true,
          );
        }
        return CadenceProfile(
          tier: t,
          gpsInterval: config.fastGpsInterval,
          distanceFilterM: 0,
          minPostInterval: config.fastMinPost,
          highAccuracy: true,
        );
      case CadenceTier.walking:
        if (_lowBattery) {
          return CadenceProfile(
            tier: t,
            gpsInterval: config.lowBatteryWalkInterval,
            distanceFilterM: 0,
            minPostInterval: config.lowBatteryWalkInterval,
            highAccuracy: true,
            lowBatteryBackoff: true,
          );
        }
        return CadenceProfile(
          tier: t,
          gpsInterval: config.walkGpsInterval,
          distanceFilterM: 0,
          minPostInterval: config.walkMinPost,
          highAccuracy: true,
        );
      case CadenceTier.stationary:
        if (_background) {
          return CadenceProfile(
            tier: t,
            gpsInterval: config.stationaryBackgroundGpsInterval,
            distanceFilterM: 0,
            minPostInterval: config.stationaryBackgroundMinPost,
            highAccuracy: true,
          );
        }
        return CadenceProfile(
          tier: t,
          gpsInterval: Duration.zero,
          distanceFilterM: config.stationaryForegroundDistanceM,
          minPostInterval: config.stationaryForegroundMinPost,
          highAccuracy: true,
        );
    }
  }

  bool get _lowBattery =>
      _batteryPct != null && _batteryPct! < config.lowBatteryPct && !_charging;
}

/// Decides when a changed [CadenceProfile] may be pushed to the GPS source so
/// it never thrashes: at most one change per [CadenceConfig.minApplyGap],
/// except that speeding up for boost / SOS / drive-from-slow is allowed
/// immediately (the user asked for live data; waiting would defeat it).
class ProfileApplier {
  ProfileApplier(this.config);

  final CadenceConfig config;
  CadenceProfile? applied;
  DateTime? _appliedAt;

  /// Returns the profile to apply now, or null when nothing should change.
  /// Call [markApplied] after the GPS source was actually reconfigured.
  CadenceProfile? next(CadenceProfile desired, DateTime now) {
    final CadenceProfile? cur = applied;
    if (cur == null) return desired;
    if (!cur.gpsDiffersFrom(desired)) {
      final DateTime? at0 = _appliedAt;
      if (desired.tier != CadenceTier.stationary &&
          at0 != null &&
          now.difference(at0) >= config.reassertAfter) {
        return desired;
      }
      return null; // Only post-gate differences: just use the new profile.
    }
    final bool urgent = (desired.tier == CadenceTier.boosted ||
            desired.tier == CadenceTier.sos) &&
        desired.gpsInterval < cur.gpsInterval;
    final DateTime? at = _appliedAt;
    if (!urgent && at != null && now.difference(at) < config.minApplyGap) {
      return null;
    }
    return desired;
  }

  void markApplied(CadenceProfile p, DateTime now) {
    applied = p;
    _appliedAt = now;
  }

  /// Forget state (service restarted).
  void reset() {
    applied = null;
    _appliedAt = null;
  }
}
