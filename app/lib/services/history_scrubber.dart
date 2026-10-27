import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'history_service.dart';

/// Pure math behind the Daily History scrubber: time <-> path position,
/// interpolation, drawing downsampling, stop clustering and day navigation.
/// No Flutter imports so it is trivially unit-testable.

/// Gaps between fixes longer than this are not interpolated across: the
/// avatar holds at the earlier fix (the phone was off or not reporting), so it
/// never glides through buildings on a straight line.
const Duration kMaxInterpolateGap = Duration(minutes: 10);

/// Fixes within this radius of a stop's anchor belong to that stop (GPS jitter).
const double kStopRadiusMeters = 75;

/// Minimum dwell for a cluster to be reported as a stop.
const Duration kStopMinDwell = Duration(minutes: 5);

/// How many days back the history screen lets you go.
const int kHistoryMaxDaysBack = 89;

const Distance _distance = Distance();

double metersBetween(LatLng a, LatLng b) => _distance(a, b);

/// The scrubber's value at one instant.
class ScrubSample {
  const ScrubSample({
    required this.time,
    required this.position,
    required this.index,
    this.speedMps,
    this.batteryPct,
    this.motionState = '',
    this.interpolated = false,
  });

  final DateTime time;
  final LatLng position;

  /// Index of the last fix at or before [time].
  final int index;
  final double? speedMps;
  final double? batteryPct;
  final String motionState;

  /// True when [position] lies between two fixes.
  final bool interpolated;
}

/// A stationary cluster: merged jittery fixes with a single dwell time.
class StopCluster {
  const StopCluster({
    required this.position,
    required this.arrivedAt,
    required this.departedAt,
    required this.firstIndex,
    required this.lastIndex,
    this.name,
  });

  final LatLng position;
  final DateTime arrivedAt;
  final DateTime departedAt;
  final int firstIndex;
  final int lastIndex;

  /// Place name when a saved family place covers this stop.
  final String? name;

  Duration get dwell => departedAt.difference(arrivedAt);

  StopCluster withName(String? n) => StopCluster(
        position: position,
        arrivedAt: arrivedAt,
        departedAt: departedAt,
        firstIndex: firstIndex,
        lastIndex: lastIndex,
        name: n,
      );
}

/// One day's trail as a seekable timeline at full resolution.
class HistoryTimeline {
  HistoryTimeline(List<HistoryTrailPoint> points)
      : points = _sorted(points);

  final List<HistoryTrailPoint> points;

  static List<HistoryTrailPoint> _sorted(List<HistoryTrailPoint> pts) {
    final List<HistoryTrailPoint> out = List<HistoryTrailPoint>.of(pts)
      ..sort((HistoryTrailPoint a, HistoryTrailPoint b) => a.ts.compareTo(b.ts));
    return out;
  }

  bool get isEmpty => points.isEmpty;
  bool get isSingle => points.length == 1;

  /// True when there is a span of time to scrub over.
  bool get isScrubbable => points.length >= 2 && duration > Duration.zero;

  DateTime get start => points.first.ts;
  DateTime get end => points.last.ts;
  Duration get duration => isEmpty ? Duration.zero : end.difference(start);

  /// 0..1 position of [t] along the day's time span (clamped).
  double fractionForTime(DateTime t) {
    if (!isScrubbable) return 0;
    final double f =
        t.difference(start).inMicroseconds / duration.inMicroseconds;
    return f.clamp(0.0, 1.0);
  }

  /// Time at 0..1 [fraction] of the span (clamped).
  DateTime timeForFraction(double fraction) {
    if (isEmpty) throw StateError('empty timeline');
    final double f = fraction.clamp(0.0, 1.0);
    return start.add(Duration(microseconds: (duration.inMicroseconds * f).round()));
  }

