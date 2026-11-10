import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/circle.dart';
import 'package:openfamily/services/diagnostics/diag_model.dart' show PrivateCircleDelivery;
import 'package:openfamily/services/e2ee/e2ee_crypto.dart';
import 'package:openfamily/services/e2ee/e2ee_models.dart';
import 'package:openfamily/services/e2ee/e2ee_service.dart';
import 'package:openfamily/services/e2ee/e2ee_trust.dart';
import 'package:openfamily/services/e2ee/e2ee_vault.dart';
import 'package:openfamily/services/e2ee/lanes_service.dart';
import 'package:openfamily/services/e2ee/lanes_store.dart';
import 'package:openfamily/services/e2ee/lanes_wire.dart';
import 'package:openfamily/services/e2ee/private_channel.dart';
import 'package:openfamily/services/e2ee/private_runtime.dart';

import '../../support/fake_e2ee_server.dart';
import '../../support/viewer_fixture.dart';
import 'private_channel_test.dart' show FakeClock;

// Phase 4 integration: policy (admin), pref (member), SK custody, queue re-seal
// on opt-out, receiver badges, old-app and hostile-server simulations. Everything
// runs against the in-memory server fake that enforces the same rules as the
// real handlers (admin only policy, own-only pref, CK never to a server key...).

const String uA = '11111111-1111-4111-8111-111111111111';
const String uB = '22222222-2222-4222-8222-222222222222';
const String uC = '33333333-3333-4333-8333-333333333333';
const String priv = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';

Circle circleOf(String id) =>
    Circle(id: id, name: id, role: 'member', sharingEnabled: true, memberCount: 3, e2eeMode: 'private');

/// Lets a test make the pref upload fail (offline at the moment of the opt-out).
class FlakyClient extends FakeE2eeClient {
  FlakyClient(super.s, super.uid);
  bool failPrefPut = false;
  @override
  Future<void> putProcessingPref(String circleId, Map<String, dynamic> body) async {
    if (failPrefPut) throw StateError('offline');
    return super.putProcessingPref(circleId, body);
  }
}

class Dev {
  Dev(FakeE2eeServer server, FakeLaneChannel channel, this.user, FakeClock clock)
      : vault = MemoryVault(),
        kv = MemoryKv(),
        client = FlakyClient(server, user) {
    service = E2eeService(api: client, vault: vault, trust: TrustStore(MemoryTrustKv()), userIdProvider: () async => user);
    runtime = PrivateRuntime(
        service: service, api: client, kv: kv, clock: clock, channel: channel,
        directory: StateSenderDirectory(client));
    runtime.lanesService.logTtl = Duration.zero;
    runtime.notify = (String t, String b) async {};
    runtime.chatNotify = (String t, String b) async {};
  }
  final String user;
  final MemoryVault vault;
  final MemoryKv kv;
  final FlakyClient client;
  late final E2eeService service;
  late final PrivateRuntime runtime;
  LanesService get lanes => runtime.lanesService;
  LaneStore get store => lanes.store;
  Future<LaneChoice> ownLane() => runtime.lanes.ownLane(priv);
}

