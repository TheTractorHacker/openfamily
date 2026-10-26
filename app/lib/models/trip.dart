import 'package:latlong2/latlong.dart';

import 'trip_report.dart';

/// How a trip leg was classified by the server.
enum TripMode { driving, walking, other }

TripMode parseTripMode(Object? raw) {
  switch (raw) {
    case 'driving':
      return TripMode.driving;
    case 'walking':
      return TripMode.walking;
    default:
      return TripMode.other;
  }
}

double _num(Object? v) => v is num ? v.toDouble() : 0;

DateTime _time(Object? v) {
  if (v is String) {
    final DateTime? t = DateTime.tryParse(v);
    if (t != null) return t.toLocal();
  }
  throw const FormatException('Invalid timestamp in trips response.');
}

/// One movement leg. Speeds are GPS estimates in m/s, distance in metres,
/// duration in seconds (the units the backend documents).
class Trip {
  const Trip({
    required this.id,
    required this.userId,
    required this.startedAt,
    required this.endedAt,
    required this.durationS,
    required this.distanceM,
    required this.maxSpeedMps,
    required this.avgSpeedMps,
    required this.mode,
    required this.speedSource,
    required this.start,
    required this.end,
  });

  factory Trip.fromJson(Map<String, dynamic> j) {
    return Trip(
      id: (j['id'] ?? '').toString(),
      userId: (j['user_id'] ?? '').toString(),
      startedAt: _time(j['started_at']),
      endedAt: _time(j['ended_at']),
      durationS: _num(j['duration_s']),
      distanceM: _num(j['distance_m']),
      maxSpeedMps: _num(j['max_speed_mps']),
      avgSpeedMps: _num(j['avg_speed_mps']),
      mode: parseTripMode(j['mode']),
      speedSource: (j['speed_source'] ?? '').toString(),
      start: LatLng(_num(j['start_lat']), _num(j['start_lon'])),
      end: LatLng(_num(j['end_lat']), _num(j['end_lon'])),
    );
  }

  final String id;
  final String userId;
  final DateTime startedAt;
  final DateTime endedAt;
  final double durationS;
  final double distanceM;
  final double maxSpeedMps;
  final double avgSpeedMps;
  final TripMode mode;
  final String speedSource;
  final LatLng start;
  final LatLng end;

  Duration get duration => Duration(seconds: durationS.round());
}

/// A downsampled route sample; [speedMps] is absent when the device sent none.
class TripRoutePoint {
  const TripRoutePoint({
    required this.ts,
    required this.position,
    this.speedMps,
  });

  factory TripRoutePoint.fromJson(Map<String, dynamic> j) {
    return TripRoutePoint(
      ts: _time(j['ts']),
      position: LatLng(_num(j['lat']), _num(j['lon'])),
      speedMps: j['speed_mps'] is num ? (j['speed_mps'] as num).toDouble() : null,
    );
  }

  final DateTime ts;
  final LatLng position;
  final double? speedMps;
}

class TripDetail {
  const TripDetail({
    required this.trip,
    required this.route,
    this.events = const <TripEvent>[],
  });

  factory TripDetail.fromJson(Map<String, dynamic> j) {
    final Object? t = j['trip'];
    if (t is! Map<String, dynamic>) {
      throw const FormatException('Missing trip in response.');
    }
    final Object? r = j['route'];
    return TripDetail(
      trip: Trip.fromJson(t),
      route: r is List
          ? r
              .whereType<Map<String, dynamic>>()
              .map(TripRoutePoint.fromJson)
              .toList()
          : const <TripRoutePoint>[],
      events: parseTripEvents(j['events']),
    );
  }

  final Trip trip;
  final List<TripRoutePoint> route;

  /// Detected driving events (empty on older servers).
  final List<TripEvent> events;
}

/// A dwell between two consecutive trips.
class TripStop {
  const TripStop({
    required this.arrivedAt,
    required this.departedAt,
    required this.durationS,
    required this.position,
  });

