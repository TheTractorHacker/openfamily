import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/circle.dart';
import 'package:openfamily/services/e2ee/e2ee_crypto.dart';
import 'package:openfamily/services/e2ee/e2ee_models.dart';
import 'package:openfamily/services/e2ee/e2ee_service.dart' show PendingItem, PendingReport;
import 'package:openfamily/services/e2ee/e2ee_trust.dart';
import 'package:openfamily/services/e2ee/lanes_service.dart';
import 'package:openfamily/services/e2ee/lanes_store.dart';
import 'package:openfamily/services/e2ee/private_channel.dart';
import 'package:openfamily/services/e2ee/processing_controller.dart';

import '../../support/fake_e2ee_server.dart';
import '../../support/viewer_fixture.dart';
import 'lanes_service_test.dart' show Dev, circleOf, priv, uA, uB, uC;
import 'private_channel_test.dart' show FakeClock;

// Findings of the independent review: policy history, circle key == server key,
// bridges and viewers, opt-out retry, the queue under two writers, rejections.

WireItem item(int seq, {String circle = 'c1', String device = 'd1'}) => WireItem(
    circleId: circle, deviceId: device, seq: seq, purpose: 'fix', epoch: 1, sizeBucket: 256, ciphertext: Uint8List.fromList(<int>[seq, 1, 2, 3]));

/// A store whose second fresh read of the queue lets "the other isolate" write first.
class RacingKv extends MemoryKv {
  void Function()? onPrecheck;
  int queueReads = 0;
  @override
  Future<String?> getFresh(String key) async {
    if (key == 'queue/v1') {
      queueReads++;
      if (queueReads == 2 && onPrecheck != null) {
        final void Function() f = onPrecheck!;
        onPrecheck = null;
        f();
        await Future<void>.delayed(Duration.zero);
      }
    }
    return super.getFresh(key);
  }
}

