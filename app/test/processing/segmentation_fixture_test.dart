import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/processing/processing.dart';

import 'fixture_support.dart';

Map<String, dynamic> _expected(Map<String, dynamic> c) => <String, dynamic>{
  'trips': c['trips'],
  'stops': c['stops'],
};

void main() {
  final Map<String, dynamic> fx = loadFixture('segmentation.json');
  final List<dynamic> cases = fx['cases'] as List<dynamic>;

  test('fixture file has the scenarios and is non-trivial', () {
    expect(cases.length, greaterThanOrEqualTo(12));
    final int trips = cases.fold<int>(
      0,
      (int a, dynamic c) => a + ((c as Map<String, dynamic>)['trips'] as List<dynamic>).length,
    );
    expect(trips, greaterThan(8));
  });

  for (final dynamic raw in cases) {
    final Map<String, dynamic> c = raw as Map<String, dynamic>;
    final String name = c['name'] as String;
    final List<Fix> fixes = <Fix>[
      for (final dynamic f in c['fixes'] as List<dynamic>)
        Fix.fromJson(f as Map<String, dynamic>),
    ];

    for (final int fold in <int>[2048, 40]) {
      // fold=40 forces the long-stop compaction path; results must not change.
      test('$name (maxStopFixes=$fold) matches Go', () {
        final SegmentResult r = segmentFixes(
          fixes,
          finalizeOpen: c['finalize_open'] as bool,
          maxStopFixes: fold,
        );
        final Map<String, dynamic> got = <String, dynamic>{
          'trips': <dynamic>[for (final ProcessedTrip t in r.trips) t.toJson()],
          'stops': <dynamic>[for (final ProcessedStop s in r.stops) s.toJson()],
        };
        final List<String> diffs = <String>[];
        diffJson(_expected(c), got, name, diffs);
        expect(diffs, isEmpty, reason: diffs.take(12).join('\n'));

        final Map<String, dynamic> st = c['stats'] as Map<String, dynamic>;
        expect(r.stats.input, st['Input']);
        expect(r.stats.used, st['Used']);
        expect(r.stats.outOfOrder, st['OutOfOrder']);
        expect(r.stats.duplicate, st['Duplicate']);
        expect(r.stats.lowAccuracy, st['LowAccuracy']);
        expect(r.stats.teleport, st['Teleport']);
        expect(r.stats.invalidPosition, st['InvalidPosition']);
        expect(r.inProgress, c['in_progress']);
        final String? su = c['safe_until'] as String?;
        expect(
          r.safeUntilUs,
          (su == null || su.isEmpty) ? isNull : parseUtcMicros(su),
        );
      });
    }

    test('$name: streaming in chunks with takeNew equals batch', () {
      final TripSegmenter seg = TripSegmenter(finalizeOpen: c['finalize_open'] as bool);
      final List<ProcessedTrip> trips = <ProcessedTrip>[];
      final List<ProcessedStop> stops = <ProcessedStop>[];
      for (int i = 0; i < fixes.length; i++) {
        seg.add(fixes[i]);
        if (i % 37 == 0) {
          final n = seg.takeNew();
          trips.addAll(n.trips);
          stops.addAll(n.stops);
        }
      }
      final SegmentResult fin = seg.finish();
      trips.addAll(fin.trips);
      stops.addAll(fin.stops);
      final List<String> diffs = <String>[];
      diffJson(
        _expected(c),
        <String, dynamic>{
          'trips': <dynamic>[for (final ProcessedTrip t in trips) t.toJson()],
          'stops': <dynamic>[for (final ProcessedStop s in stops) s.toJson()],
        },
        name,
        diffs,
      );
      expect(diffs, isEmpty, reason: diffs.take(12).join('\n'));
    });

    test('$name: standalone detectEvents matches Go DetectEvents', () {
      final List<DrivingEvent> ev = detectEvents(fixes);
      final List<String> diffs = <String>[];
      diffJson(
        c['direct_events'],
        <dynamic>[for (final DrivingEvent e in ev) e.toJson()],
        name,
        diffs,
      );
      expect(diffs, isEmpty, reason: diffs.take(12).join('\n'));
    });
  }

  test('events were exercised in the fixtures (all four detectors but phone)', () {
    final Set<String> kinds = <String>{};
    for (final dynamic raw in cases) {
      for (final dynamic t in (raw as Map<String, dynamic>)['trips'] as List<dynamic>) {
        for (final dynamic e in (t as Map<String, dynamic>)['events'] as List<dynamic>) {
          kinds.add((e as Map<String, dynamic>)['kind'] as String);
        }
      }
    }
    expect(kinds, containsAll(<String>['hard_brake']));
  });
}
