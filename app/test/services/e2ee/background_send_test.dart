// The send path of a Private circle while driving with the app in the background: fixes arrive once a second,
// every seal is several store round trips, and the newest position must reach the relay within seconds.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/circle.dart';
import 'package:openfamily/services/e2ee/e2ee_service.dart';
import 'package:openfamily/services/e2ee/e2ee_trust.dart';
import 'package:openfamily/services/e2ee/e2ee_vault.dart';
import 'package:openfamily/services/e2ee/private_channel.dart';
import 'package:openfamily/services/e2ee/private_runtime.dart';

import '../../support/fake_e2ee_server.dart';
import 'private_channel_test.dart' show FakeServer, FakeClock;

const String uA = '11111111-1111-4111-8111-111111111111';
const String uB = '22222222-2222-4222-8222-222222222222';
const String priv = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
// Private on this phone's list, but this phone holds no key for it: every fix parks a copy for it.
const String noKey = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';

Circle _private(String id) =>
    Circle(id: id, name: id, role: 'member', sharingEnabled: true, memberCount: 2, e2eeMode: 'private');

/// A store whose every write takes [delay] (a phone's platform channel), and that counts what it is asked.
class SlowKv extends MemoryKv {
  Duration delay = Duration.zero;
  int parkedRemoves = 0;
  @override
  Future<void> set(String key, String value) async {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    return super.set(key, value);
  }

  @override
  Future<void> remove(String key) {
    if (key == 'parked/v1') parkedRemoves++;
    return super.remove(key);
  }
}

/// A relay that answers after [delay] and counts requests in flight.
class SlowServer extends FakeServer {
  Duration delay = Duration.zero;
  int inFlight = 0, maxInFlight = 0;
  @override
  Future<List<BatchResult>> postBatch(String circleId, String deviceId, List<WireItem> batch) async {
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      return await super.postBatch(circleId, deviceId, batch);
    } finally {
      inFlight--;
    }
  }
}

