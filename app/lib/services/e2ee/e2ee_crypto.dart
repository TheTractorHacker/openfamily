import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// OpenFamily end-to-end encryption primitives (docs/design/E2EE.md).
///
/// Every byte format here is frozen and mirrored by
/// backend/internal/e2ee; both sides are checked against
/// backend/internal/e2ee/testdata/vectors.json. Private keys and circle keys
/// exist only in this process: nothing in this file does I/O.
class E2eeFormatException implements Exception {
  const E2eeFormatException(this.message);
  final String message;
  @override
  String toString() => 'E2eeFormatException: $message';
}

/// Decryption / signature failures carry no detail on purpose.
class E2eeAuthException implements Exception {
  const E2eeAuthException([this.message = 'authentication failed']);
  final String message;
  @override
  String toString() => 'E2eeAuthException: $message';
}

typedef Bytes = List<int>;

class E2ee {
  E2ee._();

  static const int pubLen = 32;
  static const int sigLen = 64;
  static const int keyLen = 32;
  static const int nonceLen = 24;
  static const int tagLen = 16;
  static const int wrapVersion = 1;
  static const int wrapBlobLen = 1 + 32 + 24 + 32 + 16; // 105
  static const int msgVersion = 1;
  static const String zeroUuid = '00000000-0000-0000-0000-000000000000';

  // Log action codes (must equal e2ee.Act* in Go).
  static const int actRegister = 1;
  static const int actRotate = 2;
  static const int actRevoke = 3;
  static const int actRecovery = 4;
  static const int actEnable = 5;
  static const int actEpoch = 6;
  static const int actDisable = 7;
  static const int actReset = 8;
  static const int actApprove = 9;

  // Argon2id parameters for the optional recovery passphrase.
  static const int argon2MemKiB = 32 * 1024;
  static const int argon2Iterations = 3;
  static const int argon2Lanes = 1;

  static final Ed25519 _ed = Ed25519();
  static final X25519 _x = X25519();
  static final Xchacha20 _aead = Xchacha20.poly1305Aead();
  static final Sha256 _sha256 = Sha256();
  static final Sha512 _sha512 = Sha512();
  static final Random _rng = Random.secure();

  /// Cryptographically secure random bytes (OS CSPRNG).
  static Uint8List randomBytes(int n) {
    final Uint8List b = Uint8List(n);
    for (int i = 0; i < n; i++) {
      b[i] = _rng.nextInt(256);
    }
    return b;
  }

  /// A random version-4 UUID in canonical lower-case form.
  static String newUuid() {
    final Uint8List b = randomBytes(16);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final String h = hex(b);
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
        '${h.substring(16, 20)}-${h.substring(20)}';
  }

  static final RegExp _uuidRe = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

  /// Identifiers enter signed messages as ASCII, so there is one encoding.
  static void checkId(String id) {
    if (!_uuidRe.hasMatch(id)) {
      throw const E2eeFormatException('identifier must be a lower-case UUID');
    }
  }