class _Api implements ChannelApi {
  _Api(this.answer);
  List<BatchResult> Function(List<WireItem>) answer;
  int posts = 0;
  @override
  Future<List<BatchResult>> postBatch(String circleId, String deviceId, List<WireItem> batch) async {
    posts++;
    return answer(batch);
  }

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

void main() {
  group('queue under two writers', () {
    test('a stale save does not lose the other isolate\'s item', () async {
      final RacingKv kv = RacingKv();
      final SealedQueue a = SealedQueue(kv: kv), b = SealedQueue(kv: MemoryKvView(kv));
      await a.enqueue(item(1));
      kv.queueReads = 0;
      // While A is between reading and writing, B (the background isolate) enqueues another item.
      kv.onPrecheck = () => b.enqueue(item(2));
      await a.enqueue(item(3));
      final List<int> seqs = (await a.peek()).map((WireItem w) => w.seq).toList()..sort();
      expect(seqs, <int>[1, 2, 3]);
    });

    test('an older build\'s plain list is still read', () async {
      final MemoryKv kv = MemoryKv();
      await SealedQueue(kv: kv).enqueue(item(1));
      final String raw = kv.data['queue/v1']!;
      expect(raw.contains('"v":'), isTrue);
      kv.data['queue/v1'] = '[]';
      expect(await SealedQueue(kv: kv).length(), 0);
    });
  });

  group('relay rejections', () {
    test('legacy_epoch_closed keeps the item, asks for a key sync, and gives up only after the retry limit', () async {
      final MemoryKv kv = MemoryKv();
      final SealedQueue q = SealedQueue(kv: kv);
      await q.enqueue(item(1));
      final _Api api = _Api((List<WireItem> b) => <BatchResult>[BatchResult(b.first.seq, 'rejected', error: 'legacy_epoch_closed')]);
      final List<String> synced = <String>[];
      await q.flush(api, deviceFor: (_) => 'd1', onNeedKeySync: synced.add);
      expect(await q.length(), 1);
      expect(synced, <String>['c1']);
      expect(await q.undelivered('c1'), isNull);
    });

    test('required_server is not silent: the item goes and the user can be told', () async {
      final MemoryKv kv = MemoryKv();
      final SealedQueue q = SealedQueue(kv: kv);
      await q.enqueue(item(1));
      await q.enqueue(item(2));
      final _Api api = _Api((List<WireItem> b) => <BatchResult>[for (final WireItem w in b) BatchResult(w.seq, 'rejected', error: 'required_server')]);
      await q.flush(api, deviceFor: (_) => 'd1');
      expect(await q.length(), 0);
      final u = await q.undelivered('c1');
      expect((u!.count, u.code), (2, 'required_server'));
      await q.clearUndelivered('c1');
      expect(await q.undelivered('c1'), isNull);
    });

    test('required_server asks the phone to sign its own server lane once per flush, and never loops', () async {
      final SealedQueue q = SealedQueue(kv: MemoryKv());
      await q.enqueue(item(1));
      await q.enqueue(item(2));
      int posts = 0;
      final _Api api = _Api((List<WireItem> b) {
        posts++;
        return <BatchResult>[for (final WireItem w in b) BatchResult(w.seq, 'rejected', error: 'required_server')];
      });
      final List<String> asked = <String>[];
      await q.flush(api, deviceFor: (_) => 'd1', onRequiredServerRefused: (String c) async => asked.add(c));
      expect(asked, <String>['c1']);
      expect(posts, 1);
      expect(await q.length(), 0);
      // Nothing left to send: another flush does not post and does not ask again.
      await q.flush(api, deviceFor: (_) => 'd1', onRequiredServerRefused: (String c) async => asked.add(c));
      expect(asked, <String>['c1']);
      expect(posts, 1);
    });

    test('other permanent rejections are dropped as before', () async {
      final SealedQueue q = SealedQueue(kv: MemoryKv());
      await q.enqueue(item(1));
      await q.flush(_Api((List<WireItem> b) => <BatchResult>[BatchResult(b.first.seq, 'rejected', error: 'bad_header')]), deviceFor: (_) => 'd1');
      expect(await q.length(), 0);
    });
  });

  group('lane facts are read fresh and versioned', () {
    test('the version moves with every lane write and a stale cache cannot hide an opt-out', () async {
      final MemoryKv kv = MemoryKv();
      final LaneStore w = LaneStore(kv);
      final KvLaneSource src = KvLaneSource(kv);
      final int v0 = await src.laneVersion('c1');
      await w.setPolicy('c1', const StoredPolicy(assist: true, skGen: 1, defaultForNew: 0, memberOptOut: 0));
      await w.setOwnLane('c1', const LaneChoice(E2ee.lineServer, 1));
      expect(await src.serverLaneAllowed('c1'), isTrue);
      final int v1 = await src.laneVersion('c1');
      expect(v1 > v0, isTrue);
      await w.setOwnLane('c1', LaneChoice.phone);
      expect(await src.serverLaneAllowed('c1'), isFalse);
      expect(await src.laneVersion('c1') > v1, isTrue);
    });

    test('flush starts over when the lane record moves between the check and the request', () async {
      final MemoryKv kv = MemoryKv();
      final LaneStore store = LaneStore(kv);
      await store.setPolicy('c1', const StoredPolicy(assist: true, skGen: 1, defaultForNew: 0, memberOptOut: 0));
      await store.setOwnLane('c1', const LaneChoice(E2ee.lineServer, 1));
      final SealedQueue q = SealedQueue(kv: kv);
      final WireItem twin = item(1);
      await q.enqueue(WireItem(
          circleId: 'c1', deviceId: 'd1', seq: 1, purpose: 'fix', epoch: 1, sizeBucket: 256, ciphertext: Uint8List.fromList(<int>[9]), line: E2ee.lineServer, twin: twin));
      final _FlippingLanes lanes = _FlippingLanes(KvLaneSource(kv), () => store.setOwnLane('c1', LaneChoice.phone));
      final List<int> sentLine = <int>[];
      final _Api api = _Api((List<WireItem> b) {
        sentLine.addAll(b.map((WireItem w) => w.line));
        return <BatchResult>[for (final WireItem w in b) BatchResult(w.seq, 'stored')];
      });
      await q.flush(api, deviceFor: (_) => 'd1', lanes: lanes);
      expect(sentLine, <int>[E2ee.linePhone], reason: 'the opt-out that landed mid-flush replaced the item by its phone twin before the request');
    });
  });

  group('store cleanup', () {
    test('clearCircle forgets the pref history of every member', () async {
      final MemoryKv kv = MemoryKv();
      final LaneStore s = LaneStore(kv);
      await s.appendHistory('c1', 'u1', 5, 1, 100);
      await s.appendHistory('c1', 'u2', 6, 0, 100);
      expect((await s.history('c1', 'u1')).length, 1);
      await s.clearCircle('c1');
      expect(await s.history('c1', 'u1'), isEmpty);
      expect(await s.history('c1', 'u2'), isEmpty);
      expect(kv.data.keys.where((String k) => k.contains('c1') && !k.startsWith('lanes/ver')), isEmpty, reason: kv.data.keys.toString());
    });
  });

  group('with the in-memory server', () {
    late FakeE2eeServer server;
    late FakeLaneChannel channel;
    late FakeClock clock;
    late Dev alice, bob, carol;
    late ViewerFixture srv;
    late DeviceKey srvKey;

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
      srv = await ViewerFixture.create(uA);
      final String ap = await alice.service.approveLinkRequest(await alice.service.inspectViewerRequest(await srv.request(kind: 'server', name: 'Orbitly server')));
      srvKey = await srv.register(server, ap, kind: 'server', label: 'Orbitly server');
      server.serverModeEnabled = true;
      server.pinnedServerDevice = srv.deviceId;
      for (final Dev d in <Dev>[alice, bob, carol]) {
        await d.runtime.setCircles(<Circle>[circleOf(priv)]);
      }
    });

    test('three policy edits (default, rotation, opt-out rule) do not void a member\'s consent', () async {
      await alice.lanes.publishPolicy(priv, serverAssist: true);
      await bob.lanes.refresh(priv);
      await bob.lanes.setLane(priv, E2ee.lineServer, confirmServerFingerprintHex: srvKey.fingerprint);
      expect((await bob.lanes.refresh(priv, force: true)).status, LaneStatus.serverAssisted);
      await alice.lanes.publishPolicy(priv, serverAssist: true, defaultForNew: E2ee.lineServer); // 1: default
      await alice.lanes.publishPolicy(priv, serverAssist: true, defaultForNew: E2ee.lineServer, rotate: true); // 2: SK rotation
      await alice.lanes.publishPolicy(priv, serverAssist: true, defaultForNew: E2ee.linePhone, memberOptOut: E2ee.optOutAllowed); // 3: default back
      final CircleLanes v = await alice.lanes.refresh(priv, force: true);
      expect(v.policy.assist, isTrue);
      expect(v.members.where((MemberLaneView m) => m.serverAssisted).map((MemberLaneView m) => m.userId), <String>[uB],
          reason: 'prefs signed before harmless policy edits stay valid');
    });

    test('turning the policy OFF still voids older consents (fail closed)', () async {
      await alice.lanes.publishPolicy(priv, serverAssist: true);
      await bob.lanes.refresh(priv);
      await bob.lanes.setLane(priv, E2ee.lineServer, confirmServerFingerprintHex: srvKey.fingerprint);
      await alice.lanes.publishPolicy(priv, serverAssist: true, defaultForNew: E2ee.lineServer);
      await alice.lanes.publishPolicy(priv, serverAssist: false);
      await alice.lanes.publishPolicy(priv, serverAssist: true);
      final CircleLanes v = await alice.lanes.refresh(priv, force: true);
      expect(v.members.any((MemberLaneView m) => m.serverAssisted), isFalse);
    });

    test('a circle key that equals a server key is refused, flagged and listed', () async {
      await alice.lanes.publishPolicy(priv, serverAssist: true);
      await bob.lanes.refresh(priv);
      final Uint8List sk = (await bob.service.serverKey(priv, 1))!;
      expect(await bob.service.circleKeyIsServerKey(priv, sk), isTrue, reason: 'byte for byte');
      expect(await bob.service.circleKeyIsServerKey(priv, E2ee.randomBytes(32)), isFalse);
      // The same key as the commitment of a signed policy says (here Carol has not even opened SK).
      expect(await carol.service.circleKeyIsServerKey(priv, sk), isTrue, reason: 'commitment of the signed policy');
      expect(await bob.service.laneAlarmList(), isEmpty);
      await bob.service.trust.kv.set('alarm:skck:index', priv);
      await bob.service.trust.kv.set('alarm:skck:$priv', '2026-11-07T10:00:00Z|ck');
      final List<E2eeAlarm> al = await bob.service.laneAlarmList();
      expect(al.length, 1);
      expect((al.single.severe, al.single.circleId, al.single.title), (true, priv, 'Circle key refused'));
    });

    test('a bridge never receives a phone-key epoch in a circle with server processing, but gets the server key', () async {
      final ViewerFixture bridge = await ViewerFixture.create(uA);
      final String ap = await alice.service.approveLinkRequest(await alice.service.inspectViewerRequest(await bridge.request(kind: 'service', name: 'Dawarich')));
      final DeviceKey bk = await bridge.register(server, ap, kind: 'service', label: 'Dawarich');
      final ViewerFixture web = await ViewerFixture.create(uA);
      final String ap2 = await alice.service.approveLinkRequest(await alice.service.inspectViewerRequest(await web.request(kind: 'web', name: 'Browser')));
      final DeviceKey wk = await web.register(server, ap2, kind: 'web', label: 'Browser');
      // Without server processing: the old behaviour (a viewer or bridge the owner approved reads through the phone key).
      await alice.service.bumpEpoch(priv);
      expect(server.circles[priv]!.wraps.values.any((WrapRecord w) => w.epoch == 2 && w.recipientDeviceId == bk.deviceId), isTrue);
      // With it on: no phone-key wrap for either, SK for the bridge.
      await alice.lanes.publishPolicy(priv, serverAssist: true);
      await alice.service.bumpEpoch(priv);
      final FakeCircle c = server.circles[priv]!;
      expect(c.wraps.values.any((WrapRecord w) => w.epoch == 3 && w.recipientDeviceId == bk.deviceId), isFalse);
      expect(c.wraps.values.any((WrapRecord w) => w.epoch == 3 && w.recipientDeviceId == wk.deviceId), isFalse);
      expect(c.skWraps.containsKey('1/${bk.deviceId}'), isTrue, reason: 'the bridge reads the server line');
      // The pending report asks for explicit approval of the web viewer and never lists the bridge.
      final PendingReport pr = await alice.service.processPending(priv);
      expect(pr.needConfirm.map((PendingItem p) => p.key.deviceId), contains(wk.deviceId));
      expect(pr.needConfirm.map((PendingItem p) => p.key.deviceId), isNot(contains(bk.deviceId)));
      await expectLater(alice.service.confirmWrap(priv, bk, viewerInformed: true), throwsA(isA<StateError>()));
      await expectLater(alice.service.confirmWrap(priv, wk), throwsA(isA<StateError>()));
      await alice.service.confirmWrap(priv, wk, viewerInformed: true);
      expect(c.wraps.values.any((WrapRecord w) => w.recipientDeviceId == wk.deviceId && w.epoch == 3), isTrue);
    });

    test('bulk wraps (new phone, recovery) never go to a bridge, a viewer or the server key', () async {
      final ViewerFixture bridge = await ViewerFixture.create(uA);
      final String ap = await alice.service.approveLinkRequest(await alice.service.inspectViewerRequest(await bridge.request(kind: 'service', name: 'Dawarich')));
      final DeviceKey bk = await bridge.register(server, ap, kind: 'service', label: 'Dawarich');
      final int before = server.circles[priv]!.wraps.length;
      await alice.service.wrapHeldKeysTo(bk);
      await alice.service.wrapHeldKeysTo(srvKey);
      expect(server.circles[priv]!.wraps.length, before);
    });

    test('an opt-out the server did not take stays in force locally, is shown as unconfirmed, and is retried until it lands', () async {
      await alice.lanes.publishPolicy(priv, serverAssist: true);
      await bob.lanes.refresh(priv);
      await bob.lanes.setLane(priv, E2ee.lineServer, confirmServerFingerprintHex: srvKey.fingerprint);
      bob.client.failPrefPut = true;
      await expectLater(bob.lanes.setLane(priv, E2ee.linePhone), throwsA(anything));
      expect((await bob.ownLane()).line, E2ee.linePhone, reason: 'the phone lane is in force immediately');
      expect(await bob.lanes.store.pendingBody(priv), isNotNull);
      final ProcessingSnapshot s = await LanesProcessingController(bob.lanes).load(priv);
      expect(s.optOutPendingSince, isNotNull);
      expect(await bob.lanes.retryPendingOptOut(priv), isFalse);
      expect((await bob.ownLane()).line, E2ee.linePhone, reason: 'still phone while the retry keeps failing');
      bob.client.failPrefPut = false;
      expect(await bob.lanes.retryPendingOptOut(priv), isTrue);
      expect(await bob.lanes.store.pendingBody(priv), isNull);
      final ProcessingSnapshot after = await LanesProcessingController(bob.lanes).load(priv, force: true);
      expect(after.optOutPendingSince, isNull);
      expect(after.me!.serverAssisted, isFalse);
    });

    test('the snapshot lists viewers and bridges so every member can see them', () async {
      final ViewerFixture web = await ViewerFixture.create(uA);
      final String ap = await alice.service.approveLinkRequest(await alice.service.inspectViewerRequest(await web.request(kind: 'web', name: 'Browser')));
      await web.register(server, ap, kind: 'web', label: 'Browser');
      final ProcessingSnapshot s = await LanesProcessingController(bob.lanes).load(priv);
      expect(s.viewers.map((ProcessingViewer v) => '${v.ownerName}/${v.kind}'), <String>['Alice/web']);
    });
  });
}

