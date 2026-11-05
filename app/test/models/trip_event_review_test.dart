import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/trip.dart';
import 'package:openfamily/models/trip_report.dart';

void main() {
  test('phone use events parse the optional detail', () {
    final TripEvent e = TripEvent.tryParse(<String, dynamic>{
      'id': 'x',
      'kind': 'phone_use',
      'started_at': '2026-10-24T17:05:00Z',
      'ended_at': '2026-10-24T17:05:20Z',
      'magnitude': 14,
      'lat': null,
      'lon': null,
      'max_speed_mps': 21.5,
      'confidence': 0.4,
      'activity': 'call',
      'dismissed': true,
    })!;
    expect(e.maxSpeedMps, 21.5);
    expect(e.activity, 'call');
    expect(e.dismissed, isTrue);
    expect(e.possibleFalseAlarm, isTrue);
    expect(e.span, const Duration(seconds: 20));
  });

  test('old servers send none of it', () {
    final TripEvent e = TripEvent.tryParse(<String, dynamic>{
      'id': 'x',
      'kind': 'phone_use',
      'started_at': '2026-10-24T17:05:00Z',
      'magnitude': 14,
    })!;
    expect(e.confidence, isNull);
    expect(e.dismissed, isFalse);
    expect(e.possibleFalseAlarm, isFalse);
    final TripDetail d = TripDetail.fromJson(<String, dynamic>{
      'trip': <String, dynamic>{
        'id': 'a', 'user_id': 'u', 'started_at': '2026-10-24T17:00:00Z',
        'ended_at': '2026-10-24T17:20:00Z', 'duration_s': 1200,
        'distance_m': 1000, 'max_speed_mps': 10, 'avg_speed_mps': 5,
        'mode': 'driving', 'speed_source': 'device_gps',
        'start_lat': 1, 'start_lon': 2, 'end_lat': 3, 'end_lon': 4,
      },
      'passenger': true,
    });
    expect(d.passenger, isTrue);
  });
}