void main() {
  late FakeE2eeServer server;
  late FakeLaneChannel channel;
  late FakeClock clock;
  late Dev alice, bob, carol;
  late ViewerFixture srv;
  late DeviceKey srvKey;

  Future<void> sealFixes(Dev d, int n, {double lat = 10}) async {
    for (int i = 0; i < n; i++) {
      clock.t = clock.t.add(const Duration(seconds: 5));
      await d.runtime.routeFix(<String, dynamic>{
        'device_id': 'x', 'ts': clock.t.toIso8601String(), 'lat': lat + i * 0.0001, 'lon': 20.0,
        'accuracy_meters': 8, 'speed_mps': 1.0, 'battery_pct': 70, 'motion_state': '',
      });
    }
    await Future<void>.delayed(const Duration(milliseconds: 150));
  }

  Future<void> policyOn({int optOut = E2ee.optOutAllowed}) =>
      alice.lanes.publishPolicy(priv, serverAssist: true, memberOptOut: optOut);

  Future<void> bobOptsIn() async {
    await bob.lanes.refresh(priv);
    await bob.lanes.setLane(priv, E2ee.lineServer, confirmServerFingerprintHex: srvKey.fingerprint);
  }

  Future<List<ReceivedItem>> receive(Dev d) async {
    final List<ReceivedItem> out = <ReceivedItem>[];
    await d.runtime.sync.resetCursor(priv);
    await d.runtime.sync.catchUp(priv, onItem: out.add);
    return out;
  }

  setUp(() async {
    server = FakeE2eeServer()..names.addAll(<String, String>{uA: 'Alice', uB: 'Bob', uC: 'Carol'});
    clock = FakeClock(DateTime.utc(2026, 11, 6, 12));
    server.now = () => clock.t;
    server.circle(priv, members: <String>[uA, uB, uC], admin: uA);
    channel = FakeLaneChannel(server);
    alice = Dev(server, channel, uA, clock);
    bob = Dev(server, channel, uB, clock);
    carol = Dev(server, channel, uC, clock);
    for (final Dev d in <Dev>[alice, bob, carol]) {
      await d.service.registerThisDevice();
    }
    await alice.service.enableCircle(priv);
    await bob.service.syncCircleKeys(priv);
    await carol.service.syncCircleKeys(priv);
    // The Orbitly server's own key: a `server` key of Alice's account, pinned.
    srv = await ViewerFixture.create(uA);
    final String ap = await alice.service.approveLinkRequest(await alice.service.inspectViewerRequest(await srv.request(kind: 'server', name: 'Orbitly server')));
    srvKey = await srv.register(server, ap, kind: 'server', label: 'Orbitly server');
    server.serverModeEnabled = true;
    server.pinnedServerDevice = srv.deviceId;
    for (final Dev d in <Dev>[alice, bob, carol]) {
      await d.runtime.setCircles(<Circle>[circleOf(priv)]);
    }
  });

  group('registration advertises the capability', () {
    test('a current app registers with lanes2, an old app without', () async {
      final DeviceKey a = (await alice.client.myKeys()).firstWhere((DeviceKey k) => k.kind == 'device');
      expect(a.supportsLanes, isTrue);
      expect(E2eeService.capabilities, contains(kCapLanes));
      server.oldAppUsers.add('44444444-4444-4444-8444-444444444444');
      final FakeE2eeClient old = server.client('44444444-4444-4444-8444-444444444444');
      final E2eeService svc = E2eeService(api: old, vault: MemoryVault(), trust: TrustStore(MemoryTrustKv()), userIdProvider: () async => '44444444-4444-4444-8444-444444444444');
      expect((await svc.registerThisDevice()).caps, isEmpty);
    });
  });

  group('admin policy and SK custody', () {
    test('only an admin can publish; turning on makes SK gen 1 for every member phone and NOTHING for the server key', () async {
      await expectLater(bob.lanes.publishPolicy(priv, serverAssist: true), throwsA(isA<StateError>()));
      await expectLater(server.client(uB).putProcessingPolicy(priv, <String, dynamic>{}), throwsA(anything));
      await policyOn();
      final FakeCircle c = server.circles[priv]!;
      expect(c.assist, isTrue);
      expect(c.skGen, 1);
      expect(await alice.service.heldServerGens(priv), <int>[1]);
      for (final Dev d in <Dev>[bob, carol]) {
        await d.lanes.refresh(priv);
        expect(await d.service.heldServerGens(priv), <int>[1]);
        expect(E2ee.hex((await d.service.serverKey(priv, 1))!), E2ee.hex((await alice.service.serverKey(priv, 1))!));
      }
      // Nobody opted in yet: the server key has no wrap, of either line.
      expect(c.skWraps.values.any((WrapRecord w) => w.recipientDeviceId == srv.deviceId), isFalse);
      expect(c.wraps.values.any((WrapRecord w) => w.recipientDeviceId == srv.deviceId), isFalse);
      // The members' own view of the policy is the verified one.
      final CircleLanes v = await bob.lanes.refresh(priv);
      expect((v.policy.assist, v.policy.skGen, v.status), (true, 1, LaneStatus.phoneOnly));
    });

    test('an app that predates lanes blocks turning it on and is named', () async {
      server.oldAppUsers.add(uB);
      final Dev oldBob = Dev(server, channel, uB, clock);
      // Bob re-registers as an old app: replace his key entry (a fresh phone without caps).
      server.keys[uB] = <DeviceKey>[];
      await oldBob.service.registerThisDevice();
      await expectLater(policyOn(), throwsA(isA<LanesNotReady>().having((LanesNotReady e) => e.names, 'names', <String>['Bob'])));
      expect(server.circles[priv]!.assist, isFalse);
      // The server also refuses it (defence in depth).
      expect(server.circles[priv]!.skGen, 0);
    });

    test('a missing or unapproved server key blocks turning on', () async {
      server.pinnedServerDevice = null;
      await expectLater(policyOn(), throwsA(isA<StateError>()));
    });

    test('the phone key line is never wrapped to the server key, by any path', () async {
      await policyOn();
      await bobOptsIn();
      await alice.lanes.maintain(priv);
      final FakeCircle c = server.circles[priv]!;
      expect(c.skWraps.containsKey('1/${srv.deviceId}'), isTrue, reason: 'SK is wrapped to the server once a member opted in');
      expect(c.wraps.values.any((WrapRecord w) => w.recipientDeviceId == srv.deviceId), isFalse);
      expect(server.acceptedWraps.where((String w) => w.endsWith(srv.deviceId)).every((String w) => w.startsWith('server/')), isTrue);
      await alice.service.bumpEpoch(priv);
      expect(c.wraps.values.any((WrapRecord w) => w.recipientDeviceId == srv.deviceId), isFalse);
      // Recipients by line: the phone line list never holds a server key, even when one is offered.
      final CircleE2eeState st = await alice.client.circleState(priv);
      final LocalIdentity me = (await alice.service.identity())!;
      final List<DeviceKey> sl = await alice.service.serverLineRecipients(st, me);
      expect(sl.any((DeviceKey k) => k.kind == 'server'), isFalse);
      final List<DeviceKey> slSrv = await alice.service.serverLineRecipients(st, me, serverKey: st.allDevices.firstWhere((DeviceKey k) => k.kind == 'server'));
      expect(slSrv.any((DeviceKey k) => k.kind == 'server'), isTrue);
      final DeviceKey server0 = st.allDevices.firstWhere((DeviceKey k) => k.kind == 'server');
      expect(() => E2ee.checkWrapRecipient(E2ee.linePhone, server0.kind, policyOn: true, hasServerLaneMember: true), throwsA(isA<E2eeFormatException>()));
      expect(() => alice.service.confirmWrap(priv, server0), throwsA(isA<StateError>()));
    });

    test('the server line wrap to the server key is refused by the server fake too until assistance is on and a member opted in', () async {
      await policyOn();
      final CircleE2eeState st = await alice.client.circleState(priv);
      final LocalIdentity me = (await alice.service.identity())!;
      final DeviceKey s0 = st.allDevices.firstWhere((DeviceKey k) => k.kind == 'server');
      final Uint8List sk = (await alice.service.serverKey(priv, 1))!;
      await expectLater(
          alice.client.submitLineWraps(priv, E2ee.lineServer, 1, <Map<String, dynamic>>[await alice.service.wrapServerKeyTo(me, priv, 1, sk, s0)]),
          throwsA(isA<StateError>()));
    });

    test('a forged SK wrap (wrong key) is not accepted by a member phone', () async {
      await policyOn();
      final CircleE2eeState st = await alice.client.circleState(priv);
      final LocalIdentity me = (await alice.service.identity())!;
      final DeviceKey bobDev = st.allDevices.firstWhere((DeviceKey k) => k.userId == uB);
      // The server swaps Bob's wrap for a wrap of a different key, correctly signed by Alice.
      final Uint8List other = E2ee.randomBytes(32);
      final Map<String, dynamic> w = await alice.service.wrapServerKeyTo(me, priv, 1, other, bobDev);
      final FakeCircle c = server.circles[priv]!;
      c.skWraps['1/${bobDev.deviceId}'] = WrapRecord(
          line: E2ee.lineServer, epoch: 1, recipientDeviceId: bobDev.deviceId, wrapperDeviceId: me.deviceId,
          wrapperEdPub: me.edPub, blob: E2ee.unb64(w['wrapped_key']), signature: E2ee.unb64(w['signature']));
      await bob.lanes.refresh(priv);
      expect(await bob.service.heldServerGens(priv), isEmpty, reason: 'the commitment in the admin\'s signed policy does not match');
      expect(bob.service.rejectedServerWraps, 1);
    });

    test('member removal: the admin rotates SK, the removed member gets no new generation, the server only with a server member', () async {
      await policyOn();
      await bobOptsIn();
      await alice.lanes.maintain(priv);
      final FakeCircle c = server.circles[priv]!;
      final String carolDev = (await carol.service.identity())!.deviceId;
      server.removeMember(priv, uC);
      await alice.lanes.maintain(priv);
      expect(c.skGen, 2);
      expect(c.skWraps.containsKey('2/$carolDev'), isFalse);
      expect(c.skWraps.containsKey('2/${(await bob.service.identity())!.deviceId}'), isTrue);
      expect(c.skWraps.containsKey('2/${srv.deviceId}'), isTrue, reason: 'Bob is still in lane server');
      await bob.lanes.refresh(priv);
      expect(await bob.service.heldServerGens(priv), <int>[1, 2]);
      // The gen-2 key differs from gen 1 (a real rotation).
      expect(E2ee.hex((await bob.service.serverKey(priv, 2))!) == E2ee.hex((await bob.service.serverKey(priv, 1))!), isFalse);
    });

    test('a pref that names an OLDER server-key generation still delivers: server line, current gen, shown in diagnostics', () async {
      // The production case: the circle's policy moved to a newer SK generation after this member signed the pref.
      await policyOn();
      await bobOptsIn();
      await alice.lanes.maintain(priv);
      server.removeMember(priv, uC);
      await alice.lanes.maintain(priv); // rotates: SK gen 2, Bob's pref still names gen 1
      expect(server.circles[priv]!.skGen, 2);
      await bob.lanes.refresh(priv);
      expect(await bob.lanes.status(priv), LaneStatus.serverAssisted);
      expect((await bob.ownLane()).skGen, 2, reason: 'the sealer uses the policy generation, not the pref one');
      expect(await bob.store.ownPrefGen(priv), 1);
      channel.items.clear();
      await sealFixes(bob, 2);
      expect(await bob.runtime.queue.length(), 2, reason: 'fixes are sealed and queued, never skipped');
      expect(await bob.runtime.flush(), 2);
      expect(channel.items.where((WireItem i) => i.purpose == ChannelPurpose.fix).every((WireItem i) => i.line == E2ee.lineServer && i.epoch == 2), isTrue);
      final PrivateCircleDelivery c = (await bob.runtime.deliveryFacts()).circles.single;
      expect(c.laneLabel, 'server gen 2 (pref names gen 1)');
      expect(c.stalePref, isTrue);
      expect(c.queued, 0);
    });

    test('policy off: server key loses its wraps, every consent ends, nobody is silently re-opted-in later', () async {
      await policyOn();
      await bobOptsIn();
      await alice.lanes.maintain(priv);
      await alice.lanes.publishPolicy(priv, serverAssist: false);
      final FakeCircle c = server.circles[priv]!;
      expect(c.skWraps.values.any((WrapRecord w) => w.recipientDeviceId == srv.deviceId), isFalse);
      expect(c.prefs, isEmpty);
      await bob.lanes.refresh(priv);
      expect((await bob.ownLane()).line, E2ee.linePhone);
      // Turning it on again: a NEW SK generation and Bob is phone-only until he signs again.
      await policyOn();
      expect(c.skGen, 2);
      final CircleLanes v = await bob.lanes.refresh(priv);
      expect(v.members.firstWhere((MemberLaneView m) => m.userId == uB).lane, E2ee.linePhone);
      expect((await bob.ownLane()).line, E2ee.linePhone);
      // Even if the server brings the old signed server pref back, the log says it predates the "off".
      // (the pref statement was captured before switching off)
    });
  });

  group('member pref', () {
    test('opt-in needs the policy, the SK on this phone and the compared server fingerprint', () async {
      await expectLater(bob.lanes.setLane(priv, E2ee.lineServer, confirmServerFingerprintHex: srvKey.fingerprint), throwsA(isA<StateError>()));
      await policyOn();
      await bob.lanes.refresh(priv);
      await expectLater(bob.lanes.setLane(priv, E2ee.lineServer), throwsA(isA<StateError>()));
      await expectLater(bob.lanes.setLane(priv, E2ee.lineServer, confirmServerFingerprintHex: '00' * 32), throwsA(isA<StateError>()));
      expect(server.circles[priv]!.prefs, isEmpty);
      await bob.lanes.setLane(priv, E2ee.lineServer, confirmServerFingerprintHex: srvKey.fingerprint.toUpperCase());
      expect((await bob.ownLane()), isA<LaneChoice>().having((LaneChoice c) => c.line, 'line', E2ee.lineServer).having((LaneChoice c) => c.skGen, 'gen', 1));
      expect(await bob.lanes.status(priv), LaneStatus.serverAssisted);
    });

    test('nobody can write another member\'s pref, and a pref signed by the wrong person does not count', () async {
      await policyOn();
      // The fake server mirrors the real route: own pref only.
      final Dev eve = alice;
      final LocalIdentity me = (await eve.service.identity())!;
      final Uint8List nonce = E2ee.randomBytes(16);
      final Uint8List msg = E2ee.processingPrefMessage(priv, uB, E2ee.linePhone, 0, E2ee.zeroUuid, Uint8List(32), nonce);
      final PrefStatement forged = PrefStatement(userId: uB, lane: E2ee.linePhone, skGen: 0, serverDeviceId: E2ee.zeroUuid, nonce: nonce, approverDeviceId: me.deviceId, signature: await E2ee.sign(me.edSeed, msg));
      // Alice's PUT is for Alice: the body's user is ignored.
      await eve.client.putProcessingPref(priv, <String, dynamic>{
        ...forged.toJson(),
        'log_signature': E2ee.b64(await E2ee.sign(me.edSeed, E2ee.logActionMessage(E2ee.actProcessingPref, uA, me.deviceId, circleId: priv, ref: await E2ee.processingRef(E2ee.processingPrefMessage(priv, uA, E2ee.linePhone, 0, E2ee.zeroUuid, Uint8List(32), nonce))))),
        'signature': E2ee.b64(await E2ee.sign(me.edSeed, E2ee.processingPrefMessage(priv, uA, E2ee.linePhone, 0, E2ee.zeroUuid, Uint8List(32), nonce))),
      });
      expect(server.circles[priv]!.prefs.containsKey(uB), isFalse);
      // A hostile server plants a server-lane pref for Bob signed by Alice's key, with a matching forged log entry.
      await bobOptsIn(); // Bob is server-lane legitimately; now Carol is "forged in"
      final FakeCircle c = server.circles[priv]!;
      final Uint8List n2 = E2ee.randomBytes(16);
      final Uint8List m2 = E2ee.processingPrefMessage(priv, uC, E2ee.lineServer, 1, srv.deviceId, E2ee.unhex(srvKey.fingerprint), n2);
      final Uint8List sig2 = await E2ee.sign(me.edSeed, m2);
      c.prefs[uC] = PrefStatement(userId: uC, lane: E2ee.lineServer, skGen: 1, serverDeviceId: srv.deviceId, nonce: n2, approverDeviceId: me.deviceId, signature: sig2);
      await server.appendLog(E2ee.actProcessingPref, uC, me.deviceId, me.edPub, circleId: priv, subjectId: srv.deviceId, epoch: 1, ref: await E2ee.processingRef(m2),
          sig: await E2ee.sign(me.edSeed, E2ee.logActionMessage(E2ee.actProcessingPref, uC, me.deviceId, circleId: priv, subjectId: srv.deviceId, epoch: 1, ref: await E2ee.processingRef(m2))));
      final CircleLanes v = await carol.lanes.refresh(priv);
      expect(v.members.firstWhere((MemberLaneView m) => m.userId == uC).lane, E2ee.linePhone, reason: 'the actor is not Carol\'s own phone key');
      expect(v.members.firstWhere((MemberLaneView m) => m.userId == uB).lane, E2ee.lineServer);
      expect((await carol.ownLane()).line, E2ee.linePhone);
    });

    test('claimed member rows (server flags) never decide a lane', () async {
      await policyOn();
      // The server CLAIMS Bob is server-assisted, with no signed pref anywhere.
      final FakeCircle c = server.circles[priv]!;
      expect(c.prefs, isEmpty);
      final ProcessingServerState claimed = ProcessingServerState.fromJson(<String, dynamic>{
        'server_assist': true, 'members': <Map<String, dynamic>>[<String, dynamic>{'user_id': uB, 'lane': 'server', 'since': clock.t.toIso8601String()}],
      });
      expect(claimed.claimedMembers.single.lane, E2ee.lineServer);
      final CircleLanes v = await alice.lanes.refresh(priv);
      expect(v.members.every((MemberLaneView m) => m.lane == E2ee.linePhone && !m.verified), isTrue);
    });

    test('a replayed OLD server pref cannot undo an opt-out: the newest log entry wins', () async {
      await policyOn();
      await bobOptsIn();
      final PrefStatement oldServerPref = server.circles[priv]!.prefs[uB]!;
      await bob.lanes.setLane(priv, E2ee.linePhone);
      expect((await bob.ownLane()).line, E2ee.linePhone);
      // A malicious server (or replay) serves the old signed server pref again.
      server.circles[priv]!.prefs[uB] = oldServerPref;
      await bob.lanes.refresh(priv);
      await alice.lanes.refresh(priv);
      expect((await bob.ownLane()).line, E2ee.linePhone);
      expect((await alice.lanes.members(priv)).firstWhere((MemberLaneView m) => m.userId == uB).lane, E2ee.linePhone);
    });
  });

  group('opt-out never lets an SK item upload', () {
    test('queued SK items become phone-line items at the moment of the opt-out; later uploads carry only the phone line', () async {
      await policyOn();
      await bobOptsIn();
      channel.offline = true; // nothing can be uploaded yet
      await sealFixes(bob, 3);
      List<WireItem> q = await bob.runtime.queue.peek();
      expect(q.where((WireItem i) => i.purpose == 'fix' && i.line == E2ee.lineServer), hasLength(3));
      await bob.lanes.setLane(priv, E2ee.linePhone); // opt-out while offline: effective at once, locally
      q = await bob.runtime.queue.peek();
      expect(q.any((WireItem i) => i.line == E2ee.lineServer), isFalse, reason: 'purged / re-sealed before any network call');
      channel.offline = false;
      await sealFixes(bob, 2);
      await bob.runtime.flush();
      final int optOutAt = channel.uploaded.length;
      expect(channel.uploaded.every((String u) => u.endsWith('/0')), isTrue, reason: 'no server-line item was ever POSTed after the opt-out: ${channel.uploaded}');
      expect(channel.items.where((WireItem i) => i.line == E2ee.lineServer), isEmpty);
      expect(optOutAt, greaterThan(0));
      // Alice reads all five, all phone-only.
      await alice.lanes.refresh(priv);
      final List<ReceivedItem> got = (await receive(alice)).where((ReceivedItem r) => r.purpose == 'fix').toList();
      expect(got, hasLength(5));
      expect(got.every((ReceivedItem r) => r.badge == ProcessingBadge.phoneOnly), isTrue);
    });

    test('the opt-out holds even if publishing the pref fails (offline): the phone lane is already in force', () async {
      await policyOn();
      await bobOptsIn();
      bob.client.failPrefPut = true;
      await sealFixes(bob, 2);
      await expectLater(bob.lanes.setLane(priv, E2ee.linePhone), throwsA(isA<StateError>()));
      expect((await bob.ownLane()).line, E2ee.linePhone);
      // A refresh that still shows the old server pref (the new one never reached the server) does not undo it.
      await bob.lanes.refresh(priv);
      expect((await bob.ownLane()).line, E2ee.linePhone);
      await sealFixes(bob, 2);
      await bob.runtime.flush();
      expect(channel.uploaded.where((String u) => u.endsWith('/1')), isEmpty);
      // When the network is back, publishing works and the log catches up.
      bob.client.failPrefPut = false;
      await bob.lanes.setLane(priv, E2ee.linePhone);
      await bob.lanes.refresh(priv);
      expect(await bob.store.pendingPhoneRef(priv), isNull, reason: 'the pending marker clears once the log shows the entry');
    });

    test('a pref flip while fixes are being sealed: whatever is queued is phone-line after the flip', () async {
      await policyOn();
      await bobOptsIn();
      channel.offline = true;
      await sealFixes(bob, 2);
      final Future<void> flip = bob.lanes.setLane(priv, E2ee.linePhone);
      await sealFixes(bob, 2); // sealed concurrently with the flip
      await flip;
      channel.offline = false;
      await bob.runtime.flush();
      expect(channel.uploaded.where((String u) => u.endsWith('/1')), isEmpty);
    });

    test('policy turned off by the admin: SK items still queued are re-sealed, none uploaded', () async {
      await policyOn();
      await bobOptsIn();
      channel.offline = true;
      await sealFixes(bob, 2);
      await alice.lanes.publishPolicy(priv, serverAssist: false);
      await bob.lanes.refresh(priv);
      channel.offline = false;
      await bob.runtime.flush();
      expect(channel.uploaded.where((String u) => u.endsWith('/1')), isEmpty);
      expect(channel.items.where((WireItem i) => i.line == E2ee.lineServer), isEmpty);
    });

    test('a key log that fails verification drops the phone to the phone lane and purges SK items', () async {
      await policyOn();
      await bobOptsIn();
      channel.offline = true;
      await sealFixes(bob, 2);
      // The server shows a log that does not extend what Bob pinned (a rewrite).
      await bob.service.trust.pinHead(LogHead(99, Uint8List(32)..fillRange(0, 32, 7)));
      final CircleLanes v = await bob.lanes.refresh(priv);
      expect(v.status, LaneStatus.verificationFailed);
      expect((await bob.ownLane()).line, E2ee.linePhone);
      expect((await bob.runtime.queue.peek()).any((WireItem i) => i.line == E2ee.lineServer), isFalse);
    });
  });

  group('end to end: lanes, sidecar view and badges', () {
    test('the server key can read server-line items only; phone-line items stay unreadable to it', () async {
      await policyOn();
      await bobOptsIn();
      await alice.lanes.maintain(priv);
      await sealFixes(bob, 2, lat: 11);
      await carol.lanes.refresh(priv); // Carol never opts in: phone lane
      await sealFixes(carol, 2, lat: 33);
      await bob.runtime.flush();
      await carol.runtime.flush();
      // The sidecar: opens its SK wrap with its own X25519 key, checks the commitment from the admin's signed policy.
      final WrapRecord wrap = server.circles[priv]!.skWraps['1/${srv.deviceId}']!;
      final PolicyStatement pol = server.circles[priv]!.policy!;
      final Uint8List sk = await E2ee.openWrapLine(priv, srv.deviceId, srv.xSecret, srv.xPub,
          LineWrap(line: wrap.line, gen: wrap.epoch, recipientDeviceId: wrap.recipientDeviceId, wrapperDeviceId: wrap.wrapperDeviceId, wrapperEdPub: wrap.wrapperEdPub, blob: wrap.blob, signature: wrap.signature),
          E2ee.lineServer, 1, pol.commitment);
      final DeviceKey bobDev = (await bob.client.myKeys()).firstWhere((DeviceKey k) => k.kind == 'device');
      final DeviceKey carolDev = (await carol.client.myKeys()).single;
      int readable = 0, unreadable = 0;
      for (final WireItem i in channel.items.where((WireItem x) => x.purpose == 'fix')) {
        if (i.line == E2ee.lineServer) {
          expect(i.deviceId, bobDev.deviceId);
          final Uint8List padded = await E2ee.openV2(sk, priv, E2ee.lineServer, i.deviceId, 'fix', i.ciphertext);
          expect(padded, isNotEmpty);
          readable++;
        } else {
          expect(i.deviceId, carolDev.deviceId);
          // Not even under SK: the server has no CK, and v1 payloads need it.
          await expectLater(E2ee.open(sk, priv, i.deviceId, 'fix', i.ciphertext), throwsA(isA<E2eeAuthException>()));
          unreadable++;
        }
      }
      expect((readable, unreadable), (2, 2));
      // Alice sees both with badges derived on her phone.
      await alice.lanes.refresh(priv);
      final List<ReceivedItem> got = (await receive(alice)).where((ReceivedItem r) => r.purpose == 'fix').toList();
      expect(got.where((ReceivedItem r) => r.userId == uB).every((ReceivedItem r) => r.badge == ProcessingBadge.serverAssisted), isTrue);
      expect(got.where((ReceivedItem r) => r.userId == uC).every((ReceivedItem r) => r.badge == ProcessingBadge.phoneOnly), isTrue);
    });

    test('a member sealing under SK without a pref (hostile member) is accepted but FLAGGED', () async {
      await policyOn();
      await carol.lanes.refresh(priv); // Carol holds SK, her signed lane is phone (none)
      // Carol's phone is patched to seal under SK anyway.
      final ChannelSealer rogue = ChannelSealer(
          keys: carol.runtime.keys, kv: MemoryKv(), clock: clock,
          lanes: _AlwaysServer(1), serverKeys: carol.runtime.keys as ServerKeys);
      final LocalIdentity me = (await carol.service.identity())!;
      final WireItem it = await rogue.seal(SenderIdentity(me.deviceId, me.edSeed, me.userId), priv, 'fix', <String, dynamic>{'lat': 1.0, 'lon': 2.0});
      expect(it.line, E2ee.lineServer);
      await alice.lanes.refresh(priv);
      final ReceivedItem r = await alice.runtime.receiver.process(it);
      expect(r.badge, ProcessingBadge.unverified);
    });

    test('a lying server: wrong key_line is refused, a missing one is fine (the header decides)', () async {
      await policyOn();
      await bobOptsIn();
      await sealFixes(bob, 1);
      await bob.runtime.flush();
      await alice.lanes.refresh(priv);
      channel.lieLine = E2ee.linePhone;
      expect((await receive(alice)).where((ReceivedItem r) => r.purpose == 'fix'), isEmpty);
      channel.lieLine = null;
      channel.omitLine = true;
      expect((await receive(alice)).where((ReceivedItem r) => r.purpose == 'fix').single.badge, ProcessingBadge.serverAssisted);
    });

    test('old app simulation: a v1 sealer in an upgraded circle is read correctly, labelled phone-only and never reaches the server line', () async {
      await policyOn();
      await bobOptsIn();
      // Bob's OTHER phone runs an old app: no lanes, no SK, plain v1 sealer.
      final ChannelSealer old = ChannelSealer(keys: bob.runtime.keys, kv: MemoryKv(), clock: clock);
      final LocalIdentity me = (await bob.service.identity())!;
      final WireItem it = await old.seal(SenderIdentity(me.deviceId, me.edSeed, me.userId), priv, 'fix', <String, dynamic>{'lat': 5.0, 'lon': 6.0});
      expect(it.line, E2ee.linePhone);
      expect(it.toUpload().containsKey(LanesFields.keyLine), isFalse);
      await alice.lanes.refresh(priv);
      expect((await alice.runtime.receiver.process(it)).badge, ProcessingBadge.phoneOnly);
      // And an old receiver (v1 only: E2ee.open / payloadEpoch) cannot read a server-line item. It fails closed.
      await sealFixes(bob, 1);
      final WireItem srvItem = (await bob.runtime.queue.peek()).firstWhere((WireItem i) => i.line == E2ee.lineServer);
      expect(() => E2ee.payloadEpoch(srvItem.ciphertext), throwsA(isA<E2eeFormatException>()));
      await expectLater(E2ee.open((await bob.service.circleKey(priv, 1))!, priv, srvItem.deviceId, 'fix', srvItem.ciphertext), throwsA(isA<E2eeFormatException>()));
    });
  });

  group('SK must never equal a circle key (security review M1)', () {
    /// A hostile admin phone publishes a policy whose SK is [skBytes] (a CK), wrapped to Bob and Carol.
    Future<void> hostilePolicy(Uint8List skBytes) async {
      final LocalIdentity me = (await alice.service.identity())!;
      final CircleE2eeState st = await alice.client.circleState(priv);
      final Uint8List commit = await E2ee.keyCommitmentLine(skBytes, priv, E2ee.lineServer, 1);
      final Uint8List nonce = E2ee.randomBytes(16);
      final Uint8List msg = E2ee.processingPolicyMessage(priv, uA, true, E2ee.linePhone, E2ee.optOutAllowed, 1, commit, nonce);
      final Uint8List ref = await E2ee.processingRef(msg);
      final List<Map<String, dynamic>> wraps = <Map<String, dynamic>>[];
      for (final DeviceKey k in st.allDevices.where((DeviceKey d) => d.kind == 'device')) {
        final Uint8List blob = await E2ee.wrap(skBytes, k.xPub, E2ee.wrapAadLine(priv, E2ee.lineServer, 1, k.deviceId, me.deviceId));
        wraps.add(<String, dynamic>{
          'recipient_device_id': k.deviceId, 'wrapper_device_id': me.deviceId, 'wrapped_key': E2ee.b64(blob),
          'signature': E2ee.b64(await E2ee.sign(me.edSeed, E2ee.wrapSigMessageLine(priv, E2ee.lineServer, 1, k.deviceId, me.deviceId, blob))),
        });
      }
      await alice.client.putProcessingPolicy(priv, <String, dynamic>{
        ...PolicyStatement(serverAssist: true, defaultForNew: E2ee.linePhone, memberOptOut: E2ee.optOutAllowed, skGen: 1, commitment: commit, nonce: nonce,
                adminUserId: uA, actorDeviceId: me.deviceId, signature: await E2ee.sign(me.edSeed, msg))
            .toJson(),
        'log_signature': E2ee.b64(await E2ee.sign(me.edSeed, E2ee.logActionMessage(E2ee.actProcessingPolicy, uA, me.deviceId, circleId: priv, epoch: 1, ref: ref))),
        'wraps': wraps,
      });
    }

    test('SK == the current CK: refused on unwrap, never stored, alarm raised and recorded', () async {
      await hostilePolicy((await alice.service.circleKey(priv, 1))!);
      for (final Dev d in <Dev>[bob, carol]) {
        await d.lanes.refresh(priv);
        expect(await d.service.heldServerGens(priv), isEmpty);
        expect(d.service.rejectedServerWraps, 1);
        expect(d.service.laneAlarms.single.kind, AlarmKind.serverKeyIsCircleKey);
        expect(d.service.laneAlarms.single.severe, isTrue);
        expect(await d.service.trust.kv.get('alarm:skck:$priv'), isNotNull);
        expect((await d.ownLane()).line, E2ee.linePhone);
      }
    });

    test('SK == an OLDER CK epoch is refused too', () async {
      await alice.service.bumpEpoch(priv);
      await bob.service.syncCircleKeys(priv);
      await carol.service.syncCircleKeys(priv);
      await hostilePolicy((await alice.service.circleKey(priv, 1))!);
      await bob.lanes.refresh(priv);
      expect(await bob.service.heldServerGens(priv), isEmpty);
      expect(bob.service.laneAlarms, hasLength(1));
    });

    test('equal commitment is caught even on a phone that does not hold that epoch key', () async {
      final Uint8List ck1 = (await alice.service.circleKey(priv, 1))!;
      final E2eeService fresh = E2eeService(api: server.client(uC), vault: MemoryVault(), trust: TrustStore(MemoryTrustKv()), userIdProvider: () async => uC);
      expect(await fresh.heldEpochs(priv), isEmpty);
      expect(await fresh.serverKeyEqualsCircleKey(priv, ck1), isTrue, reason: 'the signed epoch commitment matches');
      expect(await fresh.serverKeyEqualsCircleKey(priv, E2ee.randomBytes(32)), isFalse);
    });

    test('generation asserts inequality; a colliding generator is refused; a CK can never be wrapped under the server line', () async {
      final Uint8List ck1 = (await alice.service.circleKey(priv, 1))!;
      await expectLater(alice.service.generateServerKey(priv, random: () => Uint8List.fromList(ck1)), throwsA(isA<StateError>()));
      expect(alice.service.laneAlarms, hasLength(1));
      final Uint8List ok = await alice.service.generateServerKey(priv);
      expect(ok, hasLength(32));
      final LocalIdentity me = (await alice.service.identity())!;
      final CircleE2eeState st = await alice.client.circleState(priv);
      final DeviceKey srvDev = st.allDevices.firstWhere((DeviceKey k) => k.kind == 'server');
      await expectLater(alice.service.wrapServerKeyTo(me, priv, 1, ck1, srvDev), throwsA(isA<StateError>()));
      await expectLater(alice.service.storeServerKey(priv, 1, ck1), throwsA(isA<StateError>()));
      expect(await alice.service.heldServerGens(priv), isEmpty);
    });

    test('an honest policy is unaffected and its SK differs from every CK epoch', () async {
      await policyOn();
      final Uint8List sk = (await alice.service.serverKey(priv, 1))!;
      expect(await alice.service.serverKeyEqualsCircleKey(priv, sk), isFalse);
      expect(alice.service.laneAlarms, isEmpty);
    });
  });

  group('member_opt_out: required_server', () {
    test('a member whose phone has not signed yet keeps sending on the phone line; then the phone signs by itself', () async {
      await policyOn(optOut: E2ee.optOutRequiredServer);
      final CircleLanes v = await bob.lanes.refresh(priv);
      expect((v.status, v.policy.memberOptOut), (LaneStatus.serverPending, E2ee.optOutRequiredServer));
      // Nothing is held back: the position is sealed on the phone line (never plaintext, never nothing).
      await sealFixes(bob, 3);
      final List<WireItem> q = (await bob.runtime.queue.peek()).where((WireItem i) => i.purpose == 'fix').toList();
      expect(q.length, 3);
      expect(q.every((WireItem i) => i.line == E2ee.linePhone), isTrue);
      // The member's OWN phone signs the lane; nobody asks and the admin does not do it for them.
      expect(await bob.lanes.signRequiredLaneIfDue(priv), AutoApplyOutcome.applied);
      expect(await bob.lanes.status(priv), LaneStatus.serverAssisted);
      final String bobDevice = (await bob.service.identity())!.deviceId;
      expect(server.log.where((Map<String, dynamic> e) => e['action'] == E2ee.actProcessingPref && e['user'] == uB && e['actor'] == bobDevice).length, 1);
      await sealFixes(bob, 1);
      expect((await bob.runtime.queue.peek()).where((WireItem i) => i.purpose == 'fix' && i.line == E2ee.lineServer), isNotEmpty);
    });

    test('allowed (the default) leaves a member without a pref simply phone-only', () async {
      await policyOn();
      final CircleLanes v = await bob.lanes.refresh(priv);
      expect(v.status, LaneStatus.phoneOnly);
      await sealFixes(bob, 1);
      expect((await bob.runtime.queue.peek()).where((WireItem i) => i.purpose == 'fix').single.line, E2ee.linePhone);
    });

    test('switching to required_server needs assistance on (the signed statement itself forbids otherwise)', () async {
      await expectLater(alice.lanes.publishPolicy(priv, serverAssist: false, memberOptOut: E2ee.optOutRequiredServer), throwsA(isA<ArgumentError>()));
    });
  });

  group('forged policy', () {
    test('a policy signed by a non-admin (planted by a hostile server) does not switch anything on', () async {
      final FakeCircle c = server.circles[priv]!;
      final LocalIdentity b = (await bob.service.identity())!;
      final Uint8List key = E2ee.randomBytes(32);
      final Uint8List commit = await E2ee.keyCommitmentLine(key, priv, E2ee.lineServer, 1);
      final Uint8List nonce = E2ee.randomBytes(16);
      final Uint8List msg = E2ee.processingPolicyMessage(priv, uB, true, E2ee.lineServer, E2ee.optOutRequiredServer, 1, commit, nonce);
      final PolicyStatement forged = PolicyStatement(
          serverAssist: true, defaultForNew: E2ee.lineServer, memberOptOut: E2ee.optOutRequiredServer, skGen: 1, commitment: commit,
          nonce: nonce, adminUserId: uB, actorDeviceId: b.deviceId, signature: await E2ee.sign(b.edSeed, msg));
      c.policy = forged;
      c.assist = true;
      c.skGen = 1;
      final Uint8List ref = await E2ee.processingRef(msg);
      await server.appendLog(E2ee.actProcessingPolicy, uB, b.deviceId, b.edPub, circleId: priv, epoch: 1, ref: ref,
          sig: await E2ee.sign(b.edSeed, E2ee.logActionMessage(E2ee.actProcessingPolicy, uB, b.deviceId, circleId: priv, epoch: 1, ref: ref)));
      for (final Dev d in <Dev>[alice, bob, carol]) {
        final CircleLanes v = await d.lanes.refresh(priv);
        expect(v.policy.assist, isFalse);
        expect((await d.ownLane()).line, E2ee.linePhone);
        expect(v.status, LaneStatus.phoneOnly, reason: 'a forged required_server must not even pause sharing');
      }
    });

    test('the server hiding the newest policy (showing an older one) cannot keep assistance on', () async {
      await policyOn();
      final FakeCircle c = server.circles[priv]!;
      final PolicyStatement onStmt = c.policy!;
      await alice.lanes.publishPolicy(priv, serverAssist: false);
      c.policy = onStmt; // replay the earlier "on" statement
      c.policyHistory.clear();
      final CircleLanes v = await bob.lanes.refresh(priv);
      expect(v.policy.assist, isFalse, reason: 'the newest log entry is the off entry; its statement was withheld');
    });
  });
}

class _AlwaysServer implements LaneSource {
  _AlwaysServer(this.gen);
  final int gen;
  @override
  Future<LaneChoice> ownLane(String circleId) async => LaneChoice(E2ee.lineServer, gen);
  @override
  Future<bool> serverLaneAllowed(String circleId) async => true;
  @override
  Future<List<PrefEntry>> prefsOf(String circleId, String userId) async => <PrefEntry>[];
  @override
  Future<bool> serverAssistOn(String circleId) async => true;
}
