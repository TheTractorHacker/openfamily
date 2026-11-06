import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/e2ee/e2ee_crypto.dart';
import 'package:openfamily/services/e2ee/e2ee_models.dart';
import 'package:openfamily/services/e2ee/e2ee_service.dart';
import 'package:openfamily/services/e2ee/e2ee_trust.dart';
import 'package:openfamily/services/e2ee/e2ee_vault.dart';

import '../../support/fake_e2ee_server.dart';
import '../../support/viewer_fixture.dart';

const String uA = '11111111-1111-4111-8111-111111111111';
const String uB = '22222222-2222-4222-8222-222222222222';
const String circle = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';

E2eeService svcFor(FakeE2eeServer s, String u) =>
    E2eeService(api: s.client(u), vault: MemoryVault(), trust: TrustStore(MemoryTrustKv()), userIdProvider: () async => u);

void main() {
  late FakeE2eeServer server;
  late E2eeService alice;

  setUp(() async {
    server = FakeE2eeServer()..names.addAll(<String, String>{uA: 'Alice', uB: 'Bob'});
    server.circle(circle, members: <String>[uA, uB], admin: uA);
    alice = svcFor(server, uA);
    await alice.registerThisDevice();
  });

  group('inspectViewerRequest', () {
    test('returns name, kind and the fingerprint digits', () async {
      final ViewerFixture v = await ViewerFixture.create(uA);
      final LinkRequestInfo i = await alice.inspectViewerRequest(await v.request(kind: 'service', name: 'Dawarich bridge'));
      expect(i.kind, 'service');
      expect(i.name, 'Dawarich bridge');
      expect(i.deviceId, v.deviceId);
      expect(E2ee.constEq(i.fingerprint, await v.fingerprint()), isTrue);
      expect(i.digits, await E2ee.digitGroups(await v.fingerprint()));
      expect(i.digits.split(' '), hasLength(12));
      expect(i.short, E2ee.shortFingerprint(await v.fingerprint()));
    });

    test('control characters are stripped and the name is capped at 40', () async {
      final ViewerFixture v = await ViewerFixture.create(uA);
      final LinkRequestInfo i = await alice.inspectViewerRequest(await v.request(name: 'a\nb${'x' * 60}'));
      expect(i.name!.length, 40);
      expect(i.name, isNot(contains('\n')));
    });

    test('a code of another account is refused', () async {
      final ViewerFixture v = await ViewerFixture.create(uB);
      await expectLater(alice.inspectViewerRequest(await v.request()), throwsA(isA<E2eeFormatException>()));
    });

    test('a forged binding is refused', () async {
      final ViewerFixture v = await ViewerFixture.create(uA);
      final Map<String, dynamic> m = jsonDecode(utf8.decode(base64Url.decode(await v.request()))) as Map<String, dynamic>;
      m['x'] = E2ee.b64(E2ee.randomBytes(32));
      await expectLater(alice.inspectViewerRequest(base64Url.encode(utf8.encode(jsonEncode(m)))), throwsA(isA<E2eeAuthException>()));
    });

    test('kind device or missing kind is redirected to Link another phone', () async {
      final ViewerFixture v = await ViewerFixture.create(uA);
      for (final String? k in <String?>['device', null]) {
        await expectLater(
            alice.inspectViewerRequest(await v.request(kind: k)),
            throwsA(isA<E2eeFormatException>().having((E2eeFormatException e) => e.message, 'message', contains('Link another phone'))));
      }
      // A real phone request has no kind either.
      final E2eeService a2 = svcFor(server, uA);
      await expectLater(alice.inspectViewerRequest(await a2.createLinkRequest()), throwsA(isA<E2eeFormatException>()));
      // The existing phone flow still works and reports no kind.
      expect((await alice.inspectLinkRequest(await a2.createLinkRequest())).kind, isNull);
    });
  });

  group('approval and key delivery', () {
    late E2eeService bob;
    Future<void> enable() async {
      bob = svcFor(server, uB);
      await bob.registerThisDevice();
      expect(await alice.enableCircle(circle), 1);
    }

    test('approval code is an Ed25519 register signature of the phone over the viewer as subject', () async {
      final ViewerFixture v = await ViewerFixture.create(uA);
      final String code = await alice.approveLinkRequest(await alice.inspectViewerRequest(await v.request()));
      final Map<String, dynamic> ap = jsonDecode(utf8.decode(base64Url.decode(code))) as Map<String, dynamic>;
      final LocalIdentity me = (await alice.identity())!;
      expect(ap['a'], me.deviceId);
      final Uint8List msg = E2ee.logActionMessage(E2ee.actRegister, uA, me.deviceId, subjectId: v.deviceId, ref: await v.fingerprint());
      expect(await E2ee.verify(me.edPub, msg, E2ee.unb64(ap['s'] as String)), isTrue);
      // And the viewer can register with it (server verifies the same message).
      final DeviceKey k = await v.register(server, code);
      expect(k.kind, 'web');
      expect(k.registeredByDeviceId, me.deviceId);
      expect(await verifyRegistration(k), isTrue);
    });

    test('processPending auto-wraps a web and a service key of the own account; they unwrap and match the commitment', () async {
      await enable();
      final List<ViewerFixture> vs = <ViewerFixture>[await ViewerFixture.create(uA), await ViewerFixture.create(uA)];
      final List<String> kinds = <String>['web', 'service'];
      for (int i = 0; i < 2; i++) {
        final String code = await alice.approveLinkRequest(await alice.inspectViewerRequest(await vs[i].request(kind: kinds[i])));
        await vs[i].register(server, code, kind: kinds[i], label: kinds[i]);
      }
      expect((await server.client(uA).pending(circle)).where((DeviceKey k) => k.userId == uA && k.kind != 'device'), hasLength(2));
      final PendingReport r = await alice.processPending(circle);
      expect(r.wrapped, 2);
      expect(r.needConfirm, isEmpty);
      for (int i = 0; i < 2; i++) {
        // What the viewer does: fetch wraps for ITS device id and unwrap with ITS x25519 secret.
        final E2eeService viewer = svcFor(server, uA);
        await viewer.identity(create: true);
        expect(await viewer.syncCircleKeys(circle, asDeviceId: vs[i].deviceId, xSecret: vs[i].xSecret, xPub: vs[i].xPub), 1);
        expect(viewer.rejectedWraps, 0);
        final Uint8List? key = await viewer.circleKey(circle, 1);
        expect(key, isNotNull);
        expect(E2ee.constEq(key!, (await alice.circleKey(circle, 1))!), isTrue);
        final EpochRecord rec = (await server.client(uA).circleState(circle)).epochRecord(1)!;
        expect(E2ee.constEq(await E2ee.keyCommitment(key, circle, 1), rec.commitment), isTrue);
      }
    });

    test('another member\'s cross-signed web key is wrapped automatically by the publisher (documented behaviour)', () async {
      await enable();
      final ViewerFixture v = await ViewerFixture.create(uB);
      await v.register(server, await bob.approveLinkRequest(await bob.inspectViewerRequest(await v.request())));
      final PendingReport r = await alice.processPending(circle);
      // Same rule as a member's second phone: cross-signed by that member's own key.
      expect(r.wrapped, 1);
      expect(r.needConfirm, isEmpty);
      // A non-publisher member does not wrap it.
      final PendingReport rb = await bob.processPending(circle);
      expect(rb.wrapped, 0);
    });
  });
}
