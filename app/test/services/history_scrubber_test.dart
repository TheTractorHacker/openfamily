import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:openfamily/services/history_scrubber.dart';
import 'package:openfamily/services/history_service.dart';

final DateTime _t0 = DateTime.utc(2026, 10, 27, 8);

HistoryTrailPoint _p(int minute, double lat, double lon,
        {double? speed, double? battery, String motion = ''}) =>
    HistoryTrailPoint(
      position: LatLng(lat, lon),
      ts: _t0.add(Duration(minutes: minute)),
      speedMps: speed,
      batteryPct: battery,
      motionState: motion,
    );

void main() {
  group('time <-> fraction', () {
    final HistoryTimeline tl =
        HistoryTimeline(<HistoryTrailPoint>[_p(0, 0, 0), _p(60, 0, 1)]);
    test('round trips and clamps', () {
      expect(tl.fractionForTime(_t0.add(const Duration(minutes: 30))), 0.5);
      expect(tl.timeForFraction(0.25), _t0.add(const Duration(minutes: 15)));
      expect(tl.fractionForTime(_t0.subtract(const Duration(hours: 1))), 0);
      expect(tl.fractionForTime(_t0.add(const Duration(hours: 5))), 1);
      expect(tl.timeForFraction(2), tl.end);
      expect(tl.timeForFraction(-1), tl.start);
    });
    test('unsorted input is sorted', () {
      final HistoryTimeline u =
          HistoryTimeline(<HistoryTrailPoint>[_p(10, 0, 1), _p(0, 0, 0)]);
      expect(u.start, _t0);
    });
  });

  group('interpolation', () {
    test('midpoint between close fixes', () {
      final HistoryTimeline tl = HistoryTimeline(<HistoryTrailPoint>[
        _p(0, 10, 20, speed: 0, battery: 90),
        _p(4, 12, 24, speed: 10, battery: 88),
      ]);
      final ScrubSample s = tl.sampleAt(_t0.add(const Duration(minutes: 2)));
      expect(s.position.latitude, closeTo(11, 1e-9));
      expect(s.position.longitude, closeTo(22, 1e-9));
      expect(s.speedMps, closeTo(5, 1e-9));
      expect(s.batteryPct, 90);
      expect(s.interpolated, isTrue);
      expect(s.index, 0);
    });
    test('exact fix and clamping', () {
      final HistoryTimeline tl = HistoryTimeline(<HistoryTrailPoint>[
        _p(0, 1, 1),
        _p(4, 2, 2),
      ]);
      expect(tl.sampleAt(_t0.add(const Duration(minutes: 4))).position,
          const LatLng(2, 2));
      expect(tl.sampleAt(_t0.subtract(const Duration(days: 1))).position,
          const LatLng(1, 1));
      expect(tl.sampleAt(_t0.add(const Duration(days: 1))).index, 1);
    });
    test('derives speed from distance when not reported', () {
      final HistoryTimeline tl = HistoryTimeline(<HistoryTrailPoint>[
        _p(0, 0, 0),
        _p(1, 0, 0.001), // ~111 m in 60 s
      ]);
      final ScrubSample s = tl.sampleAt(_t0.add(const Duration(seconds: 30)));
      expect(s.speedMps, closeTo(1.85, 0.05));
    });
    test('holds position across a long gap', () {
      final HistoryTimeline tl = HistoryTimeline(<HistoryTrailPoint>[
        _p(0, 1, 1),
        _p(120, 5, 5),
      ]);
      final ScrubSample s = tl.sampleAt(_t0.add(const Duration(minutes: 60)));
      expect(s.position, const LatLng(1, 1));
      expect(s.speedMps, 0);
      expect(s.interpolated, isFalse);
    });
  });

  group('empty and single point', () {
    test('empty', () {
      final HistoryTimeline tl = HistoryTimeline(const <HistoryTrailPoint>[]);
      expect(tl.isEmpty, isTrue);
      expect(tl.isScrubbable, isFalse);
      expect(tl.fractionForTime(_t0), 0);
      expect(tl.stops(), isEmpty);
      expect(tl.moveRanges(<StopCluster>[]), isEmpty);
      expect(() => tl.sampleAt(_t0), throwsStateError);
    });
    test('single point', () {
      final HistoryTimeline tl =
          HistoryTimeline(<HistoryTrailPoint>[_p(0, 3, 4, battery: 50)]);
      expect(tl.isSingle, isTrue);
      expect(tl.isScrubbable, isFalse);
      expect(tl.fractionForTime(_t0.add(const Duration(hours: 1))), 0);
      final ScrubSample s = tl.sampleAt(_t0.add(const Duration(hours: 1)));
      expect(s.position, const LatLng(3, 4));
      expect(s.batteryPct, 50);
    });
  });

  group('stop clustering', () {
    // 30 min at home with jitter, 10 min drive, 20 min at work.
    List<HistoryTrailPoint> day() => <HistoryTrailPoint>[
          for (int m = 0; m <= 30; m += 2)
            _p(m, 40.0 + (m.isEven ? 0.0002 : -0.0002), -74.0),
          _p(32, 40.02, -74.0, speed: 15, motion: 'driving'),
          _p(34, 40.04, -74.0, speed: 15, motion: 'driving'),
          _p(36, 40.06, -74.0, speed: 15, motion: 'driving'),
          for (int m = 40; m <= 60; m += 2) _p(m, 40.08, -74.0),
        ];

    test('merges jitter into one cluster per stay with dwell', () {
      final HistoryTimeline tl = HistoryTimeline(day());
      final List<StopCluster> stops = tl.stops();
      expect(stops, hasLength(2));
      expect(stops[0].dwell, const Duration(minutes: 30));
      expect(stops[1].dwell, const Duration(minutes: 20));
      expect(stops[0].position.latitude, closeTo(40.0, 0.0003));
    });

    test('move ranges cover drive and connect to stops', () {
      final HistoryTimeline tl = HistoryTimeline(day());
      final List<StopCluster> stops = tl.stops();
      final List<List<int>> r = tl.moveRanges(stops);
      expect(r, hasLength(1));
      expect(r[0].first, stops[0].lastIndex);
      expect(r[0].last, stops[1].firstIndex);
    });

    test('short pause is not a stop', () {
      final HistoryTimeline tl = HistoryTimeline(<HistoryTrailPoint>[
        _p(0, 40, -74),
        _p(2, 40, -74),
        _p(4, 40.01, -74),
        _p(6, 40.02, -74),
      ]);
      expect(tl.stops(), isEmpty);
      expect(tl.moveRanges(tl.stops()), <List<int>>[
        <int>[0, 3]
      ]);
    });

    test('names stops from overlapping place visits', () {
      final HistoryTimeline tl = HistoryTimeline(day());
      final List<StopCluster> named = tl.nameStops(tl.stops(), <HistoryVisit>[
        HistoryVisit(
          arrivedAt: _t0,
          departedAt: _t0.add(const Duration(minutes: 30)),
          position: const LatLng(40, -74),
          placeName: 'Home',
          kind: 'place',
        ),
        HistoryVisit(
          arrivedAt: _t0.add(const Duration(minutes: 40)),
          departedAt: _t0.add(const Duration(minutes: 60)),
          position: const LatLng(40.08, -74),
          placeName: 'Stopped',
          kind: 'stop',
        ),
      ]);
      expect(named[0].name, 'Home');
      expect(named[1].name, isNull);
      expect(HistoryTimeline.stopAt(named, _t0.add(const Duration(minutes: 10)))?.name,
          'Home');
      expect(HistoryTimeline.stopAt(named, _t0.add(const Duration(minutes: 35))),
          isNull);
    });
  });

  group('downsampling', () {
    test('keeps short paths untouched', () {
      final List<LatLng> p = <LatLng>[const LatLng(0, 0), const LatLng(1, 1)];
      expect(downsamplePath(p, 10), p);
    });
    test('caps long paths, keeps endpoints and shape', () {
      final List<LatLng> p = <LatLng>[
        for (int i = 0; i < 5000; i++)
          LatLng(i * 0.0001, 0.01 * (i % 200 < 100 ? i % 100 : 100 - i % 100) / 100),
      ];
      final List<LatLng> d = downsamplePath(p, 200);
      expect(d.length, lessThanOrEqualTo(200));
      expect(d.length, greaterThan(2));
      expect(d.first, p.first);
      expect(d.last, p.last);
    });
    test('straight line collapses to its endpoints', () {
      final List<LatLng> p = <LatLng>[
        for (int i = 0; i < 100; i++) LatLng(i * 0.001, 0),
      ];
      expect(downsamplePath(p, 10), <LatLng>[p.first, p.last]);
    });
  });

  group('playback', () {
    test('advances by multiplier and clamps to end', () {
      final DateTime end = _t0.add(const Duration(hours: 1));
      expect(advancePlayback(_t0, const Duration(seconds: 1), 1, end),
          _t0.add(const Duration(minutes: 1)));
      expect(advancePlayback(_t0, const Duration(seconds: 2), 16, end),
          _t0.add(const Duration(minutes: 32)));
      expect(advancePlayback(_t0, const Duration(minutes: 5), 16, end), end);
    });
    test('speed cycles 1 -> 4 -> 16 -> 1', () {
      expect(nextPlaybackSpeed(1), 4);
      expect(nextPlaybackSpeed(4), 16);
      expect(nextPlaybackSpeed(16), 1);
    });
  });

  group('day navigation', () {
    final DateTime today = DateTime(2026, 10, 27);
    test('forward disabled on today, back allowed', () {
      expect(canGoForwardDay(today, today), isFalse);
      expect(canGoBackDay(today, today), isTrue);
      expect(canGoForwardDay(DateTime(2026, 10, 26), today), isTrue);
    });
    test('back limit is the retention window', () {
      final DateTime oldest = oldestHistoryDay(today);
      expect(canGoBackDay(oldest, today), isFalse);
      expect(canGoBackDay(oldest.add(const Duration(days: 1)), today), isTrue);
    });
    test('shift clamps at the limits', () {
      expect(shiftHistoryDay(today, 1, today), today);
      expect(shiftHistoryDay(today, -1, today), DateTime(2026, 10, 26));
      final DateTime oldest = oldestHistoryDay(today);
      expect(shiftHistoryDay(oldest, -1, today), oldest);
    });
    test('labels', () {
      expect(historyDayLabel(today, today), 'Today');
      expect(historyDayLabel(DateTime(2026, 10, 26), today), 'Yesterday');
      expect(historyDayLabel(DateTime(2026, 10, 20), today), 'Tue, Oct 20');
      expect(dwellLabel(const Duration(minutes: 125)), '2 h 05 min');
      expect(dwellLabel(const Duration(seconds: 20)), '<1 min');
    });
  });
}