  static String hex(Bytes b) {
    final StringBuffer sb = StringBuffer();
    for (final int v in b) {
      sb.write(v.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  static Uint8List unhex(String s) {
    if (s.length.isOdd) throw const E2eeFormatException('odd hex length');
    final Uint8List out = Uint8List(s.length ~/ 2);
    for (int i = 0; i < out.length; i++) {
      out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  static String b64(Bytes b) => base64.encode(b);
  static Uint8List unb64(String s) => Uint8List.fromList(base64.decode(s));

  /// Constant-time equality (no early exit on the first differing byte).
  static bool constEq(Bytes a, Bytes b) {
    if (a.length != b.length) return false;
    int d = 0;
    for (int i = 0; i < a.length; i++) {
      d |= a[i] ^ b[i];
    }
    return d == 0;
  }

  static Uint8List cat(List<Bytes> parts) {
    final BytesBuilder bb = BytesBuilder(copy: false);
    for (final Bytes p in parts) {
      bb.add(p);
    }
    return bb.toBytes();
  }

  static Uint8List _ascii(String s) => Uint8List.fromList(ascii.encode(s));
  static Uint8List _dom(String s) => Uint8List.fromList(utf8.encode('$s\x00'));

  static Uint8List u32(int v) {
    final ByteData d = ByteData(4)..setUint32(0, v, Endian.big);
    return d.buffer.asUint8List();
  }

  static Uint8List u64(int v) {
    final ByteData d = ByteData(8)..setUint64(0, v, Endian.big);
    return d.buffer.asUint8List();
  }

  static Future<Uint8List> sha256(Bytes data) async =>
      Uint8List.fromList((await _sha256.hash(data)).bytes);

  static Future<Uint8List> _sha512Of(Bytes data) async =>
      Uint8List.fromList((await _sha512.hash(data)).bytes);

  /// HKDF-SHA256. [salt] empty means the RFC 5869 default (zeros).
  static Future<Uint8List> hkdf(Bytes ikm, Bytes salt, Bytes info, int length) async {
    final Hkdf h = Hkdf(hmac: Hmac.sha256(), outputLength: length);
    final SecretKey k = await h.deriveKey(
        secretKey: SecretKey(ikm), nonce: salt, info: info);
    return Uint8List.fromList(await k.extractBytes());
  }

  // ------------------------------------------------------------ identity

  /// Expands the 32-byte device identity seed into the Ed25519 seed and the
  /// X25519 secret (HKDF-SHA256, labels "OFE2EE1-IDENTITY-...").
  static Future<(Uint8List edSeed, Uint8List xSecret)> deriveIdentity(
      Bytes seed) async {
    if (seed.length != 32) {
      throw const E2eeFormatException('identity seed must be 32 bytes');
    }
    final Uint8List ed =
        await hkdf(seed, const <int>[], utf8.encode('OFE2EE1-IDENTITY-ED25519'), 32);
    final Uint8List x =
        await hkdf(seed, const <int>[], utf8.encode('OFE2EE1-IDENTITY-X25519'), 32);
    return (ed, x);
  }

  static Future<Uint8List> edPublicFromSeed(Bytes edSeed) async {
    final SimpleKeyPair kp = await _ed.newKeyPairFromSeed(edSeed);
    return Uint8List.fromList((await kp.extractPublicKey()).bytes);
  }

  static Future<Uint8List> xPublicFromSecret(Bytes xSecret) async {
    final SimpleKeyPair kp = await _x.newKeyPairFromSeed(xSecret);
    return Uint8List.fromList((await kp.extractPublicKey()).bytes);
  }

  static Future<Uint8List> sign(Bytes edSeed, Bytes message) async {
    final SimpleKeyPair kp = await _ed.newKeyPairFromSeed(edSeed);
    return Uint8List.fromList((await _ed.sign(message, keyPair: kp)).bytes);
  }

  static Future<bool> verify(Bytes edPub, Bytes message, Bytes sig) async {
    if (edPub.length != pubLen || sig.length != sigLen) return false;
    try {
      return await _ed.verify(message,
          signature: Signature(sig,
              publicKey: SimplePublicKey(edPub, type: KeyPairType.ed25519)));
    } catch (_) {
      return false;
    }
  }

  // ---------------------------------------------------- fingerprint, digits

  /// SHA-256("OFE2EE1-FP\0" || ed25519_pub || x25519_pub).
  static Future<Uint8List> fingerprint(Bytes edPub, Bytes xPub) {
    if (edPub.length != pubLen || xPub.length != pubLen) {
      throw const E2eeFormatException('public keys must be 32 bytes');
    }
    return sha256(cat(<Bytes>[_dom('OFE2EE1-FP'), edPub, xPub]));
  }

  static String _digits(Bytes sum) {
    final List<String> groups = <String>[];
    for (int i = 0; i < 12; i++) {
      int v = 0;
      for (int j = 0; j < 5; j++) {
        v = (v << 8) | sum[i * 5 + j];
      }
      groups.add((v % 100000).toString().padLeft(5, '0'));
    }
    return groups.join(' ');
  }

  /// 12 groups of 5 digits from SHA-512("OFE2EE1-DIGITS\0" || fingerprint).
  static Future<String> digitGroups(Bytes fp) async =>
      _digits(await _sha512Of(cat(<Bytes>[_dom('OFE2EE1-DIGITS'), fp])));

  /// Glance form: 4 groups of 4 upper-case hex characters.
  static String shortFingerprint(Bytes fp) {
    final String h = hex(fp.sublist(0, 8)).toUpperCase();
    return '${h.substring(0, 4)} ${h.substring(4, 8)} '
        '${h.substring(8, 12)} ${h.substring(12, 16)}';
  }

  static int _cmp(Bytes a, Bytes b) {
    for (int i = 0; i < a.length && i < b.length; i++) {
      if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
    }
    return a.length.compareTo(b.length);
  }

  /// SHA-256("OFE2EE1-USER\0" || user_id || sorted distinct fingerprints).
  static Future<Uint8List> userDigest(String userId, List<Bytes> fps) {
    final List<Bytes> sorted = List<Bytes>.of(fps)..sort(_cmp);
    final List<Bytes> parts = <Bytes>[_dom('OFE2EE1-USER'), _ascii(userId)];
    Bytes? prev;
    for (final Bytes f in sorted) {
      if (prev != null && _cmp(prev, f) == 0) continue;
      parts.add(f);
      prev = f;
    }
    return sha256(cat(parts));
  }

  /// Symmetric 12x5 digit safety number of two users.
  static Future<String> safetyNumber(
      String userA, List<Bytes> fpsA, String userB, List<Bytes> fpsB) async {
    Uint8List a = await userDigest(userA, fpsA);
    Uint8List b = await userDigest(userB, fpsB);
    if (_cmp(a, b) > 0) {
      final Uint8List t = a;
      a = b;
      b = t;
    }
    return _digits(await _sha512Of(cat(<Bytes>[_dom('OFE2EE1-SAFETY'), a, b])));
  }

  // ------------------------------------------------- signed message formats

  static Uint8List bindingMessage(
      String userId, String deviceId, Bytes edPub, Bytes xPub) {
    checkId(userId);
    checkId(deviceId);
    return cat(<Bytes>[
      _dom('OFE2EE1-BIND'), _ascii(userId), _ascii(deviceId), edPub, xPub
    ]);
  }

  static Uint8List logActionMessage(int action, String userId, String actorId,
      {String? circleId, String? subjectId, int epoch = 0, Bytes? ref}) {
    final String c = circleId ?? zeroUuid;
    final String s = subjectId ?? zeroUuid;
    for (final String id in <String>[userId, actorId, c, s]) {
      checkId(id);
    }
    final Bytes r = ref ?? Uint8List(32);
    if (r.length != 32 || action < actRegister || action > actApprove) {
      throw const E2eeFormatException('bad log action');
    }
    return cat(<Bytes>[
      _dom('OFE2EE1-LOGACT'), <int>[action], _ascii(userId), _ascii(actorId),
      _ascii(c), _ascii(s), u32(epoch), r,
    ]);
  }

  /// SHA-256("OFE2EE1-WRAPS\0" || (recipient_id || blob)...) ordered by id.
  static Future<Uint8List> wrapsDigest(
      List<String> recipients, List<Bytes> blobs) {
    final List<int> idx = List<int>.generate(recipients.length, (i) => i)
      ..sort((a, b) => recipients[a].compareTo(recipients[b]));
    final List<Bytes> parts = <Bytes>[_dom('OFE2EE1-WRAPS')];
    for (final int i in idx) {
      parts
        ..add(_ascii(recipients[i]))
        ..add(blobs[i]);
    }
    return sha256(cat(parts));
  }

  static final Uint8List genesisHash = Uint8List(32);

  /// SHA-256("OFE2EE1-LOG\0" || prev || seq(8 BE) || actionMessage || sig).
  static Future<Uint8List> logEntryHash(
          Bytes prev, int seq, Bytes actionMsg, Bytes sig) =>
      sha256(cat(<Bytes>[_dom('OFE2EE1-LOG'), prev, u64(seq), actionMsg, sig]));

  // --------------------------------------------------------------- wrapping

  static Uint8List wrapAad(
      String circleId, int epoch, String recipientDeviceId, String wrapperDeviceId) {
    for (final String id in <String>[circleId, recipientDeviceId, wrapperDeviceId]) {
      checkId(id);
    }
    if (epoch < 1) throw const E2eeFormatException('epoch must be >= 1');
    return cat(<Bytes>[
      _dom('OFE2EE1-WRAP-AAD'), _ascii(circleId), u32(epoch),
      _ascii(recipientDeviceId), _ascii(wrapperDeviceId),
    ]);
  }

  static Uint8List wrapSigMessage(String circleId, int epoch,
      String recipientDeviceId, String wrapperDeviceId, Bytes blob) {
    if (blob.length != wrapBlobLen) {
      throw const E2eeFormatException('bad wrap length');
    }
    final Uint8List aad =
        wrapAad(circleId, epoch, recipientDeviceId, wrapperDeviceId);
    final int skip = utf8.encode('OFE2EE1-WRAP-AAD\x00').length;
    return cat(<Bytes>[
      _dom('OFE2EE1-WRAP-SIG'), aad.sublist(skip), blob,
    ]);
  }

  static Future<Uint8List> _wrapKey(
      Bytes shared, Bytes epk, Bytes recipientX) {
    return hkdf(shared, cat(<Bytes>[epk, recipientX]),
        _dom('OFE2EE1-WRAP-KEY'), 32);
  }

  static Future<Bytes> _ecdh(Bytes secret, Bytes remotePub) async {
    final SimpleKeyPair kp = await _x.newKeyPairFromSeed(secret);
    final SecretKey s = await _x.sharedSecretKey(
        keyPair: kp,
        remotePublicKey: SimplePublicKey(remotePub, type: KeyPairType.x25519));
    final List<int> out = await s.extractBytes();
    // Low-order remote points give an all-zero secret: refuse.
    if (out.every((int b) => b == 0)) {
      throw const E2eeAuthException('weak public key');
    }
    return out;
  }

  /// Seals [circleKey] to [recipientX]: ephemeral X25519 + HKDF-SHA256 +
  /// XChaCha20-Poly1305 with a random 24-byte nonce.
  /// Output: version(1) || ephemeral pub(32) || nonce(24) || ct(32) || tag(16).
  /// [ephemeralSecret] and [nonce] are for test vectors only.
  static Future<Uint8List> wrap(Bytes circleKey, Bytes recipientX, Bytes aad,
      {Bytes? ephemeralSecret, Bytes? nonce}) async {
    if (circleKey.length != keyLen) {
      throw const E2eeFormatException('circle key must be 32 bytes');
    }
    final Bytes esk = ephemeralSecret ?? randomBytes(32);
    final Bytes n = nonce ?? randomBytes(nonceLen);
    final Uint8List epk = await xPublicFromSecret(esk);
    final Bytes shared = await _ecdh(esk, recipientX);
    final Uint8List k = await _wrapKey(shared, epk, recipientX);
    final SecretBox box = await _aead.encrypt(circleKey,
        secretKey: SecretKey(k), nonce: n, aad: aad);
    return cat(<Bytes>[<int>[wrapVersion], epk, n, box.cipherText, box.mac.bytes]);
  }

  static Future<Uint8List> unwrap(
      Bytes blob, Bytes recipientXSecret, Bytes recipientXPub, Bytes aad) async {
    if (blob.length != wrapBlobLen || blob[0] != wrapVersion) {
      throw const E2eeFormatException('malformed wrapped key');
    }
    final Bytes epk = blob.sublist(1, 33);
    final Bytes n = blob.sublist(33, 57);
    final Bytes ct = blob.sublist(57, 89);
    final Bytes tag = blob.sublist(89);
    try {
      final Bytes shared = await _ecdh(recipientXSecret, epk);
      final Uint8List k = await _wrapKey(shared, epk, recipientXPub);
      final List<int> pt = await _aead.decrypt(
          SecretBox(ct, nonce: n, mac: Mac(tag)),
          secretKey: SecretKey(k),
          aad: aad);
      return Uint8List.fromList(pt);
    } on E2eeAuthException {
      rethrow;
    } catch (_) {
      throw const E2eeAuthException();
    }
  }

  // ------------------------------------------------------- circle payloads

  static Uint8List _msgAad(String circleId, Bytes epoch, String sender, String purpose) {
    return cat(<Bytes>[
      _dom('OFE2EE1-MSG-AAD'), _ascii(circleId), epoch, _ascii(sender),
      <int>[utf8.encode(purpose).length], utf8.encode(purpose),
    ]);
  }

  static Future<Uint8List> _msgKey(
      Bytes circleKey, String circleId, Bytes epoch, String purpose) {
    return hkdf(circleKey, cat(<Bytes>[_ascii(circleId), epoch]),
        cat(<Bytes>[_dom('OFE2EE1-MSG-KEY'), utf8.encode(purpose)]), 32);
  }

  /// Encrypts a circle payload. Output: version(1) || epoch(4 BE) ||
  /// nonce(24) || ciphertext || tag. A fresh random nonce is drawn per call
  /// (24 random bytes: collisions are negligible for any realistic volume).
  static Future<Uint8List> seal(Bytes circleKey, String circleId, int epoch,
      String senderDeviceId, String purpose, Bytes plaintext,
      {Bytes? nonce}) async {
    if (purpose.isEmpty || utf8.encode(purpose).length > 64) {
      throw const E2eeFormatException('purpose must be 1..64 bytes');
    }
    checkId(circleId);
    checkId(senderDeviceId);
    if (epoch < 1) throw const E2eeFormatException('epoch must be >= 1');
    final Uint8List eb = u32(epoch);
    final Bytes n = nonce ?? randomBytes(nonceLen);
    final Uint8List k = await _msgKey(circleKey, circleId, eb, purpose);
    final SecretBox box = await _aead.encrypt(plaintext,
        secretKey: SecretKey(k),
        nonce: n,
        aad: _msgAad(circleId, eb, senderDeviceId, purpose));
    return cat(<Bytes>[<int>[msgVersion], eb, n, box.cipherText, box.mac.bytes]);
  }

  static int payloadEpoch(Bytes payload) {
    if (payload.length < 5 || payload[0] != msgVersion) {
      throw const E2eeFormatException('not an OpenFamily payload');
    }
    return ByteData.sublistView(Uint8List.fromList(payload.sublist(1, 5)))
        .getUint32(0, Endian.big);
  }

  static Future<Uint8List> open(Bytes circleKey, String circleId,
      String senderDeviceId, String purpose, Bytes payload) async {
    if (payload.length < 1 + 4 + nonceLen + tagLen || payload[0] != msgVersion) {
      throw const E2eeFormatException('malformed payload');
    }
    final Bytes eb = payload.sublist(1, 5);
    final Bytes n = payload.sublist(5, 5 + nonceLen);
    final Bytes body = payload.sublist(5 + nonceLen);
    try {
      final Uint8List k = await _msgKey(circleKey, circleId, eb, purpose);
      final List<int> pt = await _aead.decrypt(
          SecretBox(body.sublist(0, body.length - tagLen),
              nonce: n, mac: Mac(body.sublist(body.length - tagLen))),
          secretKey: SecretKey(k),
          aad: _msgAad(circleId, eb, senderDeviceId, purpose));
      return Uint8List.fromList(pt);
    } catch (_) {
      throw const E2eeAuthException();
    }
  }

  // ---------------------------------------------------------------- padding

  static int padBucket(int n) {
    final int need = n + 2;
    for (final int b in <int>[256, 512, 1024, 4096]) {
      if (need <= b) return b;
    }
    return (need + 4095) ~/ 4096 * 4096;
  }

  /// length(2 BE) || payload || zeros, to the next size bucket (hides the
  /// payload size from the server within a bucket).
  static Uint8List pad(Bytes p) {
    if (p.length > 0xffff) throw const E2eeFormatException('payload too large');
    final Uint8List out = Uint8List(padBucket(p.length));
    out[0] = p.length >> 8;
    out[1] = p.length & 0xff;
    out.setRange(2, 2 + p.length, p);
    return out;
  }

  static Uint8List unpad(Bytes p) {
    if (p.length < 2) throw const E2eeFormatException('short padded payload');
    final int n = (p[0] << 8) | p[1];
    if (2 + n > p.length || padBucket(n) != p.length) {
      throw const E2eeFormatException('bad padding');
    }
    for (int i = 2 + n; i < p.length; i++) {
      if (p[i] != 0) throw const E2eeFormatException('bad padding');
    }
    return Uint8List.fromList(p.sublist(2, 2 + n));
  }

  // --------------------------------------------------------------- recovery

  static const String _recoverySalt = 'openfamily/e2ee/v1/recovery';

  /// recovery_seed = HKDF-SHA256(ikm, salt "openfamily/e2ee/v1/recovery",
  /// info "seed"). ikm is the 32-byte BIP39 entropy, or, with a passphrase,
  /// entropy || Argon2id(passphrase, salt = HKDF(entropy, ..., 16)).
  static Future<Uint8List> recoverySeed(Bytes entropy, {String passphrase = ''}) async {
    if (entropy.length != 32) {
      throw const E2eeFormatException('recovery entropy must be 32 bytes');
    }
    Bytes ikm = entropy;
    if (passphrase.isNotEmpty) {
      final Uint8List salt = await hkdf(
          entropy,
          utf8.encode('openfamily/e2ee/v1/recovery-argon2-salt'),
          utf8.encode('salt'),
          16);
      final Argon2id kdf = Argon2id(
          parallelism: argon2Lanes,
          memory: argon2MemKiB,
          iterations: argon2Iterations,
          hashLength: 32);
      final SecretKey a = await kdf.deriveKey(
          secretKey: SecretKey(utf8.encode(passphrase)), nonce: salt);
      ikm = cat(<Bytes>[entropy, await a.extractBytes()]);
    }
    return hkdf(ikm, utf8.encode(_recoverySalt), utf8.encode('seed'), 32);
  }

  /// The recovery identity's Ed25519 seed and X25519 secret.
  static Future<(Uint8List edSeed, Uint8List xSecret)> recoveryIdentity(
      Bytes recoverySeed) async {
    final Uint8List ed = await hkdf(
        recoverySeed, utf8.encode(_recoverySalt), utf8.encode('recovery-ed25519'), 32);
    final Uint8List x = await hkdf(
        recoverySeed, utf8.encode(_recoverySalt), utf8.encode('recovery-x25519'), 32);
    return (ed, x);
  }
}