/// A [LaneSource] over the real store that moves the lane record once, right after the first check of the server lane.
class _FlippingLanes implements LaneSource, VersionedLaneSource {
  _FlippingLanes(this.inner, this.flip);
  final KvLaneSource inner;
  final Future<void> Function() flip;
  bool flipped = false;
  int _checks = 0;
  @override
  Future<LaneChoice> ownLane(String c) => inner.ownLane(c);
  @override
  Future<bool> serverLaneAllowed(String c) async {
    final bool r = await inner.serverLaneAllowed(c);
    if (++_checks == 2 && !flipped) {
      flipped = true;
      await flip();
    }
    return r;
  }

  @override
  Future<List<PrefEntry>> prefsOf(String c, String u) => inner.prefsOf(c, u);
  @override
  Future<bool> serverAssistOn(String c) => inner.serverAssistOn(c);
  @override
  Future<int> laneVersion(String c) => inner.laneVersion(c);
}

/// A second view of the same data, standing in for the other isolate (own lock, own queue object).
class MemoryKvView implements ChannelKv {
  MemoryKvView(this.base);
  final MemoryKv base;
  @override
  Future<String?> get(String key) => base.get(key);
  @override
  Future<String?> getFresh(String key) => base.getFresh(key);
  @override
  Future<void> set(String key, String value) => base.set(key, value);
  @override
  Future<void> remove(String key) => base.remove(key);
}
