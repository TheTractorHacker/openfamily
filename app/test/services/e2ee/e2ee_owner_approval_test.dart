import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/e2ee/e2ee_crypto.dart';
import 'package:openfamily/services/e2ee/e2ee_models.dart';
import 'package:openfamily/services/e2ee/e2ee_service.dart';
import 'package:openfamily/services/e2ee/e2ee_trust.dart';
import 'package:openfamily/services/e2ee/e2ee_vault.dart';

import '../../support/fake_e2ee_server.dart';

// Owner approval (docs/design/E2EE.md "Owner approval").

const String uA = '11111111-1111-4111-8111-111111111111';
const String uB = '22222222-2222-4222-8222-222222222222';
const String circle = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const String devA2 = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2';
const String devB = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

class Phone {
  Phone(FakeE2eeServer server, this.userId) : trust = TrustStore(MemoryTrustKv()) {
    svc = E2eeService(api: server.client(userId), vault: MemoryVault(), trust: trust, userIdProvider: () async => userId);
  }
  final String userId;
  final TrustStore trust;
  late final E2eeService svc;
}

LogEntry entry(int seq, int action, String user, {String? subject, Uint8List? ref}) => LogEntry(
      seq: seq,
      prevHash: Uint8List(32),
      entryHash: Uint8List(32),
      redacted: false,
      action: action,
      userId: user,
      actorDeviceId: devA2,
      actorPub: Uint8List(32),
      circleId: circle,
      subjectId: subject,
      epoch: 0,
      ref: ref ?? Uint8List(32),
      signature: Uint8List(64),
    );