  /// Index of the last fix with ts <= [t], or 0 when [t] precedes all fixes.
  int indexAtOrBefore(DateTime t) {
    int lo = 0;
    int hi = points.length - 1;
    while (lo < hi) {
      final int mid = (lo + hi + 1) >> 1;
      if (!points[mid].ts.isAfter(t)) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  /// Position, speed and battery at [t]. Interpolates linearly between
  /// neighbouring fixes unless they are further apart than [maxGap]; then the
  /// avatar holds at the earlier fix. [t] is clamped to the day's span.
  ScrubSample sampleAt(DateTime t, {Duration maxGap = kMaxInterpolateGap}) {
    if (isEmpty) throw StateError('empty timeline');
    final DateTime tc = t.isBefore(start)
        ? start
        : (t.isAfter(end) ? end : t);
    final int i = indexAtOrBefore(tc);
    final HistoryTrailPoint a = points[i];
    if (i == points.length - 1 || !tc.isAfter(a.ts)) {
      return ScrubSample(
        time: tc,
        position: a.position,
        index: i,
        speedMps: a.speedMps,
        batteryPct: a.batteryPct,
        motionState: a.motionState,
      );
    }
    final HistoryTrailPoint b = points[i + 1];
    final Duration gap = b.ts.difference(a.ts);
    if (gap > maxGap) {
      // Hold; an unreported stretch is not "moving".
      return ScrubSample(
        time: tc,
        position: a.position,
        index: i,
        speedMps: 0,
        batteryPct: a.batteryPct,
        motionState: a.motionState,
      );
    }
    final double f = tc.difference(a.ts).inMicroseconds / gap.inMicroseconds;
    final double? speed = (a.speedMps != null && b.speedMps != null)
        ? _lerp(a.speedMps!, b.speedMps!, f)
        : (a.speedMps ?? b.speedMps) ?? _derivedSpeed(a, b);
    return ScrubSample(
      time: tc,
      position: LatLng(
        _lerp(a.position.latitude, b.position.latitude, f),
        _lerp(a.position.longitude, b.position.longitude, f),
      ),
      index: i,
      speedMps: speed,
      batteryPct: a.batteryPct ?? b.batteryPct,
      motionState: a.motionState,
      interpolated: true,
    );
  }

  static double _lerp(double a, double b, double f) => a + (b - a) * f;

  static double? _derivedSpeed(HistoryTrailPoint a, HistoryTrailPoint b) {
    final double secs = b.ts.difference(a.ts).inMilliseconds / 1000;
    if (secs <= 0) return null;
    return metersBetween(a.position, b.position) / secs;
  }

  /// Splits the trail into stationary clusters. A cluster is a run of fixes
  /// within [radiusMeters] of the run's first fix, tolerating jitter, that
  /// lasts at least [minDwell]. Fixes after the last cluster-able run are
  /// moving.
  List<StopCluster> stops({
    double radiusMeters = kStopRadiusMeters,
    Duration minDwell = kStopMinDwell,
  }) {
    final List<StopCluster> out = <StopCluster>[];
    int i = 0;
    while (i < points.length) {
      int end = i;
      double latSum = points[i].position.latitude;
      double lonSum = points[i].position.longitude;
      int n = 1;
      for (int j = i + 1; j < points.length; j++) {
        if (metersBetween(points[i].position, points[j].position) >
            radiusMeters) {
          break;
        }
        end = j;
        latSum += points[j].position.latitude;
        lonSum += points[j].position.longitude;
        n++;
      }
      final Duration dwell = points[end].ts.difference(points[i].ts);
      if (end > i && dwell >= minDwell) {
        out.add(StopCluster(
          position: LatLng(latSum / n, lonSum / n),
          arrivedAt: points[i].ts,
          departedAt: points[end].ts,
          firstIndex: i,
          lastIndex: end,
        ));
        i = end + 1;
      } else {
        i++;
      }
    }
    return _mergeNearbyStops(out);
  }

  /// Consecutive stops at (nearly) the same spot, e.g. split by one jittery
  /// fix, become one.
  List<StopCluster> _mergeNearbyStops(List<StopCluster> stops) {
    if (stops.length < 2) return stops;
    final List<StopCluster> out = <StopCluster>[stops.first];
    for (final StopCluster s in stops.skip(1)) {
      final StopCluster prev = out.last;
      if (metersBetween(prev.position, s.position) <= kStopRadiusMeters &&
          s.arrivedAt.difference(prev.departedAt) <= const Duration(minutes: 5)) {
        out[out.length - 1] = StopCluster(
          position: prev.position,
          arrivedAt: prev.arrivedAt,
          departedAt: s.departedAt,
          firstIndex: prev.firstIndex,
          lastIndex: s.lastIndex,
        );
      } else {
        out.add(s);
      }
    }
    return out;
  }

  /// Indices (inclusive ranges) of fixes outside every stop: the drive
  /// segments to draw as solid lines. Each range includes the neighbouring
  /// stop's boundary fix so lines connect to the stop markers.
  List<List<int>> moveRanges(List<StopCluster> stops) {
    final List<List<int>> out = <List<int>>[];
    int cursor = 0;
    for (final StopCluster s in stops) {
      if (s.firstIndex > cursor) {
        out.add(<int>[cursor, s.firstIndex]);
      }
      cursor = s.lastIndex;
    }
    if (points.isNotEmpty && cursor < points.length - 1) {
      out.add(<int>[cursor, points.length - 1]);
    }
    return out;
  }

  /// Attaches the name of a saved place ("place" visit) overlapping each stop
  /// the most in time.
  List<StopCluster> nameStops(
    List<StopCluster> stops,
    List<HistoryVisit> visits,
  ) {
    return <StopCluster>[
      for (final StopCluster s in stops) s.withName(_nameFor(s, visits)),
    ];
  }

  static String? _nameFor(StopCluster s, List<HistoryVisit> visits) {
    String? best;
    Duration bestOverlap = Duration.zero;
    for (final HistoryVisit v in visits) {
      if (!v.isPlace) continue;
      final DateTime a = v.arrivedAt.isAfter(s.arrivedAt) ? v.arrivedAt : s.arrivedAt;
      final DateTime b = v.departedAt.isBefore(s.departedAt) ? v.departedAt : s.departedAt;
      final Duration o = b.difference(a);
      if (o > bestOverlap) {
        bestOverlap = o;
        best = v.placeName;
      }
    }
    return best;
  }

  /// The stop containing [t], if any.
  static StopCluster? stopAt(List<StopCluster> stops, DateTime t) {
    for (final StopCluster s in stops) {
      if (!t.isBefore(s.arrivedAt) && !t.isAfter(s.departedAt)) return s;
    }
    return null;
  }
}

/// Reduces [path] to at most [maxPoints] for drawing (Ramer-Douglas-Peucker
/// with a growing tolerance), always keeping first and last. Does not affect
/// the scrubber, which reads the full-resolution timeline.
List<LatLng> downsamplePath(List<LatLng> path, int maxPoints) {
  if (maxPoints < 2 || path.length <= maxPoints) {
    return List<LatLng>.of(path);
  }
  double eps = 1; // meters
  List<LatLng> out = path;
  for (int round = 0; round < 24 && out.length > maxPoints; round++) {
    out = _rdp(path, eps);
    eps *= 1.8;
  }
  if (out.length > maxPoints) {
    // Pathological input: fall back to even striding.
    final double step = (path.length - 1) / (maxPoints - 1);
    out = <LatLng>[
      for (int i = 0; i < maxPoints; i++) path[(i * step).round()],
    ];
  }
  return out;
}

List<LatLng> _rdp(List<LatLng> pts, double epsMeters) {
  final int n = pts.length;
  final List<bool> keep = List<bool>.filled(n, false);
  keep[0] = true;
  keep[n - 1] = true;
  final List<List<int>> stack = <List<int>>[<int>[0, n - 1]];
  while (stack.isNotEmpty) {
    final List<int> r = stack.removeLast();
    double maxD = 0;
    int idx = -1;
    for (int i = r[0] + 1; i < r[1]; i++) {
      final double d = _crossTrackMeters(pts[i], pts[r[0]], pts[r[1]]);
      if (d > maxD) {
        maxD = d;
        idx = i;
      }
    }
    if (idx != -1 && maxD > epsMeters) {
      keep[idx] = true;
      stack.add(<int>[r[0], idx]);
      stack.add(<int>[idx, r[1]]);
    }
  }
  return <LatLng>[
    for (int i = 0; i < n; i++)
      if (keep[i]) pts[i],
  ];
}

/// Distance from [p] to segment a-b using a local equirectangular projection.
double _crossTrackMeters(LatLng p, LatLng a, LatLng b) {
  const double mPerDeg = 111320;
  final double cosLat = math.cos(a.latitude * math.pi / 180);
  final double px = (p.longitude - a.longitude) * cosLat * mPerDeg;
  final double py = (p.latitude - a.latitude) * mPerDeg;
  final double bx = (b.longitude - a.longitude) * cosLat * mPerDeg;
  final double by = (b.latitude - a.latitude) * mPerDeg;
  final double len2 = bx * bx + by * by;
  if (len2 == 0) return math.sqrt(px * px + py * py);
  final double t = ((px * bx + py * by) / len2).clamp(0.0, 1.0);
  final double dx = px - bx * t;
  final double dy = py - by * t;
  return math.sqrt(dx * dx + dy * dy);
}

/// Playback speed multipliers.
const List<int> kPlaybackSpeeds = <int>[1, 4, 16];

/// Day-time advanced per real second at 1x. A full day at 1x plays in
/// ~24 minutes; at 16x in 90 s.
const Duration kPlaybackBase = Duration(minutes: 1);

/// New scrub time after [elapsed] real time at [multiplier]; clamps to [end].
DateTime advancePlayback(
  DateTime current,
  Duration elapsed,
  int multiplier,
  DateTime end,
) {
  final DateTime next = current.add(Duration(
    microseconds: (kPlaybackBase.inMicroseconds *
            multiplier *
            elapsed.inMicroseconds /
            Duration.microsecondsPerSecond)
        .round(),
  ));
  return next.isAfter(end) ? end : next;
}

/// Next speed in the 1x -> 4x -> 16x -> 1x cycle.
int nextPlaybackSpeed(int current) {
  final int i = kPlaybackSpeeds.indexOf(current);
  return kPlaybackSpeeds[(i + 1) % kPlaybackSpeeds.length];
}

/// Day navigation limits (local calendar days).
DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

DateTime oldestHistoryDay(DateTime today) =>
    DateTime(today.year, today.month, today.day - kHistoryMaxDaysBack);

bool canGoBackDay(DateTime day, DateTime today) =>
    dateOnly(day).isAfter(oldestHistoryDay(dateOnly(today)));

bool canGoForwardDay(DateTime day, DateTime today) =>
    dateOnly(day).isBefore(dateOnly(today));

/// [day] moved by [delta] days, or unchanged if it would leave the allowed range.
DateTime shiftHistoryDay(DateTime day, int delta, DateTime today) {
  final DateTime t = dateOnly(today);
  final DateTime next = DateTime(day.year, day.month, day.day + delta);
  if (next.isAfter(t) || next.isBefore(oldestHistoryDay(t))) {
    return dateOnly(day);
  }
  return next;
}

/// "Today", "Yesterday" or "Mon, Oct 26".
String historyDayLabel(DateTime day, DateTime today) {
  final DateTime d = dateOnly(day);
  final DateTime t = dateOnly(today);
  if (d == t) return 'Today';
  if (d == DateTime(t.year, t.month, t.day - 1)) return 'Yesterday';
  const List<String> wd = <String>['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const List<String> mo = <String>[
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${wd[d.weekday - 1]}, ${mo[d.month - 1]} ${d.day}';
}

/// "2 h 05 min" style dwell label.
String dwellLabel(Duration d) {
  final int mins = d.inMinutes;
  if (mins < 1) return '<1 min';
  if (mins < 60) return '$mins min';
  return '${mins ~/ 60} h ${(mins % 60).toString().padLeft(2, '0')} min';
}
