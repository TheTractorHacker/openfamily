import 'dart:math' as math;

import 'fix.dart';
import 'processing_params.dart';

/// One driving risk event inside a driving trip (Go `trips.Event`).
///
/// [magnitude] is the peak speed (m/s) for speeding and the peak acceleration
/// magnitude (m/s^2) for hard_brake / rapid_accel.
class DrivingEvent {
  const DrivingEvent({
    required this.kind,
    required this.startedAtUs,
    required this.endedAtUs,
    required this.magnitude,
    required this.lat,
    required this.lon,
  });

  final String kind;
  final int startedAtUs;
  final int endedAtUs;
  final double magnitude;
  final double lat;
  final double lon;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'kind': kind,
    'started_at': formatUtcMicros(startedAtUs),
    'ended_at': formatUtcMicros(endedAtUs),
    'magnitude': magnitude,
    'lat': lat,
    'lon': lon,
  };

  DrivingEvent copyWith({double? magnitude, double? lat, double? lon, int? endedAtUs}) =>
      DrivingEvent(
        kind: kind,
        startedAtUs: startedAtUs,
        endedAtUs: endedAtUs ?? this.endedAtUs,
        magnitude: magnitude ?? this.magnitude,
        lat: lat ?? this.lat,
        lon: lon ?? this.lon,
      );
}

/// Speed at fix [i]: device-reported if present, else distance / time from the
/// previous fix when within `maxSpeedingGap` (Go `fixSpeed`).
double? _fixSpeed(List<Fix> c, int i, EventParams ep, TripParams p) {
  final Fix f = c[i];
  if (f.hasDeviceSpeed) return math.min(f.speedMps!, p.maxPlausibleSpeedMps);
  if (i == 0) return null;
  final int dt = f.tsUs - c[i - 1].tsUs;
  if (dt <= 0 || dt > ep.maxSpeedingGap.inMicroseconds) return null;
  return haversine(c[i - 1].lat, c[i - 1].lon, f.lat, f.lon) / (dt / 1e6);
}

/// Finds speeding, hard braking and rapid acceleration in the fixes of ONE
/// driving leg (Go `trips.DetectEvents`). [input] is cleaned first. Output is
/// ordered by start time (stable).
List<DrivingEvent> detectEvents(
  Iterable<Fix> input, {
  EventParams ep = const EventParams(),
  TripParams p = const TripParams(),
}) {
  final List<Fix> c = cleanFixes(input, p);
  if (c.length < 2) return const <DrivingEvent>[];
  final List<double> v = List<double>.filled(c.length, 0);
  final List<bool> ok = List<bool>.filled(c.length, false);
  for (int i = 0; i < c.length; i++) {
    final double? s = _fixSpeed(c, i, ep, p);
    if (s != null) {
      v[i] = s;
      ok[i] = true;
    }
  }
  final List<DrivingEvent> out = <DrivingEvent>[
    ..._detectSpeeding(c, v, ok, ep),
    ..._detectAccel(c, v, ok, ep),
  ];
  return _stableSortByStart(out);
}

List<DrivingEvent> _stableSortByStart(List<DrivingEvent> l) {
  // Dart's List.sort is not guaranteed stable; decorate with the index.
  final List<MapEntry<int, DrivingEvent>> d = <MapEntry<int, DrivingEvent>>[
    for (int i = 0; i < l.length; i++) MapEntry<int, DrivingEvent>(i, l[i]),
  ];
  d.sort((MapEntry<int, DrivingEvent> a, MapEntry<int, DrivingEvent> b) {
    final int c = a.value.startedAtUs.compareTo(b.value.startedAtUs);
    return c != 0 ? c : a.key.compareTo(b.key);
  });
  return <DrivingEvent>[for (final MapEntry<int, DrivingEvent> e in d) e.value];
}

