import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/processing/processing.dart';

void main() {
  Fix f(int s, double lat, double lon, {double? v, double acc = 5}) => Fix(
    tsUs: DateTime.utc(2026, 10, 19, 8).microsecondsSinceEpoch + s * 1000000,
    lat: lat,
    lon: lon,
    speedMps: v,
    accuracyM: acc,
  );

  test('haversine matches 1 degree of latitude and is zero for equal points', () {
    expect(haversine(0, 10, 1, 10), closeTo(111195, 100));
    expect(haversine(40, -75, 40, -75), 0);
  });

  test('empty input and single fix produce nothing', () {
    expect(segmentFixes(const <Fix>[]).trips, isEmpty);
    final SegmentResult r = segmentFixes(<Fix>[f(0, 40, -75)]);
    expect(r.trips, isEmpty);
    expect(r.stops, isEmpty);
    expect(r.stats.used, 1);
  });

  test('formatUtcMicros round trips and trims zeros like Go RFC3339Nano', () {
    expect(formatUtcMicros(parseUtcMicros('2026-10-19T08:00:00Z')), '2026-10-19T08:00:00Z');
    expect(formatUtcMicros(parseUtcMicros('2026-10-19T08:00:00.5Z')), '2026-10-19T08:00:00.5Z');
    expect(formatUtcMicros(parseUtcMicros('2026-10-19T08:00:00.123456Z')), '2026-10-19T08:00:00.123456Z');
  });

  test('segmenter refuses fixes after finish', () {
    final TripSegmenter s = TripSegmenter()..add(f(0, 40, -75));
    s.finish();
    expect(() => s.add(f(1, 40, -75)), throwsStateError);
  });

  test('effectiveEvents hides a GPS event shadowed by a same-kind sensor event within 4 s', () {
    DrivingEvent e(String k, int s) => DrivingEvent(kind: k, startedAtUs: s * 1000000, endedAtUs: s * 1000000, magnitude: 1, lat: 0, lon: 0);
    final List<DrivingEvent> out = effectiveEvents(
      <DrivingEvent>[e('hard_brake', 100), e('hard_brake', 200), e('rapid_accel', 101)],
      <DrivingEvent>[e('hard_brake', 103)],
    );
    expect(out.map((DrivingEvent x) => '${x.kind}@${x.startedAtUs ~/ 1000000}').toList()..sort(),
        <String>['hard_brake@103', 'hard_brake@200', 'rapid_accel@101']);
  });

  test('score formula edge: 10 km floor and clamping', () {
    final EventCountsOut ev = EventCountsOut(hardBrake: 1);
    expect(weeklySafetyScore(1, 1000, ev), 50); // 100 - 5*1/10*100
    expect(weeklySafetyScore(0, 1000, ev), isNull);
    expect(weeklySafetyScore(1, 1000, EventCountsOut(hardBrake: 9)), 0);
  });
}
