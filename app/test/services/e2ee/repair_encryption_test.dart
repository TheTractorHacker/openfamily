import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/e2ee/e2ee_models.dart';
import 'package:openfamily/services/e2ee/e2ee_service.dart';
import 'package:openfamily/services/e2ee/e2ee_trust.dart';
import 'package:openfamily/services/e2ee/e2ee_vault.dart';

import '../../support/fake_e2ee_server.dart';

// "Repair encryption": the owner's self-heal path (E2eeService.repairOwnEncryption).

const String uA = '11111111-1111-4111-8111-111111111111';
const String uB = '22222222-2222-4222-8222-222222222222';
const String circle = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';

class Phone {
  Phone(FakeE2eeServer server, this.userId) {
    svc = E2eeService(
        api: server.client(userId), vault: MemoryVault(), trust: TrustStore(MemoryTrustKv()), userIdProvider: () async => userId);
  }
  final String userId;
  late final E2eeService svc;
}

void main() {
  late FakeE2eeServer server;
  setUp(() => server = FakeE2eeServer()..names.addAll(<String, String>{uA: 'Alice', uB: 'Bob'}));

  test('a reinstalled owner of a Private circle gets approved and, with no key left, starts a new one', () async {
    server.circle(circle, members: <String>[uA, uB], admin: uA);
    final Phone a = Phone(server, uA), b = Phone(server, uB);
    await a.svc.registerThisDevice();
    await b.svc.registerThisDevice();
    await a.svc.enableCircle(circle);
    await b.svc.syncCircleKeys(circle);

    // Alice reinstalls: a new root key, the old phone and its key are gone.
    final Phone a2 = Phone(server, uA);
    await a2.svc.registerThisDevice(reset: true);

    RepairResult r = await a2.svc.repairOwnEncryption(circle);
    expect(r.status, RepairStatus.needsPassword);
    r = await a2.svc.repairOwnEncryption(circle, password: FakeCircle.password);
    expect(r.status, RepairStatus.needsNewKey);
    final CircleE2eeState st = await a2.svc.api.circleState(circle);
    expect(st.members.firstWhere((CircleE2eeMember m) => m.userId == uA).devices.every((DeviceKey d) => d.approved == true), isTrue);

    r = await a2.svc.repairOwnEncryption(circle, password: FakeCircle.password, publishNewKeyIfLost: true);
    expect(r.status, RepairStatus.newKeyPublished);
    expect(await a2.svc.circleKey(circle, 2), isNotNull);
    expect(await b.svc.syncCircleKeys(circle), 1); // Bob's phone received the new key

    // Idempotent: running it again changes nothing and does not ask again.
    r = await a2.svc.repairOwnEncryption(circle);
    expect(r.status, RepairStatus.ok);
  });

  test('a creator whose key was replaced can turn Private on in a circle made afterwards', () async {
    final Phone a = Phone(server, uA);
    await a.svc.registerThisDevice();
    final Phone a2 = Phone(server, uA);
    await a2.svc.registerThisDevice(reset: true);
    server.circle(circle, members: <String>[uA], admin: uA); // created after the reset, not Private yet

    await expectLater(a2.svc.enableCircle(circle), throwsA(predicate((Object e) => e.toString().contains('not approved'))));
    expect((await a2.svc.repairOwnEncryption(circle)).status, RepairStatus.needsPassword);
    final RepairResult r = await a2.svc.repairOwnEncryption(circle, password: FakeCircle.password);
    expect(r.status, RepairStatus.ok);
    expect(await a2.svc.enableCircle(circle), 1);
    expect((await a2.svc.repairOwnEncryption(circle)).status, RepairStatus.ok);
  });

  test('wrong password does not approve; a member who is not the creator is pointed at the admin', () async {
    server.circle(circle, members: <String>[uA, uB], admin: uA);
    final Phone a = Phone(server, uA), b = Phone(server, uB);
    await a.svc.registerThisDevice();
    await b.svc.registerThisDevice();
    await a.svc.enableCircle(circle);
    final Phone a2 = Phone(server, uA);
    await a2.svc.registerThisDevice(reset: true);
    await expectLater(a2.svc.repairOwnEncryption(circle, password: 'nope'), throwsA(anything));

    final Phone b2 = Phone(server, uB);
    await b2.svc.registerThisDevice(reset: true);
    final RepairResult r = await b2.svc.repairOwnEncryption(circle);
    expect(r.status, RepairStatus.waitingForAdmin);
  });

  test('a phone whose account has other keys is told to link or reset, nothing is reset for it', () async {
    server.circle(circle, members: <String>[uA], admin: uA);
    final Phone a = Phone(server, uA);
    await a.svc.registerThisDevice();
    final Phone a2 = Phone(server, uA);
    final RepairResult r = await a2.svc.repairOwnEncryption(circle);
    expect(r.status, RepairStatus.keyNotRegistered);
    expect((await a2.svc.api.myKeys()).where((DeviceKey k) => k.isActive).length, 1);
  });
}
