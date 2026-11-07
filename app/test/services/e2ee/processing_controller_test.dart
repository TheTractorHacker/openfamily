import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/circle.dart';
import 'package:openfamily/services/e2ee/e2ee_crypto.dart';
import 'package:openfamily/services/e2ee/e2ee_models.dart';
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

  test('required_server: a member without their own consent sees consentRequired and can consent', () async {
    final LanesProcessingController a = LanesProcessingController(alice.lanes), b = LanesProcessingController(bob.lanes);
    await a.setPolicy(priv, assist: true, defaultForNew: E2ee.linePhone, memberOptOut: E2ee.optOutRequiredServer);
    ProcessingSnapshot s = await b.load(priv, force: true);
    expect((s.status, s.required), (LaneStatus.consentRequired, true));
    await b.setMyLane(priv, E2ee.lineServer, confirmServerFingerprintHex: srvKey.fingerprint);
    s = await b.load(priv, force: true);
    expect(s.status, LaneStatus.serverAssisted);
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
