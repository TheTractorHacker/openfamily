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

  group('serverKeyVouched (the phone checks the chain itself, never the server\'s say-so)', () {
    const String dOld = '44444444-4444-4444-8444-444444444444';
    const String uAdmin = '66666666-6666-4666-8666-666666666666';
    Uint8List seedOf(int n) => Uint8List.fromList(List<int>.filled(32, n));

    /// A key with a REAL registration signature by [voucherSeed] (the key's own seed when it is a root).
    Future<DeviceKey> mk(String id, String kind, int seedN, {String? voucher, int? voucherSeedN, int action = E2ee.actRegister, String user = uOwner, DateTime? at}) async {
      final Uint8List seed = seedOf(seedN), ed = await E2ee.edPublicFromSeed(seed);
      final Uint8List x = await E2ee.edPublicFromSeed(seedOf(seedN + 50));
      final Uint8List fp = await E2ee.fingerprint(ed, x);
      final String by = voucher ?? id;
      final Uint8List bySeed = seedOf(voucherSeedN ?? seedN);
      final Uint8List sig = await E2ee.sign(bySeed, E2ee.logActionMessage(action, user, by, subjectId: id, ref: fp));
      return DeviceKey(
          deviceId: id, userId: user, kind: kind, edPub: ed, xPub: x, fingerprint: E2ee.hex(fp), digits: '', short: '', registeredByDeviceId: by,
          registeredByPub: await E2ee.edPublicFromSeed(bySeed), registrationAction: action, registrationSignature: sig, initial: false, label: '',
          createdAt: at ?? DateTime.utc(2026), approved: true);
    }

    Future<LogEntry> entry(List<LogEntry> log, int action, String user, String actor, int actorSeedN, String subject, Uint8List ref, {bool redacted = false}) async {
      final Uint8List seed = seedOf(actorSeedN);
      final Uint8List msg = E2ee.logActionMessage(action, user, actor, subjectId: subject, ref: ref);
      final Uint8List sig = await E2ee.sign(seed, msg);
      final Uint8List prev = log.isEmpty ? E2ee.genesisHash : log.last.entryHash;
      final Uint8List h = await E2ee.logEntryHash(prev, log.length + 1, msg, sig);
      final LogEntry e = redacted
          ? LogEntry(seq: log.length + 1, prevHash: prev, entryHash: h, redacted: true)
          : LogEntry(
              seq: log.length + 1, prevHash: prev, entryHash: h, redacted: false, action: action, userId: user, actorDeviceId: actor,
              actorPub: await E2ee.edPublicFromSeed(seed), subjectId: subject, epoch: 0, ref: ref, signature: sig);
      log.add(e);
      return e;
    }

    Uint8List fpOf(DeviceKey k) => E2ee.unhex(k.fingerprint);
    Map<String, DeviceKey> by(List<DeviceKey> l) => <String, DeviceKey>{for (final DeviceKey k in l) k.deviceId: k};

    /// Old phone (root, seed 1) approved the server key (seed 3); logged honestly.
    Future<({List<LogEntry> log, DeviceKey old, DeviceKey srv})> plain() async {
      final DeviceKey old = await mk(dOld, 'device', 1);
      final DeviceKey srv = await mk(dServer, 'server', 3, voucher: dOld, voucherSeedN: 1);
      final List<LogEntry> log = <LogEntry>[];
      await entry(log, E2ee.actRegister, uOwner, dOld, 1, dOld, fpOf(old));
      await entry(log, E2ee.actRegister, uOwner, dOld, 1, dServer, fpOf(srv));
      return (log: log, old: old, srv: srv);
    }

    test('a key an approved owner phone signed into the log is the server key', () async {
      final w = await plain();
      expect(await serverKeyVouched(w.log, w.srv, by(<DeviceKey>[w.old, w.srv])), isTrue);
    });

    test('negative: no logged registration, a redacted one, a swapped fingerprint or voucher key, an unlisted voucher', () async {
      final w = await plain();
      final Map<String, DeviceKey> all = by(<DeviceKey>[w.old, w.srv]);
      // The server invents a key: nothing in the log.
      final DeviceKey fake = await mk('77777777-7777-4777-8777-777777777777', 'server', 9, voucher: dOld, voucherSeedN: 1);
      expect(await serverKeyVouched(w.log, fake, <String, DeviceKey>{...all, fake.deviceId: fake}), isFalse, reason: 'unlogged');
      // The entry is there but redacted.
      final List<LogEntry> red = <LogEntry>[w.log[0], LogEntry(seq: 2, prevHash: w.log[0].entryHash, entryHash: w.log[1].entryHash, redacted: true)];
      expect(await serverKeyVouched(red, w.srv, all), isFalse, reason: 'redacted registration');
      // The listed fingerprint is not the logged one.
      final DeviceKey swapped = DeviceKey(
          deviceId: w.srv.deviceId, userId: uOwner, kind: 'server', edPub: w.srv.edPub, xPub: w.srv.xPub, fingerprint: E2ee.hex(Uint8List(32)),
          digits: '', short: '', registeredByDeviceId: dOld, registeredByPub: w.srv.registeredByPub, registrationAction: E2ee.actRegister,
          registrationSignature: w.srv.registrationSignature, initial: false, label: '', createdAt: DateTime.utc(2026), approved: true);
      expect(await serverKeyVouched(w.log, swapped, all), isFalse, reason: 'fingerprint swapped');
      // The server picks the voucher key: the signature is by an attacker key, not the logged phone.
      final DeviceKey evilVoucher = await mk(dServer, 'server', 3, voucher: dOld, voucherSeedN: 66);
      expect(await serverKeyVouched(w.log, evilVoucher, all), isFalse, reason: 'voucher key chosen by the server');
      // The voucher is not listed.
      expect(await serverKeyVouched(w.log, w.srv, by(<DeviceKey>[w.srv])), isFalse, reason: 'voucher unknown');
      // A self-registered "server" key has no owner device behind it.
      final DeviceKey selfSrv = await mk('88888888-8888-4888-8888-888888888888', 'server', 8);
      final List<LogEntry> l2 = <LogEntry>[];
      await entry(l2, E2ee.actRegister, uOwner, selfSrv.deviceId, 8, selfSrv.deviceId, fpOf(selfSrv));
      expect(await serverKeyVouched(l2, selfSrv, by(<DeviceKey>[selfSrv])), isFalse, reason: 'a root cannot be a server key');
      // A voucher of another account.
      final DeviceKey stranger = await mk('99999999-9999-4999-8999-999999999999', 'device', 5, user: uAdmin);
      final DeviceKey srv2 = await mk('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'server', 6, voucher: stranger.deviceId, voucherSeedN: 5);
      final List<LogEntry> l3 = <LogEntry>[];
      await entry(l3, E2ee.actRegister, uAdmin, stranger.deviceId, 5, stranger.deviceId, fpOf(stranger));
      await entry(l3, E2ee.actRegister, uOwner, stranger.deviceId, 5, srv2.deviceId, fpOf(srv2));
      expect(await serverKeyVouched(l3, srv2, by(<DeviceKey>[stranger, srv2])), isFalse, reason: 'voucher belongs to another user');
    });

    /// plain() plus an owner reset by the new root phone (seed 2), optionally the attach.
    Future<({List<LogEntry> log, DeviceKey old, DeviceKey srv, DeviceKey fresh})> afterReset({bool attach = false, bool redactReset = false, bool listFresh = true, int attachBy = 2}) async {
      final w = await plain();
      final DeviceKey fresh = await mk(dNewPhone, 'device', 2, action: E2ee.actReset, at: DateTime.utc(2026, 2));
      final List<LogEntry> log = <LogEntry>[...w.log];
      await entry(log, E2ee.actReset, uOwner, dNewPhone, 2, dNewPhone, fpOf(fresh), redacted: redactReset);
      if (attach) await entry(log, E2ee.actServerAttach, uOwner, dNewPhone, attachBy, dServer, fpOf(w.srv));
      return (log: log, old: w.old, srv: w.srv, fresh: fresh);
    }

    test('after an owner reset: kept only with the new root phone\'s attach', () async {
      var w = await afterReset(attach: true);
      expect(await serverKeyVouched(w.log, w.srv, by(<DeviceKey>[w.fresh, w.srv])), isTrue);
      w = await afterReset();
      expect(await serverKeyVouched(w.log, w.srv, by(<DeviceKey>[w.fresh, w.srv])), isFalse, reason: 'a reset retired it');
    });

    test('negative: a reset the server serves redacted does not bring the key back', () async {
      final w = await afterReset(redactReset: true);
      // The list still shows the owner\'s reset root phone created after the key: the attach is required.
      expect(await serverKeyVouched(w.log, w.srv, by(<DeviceKey>[w.fresh, w.srv])), isFalse);
    });

    test('negative: attach by a stranger, for another key, before the reset, by an unapproved or non-root phone', () async {
      final w = await afterReset(attach: true);
      final Map<String, DeviceKey> ok = by(<DeviceKey>[w.fresh, w.srv]);
      // attach signed with the wrong seed: the log entry names the new phone but another key signed it (entry signature is
      // checked by verifyLogSlice; the actor key must also equal the listed one).
      final List<LogEntry> bad = <LogEntry>[...w.log.sublist(0, 3), await _forgedAttach(w.log[2].entryHash, w.srv)];
      expect(await serverKeyVouched(bad, w.srv, ok), isFalse, reason: 'actor key differs from the listed phone');
      // for another subject
      final List<LogEntry> other = <LogEntry>[...w.log.sublist(0, 3)];
      await entry(other, E2ee.actServerAttach, uOwner, dNewPhone, 2, '55555555-5555-4555-8555-555555555555', fpOf(w.srv));
      expect(await serverKeyVouched(other, w.srv, ok), isFalse);
      // before the reset
      final List<LogEntry> early = <LogEntry>[...w.log.sublist(0, 2)];
      await entry(early, E2ee.actServerAttach, uOwner, dNewPhone, 2, dServer, fpOf(w.srv));
      await entry(early, E2ee.actReset, uOwner, dNewPhone, 2, dNewPhone, fpOf(w.fresh));
      expect(await serverKeyVouched(early, w.srv, ok), isFalse, reason: 'must come after the reset');
      // the new phone is not listed / is revoked / is not approved
      expect(await serverKeyVouched(w.log, w.srv, by(<DeviceKey>[w.srv])), isFalse);
      final DeviceKey unapproved = DeviceKey(
          deviceId: w.fresh.deviceId, userId: uOwner, kind: 'device', edPub: w.fresh.edPub, xPub: w.fresh.xPub, fingerprint: w.fresh.fingerprint, digits: '',
          short: '', registeredByDeviceId: w.fresh.deviceId, registeredByPub: w.fresh.edPub, registrationAction: E2ee.actReset,
          registrationSignature: w.fresh.registrationSignature, initial: false, label: '', createdAt: w.fresh.createdAt, approved: false);
      expect(await serverKeyVouched(w.log, w.srv, by(<DeviceKey>[unapproved, w.srv])), isFalse);
      // a second, newer reset root exists whose phone did not attach: the older root's attach no longer counts
      final DeviceKey newer = await mk('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'device', 12, action: E2ee.actReset, at: DateTime.utc(2026, 3));
      final List<LogEntry> twice = <LogEntry>[...w.log];
      await entry(twice, E2ee.actReset, uOwner, newer.deviceId, 12, newer.deviceId, fpOf(newer));
      expect(await serverKeyVouched(twice, w.srv, by(<DeviceKey>[w.fresh, newer, w.srv])), isFalse);
    });

    test('a server key registered after the latest reset needs no attach', () async {
      final DeviceKey fresh = await mk(dNewPhone, 'device', 2, action: E2ee.actReset, at: DateTime.utc(2026, 2));
      final DeviceKey srv = await mk(dServer, 'server', 3, voucher: dNewPhone, voucherSeedN: 2, at: DateTime.utc(2026, 3));
      final List<LogEntry> log = <LogEntry>[];
      await entry(log, E2ee.actReset, uOwner, dNewPhone, 2, dNewPhone, fpOf(fresh));
      await entry(log, E2ee.actRegister, uOwner, dNewPhone, 2, dServer, fpOf(srv));
      expect(await serverKeyVouched(log, srv, by(<DeviceKey>[fresh, srv])), isTrue);
    });

    test('in a circle the key must belong to an admin or carry a logged admin approval', () async {
      // A member (not an admin) makes a server key with their own phone; a lying server pins it.
      final DeviceKey phone = await mk(dOld, 'device', 1, user: uAdmin);
      final DeviceKey srv = await mk(dServer, 'server', 3, voucher: dOld, voucherSeedN: 1, user: uAdmin);
      final List<LogEntry> log = <LogEntry>[];
      await entry(log, E2ee.actRegister, uAdmin, dOld, 1, dOld, fpOf(phone));
      await entry(log, E2ee.actRegister, uAdmin, dOld, 1, dServer, fpOf(srv));
      final Map<String, DeviceKey> all = by(<DeviceKey>[phone, srv]);
      const String circle = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
      expect(await serverKeyVouched(log, srv, all, admins: <String>{uOwner}, circleId: circle), isFalse, reason: 'owner is no admin, nobody approved it');
      expect(await serverKeyVouched(log, srv, all, admins: <String>{uAdmin}, circleId: circle), isTrue, reason: 'owner is an admin');
      // An admin of the circle (another account) signed the approval for this circle.
      final DeviceKey adminPhone = await mk('dddddddd-dddd-4ddd-8ddd-dddddddddddd', 'device', 20, user: uOwner);
      final List<LogEntry> l2 = <LogEntry>[...log];
      final Uint8List msg = E2ee.logActionMessage(E2ee.actApprove, uOwner, adminPhone.deviceId, circleId: circle, subjectId: dServer, ref: fpOf(srv));
      final Uint8List sig = await E2ee.sign(seedOf(20), msg);
      l2.add(LogEntry(
          seq: 3, prevHash: l2.last.entryHash, entryHash: await E2ee.logEntryHash(l2.last.entryHash, 3, msg, sig), redacted: false,
          action: E2ee.actApprove, userId: uOwner, actorDeviceId: adminPhone.deviceId, actorPub: adminPhone.edPub, circleId: circle,
          subjectId: dServer, epoch: 0, ref: fpOf(srv), signature: sig));
      expect(await serverKeyVouched(l2, srv, <String, DeviceKey>{...all, adminPhone.deviceId: adminPhone}, admins: <String>{uOwner}, circleId: circle), isTrue);
      expect(await serverKeyVouched(l2, srv, <String, DeviceKey>{...all, adminPhone.deviceId: adminPhone}, admins: <String>{uOwner}, circleId: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'), isFalse,
          reason: 'an approval for another circle does not count');
    });
  });
}

Future<LogEntry> _forgedAttach(Uint8List prev, DeviceKey srv) async {
  // Names the new phone as actor but is signed by another key.
  final Uint8List seed = Uint8List.fromList(List<int>.filled(32, 77));
  final Uint8List msg = E2ee.logActionMessage(E2ee.actServerAttach, uOwner, dNewPhone, subjectId: dServer, ref: E2ee.unhex(srv.fingerprint));
  final Uint8List sig = await E2ee.sign(seed, msg);
  return LogEntry(
      seq: 4, prevHash: prev, entryHash: await E2ee.logEntryHash(prev, 4, msg, sig), redacted: false, action: E2ee.actServerAttach, userId: uOwner,
      actorDeviceId: dNewPhone, actorPub: await E2ee.edPublicFromSeed(seed), subjectId: dServer, epoch: 0, ref: E2ee.unhex(srv.fingerprint), signature: sig);
}
