import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/e2ee/e2ee_crypto.dart';
import 'package:openfamily/services/e2ee/e2ee_models.dart';
import 'package:openfamily/services/e2ee/e2ee_service.dart';
import 'package:openfamily/services/e2ee/e2ee_trust.dart';
import 'package:openfamily/services/e2ee/e2ee_vault.dart';

import '../../support/fake_e2ee_server.dart';

const String uA = '11111111-1111-4111-8111-111111111111';
const String uB = '22222222-2222-4222-8222-222222222222';
const String uC = '33333333-3333-4333-8333-333333333333';
const String circle = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';

class Phone {
  Phone(FakeE2eeServer server, String user)
      : vault = MemoryVault(),
        kv = MemoryTrustKv(),
        userId = user {
    trust = TrustStore(kv);
    svc = E2eeService(api: server.client(user), vault: vault, trust: trust, userIdProvider: () async => user);
  }
  final MemoryVault vault;
  final MemoryTrustKv kv;
  final String userId;
  late final TrustStore trust;
  late final E2eeService svc;
}

void main() {
  late FakeE2eeServer server;
  setUp(() {
    server = FakeE2eeServer()
      ..names.addAll(<String, String>{uA: 'Alice', uB: 'Bob', uC: 'Cleo'});
  });

  group('registration and linking', () {
    test('first key is a root; a second phone needs a cross-signature', () async {
      final Phone a1 = Phone(server, uA);
      final DeviceKey k1 = await a1.svc.registerThisDevice();
      expect(k1.initial, isTrue);
      expect(await verifyRegistration(k1), isTrue);

      final Phone a2 = Phone(server, uA);
      await expectLater(a2.svc.registerThisDevice(), throwsA(isA<NeedsCrossSignatureException>()));

      // Manual link: new phone shows a code, old phone checks and signs.
      final String request = await a2.svc.createLinkRequest();
      final LinkRequestInfo info = await a1.svc.inspectLinkRequest(request);
      expect(info.short, matches(RegExp(r'^([0-9A-F]{4} ){3}[0-9A-F]{4}$')));
      final String approval = await a1.svc.approveLinkRequest(info);
      final DeviceKey k2 = await a2.svc.registerThisDevice(approval: a2.svc.parseApproval(approval));
      expect(k2.isRoot, isFalse);
      expect(k2.registeredByDeviceId, k1.deviceId);
      expect(await verifyRegistration(k2), isTrue);
      // The chain is visible to others and a tampered record fails the check.
      final DeviceKey forged = DeviceKey(
          deviceId: k2.deviceId, userId: uB, kind: k2.kind, edPub: k2.edPub, xPub: k2.xPub, fingerprint: k2.fingerprint,
          digits: '', short: '', registeredByDeviceId: k2.registeredByDeviceId, registeredByPub: k2.registeredByPub,
          registrationAction: k2.registrationAction, registrationSignature: k2.registrationSignature, initial: false,
          label: '', createdAt: k2.createdAt);
      expect(await verifyRegistration(forged), isFalse);
    });

    test('a link request for another account or with a bad binding is refused', () async {
      final Phone a1 = Phone(server, uA);
      await a1.svc.registerThisDevice();
      final Phone b1 = Phone(server, uB);
      final String foreign = await b1.svc.createLinkRequest();
      await expectLater(a1.svc.inspectLinkRequest(foreign), throwsA(isA<E2eeFormatException>()));
      final Phone a2 = Phone(server, uA);
      final Map<String, dynamic> m = jsonDecode(utf8.decode(base64Url.decode(await a2.svc.createLinkRequest()))) as Map<String, dynamic>;
      m['x'] = E2ee.b64(E2ee.randomBytes(32));
      await expectLater(a1.svc.inspectLinkRequest(base64Url.encode(utf8.encode(jsonEncode(m)))), throwsA(isA<E2eeAuthException>()));
    });

    test('reset replaces all keys and is a ROOT that needs approval', () async {
      final Phone a1 = Phone(server, uA);
      await a1.svc.registerThisDevice();
      final Phone a2 = Phone(server, uA);
      final DeviceKey k = await a2.svc.registerThisDevice(reset: true);
      expect(k.isRoot, isTrue);
      expect(k.initial, isFalse);
      expect(k.registrationAction, E2ee.actReset);
      expect(server.activeOf(uA).length, 1);
    });
  });

  group('Check server record', () {
    test('match, mismatch (server swapped a key) and revoked', () async {
      final Phone a = Phone(server, uA);
      await a.svc.registerThisDevice();
      ServerRecordCheck c = await a.svc.checkServerRecord();
      expect(c.match, isTrue);
      expect(c.serverFingerprint, c.localFingerprint);

      // The server starts showing different public keys for this device.
      final DeviceKey real = server.keys[uA]!.single;
      final Uint8List evilX = E2ee.randomBytes(32);
      server.keys[uA]![0] = DeviceKey(
          deviceId: real.deviceId, userId: uA, kind: 'device', edPub: real.edPub, xPub: evilX,
          fingerprint: E2ee.hex(await E2ee.fingerprint(real.edPub, evilX)), digits: '', short: '',
          registeredByDeviceId: real.registeredByDeviceId, registeredByPub: real.registeredByPub,
          registrationAction: 1, registrationSignature: real.registrationSignature, initial: true, label: '', createdAt: real.createdAt);
      c = await a.svc.checkServerRecord();
      expect(c.match, isFalse);
      expect(c.registered, isTrue);
      expect(c.problem, contains('different keys'));
    });

    test('no keys yet and revoked states', () async {
      final Phone a = Phone(server, uA);
      expect((await a.svc.checkServerRecord()).registered, isFalse);
      await a.svc.registerThisDevice();
      await a.svc.revokeKey(server.keys[uA]!.single);
      final ServerRecordCheck c = await a.svc.checkServerRecord();
      expect(c.match, isFalse);
      expect(c.revoked, isTrue);
    });
  });

  group('circle keys', () {
    Future<(Phone, Phone)> twoMembers() async {
      server.circle(circle, members: <String>[uA, uB], admin: uA);
      final Phone a = Phone(server, uA), b = Phone(server, uB);
      await a.svc.registerThisDevice();
      await b.svc.registerThisDevice();
      return (a, b);
    }

    test('enable wraps the key to every member and each opens the same key', () async {
      final (Phone a, Phone b) = await twoMembers();
      expect(await a.svc.enableCircle(circle), 1);
      expect(await b.svc.syncCircleKeys(circle), 1);
      final Uint8List? ka = await a.svc.circleKey(circle, 1);
      final Uint8List? kb = await b.svc.circleKey(circle, 1);
      expect(ka, isNotNull);
      expect(E2ee.hex(ka!), E2ee.hex(kb!));
      // The server holds only wraps: it cannot produce the key.
      final Uint8List payload = await E2ee.seal(ka, circle, 1, (await a.svc.identity())!.deviceId, 'loc', utf8.encode('52.5,13.4'));
      expect(utf8.decode(await E2ee.open(kb, circle, (await a.svc.identity())!.deviceId, 'loc', payload)), '52.5,13.4');
    });

    test('a wrap addressed to someone else does not open; a tampered wrap is ignored', () async {
      final (Phone a, Phone b) = await twoMembers();
      await a.svc.enableCircle(circle);
      final FakeCircle c = server.circles[circle]!;
      final String bDev = (await b.svc.identity())!.deviceId;
      final WrapRecord w = c.wraps['1/$bDev']!;
      final Uint8List bad = Uint8List.fromList(w.blob)..[60] ^= 1;
      c.wraps['1/$bDev'] = WrapRecord(epoch: 1, recipientDeviceId: bDev, wrapperDeviceId: w.wrapperDeviceId,
          wrapperEdPub: w.wrapperEdPub, blob: bad, signature: w.signature);
      expect(await b.svc.syncCircleKeys(circle), 0); // signature no longer matches the blob
      expect(await b.svc.circleKey(circle, 1), isNull);
    });

    test('epoch bump after removal re-wraps only to remaining devices', () async {
      server.circle(circle, members: <String>[uA, uB, uC], admin: uA);
      final Phone a = Phone(server, uA), b = Phone(server, uB), c = Phone(server, uC);
      for (final Phone p in <Phone>[a, b, c]) {
        await p.svc.registerThisDevice();
      }
      await a.svc.enableCircle(circle);
      await c.svc.syncCircleKeys(circle);
      server.circles[circle]!.members.remove(uC);
      server.circles[circle]!.rekey = true;
      expect(await a.svc.bumpEpoch(circle), 2);
      expect(await b.svc.syncCircleKeys(circle), 2); // epochs 1 and 2
      expect(await c.svc.syncCircleKeys(circle).onError((_, __) => 0), 0);
      expect(server.circles[circle]!.wraps.keys.where((String k) => k.startsWith('2/')).length, 2);
    });

    test('pending: first-seen member is wrapped automatically (TOFU)', () async {
      final (Phone a, Phone b) = await twoMembers();
      await a.svc.enableCircle(circle);
      server.circles[circle]!.members.add(uC);
      final Phone c = Phone(server, uC);
      await c.svc.registerThisDevice();
      final PendingReport r = await b.svc.processPending(circle);
      expect(r.wrapped, 0); // b does not hold... actually does after sync
      await b.svc.syncCircleKeys(circle);
      final PendingReport r2 = await b.svc.processPending(circle);
      expect(r2.wrapped, 1);
      expect(await c.svc.syncCircleKeys(circle), 1);
    });

    test('replacement key of a VERIFIED member waits for explicit approval, then confirm', () async {
      final (Phone a, Phone b) = await twoMembers();
      await a.svc.enableCircle(circle);
      await b.svc.syncCircleKeys(circle);
      await a.svc.markVerified(uB); // Alice verified Bob in person

      // Bob loses his phone and resets: a new ROOT, not cross-signed.
      final Phone b2 = Phone(server, uB);
      await b2.svc.registerThisDevice(reset: true);

      PendingReport r = await a.svc.processPending(circle);
      expect(r.wrapped, 0);
      expect(r.waiting.length, 1); // the server says: not approved in this circle
      expect(r.waiting.single.result.reason, contains('approval'));

      // Alice (the admin) compared the safety number and approves.
      await a.svc.approveDevice(circle, r.waiting.single.key);
      r = await a.svc.processPending(circle);
      expect(r.wrapped, 0);
      expect(r.needConfirm.length, 1); // verified member, new key: explicit confirmation
      expect(r.needConfirm.single.result.reason, contains('safety number'));

      await a.svc.confirmWrap(circle, r.needConfirm.single.key, markVerified: true);
      expect(await b2.svc.syncCircleKeys(circle), 1);
      expect(E2ee.hex((await b2.svc.circleKey(circle, 1))!), E2ee.hex((await a.svc.circleKey(circle, 1))!));
      expect(await a.trust.assess(uB, server.activeOf(uB).map((DeviceKey k) => k.fingerprint)), isA<TrustAssessment>()
          .having((TrustAssessment t) => t.level, 'level', TrustLevel.verified));
    });

    test('the server refuses wraps to an unapproved key (client-visible)', () async {
      final (Phone a, _) = await twoMembers();
      await a.svc.enableCircle(circle);
      final Phone b2 = Phone(server, uB);
      await b2.svc.registerThisDevice(reset: true);
      final DeviceKey nb = server.activeOf(uB).single;
      await expectLater(a.svc.confirmWrap(circle, nb), throwsA(anything));
    });

    test('invite anchor: inviter fingerprint from the link must match the server keys', () async {
      final (Phone a, Phone b) = await twoMembers();
      await a.svc.enableCircle(circle);
      final String? fp = await a.svc.inviteFingerprint();
      expect(await b.svc.checkInviter(circle, fp!), uA);
      expect(await b.trust.isVerified(uA), isTrue);
      expect(await b.svc.checkInviter(circle, E2ee.hex(E2ee.randomBytes(32))), isNull);
    });
  });

  group('recovery', () {
    test('phrase -> recovery identity -> new phone gets the circle keys', () async {
      server.circle(circle, members: <String>[uA, uB], admin: uA);
      final Phone a = Phone(server, uA), b = Phone(server, uB);
      await a.svc.registerThisDevice();
      await b.svc.registerThisDevice();
      await a.svc.enableCircle(circle);

      final RecoverySetup setup = a.svc.newRecoverySetup();
      expect(setup.mnemonic.split(' ').length, 24);
      final DeviceKey rec = await a.svc.registerRecovery(setup.entropy);
      expect(rec.isRecovery, isTrue);
      expect(await verifyRegistration(rec), isTrue);
      // The recovery PUBLIC key got a wrap; nothing secret is on the server.
      expect(server.circles[circle]!.wraps.containsKey('1/${rec.deviceId}'), isTrue);

      // Alice's phone is lost: a new phone restores with the phrase.
      final Phone a2 = Phone(server, uA);
      await expectLater(a2.svc.restoreFromPhrase('abandon ' * 23 + 'abandon', circleIds: <String>[circle]), throwsA(isA<E2eeFormatException>())); // checksum
      final List<String> words = setup.mnemonic.split(' ');
      final String wrongOrder = (List<String>.of(words)..setAll(0, words.reversed)).join(' ');
      await expectLater(a2.svc.restoreFromPhrase(wrongOrder, circleIds: <String>[circle]), throwsA(anything));
      final RestoreResult res = await a2.svc.restoreFromPhrase(setup.mnemonic, circleIds: <String>[circle]);
      expect(res.keysRecovered, 1);
      expect(res.failedCircles, isEmpty);
      expect(E2ee.hex((await a2.svc.circleKey(circle, 1))!), E2ee.hex((await a.svc.circleKey(circle, 1))!));
      // The new phone is registered, cross-signed by the recovery key (approved, no admin step).
      final DeviceKey nk = server.activeOf(uA).firstWhere((DeviceKey k) => k.deviceId == (a2.vault.data.isEmpty ? '' : utf8.decode(a2.vault.data['device_id']!)));
      expect(nk.registeredByDeviceId, rec.deviceId);
      expect(await verifyRegistration(nk), isTrue);
    });

    test('wrong passphrase cannot restore; the right one can', () async {
      server.circle(circle, members: <String>[uA], admin: uA);
      final Phone a = Phone(server, uA);
      await a.svc.registerThisDevice();
      await a.svc.enableCircle(circle);
      final RecoverySetup setup = a.svc.newRecoverySetup();
      await a.svc.registerRecovery(setup.entropy, passphrase: 'correct horse');
      final Phone a2 = Phone(server, uA);
      await expectLater(a2.svc.restoreFromPhrase(setup.mnemonic, passphrase: 'wrong', circleIds: <String>[circle]), throwsA(isA<E2eeAuthException>()));
      await expectLater(a2.svc.restoreFromPhrase(setup.mnemonic, circleIds: <String>[circle]), throwsA(isA<E2eeAuthException>()));
      final RestoreResult r = await a2.svc.restoreFromPhrase(setup.mnemonic, passphrase: 'correct horse', circleIds: <String>[circle]);
      expect(r.keysRecovered, 1);
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  group('trust, key change and log', () {
    test('verified member whose keys change raises the loud state', () async {
      final TrustStore t = TrustStore(MemoryTrustKv());
      expect((await t.assess(uB, <String>['aa'])).level, TrustLevel.unseen);
      await t.rememberSeen(uB, <String>['aa']);
      expect((await t.assess(uB, <String>['aa'])).level, TrustLevel.seen);
      expect((await t.assess(uB, <String>['aa', 'bb'])).level, TrustLevel.changed);
      await t.markVerified(uB, <String>['aa']);
      expect((await t.assess(uB, <String>['aa'])).level, TrustLevel.verified);
      final TrustAssessment a = await t.assess(uB, <String>['cc']);
      expect(a.level, TrustLevel.verifiedChanged);
      expect(a.alarming, isTrue);
      expect(a.added, <String>['cc']);
      expect(a.removed, <String>['aa']);
      await t.clearVerified(uB);
      expect((await t.assess(uB, <String>['cc'])).alarming, isFalse);
    });

    test('log: pins the head, accepts growth, detects rollback, fork and forged entries', () async {
      server.circle(circle, members: <String>[uA, uB], admin: uA);
      final Phone a = Phone(server, uA), b = Phone(server, uB);
      await a.svc.registerThisDevice();
      await b.svc.registerThisDevice();
      LogSync s = await b.svc.syncLog();
      expect(s.check.ok, isTrue);
      expect(s.head!.seq, 2);
      final LogHead pinned = (await b.trust.pinnedHead())!;
      expect(pinned.seq, 2);

      await a.svc.enableCircle(circle);
      s = await b.svc.syncLog(userNames: <String, String>{uA: 'Alice'}, circleNames: <String, String>{circle: 'Family'});
      expect(s.check.ok, isTrue);
      expect(s.head!.seq, 3);
      // Alice published epoch 1 and Bob never verified her: a notice.
      expect(s.alarms.map((E2eeAlarm e) => e.kind), contains(AlarmKind.epochByUnverified));

      // Verified admin: no such alarm.
      await b.svc.markVerified(uA);
      await a.svc.bumpEpoch(circle);
      s = await b.svc.syncLog();
      expect(s.alarms.where((E2eeAlarm e) => e.kind == AlarmKind.epochByUnverified), isEmpty);

      // Rollback: the server serves an older, shorter log.
      final LogHead pin = (await b.trust.pinnedHead())!;
      server.logOverride = (entries: <LogEntry>[], head: LogHead(1, server.log[0]['entry_hash'] as Uint8List));
      s = await b.svc.syncLog();
      expect(s.check.problem, LogProblem.rollback);
      expect(s.alarms.single.kind, AlarmKind.logProblem);
      expect((await b.trust.pinnedHead())!.seq, pin.seq); // pin unchanged

      // Fork: same length, but the pinned entry has another hash.
      server.logOverride = null;
      final Map<String, dynamic> saved = Map<String, dynamic>.of(server.log[pin.seq - 1]);
      server.log[pin.seq - 1]['entry_hash'] = E2ee.randomBytes(32);
      s = await b.svc.syncLog();
      expect(s.check.problem, anyOf(LogProblem.fork, LogProblem.badHash));
      server.log[pin.seq - 1] = saved;

      // Forged entry: signature does not verify.
      final Map<String, dynamic> last = server.log.last;
      final Uint8List oldSig = last['sig'] as Uint8List;
      last['sig'] = Uint8List.fromList(oldSig)..[0] ^= 1;
      s = await b.svc.syncLog();
      expect(s.check.problem, LogProblem.badSignature);
      last['sig'] = oldSig;
      expect((await b.svc.syncLog()).check.ok, isTrue);
    });

    test('log: a member resetting all keys raises an alarm (loud when verified)', () async {
      final Phone a = Phone(server, uA), b = Phone(server, uB);
      await a.svc.registerThisDevice();
      await b.svc.registerThisDevice();
      await a.svc.syncLog();
      await a.svc.markVerified(uB);
      final Phone b2 = Phone(server, uB);
      await b2.svc.registerThisDevice(reset: true);
      final LogSync s = await a.svc.syncLog(userNames: <String, String>{uB: 'Bob'});
      expect(s.alarms.single.kind, AlarmKind.verifiedKeyChanged);
      expect(s.alarms.single.severe, isTrue);
    });

    test('compare log head: same history matches, different hash does not', () async {
      final Phone a = Phone(server, uA);
      await a.svc.registerThisDevice();
      final String h = E2ee.hex(server.log.last['entry_hash'] as Uint8List);
      expect(await a.svc.compareHead(1, h), isTrue);
      expect(await a.svc.compareHead(1, '00' * 32), isFalse);
      expect(await a.svc.compareHead(9, h), isNull);
    });
  });

  group('wrap policy', () {
    Future<DeviceKey> keyOf(Phone p) async {
      await p.svc.registerThisDevice();
      return server.activeOf(p.userId).single;
    }

    test('refuses a key whose registration signature is invalid', () async {
      final Phone b = Phone(server, uB);
      final DeviceKey k = await keyOf(b);
      final DeviceKey bad = DeviceKey(deviceId: k.deviceId, userId: k.userId, kind: k.kind, edPub: k.edPub, xPub: E2ee.randomBytes(32),
          fingerprint: k.fingerprint, digits: '', short: '', registeredByDeviceId: k.registeredByDeviceId,
          registeredByPub: k.registeredByPub, registrationAction: k.registrationAction,
          registrationSignature: k.registrationSignature, initial: true, label: '', createdAt: k.createdAt, approved: true);
      final WrapDecisionResult d = await decideWrap(key: bad, selfUserId: uA, trust: TrustStore(MemoryTrustKv()), ownKnownDeviceIds: <String>{});
      expect(d.decision, WrapDecision.refuse);
    });

    test('own cross-signed device is automatic; unknown voucher needs confirmation', () async {
      final Phone a1 = Phone(server, uA);
      final DeviceKey k1 = await keyOf(a1);
      final Phone a2 = Phone(server, uA);
      final String code = await a1.svc.approveLinkRequest(await a1.svc.inspectLinkRequest(await a2.svc.createLinkRequest()));
      final DeviceKey k2 = await a2.svc.registerThisDevice(approval: a2.svc.parseApproval(code));
      final DeviceKey approved = DeviceKey(deviceId: k2.deviceId, userId: k2.userId, kind: k2.kind, edPub: k2.edPub, xPub: k2.xPub,
          fingerprint: k2.fingerprint, digits: '', short: '', registeredByDeviceId: k2.registeredByDeviceId,
          registeredByPub: k2.registeredByPub, registrationAction: k2.registrationAction,
          registrationSignature: k2.registrationSignature, initial: false, label: '', createdAt: k2.createdAt, approved: true);
      expect((await decideWrap(key: approved, selfUserId: uA, trust: a1.trust, ownKnownDeviceIds: <String>{k1.deviceId})).decision, WrapDecision.auto);
      expect((await decideWrap(key: approved, selfUserId: uA, trust: a1.trust, ownKnownDeviceIds: <String>{})).decision, WrapDecision.confirm);
    });
  });
}
