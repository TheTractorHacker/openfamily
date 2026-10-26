import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// Tunables for [MarkerMotion]. Documented in docs/live-tracking-map.md.
class MotionConfig {
  const MotionConfig({
    this.minSegmentS = 0.5,
    this.maxSegmentS = 2.5,
    this.defaultSegmentS = 1.0,
    this.deadReckonMaxS = 3.0,
    this.teleportMeters = 500,
    this.teleportGapS = 120,
    this.stationaryMps = 0.5,
    this.stationaryMinRadiusM = 8,
    this.headingTauS = 0.25,
    this.speedStaleS = 15,
    this.maxPlausibleMps = 90,
  });

  /// Bounds for the time spent easing from the displayed position to a new
  /// fix (normally the fix-to-fix interval, so the pin is ~1 fix behind).
  final double minSegmentS;
  final double maxSegmentS;
  final double defaultSegmentS;

  /// How long the pin keeps coasting along the heading at the GPS speed when
  /// the next fix is late, before it holds still.
  final double deadReckonMaxS;

  /// A jump bigger than this, or a gap longer than [teleportGapS], snaps.
  final double teleportMeters;
  final double teleportGapS;

  /// Below this GPS speed the member counts as stationary.
  final double stationaryMps;

  /// A stationary fix closer than max(accuracy, this) to the pin is jitter.
  final double stationaryMinRadiusM;

  /// Time constant of the heading smoothing.
  final double headingTauS;

  /// A speed older than this reads as 0.
  final double speedStaleS;

  /// Speeds above this are treated as GPS garbage when dead reckoning.
  final double maxPlausibleMps;
}

/// One GPS fix as the server reported it.
class TrackFix {
  const TrackFix({
    required this.position,
    required this.ts,
    this.speedMps,
    this.headingDeg,
    this.accuracyM,
  });

  final LatLng position;

  /// GPS fix time.
  final DateTime ts;
  final double? speedMps;

  /// Degrees clockwise from north; null when unknown.
  final double? headingDeg;
  final double? accuracyM;
}

/// What to draw this frame.
class MotionSample {
  const MotionSample({
    required this.position,
    required this.headingDeg,
    required this.speedMps,
    required this.animating,
  });

  final LatLng position;

  /// Smoothed heading in [0, 360), or null when never known.
  final double? headingDeg;

  /// Smoothed GPS speed, 0 when stationary / stale, null when unknown.
  final double? speedMps;

  /// Whether another frame is needed (position or heading still changing).
  final bool animating;
}

/// Turns sparse GPS fixes (about 1 Hz while driving) into a continuous,
/// Life360-style motion for one member. Pure Dart: time is always passed in.
///
/// * The pin renders about one fix behind real time. On a new fix it eases
///   from where it currently is to the fix over the fix interval, so a steady
///   1 Hz drive becomes constant-velocity motion.
/// * If the next fix is late it coasts along the heading at the GPS speed for
///   up to [MotionConfig.deadReckonMaxS], tapering to a stop, then holds.
/// * It never moves backwards (a new fix behind the coasting pin waits to be
///   overtaken), snaps on teleports, and ignores jitter inside the accuracy
///   circle while stationary.
class MarkerMotion {
  MarkerMotion({this.config = const MotionConfig()});

  final MotionConfig config;

  static const Distance _dist = Distance(roundResult: false);

  // Newest accepted fix (by ts).
  TrackFix? _last;
  DateTime? _lastArrival;

  // Current easing segment, in seconds on the caller's clock.
  LatLng? _from;
  LatLng? _to;
  double _segStart = 0;
  double _segDur = 0;
  bool _segEase = false;

  // Dead reckoning.
  double _speedForDr = 0;
  double? _fixHeading; // heading used for DR and as the heading target
  double? _bearingFromTrack;

  // Last drawn state (monotonic hold + heading smoothing).
  LatLng? _shown;
  double? _shownHeading;
  double _lastSampleT = double.nan;

  // Speed low-pass over the last three raw samples (newest last).
  final List<double> _speeds = <double>[];
  double? _speedOut;

  /// True once at least one fix has been accepted.
  bool get hasFix => _last != null;

  /// The newest accepted fix.
  TrackFix? get lastFix => _last;

  static double _secs(DateTime t) => t.microsecondsSinceEpoch / 1e6;

