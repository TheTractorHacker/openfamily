import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/trip.dart';

const Map<String, dynamic> _tripJson = <String, dynamic>{
  'id': 'a1b2',
  'user_id': 'u1',
  'device_id': 'd1',
  'started_at': '2026-10-24T13:05:00Z',
  'ended_at': '2026-10-24T13:35:30Z',
  'duration_s': 1830.0,
  'distance_m': 21450.5,
  'max_speed_mps': 31.2,
  'avg_speed_mps': 11.7,
  'mode': 'driving',
  'speed_source': 'device_gps',
  'start_lat': 40.1,
  'start_lon': -74.2,
  'end_lat': 40.3,
  'end_lon': -74.0,
  'point_count': 212,
};

void main() {
  test('parses a trip row', () {
    final Trip t = Trip.fromJson(_tripJson);
    expect(t.mode, TripMode.driving);
    expect(t.distanceM, 21450.5);
    expect(t.maxSpeedMps, 31.2);
    expect(t.duration, const Duration(seconds: 1830));
    expect(t.startedAt.toUtc().hour, 13);
    expect(t.end.longitude, -74.0);
  });

  test('unknown mode and integer numbers are tolerated', () {
    final Trip t = Trip.fromJson(<String, dynamic>{
      ..._tripJson,
      'mode': 'cycling',
      'distance_m': 900,
    });
    expect(t.mode, TripMode.other);
    expect(t.distanceM, 900.0);
  });

  test('bad timestamp throws FormatException', () {
    expect(
      () => Trip.fromJson(<String, dynamic>{..._tripJson, 'started_at': 'x'}),
      throwsFormatException,
    );
  });

  test('parses trip detail with optional point speeds', () {
    final TripDetail d = TripDetail.fromJson(<String, dynamic>{
      'units': <String, String>{'speed': 'm/s'},
      'trip': _tripJson,
      'route': <Map<String, dynamic>>[
        <String, dynamic>{'ts': '2026-10-24T13:05:00Z', 'lat': 40.1, 'lon': -74.2},
        <String, dynamic>{
          'ts': '2026-10-24T13:06:00Z',
          'lat': 40.11,
          'lon': -74.19,
          'speed_mps': 12.5,
        },
      ],
    });
    expect(d.route, hasLength(2));
    expect(d.route.first.speedMps, isNull);
    expect(d.route.last.speedMps, 12.5);
  });

  test('parses the summary envelope', () {
    final TripSummary s = TripSummary.fromResponse(<String, dynamic>{
      'period': 'week',
      'summary': <String, dynamic>{
        'user_id': 'u1',
        'from': '2026-10-19T00:00:00Z',
        'to': '2026-10-26T00:00:00Z',
        'trip_count': 9,
        'trips_by_mode': <String, int>{'driving': 5, 'walking': 4},
        'total_distance_m': 50000.0,
        'driving': <String, dynamic>{
          'trip_count': 5,
          'distance_m': 48000.0,
          'drive_time_s': 3600.0,
          'max_speed_mps': 33.0,
          'avg_speed_mps': 13.3,
          'speed_events': 2,
          'speed_events_truncated': true,
        },
        'speed_threshold_mps': 31.3,
        'stop_count': 1,
        'stops': <Map<String, dynamic>>[
          <String, dynamic>{
            'arrived_at': '2026-10-20T10:00:00Z',
            'departed_at': '2026-10-20T10:20:00Z',
            'duration_s': 1200.0,
            'lat': 40.0,
            'lon': -74.0,
          },
        ],
      },
    });
    expect(s.tripCount, 9);
    expect(s.driving.speedEvents, 2);
    expect(s.driving.speedEventsTruncated, isTrue);
    expect(s.stops.single.durationS, 1200);
  });

  test('summary tolerates empty stops and missing driving block', () {
    final TripSummary s = TripSummary.fromJson(<String, dynamic>{
      'from': '2026-10-24T00:00:00Z',
      'to': '2026-10-25T00:00:00Z',
      'trip_count': 0,
      'stops': null,
    });
    expect(s.stops, isEmpty);
    expect(s.driving.tripCount, 0);
  });

  test('groups trips by local day, newest first', () {
    Trip at(String id, DateTime local) => Trip.fromJson(<String, dynamic>{
          ..._tripJson,
          'id': id,
          'started_at': local.toUtc().toIso8601String(),
          'ended_at': local.add(const Duration(minutes: 10)).toUtc().toIso8601String(),
        });
    final List<TripDay> days = groupTripsByDay(<Trip>[
      at('a', DateTime(2026, 10, 23, 9)),
      at('b', DateTime(2026, 10, 24, 8)),
      at('c', DateTime(2026, 10, 24, 17)),
    ]);
    expect(days.map((TripDay d) => d.day.day), <int>[24, 23]);
    expect(days.first.trips.map((Trip t) => t.id), <String>['c', 'b']);
  });
}