void main() {
  test('owner-approval ref matches the Go vector', () async {
    expect(E2ee.hex(await E2ee.ownerApprovalRef(uA, uB, false)), 'eac3341d0c0f79c9b0f4b470cd77eb7f386450f4d446af5c45aad3caee654ea3');
    expect(E2ee.hex(await E2ee.ownerApprovalRef(uA, uB, true)), 'ea645725ab2e3c584928d151d346ccef83c662078f3ef68dde7fc19a62035b22');
    // Action 12 is a valid log action for this app.
    expect(E2ee.logActionMessage(E2ee.actOwnerApproval, uA, devA2, circleId: circle).length, greaterThan(0));
  });

  group('trust rules', () {
    const CircleRoles roles = CircleRoles(creatorId: uA, adminIds: <String>{uA, uB});

    test('the rule counts only when an admin signed it; ON only from the creator', () async {
      final Uint8List on = await E2ee.ownerApprovalRef(circle, uA, true);
      expect((await readOwnerPolicyEntry(entry(5, E2ee.actOwnerApproval, uA, ref: on), roles))?.on, isTrue);
      // Not an admin (roles as the server reports them).
      expect(await readOwnerPolicyEntry(entry(5, E2ee.actOwnerApproval, uA, ref: on), const CircleRoles(creatorId: uA)), isNull);
      // An admin who did not create the circle cannot turn it on...
      final Uint8List onB = await E2ee.ownerApprovalRef(circle, uB, true);
      expect(await readOwnerPolicyEntry(entry(5, E2ee.actOwnerApproval, uB, ref: onB), roles), isNull);
      // ...but can turn it off.
      final Uint8List offB = await E2ee.ownerApprovalRef(circle, uB, false);
      expect((await readOwnerPolicyEntry(entry(6, E2ee.actOwnerApproval, uB, ref: offB), roles))?.on, isFalse);
      // A ref signed for another person is neither on nor off.
      expect(await readOwnerPolicyEntry(entry(5, E2ee.actOwnerApproval, uA, ref: onB), roles), isNull);
    });

    test('a self-approval is accepted only under the creator\'s verified rule', () {
      final LogEntry approval = entry(9, E2ee.actApprove, uA, subject: devA2);
      const OwnerPolicy on = OwnerPolicy(on: true, byUserId: uA, seq: 5);
      expect(classifyApproval(approval, subjectOwner: uA, policy: on, roles: roles), ApprovalKind.byOwnerWithoutSecondAdmin);
      expect(classifyApproval(approval, subjectOwner: uA, policy: null, roles: roles), ApprovalKind.invalidSelfApproval);
      expect(classifyApproval(approval, subjectOwner: uA, policy: const OwnerPolicy(on: false, byUserId: uA, seq: 5), roles: roles),
          ApprovalKind.invalidSelfApproval);
      // The rule must come before the approval.
      expect(classifyApproval(approval, subjectOwner: uA, policy: const OwnerPolicy(on: true, byUserId: uA, seq: 12), roles: roles),
          ApprovalKind.invalidSelfApproval);
      // Not the creator (any more), or no longer an admin.
      expect(classifyApproval(approval, subjectOwner: uA, policy: on, roles: const CircleRoles(creatorId: uB, adminIds: <String>{uA})),
          ApprovalKind.invalidSelfApproval);
      expect(classifyApproval(approval, subjectOwner: uA, policy: on, roles: const CircleRoles(creatorId: uA, adminIds: <String>{uB})),
          ApprovalKind.invalidSelfApproval);
      // Approving someone else is the normal rule.
      expect(classifyApproval(entry(9, E2ee.actApprove, uA, subject: devB), subjectOwner: uB, policy: null, roles: roles),
          ApprovalKind.byOtherAdmin);
    });

    test('a self-approval without a rule raises a severe alarm', () async {
      final TrustStore t = TrustStore(MemoryTrustKv());
      final List<E2eeAlarm> a = await alarmsFromLog(
        events: <LogEntry>[entry(9, E2ee.actApprove, uA, subject: devA2)],
        selfUserId: uB,
        trust: t,
        userNames: const <String, String>{uA: 'Alice'},
        circleNames: const <String, String>{circle: 'Family'},
        circleRoles: const <String, CircleRoles>{circle: roles},
        deviceOwners: const <String, String>{devA2: uA},
      );
      expect(a.single.kind, AlarmKind.invalidSelfApproval);
      expect(a.single.severe, isTrue);
      expect(await t.ownerApprovedKeys(), isEmpty);
    });
  });

  group('end to end with the fake server', () {
    late FakeE2eeServer server;
    setUp(() => server = FakeE2eeServer()..names.addAll(<String, String>{uA: 'Alice', uB: 'Bob'}));

    test('the sole admin and creator approves their own new phone; others keep trusting it and are told', () async {
      server.circle(circle, members: <String>[uA, uB], admin: uA);
      final Phone a = Phone(server, uA), b = Phone(server, uB);
      await a.svc.registerThisDevice();
      await b.svc.registerThisDevice();
      await a.svc.enableCircle(circle);
      await b.svc.syncCircleKeys(circle);
      await b.svc.syncLog(); // Bob pins the log

      // Alice sets her phone up again: a new root key that nobody vouches for.
      final Phone a2 = Phone(server, uA);
      final DeviceKey k = await a2.svc.registerThisDevice(reset: true);
      CircleE2eeState st = await a2.svc.api.circleState(circle);
      expect(E2eeService.ownKeyApproval(st, uA).action, OwnKeyAction.soleAdminCanEnable);

      // Without the rule she cannot approve herself; the answer says what to do.
      await expectLater(a2.svc.approveDevice(circle, k, password: FakeCircle.password),
          throwsA(predicate((Object e) => e.toString().contains('only admin') && e.toString().contains('owner approval'))));

      // She turns the rule on (password), then approves her phone (password again).
      await expectLater(a2.svc.setOwnerApproval(circle, true, password: 'wrong'), throwsA(anything));
      await a2.svc.setOwnerApproval(circle, true, password: FakeCircle.password);
      st = await a2.svc.api.circleState(circle);
      expect(E2eeService.ownKeyApproval(st, uA).action, OwnKeyAction.approveAsOwner);
      await expectLater(a2.svc.approveDevice(circle, k), throwsA(anything)); // no re-authentication
      await a2.svc.approveDevice(circle, k, password: FakeCircle.password);

      // She publishes a new circle key; Bob's phone accepts it.
      expect(await a2.svc.bumpEpoch(circle), 2);
      expect(await b.svc.syncCircleKeys(circle), 1);
      expect(E2ee.hex((await b.svc.circleKey(circle, 2))!), E2ee.hex((await a2.svc.circleKey(circle, 2))!));

      // Bob's phone verifies the log: a notice for the rule and for the approval, no severe alarm.
      final LogSync s = await b.svc.syncLog(userNames: const <String, String>{uA: 'Alice'}, circleNames: const <String, String>{circle: 'Family'});
      expect(s.check.ok, isTrue);
      final List<AlarmKind> kinds = s.alarms.map((E2eeAlarm x) => x.kind).toList();
      expect(kinds, containsAll(<AlarmKind>[AlarmKind.ownerApprovalPolicy, AlarmKind.ownerApproved]));
      expect(s.alarms.where((E2eeAlarm x) => x.severe), isEmpty);
      expect(s.alarms.firstWhere((E2eeAlarm x) => x.kind == AlarmKind.ownerApproved).body, contains('without a second admin'));
      expect((await b.trust.ownerApprovedKeys()).keys, contains(k.deviceId));
      // The circle state marks the key too.
      final CircleE2eeState bs = await b.svc.api.circleState(circle);
      expect(bs.allDevices.firstWhere((DeviceKey d) => d.deviceId == k.deviceId).ownerApproved, isTrue);
    });

    test('a member who is not the creator cannot use the rule', () async {
      server.circle(circle, members: <String>[uA, uB], admin: uA).creator = uB;
      final Phone a = Phone(server, uA);
      await a.svc.registerThisDevice();
      await a.svc.enableCircle(circle);
      await expectLater(a.svc.setOwnerApproval(circle, true, password: FakeCircle.password), throwsA(anything));
      expect(E2eeService.ownKeyApproval(await a.svc.api.circleState(circle), uA).action, OwnKeyAction.soleAdmin);
    });
  });
}
