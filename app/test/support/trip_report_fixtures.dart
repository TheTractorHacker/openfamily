import 'package:openfamily/models/trip_report.dart';
import 'package:openfamily/services/trip_report_service.dart';

/// The API contract example, plus a second member.
Map<String, dynamic> reportJson({
  int speeding = 1,
  int hardBrake = 0,
  int rapidAccel = 0,
  int drives = 1,
  bool twoMembers = false,
  bool rich = false,
  bool sensor = false,
}) => <String, dynamic>{
  if (rich) ...richParts(drives: drives, sensor: sensor),
  'period': 'week',
  'start': '2026-10-19',
  'end': '2026-10-25',
  'prev_start': '2026-10-12',
  'prev_end': '2026-10-18',
  'totals': <String, dynamic>{
    'drives': drives,
    'distance_m': drives == 0 ? 0 : 48000,
    'top_speed_mps': drives == 0 ? null : 37.5,
    'top_speed_user_id': drives == 0 ? null : 'u1',
    'events': <String, dynamic>{
      'speeding': speeding,
      'hard_brake': hardBrake,
      'rapid_accel': rapidAccel,
      'phone_use': null,
    },
  },
  'previous_totals': <String, dynamic>{
    'drives': 2,
    'distance_m': 30000,
    'top_speed_mps': 30.0,
    'top_speed_user_id': 'u1',
    'events': <String, dynamic>{
      'speeding': 2,
      'hard_brake': 0,
      'rapid_accel': 1,
      'phone_use': null,
    },
  },
  'members': <Map<String, dynamic>>[
    <String, dynamic>{
      'user_id': 'u1',
      'name': 'Blake',
      'drives': drives,
      'distance_m': drives == 0 ? 0 : 48000,
      'top_speed_mps': drives == 0 ? null : 37.5,
      'events': <String, dynamic>{
        'speeding': speeding - (twoMembers ? 1 : 0),
        'hard_brake': hardBrake,
        'rapid_accel': rapidAccel,
        'phone_use': null,
      },
      'previous_events': <String, dynamic>{
        'speeding': 2,
        'hard_brake': 0,
        'rapid_accel': 1,
        'phone_use': null,
      },
    },
    <String, dynamic>{
      'user_id': 'u2',
      'name': 'Brian',
      'drives': twoMembers ? 1 : 0,
      'distance_m': twoMembers ? 9000 : 0,
      'top_speed_mps': null,
      'events': <String, dynamic>{
        'speeding': twoMembers ? 1 : 0,
        'hard_brake': 0,
        'rapid_accel': 0,
        'phone_use': null,
      },
      'previous_events': <String, dynamic>{
        'speeding': 0,
        'hard_brake': 0,
        'rapid_accel': 0,
        'phone_use': null,
      },
    },
  ],
  'thresholds': <String, dynamic>{
    'speeding_mps': 35.76,
    'speeding_seconds': 30,
    'hard_brake_mps2': 3.5,
    'rapid_accel_mps2': 3.5,
  },
  'estimated': true,
};

/// `days` (week of 2026-10-19, today is Mon 2026-10-26 in the screen tests, so
/// the last bar is the previous Sunday) and `recent_trips`.
Map<String, dynamic> richParts({int drives = 1, bool sensor = false}) {
  final List<double> km = <double>[0, 12000, 0, 8000, 20000, 0, 8000];
  final List<Map<String, dynamic>> days = <Map<String, dynamic>>[
    for (int i = 0; i < 7; i++)
      <String, dynamic>{
        'date': '2026-10-${19 + i}',
        'drives': km[i] == 0 ? 0 : (i == 4 ? 2 : 1),
        'distance_m': km[i],
        'top_speed_mps': km[i] == 0 ? 0 : 25.0 + i,
      },
  ];
  Map<String, dynamic> trip(String id, String user, String name, String at, double d,
          int speeding, int brake) =>
      <String, dynamic>{
        'id': id,
        'user_id': user,
        'name': name,
        'started_at': at,
        'ended_at': at.replaceFirst(':00:00', ':25:00'),
        'distance_m': d,
        'duration_s': 1500,
        'max_speed_mps': 29.0,
        'mode': 'driving',
        'event_counts': <String, dynamic>{
          'speeding': speeding,
          'hard_brake': brake,
          'rapid_accel': 0,
          'phone_use': sensor ? 0 : null,
        },
      };
  return <String, dynamic>{
    'days': days,
    'sensor_members': sensor ? <String>['u1'] : <String>[],
    'recent_trips': drives == 0
        ? <Map<String, dynamic>>[]
        : <Map<String, dynamic>>[
            trip('t3', 'u1', 'Blake', '2026-10-25T08:00:00', 8000, 0, 0),
            trip('t2', 'u1', 'Blake', '2026-10-23T17:00:00', 12000, 1, 2),
            trip('t1', 'u2', 'Brian', '2026-10-23T09:00:00', 8000, 0, 0),
          ],
  };
}

class FakeTripReportApi implements TripReportApi {
  FakeTripReportApi({this.result, this.error});

  Map<String, dynamic>? result;
  Object? error;
  final List<(DateTime, String?)> calls = <(DateTime, String?)>[];
  final List<String> periods = <String>[];

  @override
  Future<TripReport> report({
    required DateTime start,
    String period = 'week',
    String? circleId,
  }) async {
    calls.add((start, circleId));
    periods.add(period);
    if (error != null) throw error!;
    return TripReport.fromJson(result ?? reportJson());
  }

  @override
  Future<List<TripEvent>> tripEvents(String tripId) async => const <TripEvent>[];
}
