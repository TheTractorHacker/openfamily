import 'dart:math' as math;

import 'driving_events.dart';
import 'fix.dart';
import 'processing_params.dart';

/// One trip leg (Go `trips.Trip`). JSON keys equal the server's.
class ProcessedTrip {
  ProcessedTrip({
    required this.deviceId,
    required this.startedAtUs,
    required this.endedAtUs,
    required this.distanceM,
    required this.maxSpeedMps,
    required this.avgSpeedMps,
    required this.mode,
    required this.speedSource,
    required this.startLat,
    required this.startLon,
    required this.endLat,
    required this.endLon,
    required this.pointCount,
    this.events = const <DrivingEvent>[],
  });

  final String deviceId;
  final int startedAtUs;
  final int endedAtUs;
  final double distanceM;
  final double maxSpeedMps;
  final double avgSpeedMps;
  final String mode;
  final String speedSource;
  final double startLat;
  final double startLon;
  final double endLat;
  final double endLon;
  final int pointCount;

  /// Driving risk events (driving legs only); empty otherwise.
  final List<DrivingEvent> events;

  double get durationS => (endedAtUs - startedAtUs) / 1e6;

  ProcessedTrip withEvents(List<DrivingEvent> e) => ProcessedTrip(
    deviceId: deviceId,
    startedAtUs: startedAtUs,
    endedAtUs: endedAtUs,
    distanceM: distanceM,
    maxSpeedMps: maxSpeedMps,
    avgSpeedMps: avgSpeedMps,
    mode: mode,
    speedSource: speedSource,
    startLat: startLat,
    startLon: startLon,
    endLat: endLat,
    endLon: endLon,
    pointCount: pointCount,
    events: e,
  );

  /// Same keys as the server's trip row (without id/user_id) plus `events`.
  Map<String, dynamic> toJson() => <String, dynamic>{
    if (deviceId.isNotEmpty) 'device_id': deviceId,
    'started_at': formatUtcMicros(startedAtUs),
    'ended_at': formatUtcMicros(endedAtUs),
    'distance_m': distanceM,
    'max_speed_mps': maxSpeedMps,
    'avg_speed_mps': avgSpeedMps,
    'mode': mode,
    'speed_source': speedSource,
    'start_lat': startLat,
    'start_lon': startLon,
    'end_lat': endLat,
    'end_lon': endLon,
    'point_count': pointCount,
    'events': <Map<String, dynamic>>[
      for (final DrivingEvent e in events) e.toJson(),
    ],
  };
}

/// A stationary dwell (Go `trips.Stop`).
class ProcessedStop {
  const ProcessedStop({
    required this.startedAtUs,
    required this.endedAtUs,
    required this.lat,
    required this.lon,
    required this.pointCount,
    required this.open,
  });

  final int startedAtUs;
  final int endedAtUs;
  final double lat;
  final double lon;
  final int pointCount;

  /// True when the stop runs to the end of the input (true end unknown).
  final bool open;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'started_at': formatUtcMicros(startedAtUs),
    'ended_at': formatUtcMicros(endedAtUs),
    'lat': lat,
    'lon': lon,
    'point_count': pointCount,
    if (open) 'open': true,
  };
}

/// Final output of [TripSegmenter.finish].
class SegmentResult {
  SegmentResult({
    required this.trips,
    required this.stops,
    required this.stats,
    required this.safeUntilUs,
    required this.inProgress,
  });

  final List<ProcessedTrip> trips;
  final List<ProcessedStop> stops;
  final CleanStats stats;

  /// Instant up to which output is final (null when no fix was accepted).
  final int? safeUntilUs;
  final bool inProgress;
}

class _Step {
  _Step(this.dist, this.dtUs, this.speed, this.reported, this.label);
  double dist;
  final int dtUs;
  final double speed;
  final bool reported;
  final int label; // 68 'D', 83 'S', 45 '-'
}

class _Run {
  _Run(this.a, this.b, this.label);
  int a;
  int b;
  final int label;
}

const int _lD = 68, _lS = 83, _lStill = 45;

