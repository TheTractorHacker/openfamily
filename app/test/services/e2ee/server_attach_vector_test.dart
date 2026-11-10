import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/e2ee/e2ee_crypto.dart';
import 'package:openfamily/services/e2ee/e2ee_models.dart';
import 'package:openfamily/services/e2ee/e2ee_trust.dart';

// Log action 13 ("server key attached after an owner reset"): the phone signs it, Go verifies it. The message and
// the signature below were produced by the Go side (backend/internal/e2ee LogActionMessage with ActServerAttach and
// ed25519 over a fixed seed of 32 bytes of 0x07), so a drift in either implementation fails here.
const String uOwner = '11111111-1111-4111-8111-111111111111';
const String dNewPhone = '22222222-2222-4222-8222-222222222222';
const String dServer = '33333333-3333-4333-8333-333333333333';

void main() {
  final Uint8List ref = Uint8List.fromList(List<int>.generate(32, (int i) => i));
  test('the Dart message and signature for action 13 equal the Go ones byte for byte', () async {
    final Uint8List msg = E2ee.logActionMessage(E2ee.actServerAttach, uOwner, dNewPhone, subjectId: dServer, ref: ref);
    expect(E2ee.hex(msg),
        '4f4645324545312d4c4f47414354000d31313131313131312d313131312d343131312d383131312d31313131313131313131313132323232323232322d323232322d343232322d383232322d32323232323232323232323230303030303030302d303030302d303030302d303030302d30303030303030303030303033333333333333332d333333332d343333332d383333332d33333333333333333333333300000000000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f');
    final Uint8List seed = Uint8List.fromList(List<int>.filled(32, 7));
    final Uint8List pub = await E2ee.edPublicFromSeed(seed);
    expect(E2ee.hex(pub), 'ea4a6c63e29c520abef5507b132ec5f9954776aebebe7b92421eea691446d22c');
    final Uint8List sig = await E2ee.sign(seed, msg);
    expect(E2ee.hex(sig),
        'e2178d967ae4c309eec4f0abbca94ad4e49f7abfc81dce57534f1bde95e5ff31c88fce11272b32db803cac5e51e32de9c594ba937d4ca078c3aa041fa6113704');
  });

  test('action 14 and 0 are still refused', () {
    expect(() => E2ee.logActionMessage(14, uOwner, dNewPhone, ref: ref), throwsA(isA<E2eeFormatException>()));
    expect(() => E2ee.logActionMessage(0, uOwner, dNewPhone, ref: ref), throwsA(isA<E2eeFormatException>()));
  });

  group('serverKeySurvivedResets', () {
    Future<(List<LogEntry>, DeviceKey, DeviceKey)> world({required bool attach, bool attachByStranger = false, String? wrongSubject, bool attachBeforeReset = false}) async {
      final Uint8List seedOld = Uint8List.fromList(List<int>.filled(32, 1));
      final Uint8List seedNew = Uint8List.fromList(List<int>.filled(32, 2));
      final Uint8List pubOld = await E2ee.edPublicFromSeed(seedOld);
      final Uint8List pubNew = await E2ee.edPublicFromSeed(seedNew);
      final Uint8List fp = Uint8List.fromList(List<int>.generate(32, (int i) => 100 + i));
      final List<LogEntry> log = <LogEntry>[];
      Uint8List prev = E2ee.genesisHash;
      Future<void> add(int action, String actor, Uint8List seed, Uint8List pub, String subject, Uint8List r, {String user = uOwner}) async {
        final Uint8List msg = E2ee.logActionMessage(action, user, actor, subjectId: subject, ref: r);
        final Uint8List sig = await E2ee.sign(seed, msg);
        final int seq = log.length + 1;
        final Uint8List h = await E2ee.logEntryHash(prev, seq, msg, sig);
        log.add(LogEntry(
            seq: seq, prevHash: prev, entryHash: h, redacted: false, action: action, userId: user, actorDeviceId: actor, actorPub: pub,
            subjectId: subject, epoch: 0, ref: r, signature: sig));
        prev = h;
      }

      const String dOld = '44444444-4444-4444-8444-444444444444';
      await add(E2ee.actRegister, dOld, seedOld, pubOld, dOld, Uint8List(32));
      await add(E2ee.actRegister, dOld, seedOld, pubOld, dServer, fp);
      if (attachBeforeReset) await add(E2ee.actServerAttach, dNewPhone, seedNew, pubNew, dServer, fp);
      await add(E2ee.actReset, dNewPhone, seedNew, pubNew, dNewPhone, Uint8List(32));
      if (attach) {
        await add(E2ee.actServerAttach, dNewPhone, seedNew, pubNew, wrongSubject ?? dServer, fp);
      }
      DeviceKey key(String id, String kind, Uint8List pub, {bool active = true, String user = uOwner, bool? approved = true}) => DeviceKey(
          deviceId: id, userId: user, kind: kind, edPub: pub, xPub: pub, fingerprint: id == dServer ? E2ee.hex(fp) : 'aa', digits: '', short: '',
          registeredByDeviceId: dOld, registeredByPub: pubOld, registrationAction: E2ee.actRegister, registrationSignature: Uint8List(64), initial: false,
          label: '', createdAt: DateTime.utc(2026), revokedAt: active ? null : DateTime.utc(2026, 2), approved: approved);
      final DeviceKey srv = key(dServer, 'server', pubOld);
      final DeviceKey phone = key(dNewPhone, 'device', pubNew, user: attachByStranger ? 'ffffffff-ffff-4fff-8fff-ffffffffffff' : uOwner);
      return (log, srv, phone);
    }

    test('registered before the reset: kept only with the new phone\'s attach', () async {
      var (List<LogEntry> log, DeviceKey srv, DeviceKey phone) = await world(attach: true);
      final Map<String, DeviceKey> by = <String, DeviceKey>{dNewPhone: phone, dServer: srv};
      expect(serverKeySurvivedResets(log, srv, by, <String>{uOwner}), isTrue);
      (log, srv, phone) = await world(attach: false);
      expect(serverKeySurvivedResets(log, srv, <String, DeviceKey>{dNewPhone: phone, dServer: srv}, <String>{uOwner}), isFalse, reason: 'a reset retired it');
    });

    test('negative: attach before the reset, for another key, by a stranger or an unapproved/revoked phone, or the owner is not an admin', () async {
      var (List<LogEntry> log, DeviceKey srv, DeviceKey phone) = await world(attach: false, attachBeforeReset: true);
      expect(serverKeySurvivedResets(log, srv, <String, DeviceKey>{dNewPhone: phone}, <String>{uOwner}), isFalse, reason: 'must come after the reset');
      (log, srv, phone) = await world(attach: true, wrongSubject: '55555555-5555-4555-8555-555555555555');
      expect(serverKeySurvivedResets(log, srv, <String, DeviceKey>{dNewPhone: phone}, <String>{uOwner}), isFalse);
      (log, srv, phone) = await world(attach: true, attachByStranger: true);
      expect(serverKeySurvivedResets(log, srv, <String, DeviceKey>{dNewPhone: phone}, <String>{uOwner}), isFalse, reason: 'actor is another user');
      (log, srv, phone) = await world(attach: true);
      expect(serverKeySurvivedResets(log, srv, <String, DeviceKey>{}, <String>{uOwner}), isFalse, reason: 'actor not listed (revoked or unknown)');
      expect(serverKeySurvivedResets(log, srv, <String, DeviceKey>{dNewPhone: phone}, <String>{}), isFalse, reason: 'the key\'s user is no admin of the circle');
      final DeviceKey unapproved = DeviceKey(
          deviceId: phone.deviceId, userId: phone.userId, kind: 'device', edPub: phone.edPub, xPub: phone.xPub, fingerprint: 'aa', digits: '', short: '',
          registeredByDeviceId: phone.deviceId, registeredByPub: phone.edPub, registrationAction: E2ee.actReset, registrationSignature: Uint8List(64),
          initial: false, label: '', createdAt: DateTime.utc(2026), approved: false);
      expect(serverKeySurvivedResets(log, srv, <String, DeviceKey>{dNewPhone: unapproved}, <String>{uOwner}), isFalse);
    });

    test('a server key registered after the reset needs no attach', () async {
      final Uint8List seed = Uint8List.fromList(List<int>.filled(32, 2));
      final Uint8List pub = await E2ee.edPublicFromSeed(seed);
      final Uint8List fp = Uint8List(32);
      final List<LogEntry> log = <LogEntry>[];
      Uint8List prev = E2ee.genesisHash;
      for (final (int, String) a in <(int, String)>[(E2ee.actReset, dNewPhone), (E2ee.actRegister, dServer)]) {
        final Uint8List msg = E2ee.logActionMessage(a.$1, uOwner, dNewPhone, subjectId: a.$2, ref: fp);
        final Uint8List sig = await E2ee.sign(seed, msg);
        final Uint8List h = await E2ee.logEntryHash(prev, log.length + 1, msg, sig);
        log.add(LogEntry(seq: log.length + 1, prevHash: prev, entryHash: h, redacted: false, action: a.$1, userId: uOwner, actorDeviceId: dNewPhone, actorPub: pub, subjectId: a.$2, epoch: 0, ref: fp, signature: sig));
        prev = h;
      }
      final DeviceKey srv = DeviceKey(
          deviceId: dServer, userId: uOwner, kind: 'server', edPub: pub, xPub: pub, fingerprint: E2ee.hex(fp), digits: '', short: '',
          registeredByDeviceId: dNewPhone, registeredByPub: pub, registrationAction: E2ee.actRegister, registrationSignature: Uint8List(64),
          initial: false, label: '', createdAt: DateTime.utc(2026), approved: true);
      expect(serverKeySurvivedResets(log, srv, <String, DeviceKey>{}, <String>{uOwner}), isTrue);
    });
  });
}
