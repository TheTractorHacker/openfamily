import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/circle.dart';
import 'package:openfamily/services/diagnostics/diag_model.dart';
import 'package:openfamily/services/e2ee/e2ee_crypto.dart';
import 'package:openfamily/services/e2ee/e2ee_service.dart';
import 'package:openfamily/services/e2ee/e2ee_trust.dart';
import 'package:openfamily/services/e2ee/e2ee_vault.dart';
import 'package:openfamily/services/e2ee/lanes_store.dart';
import 'package:openfamily/services/e2ee/private_channel.dart';
import 'package:openfamily/services/e2ee/private_runtime.dart';

import '../../support/fake_e2ee_server.dart';
import 'private_channel_test.dart' show FakeServer, FakeClock;

// The ways a phone's Private-circle pipeline could stop without a word (0.26.23): a seal or an upload that never
// finishes holding the one-at-a-time flag for the life of the isolate, a stale "consent required" status sealing
// nothing, and refused uploads that left no trace on the phone. Each one now heals itself or shows in the
// diagnostic report.

const String uA = '11111111-1111-4111-8111-111111111111';
const String uB = '22222222-2222-4222-8222-222222222222';
const String priv = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';

Circle circleOf(String id) => Circle(id: id, name: id, role: 'member', sharingEnabled: true, memberCount: 2, e2eeMode: 'private');

/// A vault whose reads never answer while [hang] is set (a key-store call of a background engine that went away).
class _HangingVault implements E2eeVault {
  _HangingVault(this.inner);
  final E2eeVault inner;
  bool hang = false;
  @override
  Future<Uint8List?> read(String name) => hang ? Completer<Uint8List?>().future : inner.read(name);
  @override
  Future<void> write(String name, Uint8List value) => inner.write(name, value);
  @override
  Future<void> delete(String name) => inner.delete(name);
  @override
  Future<List<String>> names() => inner.names();
  @override
  Future<KeystoreStatus> status() => inner.status();
}

/// A relay that never answers while [hang] is set, and otherwise behaves like [FakeServer].
class _HangingServer extends FakeServer {
  bool hang = false;
  @override
  Future<List<BatchResult>> postBatch(String circleId, String deviceId, List<WireItem> batch) =>
      hang ? Completer<List<BatchResult>>().future : super.postBatch(circleId, deviceId, batch);
}