/// Splits the points of one movement into trips (Go `buildLegs`). Returns null
/// when the movement is below the minimum trip distance/duration.
List<ProcessedTrip>? buildLegs(List<Fix> pts, TripParams p) {
  if (pts.length < 2) return null;
  final List<_Step> steps = <_Step>[];
  double total = 0;
  for (int k = 1; k < pts.length; k++) {
    final Fix a = pts[k - 1], b = pts[k];
    final double d = haversine(a.lat, a.lon, b.lat, b.lon);
    final ({double speed, bool reported}) ss = stepSpeed(a, b, p);
    final _Step st = _Step(d, b.tsUs - a.tsUs, ss.speed, ss.reported, _lStill);
    if (d < p.noiseStepM ||
        (ss.reported && ss.speed < p.movingSpeedMps && d < kStationaryJitterM)) {
      st.dist = 0;
    }
    final _Step s2 = ss.speed >= p.driveSpeedMps
        ? _Step(st.dist, st.dtUs, st.speed, st.reported, _lD)
        : ss.speed >= p.movingSpeedMps
        ? _Step(st.dist, st.dtUs, st.speed, st.reported, _lS)
        : st;
    total += s2.dist;
    steps.add(s2);
  }
  final int durUs = pts.last.tsUs - pts.first.tsUs;
  if (total < p.minTripDistanceM || durUs < p.minTripDuration.inMicroseconds) {
    return null;
  }

  // Runs of equal label; still steps inherit the running label.
  final List<_Run> runs = <_Run>[];
  int cur = 0;
  for (int i = 0; i < steps.length; i++) {
    int l = steps[i].label;
    if (l == _lStill) {
      if (cur == 0) continue;
      l = cur;
    }
    if (l != cur) {
      if (runs.isNotEmpty) runs.last.b = i;
      runs.add(_Run(i, 0, l));
      cur = l;
    }
  }
  if (runs.isEmpty) runs.add(_Run(0, steps.length, _lS));
  runs.first.a = 0;
  runs.last.b = steps.length;

  (int, double) measure(_Run r) {
    int d = 0;
    double m = 0;
    for (int i = r.a; i < r.b; i++) {
      d += steps[i].dtUs;
      m += steps[i].dist;
    }
    return (d, m);
  }

  // Absorb legs that are too short into their neighbour, then coalesce.
  for (bool changed = true; changed && runs.length > 1;) {
    changed = false;
    for (int i = 0; i < runs.length; i++) {
      final _Run r = runs[i];
      final (int d, double m) = measure(r);
      if (d >= p.minLegDuration.inMicroseconds && m >= p.minLegDistanceM) {
        continue;
      }
      if (i == 0) {
        runs[1].a = r.a;
        runs.removeAt(0);
      } else {
        runs[i - 1].b = r.b;
        runs.removeAt(i);
      }
      changed = true;
      break;
    }
    for (int i = 1; i < runs.length;) {
      if (runs[i].label == runs[i - 1].label) {
        runs[i - 1].b = runs[i].b;
        runs.removeAt(i);
      } else {
        i++;
      }
    }
  }

  return <ProcessedTrip>[
    for (final _Run r in runs)
      _makeTrip(pts.sublist(r.a, r.b + 1), steps.sublist(r.a, r.b)),
  ];
}

ProcessedTrip _makeTrip(List<Fix> pts, List<_Step> steps) {
  final Fix first = pts.first, last = pts.last;
  double dist = 0, maxSp = 0;
  final List<double> moving = <double>[];
  int rep = 0, der = 0;
  for (final _Step s in steps) {
    dist += s.dist;
    if (s.speed > maxSp) maxSp = s.speed;
    if (s.speed >= 0 && s.label != _lStill) {
      moving.add(s.speed);
      if (s.reported) {
        rep++;
      } else {
        der++;
      }
    }
  }
  final double dur = (last.tsUs - first.tsUs) / 1e6;
  final double avg = dur > 0 ? dist / dur : 0;
  final String src = (rep > 0 && der > 0)
      ? kSourceMixed
      : rep > 0
      ? kSourceDevice
      : kSourceDerived;
  return ProcessedTrip(
    deviceId: first.deviceId,
    startedAtUs: first.tsUs,
    endedAtUs: last.tsUs,
    distanceM: dist,
    maxSpeedMps: maxSp,
    avgSpeedMps: avg,
    mode: _classify(moving),
    speedSource: src,
    startLat: first.lat,
    startLon: first.lon,
    endLat: last.lat,
    endLon: last.lon,
    pointCount: pts.length,
  );
}

