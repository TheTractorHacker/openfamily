// Benchmarks of the Private-circle receive path, measured in the Flutter test VM (NOT on a phone).
// Every number printed as PERFMETRIC is also in docs/developers/performance-private.md.
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/e2ee/item_open_job.dart';
import 'package:openfamily/services/e2ee/private_channel.dart';
import 'package:openfamily/services/e2ee/private_history.dart';

import '../support/private_bench_harness.dart';

void main() {
  test('burst of 300 items: catch-up cost, store traffic, event-loop blocking', () async {
    final BenchWorld w = await BenchWorld.make();
    await w.aliceSends(300);
    w.b.kv.gets = w.b.kv.sets = w.b.kv.fresh = w.b.kv.bytesSet = 0;
    w.b.vault.reads = w.b.vault.namesCalls = 0;
    final LoopLag lag = LoopLag()..start();
    final Stopwatch sw = Stopwatch()..start();
    final SyncStats s = await w.b.runtime.catchUp(benchCircle);
    sw.stop();
    lag.stop();
    // ignore: avoid_print
    print('PERFMETRIC burst300: accepted=${s.accepted} wall=${sw.elapsedMilliseconds}ms maxLoopBlock=${lag.maxGapMs}ms '
        'frames=${w.b.frames.length} kvGets=${w.b.kv.gets} kvSets=${w.b.kv.sets} kvBytesWritten=${w.b.kv.bytesSet} '
        'vaultReads=${w.b.vault.reads} vaultNames=${w.b.vault.namesCalls}');
    expect(s.accepted, 300);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('burst of 300 items with the crypto in the worker isolate (what the app does)', () async {
    final WorkerOpenRunner worker = WorkerOpenRunner(idle: const Duration(milliseconds: 300));
    addTearDown(worker.dispose);
    final BenchWorld w = await BenchWorld.make(receiverOpener: worker);
    final Stopwatch sender = Stopwatch()..start();
    await w.aliceSends(300);
    sender.stop();
    final LoopLag lag = LoopLag()..start();
    final Stopwatch sw = Stopwatch()..start();
    final SyncStats s = await w.b.runtime.catchUp(benchCircle);
    sw.stop();
    lag.stop();
    // ignore: avoid_print
    print('PERFMETRIC burst300 worker: accepted=${s.accepted} wall=${sw.elapsedMilliseconds}ms maxLoopBlock=${lag.maxGapMs}ms '
        'workerBatches=${worker.batchesOnWorker} | sender side: 300 fixes sealed+queued+uploaded in ${sender.elapsedMilliseconds}ms');
    expect(s.accepted, 300);
    expect(worker.batchesOnWorker, greaterThan(0));
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('burst of 300 on top of a full 6000-point history per member', () async {
    final BenchWorld w = await BenchWorld.make();
    final int base = w.clock.t.subtract(const Duration(days: 6)).millisecondsSinceEpoch;
    await w.b.runtime.history.add(benchCircle, benchA, <TrackPoint>[
      for (int i = 0; i < 6000; i++) TrackPoint(base + i * 60000, 52.0 + i * 1e-5, 13.0 + i * 1e-5, 9)
    ]);
    await w.aliceSends(300);
    final LoopLag lag = LoopLag()..start();
    final Stopwatch sw = Stopwatch()..start();
    final SyncStats s = await w.b.runtime.catchUp(benchCircle);
    sw.stop();
    lag.stop();
    // ignore: avoid_print
    print('PERFMETRIC burst300+fullHistory: accepted=${s.accepted} wall=${sw.elapsedMilliseconds}ms maxLoopBlock=${lag.maxGapMs}ms '
        'kvBytesWritten=${w.b.kv.bytesSet} frames=${w.b.frames.length}');
    expect(s.accepted, 300);
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('replayLatest (runs on every members snapshot) with a full history', () async {
    final BenchWorld w = await BenchWorld.make();
    await w.aliceSends(20);
    await w.b.runtime.catchUp(benchCircle);
    final int base = w.clock.t.subtract(const Duration(days: 6)).millisecondsSinceEpoch;
    await w.b.runtime.history.add(benchCircle, benchA, <TrackPoint>[
      for (int i = 0; i < 6000; i++) TrackPoint(base + i * 60000, 52.0 + i * 1e-5, 13.0 + i * 1e-5, 9)
    ]);
    w.b.frames.clear();
    final Stopwatch sw = Stopwatch()..start();
    for (int i = 0; i < 10; i++) {
      await w.b.runtime.replayLatest();
    }
    sw.stop();
    // ignore: avoid_print
    print('PERFMETRIC replayLatest x10 (1 member, 6000 pts): ${sw.elapsedMilliseconds}ms');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
