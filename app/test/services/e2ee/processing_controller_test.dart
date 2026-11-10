import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/circle.dart';
import 'package:openfamily/services/e2ee/e2ee_crypto.dart';
import 'package:openfamily/services/api_client.dart' show ApiException;
import 'package:openfamily/services/e2ee/e2ee_models.dart';
import 'package:openfamily/services/e2ee/lanes_service.dart';
import 'package:openfamily/services/e2ee/lanes_wire.dart';
import 'package:openfamily/services/e2ee/lanes_store.dart';
import 'package:openfamily/services/e2ee/processing_controller.dart';

import '../../support/fake_e2ee_server.dart';
import '../../support/viewer_fixture.dart';
import 'lanes_service_test.dart' show Dev, circleOf, priv, uA, uB, uC;
import 'private_channel_test.dart' show FakeClock;

// The real controller over the real LanesService and the in-memory server:
// what the screens would see and do, with signatures actually verified.

void main() {
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

  test('snapshot: admin vs member, policy off then on, nobody opted in by the admin', () async {
    final LanesProcessingController a = LanesProcessingController(alice.lanes), b = LanesProcessingController(bob.lanes);
    ProcessingSnapshot s = await b.load(priv);
    expect((s.iAmAdmin, s.assistOn, s.hasServerKey, s.members.length), (false, false, true, 3));
    expect(s.serverKeyFingerprint, srvKey.fingerprint);
    await a.setPolicy(priv, assist: true, defaultForNew: E2ee.lineServer, memberOptOut: E2ee.optOutAllowed);
    s = await b.load(priv);
    expect((s.assistOn, s.policy.defaultForNew, s.serverCount, s.status), (true, E2ee.lineServer, 0, LaneStatus.phoneOnly));
    expect(s.me!.verified, isFalse, reason: 'the default is not a choice');
    // A member cannot change the circle setting (the service refuses before anything is signed).
    await expectLater(b.setPolicy(priv, assist: false, defaultForNew: E2ee.linePhone, memberOptOut: E2ee.optOutAllowed), throwsA(isA<StateError>()));
    expect(server.circles[priv]!.assist, isTrue);
  });

  test('a member opts in with the fingerprint they compared, then opts out and the server copies are deleted on request', () async {
    final LanesProcessingController a = LanesProcessingController(alice.lanes), b = LanesProcessingController(bob.lanes);
    await a.setPolicy(priv, assist: true, defaultForNew: E2ee.linePhone, memberOptOut: E2ee.optOutAllowed);
    await expectLater(b.setMyLane(priv, E2ee.lineServer, confirmServerFingerprintHex: 'aa' * 32), throwsA(isA<StateError>()));
    await b.setMyLane(priv, E2ee.lineServer, confirmServerFingerprintHex: srvKey.fingerprint);
    ProcessingSnapshot s = await a.load(priv, force: true);
    expect(s.members.where((ProcessingMember m) => m.serverAssisted).map((ProcessingMember m) => m.userId), <String>[uB]);
    // The admin has no way to put Alice or anyone else on the server lane.
    expect(s.members.firstWhere((ProcessingMember m) => m.userId == uA).serverAssisted, isFalse);
    await b.setMyLane(priv, E2ee.linePhone, deleteCopies: true);
    s = await a.load(priv, force: true);
    expect(s.serverCount, 0);
    expect(server.circles[priv]!.serverPurges, contains('mine'));
  });

  test('Require server processing: one admin switch; a member is never stuck on "consent required"', () async {
    final LanesProcessingController a = LanesProcessingController(alice.lanes), b = LanesProcessingController(bob.lanes);
    await a.setPolicy(priv, assist: true, defaultForNew: E2ee.linePhone, memberOptOut: E2ee.optOutAllowed);
    await a.setRequireServer(priv, true);
    final FakeCircle c = server.circles[priv]!;
    expect((c.assist, c.policy!.memberOptOut, c.policy!.defaultForNew), (true, E2ee.optOutRequiredServer, E2ee.lineServer));
    ProcessingSnapshot s = await b.load(priv, force: true);
    expect(s.required, isTrue);
    expect(s.status, anyOf(LaneStatus.serverPending, LaneStatus.serverAssisted));
    await a.setRequireServer(priv, false);
    s = await b.load(priv, force: true);
    expect((s.required, s.assistOn, c.policy!.memberOptOut), (false, true, E2ee.optOutAllowed));
  });

  group('after the owner reset their keys (production state of 2026-11-10)', () {
    late Dev alice2;
    late ViewerFixture srv2;

    /// Policy on, Bob and Alice in the server lane, then Alice resets her keys on a new phone (fresh vault). The
    /// server makes a new server key that Alice's new phone approves, like v0.26.16 did in production.
    Future<void> resetState({bool approveNewPhone = true}) async {
      final LanesProcessingController a = LanesProcessingController(alice.lanes), b = LanesProcessingController(bob.lanes);
      await a.setPolicy(priv, assist: true, defaultForNew: E2ee.lineServer, memberOptOut: E2ee.optOutAllowed);
      await b.setMyLane(priv, E2ee.lineServer, confirmServerFingerprintHex: srvKey.fingerprint);
      await a.setMyLane(priv, E2ee.lineServer, confirmServerFingerprintHex: srvKey.fingerprint);
      alice2 = Dev(server, channel, uA, clock);
      await alice2.service.registerThisDevice(reset: true, label: 'Reset');
      // In production the reset revoked the server key too and the server made a new one, approved by the new phone.
      final List<DeviceKey> mine = server.keys[uA]!;
      for (int i = 0; i < mine.length; i++) {
        final DeviceKey k = mine[i];
        if (k.deviceId == srv.deviceId && k.isActive) await server.client(uA).revoke(k.deviceId, const <String, dynamic>{});
      }
      srv2 = await ViewerFixture.create(uA);
      final String ap = await alice2.service.approveLinkRequest(
          await alice2.service.inspectViewerRequest(await srv2.request(kind: 'server', name: 'Orbitly server')));
      await srv2.register(server, ap, kind: 'server', label: 'Orbitly server');
      server.pinnedServerDevice = srv2.deviceId;
      if (approveNewPhone) {
        final String newId = (await alice2.service.identity())!.deviceId;
        server.circles[priv]!.approvals.add(newId);
      }
      await alice2.runtime.setCircles(<Circle>[circleOf(priv)]);
    }

    test('the owner\'s new phone and the other member both get a snapshot, never an error', () async {
      await resetState();
      final ProcessingSnapshot sa = await LanesProcessingController(alice2.lanes).load(priv, force: true);
      expect(sa.isPrivate, isTrue);
      expect(sa.iAmAdmin, isTrue);
      final ProcessingSnapshot sb = await LanesProcessingController(bob.lanes).load(priv, force: true);
      expect(sb.isPrivate, isTrue);
    });

    test('the owner\'s new phone not yet approved in the circle still gets a snapshot', () async {
      await resetState(approveNewPhone: false);
      final ProcessingSnapshot sa = await LanesProcessingController(alice2.lanes).load(priv, force: true);
      expect(sa.isPrivate, isTrue);
    });
  });

  test('a broken processing record never ends the screen: a snapshot with a plain problem; a transport error is rethrown', () async {
    await LanesProcessingController(alice.lanes).setPolicy(priv, assist: true, defaultForNew: E2ee.lineServer, memberOptOut: E2ee.optOutAllowed);
    final _BrokenProcClient broken = _BrokenProcClient(server, uB, const FormatException('bad record'));
    final LanesService l = LanesService(service: bob.service, api: broken, kv: bob.kv);
    final ProcessingSnapshot s = await LanesProcessingController(l).load(priv, force: true);
    expect(s.problem, LanesProcessingController.checkProblem);
    expect(s.isPrivate, isTrue);
    expect(s.members.map((ProcessingMember m) => m.userId).toSet(), <String>{uA, uB, uC});
    expect(s.members.firstWhere((ProcessingMember m) => m.isMe).userId, uB);
    final LanesService offline = LanesService(service: bob.service, api: _BrokenProcClient(server, uB, const ApiException(0, 'Could not reach the server. Check your connection.')), kv: bob.kv);
    await expectLater(LanesProcessingController(offline).load(priv, force: true), throwsA(isA<ApiException>()));
  });

  test('legacy circle: the admin upgrades it; members start phone-only; non-admins cannot', () async {
    server.circles[priv]!.legacy = true;
    final LanesProcessingController a = LanesProcessingController(alice.lanes), b = LanesProcessingController(bob.lanes);
    ProcessingSnapshot s = await b.load(priv, force: true);
    expect(s.legacy, isTrue);
    await expectLater(b.upgradeLegacy(priv), throwsA(isA<StateError>()));
    final int epochBefore = server.circles[priv]!.epoch;
    await a.upgradeLegacy(priv);
    final FakeCircle c = server.circles[priv]!;
    expect((c.legacy, c.epoch, c.skGen, c.assist), (false, epochBefore + 1, 1, true));
    // The new circle key epoch is not wrapped to the server key.
    expect(c.wraps.values.where((WrapRecord w) => w.epoch == epochBefore + 1).any((WrapRecord w) => w.recipientDeviceId == srv.deviceId), isFalse);
    s = await b.load(priv, force: true);
    expect((s.legacy, s.assistOn, s.serverCount, s.policy.memberOptOut), (false, true, 0, E2ee.optOutAllowed));
  });
}

class _BrokenProcClient extends FakeE2eeClient {
  _BrokenProcClient(super.s, super.uid, this.error);
  final Object error;
  @override
  Future<ProcessingServerState> processingState(String circleId) async => throw error;
}
