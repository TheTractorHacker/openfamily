import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/e2ee/e2ee_crypto.dart';
import 'package:openfamily/services/e2ee/e2ee_models.dart';
import 'package:openfamily/services/e2ee/lanes_wire.dart';
import 'package:openfamily/services/e2ee/private_channel.dart';

import 'private_channel_test.dart' show Phone, Keys, Dir, FakeClock, uA, uB, circle;

// Phase 4: lane selection of the sealer, the receiver's lane checks (header,
// per-line rollback, cross-line confusion), badges, and the upload queue's
// re-seal / drop rule. Pure unit tests over small fakes.

class FakeLanes implements LaneSource {
  LaneChoice own = LaneChoice.phone;
  bool assist = true;
  final Map<String, List<PrefEntry>> prefs = <String, List<PrefEntry>>{};
  bool Function()? allowedHook;
  int allowedCalls = 0;
  bool throwOnRead = false;

  @override
  Future<LaneChoice> ownLane(String circleId) async {
    if (throwOnRead) throw StateError('storage broke');
    return own;
  }

  @override
  Future<bool> serverLaneAllowed(String circleId) async {
    allowedCalls++;
    if (throwOnRead) throw StateError('storage broke');
    return allowedHook != null ? allowedHook!() : (assist && own.line == E2ee.lineServer);
  }

  @override
  Future<List<PrefEntry>> prefsOf(String circleId, String userId) async => prefs[userId] ?? <PrefEntry>[];

  @override
  Future<bool> serverAssistOn(String circleId) async => assist;
}

class FakeSk implements ServerKeys {
  final Map<int, Uint8List> byGen = <int, Uint8List>{};
  @override
  Future<Uint8List?> serverKey(String circleId, int gen) async => byGen[gen];
  @override
  Future<int> latestServerGen(String circleId) async => byGen.isEmpty ? 0 : (byGen.keys.toList()..sort()).last;
}

class RecordingApi implements ChannelApi {
  final List<WireItem> posted = <WireItem>[];
  @override
  Future<List<BatchResult>> postBatch(String circleId, String deviceId, List<WireItem> items) async {
    posted.addAll(items);
    return <BatchResult>[for (final WireItem i in items) BatchResult(i.seq, 'stored')];
  }

  @override
  Future<Page> pull(String circleId, int after, {List<String>? purposes, int limit = 200}) async => Page(<WireItem>[], after, false);
}

WireItem _copy(WireItem i, {Uint8List? ct, int? declaredLine, int? epoch, bool clearDeclared = false}) => WireItem(
    circleId: i.circleId, deviceId: i.deviceId, seq: i.seq, purpose: i.purpose, epoch: epoch ?? i.epoch, sizeBucket: i.sizeBucket,
    ciphertext: ct ?? i.ciphertext, line: i.line, declaredLine: clearDeclared ? null : (declaredLine ?? i.declaredLine));

