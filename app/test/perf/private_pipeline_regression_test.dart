// Regression tests for the Private-circle receive path (see docs/developers/performance-private.md).
// They count work (vault reads, store writes, map frames, worker hops) instead of timing it, so they are stable
// on any machine and fail on the pre-0.23.1 behaviour: one vault read, one 6000-point rewrite and one map frame per item.
import 'dart:typed_data';

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart' show LatLng;
import 'package:openfamily/models/member.dart';
import 'package:openfamily/services/delivery_status.dart';
import 'package:openfamily/services/family_service.dart';
import 'package:openfamily/utils/member_status.dart';
import 'package:openfamily/models/circle.dart';
import 'package:openfamily/services/e2ee/item_open_job.dart';
import 'package:openfamily/services/e2ee/last_positions.dart';
import 'package:openfamily/services/e2ee/private_channel.dart';
import 'package:openfamily/services/e2ee/private_runtime.dart';
import 'package:openfamily/services/perf/perf_profile.dart';
import 'package:openfamily/services/processing/on_device_setting.dart';

import '../support/private_bench_harness.dart';

void main() {
  group('a burst of 300 items', () {
    late BenchWorld w;
    late SyncStats stats;

    setUp(() async {
      // The frame/page counts below are defined for the full-size catch-up page (200); the page size
      // otherwise follows the device tier (see perf_profile.dart), one frame per member per page.
      PerfProfile.override = PerfProfile.full;
      addTearDown(PerfProfile.reset);
      w = await BenchWorld.make();
      await w.aliceSends(300);
      w.b.kv.sets = 0;
      w.b.vault.reads = 0;
      w.b.vault.namesCalls = 0;
      stats = await w.b.runtime.catchUp(benchCircle);
    });

    test('is accepted in full', () {
      expect(stats.accepted, 300);
      expect(stats.rejectedTotal, 0);
    });

    test('reads the circle key from the vault a handful of times, not once per item', () {
      expect(w.b.vault.reads, lessThanOrEqualTo(4), reason: 'was 300 before keys were remembered');
    });

    test('rewrites the member track once, not once per item', () async {
      await w.b.runtime.flushStores();
      final int histWrites = w.b.kv.data.keys.where((String k) => k.startsWith('hist/')).length;
      expect(histWrites, 1);
      expect(w.b.kv.sets, lessThanOrEqualTo(40), reason: 'was ~900 store writes');
      final pts = await w.b.runtime.history.range(
          benchCircle, benchA, w.clock.t.subtract(const Duration(hours: 2)), w.clock.t.add(const Duration(hours: 1)));
      expect(pts.length, 300); // nothing was lost by batching
    });

    test('puts one map frame per member on the screen, carrying the newest fix', () {
      expect(w.b.frames.length, lessThanOrEqualTo(2), reason: 'was 300 frames, i.e. 300 rebuilds of the roster');
      final newest = w.b.frames.last;
      expect(newest['user_id'], benchA);
      expect(newest['lat'], closeTo(52.5 + 299 * 0.0001, 1e-9));
    });
  });

  test('catch-up verifies the page in a worker isolate when one is given', () async {
    final BenchWorld w = await BenchWorld.make();
    await w.aliceSends(40);
    final WorkerOpenRunner worker = WorkerOpenRunner(idle: const Duration(milliseconds: 200));
    addTearDown(worker.dispose);
    final PrivateRuntime rt = PrivateRuntime(
        service: w.b.service, api: w.e2eeServer.client(benchB), kv: w.b.kv, clock: w.clock, channel: w.channel,
        directory: StateSenderDirectory(w.e2eeServer.client(benchB)), opener: worker);
    final SyncStats s = await rt.catchUp(benchCircle);
    expect(s.accepted, 40);
    expect(worker.batchesOnWorker, greaterThanOrEqualTo(1));
    expect(worker.batchesInline, 0);
  });

  test('the worker and the inline runner give the same verdicts, including for forged items', () async {
    final BenchWorld w = await BenchWorld.make();
    await w.aliceSends(3);
    final List<WireItem> items = List<WireItem>.of(w.channel.items);
    // A copy with a flipped ciphertext byte must be refused as a bad cipher, a duplicate must be refused.
    final WireItem good = items.first;
    final List<int> bad = List<int>.of(good.ciphertext)..[good.ciphertext.length - 3] ^= 1;
    final WireItem forged = WireItem(
        circleId: good.circleId, deviceId: good.deviceId, seq: items.last.seq + 5, purpose: good.purpose, epoch: good.epoch,
        sizeBucket: good.sizeBucket, ciphertext: Uint8List.fromList(bad));
    for (final OpenRunner runner in <OpenRunner>[const InlineOpenRunner(), WorkerOpenRunner(idle: const Duration(milliseconds: 100))]) {
      final ChannelReceiver r = ChannelReceiver(
          keys: ServiceChannelKeys(w.b.service), directory: StateSenderDirectory(w.e2eeServer.client(benchB)), kv: MemoryKv(),
          clock: w.clock, runner: runner);
      final List<ItemOutcome> o = await r.processMany(<WireItem>[...items, items.first, forged]);
      expect(o.take(3).every((ItemOutcome x) => x.item != null), isTrue);
      expect(o[3].rejected?.reason, ItemRejection.duplicate, reason: 'same (device, seq) twice in one batch');
      expect(o[4].rejected?.reason, ItemRejection.badCipher);
      if (runner is WorkerOpenRunner) runner.dispose();
    }
  });

  group('heavy on-device processing is opt-in', () {
    Future<List<String>> queuedPurposes(BenchWorld w) async => (await w.a.runtime.queue.peek()).map((WireItem i) => i.purpose).toList();

    Future<void> drive(BenchWorld w) async {
      // 30 minutes of fast movement and a stop: enough for the trip segmenter to close a trip.
      for (int i = 0; i < 60; i++) {
        w.clock.t = w.clock.t.add(const Duration(seconds: 30));
        await w.a.runtime.routeFix(<String, dynamic>{
          'ts': w.clock.t.toIso8601String(), 'lat': 52.5 + i * 0.002, 'lon': 13.4, 'accuracy_meters': 5.0, 'speed_mps': 20.0,
        });
      }
      for (int i = 0; i < 30; i++) {
        w.clock.t = w.clock.t.add(const Duration(minutes: 1));
        await w.a.runtime.routeFix(<String, dynamic>{
          'ts': w.clock.t.toIso8601String(), 'lat': 52.62, 'lon': 13.4, 'accuracy_meters': 5.0, 'speed_mps': 0.0,
        });
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }

    test('default: only fixes are sealed, no trip/drive/week result is computed or sent', () async {
      final BenchWorld w = await BenchWorld.make();
      w.a.runtime.onDeviceBatchEvery = Duration.zero;
      await drive(w);
      final List<String> p = await queuedPurposes(w);
      expect(p, isNotEmpty);
      expect(p.toSet().difference(<String>{ChannelPurpose.fix, ChannelPurpose.history}), isEmpty);
    });

    test('the setting key is the documented one and defaults to off', () async {
      final BenchWorld w = await BenchWorld.make();
      expect(OnDeviceReportsSetting.kvKey, 'procset/on_device_reports');
      expect(await OnDeviceReportsSetting.isOn(w.a.kv), isFalse);
    });

    test('switched on: results are produced, in batches', () async {
      final BenchWorld w = await BenchWorld.make();
      w.a.runtime.onDeviceBatchEvery = Duration.zero;
      await OnDeviceReportsSetting.set(w.a.kv, true);
      await drive(w);
      final List<String> p = await queuedPurposes(w);
      expect(p.where((String x) => x == ChannelPurpose.trip), isNotEmpty);
    });
  });

  group('last known position', () {
    test('survives a restart, is kept however old it is, and is encrypted at rest', () async {
      final BenchWorld w = await BenchWorld.make();
      await w.aliceSends(3);
      await w.b.runtime.catchUp(benchCircle);
      await w.b.runtime.flushStores();
      final String stored = String.fromCharCodes((await w.b.vault.read(LastPositionBook.vaultName))!);
      expect(stored, contains('52.5')); // it is in the vault ...
      expect(w.b.kv.data.values.any((String v) => v.contains(benchA) && v.contains('52.50')), isFalse); // ... not in the plain store

      // New process, a day and a half later: same vault, nothing else in memory.
      w.clock.t = w.clock.t.add(const Duration(hours: 36));
      final PrivateRuntime cold = PrivateRuntime(
          service: w.b.service, api: w.e2eeServer.client(benchB), kv: MemoryKv(), clock: w.clock, channel: w.channel,
          directory: StateSenderDirectory(w.e2eeServer.client(benchB)));
      await cold.setCircles(<Circle>[benchCircleOf(benchCircle)]);
      await cold.warmUp();
      final LastPosition? p = cold.lastKnown(benchA);
      expect(p, isNotNull);
      expect(p!.lat, closeTo(52.5002, 1e-6));
      expect(w.clock.t.difference(p.at).inHours, greaterThanOrEqualTo(36));
    });
  });

  group('"No location yet" is only said when no position was ever received', () {
    test('a roster snapshot without positions keeps the last known one', () async {
      final BenchWorld w = await BenchWorld.make();
      await w.aliceSends(2);
      await w.b.runtime.catchUp(benchCircle);
      await w.b.runtime.warmUp();
      PrivateRuntime.override = w.b.runtime;
      addTearDown(() => PrivateRuntime.override = null);
      final FamilyService svc = FamilyService()..scopeTo(benchCircle);
      svc.debugHandleFrame(jsonEncode(<String, dynamic>{
        'type': 'members',
        'circle_id': benchCircle,
        'members': <Map<String, dynamic>>[<String, dynamic>{'id': benchA, 'name': 'Alice', 'role': 'member'}],
      }));
      expect(svc.members.single.position, isNotNull, reason: 'was null until the async replay finished');
    });

    test('a silent member shows the reason AND the age of the last position', () {
      final DateTime now = DateTime.now();
      final Member m = Member(
          id: 'u-Kin', name: 'Kin', position: const LatLng(1, 2), status: MemberStatus.stopped, batteryPercent: 50, address: '',
          lastSeen: now.subtract(const Duration(hours: 3)));
      DeliveryHints.put(CircleDelivery(circleId: 'c1', summary: 'some_not_sending', at: now, members: <MemberDelivery>[
        MemberDelivery.fromJson(<String, dynamic>{'user_id': 'u-Kin', 'name': 'Kin', 'reason': 'no_key_wrap', 'app_version': '0.23.0', 'app_bucket': 'ok'})
      ]));
      addTearDown(DeliveryHints.clear);
      expect(memberStatusLine(m), allOf(contains('circle key'), contains('last seen 3 h ago')));
    });

    test('there is no age limit: a position from 40 days ago is still shown', () {
      final DateTime now = DateTime.now();
      final Member m = Member(
          id: 'u-Kin', name: 'Kin', position: const LatLng(1, 2), status: MemberStatus.stopped, batteryPercent: 50,
          address: 'Position from 40d ago', lastSeen: now.subtract(const Duration(days: 40)));
      expect(memberStatusLine(m), contains('last seen'));
      expect(m.position, isNotNull);
    });
  });
}
