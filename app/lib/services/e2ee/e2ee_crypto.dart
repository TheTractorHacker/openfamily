import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Orbitly end-to-end encryption primitives (docs/design/E2EE.md).
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
  // Processing lanes (docs/design/PRIVACY_PROCESSING.md section 5.3).
  static const int actProcessingPref = 10;
  static const int actProcessingPolicy = 11;
  // Owner approval (docs/design/E2EE.md "Owner approval"): the circle's
  // "owner may approve their own replacement device" rule switched on/off.
  static const int actOwnerApproval = 12;
  // The built-in server key kept across an owner key reset: written right after the reset, signed by the NEW root phone,
  // naming the exact server key (subject) and its fingerprint (ref). Must equal e2ee.ActServerAttach in Go.
  static const int actServerAttach = 13;

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

  /// What a member's phone signs to let the Orbitly server (a `server` key)
  /// read ONE circle. It names the circle, the person and the exact server key,
  /// so it cannot be moved. Vector: backend/internal/e2ee/testdata/server_consent.json.
  static Uint8List serverConsentMessage(String circleId, String userId, String serverDeviceId, Bytes serverFingerprint) {
    checkId(circleId);
    checkId(userId);
    checkId(serverDeviceId);
    if (serverFingerprint.length != 32) throw const E2eeFormatException('bad fingerprint length');
    return cat(<Bytes>[
      _dom('OFE2EE1-SERVERCONSENT'), _ascii(circleId), _ascii(userId), _ascii(serverDeviceId), serverFingerprint
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
    if (r.length != 32 || action < actRegister || action > actServerAttach) {
      throw const E2eeFormatException('bad log action');
    }
    return cat(<Bytes>[
      _dom('OFE2EE1-LOGACT'), <int>[action], _ascii(userId), _ascii(actorId),
      _ascii(c), _ascii(s), u32(epoch), r,
    ]);
  }

  /// The `ref` of an owner-approval log entry (action 12):
  /// SHA-256("OFE2EE4-OWNER-APPROVAL\0" || circle(36) || admin_user(36) || on(1)).
  /// The signed log entry is the whole statement; a phone tries on and off.
  static Future<Uint8List> ownerApprovalRef(String circleId, String adminUserId, bool on) {
    checkId(circleId);
    checkId(adminUserId);
    return sha256(cat(<Bytes>[_dom('OFE2EE4-OWNER-APPROVAL'), _ascii(circleId), _ascii(adminUserId), <int>[on ? 1 : 0]]));
  }

  /// HKDF-SHA256(circle_key, salt = circle_id || epoch(4 BE),
  /// info = "OFE2EE1-KEY-COMMIT\0", 32). The publisher signs it in the log;
  /// every phone checks an unwrapped key against it before accepting the key.
  static Future<Uint8List> keyCommitment(Bytes circleKey, String circleId, int epoch) {
    checkId(circleId);
    if (circleKey.length != keyLen || epoch < 1) {
      throw const E2eeFormatException('bad commitment input');
    }
    return hkdf(circleKey, cat(<Bytes>[_ascii(circleId), u32(epoch)]), _dom('OFE2EE1-KEY-COMMIT'), 32);
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
      throw const E2eeFormatException('not an Orbitly payload');
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

  // ====================================================== processing lanes
  //
  // Key LINES (docs/design/PRIVACY_PROCESSING.md section 5): line 0 = phone
  // (CK), line 1 = server (SK). A member's "lane" uses the same two values.
  // Frozen formats shared with backend/internal/e2ee/lanes.go and checked
  // against backend/internal/e2ee/testdata/lanes.json. v1 items and wraps are
  // untouched (they are the phone line). Unknown line/version: fail closed.

  static const int linePhone = 0;
  static const int lineServer = 1;
  static const int msgVersionV2 = 2;
  static const int itemVersionV2 = 2;
  static const int payloadHeaderLenV2 = 6;
  static const int processingNonceLen = 16;
  static const int optOutAllowed = 0;
  static const int optOutRequiredServer = 1;

  static bool validLine(int l) => l == linePhone || l == lineServer;

  /// "phone" / "server" wire name; throws for an unknown value.
  static String lineName(int l) {
    if (l == linePhone) return 'phone';
    if (l == lineServer) return 'server';
    throw const E2eeFormatException('unknown key line');
  }

  static int parseLine(String s) {
    if (s == 'phone') return linePhone;
    if (s == 'server') return lineServer;
    throw const E2eeFormatException('unknown key line');
  }

  static String optOutName(int o) {
    if (o == optOutAllowed) return 'allowed';
    if (o == optOutRequiredServer) return 'required_server';
    throw const E2eeFormatException('unknown member_opt_out');
  }

  static int parseOptOut(String s) {
    if (s == 'allowed') return optOutAllowed;
    if (s == 'required_server') return optOutRequiredServer;
    throw const E2eeFormatException('unknown member_opt_out');
  }

  static void _checkLineGen(int line, int gen) {
    if (!validLine(line)) throw const E2eeFormatException('unknown key line');
    if (gen < 1 || gen > 0xffffffff) throw const E2eeFormatException('generation out of range');
  }

  static Uint8List _lineGen(int line, int gen) => cat(<Bytes>[<int>[line], u32(gen)]);

  static bool _allZero(Bytes b) {
    int d = 0;
    for (final int v in b) {
      d |= v;
    }
    return d == 0;
  }

  /// v3 wrap AAD: "OFE2EE3-WRAP-AAD\0" || line || circle || gen(4) ||
  /// recipient_device || wrapper_device. Server-line wraps MUST use it.
  static Uint8List wrapAadLine(String circleId, int line, int gen, String recipientDeviceId, String wrapperDeviceId) {
    _checkLineGen(line, gen);
    for (final String id in <String>[circleId, recipientDeviceId, wrapperDeviceId]) {
      checkId(id);
    }
    return cat(<Bytes>[
      _dom('OFE2EE3-WRAP-AAD'), <int>[line], _ascii(circleId), u32(gen),
      _ascii(recipientDeviceId), _ascii(wrapperDeviceId),
    ]);
  }

  /// What the wrapper signs for a v3 wrap: "OFE2EE3-WRAP-SIG\0" || (AAD fields) || blob.
  static Uint8List wrapSigMessageLine(String circleId, int line, int gen, String recipientDeviceId, String wrapperDeviceId, Bytes blob) {
    if (blob.length != wrapBlobLen) throw const E2eeFormatException('bad wrap length');
    final Uint8List aad = wrapAadLine(circleId, line, gen, recipientDeviceId, wrapperDeviceId);
    final int skip = utf8.encode('OFE2EE3-WRAP-AAD\x00').length;
    return cat(<Bytes>[_dom('OFE2EE3-WRAP-SIG'), aad.sublist(skip), blob]);
  }

  static Future<bool> verifyWrapSignatureLine(Bytes wrapperEdPub, String circleId, int line, int gen,
      String recipientDeviceId, String wrapperDeviceId, Bytes blob, Bytes sig) async {
    try {
      return await verify(wrapperEdPub,
          wrapSigMessageLine(circleId, line, gen, recipientDeviceId, wrapperDeviceId, blob), sig);
    } on E2eeFormatException {
      return false;
    }
  }

  /// HKDF-SHA256(key, salt = circle || line || gen(4), info = "OFE2EE3-KEY-COMMIT\0", 32).
  /// The admin signs the SK commitment in processing_policy; phones recompute it
  /// from the unwrapped SK so a wrapper cannot hand members different keys.
  static Future<Uint8List> keyCommitmentLine(Bytes key, String circleId, int line, int gen) {
    if (key.length != keyLen) throw const E2eeFormatException('key must be 32 bytes');
    _checkLineGen(line, gen);
    checkId(circleId);
    return hkdf(key, cat(<Bytes>[_ascii(circleId), _lineGen(line, gen)]), _dom('OFE2EE3-KEY-COMMIT'), 32);
  }

  /// Verifies and unwraps one v3 wrap. [commitment] is the commitment the
  /// caller already verified from the signed log/policy record. Throws
  /// [E2eeAuthException] (no detail) when anything fails: line or gen differ
  /// from what was asked (cross-line confusion), wrong recipient, bad wrapper
  /// signature, AEAD failure, short commitment, or commitment mismatch.
  static Future<Uint8List> openWrapLine(String circleId, String deviceId, Bytes xSecret, Bytes xPub,
      LineWrap w, int wantLine, int wantGen, Bytes commitment) async {
    if (w.line != wantLine || w.gen != wantGen || w.recipientDeviceId != deviceId || commitment.length != 32) {
      throw const E2eeAuthException();
    }
    if (!await verifyWrapSignatureLine(
        w.wrapperEdPub, circleId, w.line, w.gen, deviceId, w.wrapperDeviceId, w.blob, w.signature)) {
      throw const E2eeAuthException();
    }
    final Uint8List key;
    try {
      key = await unwrap(w.blob, xSecret, xPub, wrapAadLine(circleId, w.line, w.gen, deviceId, w.wrapperDeviceId));
      final Uint8List got = await keyCommitmentLine(key, circleId, w.line, w.gen);
      if (!constEq(got, commitment)) throw const E2eeAuthException();
    } on E2eeFormatException {
      throw const E2eeAuthException();
    }
    return key;
  }

  /// Hard wrapping rules (section 5.4) a phone can decide locally. The phone
  /// line is never wrapped to a `server` device; the server line only while the
  /// admin policy is on and at least one member is in lane server.
  static void checkWrapRecipient(int line, String recipientKind, {required bool policyOn, required bool hasServerLaneMember}) {
    if (!validLine(line)) throw const E2eeFormatException('unknown key line');
    if (recipientKind != 'server') return;
    if (line == linePhone || !policyOn || !hasServerLaneMember) {
      throw const E2eeFormatException('this key line may not be wrapped to a server device');
    }
  }

  /// Parses version/line/generation of a sealed payload WITHOUT decrypting. v1
  /// is phone line with gen = epoch. Anything else throws.
  static PayloadHeader parsePayloadHeader(Bytes payload) {
    if (payload.isEmpty) throw const E2eeFormatException('malformed payload');
    if (payload[0] == msgVersion) {
      if (payload.length < 5) throw const E2eeFormatException('malformed payload');
      final int g = ByteData.sublistView(Uint8List.fromList(payload.sublist(1, 5))).getUint32(0, Endian.big);
      if (g == 0) throw const E2eeFormatException('generation out of range');
      return PayloadHeader(msgVersion, linePhone, g);
    }
    if (payload[0] == msgVersionV2) {
      if (payload.length < payloadHeaderLenV2) throw const E2eeFormatException('malformed payload');
      final int g = ByteData.sublistView(Uint8List.fromList(payload.sublist(2, 6))).getUint32(0, Endian.big);
      _checkLineGen(payload[1], g);
      return PayloadHeader(msgVersionV2, payload[1], g);
    }
    throw const E2eeFormatException('unknown payload version');
  }

  static void _checkItemFields(String circleId, String deviceId, String purpose, int line, int gen) {
    final int pl = utf8.encode(purpose).length;
    if (pl == 0 || pl > 64) throw const E2eeFormatException('purpose must be 1..64 bytes');
    _checkLineGen(line, gen);
    checkId(circleId);
    checkId(deviceId);
  }

  /// "OFE2EE3-ITEM-AAD\0" || circle || line || gen(4) || device_id || purpose.
  static Uint8List itemAadV2(String circleId, int line, int gen, String deviceId, String purpose) =>
      cat(<Bytes>[_dom('OFE2EE3-ITEM-AAD'), _ascii(circleId), _lineGen(line, gen), _ascii(deviceId), utf8.encode(purpose)]);

  static Future<Uint8List> _msgKeyV2(Bytes key, String circleId, int line, int gen, String purpose) =>
      hkdf(key, cat(<Bytes>[_ascii(circleId), _lineGen(line, gen)]),
          cat(<Bytes>[_dom('OFE2EE3-MSG-KEY'), utf8.encode(purpose)]), 32);

  /// v2 payload: 0x02 || line || gen(4 BE) || nonce(24) || ciphertext || tag.
  static Future<Uint8List> sealV2(Bytes key, String circleId, int line, int gen, String deviceId, String purpose, Bytes plaintext,
      {Bytes? nonce}) async {
    if (key.length != keyLen) throw const E2eeFormatException('key must be 32 bytes');
    _checkItemFields(circleId, deviceId, purpose, line, gen);
    final Bytes n = nonce ?? randomBytes(nonceLen);
    final Uint8List k = await _msgKeyV2(key, circleId, line, gen, purpose);
    final SecretBox box = await _aead.encrypt(plaintext,
        secretKey: SecretKey(k), nonce: n, aad: itemAadV2(circleId, line, gen, deviceId, purpose));
    return cat(<Bytes>[<int>[msgVersionV2], _lineGen(line, gen), n, box.cipherText, box.mac.bytes]);
  }

  /// Decrypts a v2 payload under [key] (the key of the header's line/gen).
  /// A header line different from [expectLine] is rejected before decryption.
  static Future<Uint8List> openV2(Bytes key, String circleId, int expectLine, String deviceId, String purpose, Bytes payload) async {
    final PayloadHeader h = parsePayloadHeader(payload);
    if (h.version != msgVersionV2) throw const E2eeFormatException('not a v2 payload');
    if (h.line != expectLine) throw const E2eeFormatException('item line does not match the expected line');
    if (payload.length < payloadHeaderLenV2 + nonceLen + tagLen || key.length != keyLen) {
      throw const E2eeFormatException('malformed payload');
    }
    _checkItemFields(circleId, deviceId, purpose, h.line, h.gen);
    try {
      final Uint8List k = await _msgKeyV2(key, circleId, h.line, h.gen, purpose);
      final Bytes body = payload.sublist(payloadHeaderLenV2 + nonceLen);
      final List<int> pt = await _aead.decrypt(
          SecretBox(body.sublist(0, body.length - tagLen),
              nonce: payload.sublist(payloadHeaderLenV2, payloadHeaderLenV2 + nonceLen),
              mac: Mac(body.sublist(body.length - tagLen))),
          secretKey: SecretKey(k),
          aad: itemAadV2(circleId, h.line, h.gen, deviceId, purpose));
      return Uint8List.fromList(pt);
    } catch (_) {
      throw const E2eeAuthException();
    }
  }

  /// "OFE2EE3-ITEM\0" || circle || line || gen(4) || device_id || len(purpose)(1) ||
  /// purpose || seq(8) || ts_ms(8) || body. Signed by the sender device key.
  static Uint8List itemSignedMessageV2(String circleId, int line, int gen, String deviceId, String purpose, int seq, int tsMs, Bytes body) {
    _checkItemFields(circleId, deviceId, purpose, line, gen);
    final Uint8List p = Uint8List.fromList(utf8.encode(purpose));
    return cat(<Bytes>[
      _dom('OFE2EE3-ITEM'), _ascii(circleId), _lineGen(line, gen), _ascii(deviceId),
      <int>[p.length], p, u64(seq), u64(tsMs), body,
    ]);
  }

  /// Signs [body] as the sender device (Ed25519 seed [edSeed]) and seals it,
  /// padded, under the key of (line, gen). Envelope: 0x02 || seq || ts_ms || sig || body.
  static Future<Uint8List> sealItemV2(Bytes key, String circleId, int line, int gen, String deviceId, Bytes edSeed,
      String purpose, int seq, int tsMs, Bytes body, {Bytes? nonce}) async {
    final Uint8List sig = await sign(edSeed, itemSignedMessageV2(circleId, line, gen, deviceId, purpose, seq, tsMs, body));
    final Uint8List env = cat(<Bytes>[<int>[itemVersionV2], u64(seq), u64(tsMs), sig, body]);
    return sealV2(key, circleId, line, gen, deviceId, purpose, pad(env), nonce: nonce);
  }

  /// Decrypts and verifies a v2 item: line == [expectLine], signed seq ==
  /// [serverSeq], sender signature (covers line and gen). Throws on any
  /// failure. The caller still owes sender approval, the signed-time window,
  /// the replay window, [RollbackGuard.check] and [classifyItemLane].
  static Future<ItemV2> openItemV2(Bytes key, String circleId, int expectLine, String deviceId, Bytes senderEdPub,
      String purpose, int serverSeq, Bytes payload) async {
    final Uint8List padded = await openV2(key, circleId, expectLine, deviceId, purpose, payload);
    final PayloadHeader h = parsePayloadHeader(payload);
    final Uint8List env = unpad(padded);
    if (env.length < 1 + 8 + 8 + sigLen || env[0] != itemVersionV2) {
      throw const E2eeFormatException('malformed item envelope');
    }
    final ByteData bd = ByteData.sublistView(env);
    final int seq = bd.getUint64(1, Endian.big);
    final int ts = bd.getUint64(9, Endian.big);
    if (seq != serverSeq) throw const E2eeAuthException('seq mismatch');
    final Uint8List body = Uint8List.fromList(env.sublist(17 + sigLen));
    final Uint8List msg = itemSignedMessageV2(circleId, h.line, h.gen, deviceId, purpose, seq, ts, body);
    if (!await verify(senderEdPub, msg, env.sublist(17, 17 + sigLen))) {
      throw const E2eeAuthException('bad item signature');
    }
    return ItemV2(h.line, h.gen, seq, ts, body);
  }

  static void _checkNonce(Bytes n) {
    if (n.length != processingNonceLen) throw const E2eeFormatException('bad statement nonce');
  }

  /// "OFE2EE3-PROCESSING\0" || circle || user || lane(1) || sk_gen(4) ||
  /// server_device_id || server_fingerprint(32) || nonce(16). Supersedes
  /// [serverConsentMessage] (still valid for legacy rows). Lane server needs
  /// sk_gen >= 1, a real server device and a non-zero fingerprint; lane phone
  /// needs the zero UUID and an all-zero fingerprint.
  static Uint8List processingPrefMessage(String circleId, String userId, int lane, int skGen,
      String serverDeviceId, Bytes serverFingerprint, Bytes nonce) {
    if (!validLine(lane)) throw const E2eeFormatException('unknown lane');
    for (final String id in <String>[circleId, userId, serverDeviceId]) {
      checkId(id);
    }
    if (serverFingerprint.length != 32) throw const E2eeFormatException('bad fingerprint length');
    _checkNonce(nonce);
    if (skGen < 0 || skGen > 0xffffffff) throw const E2eeFormatException('generation out of range');
    if (lane == lineServer && (skGen == 0 || serverDeviceId == zeroUuid || _allZero(serverFingerprint))) {
      throw const E2eeFormatException('lane server must name the server key');
    }
    if (lane == linePhone && (serverDeviceId != zeroUuid || !_allZero(serverFingerprint))) {
      throw const E2eeFormatException('lane phone names no server key');
    }
    return cat(<Bytes>[
      _dom('OFE2EE3-PROCESSING'), _ascii(circleId), _ascii(userId), <int>[lane], u32(skGen),
      _ascii(serverDeviceId), serverFingerprint, nonce,
    ]);
  }

  static Future<bool> verifyProcessingPref(Bytes approverEdPub, String circleId, String userId, int lane, int skGen,
      String serverDeviceId, Bytes serverFingerprint, Bytes nonce, Bytes sig) async {
    try {
      return await verify(approverEdPub,
          processingPrefMessage(circleId, userId, lane, skGen, serverDeviceId, serverFingerprint, nonce), sig);
    } on E2eeFormatException {
      return false;
    }
  }

  /// "OFE2EE3-POLICY\0" || circle || admin_user || server_assist(1) ||
  /// default_for_new(1: lane) || member_opt_out(1: 0 allowed, 1 required_server) ||
  /// sk_gen(4) || commitment(32) || nonce(16). Assist on needs sk_gen >= 1 and a
  /// non-zero commitment; required_server needs assist on; unknown values throw.
  static Uint8List processingPolicyMessage(String circleId, String adminUserId, bool serverAssist, int defaultForNew,
      int memberOptOut, int skGen, Bytes commitment, Bytes nonce) {
    if (!validLine(defaultForNew)) throw const E2eeFormatException('unknown lane');
    if ((memberOptOut != optOutAllowed && memberOptOut != optOutRequiredServer) ||
        (memberOptOut == optOutRequiredServer && !serverAssist)) {
      throw const E2eeFormatException('bad member_opt_out');
    }
    checkId(circleId);
    checkId(adminUserId);
    if (commitment.length != 32) throw const E2eeFormatException('bad commitment length');
    _checkNonce(nonce);
    if (skGen < 0 || skGen > 0xffffffff) throw const E2eeFormatException('generation out of range');
    if (serverAssist && (skGen == 0 || _allZero(commitment))) throw const E2eeFormatException('assist on needs an SK');
    if (skGen == 0 && !_allZero(commitment)) throw const E2eeFormatException('commitment without a generation');
    return cat(<Bytes>[
      _dom('OFE2EE3-POLICY'), _ascii(circleId), _ascii(adminUserId), <int>[serverAssist ? 1 : 0],
      <int>[defaultForNew], <int>[memberOptOut], u32(skGen), commitment, nonce,
    ]);
  }

  /// That the signer is currently a circle admin is the caller's check.
  static Future<bool> verifyProcessingPolicy(Bytes adminEdPub, String circleId, String adminUserId, bool serverAssist,
      int defaultForNew, int memberOptOut, int skGen, Bytes commitment, Bytes nonce, Bytes sig) async {
    try {
      return await verify(
          adminEdPub,
          processingPolicyMessage(circleId, adminUserId, serverAssist, defaultForNew, memberOptOut, skGen, commitment, nonce),
          sig);
    } on E2eeFormatException {
      return false;
    }
  }

  /// `ref` of the transparency-log entry for processing_pref / processing_policy:
  /// SHA-256 of the signed statement. The entry is
  /// logActionMessage(actProcessingPref|actProcessingPolicy, user, actor, circleId:,
  /// subjectId: server device (lane-server pref only), epoch: sk_gen, ref: processingRef(..)).
  /// A pref's "effective_seq" is the log entry's own seq, not a signed field.
  static Future<Uint8List> processingRef(Bytes statement) => sha256(statement);

  /// Receiver-side badge decision for one item (see [LaneVerdict]). [prefs] are
  /// the author's VERIFIED prefs in any order. Phone-line items are always
  /// consistent; a server-line item is consistent only if the latest pref
  /// effective at its signed time is lane server.
  static LaneVerdict classifyItemLane(List<PrefEntry> prefs, int line, int itemTsMs) {
    if (line == linePhone) return LaneVerdict.consistent;
    if (line != lineServer || itemTsMs < 0) return LaneVerdict.flagged;
    PrefEntry? best;
    for (final PrefEntry p in prefs) {
      if (p.sinceMs <= itemTsMs && (best == null || p.sinceMs >= best.sinceMs)) best = p;
    }
    return best != null && best.lane == lineServer ? LaneVerdict.consistent : LaneVerdict.flagged;
  }
}

/// Parsed, UNAUTHENTICATED header of a sealed payload (v1: phone line, gen = epoch).
class PayloadHeader {
  const PayloadHeader(this.version, this.line, this.gen);
  final int version;
  final int line;
  final int gen;
}

/// A successfully opened and verified v2 item.
class ItemV2 {
  const ItemV2(this.line, this.gen, this.seq, this.tsMs, this.body);
  final int line;
  final int gen;
  final int seq;
  final int tsMs;
  final Uint8List body;
}

/// One v3 wrap addressed to a device (raw bytes).
class LineWrap {
  const LineWrap({
    required this.line,
    required this.gen,
    required this.recipientDeviceId,
    required this.wrapperDeviceId,
    required this.wrapperEdPub,
    required this.blob,
    required this.signature,
  });
  final int line;
  final int gen;
  final String recipientDeviceId;
  final String wrapperDeviceId;
  final Uint8List wrapperEdPub;
  final Uint8List blob;
  final Uint8List signature;
}

/// One VERIFIED processing_pref of one user. [sinceMs] is advisory (server
/// recorded); it only flags, never grants access.
class PrefEntry {
  const PrefEntry(this.lane, this.sinceMs);
  final int lane;
  final int sinceMs;
}

enum LaneVerdict { consistent, flagged }

/// The per-line epoch/generation rollback rule (E2EE.md phase 2 receiving)
/// applied independently to each line. Call [check] only AFTER the item's
/// AEAD and signature verified, and [observe] when a key of (line, gen) is
/// first accepted. Times are milliseconds.
class RollbackGuard {
  RollbackGuard({this.graceMs = 10 * 60 * 1000});
  final int graceMs;
  final Map<int, Map<int, int>> _first = <int, Map<int, int>>{};
  final Map<int, int> _high = <int, int>{};
  final Map<String, int> _dev = <String, int>{};

  void observe(int line, int gen, int nowMs) {
    if (!E2ee.validLine(line) || gen < 1) throw const E2eeFormatException('bad line/generation');
    _first.putIfAbsent(line, () => <int, int>{}).putIfAbsent(gen, () => nowMs);
    if (gen > (_high[line] ?? 0)) _high[line] = gen;
  }

  /// Throws [E2eeAuthException] on rollback. On success records the item.
  void check(int line, int gen, String deviceId, int itemTsMs, int nowMs) {
    if (!E2ee.validLine(line) || gen < 1) throw const E2eeFormatException('bad line/generation');
    final int hi = _high[line] ?? 0;
    if (gen < hi) {
      final int firstHi = _first[line]![hi]!;
      if (itemTsMs >= firstHi && nowMs - firstHi > graceMs) throw const E2eeAuthException('rollback');
    }
    final String dk = '$deviceId/$line';
    final int dh = _dev[dk] ?? 0;
    if (gen < dh && itemTsMs >= _first[line]![dh]!) throw const E2eeAuthException('rollback');
    observe(line, gen, nowMs);
    if (gen > dh) _dev[dk] = gen;
  }
}