void main() {
  late FakeE2eeServer e2ee;
  late _HangingServer channel;
  late FakeClock clock;
  late MemoryVault vault;
  late _HangingVault hv;
  late MemoryKv kv;
  late E2eeService svc;
  late PrivateRuntime rt;

  setUp(() async {
    e2ee = FakeE2eeServer()..names.addAll(<String, String>{uA: 'Alice', uB: 'Bob'});
    e2ee.circle(priv, members: <String>[uA, uB], admin: uA);
    channel = _HangingServer();
    clock = FakeClock(DateTime.utc(2026, 11, 9, 19));
    vault = MemoryVault();
    hv = _HangingVault(vault);
    kv = MemoryKv();
    svc = E2eeService(api: e2ee.client(uA), vault: hv, trust: TrustStore(MemoryTrustKv()), userIdProvider: () async => uA);
    await svc.registerThisDevice();
    await svc.enableCircle(priv);
    rt = PrivateRuntime(service: svc, api: e2ee.client(uA), kv: kv, clock: clock, channel: channel, directory: StateSenderDirectory(e2ee.client(uA)));
    await rt.setCircles(<Circle>[circleOf(priv)]);
  });

  Map<String, dynamic> loc(double lat) => <String, dynamic>{
        'device_id': 'x', 'ts': clock.t.toIso8601String(), 'lat': lat, 'lon': 13.4,
        'accuracy_meters': 8, 'speed_mps': 0.0, 'battery_pct': 80, 'motion_state': '', 'source': 'background',
      };

  Future<void> settle([int ms = 150]) => Future<void>.delayed(Duration(milliseconds: ms));

  group('a seal that never finishes', () {
    test('is given up on: the next fix is sealed and queued, and the reason is recorded', () async {
      rt.sealTimeout = const Duration(milliseconds: 200);
      // A fresh runtime has no identity cached: the very first seal reads the vault, which hangs.
      final PrivateRuntime fresh = PrivateRuntime(
          service: E2eeService(api: e2ee.client(uA), vault: hv, trust: TrustStore(MemoryTrustKv()), userIdProvider: () async => uA),
          api: e2ee.client(uA), kv: kv, clock: clock, channel: channel, directory: StateSenderDirectory(e2ee.client(uA)))
        ..sealTimeout = const Duration(milliseconds: 200);
      hv.hang = true;
      expect(await fresh.routeFix(loc(52.50)), isFalse); // never plaintext
      await settle(350);
      expect(fresh.sealTimeouts, 1);
      expect(fresh.sealWaiting, 0, reason: 'the one-at-a-time flag was released');
      expect((await fresh.lastSealError())!.problem, 'timeout');
      // The key store answers again: the next fix goes through instead of waiting behind the stuck one forever.
      hv.hang = false;
      clock.t = clock.t.add(const Duration(minutes: 1));
      await fresh.routeFix(loc(52.51));
      await settle();
      expect(await fresh.queue.length(), 1);
      expect(await fresh.lastSealError(), isNull, reason: 'a good seal clears the note');
    });
  });

  group('an upload that never finishes', () {
    test('releases the flag after flushTimeout, records flush_timeout, and the next flush delivers', () async {
      rt.flushTimeout = const Duration(milliseconds: 200);
      await rt.routeFix(loc(52.52));
      await settle();
      expect(await rt.queue.length(), 1);
      channel.hang = true;
      expect(await rt.flush(), 0);
      final PrivateDeliveryFacts f = await rt.deliveryFacts();
      expect(f.lastErrorCode, 'flush_timeout');
      expect(f.circles.single.queued, 1);
      channel.hang = false;
      expect(await rt.flush(), 1, reason: 'a new flush is not stuck behind the hung one');
      expect(await rt.queue.length(), 0);
      expect((await rt.deliveryFacts()).lastUploadOkAt, clock.t);
    });
  });

  group('refused uploads leave a trace', () {
    test('401 (key voided by a new sign-in): items kept, code http_401 with its time', () async {
      await rt.routeFix(loc(52.53));
      await settle();
      channel.failWith = const UploadUnavailable('401');
      expect(await rt.flush(), 0);
      expect(await rt.queue.length(), 1, reason: 'kept for later');
      final PrivateDeliveryFacts f = await rt.deliveryFacts();
      expect(f.lastErrorCode, 'http_401');
      expect(f.lastErrorAt, clock.t);
      expect(f.lastUploadOkAt, isNull);
      expect(f.uplink, 'sealed only');
      expect(f.circles.single.queued, 1);
      expect(f.circles.single.parked, 0);
      expect(f.circles.single.lastSealedAt, clock.t);
      expect(f.lastFixAt, clock.t);
    });

    test('the background channel reads the CURRENT ingest key per upload; no credentials keeps the items', () async {
      int reads = 0;
      final IngestKeyChannelApi none = IngestKeyChannelApi('http://unused.invalid', const <String, String>{'X-Device-Key': 'old.old'},
          fresh: () async {
        reads++;
        return null; // signed out
      });
      await expectLater(none.postBatch(priv, 'd', <WireItem>[]),
          throwsA(isA<UploadUnavailable>().having((UploadUnavailable e) => SealedQueue.unavailableCode(e.message), 'code', 'no_credentials')));
      expect(reads, 1);
      await expectLater(none.postBatch(priv, 'd', <WireItem>[]), throwsA(isA<UploadUnavailable>()));
      expect(reads, 2, reason: 'asked again for every upload, never cached from the first fix');
    });

    test('codes are short and carry no host or message text', () {
      expect(SealedQueue.unavailableCode('401'), 'http_401');
      expect(SealedQueue.unavailableCode('0'), 'offline');
      expect(SealedQueue.unavailableCode('ClientException: Failed host lookup: example.org'), 'offline');
    });
  });

  group('a stale "consent required" status', () {
    test('no longer silences the phone when the verified policy allows opting out', () async {
      final LaneStore store = rt.lanes.store;
      await store.setPolicy(priv, const StoredPolicy(assist: true, skGen: 3, defaultForNew: E2ee.linePhone, memberOptOut: E2ee.optOutAllowed));
      await store.setStatus(priv, LaneStatus.consentRequired);
      expect(await rt.consentBlocks(priv), isFalse);
      await rt.routeFix(loc(52.54));
      await settle();
      final List<WireItem> q = await rt.queue.peek();
      expect(q.length, 1);
      expect(q.single.line, E2ee.linePhone, reason: 'no own server pref: the phone line, readable by members only');
    });

    test('still seals nothing while the verified policy requires server processing, and says so', () async {
      final LaneStore store = rt.lanes.store;
      await store.setPolicy(priv, const StoredPolicy(assist: true, skGen: 3, defaultForNew: E2ee.lineServer, memberOptOut: E2ee.optOutRequiredServer));
      await store.setStatus(priv, LaneStatus.consentRequired);
      expect(await rt.consentBlocks(priv), isTrue);
      await rt.routeFix(loc(52.55));
      await settle();
      expect(await rt.queue.length(), 0);
      final PrivateDeliveryFacts f = await rt.deliveryFacts();
      expect(f.circles.single.laneKind, 'consent');
      final DiagCheck c = privateDeliveryCheck(DiagFacts(now: clock.t, privateDelivery: f))!;
      expect(c.status, DiagStatus.warn);
      expect(c.detail, contains('requires server processing'));
    });
  });

  group('lane shown in the report', () {
    test('server lane without the server key on this phone: phone line used, and it says so', () async {
      final LaneStore store = rt.lanes.store;
      await store.setPolicy(priv, const StoredPolicy(assist: true, skGen: 3, defaultForNew: E2ee.linePhone, memberOptOut: E2ee.optOutAllowed));
      await store.setOwnLane(priv, const LaneChoice(E2ee.lineServer, 3), prefGen: 2);
      await store.setStatus(priv, LaneStatus.serverAssisted);
      await rt.routeFix(loc(52.56));
      await settle();
      final List<WireItem> q = await rt.queue.peek();
      expect(q.single.line, E2ee.linePhone, reason: 'no SK of gen 3 here: phone-line fallback, never nothing');
      final PrivateCircleDelivery c = (await rt.deliveryFacts()).circles.single;
      expect(c.laneLabel, 'server gen 3 (pref names gen 2) (no server key here: phone line used)');
    });
  });
}
