import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/e2ee/e2ee_crypto.dart';
import 'package:openfamily/services/e2ee/e2ee_models.dart';
import 'package:openfamily/services/api_client.dart';
import 'package:openfamily/services/e2ee/private_channel.dart';

// Phase-2 channel: seal/verify round trip against the Go vector, sender
// authenticity, replay/duplicate, epoch rollback, clock skew, queue and catch-up.

const String circle = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const String uA = '11111111-1111-4111-8111-111111111111';
const String uB = '22222222-2222-4222-8222-222222222222';
const String uC = '33333333-3333-4333-8333-333333333333';

class FakeClock extends Clock {
  FakeClock(this.t);
  DateTime t;
  @override
  DateTime now() => t;
}

class Phone {
  Phone(this.user, this.deviceId, this.edSeed, this.edPub);
  final String user;
  final String deviceId;
  final Uint8List edSeed;
  final Uint8List edPub;
  SenderIdentity get id => SenderIdentity(deviceId, edSeed, user);

  static Future<Phone> make(String user, int b) async {
    final (Uint8List es, Uint8List xs) = await E2ee.deriveIdentity(Uint8List(32)..fillRange(0, 32, b));
    final Uint8List ed = await E2ee.edPublicFromSeed(es);
    final Uint8List x = await E2ee.xPublicFromSecret(xs);
    final String did = '${b.toRadixString(16).padLeft(2, '0') * 4}-0000-4000-8000-${b.toRadixString(16).padLeft(2, '0') * 6}';
    return Phone(user, did, es, ed)..x = x;
  }

  late Uint8List x;
  DeviceKey key({bool approved = true, DateTime? revokedAt, String kind = 'device'}) => DeviceKey(
      deviceId: deviceId, userId: user, kind: kind, edPub: edPub, xPub: x, fingerprint: '', digits: '', short: '',
      registeredByDeviceId: deviceId, registeredByPub: edPub, registrationAction: 1, registrationSignature: Uint8List(64),
      initial: true, label: '', createdAt: DateTime.utc(2026), approved: approved, revokedAt: revokedAt);
}

class Keys implements ChannelKeys {
  final Map<int, Uint8List> byEpoch = <int, Uint8List>{};
  @override
  Future<Uint8List?> circleKey(String circleId, int epoch) async => byEpoch[epoch];
  @override
  Future<int> latestEpoch(String circleId) async => byEpoch.isEmpty ? 0 : (byEpoch.keys.toList()..sort()).last;
}

class Dir implements SenderDirectory {
  final Map<String, DeviceKey> devices = <String, DeviceKey>{};
  int refreshes = 0;
  @override
  Future<DeviceKey?> sender(String circleId, String deviceId, {bool refresh = false}) async {
    if (refresh) refreshes++;
    return devices[deviceId];
  }
}

/// In-memory server: stores ciphertext, idempotent by (circle, device, seq).
class FakeServer implements ChannelApi {
  final List<WireItem> items = <WireItem>[];
  bool offline = false;
  bool permanent = false;

  /// Thrown by every post while set (a 5xx storm, a timeout ...).
  Object? failWith;
  int posts = 0;
  @override
  Future<List<BatchResult>> postBatch(String circleId, String deviceId, List<WireItem> batch) async {
    posts++;
    if (offline) throw StateError('offline');
    if (failWith != null) throw failWith!;
    if (permanent) throw const PermanentUploadError('409');
    final List<BatchResult> out = <BatchResult>[];
    for (final WireItem i in batch) {
      final bool dup = items.any((WireItem x) => x.circleId == circleId && x.deviceId == deviceId && x.seq == i.seq);
      if (dup) {
        out.add(BatchResult(i.seq, 'duplicate'));
      } else {
        items.add(WireItem(
            circleId: circleId, deviceId: deviceId, seq: i.seq, purpose: i.purpose, epoch: i.epoch, sizeBucket: i.sizeBucket,
            ciphertext: i.ciphertext, id: items.length + 1));
        out.add(BatchResult(i.seq, 'stored'));
      }
    }
    return out;
  }

  @override
  Future<Page> pull(String circleId, int after, {List<String>? purposes, int limit = 200}) async {
    final List<WireItem> all = items
        .where((WireItem i) => i.circleId == circleId && i.id! > after && (purposes == null || purposes.contains(i.purpose)))
        .toList();
    final List<WireItem> page = all.take(limit).toList();
    return Page(page, page.isEmpty ? after : page.last.id!, all.length > page.length);
  }
}

