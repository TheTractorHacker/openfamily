import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/e2ee/e2ee_crypto.dart';
import 'package:openfamily/services/e2ee/e2ee_models.dart';
import 'package:openfamily/services/e2ee/e2ee_service.dart';
import 'package:openfamily/services/e2ee/e2ee_trust.dart';
import 'package:openfamily/services/e2ee/e2ee_vault.dart';

import '../support/fake_e2ee_server.dart';
import '../support/viewer_fixture.dart';

const String uA = '11111111-1111-4111-8111-111111111111';
const String uB = '22222222-2222-4222-8222-222222222222';
const String cid = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';

void main() {
  late FakeE2eeServer server;
  late E2eeService alice, bob;
  late ViewerFixture srv;
  late DeviceKey srvKey;

  E2eeService mk(String u) => E2eeService(api: server.client(u), vault: MemoryVault(), trust: TrustStore(MemoryTrustKv()), userIdProvider: () async => u);

  setUp(() async {
    server = FakeE2eeServer()..names.addAll(<String, String>{uA: 'Alice', uB: 'Bob'});
    server.circle(cid, members: <String>[uA, uB], admin: uA);
    alice = mk(uA);
    bob = mk(uB);
    await alice.registerThisDevice();
    await bob.registerThisDevice();
    await alice.enableCircle(cid);
    // The server device: a `server` key of Alice's account, approved by her phone.
    srv = await ViewerFixture.create(uA);
    final String ap = await alice.approveLinkRequest(await alice.inspectViewerRequest(await srv.request(kind: 'server', name: 'OpenFamily server')));
    srvKey = await srv.register(server, ap, kind: 'server', label: 'OpenFamily server');
    server.serverModeEnabled = true;
    server.pinnedServerDevice = srv.deviceId;
  });

  test('the server-consent message matches the frozen Go vector', () async {
    final Map<String, dynamic> v = jsonDecode(File('../backend/internal/e2ee/testdata/server_consent.json').readAsStringSync()) as Map<String, dynamic>;
    final Uint8List msg = E2ee.serverConsentMessage(v['circle_id'] as String, v['user_id'] as String, v['server_device_id'] as String, E2ee.unhex(v['server_fingerprint_hex'] as String));
    expect(E2ee.hex(msg), v['message_hex']);
    final Uint8List seed = E2ee.unhex(v['approver_seed_hex'] as String);
    final Uint8List pub = await E2ee.edPublicFromSeed(seed);
    expect(E2ee.hex(pub), v['approver_ed25519_pub_hex']);
    expect(E2ee.hex(await E2ee.sign(seed, msg)), v['signature_hex']);
    expect(await E2ee.verify(pub, msg, E2ee.unhex(v['signature_hex'] as String)), isTrue);
  });

  test('a registered server key gets NO circle key automatically', () async {
    final PendingReport r = await alice.processPending(cid);
    expect(r.wrapped, 0);
    expect(server.circles[cid]!.wraps.containsKey('1/${srv.deviceId}'), isFalse);
    // Even a direct confirmWrap is refused without every member's consent.
    final CircleE2eeState st = await alice.api.circleState(cid);
    final DeviceKey k = st.allDevices.firstWhere((DeviceKey d) => d.deviceId == srv.deviceId);
    expect(() => alice.confirmWrap(cid, k), throwsA(isA<StateError>()));
    await alice.consentToServer(cid);
    expect(() => alice.confirmWrap(cid, k), throwsA(isA<StateError>()), reason: 'Bob has not consented');
    expect(() => alice.shareKeyWithServer(cid), throwsA(isA<StateError>()));
  });

  test('even after every member consented the phone key (CK) is NEVER given to the server', () async {
    await alice.consentToServer(cid);
    await bob.consentToServer(cid);
    final CircleE2eeState st = await alice.api.circleState(cid);
    final ServerMemberState ss = await alice.api.serverMemberState(cid);
    expect((await alice.verifiedConsentUsers(st, ss, srvKey)).toSet(), <String>{uA, uB});
    expect(E2eeService.membersNeedingConsent(st).toSet(), <String>{uA, uB});
    // Phase 4 (PRIVACY_PROCESSING 5.4.1): the legacy action is gone, and a direct wrap is refused too.
    expect(() => alice.shareKeyWithServer(cid), throwsA(isA<StateError>()));
    final DeviceKey k = st.allDevices.firstWhere((DeviceKey d) => d.deviceId == srv.deviceId);
    expect(() => alice.confirmWrap(cid, k), throwsA(isA<StateError>()));
    expect(server.circles[cid]!.wraps.containsKey('1/${srv.deviceId}'), isFalse);
  });

  test('a withdrawn consent excludes the server key from the next epoch', () async {
    await alice.consentToServer(cid);
    await bob.consentToServer(cid);
    await bob.withdrawServerConsent(cid);
    expect(server.circles[cid]!.rekey, isTrue);
    await alice.bumpEpoch(cid);
    expect(server.circles[cid]!.wraps.containsKey('2/${srv.deviceId}'), isFalse, reason: 'server key must not receive epoch 2');
    expect(server.circles[cid]!.wraps.containsKey('2/${(await alice.identity())!.deviceId}'), isTrue);
  });

  test('with everyone consenting the next epoch is STILL not wrapped for the server key', () async {
    await alice.consentToServer(cid);
    await bob.consentToServer(cid);
    await alice.bumpEpoch(cid);
    expect(server.circles[cid]!.wraps.containsKey('2/${srv.deviceId}'), isFalse);
    expect(server.circles[cid]!.wraps.values.any((WrapRecord w) => w.recipientDeviceId == srv.deviceId), isFalse);
  });

  test('forged or mis-bound consents do not count on the phone', () async {
    await alice.consentToServer(cid);
    final CircleE2eeState st = await alice.api.circleState(cid);
    final FakeCircle c = server.circles[cid]!;
    // The server invents a consent for Bob signed by Alice's key, and one with junk.
    final ServerMemberState real = await alice.api.serverMemberState(cid);
    final Uint8List aliceFp = E2ee.unhex(srvKey.fingerprint);
    final LocalIdentity me = (await alice.identity())!;
    final Uint8List forged = await E2ee.sign(me.edSeed, E2ee.serverConsentMessage(cid, uB, srv.deviceId, aliceFp));
    final ServerMemberState bad = ServerMemberState(enabled: true, device: real.device, consents: <ServerConsent>[
      ...real.consents,
      ServerConsent(uB, me.deviceId, forged), // Alice's key, claimed for Bob
      ServerConsent(uB, (await bob.identity())!.deviceId, Uint8List(64)), // junk signature
    ]);
    expect(await alice.verifiedConsentUsers(st, bad, srvKey), <String>{uA});
    expect(c.serverConsents.containsKey(uB), isFalse);
    // A consent for another server key does not verify either.
    final Uint8List otherFp = Uint8List(32);
    final Uint8List wrongKey = await E2ee.sign(me.edSeed, E2ee.serverConsentMessage(cid, uA, srv.deviceId, otherFp));
    final ServerMemberState wrong = ServerMemberState(enabled: true, device: real.device, consents: <ServerConsent>[ServerConsent(uA, me.deviceId, wrongKey)]);
    expect(await alice.verifiedConsentUsers(st, wrong, srvKey), isEmpty);
  });

  test('consent is refused when the server mode is off or no key is pinned', () async {
    server.serverModeEnabled = false;
    expect(() => alice.consentToServer(cid), throwsA(isA<StateError>()));
    server.serverModeEnabled = true;
    server.pinnedServerDevice = null;
    expect(() => alice.consentToServer(cid), throwsA(isA<StateError>()));
    // A key that merely has kind=server but is not the pinned device is never allowed.
    final ViewerFixture other = await ViewerFixture.create(uB);
    final String ap = await bob.approveLinkRequest(await bob.inspectViewerRequest(await other.request(kind: 'server')));
    await other.register(server, ap, kind: 'server');
    server.pinnedServerDevice = srv.deviceId;
    await alice.consentToServer(cid);
    await bob.consentToServer(cid);
    final CircleE2eeState st = await alice.api.circleState(cid);
    expect((await alice.allowedServerKey(st))!.deviceId, srv.deviceId);
    expect(await alice.purgeServerCopies(cid), 3);
  });
}
