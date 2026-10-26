import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/trip.dart';
import 'package:openfamily/models/trip_report.dart';
import 'package:openfamily/services/speed_units.dart';
import 'package:openfamily/widgets/driving_event_sheet.dart';

import '../support/trip_report_fixtures.dart';

void main() {
  group('TripReport.fromJson', () {
    test('parses the contract example', () {
      final TripReport r = TripReport.fromJson(reportJson());
      expect(r.start, DateTime(2026, 10, 19));
      expect(r.prevEnd, DateTime(2026, 10, 18));
      expect(r.totals.drives, 1);
      expect(r.totals.distanceM, 48000);
      expect(r.totals.topSpeedMps, 37.5);
      expect(r.totals.topSpeedUserId, 'u1');
      expect(r.totals.events.speeding, 1);
      expect(r.totals.events.phoneUse, isNull, reason: 'null = not tracked');
      expect(r.members, hasLength(2));
      expect(r.members.first.previousEvents.speeding, 2);
      expect(r.thresholds.speedingMps, 35.76);
      expect(r.thresholds.speedingSeconds, 30);
      expect(r.estimated, isTrue);
      expect(r.isEmpty, isFalse);
    });

    test('empty week has null top speed and no drives', () {
      final TripReport r = TripReport.fromJson(
        reportJson(drives: 0, speeding: 0),
      );
      expect(r.isEmpty, isTrue);
      expect(r.totals.topSpeedMps, isNull);
    });

    test('rejects a bad date', () {
      final Map<String, dynamic> j = reportJson()..['start'] = 'nope';
      expect(() => TripReport.fromJson(j), throwsFormatException);
    });

    test('membersWith lists only members with incidents, most first', () {
      final TripReport r = TripReport.fromJson(
        reportJson(speeding: 3, twoMembers: true),
      );
      final List<MemberReport> w = r.membersWith(DrivingEventKind.speeding);
      expect(w.map((MemberReport m) => m.userId), <String>['u1', 'u2']);
      expect(r.membersWith(DrivingEventKind.hardBrake), isEmpty);
    });

    test('risky counts only tracked kinds', () {
      expect(
        const EventCounts(speeding: 1, hardBrake: 2, rapidAccel: 3).risky,
        6,
      );
    });
  });

  group('trend', () {
    test('fewer is down, more is up', () {
      expect(trendOf(0, 2), Trend.fewer);
      expect(trendOf(3, 2), Trend.more);
      expect(trendOf(2, 2), Trend.same);
    });
    test('untracked is unknown, never zero', () {
      expect(trendOf(null, 2), Trend.unknown);
      expect(trendOf(2, null), Trend.unknown);
    });
    test('text carries the meaning', () {
      expect(trendText(Trend.fewer, 2), 'down from 2');
      expect(trendText(Trend.more, 1), 'up from 1');
      expect(trendText(Trend.same, 1), 'no change');
      expect(trendText(Trend.unknown, null), 'no earlier data');
    });
    test('report trend per kind', () {
      final TripReport r = TripReport.fromJson(reportJson());
      expect(r.trend(DrivingEventKind.speeding), Trend.fewer);
      expect(r.trend(DrivingEventKind.rapidAccel), Trend.fewer);
      expect(r.trend(DrivingEventKind.hardBrake), Trend.same);
      expect(r.trend(DrivingEventKind.phoneUse), Trend.unknown);
    });
  });

  group('weeks', () {
    test('weekStartOf is Monday', () {
      expect(weekStartOf(DateTime(2026, 10, 25)), DateTime(2026, 10, 19));
      expect(weekStartOf(DateTime(2026, 10, 26, 23)), DateTime(2026, 10, 26));
      expect(weekStartOf(DateTime(2026, 1, 1)), DateTime(2025, 12, 29));
    });
    test('presets', () {
      final DateTime now = DateTime(2026, 10, 26, 9);
      expect(presetStart(ReportPreset.thisWeek, now), DateTime(2026, 10, 26));
      expect(presetStart(ReportPreset.lastWeek, now), DateTime(2026, 10, 19));
      expect(
        presetStart(ReportPreset.custom, now, custom: DateTime(2026, 10, 14)),
        DateTime(2026, 10, 12),
      );
    });
    test('labels', () {
      final DateTime now = DateTime(2026, 10, 26);
      expect(
        formatDateRange(DateTime(2026, 10, 12), DateTime(2026, 10, 18), now: now),
        'Oct 12 – Oct 18',
      );
      expect(
        formatDateRange(DateTime(2025, 12, 29), DateTime(2026, 1, 4), now: now),
        'Dec 29, 2025 – Jan 4, 2026',
      );
      expect(apiDate(DateTime(2026, 3, 5)), '2026-03-05');
    });
  });

  group('units and copy', () {
    test('speed thresholds convert', () {
      expect(UnitSystem.imperial.formatSpeed(35.76), '80 mph');
      expect(UnitSystem.metric.formatSpeed(35.76), '129 km/h');
      expect(UnitSystem.imperial.formatDistance(48000), '30 mi');
    });
    test('explanations quote thresholds', () {
      const ReportThresholds t = ReportThresholds();
      expect(
        eventExplanation(DrivingEventKind.speeding, t, UnitSystem.imperial),
        contains('over 80 mph for at least 30 seconds'),
      );
      expect(
        eventExplanation(DrivingEventKind.speeding, t, UnitSystem.metric),
        contains('over 129 km/h for at least 30 seconds'),
      );
      expect(
        eventExplanation(DrivingEventKind.hardBrake, t, UnitSystem.imperial),
        contains('7.8 mph per second'),
      );
    });
  });

  group('trip events', () {
    test('trip detail parses events and skips unknown kinds', () {
      final TripDetail d = TripDetail.fromJson(<String, dynamic>{
        'trip': <String, dynamic>{
          'id': 't',
          'user_id': 'u1',
          'started_at': '2026-10-24T10:00:00Z',
          'ended_at': '2026-10-24T10:20:00Z',
        },
        'route': <dynamic>[],
        'events': <dynamic>[
          <String, dynamic>{
            'id': 'e1',
            'kind': 'hard_brake',
            'started_at': '2026-10-24T10:05:00Z',
            'ended_at': '2026-10-24T10:05:02Z',
            'magnitude': 4.1,
            'lat': 40.0,
            'lon': -74.0,
          },
          <String, dynamic>{
            'id': 'e2',
            'kind': 'teleport',
            'started_at': '2026-10-24T10:06:00Z',
          },
        ],
      });
      expect(d.events, hasLength(1));
      expect(d.events.first.kind, DrivingEventKind.hardBrake);
      expect(d.events.first.magnitude, 4.1);
      expect(d.events.first.position!.latitude, 40.0);
    });
    test('missing events means none', () {
      expect(parseTripEvents(null), isEmpty);
    });
  });
}