String _classify(List<double> moving) {
  if (moving.isEmpty) return kModeWalking;
  moving.sort();
  final double p90 = moving[(0.9 * moving.length).ceil() - 1];
  if (p90 >= kDrivingP90Mps) return kModeDriving;
  if (p90 <= kWalkingP90Mps) return kModeWalking;
  return kModeOther;
}

enum _Phase { stationary, moving }

/// Streaming trip/stop segmenter, a resumable state machine that follows the
/// control flow of Go `trips.Segment` step for step, so for the same input and
/// [finish] it yields the same trips and stops.
///
/// Usage: call [add] for every fix in time order; call [takeNew] whenever
/// results are wanted (e.g. after each batch); call [finish] at the end of the
/// input (or never: an open trip then simply stays pending and is resumed by
/// the next [add]).
///
/// Memory: fixes are kept only from the start of the current stop (needed for
/// its centroid) and through the current trip (needed to build its legs and
/// events). Once a stationary period exceeds [maxStopFixes] retained fixes,
/// the middle of the stop is folded into running sums (exact for the centroid
/// and point count; see PROCESSING_ON_DEVICE.md for the one theoretical
/// inexactness). No work is O(total history).
///
/// Not thread-safe; one instance per device/user, owned by one isolate.
class TripSegmenter {
  TripSegmenter({
    this.params = const TripParams(),
    this.eventParams = const EventParams(),
    this.finalizeOpen = false,
    this.maxStopFixes = 2048,
    this.keepTail = 64,
  }) : _cleaner = FixCleaner(params);

  final TripParams params;
  final EventParams eventParams;

  /// Close a trip still in progress at [finish] instead of leaving it out.
  final bool finalizeOpen;
  final int maxStopFixes;
  final int keepTail;

  final FixCleaner _cleaner;
  final List<Fix> _c = <Fix>[];

  final List<ProcessedTrip> _newTrips = <ProcessedTrip>[];
  final List<ProcessedStop> _newStops = <ProcessedStop>[];

  _Phase _phase = _Phase.stationary;
  int _anchor = 0, _stopFrom = 0, _i = 1;
  // moving phase
  int _s = 0, _ca = 0, _j = 0;

  // Folded part of the current stop (fixes removed from the buffer).
  double _foldLat = 0, _foldLon = 0;
  int _foldInRadius = 0, _foldCount = 0;

  bool _finished = false;
  bool _inProgress = false;
  int? _safeUntilUs;
  int? _lastTsUs;

  /// Fixes currently buffered (for diagnostics and the memory bound tests).
  int get bufferedFixes => _c.length;

  CleanStats get stats => _cleaner.stats;

  /// True while a trip is open (departure seen, arrival not yet).
  bool get tripInProgress => _phase == _Phase.moving;

  double _radius(Fix a, Fix b) =>
      math.max(params.stopRadiusM, math.max(a.accuracyM, b.accuracyM));

  bool _within(int a, int b) =>
      haversine(_c[a].lat, _c[a].lon, _c[b].lat, _c[b].lon) <=
      _radius(_c[a], _c[b]);

  bool _gap(int i) => _c[i].tsUs - _c[i - 1].tsUs > params.maxGap.inMicroseconds;

  /// Feeds one raw fix. Fixes must arrive in time order; others are rejected
  /// by the cleaner exactly like the server does.
  void add(Fix f) {
    if (_finished) throw StateError('TripSegmenter already finished');
    final Fix? a = _cleaner.accept(f);
    if (a == null) return;
    _c.add(a);
    _lastTsUs = a.tsUs;
    _advance(false);
    _compact();
  }

  void addAll(Iterable<Fix> fixes) {
    for (final Fix f in fixes) {
      add(f);
    }
  }