void main() {
  late Phone a, b, c;
  late Keys keys;
  late Dir dir;
  late MemoryKv senderKv, recvKv;
  late FakeClock clock;
  late ChannelSealer sealer;
  late ChannelReceiver receiver;
  final Uint8List key1 = Uint8List(32)..fillRange(0, 32, 0x42);
  final Uint8List key2 = Uint8List(32)..fillRange(0, 32, 0x43);

  setUp(() async {
    a = await Phone.make(uA, 0xa1);
    b = await Phone.make(uB, 0xb2);
    c = await Phone.make(uC, 0xc3);
    keys = Keys()..byEpoch[1] = key1;
    dir = Dir()
      ..devices[a.deviceId] = a.key()
      ..devices[b.deviceId] = b.key();
    senderKv = MemoryKv();
    recvKv = MemoryKv();
    clock = FakeClock(DateTime.utc(2026, 11, 6, 12));
    sealer = ChannelSealer(keys: keys, kv: senderKv, clock: clock);
    receiver = ChannelReceiver(keys: keys, directory: dir, kv: recvKv, clock: clock);
  });

  Future<WireItem> sealFix(Phone p, {int lat = 52, String purpose = 'fix', DateTime? at}) =>
      sealer.seal(p.id, circle, purpose, <String, dynamic>{'lat': lat, 'lon': 13.4, 'acc': 8}, at: at);

  group('cross-language vector (Go -> Dart)', () {
    test('the Go item payload verifies and opens in Dart, and Dart reproduces it byte for byte', () async {
      final Map<String, dynamic> v = jsonDecode(File('../backend/internal/e2ee/testdata/vectors.json').readAsStringSync()) as Map<String, dynamic>;
      final Map<String, dynamic> item = v['item'] as Map<String, dynamic>;
      final Map<String, dynamic> ia = v['identity_a'] as Map<String, dynamic>;
      final Uint8List ck = E2ee.unhex(v['wrap_a_to_b']['CircleKey'] as String);
      final Uint8List edSeed = E2ee.unhex(ia['EdSeed'] as String);
      final Uint8List edPub = E2ee.unhex(ia['EdPub'] as String);
      final String circ = v['circle_id'] as String;
      final String dev = ia['DeviceID'] as String;
      final Uint8List body = E2ee.unhex(item['Body'] as String);

      // Dart reproduces Go's payload exactly (same nonce, same signature: Ed25519 is deterministic).
      final Uint8List padded = await buildPaddedEnvelope(
          edSeed: edSeed, circleId: circ, epoch: 1, deviceId: dev, purpose: 'fix',
          seq: int.parse(item['Seq'] as String), tsMs: int.parse(item['TsMs'] as String), body: body);
      final Uint8List mine = await E2ee.seal(ck, circ, 1, dev, 'fix', padded, nonce: E2ee.unhex(item['Nonce'] as String));
      expect(E2ee.hex(mine), item['Payload']);

      // And the receiver accepts the Go payload from the approved device.
      final Keys k = Keys()..byEpoch[1] = ck;
      final Dir d = Dir()..devices[dev] = DeviceKey(
          deviceId: dev, userId: uA, kind: 'device', edPub: edPub, xPub: Uint8List(32), fingerprint: '', digits: '', short: '',
          registeredByDeviceId: dev, registeredByPub: edPub, registrationAction: 1, registrationSignature: Uint8List(64),
          initial: true, label: '', createdAt: DateTime.utc(2026), approved: true);
      final FakeClock fc = FakeClock(DateTime.fromMillisecondsSinceEpoch(1700000000123, isUtc: true));
      final ChannelReceiver r = ChannelReceiver(keys: k, directory: d, kv: MemoryKv(), clock: fc);
      final ReceivedItem got = await r.process(WireItem(
          circleId: circ, deviceId: dev, seq: 7, purpose: 'fix', epoch: 1, sizeBucket: padded.length,
          ciphertext: E2ee.unhex(item['Payload'] as String)));
      expect(got.userId, uA);
      expect(got.body['lat'], 52.52);
      expect(got.ts.millisecondsSinceEpoch, 1700000000123);
    });
  });

  group('seal and receive', () {
    test('round trip: position is in the plaintext only, sender is the verified account', () async {
      final WireItem w = await sealFix(a, at: clock.t);
      expect(utf8.decode(w.ciphertext, allowMalformed: true).contains('52'), isFalse);
      expect(w.sizeBucket, 256);
      expect(w.ciphertext.length, 1 + 4 + 24 + 256 + 16);
      final ReceivedItem r = await receiver.process(w);
      expect(r.userId, uA);
      expect(r.body['lat'], 52);
      expect(r.purpose, 'fix');
      expect(r.ts, clock.t);
    });

    test('sizes fall into buckets and the per-purpose cap is enforced', () async {
      final WireItem big = await sealer.seal(a.id, circle, 'history', <String, dynamic>{'x': 'y' * 3000});
      expect(big.sizeBucket, 4096);
      await expectLater(
          sealer.seal(a.id, circle, 'fix', <String, dynamic>{'x': 'y' * 3000}), throwsA(isA<ItemRejected>()));
    });

    test('without a key nothing is produced and nothing falls back to plaintext', () async {
      keys.byEpoch.clear();
      await expectLater(sealFix(a), throwsA(isA<ItemRejected>().having((ItemRejected e) => e.reason, 'reason', ItemRejection.noKey)));
      expect(senderKv.data.keys.where((String k) => k.startsWith('queue')), isEmpty);
    });

    test('sequence numbers are per device and survive a restart', () async {
      expect((await sealFix(a)).seq, 1);
      expect((await sealFix(a)).seq, 2);
      final ChannelSealer again = ChannelSealer(keys: keys, kv: senderKv, clock: clock);
      expect((await again.seal(a.id, circle, 'fix', <String, dynamic>{'lat': 1, 'lon': 1})).seq, 3);
      expect((await sealFix(b)).seq, 1);
    });

    test('a device id restored after a reinstall starts above its floor, an existing counter is kept', () async {
      await senderKv.set(ChannelSealer.seqFloorKey(a.deviceId), '1700000000000');
      expect((await sealFix(a)).seq, 1700000000001);
      expect((await sealFix(a)).seq, 1700000000002);
      // Another device id has no floor; a counter that already exists is never lowered or moved by it.
      expect((await sealFix(b)).seq, 1);
      await senderKv.set(ChannelSealer.seqFloorKey(b.deviceId), '5');
      expect((await sealFix(b)).seq, 2);
    });

    test('a member cannot forge an item from another member\'s phone', () async {
      // C shares the circle key and knows A's device id, but only has its own signing key.
      dir.devices[c.deviceId] = c.key();
      final SenderIdentity forged = SenderIdentity(a.deviceId, c.edSeed, uC);
      final WireItem w = await sealer.seal(forged, circle, 'fix', <String, dynamic>{'lat': 1, 'lon': 2});
      await expectLater(receiver.process(w), throwsA(isA<ItemRejected>().having((ItemRejected e) => e.reason, 'r', ItemRejection.badSignature)));
    });

    test('a purpose or device swap by the server fails authentication', () async {
      final WireItem w = await sealFix(a);
      WireItem swap({String? purpose, String? device}) => WireItem(
          circleId: circle, deviceId: device ?? w.deviceId, seq: w.seq, purpose: purpose ?? w.purpose, epoch: w.epoch,
          sizeBucket: w.sizeBucket, ciphertext: w.ciphertext);
      dir.devices[b.deviceId] = b.key();
      await expectLater(receiver.process(swap(purpose: 'event')), throwsA(isA<ItemRejected>()));
      await expectLater(receiver.process(swap(device: b.deviceId)), throwsA(isA<ItemRejected>()));
    });

    test('the server renumbering an item is detected (signed seq must match)', () async {
      final WireItem w = await sealFix(a);
      final WireItem renumbered = WireItem(
          circleId: circle, deviceId: w.deviceId, seq: w.seq + 5, purpose: w.purpose, epoch: w.epoch,
          sizeBucket: w.sizeBucket, ciphertext: w.ciphertext);
      await expectLater(receiver.process(renumbered),
          throwsA(isA<ItemRejected>().having((ItemRejected e) => e.reason, 'r', ItemRejection.badEnvelope)));
    });

    test('tampered ciphertext and unknown / unapproved / revoked senders are refused', () async {
      final WireItem w = await sealFix(a);
      final Uint8List bad = Uint8List.fromList(w.ciphertext)..[40] ^= 1;
      await expectLater(
          receiver.process(WireItem(circleId: circle, deviceId: w.deviceId, seq: w.seq, purpose: 'fix', epoch: 1, sizeBucket: w.sizeBucket, ciphertext: bad)),
          throwsA(isA<ItemRejected>().having((ItemRejected e) => e.reason, 'r', ItemRejection.badCipher)));

      final WireItem fromC = await sealFix(c);
      await expectLater(receiver.process(fromC), throwsA(isA<ItemRejected>().having((ItemRejected e) => e.reason, 'r', ItemRejection.unknownSender)));
      expect(dir.refreshes, 1); // asked the directory to refresh once before giving up

      dir.devices[c.deviceId] = c.key(approved: false);
      await expectLater(receiver.process(await sealFix(c)), throwsA(isA<ItemRejected>().having((ItemRejected e) => e.reason, 'r', ItemRejection.senderNotMember)));

      // Revoked later: older items still verify, newer ones do not.
      dir.devices[c.deviceId] = c.key(revokedAt: clock.t);
      final ReceivedItem old = await receiver.process(await sealFix(c, at: clock.t.subtract(const Duration(minutes: 1))));
      expect(old.userId, uC);
      await expectLater(receiver.process(await sealFix(c, at: clock.t.add(const Duration(minutes: 1)))), throwsA(isA<ItemRejected>()));
    });

    test('the recovery key kind can never be a sender', () async {
      dir.devices[c.deviceId] = c.key(kind: 'recovery');
      await expectLater(receiver.process(await sealFix(c)), throwsA(isA<ItemRejected>()));
    });
  });

  group('replay, ordering, clock skew', () {
    test('duplicates are dropped; out-of-order new items are still accepted', () async {
      final WireItem one = await sealFix(a), two = await sealFix(a), three = await sealFix(a);
      await receiver.process(three);
      await receiver.process(one); // late but new
      await expectLater(receiver.process(three), throwsA(isA<ItemRejected>().having((ItemRejected e) => e.reason, 'r', ItemRejection.duplicate)));
      await expectLater(receiver.process(one), throwsA(isA<ItemRejected>()));
      await receiver.process(two);
    });

    test('a signed timestamp far in the future is refused; skew inside the limit is fine', () async {
      await receiver.process(await sealFix(a, at: clock.t.add(const Duration(minutes: 9))));
      await expectLater(receiver.process(await sealFix(a, at: clock.t.add(const Duration(hours: 2)))),
          throwsA(isA<ItemRejected>().having((ItemRejected e) => e.reason, 'r', ItemRejection.clockSkew)));
    });

    test('a delayed (offline) item keeps its own signed time', () async {
      final DateTime then = clock.t.subtract(const Duration(hours: 3));
      final ReceivedItem r = await receiver.process(await sealFix(a, at: then));
      expect(r.ts, then);
    });
  });

  group('epochs', () {
    test('mid-flight rotation: backlog sealed under the old key still opens, new items use the new epoch', () async {
      final WireItem old1 = await sealFix(a, at: clock.t);
      keys.byEpoch[2] = key2;
      final WireItem new2 = await sealFix(a, at: clock.t.add(const Duration(seconds: 1)));
      expect(old1.epoch, 1);
      expect(new2.epoch, 2);
      expect((await receiver.process(new2)).epoch, 2);
      // The old-epoch item arrives after the epoch change, but it is backlog (sent before) and from the same grace window.
      expect((await receiver.process(old1)).epoch, 1);
    });

    test('a device never goes back to an older epoch for fresh items', () async {
      keys.byEpoch[2] = key2;
      final WireItem e2 = await sealFix(a);
      final ChannelSealer old = ChannelSealer(keys: keys, kv: senderKv, clock: clock);
      final WireItem e1 = await old.seal(a.id, circle, 'fix', <String, dynamic>{'lat': 1, 'lon': 1}, maxEpoch: 1);
      expect(e1.seq, greaterThan(e2.seq));
      await receiver.process(e2);
      await expectLater(receiver.process(e1), throwsA(isA<ItemRejected>().having((ItemRejected e) => e.reason, 'r', ItemRejection.epochRollback)));
    });

    test('circle-wide: after the grace period an old-epoch live item is refused, backlog is not', () async {
      keys.byEpoch[2] = key2;
      dir.devices[c.deviceId] = c.key();
      // B publishes under epoch 2: receiver learns the newer epoch now.
      await receiver.process(await sealFix(b, at: clock.t));
      final ChannelSealer slow = ChannelSealer(keys: keys, kv: MemoryKv(), clock: clock);
      // C is slow and still seals under epoch 1 with a timestamp BEFORE the switch: backlog.
      final WireItem backlog = await slow.seal(c.id, circle, 'fix', <String, dynamic>{'lat': 1, 'lon': 1}, at: clock.t.subtract(const Duration(minutes: 5)), maxEpoch: 1);
      expect((await receiver.process(backlog)).epoch, 1);
      // 30 minutes later C (compromised or never synced) still seals under epoch 1 with a NEW time.
      clock.t = clock.t.add(const Duration(minutes: 30));
      final WireItem live = await slow.seal(c.id, circle, 'fix', <String, dynamic>{'lat': 2, 'lon': 2}, maxEpoch: 1);
      await expectLater(receiver.process(live), throwsA(isA<ItemRejected>().having((ItemRejected e) => e.reason, 'r', ItemRejection.epochRollback)));
    });

    test('an item for an epoch whose key this phone does not hold waits (deferred), it is not lost', () async {
      final FakeServer srv = FakeServer();
      keys.byEpoch[2] = key2;
      final WireItem w = await sealFix(a);
      await srv.postBatch(circle, a.deviceId, <WireItem>[w]);
      keys.byEpoch.remove(2); // receiver has not got the new key yet
      final ChannelSync sync = ChannelSync(api: srv, receiver: receiver, kv: recvKv);
      final List<ReceivedItem> got = <ReceivedItem>[];
      SyncStats s = await sync.catchUp(circle, onItem: got.add);
      expect(got, isEmpty);
      expect(s.rejected[ItemRejection.noKey], 1);
      keys.byEpoch[2] = key2; // key arrives
      s = await sync.catchUp(circle, onItem: got.add);
      expect(got.length, 1);
      expect(s.accepted, 1);
    });
  });

  group('store and forward', () {
    test('offline: items stay queued, retries are idempotent, order is preserved', () async {
      final FakeServer srv = FakeServer();
      final SealedQueue q = SealedQueue(kv: senderKv, clock: clock);
      for (int i = 0; i < 5; i++) {
        await q.enqueue(await sealFix(a, lat: 40 + i));
      }
      srv.offline = true;
      expect(await q.flush(srv, deviceFor: (_) => a.deviceId), 0);
      expect(await q.length(), 5);
      srv.offline = false;
      expect(await q.flush(srv, deviceFor: (_) => a.deviceId), 5);
      expect(await q.length(), 0);
      expect(srv.items.map((WireItem i) => i.seq).toList(), <int>[1, 2, 3, 4, 5]);
      // The same items sent again (crash between send and removal) are duplicates, not copies.
      await q.enqueue(srv.items.first);
      expect(await q.flush(srv, deviceFor: (_) => a.deviceId), 1);
      expect(srv.items.length, 5);
    });

    test('batches of at most 50, and a permanent refusal drops the batch instead of pinning the queue', () async {
      final FakeServer srv = FakeServer();
      final SealedQueue q = SealedQueue(kv: senderKv, clock: clock);
      for (int i = 0; i < 120; i++) {
        await q.enqueue(await sealFix(a));
      }
      await q.flush(srv, deviceFor: (_) => a.deviceId);
      expect(srv.posts, 3);
      for (int i = 0; i < 3; i++) {
        await q.enqueue(await sealFix(a));
      }
      srv.permanent = true;
      await q.flush(srv, deviceFor: (_) => a.deviceId);
      expect(await q.length(), 0);
    });

    test('the queue is bounded and ages out old fixes but keeps events', () async {
      final SealedQueue q = SealedQueue(kv: senderKv, clock: clock, maxItems: 5);
      for (int i = 0; i < 8; i++) {
        await q.enqueue(await sealFix(a));
      }
      expect(await q.length(), 5);
      final SealedQueue aged = SealedQueue(kv: MemoryKv(), clock: clock);
      await aged.enqueue(await sealFix(a));
      await aged.enqueue(await sealer.seal(a.id, circle, 'event', <String, dynamic>{'k': 'place'}));
      clock.t = clock.t.add(const Duration(days: 3));
      await aged.enqueue(await sealFix(a));
      final List<WireItem> left = await aged.peek();
      expect(left.map((WireItem i) => i.purpose).toList(), <String>['event', 'fix']);
    });

    test('a 5xx storm never eats queued items: nothing is dropped, everything arrives once afterwards', () async {
      final FakeServer srv = FakeServer();
      final SealedQueue q = SealedQueue(kv: senderKv, clock: clock);
      await q.enqueue(await sealFix(a, purpose: 'checkin'));
      await q.enqueue(await sealFix(a, purpose: 'chat'));
      await q.enqueue(await sealFix(a));
      srv.failWith = const ApiException(503, 'bad gateway');
      for (int i = 0; i < 60; i++) {
        expect(await q.flush(srv, deviceFor: (_) => a.deviceId), 0);
      }
      expect(await q.length(), 3, reason: '60 failed flushes used to drop the whole batch after 20');
      srv.failWith = null;
      expect(await q.flush(srv, deviceFor: (_) => a.deviceId), 3);
      expect(srv.items.map((WireItem i) => i.purpose).toList(), <String>['checkin', 'chat', 'fix']);
      expect(srv.items.map((WireItem i) => i.seq).toList(), <int>[1, 2, 3]);
    });

    test('check-ins and chat are never dropped for age or to make room; fixes go first', () async {
      final SealedQueue q = SealedQueue(kv: senderKv, clock: clock, maxItems: 3);
      await q.enqueue(await sealFix(a, purpose: 'checkin'));
      await q.enqueue(await sealFix(a, purpose: 'chat'));
      for (int i = 0; i < 4; i++) {
        await q.enqueue(await sealFix(a));
      }
      List<WireItem> left = await q.peek();
      expect(left.where((WireItem i) => i.purpose == 'checkin').length, 1);
      expect(left.where((WireItem i) => i.purpose == 'chat').length, 1);
      expect(left.length, 3);
      for (int i = 0; i < 5; i++) {
        await q.enqueue(await sealFix(a, purpose: 'chat'));
      }
      left = await q.peek();
      expect(left.where((WireItem i) => i.purpose == 'chat').length, 6, reason: 'over the cap rather than losing a message');
      // Three days offline: the old fix expires, the messages stay.
      clock.t = clock.t.add(const Duration(days: 3));
      await q.enqueue(await sealFix(a, purpose: 'chat'));
      left = await q.peek();
      expect(left.where((WireItem i) => i.purpose == 'fix'), isEmpty);
      expect(left.where((WireItem i) => i.purpose == 'chat').length, 7);
      expect(left.where((WireItem i) => i.purpose == 'checkin').length, 1);
    });

    test('items sealed under epoch 1 flush fine after the circle moved to epoch 2', () async {
      final FakeServer srv = FakeServer();
      final SealedQueue q = SealedQueue(kv: senderKv, clock: clock);
      await q.enqueue(await sealFix(a));
      keys.byEpoch[2] = key2;
      await q.enqueue(await sealFix(a));
      await q.flush(srv, deviceFor: (_) => a.deviceId);
      expect(srv.items.map((WireItem i) => i.epoch).toList(), <int>[1, 2]);
    });
  });

  group('catch-up', () {
    test('pulls all pages, keeps the cursor, never re-applies and counts rejects', () async {
      final FakeServer srv = FakeServer();
      final SealedQueue q = SealedQueue(kv: senderKv, clock: clock);
      for (int i = 0; i < 7; i++) {
        await q.enqueue(await sealFix(a, lat: 10 + i));
      }
      dir.devices[c.deviceId] = c.key(approved: false);
      await q.enqueue(await sealFix(c)); // a non-approved member's device
      await q.flush(srv, deviceFor: (String _) => a.deviceId);
      expect(await q.length(), 0);

      final ChannelSync sync = ChannelSync(api: srv, receiver: receiver, kv: recvKv);
      final List<ReceivedItem> got = <ReceivedItem>[];
      SyncStats s = await sync.catchUp(circle, onItem: got.add);
      expect(got.map((ReceivedItem r) => r.body['lat']).toList(), <Object?>[10, 11, 12, 13, 14, 15, 16]);
      expect(s.rejected[ItemRejection.senderNotMember], 1);
      expect(await sync.cursor(circle), srv.items.last.id);
      got.clear();
      s = await sync.catchUp(circle, onItem: got.add);
      expect(got, isEmpty);
      expect(s.accepted, 0);
    });
  });
}
