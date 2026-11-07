import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/e2ee/e2ee_crypto.dart';

// Shared vectors for the processing-lanes formats. Go generates
// backend/internal/e2ee/testdata/lanes.json; this test proves the Dart client
// reproduces every positive value and rejects every negative case.
Map<String, dynamic> _load(String f) =>
    jsonDecode(File('../backend/internal/e2ee/testdata/$f').readAsStringSync()) as Map<String, dynamic>;

Uint8List h(String s) => E2ee.unhex(s);

Future<bool> _rejects(Future<Object?> Function() f) async {
  try {
    await f();
    return false;
  } on E2eeFormatException {
    return true;
  } on E2eeAuthException {
    return true;
  }
}

void main() {
  final Map<String, dynamic> v = _load('lanes.json');
  final String circle = v['circle_id'] as String;
  final Map<String, dynamic> sender = v['sender'] as Map<String, dynamic>;
  final Map<String, dynamic> admin = v['admin'] as Map<String, dynamic>;
  final Map<String, dynamic> rcpt = v['recipient'] as Map<String, dynamic>;
  final Map<String, dynamic> neg = v['negative'] as Map<String, dynamic>;
  List<Map<String, dynamic>> list(dynamic x) => (x as List<dynamic>).cast<Map<String, dynamic>>();

  group('lanes vectors (Go -> Dart)', () {
    test('v2 items: seal is byte-identical and open verifies', () async {
      final List<Map<String, dynamic>> items = list(v['items']);
      expect(items, isNotEmpty);
      for (final Map<String, dynamic> it in items) {
        final int line = it['line'] as int;
        final int gen = it['gen'] as int;
        final String purpose = it['purpose'] as String;
        expect(E2ee.hex(E2ee.itemAadV2(circle, line, gen, sender['device_id'], purpose)), it['aad_hex']);
        expect(
            E2ee.hex(E2ee.itemSignedMessageV2(circle, line, gen, sender['device_id'], purpose, it['seq'] as int,
                it['ts_ms'] as int, h(it['body_hex']))),
            it['signed_message_hex']);
        final Uint8List p = await E2ee.sealItemV2(h(it['key_hex']), circle, line, gen, sender['device_id'],
            h(sender['ed_seed_hex']), purpose, it['seq'] as int, it['ts_ms'] as int, h(it['body_hex']),
            nonce: h(it['nonce_hex']));
        expect(E2ee.hex(p), it['payload_hex'], reason: it['name'] as String);
        final PayloadHeader ph = E2ee.parsePayloadHeader(p);
        expect((ph.version, ph.line, ph.gen), (2, line, gen));
        final ItemV2 got = await E2ee.openItemV2(h(it['key_hex']), circle, line, sender['device_id'],
            h(sender['ed_pub_hex']), purpose, it['seq'] as int, h(it['payload_hex']));
        expect(E2ee.hex(got.body), it['body_hex']);
        expect((got.line, got.gen, got.tsMs), (line, gen, it['ts_ms']));
      }
    });

    test('v3 wraps: AAD, signature message, blob, commitment, open', () async {
      for (final Map<String, dynamic> w in list(v['wraps'])) {
        final int line = w['line'] as int;
        final int gen = w['gen'] as int;
        final Uint8List aad = E2ee.wrapAadLine(circle, line, gen, rcpt['device_id'], admin['device_id']);
        expect(E2ee.hex(aad), w['aad_hex']);
        final Uint8List blob = await E2ee.wrap(h(w['key_hex']), h(rcpt['x_pub_hex']), aad,
            ephemeralSecret: h(w['ephemeral_secret_hex']), nonce: h(w['nonce_hex']));
        expect(E2ee.hex(blob), w['blob_hex']);
        final Uint8List sm = E2ee.wrapSigMessageLine(circle, line, gen, rcpt['device_id'], admin['device_id'], blob);
        expect(E2ee.hex(sm), w['sig_message_hex']);
        expect(E2ee.hex(await E2ee.sign(h(admin['ed_seed_hex']), sm)), w['sig_hex']);
        expect(E2ee.hex(await E2ee.keyCommitmentLine(h(w['key_hex']), circle, line, gen)), w['commitment_hex']);
        final Uint8List key = await E2ee.openWrapLine(
            circle,
            rcpt['device_id'],
            h(rcpt['x_secret_hex']),
            h(rcpt['x_pub_hex']),
            LineWrap(
                line: line,
                gen: gen,
                recipientDeviceId: rcpt['device_id'],
                wrapperDeviceId: admin['device_id'],
                wrapperEdPub: h(admin['ed_pub_hex']),
                blob: h(w['blob_hex']),
                signature: h(w['sig_hex'])),
            line,
            gen,
            h(w['commitment_hex']));
        expect(E2ee.hex(key), w['key_hex']);
      }
    });

    test('processing_pref: message, signature, log ref and log action', () async {
      for (final Map<String, dynamic> p in list(v['prefs'])) {
        final int lane = p['lane'] as int;
        final Uint8List m = E2ee.processingPrefMessage(circle, sender['user_id'], lane, p['sk_gen'] as int,
            p['server_device_id'], h(p['server_fingerprint_hex']), h(p['nonce_hex']));
        expect(E2ee.hex(m), p['message_hex']);
        expect(E2ee.hex(await E2ee.sign(h(sender['ed_seed_hex']), m)), p['sig_hex']);
        expect(
            await E2ee.verifyProcessingPref(h(sender['ed_pub_hex']), circle, sender['user_id'], lane, p['sk_gen'] as int,
                p['server_device_id'], h(p['server_fingerprint_hex']), h(p['nonce_hex']), h(p['sig_hex'])),
            isTrue);
        final Uint8List ref = await E2ee.processingRef(m);
        expect(E2ee.hex(ref), p['log_ref_hex']);
        expect(
            E2ee.hex(E2ee.logActionMessage(E2ee.actProcessingPref, sender['user_id'], sender['device_id'],
                circleId: circle,
                subjectId: lane == E2ee.lineServer ? p['server_device_id'] as String : null,
                epoch: p['sk_gen'] as int,
                ref: ref)),
            p['log_action_message_hex']);
      }
    });

    test('processing_policy incl. member_opt_out: both values', () async {
      final Set<int> seen = <int>{};
      for (final Map<String, dynamic> p in list(v['policies'])) {
        seen.add(p['member_opt_out'] as int);
        final Uint8List m = E2ee.processingPolicyMessage(circle, admin['user_id'], p['server_assist'] as bool,
            p['default_for_new'] as int, p['member_opt_out'] as int, p['sk_gen'] as int, h(p['commitment_hex']),
            h(p['nonce_hex']));
        expect(E2ee.hex(m), p['message_hex']);
        expect(E2ee.hex(await E2ee.sign(h(admin['ed_seed_hex']), m)), p['sig_hex']);
        expect(
            await E2ee.verifyProcessingPolicy(h(admin['ed_pub_hex']), circle, admin['user_id'], p['server_assist'] as bool,
                p['default_for_new'] as int, p['member_opt_out'] as int, p['sk_gen'] as int, h(p['commitment_hex']),
                h(p['nonce_hex']), h(p['sig_hex'])),
            isTrue);
        final Uint8List ref = await E2ee.processingRef(m);
        expect(E2ee.hex(ref), p['log_ref_hex']);
        expect(
            E2ee.hex(E2ee.logActionMessage(E2ee.actProcessingPolicy, admin['user_id'], admin['device_id'],
                circleId: circle, epoch: p['sk_gen'] as int, ref: ref)),
            p['log_action_message_hex']);
      }
      expect(seen, <int>{E2ee.optOutAllowed, E2ee.optOutRequiredServer});
      expect(E2ee.parseOptOut('required_server'), 1);
      expect(() => E2ee.parseOptOut('forced'), throwsA(isA<E2eeFormatException>()));
    });

    test('the legacy server-consent vector still verifies (and is not a new-format signature)', () async {
      final Map<String, dynamic> c = _load('server_consent.json');
      final Uint8List msg = E2ee.serverConsentMessage(c['circle_id'], c['user_id'], c['server_device_id'],
          h(c['server_fingerprint_hex']));
      expect(E2ee.hex(msg), c['message_hex']);
      expect(await E2ee.verify(h(c['approver_ed25519_pub_hex']), msg, h(c['signature_hex'])), isTrue);
    });

    test('v1 payloads keep their meaning', () async {
      final Uint8List p = await E2ee.seal(Uint8List(32), circle, 3, sender['device_id'], 'fix', <int>[1, 2, 3]);
      final PayloadHeader ph = E2ee.parsePayloadHeader(p);
      expect((ph.version, ph.line, ph.gen), (1, E2ee.linePhone, 3));
      expect(await _rejects(() => E2ee.openV2(Uint8List(32), circle, 0, sender['device_id'], 'fix', p)), isTrue);
    });
  });

  group('negative vectors must all be rejected', () {
    test('items', () async {
      final List<Map<String, dynamic>> ns = list(neg['items']);
      expect(ns.length, greaterThanOrEqualTo(10));
      for (final Map<String, dynamic> n in ns) {
        expect(
            await _rejects(() => E2ee.openItemV2(h(n['key_hex']), n['circle_id'], n['expect_line'] as int, n['device_id'],
                h(n['sender_pub_hex']), n['purpose'], n['server_seq'] as int, h(n['payload_hex']))),
            isTrue,
            reason: n['name'] as String);
      }
    });

    test('wraps', () async {
      final List<Map<String, dynamic>> ns = list(neg['wraps']);
      expect(ns.length, greaterThanOrEqualTo(8));
      for (final Map<String, dynamic> n in ns) {
        expect(
            await _rejects(() => E2ee.openWrapLine(
                n['circle_id'],
                n['device_id'],
                h(n['x_secret_hex']),
                h(n['x_pub_hex']),
                LineWrap(
                    line: n['wrap_line'] as int,
                    gen: n['wrap_gen'] as int,
                    recipientDeviceId: n['recipient_device_id'],
                    wrapperDeviceId: n['wrapper_device_id'],
                    wrapperEdPub: h(n['wrapper_pub_hex']),
                    blob: h(n['blob_hex']),
                    signature: h(n['sig_hex'])),
                n['want_line'] as int,
                n['want_gen'] as int,
                h(n['commitment_hex']))),
            isTrue,
            reason: n['name'] as String);
      }
    });

    test('processing_pref / consent', () async {
      final List<Map<String, dynamic>> ns = list(neg['prefs']);
      expect(ns.length, greaterThanOrEqualTo(8));
      for (final Map<String, dynamic> n in ns) {
        expect(
            await E2ee.verifyProcessingPref(h(n['approver_pub_hex']), n['circle_id'], n['user_id'], n['lane'] as int,
                n['sk_gen'] as int, n['server_device_id'], h(n['server_fingerprint_hex']), h(n['nonce_hex']),
                h(n['sig_hex'])),
            isFalse,
            reason: n['name'] as String);
      }
    });

    test('processing_policy', () async {
      final List<Map<String, dynamic>> ns = list(neg['policies']);
      expect(ns.length, greaterThanOrEqualTo(10));
      for (final Map<String, dynamic> n in ns) {
        expect(
            await E2ee.verifyProcessingPolicy(h(n['admin_pub_hex']), n['circle_id'], n['admin_user_id'],
                n['server_assist'] as bool, n['default_for_new'] as int, n['member_opt_out'] as int,
                n['sk_gen'] as int, h(n['commitment_hex']), h(n['nonce_hex']), h(n['sig_hex'])),
            isFalse,
            reason: n['name'] as String);
      }
    });
  });

  group('receiver rules', () {
    test('header parsing fails closed', () {
      for (final List<int> bad in <List<int>>[
        <int>[],
        <int>[2],
        <int>[2, 0, 0, 0, 0],
        <int>[2, 9, 0, 0, 0, 1],
        <int>[2, 0, 0, 0, 0, 0],
        <int>[3, 0, 0, 0, 0, 1],
        <int>[1, 0, 0, 0, 0],
      ]) {
        expect(() => E2ee.parsePayloadHeader(bad), throwsA(isA<E2eeFormatException>()));
      }
      expect(() => E2ee.lineName(2), throwsA(isA<E2eeFormatException>()));
    });

    test('CK is never wrapped to a server device', () {
      expect(() => E2ee.checkWrapRecipient(E2ee.linePhone, 'server', policyOn: true, hasServerLaneMember: true),
          throwsA(isA<E2eeFormatException>()));
      expect(() => E2ee.checkWrapRecipient(E2ee.lineServer, 'server', policyOn: true, hasServerLaneMember: false),
          throwsA(isA<E2eeFormatException>()));
      E2ee.checkWrapRecipient(E2ee.lineServer, 'server', policyOn: true, hasServerLaneMember: true);
      E2ee.checkWrapRecipient(E2ee.lineServer, 'phone', policyOn: false, hasServerLaneMember: false);
    });

    test('rollback is tracked per line', () {
      final RollbackGuard g = RollbackGuard();
      const int min = 60000;
      const int now = 1000000000000;
      g.observe(E2ee.linePhone, 2, now);
      g.observe(E2ee.lineServer, 1, now);
      g.observe(E2ee.lineServer, 2, now);
      g.check(E2ee.linePhone, 2, 'a', now + 1, now + 20 * min); // SK gen does not outdate CK
      expect(() => g.check(E2ee.lineServer, 1, 'b', now + min, now + 20 * min), throwsA(isA<E2eeAuthException>()));
      g.check(E2ee.lineServer, 1, 'b', now + min, now + 5 * min); // inside grace
      g.check(E2ee.lineServer, 1, 'c', now - min, now + 20 * min); // backlog
      g.check(E2ee.lineServer, 2, 'a', now + 2 * min, now + 3 * min);
      expect(() => g.check(E2ee.lineServer, 1, 'a', now + 3 * min, now + 4 * min), throwsA(isA<E2eeAuthException>()));
      g.check(E2ee.linePhone, 2, 'a', now + 3 * min, now + 4 * min); // other line unaffected
      expect(() => g.check(5, 1, 'a', 1, now), throwsA(isA<E2eeFormatException>()));
    });

    test('server-line items are flagged unless the author prefers the server then', () {
      const List<PrefEntry> prefs = <PrefEntry>[PrefEntry(1, 1000), PrefEntry(0, 2000), PrefEntry(1, 3000)];
      expect(E2ee.classifyItemLane(prefs, E2ee.linePhone, 5000), LaneVerdict.consistent);
      expect(E2ee.classifyItemLane(prefs, E2ee.lineServer, 500), LaneVerdict.flagged);
      expect(E2ee.classifyItemLane(prefs, E2ee.lineServer, 1500), LaneVerdict.consistent);
      expect(E2ee.classifyItemLane(prefs, E2ee.lineServer, 2500), LaneVerdict.flagged);
      expect(E2ee.classifyItemLane(prefs, E2ee.lineServer, 3500), LaneVerdict.consistent);
      expect(E2ee.classifyItemLane(const <PrefEntry>[], E2ee.lineServer, 10), LaneVerdict.flagged);
      expect(E2ee.classifyItemLane(prefs, 9, 1500), LaneVerdict.flagged);
    });
  });
}