  factory TripStop.fromJson(Map<String, dynamic> j) {
    return TripStop(
      arrivedAt: _time(j['arrived_at']),
      departedAt: _time(j['departed_at']),
      durationS: _num(j['duration_s']),
      position: LatLng(_num(j['lat']), _num(j['lon'])),
    );
  }

  final DateTime arrivedAt;
  final DateTime departedAt;
  final double durationS;
  final LatLng position;
}

/// Driving-only aggregate within a [TripSummary].
class DrivingStats {
  const DrivingStats({
    this.tripCount = 0,
    this.distanceM = 0,
    this.driveTimeS = 0,
    this.maxSpeedMps = 0,
    this.avgSpeedMps = 0,
    this.speedEvents = 0,
    this.speedEventsTruncated = false,
  });

  factory DrivingStats.fromJson(Map<String, dynamic> j) {
    return DrivingStats(
      tripCount: _num(j['trip_count']).round(),
      distanceM: _num(j['distance_m']),
      driveTimeS: _num(j['drive_time_s']),
      maxSpeedMps: _num(j['max_speed_mps']),
      avgSpeedMps: _num(j['avg_speed_mps']),
      speedEvents: _num(j['speed_events']).round(),
      speedEventsTruncated: j['speed_events_truncated'] == true,
    );
  }

  final int tripCount;
  final double distanceM;
  final double driveTimeS;
  final double maxSpeedMps;
  final double avgSpeedMps;
  final int speedEvents;
  final bool speedEventsTruncated;
}

class TripSummary {
  const TripSummary({
    required this.from,
    required this.to,
    required this.tripCount,
    required this.totalDistanceM,
    required this.driving,
    required this.speedThresholdMps,
    required this.stops,
  });

  factory TripSummary.fromJson(Map<String, dynamic> j) {
    final Object? d = j['driving'];
    final Object? s = j['stops'];
    return TripSummary(
      from: _time(j['from']),
      to: _time(j['to']),
      tripCount: _num(j['trip_count']).round(),
      totalDistanceM: _num(j['total_distance_m']),
      driving: d is Map<String, dynamic>
          ? DrivingStats.fromJson(d)
          : const DrivingStats(),
      speedThresholdMps: _num(j['speed_threshold_mps']),
      stops: s is List
          ? s.whereType<Map<String, dynamic>>().map(TripStop.fromJson).toList()
          : const <TripStop>[],
    );
  }

  /// Unwraps the `{"period":..., "summary": {...}}` envelope.
  factory TripSummary.fromResponse(Map<String, dynamic> body) {
    final Object? s = body['summary'];
    if (s is! Map<String, dynamic>) {
      throw const FormatException('Missing summary in response.');
    }
    return TripSummary.fromJson(s);
  }

  final DateTime from;
  final DateTime to;
  final int tripCount;
  final double totalDistanceM;
  final DrivingStats driving;
  final double speedThresholdMps;
  final List<TripStop> stops;
}

/// Trips that started on one local calendar day, newest first.
class TripDay {
  const TripDay(this.day, this.trips);

  final DateTime day;
  final List<Trip> trips;
}

/// Groups [trips] by the local day they started on; days newest first, trips
/// inside a day newest first.
List<TripDay> groupTripsByDay(List<Trip> trips) {
  final Map<DateTime, List<Trip>> byDay = <DateTime, List<Trip>>{};
  for (final Trip t in trips) {
    final DateTime l = t.startedAt.toLocal();
    byDay.putIfAbsent(DateTime(l.year, l.month, l.day), () => <Trip>[]).add(t);
  }
  final List<DateTime> days = byDay.keys.toList()
    ..sort((DateTime a, DateTime b) => b.compareTo(a));
  return <TripDay>[
    for (final DateTime d in days)
      TripDay(
        d,
        byDay[d]!..sort((Trip a, Trip b) => b.startedAt.compareTo(a.startedAt)),
      ),
  ];
}