void main() {
  late FakeE2eeServer e2ee;
  late SlowServer relay;
  late FakeClock clock;
  late SlowKv kv;
  late PrivateRuntime rt;

  setUp(() async {
    e2ee = FakeE2eeServer()..names.addAll(<String, String>{uA: 'Alice', uB: 'Bob'});
    e2ee.circle(priv, members: <String>[uA, uB], admin: uA);
    relay = SlowServer();
    clock = FakeClock(DateTime.utc(2026, 11, 9, 8));
    kv = SlowKv();
    final E2eeService svc = E2eeService(
        api: e2ee.client(uA), vault: MemoryVault(), trust: TrustStore(MemoryTrustKv()), userIdProvider: () async => uA);
    // Like the background isolate: history is written at once.
    rt = PrivateRuntime(
        service: svc, api: e2ee.client(uA), kv: kv, clock: clock, channel: relay,
        directory: StateSenderDirectory(e2ee.client(uA)), historyWriteBehind: null);
    await svc.registerThisDevice();
    await svc.enableCircle(priv);
    await rt.setCircles(<Circle>[_private(priv)]);
  });

  Map<String, dynamic> fix(int i) => <String, dynamic>{
        'device_id': 'x', 'ts': clock.t.add(Duration(seconds: i)).toIso8601String(), 'lat': 52.5 + i * 0.0001,
        'lon': 13.4, 'accuracy_meters': 5.0, 'speed_mps': 15.0, 'battery_pct': 70, 'motion_state': 'driving',
        'source': 'background',
      };

  Future<void> settle() async {
    for (int i = 0; i < 400 && rt.sealWaiting > 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  group('sealing while driving (1 fix per second)', () {
    test('fixes are sealed one at a time, in order, nothing in plaintext', () async {
      for (int i = 0; i < 6; i++) {
        expect(await rt.routeFix(fix(i)), isFalse); // sealed only: no plaintext report
      }
      await settle();
      final List<WireItem> q = await rt.queue.peek();
      expect(q.length, 6);
      final List<int> seqs = q.map((WireItem w) => w.seq).toList();
      expect(seqs, List<int>.of(seqs)..sort()); // seq follows the order the fixes came in
      expect(kv.data['queue/v1']!.contains('52.5'), isFalse);
      expect(kv.data['parked/v1'], isNull);
      expect(rt.sealSkipped, 0);
    });

    test('a store slower than the GPS never builds an unbounded backlog: the newest fix is sealed', () async {
      kv.delay = const Duration(milliseconds: 15); // every write is slow
      for (int i = 0; i < 40; i++) {
        await rt.routeFix(fix(i));
        expect(rt.sealWaiting, lessThanOrEqualTo(PrivateRuntime.maxSealWaiting + 1));
      }
      await settle();
      expect(rt.sealWaiting, 0);
      expect(rt.sealSkipped, greaterThan(0));
      expect(await rt.flush(), greaterThanOrEqualTo(40 - rt.sealSkipped));
      expect(await rt.queue.length(), 0);
      // The newest position was sealed (the own track only gets a point after its item is queued).
      final List<double> lats = (await rt.history.range(
              priv, uA, clock.t.subtract(const Duration(minutes: 1)), clock.t.add(const Duration(minutes: 5))))
          .map((p) => p.lat)
          .toList();
      expect(lats.last, closeTo(52.5 + 39 * 0.0001, 1e-9));
      expect(lats.length, 40 - rt.sealSkipped);
    });
  });

  group('uploads', () {
    test('two flushes at once post each batch once, and the second waits for the same result', () async {
      for (int i = 0; i < 3; i++) {
        await rt.routeFix(fix(i));
      }
      await settle();
      relay.delay = const Duration(milliseconds: 50);
      final List<int> got = await Future.wait(<Future<int>>[rt.flush(), rt.flush()]);
      expect(relay.maxInFlight, 1);
      expect(relay.items.length, 3);
      expect(got.first, 3);
      expect(await rt.queue.length(), 0);
    });

    test('a fix queued while an upload runs is sent by that upload going round again', () async {
      await rt.routeFix(fix(0));
      await settle();
      relay.delay = const Duration(milliseconds: 300);
      final Future<int> first = rt.flush();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await rt.routeFix(fix(1));
      await settle();
      unawaited(rt.flush()); // e.g. the 2 s timer of the new fix
      await first;
      expect(relay.items.length, 2);
      expect(await rt.queue.length(), 0);
    });

    test('fixes parked for a circle without a key do not hold up the live upload', () async {
      await rt.setCircles(<Circle>[_private(priv), _private(noKey)]);
      await rt.routeFix(fix(0));
      await settle();
      expect(kv.data['parked/v1'], isNotNull); // the copy for the keyless circle waits (never plaintext)
      expect(await rt.flush(), 1); // the sealed copy for the other circle went out
      final int removesAfterFirst = kv.parkedRemoves;
      expect(removesAfterFirst, greaterThanOrEqualTo(1)); // the parked list was tried once

      // Driving on: more fixes and uploads within 30 s do not re-seal the parked list every time.
      for (int i = 1; i <= 5; i++) {
        clock.t = clock.t.add(const Duration(seconds: 2));
        await rt.routeFix(fix(i));
        await settle();
        await rt.flush();
      }
      expect(relay.items.length, 6);
      // Only the seals' own parking happened, no drain (a drain removes the parked list first).
      expect(kv.parkedRemoves, removesAfterFirst);
      expect(kv.data['parked/v1'], isNotNull);

      // After the retry interval the parked list is tried again.
      clock.t = clock.t.add(PrivateRuntime.parkedRetryEvery);
      await rt.flush();
      expect(kv.parkedRemoves, greaterThan(removesAfterFirst));
    });

    test('a drain started while one runs returns at once (no drain inside a drain)', () async {
      await rt.setCircles(<Circle>[_private(priv), _private(noKey)]);
      await rt.routeFix(fix(0));
      await settle();
      kv.delay = const Duration(milliseconds: 20);
      final Future<int> outer = rt.drainParked();
      expect(await rt.drainParked(), 0);
      expect(await outer, 1);
    });
  });
}