void main() {
  late Phone a, b;
  late Keys keys;
  late FakeSk sk;
  late FakeLanes lanesA, lanesB;
  late Dir dir;
  late FakeClock clock;
  late MemoryKv senderKv, recvKv;
  late ChannelSealer sealer;
  late ChannelReceiver receiver;
  final Uint8List ck = Uint8List(32)..fillRange(0, 32, 0x42);
  final Uint8List sk1 = Uint8List(32)..fillRange(0, 32, 0x51);
  final Uint8List sk2 = Uint8List(32)..fillRange(0, 32, 0x52);

  ChannelReceiver mkReceiver({LaneSource? lanes, ServerKeys? serverKeys, MemoryKv? kv}) =>
      ChannelReceiver(keys: keys, directory: dir, kv: kv ?? recvKv, clock: clock, serverKeys: serverKeys, lanes: lanes);

  setUp(() async {
    a = await Phone.make(uA, 0xa1);
    b = await Phone.make(uB, 0xb2);
    keys = Keys()..byEpoch[1] = ck;
    sk = FakeSk()..byGen[1] = sk1;
    lanesA = FakeLanes();
    lanesB = FakeLanes()..prefs[uA] = <PrefEntry>[const PrefEntry(E2ee.lineServer, 1000)];
    dir = Dir()
      ..devices[a.deviceId] = a.key()
      ..devices[b.deviceId] = b.key();
    senderKv = MemoryKv();
    recvKv = MemoryKv();
    clock = FakeClock(DateTime.utc(2026, 11, 6, 12));
    sealer = ChannelSealer(keys: keys, kv: senderKv, clock: clock, lanes: lanesA, serverKeys: sk);
    receiver = mkReceiver(lanes: lanesB, serverKeys: sk);
  });

  Map<String, dynamic> body(double lat) => <String, dynamic>{'lat': lat, 'lon': 2.0};

  group('wire shapes of the real server (docs section 18.2)', () {
    test('state response, wrap and item records, request bodies', () {
      final Uint8List z = Uint8List(32);
      final ProcessingServerState st = ProcessingServerState.fromJson(<String, dynamic>{
        'circle_id': circle, 'in_effect': true, 'my_lane': 'server',
        'device': <String, dynamic>{'device_id': a.deviceId, 'fingerprint': 'ab' * 32, 'owner_user_id': uA, 'label': 'srv'},
        'policy': <String, dynamic>{
          'server_assist': true, 'default_for_new': 'phone', 'member_opt_out': 'required_server', 'sk_gen': 2,
          'commitment': E2ee.b64(Uint8List(32)..fillRange(0, 32, 1)), 'rekey_required': true,
          'statement': <String, dynamic>{
            'log_seq': 9, 'admin_user_id': uA, 'actor_device_id': a.deviceId, 'server_assist': true, 'default_for_new': 'phone',
            'member_opt_out': 'required_server', 'sk_gen': 2, 'commitment': E2ee.b64(Uint8List(32)..fillRange(0, 32, 1)),
            'nonce': E2ee.b64(Uint8List(16)), 'signature': E2ee.b64(Uint8List(64)),
          },
        },
        'members': <Map<String, dynamic>>[
          <String, dynamic>{
            'user_id': uB, 'lane': 'server', 'since': '2026-11-06T12:00:00Z',
            'pref': <String, dynamic>{
              'lane': 'server', 'sk_gen': 2, 'server_device_id': a.deviceId, 'server_fingerprint': E2ee.b64(z), 'nonce': E2ee.b64(Uint8List(16)),
              'approver_device_id': b.deviceId, 'signature': E2ee.b64(Uint8List(64)), 'legacy': false, 'log_seq': 7,
            },
          },
          <String, dynamic>{'user_id': uA, 'lane': 'phone'},
        ],
      });
      expect((st.policy!.skGen, st.policy!.memberOptOut, st.rekeyRequired, st.inEffect, st.serverDeviceId), (2, E2ee.optOutRequiredServer, true, true, a.deviceId));
      expect(st.prefs.single.userId, uB);
      expect(st.prefs.single.lane, E2ee.lineServer);
      expect(st.claimedMembers, hasLength(2));
      // A statement with an unknown enum value is dropped (fail closed).
      expect(ProcessingServerState.fromJson(<String, dynamic>{'policy': <String, dynamic>{'statement': <String, dynamic>{'member_opt_out': 'whatever'}}}).policy, isNull);
      // Wrap records carry key_line; unknown line = dropped.
      expect(WrapRecord.tryParse(<String, dynamic>{'epoch': 1, 'recipient_device_id': 'r', 'wrapper_device_id': 'w', 'wrapper_ed25519_pub': E2ee.b64(z), 'wrapped_key': E2ee.b64(z), 'signature': E2ee.b64(z), 'key_line': 'bogus'}), isNull);
      // Request bodies.
      final PrefStatement p = PrefStatement(userId: uB, lane: E2ee.linePhone, skGen: 0, serverDeviceId: E2ee.zeroUuid, nonce: Uint8List(16), approverDeviceId: b.deviceId, signature: Uint8List(64));
      expect(p.toRequest(z).keys.toSet(), <String>{'lane', 'sk_gen', 'server_device_id', 'server_fingerprint', 'nonce', 'approver_device_id', 'signature'});
      expect(LanesPaths.policy(circle), endsWith('/e2ee/processing-policy'));
      expect(LanesPaths.pref(circle), endsWith('/e2ee/processing-pref'));
    });
  });

  group('sealer lane selection (from the member\'s own signed pref)', () {
    test('phone pref: a v1 item under CK, identical to what an old app sends (no key_line on the wire)', () async {
      final WireItem it = await sealer.seal(a.id, circle, 'fix', body(1));
      expect(it.line, E2ee.linePhone);
      expect(it.ciphertext[0], E2ee.msgVersion);
      expect(it.twin, isNull);
      expect(it.toUpload().containsKey(LanesFields.keyLine), isFalse);
      expect((await receiver.process(it)).badge, ProcessingBadge.phoneOnly);
    });

    test('server pref: a v2 item under SK with the phone twin, key_line only on the server line', () async {
      lanesA.own = const LaneChoice(E2ee.lineServer, 1);
      final WireItem it = await sealer.seal(a.id, circle, 'fix', body(1));
      expect(it.line, E2ee.lineServer);
      expect(it.epoch, 1);
      final PayloadHeader h = E2ee.parsePayloadHeader(it.ciphertext);
      expect((h.version, h.line, h.gen), (2, E2ee.lineServer, 1));
      expect(it.toUpload()[LanesFields.keyLine], 'server');
      // The twin is the same item under CK: same seq, a v1 payload.
      expect(it.twin!.seq, it.seq);
      expect(it.twin!.line, E2ee.linePhone);
      expect(it.twin!.ciphertext[0], E2ee.msgVersion);
      final ReceivedItem r = await receiver.process(it);
      expect((r.line, r.badge, r.body['lat']), (E2ee.lineServer, ProcessingBadge.serverAssisted, 1.0));
    });

    test('no usable SK: falls back to the PHONE lane (never plaintext, never a half-sealed item)', () async {
      lanesA.own = const LaneChoice(E2ee.lineServer, 3); // gen 3 not held
      final WireItem it = await sealer.seal(a.id, circle, 'fix', body(1));
      expect(it.line, E2ee.linePhone);
      expect(sealer.laneFallbacks, 1);
    });

    test('policy off or an unreadable lane store: phone lane', () async {
      lanesA.own = const LaneChoice(E2ee.lineServer, 1);
      lanesA.assist = false;
      expect((await sealer.seal(a.id, circle, 'fix', body(1))).line, E2ee.linePhone);
      lanesA.assist = true;
      lanesA.throwOnRead = true;
      expect((await sealer.seal(a.id, circle, 'fix', body(1))).line, E2ee.linePhone);
    });

    test('a sealer without lanes (an old app) never produces the server line', () async {
      final ChannelSealer old = ChannelSealer(keys: keys, kv: senderKv, clock: clock);
      lanesA.own = const LaneChoice(E2ee.lineServer, 1);
      final WireItem it = await old.seal(a.id, circle, 'fix', body(1));
      expect(it.line, E2ee.linePhone);
      expect(it.ciphertext[0], E2ee.msgVersion);
    });

    test('result kinds are sealed like any purpose, in the author lane', () async {
      lanesA.own = const LaneChoice(E2ee.lineServer, 1);
      for (final String k in ChannelPurpose.results) {
        expect((await receiver.process(await sealer.seal(a.id, circle, k, <String, dynamic>{'x': 1}))).purpose, k);
      }
    });
  });

  group('receiver: header, badge, cross-line confusion', () {
    test('badge comes from the verified header and the author\'s signed pref, not from a server flag', () async {
      lanesA.own = const LaneChoice(E2ee.lineServer, 1);
      final WireItem it = await sealer.seal(a.id, circle, 'fix', body(1));
      // The author's verified history says phone: the SK item is accepted but flagged.
      lanesB.prefs[uA] = <PrefEntry>[const PrefEntry(E2ee.linePhone, 0)];
      final ReceivedItem r = await mkReceiver(lanes: lanesB, serverKeys: sk, kv: MemoryKv()).process(it);
      expect(r.badge, ProcessingBadge.unverified);
      // No lane source at all: flagged too (fail closed).
      expect((await mkReceiver(serverKeys: sk, kv: MemoryKv()).process(it)).badge, ProcessingBadge.unverified);
      // Assistance off in the verified policy: flagged.
      lanesB.prefs[uA] = <PrefEntry>[const PrefEntry(E2ee.lineServer, 0)];
      lanesB.assist = false;
      expect((await mkReceiver(lanes: lanesB, serverKeys: sk, kv: MemoryKv()).process(it)).badge, ProcessingBadge.unverified);
      lanesB.assist = true;
      expect((await mkReceiver(lanes: lanesB, serverKeys: sk, kv: MemoryKv()).process(it)).badge, ProcessingBadge.serverAssisted);
    });

    test('a pref that came into force AFTER the item flags it', () async {
      lanesA.own = const LaneChoice(E2ee.lineServer, 1);
      final WireItem it = await sealer.seal(a.id, circle, 'fix', body(1));
      lanesB.prefs[uA] = <PrefEntry>[PrefEntry(E2ee.lineServer, clock.t.millisecondsSinceEpoch + 60000)];
      expect((await receiver.process(it)).badge, ProcessingBadge.unverified);
    });

    test('the server\'s key_line must agree with the signed header (relabelling is refused)', () async {
      lanesA.own = const LaneChoice(E2ee.lineServer, 1);
      final WireItem srv = await sealer.seal(a.id, circle, 'fix', body(1));
      await expectLater(receiver.process(_copy(srv, declaredLine: E2ee.linePhone)), throwsA(isA<ItemRejected>().having((ItemRejected e) => e.reason, 'reason', ItemRejection.laneMismatch)));
      lanesA.own = LaneChoice.phone;
      final WireItem ph = await sealer.seal(a.id, circle, 'fix', body(2));
      await expectLater(receiver.process(_copy(ph, declaredLine: E2ee.lineServer)), throwsA(isA<ItemRejected>().having((ItemRejected e) => e.reason, 'reason', ItemRejection.laneMismatch)));
      // No label at all: the header decides.
      expect((await receiver.process(_copy(srv, clearDeclared: true))).line, E2ee.lineServer);
    });

    test('tampering with the line byte fails even when CK and SK are the SAME bytes', () async {
      final Keys same = Keys()..byEpoch[1] = sk1;
      final FakeSk skSame = FakeSk()..byGen[1] = sk1;
      final ChannelSealer s2 = ChannelSealer(keys: same, kv: MemoryKv(), clock: clock, lanes: lanesA, serverKeys: skSame);
      final ChannelReceiver r2 = ChannelReceiver(keys: same, directory: dir, kv: MemoryKv(), clock: clock, serverKeys: skSame, lanes: lanesB);
      lanesA.own = const LaneChoice(E2ee.lineServer, 1);
      final WireItem srv = await s2.seal(a.id, circle, 'fix', body(1));
      final Uint8List flipped = Uint8List.fromList(srv.ciphertext)..[1] = E2ee.linePhone;
      await expectLater(r2.process(_copy(srv, ct: flipped, clearDeclared: true)), throwsA(isA<ItemRejected>()));
      // Generation tamper: header gen and the declared epoch agree but the AEAD AAD does not.
      skSame.byGen[2] = sk1;
      final Uint8List g2 = Uint8List.fromList(srv.ciphertext)..[5] = 2;
      await expectLater(r2.process(_copy(srv, ct: g2, epoch: 2, clearDeclared: true)), throwsA(isA<ItemRejected>()));
    });

    test('unknown line, unknown version and a bad key_line string are rejected (fail closed)', () async {
      lanesA.own = const LaneChoice(E2ee.lineServer, 1);
      final WireItem srv = await sealer.seal(a.id, circle, 'fix', body(1));
      for (final void Function(Uint8List) mut in <void Function(Uint8List)>[
        (Uint8List c) => c[1] = 2, // unknown line
        (Uint8List c) => c[0] = 3, // unknown version
        (Uint8List c) => c[0] = 0,
      ]) {
        final Uint8List c = Uint8List.fromList(srv.ciphertext);
        mut(c);
        await expectLater(receiver.process(_copy(srv, ct: c, clearDeclared: true)),
            throwsA(isA<ItemRejected>().having((ItemRejected e) => e.reason, 'reason', ItemRejection.malformed)));
      }
      expect(WireItem.fromServer(<String, dynamic>{
        'circle_id': circle, 'device_id': a.deviceId, 'seq': 1, 'purpose': 'fix', 'epoch': 1, 'size_bucket': 256,
        'ciphertext': E2ee.b64(srv.ciphertext), 'key_line': 'weird',
      }), isNull);
    });

    test('a server-line item is unreadable without SK (an old app / a phone that has none yet)', () async {
      lanesA.own = const LaneChoice(E2ee.lineServer, 1);
      final WireItem srv = await sealer.seal(a.id, circle, 'fix', body(1));
      await expectLater(mkReceiver(kv: MemoryKv()).process(srv),
          throwsA(isA<ItemRejected>().having((ItemRejected e) => e.reason, 'reason', ItemRejection.noKey)));
      // Wrong SK bytes: a bad cipher, not a crash.
      final FakeSk wrong = FakeSk()..byGen[1] = sk2;
      await expectLater(mkReceiver(serverKeys: wrong, kv: MemoryKv()).process(srv),
          throwsA(isA<ItemRejected>().having((ItemRejected e) => e.reason, 'reason', ItemRejection.badCipher)));
    });

    test('forged sender: an item signed by another device is refused on the server line too', () async {
      lanesA.own = const LaneChoice(E2ee.lineServer, 1);
      final WireItem srv = await sealer.seal(a.id, circle, 'fix', body(1));
      // Claim it came from B's device: AAD and signature bind the device.
      final WireItem asB = WireItem(circleId: circle, deviceId: b.deviceId, seq: srv.seq, purpose: srv.purpose, epoch: srv.epoch,
          sizeBucket: srv.sizeBucket, ciphertext: srv.ciphertext, line: srv.line);
      await expectLater(receiver.process(asB), throwsA(isA<ItemRejected>()));
    });

    test('seq and replay: a duplicate is refused, the signed seq must match the server\'s', () async {
      lanesA.own = const LaneChoice(E2ee.lineServer, 1);
      final WireItem srv = await sealer.seal(a.id, circle, 'fix', body(1));
      await receiver.process(srv);
      await expectLater(receiver.process(srv), throwsA(isA<ItemRejected>().having((ItemRejected e) => e.reason, 'reason', ItemRejection.duplicate)));
      final WireItem srv2 = await sealer.seal(a.id, circle, 'fix', body(2));
      final WireItem renumbered = WireItem(circleId: circle, deviceId: a.deviceId, seq: srv2.seq + 7, purpose: 'fix', epoch: 1,
          sizeBucket: srv2.sizeBucket, ciphertext: srv2.ciphertext, line: E2ee.lineServer);
      await expectLater(receiver.process(renumbered), throwsA(isA<ItemRejected>()));
    });
  });

  group('rollback guard is per key line', () {
    test('an older SK generation is refused after a newer one aged, while the phone line is unaffected', () async {
      sk.byGen[2] = sk2;
      lanesA.own = const LaneChoice(E2ee.lineServer, 2);
      await receiver.process(await sealer.seal(a.id, circle, 'fix', body(1)));
      clock.t = clock.t.add(const Duration(minutes: 30));
      lanesA.own = const LaneChoice(E2ee.lineServer, 1);
      final WireItem old = await sealer.seal(a.id, circle, 'fix', body(2));
      await expectLater(receiver.process(old), throwsA(isA<ItemRejected>().having((ItemRejected e) => e.reason, 'reason', ItemRejection.epochRollback)));
      // The phone line (CK epoch 1) is a different counter: still accepted.
      lanesA.own = LaneChoice.phone;
      expect((await receiver.process(await sealer.seal(a.id, circle, 'fix', body(3)))).line, E2ee.linePhone);
    });

    test('a newer CK epoch does not outdate SK items, and an SK gen 2 does not outdate CK epoch 1', () async {
      final Uint8List ck2 = Uint8List(32)..fillRange(0, 32, 0x44);
      keys.byEpoch[2] = ck2;
      await receiver.process(await sealer.seal(a.id, circle, 'fix', body(1))); // phone epoch 2
      clock.t = clock.t.add(const Duration(minutes: 30));
      lanesA.own = const LaneChoice(E2ee.lineServer, 1);
      expect((await receiver.process(await sealer.seal(a.id, circle, 'fix', body(2)))).line, E2ee.lineServer);
    });
  });

  group('upload queue: a pref flip must NEVER let an SK item upload after an opt-out', () {
    late SealedQueue queue;
    late RecordingApi api;
    setUp(() {
      queue = SealedQueue(kv: MemoryKv(), clock: clock);
      api = RecordingApi();
    });

    Future<void> queueServerItems(int n) async {
      lanesA.own = const LaneChoice(E2ee.lineServer, 1);
      for (int i = 0; i < n; i++) {
        await queue.enqueue(await sealer.seal(a.id, circle, 'fix', body(i + 1.0)));
      }
    }

    test('opt-out before the upload: queued SK items are replaced by their phone twins (same seq) and still delivered', () async {
      await queueServerItems(3);
      expect((await queue.peek()).every((WireItem i) => i.line == E2ee.lineServer), isTrue);
      lanesA.own = LaneChoice.phone; // the member opted out
      expect(await queue.reconcileLanes(lanesA), 3);
      final List<WireItem> q = await queue.peek();
      expect(q.map((WireItem i) => i.seq).toList(), <int>[1, 2, 3]);
      expect(q.every((WireItem i) => i.line == E2ee.linePhone && i.ciphertext[0] == E2ee.msgVersion), isTrue);
      expect(await queue.flush(api, deviceFor: (_) => a.deviceId, lanes: lanesA), 3);
      expect(api.posted.every((WireItem i) => i.line == E2ee.linePhone), isTrue);
      // The twins are valid phone-line items for the receiver.
      for (final WireItem i in api.posted) {
        expect((await mkReceiver(kv: MemoryKv()).process(i)).line, E2ee.linePhone);
      }
    });

    test('flush alone reconciles (the opt-out may not have called reconcile): nothing server-line is posted', () async {
      await queueServerItems(2);
      lanesA.own = LaneChoice.phone;
      await queue.flush(api, deviceFor: (_) => a.deviceId, lanes: lanesA);
      expect(api.posted, hasLength(2));
      expect(api.posted.any((WireItem i) => i.line == E2ee.lineServer), isFalse);
    });

    test('the pref flips BETWEEN the reconcile and the request: still nothing server-line leaves', () async {
      await queueServerItems(2);
      int reads = 0;
      lanesA.allowedHook = () => ++reads <= 1; // allowed for the first read only
      await queue.flush(api, deviceFor: (_) => a.deviceId, lanes: lanesA);
      expect(api.posted, hasLength(2));
      expect(api.posted.any((WireItem i) => i.line == E2ee.lineServer), isFalse);
      expect(reads, greaterThan(1), reason: 'the pref is read again right before the request');
    });

    test('an item without a phone twin is DROPPED on opt-out, never uploaded', () async {
      final Keys noCk = Keys(); // holds no circle key: no twin can be made
      final ChannelSealer s = ChannelSealer(keys: noCk, kv: MemoryKv(), clock: clock, lanes: lanesA, serverKeys: sk);
      lanesA.own = const LaneChoice(E2ee.lineServer, 1);
      final WireItem it = await s.seal(a.id, circle, 'fix', body(1));
      expect(it.twin, isNull);
      await queue.enqueue(it);
      lanesA.own = LaneChoice.phone;
      await queue.flush(api, deviceFor: (_) => a.deviceId, lanes: lanesA);
      expect(api.posted, isEmpty);
      expect(await queue.length(), 0);
    });

    test('no lane source / an erroring lane store: server-line items are never sent', () async {
      await queueServerItems(2);
      await queue.flush(api, deviceFor: (_) => a.deviceId);
      expect(api.posted.any((WireItem i) => i.line == E2ee.lineServer), isFalse);
      await queueServerItems(2);
      lanesA.throwOnRead = true;
      await queue.flush(api, deviceFor: (_) => a.deviceId, lanes: lanesA);
      expect(api.posted.any((WireItem i) => i.line == E2ee.lineServer), isFalse);
    });

    test('while the member stays server-assisted the SK items are sent as they are', () async {
      await queueServerItems(2);
      await queue.flush(api, deviceFor: (_) => a.deviceId, lanes: lanesA);
      expect(api.posted.every((WireItem i) => i.line == E2ee.lineServer), isTrue);
      expect(api.posted.first.toUpload()[LanesFields.keyLine], 'server');
    });

    test('re-opt-in later does not resurrect old twins as server items', () async {
      await queueServerItems(1);
      lanesA.own = LaneChoice.phone;
      await queue.reconcileLanes(lanesA);
      lanesA.own = const LaneChoice(E2ee.lineServer, 1);
      await queue.flush(api, deviceFor: (_) => a.deviceId, lanes: lanesA);
      expect(api.posted.single.line, E2ee.linePhone, reason: 'past items stay phone-only');
    });

    test('queue storage round trip keeps line and twin', () async {
      await queueServerItems(1);
      final WireItem it = (await queue.peek()).single;
      expect(it.line, E2ee.lineServer);
      expect(it.twin, isNotNull);
      expect(WireItem.fromStore(it.toStore()).twin!.seq, it.seq);
    });
  });
}