  /// Feeds a fix. [now] is the local receive time. Returns false when the fix
  /// is ignored (out of order / duplicate); stationary jitter still returns
  /// true because speed, heading and time are taken from it.
  bool addFix(TrackFix fix, {required DateTime now}) {
    final TrackFix? prev = _last;
    if (prev != null && !fix.ts.isAfter(prev.ts)) return false;

    final double nowS = _secs(now);
    // Where the pin is drawn right now, before this fix changes any state.
    final LatLng? cur = prev == null ? null : _drawnAt(nowS).$1;
    final double fixAge = nowS - _secs(fix.ts);
    final bool oldFix = fixAge > config.speedStaleS;

    // --- speed ----------------------------------------------------------
    final double? rawSpeed = fix.speedMps?.isFinite == true && fix.speedMps! >= 0
        ? fix.speedMps
        : null;
    if (rawSpeed == null) {
      _speeds.clear();
      _speedOut = null;
    } else if (oldFix || rawSpeed < config.stationaryMps) {
      _speeds
        ..clear()
        ..add(0);
      _speedOut = 0;
    } else {
      _speeds.add(rawSpeed);
      if (_speeds.length > 3) _speeds.removeAt(0);
      _speedOut = _lowPass(rawSpeed);
    }
    final bool stationary = !oldFix &&
        (rawSpeed == null ? false : rawSpeed < config.stationaryMps);

    if (prev == null) {
      _snap(fix.position, nowS);
      _accept(fix, now, rawSpeed, oldFix);
      return true;
    }

    final double gapS = _secs(fix.ts) - _secs(prev.ts);
    final double jump = _dist.as(LengthUnit.Meter, cur!, fix.position);
    final double fromAnchor =
        _dist.as(LengthUnit.Meter, _to ?? prev.position, fix.position);

    if (jump > config.teleportMeters || gapS > config.teleportGapS) {
      _snap(fix.position, nowS);
      _accept(fix, now, rawSpeed, oldFix);
      return true;
    }

    if (stationary) {
      final double radius =
          math.max(fix.accuracyM ?? 0, config.stationaryMinRadiusM);
      if (fromAnchor <= radius) {
        // Parked: keep the pin where it is, only refresh the metadata.
        _accept(fix, now, rawSpeed, oldFix, moved: false);
        return true;
      }
    }

    // Ease from the current drawn position to the fix.
    final double dur = gapS.clamp(config.minSegmentS, config.maxSegmentS);
    final bool wasMoving = _speedForDr > config.stationaryMps &&
        nowS - (_segStart + _segDur) < config.deadReckonMaxS + 1;
    _from = cur;
    _to = fix.position;
    _segStart = nowS;
    _segDur = dur;
    // Continuous motion stays linear (constant velocity); a pin that was
    // resting eases out so it does not lurch.
    _segEase = !wasMoving;
    _accept(fix, now, rawSpeed, oldFix);
    return true;
  }

  double _lowPass(double latest) {
    // Weights newest-first. Rising is quick, falling is gentler.
    final List<double> s = _speeds.reversed.toList();
    final double mean = s.length == 1
        ? s[0]
        : s.length == 2
            ? s[0] * 0.6 + s[1] * 0.4
            : s[0] * 0.5 + s[1] * 0.3 + s[2] * 0.2;
    if (_speedOut == null || _speedOut == 0) return latest;
    if (latest >= _speedOut!) {
      return latest * 0.75 + _speedOut! * 0.25;
    }
    return mean;
  }

  void _snap(LatLng p, double nowS) {
    _from = p;
    _to = p;
    _segStart = nowS;
    _segDur = 0;
    _segEase = false;
    _shown = p;
  }

  void _accept(TrackFix fix, DateTime now, double? rawSpeed, bool oldFix,
      {bool moved = true}) {
    final TrackFix? prev = _last;
    // Heading: trust the reported value while actually moving; otherwise
    // derive it from the track; otherwise keep the previous one.
    final bool moving = rawSpeed != null && rawSpeed >= 1.0;
    if (fix.headingDeg != null &&
        fix.headingDeg!.isFinite &&
        (moving || rawSpeed == null)) {
      _fixHeading = _norm(fix.headingDeg!);
    } else if (prev != null && moved) {
      final double d = _dist.as(LengthUnit.Meter, prev.position, fix.position);
      if (d > 5 && moving) {
        _bearingFromTrack = _dist.bearing(prev.position, fix.position);
        _fixHeading = _norm(_bearingFromTrack!);
      }
    }
    _speedForDr = (oldFix || rawSpeed == null)
        ? 0
        : (rawSpeed > config.maxPlausibleMps ? 0 : rawSpeed);
    // Without any reported speed, estimate it from the track.
    if (rawSpeed == null && prev != null && !oldFix) {
      final double dt = _secs(fix.ts) - _secs(prev.ts);
      final double d = _dist.as(LengthUnit.Meter, prev.position, fix.position);
      if (dt > 0.2 && dt < 10 && d > 3) {
        _speedForDr = math.min(d / dt, config.maxPlausibleMps);
        _fixHeading ??= _norm(_dist.bearing(prev.position, fix.position));
      }
    }
    _last = fix;
    _lastArrival = now;
  }

