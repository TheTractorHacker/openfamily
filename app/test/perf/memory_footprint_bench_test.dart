// Memory benchmarks, measured in the Flutter test VM on a server (NOT on a phone).
// Numbers are Dart-process RSS deltas, which are noisy and include the test
// harness; use them to compare tiers with each other, not as phone figures.
// Run one scenario per process for clean numbers:
//   flutter test test/perf/memory_footprint_bench_test.dart --plain-name 'lite'
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/e2ee/private_channel.dart';
import 'package:openfamily/services/e2ee/private_history.dart';
import 'package:openfamily/services/perf/perf_profile.dart';

import '../support/private_bench_harness.dart';

int rssMb() => ProcessInfo.currentRss ~/ (1024 * 1024);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(PerfProfile.reset);

  for (final PerfProfile p in <PerfProfile>[PerfProfile.lite, PerfProfile.standard, PerfProfile.full]) {
    test('${p.tier.name}: 6000 points in, 300-item catch-up, stored size', () async {
      PerfProfile.override = p;
      final BenchWorld w = await BenchWorld.make();
      final int base = w.clock.t.subtract(const Duration(days: 6)).millisecondsSinceEpoch;
      final int rss0 = rssMb();
      await w.b.runtime.history.add(benchCircle, benchA, <TrackPoint>[
        for (int i = 0; i < 6000; i++) TrackPoint(base + i * 60000, 52.0 + i * 1e-5, 13.0 + i * 1e-5, 9)
      ]);
      final int rssHist = rssMb();
      final List<TrackPoint> loaded = await w.b.runtime.history
          .range(benchCircle, benchA, DateTime.fromMillisecondsSinceEpoch(base), DateTime.now().add(const Duration(days: 30)));
      final int rssLoad = rssMb();
      final String stored = await w.b.kv.get('hist/$benchCircle/$benchA') ?? '';
      await w.aliceSends(300);
      final int rss1 = rssMb();
      final SyncStats s = await w.b.runtime.catchUp(benchCircle);
      final int rss2 = rssMb();
      // ignore: avoid_print
      print('MEMMETRIC ${p.tier.name}: maxHistoryPoints=${p.maxHistoryPoints} pointsKept=${loaded.length} '
          'storedTrackBytes=${stored.length} catchUpPage=${p.catchUpPageSize} accepted=${s.accepted} '
          'rssMB: start=$rss0 afterHistoryWrite=$rssHist afterTrackLoad=$rssLoad beforeCatchUp=$rss1 afterCatchUp=$rss2 '
          'maxRssMB=${ProcessInfo.maxRss ~/ (1024 * 1024)}');
      expect(loaded.length, p.maxHistoryPoints < 6000 ? p.maxHistoryPoints : 6000);
      expect(s.accepted, 300);
    }, timeout: const Timeout(Duration(minutes: 10)));
  }
}