  /// Returns (and clears) the trips and stops finalized since the last call.
  ({List<ProcessedTrip> trips, List<ProcessedStop> stops}) takeNew() {
    final List<ProcessedTrip> t = List<ProcessedTrip>.of(_newTrips);
    final List<ProcessedStop> s = List<ProcessedStop>.of(_newStops);
    _newTrips.clear();
    _newStops.clear();
    return (trips: t, stops: s);
  }

  /// The stop that currently runs to the last fix, if long enough. Not final.
  ProcessedStop? get openStop {
    if (_phase != _Phase.stationary || _c.isEmpty) return null;
    return _buildStop(_stopFrom, _c.length - 1, true);
  }

  /// Ends the input. Returns everything not yet taken plus the status flags.
  SegmentResult finish() {
    if (!_finished) {
      _advance(true);
      _finished = true;
    }
    final ({List<ProcessedTrip> trips, List<ProcessedStop> stops}) n = takeNew();
    return SegmentResult(
      trips: n.trips,
      stops: n.stops,
      stats: _cleaner.stats,
      safeUntilUs: _inProgress ? _safeUntilUs : _lastTsUs,
      inProgress: _inProgress,
    );
  }

  // ---- state machine (Go Segment) ----

  void _setStopFrom(int v) {
    _stopFrom = v;
    _foldLat = _foldLon = 0;
    _foldInRadius = _foldCount = 0;
  }

  ProcessedStop? _buildStop(int from, int to, bool open) {
    if (to <= from ||
        _c[to].tsUs - _c[from].tsUs < params.stopDuration.inMicroseconds) {
      return null;
    }
    double sl = _foldLat, so = _foldLon;
    int k = _foldInRadius;
    for (int x = from; x <= to; x++) {
      if (_within(from, x)) {
        sl += _c[x].lat;
        so += _c[x].lon;
        k++;
      }
    }
    return ProcessedStop(
      startedAtUs: _c[from].tsUs,
      endedAtUs: _c[to].tsUs,
      lat: sl / k,
      lon: so / k,
      pointCount: to - from + 1 + _foldCount,
      open: open,
    );
  }

  void _emitStop(int from, int to, bool open) {
    final ProcessedStop? s = _buildStop(from, to, open);
    if (s != null) _newStops.add(s);
  }

  void _advance(bool fin) {
    final int n = _c.length;
    while (true) {
      if (_phase == _Phase.stationary) {
        if (_i >= n) break;
        final int i = _i;
        if (_gap(i)) {
          _emitStop(_stopFrom, i - 1, false);
          _anchor = i;
          _setStopFrom(i);
          _i++;
          continue;
        }
        if (_within(_anchor, i)) {
          _i++;
          continue;
        }
        if (i + 1 >= n) {
          if (!fin) return; // need the next fix to decide
          _i++;
          continue;
        }
        if (_gap(i + 1) || _within(_anchor, i + 1)) {
          _i++;
          continue;
        }
        int s = i - 1;
        final double dt = (_c[i + 1].tsUs - _c[s].tsUs) / 1e6;
        if (haversine(_c[s].lat, _c[s].lon, _c[i + 1].lat, _c[i + 1].lon) / dt <
            params.movingSpeedMps) {
          _i++;
          continue;
        }
        while (s - 1 >= _anchor) {
          if (stepSpeed(_c[s - 1], _c[s], params).speed < params.movingSpeedMps) {
            break;
          }
          s--;
        }
        _s = s;
        _ca = s;
        _j = s + 1;
        _phase = _Phase.moving;
        continue;
      }

      // Moving phase.
      int end = -1, resume = n;
      bool gapEnded = false;
      bool decided = false;
      while (_j < n) {
        final int j = _j;
        if (_gap(j)) {
          end = j - 1;
          resume = j;
          gapEnded = true;
          decided = true;
          break;
        }
        if (_within(_ca, j)) {
          if (_c[j].tsUs - _c[_ca].tsUs >= params.stopDuration.inMicroseconds) {
            end = _ca;
            while (end + 1 <= j) {
              if (stepSpeed(_c[end], _c[end + 1], params).speed <
                  params.movingSpeedMps) {
                break;
              }
              end++;
            }
            resume = j + 1;
            decided = true;
            break;
          }
        } else {
          _ca = j;
        }
        _j++;
      }
      if (!decided) {
        if (!fin) return; // wait for more fixes
        if (finalizeOpen) {
          end = _ca;
          resume = n;
        } else {
          _inProgress = true;
          _safeUntilUs = _c[_s].tsUs;
          _emitStop(_stopFrom, _s, false);
          _phase = _Phase.stationary;
          _i = n; // done
          _donePending = true;
          return;
        }
      }
      final int s = _s;
      final List<ProcessedTrip>? legs = buildLegs(_c.sublist(s, end + 1), params);
      final List<ProcessedTrip>? withEv = legs == null
          ? null
          : _attachEvents(legs, s, end);
      if (gapEnded) {
        if (withEv != null) {
          _emitStop(_stopFrom, s, false);
          _newTrips.addAll(withEv);
        } else {
          _emitStop(_stopFrom, end, false);
        }
        _anchor = resume;
        _setStopFrom(resume);
        _i = resume + 1;
      } else {
        if (withEv != null) {
          _emitStop(_stopFrom, s, false);
          _newTrips.addAll(withEv);
          _setStopFrom(end);
        }
        _anchor = end;
        _i = resume;
      }
      _phase = _Phase.stationary;
    }
    if (fin && _phase == _Phase.stationary && !_donePending && n > 0) {
      _emitStop(_stopFrom, n - 1, true);
    }
  }

