import 'package:openfamily/models/trip_report.dart';
import 'package:openfamily/services/trip_report_service.dart';

/// The API contract example, plus a second member.
Map<String, dynamic> reportJson({
  int speeding = 1,
  int hardBrake = 0,
  int rapidAccel = 0,
  int drives = 1,
  bool twoMembers = false,
}) => <String, dynamic>{
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

class FakeTripReportApi implements TripReportApi {
  FakeTripReportApi({this.result, this.error});

  Map<String, dynamic>? result;
  Object? error;
  final List<(DateTime, String?)> calls = <(DateTime, String?)>[];

  @override
  Future<TripReport> report({
    required DateTime start,
    String period = 'week',
    String? circleId,
  }) async {
    calls.add((start, circleId));
    if (error != null) throw error!;
    return TripReport.fromJson(result ?? reportJson());
  }

  @override
  Future<List<TripEvent>> tripEvents(String tripId) async => const <TripEvent>[];
}
