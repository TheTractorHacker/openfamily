import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/processing/processing.dart';

import 'fixture_support.dart';

DrivingEvent _ev(Map<String, dynamic> j) => DrivingEvent(
  kind: j['kind'] as String,
  startedAtUs: parseUtcMicros(j['started_at'] as String),
  endedAtUs: parseUtcMicros(j['started_at'] as String),
  magnitude: 0,
  lat: 0,
  lon: 0,
);

TripSummary _trip(Map<String, dynamic> j) => TripSummary(
  id: j['id'] as String,
  startedAtUs: parseUtcMicros(j['started_at'] as String),
  endedAtUs: parseUtcMicros(j['ended_at'] as String),
  distanceM: (j['distance_m'] as num).toDouble(),
  maxSpeedMps: (j['max_speed_mps'] as num).toDouble(),
  mode: j['mode'] as String,
);

void main() {
  final Map<String, dynamic> fx = loadFixture('weekly.json');

  test('safety score matches the server formula', () {
    for (final dynamic raw in fx['scores'] as List<dynamic>) {
      final Map<String, dynamic> c = raw as Map<String, dynamic>;
      final EventCountsOut ev = EventCountsOut(
        hardBrake: c['hard_brake'] as int,
        rapidAccel: c['rapid_accel'] as int,
        speeding: c['speeding'] as int,
        phone: c['phone'] as int,
      );
      expect(
        weeklySafetyScore(c['drives'] as int, (c['distance_m'] as num).toDouble(), ev),
        c['score'],
        reason: '$c',
      );
    }
  });

  test('report periods match computeReportPeriod', () {
    for (final dynamic raw in fx['periods'] as List<dynamic>) {
      final Map<String, dynamic> c = raw as Map<String, dynamic>;
      final String start = c['start'] as String;
      if ((c['error'] as String?)?.isNotEmpty ?? false) {
        expect(
          () => computeReportPeriod(
            c['period'] as String,
            start,
            c['now_us'] as int,
            c['offset_min'] as int,
          ),
          throwsArgumentError,
          reason: '$c',
        );
        continue;
      }
      final ReportPeriod p = computeReportPeriod(
        c['period'] as String,
        start,
        c['now_us'] as int,
        c['offset_min'] as int,
      );
      expect(p.startUs, c['start_us'], reason: '$c');
      expect(p.endUs, c['end_us'], reason: '$c');
      expect(p.prevStartUs, c['prev_start_us'], reason: '$c');
      expect(p.prevEndUs, c['prev_end_us'], reason: '$c');
      expect(p.startDay, c['start_day'], reason: '$c');
      expect(p.endDay, c['end_day'], reason: '$c');
      expect(p.prevStartDay, c['prev_start_day'], reason: '$c');
      expect(p.prevEndDay, c['prev_end_day'], reason: '$c');
    }
  });

  test('weeklyDue matches', () {
    for (final dynamic raw in fx['dues'] as List<dynamic>) {
      final Map<String, dynamic> c = raw as Map<String, dynamic>;
      final r = weeklyDue(c['now_us'] as int);
      expect(r.weekStartUs, c['week_start_us'], reason: '$c');
      expect(r.dueUs, c['due_us'], reason: '$c');
    }
  });

  for (final dynamic raw in fx['aggregations'] as List<dynamic>) {
    final Map<String, dynamic> c = raw as Map<String, dynamic>;
    test('aggregation ${c['name']} matches server queries', () {
      final List<TripSummary> trips = <TripSummary>[
        for (final dynamic t in c['trips'] as List<dynamic>) _trip(t as Map<String, dynamic>),
      ];
      final List<DrivingEvent> events = <DrivingEvent>[
        for (final dynamic e in c['events'] as List<dynamic>) _ev(e as Map<String, dynamic>),
      ];
      final bool phone = c['phone_use_enabled'] as bool;
      final int off = c['offset_min'] as int;
      final ReportPeriod per = computeReportPeriod('week', null, c['now_us'] as int, off);

      final List<String> diffs = <String>[];
      diffJson(c['week'], weeklyMemberJson(trips, events, per, phoneUseEnabled: phone), 'week', diffs);
      expect(diffs, isEmpty, reason: diffs.take(12).join('\n'));

      final Map<String, dynamic> rep = reportMemberJson(trips, events, per, off, phoneUseEnabled: phone);
      final Map<String, dynamic> exp = c['report'] as Map<String, dynamic>;
      final Map<String, dynamic> prev = rep['previous'] as Map<String, dynamic>;
      diffJson(
        <String, dynamic>{
          'drives': exp['drives'],
          'distance_m': exp['distance_m'],
          'top_speed_mps': exp['top_speed_mps'],
          'events': exp['events'],
          'previous_events': exp['previous_events'],
          'days': exp['days'],
          'recent_trips': exp['recent_trips'],
          'previous': <String, dynamic>{
            'drives': exp['prev_drives'],
            'distance_m': exp['prev_distance_m'],
            'top_speed_mps': exp['prev_top_speed_mps'],
          },
        },
        rep,
        'report',
        diffs,
      );
      expect(prev['drives'], exp['prev_drives']);
      expect(diffs, isEmpty, reason: diffs.take(12).join('\n'));
    });
  }
}
