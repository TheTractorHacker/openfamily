import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bip39/bip39.dart' as bip39;
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/e2ee/e2ee_crypto.dart';

// The Go package backend/internal/e2ee generates these vectors; this test
// proves the Dart client produces and accepts byte-identical values.
Map<String, dynamic> _vectors() {
  final File f = File('../backend/internal/e2ee/testdata/vectors.json');
  return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
}

Uint8List h(String s) => E2ee.unhex(s);

void main() {
  final Map<String, dynamic> v = _vectors();
  final Map<String, dynamic> a = v['identity_a'] as Map<String, dynamic>;
  final Map<String, dynamic> b = v['identity_b'] as Map<String, dynamic>;

  group('cross-language vectors (Go -> Dart)', () {
    test('identity derivation, fingerprint, digits, short form, binding', () async {
      for (final Map<String, dynamic> i in <Map<String, dynamic>>[a, b]) {
        final (Uint8List es, Uint8List xs) = await E2ee.deriveIdentity(h(i['Seed']));
        expect(E2ee.hex(es), i['EdSeed']);
        expect(E2ee.hex(xs), i['XSecret']);
        final Uint8List ed = await E2ee.edPublicFromSeed(es);
        final Uint8List x = await E2ee.xPublicFromSecret(xs);
        expect(E2ee.hex(ed), i['EdPub']);
        expect(E2ee.hex(x), i['XPub']);
        final Uint8List fp = await E2ee.fingerprint(ed, x);
        expect(E2ee.hex(fp), i['Fingerprint']);
        expect(await E2ee.digitGroups(fp), i['Digits']);
        expect(E2ee.shortFingerprint(fp), i['Short']);
        final Uint8List m =
            E2ee.bindingMessage(i['UserID'], i['DeviceID'], ed, x);
        expect(E2ee.hex(await E2ee.sign(es, m)), i['BindingSig']);
        expect(await E2ee.verify(ed, m, h(i['BindingSig'])), isTrue);
      }
    });

    test('safety number is symmetric and matches Go', () async {
      final Uint8List fa = h(a['Fingerprint']);
      final Uint8List fb = h(b['Fingerprint']);
      final String ab = await E2ee.safetyNumber(a['UserID'], <Uint8List>[fa], b['UserID'], <Uint8List>[fb]);
      final String ba = await E2ee.safetyNumber(b['UserID'], <Uint8List>[fb], a['UserID'], <Uint8List>[fa]);
      expect(ab, v['safety_number_a_b']);
      expect(ba, ab);
      expect(ab, matches(RegExp(r'^(\d{5} ){11}\d{5}$')));
    });

    test('wrap: Dart reproduces the Go blob and AAD, and opens it', () async {
      final Map<String, dynamic> w = v['wrap_a_to_b'] as Map<String, dynamic>;
      final String circle = v['circle_id'];
      final Uint8List aad = E2ee.wrapAad(circle, v['epoch'], b['DeviceID'], a['DeviceID']);
      expect(E2ee.hex(aad), w['AAD']);
      final Uint8List blob = await E2ee.wrap(h(w['CircleKey']), h(b['XPub']), aad,
          ephemeralSecret: h(w['EphemeralSecret']), nonce: h(w['Nonce']));
      expect(E2ee.hex(blob), w['Blob']);
      expect(blob.length, E2ee.wrapBlobLen);
      final Uint8List sm = E2ee.wrapSigMessage(circle, v['epoch'], b['DeviceID'], a['DeviceID'], blob);
      expect(E2ee.hex(sm), w['SigMessage']);
      expect(E2ee.hex(await E2ee.sign(h(a['EdSeed']), sm)), w['Signature']);
      final Uint8List key = await E2ee.unwrap(h(w['Blob']), h(b['XSecret']), h(b['XPub']), aad);
      expect(E2ee.hex(key), w['CircleKey']);
    });

    test('seal/open payload and padding match Go', () async {
      final Map<String, dynamic> s = v['seal'] as Map<String, dynamic>;
      final Uint8List p = await E2ee.seal(h(v['wrap_a_to_b']['CircleKey']), v['circle_id'],
          v['epoch'], a['DeviceID'], s['Purpose'], h(s['Plaintext']), nonce: h(s['Nonce']));
      expect(E2ee.hex(p), s['Payload']);
      final Uint8List pt = await E2ee.open(
          h(v['wrap_a_to_b']['CircleKey']), v['circle_id'], a['DeviceID'], s['Purpose'], p);
      expect(E2ee.hex(pt), s['Plaintext']);
      expect(E2ee.payloadEpoch(p), 1);
      final Map<String, dynamic> pad = v['padding'] as Map<String, dynamic>;
      expect(E2ee.hex(E2ee.pad(h(pad['Plain']))), pad['Padded']);
      expect(E2ee.hex(E2ee.unpad(h(pad['Padded']))), pad['Plain']);
    });

    test('log action message, signature and chained entry hash match Go', () async {
      final Map<String, dynamic> l = v['log_action'] as Map<String, dynamic>;
      final Uint8List msg = E2ee.logActionMessage(l['Action'], l['UserID'], l['ActorDeviceID'],
          subjectId: l['SubjectID'], ref: h(l['Ref']));
      expect(E2ee.hex(msg), l['Message']);
      expect(E2ee.hex(await E2ee.sign(h(a['EdSeed']), msg)), l['Signature']);
      expect(await E2ee.verify(h(a['EdPub']), msg, h(l['Signature'])), isTrue);
      expect(E2ee.hex(await E2ee.logEntryHash(E2ee.genesisHash, 1, msg, h(l['Signature']))), l['EntryHash']);
    });
  });

  group('recovery phrase', () {
    final Map<String, dynamic> r = v['recovery'] as Map<String, dynamic>;

    test('the fixed 24-word phrase maps to the vector entropy and seed', () async {
      final String phrase = r['Phrase'];
      expect(phrase.split(' ').length, 24);
      expect(bip39.validateMnemonic(phrase), isTrue);
      expect(bip39.mnemonicToEntropy(phrase), r['EntropyHex']);
      final Uint8List seed = await E2ee.recoverySeed(h(r['EntropyHex']));
      expect(E2ee.hex(seed), r['SeedNoPass']);
      final (Uint8List es, Uint8List xs) = await E2ee.recoveryIdentity(seed);
      expect(E2ee.hex(es), r['EdSeed']);
      expect(E2ee.hex(xs), r['XSecret']);
      final Uint8List ed = await E2ee.edPublicFromSeed(es);
      final Uint8List x = await E2ee.xPublicFromSecret(xs);
      expect(E2ee.hex(ed), r['EdPub']);
      expect(E2ee.hex(x), r['XPub']);
      final Uint8List fp = await E2ee.fingerprint(ed, x);
      expect(E2ee.hex(fp), r['Fingerprint']);
      expect(await E2ee.digitGroups(fp), r['Digits']);
    });

    test('Argon2id passphrase seed matches Go; a wrong passphrase differs', () async {
      final Uint8List seed = await E2ee.recoverySeed(h(r['EntropyHex']), passphrase: r['Passphrase']);
      expect(E2ee.hex(seed), r['SeedWithPass']);
      final Uint8List wrong = await E2ee.recoverySeed(h(r['EntropyHex']), passphrase: 'wrong');
      expect(E2ee.hex(wrong), isNot(r['SeedWithPass']));
      expect(E2ee.hex(wrong), isNot(r['SeedNoPass']));
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('bad checksum and bad words are rejected', () {
      final List<String> words = (r['Phrase'] as String).split(' ');
      final List<String> swapped = List<String>.of(words)..[23] = 'abandon';
      expect(bip39.validateMnemonic(swapped.join(' ')), isFalse);
      expect(bip39.validateMnemonic(words.sublist(0, 23).join(' ')), isFalse);
      expect(bip39.validateMnemonic('${words.take(23).join(' ')} notaword'), isFalse);
    });

    test('recovery wrap round trip; tampered wrap and wrong identity fail', () async {
      final Uint8List seed = await E2ee.recoverySeed(h(r['EntropyHex']));
      final (Uint8List _, Uint8List xs) = await E2ee.recoveryIdentity(seed);
      final Uint8List xp = await E2ee.xPublicFromSecret(xs);
      final String circle = v['circle_id'];
      final Uint8List aad = E2ee.wrapAad(circle, 3, b['DeviceID'], a['DeviceID']);
      final Uint8List key = E2ee.randomBytes(32);
      final Uint8List blob = await E2ee.wrap(key, xp, aad);
      expect(E2ee.hex(await E2ee.unwrap(blob, xs, xp, aad)), E2ee.hex(key));
      final Uint8List bad = Uint8List.fromList(blob)..[70] ^= 1;
      await expectLater(E2ee.unwrap(bad, xs, xp, aad), throwsA(isA<E2eeAuthException>()));
      final Uint8List other = await E2ee.recoverySeed(h(r['EntropyHex']), passphrase: 'x');
      final (Uint8List _, Uint8List wxs) = await E2ee.recoveryIdentity(other);
      await expectLater(E2ee.unwrap(blob, wxs, xp, aad), throwsA(isA<E2eeAuthException>()));
    }, timeout: const Timeout(Duration(minutes: 3)));
  });

  group('properties', () {
    test('wrap binds circle, epoch, recipient and wrapper (AAD)', () async {
      final Uint8List sec = E2ee.randomBytes(32);
      final Uint8List pub = await E2ee.xPublicFromSecret(sec);
      final String c = v['circle_id'];
      final Uint8List aad = E2ee.wrapAad(c, 2, b['DeviceID'], a['DeviceID']);
      final Uint8List blob = await E2ee.wrap(E2ee.randomBytes(32), pub, aad);
      for (final Uint8List other in <Uint8List>[
        E2ee.wrapAad(c, 3, b['DeviceID'], a['DeviceID']),
        E2ee.wrapAad(c, 2, a['DeviceID'], a['DeviceID']),
        E2ee.wrapAad(c, 2, b['DeviceID'], b['DeviceID']),
        E2ee.wrapAad('dddddddd-dddd-4ddd-8ddd-dddddddddddd', 2, b['DeviceID'], a['DeviceID']),
      ]) {
        await expectLater(E2ee.unwrap(blob, sec, pub, other), throwsA(isA<E2eeAuthException>()));
      }
      // Fresh randomness each time: two wraps of one key differ.
      final Uint8List key = E2ee.randomBytes(32);
      final Uint8List w1 = await E2ee.wrap(key, pub, aad);
      final Uint8List w2 = await E2ee.wrap(key, pub, aad);
      expect(E2ee.hex(w1), isNot(E2ee.hex(w2)));
    });

    test('low-order recipient keys are refused', () async {
      final Uint8List aad = E2ee.wrapAad(v['circle_id'], 1, b['DeviceID'], a['DeviceID']);
      await expectLater(E2ee.wrap(E2ee.randomBytes(32), Uint8List(32), aad), throwsA(anything));
    });

    test('payload purpose, sender and tampering are bound', () async {
      final Uint8List k = E2ee.randomBytes(32);
      final String c = v['circle_id'];
      final Uint8List p = await E2ee.seal(k, c, 4, a['DeviceID'], 'loc', utf8.encode('x'));
      expect(utf8.decode(await E2ee.open(k, c, a['DeviceID'], 'loc', p)), 'x');
      await expectLater(E2ee.open(k, c, a['DeviceID'], 'place', p), throwsA(isA<E2eeAuthException>()));
      await expectLater(E2ee.open(k, c, b['DeviceID'], 'loc', p), throwsA(isA<E2eeAuthException>()));
      final Uint8List t = Uint8List.fromList(p)..[4] ^= 1;
      await expectLater(E2ee.open(k, c, a['DeviceID'], 'loc', t), throwsA(isA<E2eeAuthException>()));
      final Uint8List p2 = await E2ee.seal(k, c, 4, a['DeviceID'], 'loc', utf8.encode('x'));
      expect(E2ee.hex(p.sublist(5, 29)), isNot(E2ee.hex(p2.sublist(5, 29))));
    });

    test('fingerprint format and key sensitivity', () async {
      final Uint8List fa = await E2ee.fingerprint(h(a['EdPub']), h(a['XPub']));
      final Uint8List swapped = await E2ee.fingerprint(h(a['XPub']), h(a['EdPub']));
      expect(E2ee.hex(fa), isNot(E2ee.hex(swapped)));
      expect(E2ee.shortFingerprint(fa), matches(RegExp(r'^([0-9A-F]{4} ){3}[0-9A-F]{4}$')));
      // Device set order does not matter, membership does.
      final Uint8List fb = h(b['Fingerprint']);
      final String x = await E2ee.safetyNumber(a['UserID'], <Uint8List>[fa, fb], b['UserID'], <Uint8List>[fb]);
      final String y = await E2ee.safetyNumber(a['UserID'], <Uint8List>[fb, fa], b['UserID'], <Uint8List>[fb]);
      final String z = await E2ee.safetyNumber(a['UserID'], <Uint8List>[fa], b['UserID'], <Uint8List>[fb]);
      expect(x, y);
      expect(x, isNot(z));
    });

    test('padding hides size inside buckets and rejects tampering', () {
      expect(E2ee.pad(Uint8List(10)).length, 256);
      expect(E2ee.pad(Uint8List(254)).length, 256);
      expect(E2ee.pad(Uint8List(255)).length, 512);
      expect(E2ee.pad(Uint8List(5000)).length, 8192);
      final Uint8List p = E2ee.pad(Uint8List.fromList(<int>[1, 2, 3]));
      expect(E2ee.unpad(p), <int>[1, 2, 3]);
      p[200] = 1;
      expect(() => E2ee.unpad(p), throwsA(isA<E2eeFormatException>()));
    });

    test('constant-time compare and uuid helpers', () {
      expect(E2ee.constEq(<int>[1, 2], <int>[1, 2]), isTrue);
      expect(E2ee.constEq(<int>[1, 2], <int>[1, 3]), isFalse);
      expect(E2ee.constEq(<int>[1], <int>[1, 2]), isFalse);
      expect(E2ee.newUuid(), matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
      expect(() => E2ee.checkId('NOT-A-UUID'), throwsA(isA<E2eeFormatException>()));
    });
  });
}