  /// The display state at [now]. Call once per frame.
  MotionSample sample(DateTime now) {
    final TrackFix? last = _last;
    if (last == null) {
      throw StateError('sample() before any fix');
    }
    final double t = _secs(now);
    final double dt = _lastSampleT.isNaN ? 0 : math.max(0, t - _lastSampleT);
    _lastSampleT = t;

    final (LatLng, bool) drawn = _drawnAt(t);
    final LatLng out = drawn.$1;
    final bool posAnimating = drawn.$2;
    _shown = out;

    // 3. Heading: shortest-arc exponential smoothing.
    bool headingAnimating = false;
    final double? target = _fixHeading;
    if (target != null) {
      final double? cur = _shownHeading;
      if (cur == null) {
        _shownHeading = target;
      } else {
        final double delta = _shortest(cur, target);
        final double k = dt <= 0 ? 0 : 1 - math.exp(-dt / config.headingTauS);
        final double next = _norm(cur + delta * k);
        _shownHeading = next;
        headingAnimating = _shortest(next, target).abs() > 0.5;
      }
    }

    final double? speed = speedAt(now);

    return MotionSample(
      position: out,
      headingDeg: _shownHeading,
      speedMps: speed,
      animating: posAnimating || headingAnimating,
    );
  }

  /// Where the pin is drawn at [t] (seconds): the easing segment, then
  /// coasting, then the never-backwards hold. Pure: does not change state, so
  /// [addFix] can ask "where is the pin right now" at the arrival instant even
  /// if no frame was sampled in between.
  (LatLng, bool) _drawnAt(double t) {
    final TrackFix last = _last!;
    final LatLng from = _from ?? last.position;
    final LatLng to = _to ?? last.position;
    final double segEnd = _segStart + _segDur;
    LatLng cand;
    bool animating = false;
    if (_segDur > 0 && t < segEnd) {
      double u = ((t - _segStart) / _segDur).clamp(0.0, 1.0);
      if (_segEase) u = 1 - (1 - u) * (1 - u); // ease-out quad
      cand = _lerp(from, to, u);
      animating = true;
    } else {
      cand = to;
      final bool fresh = _speedOut != null && _speedOut! > 0;
      final double coastT = t - segEnd;
      if (fresh &&
          _speedForDr > config.stationaryMps &&
          _fixHeading != null &&
          coastT > 0) {
        final double along = _coastDistance(coastT);
        if (along > 0) {
          cand = _dist.offset(to, along, _fixHeading!);
          animating = coastT < config.deadReckonMaxS;
        }
      }
    }

    // Never go backwards while moving: a candidate behind the drawn pin
    // (relative to the heading) is held until the track overtakes it.
    final LatLng? shown = _shown;
    if (shown != null &&
        _fixHeading != null &&
        _speedForDr > config.stationaryMps) {
      final double step = _dist.as(LengthUnit.Meter, shown, cand);
      if (step > 0.01) {
        final double b = _dist.bearing(shown, cand);
        if (_shortest(_fixHeading!, b).abs() > 100) cand = shown;
      }
    }
    return (cand, animating);
  }

  /// The smoothed speed at [now]: null when unknown, 0 when stopped or when
  /// the newest fix is older than [MotionConfig.speedStaleS].
  double? speedAt(DateTime now) {
    final TrackFix? last = _last;
    final double? speed = _speedOut;
    if (last == null || speed == null) return null;
    if (speed > 0 && _secs(now) - _secs(last.ts) > config.speedStaleS) {
      _speedOut = 0;
      _speeds
        ..clear()
        ..add(0);
      return 0;
    }
    return speed;
  }

  /// Distance coasted [s] seconds after the segment ended: constant speed for
  /// two seconds, then a taper to a stop at [MotionConfig.deadReckonMaxS].
  double _coastDistance(double s) {
    final double v = _speedForDr;
    final double max = config.deadReckonMaxS;
    final double cruise = math.max(0.0, max - 1.0);
    if (s <= cruise) return v * s;
    final double u = math.min(1.0, (s - cruise));
    return v * (cruise + u - u * u / 2);
  }

  static LatLng _lerp(LatLng a, LatLng b, double u) => LatLng(
        a.latitude + (b.latitude - a.latitude) * u,
        a.longitude + (b.longitude - a.longitude) * u,
      );

  static double _norm(double deg) {
    final double d = deg % 360;
    return d < 0 ? d + 360 : d;
  }

  /// Signed shortest rotation from [a] to [b], in (-180, 180].
  static double _shortest(double a, double b) {
    double d = (b - a) % 360;
    if (d > 180) d -= 360;
    if (d <= -180) d += 360;
    return d;
  }

  /// When the newest fix arrived (local clock); for staleness checks.
  DateTime? get lastArrival => _lastArrival;
}