List<DrivingEvent> _detectSpeeding(
  List<Fix> c,
  List<double> v,
  List<bool> ok,
  EventParams ep,
) {
  if (ep.speedingMps <= 0) return const <DrivingEvent>[];
  final List<DrivingEvent> out = <DrivingEvent>[];
  int first = -1, last = -1, peak = 0;
  void flush() {
    if (first < 0) return;
    if ((c[last].tsUs - c[first].tsUs) / 1e6 >= ep.speedingSeconds) {
      out.add(
        DrivingEvent(
          kind: kEventSpeeding,
          startedAtUs: c[first].tsUs,
          endedAtUs: c[last].tsUs,
          magnitude: v[peak],
          lat: c[peak].lat,
          lon: c[peak].lon,
        ),
      );
    }
    first = -1;
    last = -1;
  }

  for (int i = 0; i < c.length; i++) {
    final bool over = ok[i] && v[i] > ep.speedingMps;
    if (!over) {
      flush();
      continue;
    }
    if (first >= 0 && c[i].tsUs - c[last].tsUs > ep.maxSpeedingGap.inMicroseconds) {
      flush();
    }
    if (first < 0) {
      first = i;
      peak = i;
    }
    last = i;
    if (v[i] > v[peak]) peak = i;
  }
  flush();
  return out;
}

List<DrivingEvent> _detectAccel(
  List<Fix> c,
  List<double> v,
  List<bool> ok,
  EventParams ep,
) {
  final List<DrivingEvent> out = <DrivingEvent>[];
  DrivingEvent? cur;
  int curEnd = 0;
  void flush() {
    if (cur != null) {
      out.add(cur!);
      cur = null;
    }
  }

  for (int i = 1; i < c.length; i++) {
    final int dt = c[i].tsUs - c[i - 1].tsUs;
    final bool valid =
        ok[i] &&
        ok[i - 1] &&
        dt >= ep.minAccelDt.inMicroseconds &&
        dt <= ep.maxAccelGap.inMicroseconds &&
        (ep.maxAccelAccuracyM <= 0 ||
            (c[i].accuracyM <= ep.maxAccelAccuracyM &&
                c[i - 1].accuracyM <= ep.maxAccelAccuracyM));
    String kind = '';
    double mag = 0;
    if (valid) {
      final double a = (v[i] - v[i - 1]) / (dt / 1e6);
      if (a.abs() > ep.maxPlausibleAccel) {
        // GPS jump: breaks any running episode.
      } else if (a <= -ep.hardBrakeMps2 && v[i - 1] >= ep.minMovingMps) {
        kind = kEventHardBrake;
        mag = -a;
      } else if (a >= ep.rapidAccelMps2 && v[i] >= ep.minMovingMps) {
        kind = kEventRapidAccel;
        mag = a;
      }
    }
    if (kind.isEmpty) {
      flush();
      continue;
    }
    if (cur != null && (cur!.kind != kind || curEnd != i - 1)) flush();
    if (cur == null) {
      cur = DrivingEvent(
        kind: kind,
        startedAtUs: c[i - 1].tsUs,
        endedAtUs: c[i].tsUs,
        magnitude: mag,
        lat: c[i].lat,
        lon: c[i].lon,
      );
    } else if (mag > cur!.magnitude) {
      cur = cur!.copyWith(magnitude: mag, lat: c[i].lat, lon: c[i].lon, endedAtUs: c[i].tsUs);
    } else {
      cur = cur!.copyWith(endedAtUs: c[i].tsUs);
    }
    curEnd = i;
  }
  flush();
  return out;
}

/// Mirrors the SQL view `trip_events_effective`: a GPS-derived event is hidden
/// when a sensor event of the same kind starts within 4 s of it. [sensor]
/// events (the phone's own detectors, existing `driving_event.dart` stream) are
/// always kept.
List<DrivingEvent> effectiveEvents(
  List<DrivingEvent> gps,
  List<DrivingEvent> sensor,
) {
  const int win = 4 * 1000000;
  final List<DrivingEvent> out = <DrivingEvent>[...sensor];
  for (final DrivingEvent e in gps) {
    final bool shadowed = sensor.any(
      (DrivingEvent s) =>
          s.kind == e.kind &&
          s.startedAtUs >= e.startedAtUs - win &&
          s.startedAtUs <= e.startedAtUs + win,
    );
    if (!shadowed) out.add(e);
  }
  return out;
}