  bool _donePending = false;

  List<ProcessedTrip> _attachEvents(List<ProcessedTrip> legs, int s, int end) {
    final List<ProcessedTrip> out = <ProcessedTrip>[];
    for (final ProcessedTrip t in legs) {
      if (t.mode != kModeDriving) {
        out.add(t);
        continue;
      }
      // Cleaned fixes with started <= ts <= ended (Go attachEvents; the leg
      // lies inside _c[s..end]).
      final List<Fix> slice = <Fix>[];
      for (int x = s; x <= end; x++) {
        final int ts = _c[x].tsUs;
        if (ts < t.startedAtUs) continue;
        if (ts > t.endedAtUs) break;
        slice.add(_c[x]);
      }
      out.add(t.withEvents(detectEvents(slice, ep: eventParams, p: params)));
    }
    return out;
  }

  /// Drops fixes that can no longer matter and folds very long stops.
  void _compact() {
    if (_phase == _Phase.stationary) {
      // Fold the middle of a long stop.
      final int hi = math.min(
        _anchor == _stopFrom ? 1 << 30 : _anchor,
        _i - keepTail,
      );
      if (_c.length - _stopFrom > maxStopFixes && hi > _stopFrom + 1) {
        int removed = 0;
        for (int x = _stopFrom + 1; x < hi; x++) {
          if (_within(_stopFrom, x)) {
            _foldLat += _c[x].lat;
            _foldLon += _c[x].lon;
            _foldInRadius++;
          }
          removed++;
        }
        _c.removeRange(_stopFrom + 1, hi);
        _foldCount += removed;
        _i -= removed;
        if (_anchor > _stopFrom) _anchor -= removed;
      }
    }
    if (_stopFrom >= 64) {
      final int k = _stopFrom;
      _c.removeRange(0, k);
      _anchor -= k;
      _stopFrom -= k;
      _i -= k;
      _s -= k;
      _ca -= k;
      _j -= k;
    }
  }
}

/// Batch convenience equal to Go `trips.Segment` + `attachEvents`.
SegmentResult segmentFixes(
  Iterable<Fix> input, {
  TripParams params = const TripParams(),
  EventParams eventParams = const EventParams(),
  bool finalizeOpen = false,
  int maxStopFixes = 2048,
}) {
  final TripSegmenter s = TripSegmenter(
    params: params,
    eventParams: eventParams,
    finalizeOpen: finalizeOpen,
    maxStopFixes: maxStopFixes,
  );
  s.addAll(input);
  return s.finish();
}
