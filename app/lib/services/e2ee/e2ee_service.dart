import 'dart:convert';
import 'dart:typed_data';

import 'package:bip39/bip39.dart' as bip39;

import 'e2ee_api.dart';
import 'e2ee_crypto.dart';
import 'e2ee_models.dart';
import 'e2ee_trust.dart';
import 'lanes_wire.dart';
import 'e2ee_vault.dart';

/// This phone's identity. The private halves ([edSeed], [xSecret]) live only
/// in memory while in use and in the [E2eeVault]; they are never sent or logged.
class LocalIdentity {
  LocalIdentity._(this.userId, this.deviceId, this.edSeed, this.xSecret, this.edPub,
      this.xPub, this.fingerprint);
  final String userId;
  final String deviceId;
  final Uint8List edSeed;
  final Uint8List xSecret;
  final Uint8List edPub;
  final Uint8List xPub;
  final Uint8List fingerprint;

  String get fingerprintHex => E2ee.hex(fingerprint);
  String get short => E2ee.shortFingerprint(fingerprint);
  Future<String> get digits => E2ee.digitGroups(fingerprint);
}

class NeedsCrossSignatureException implements Exception {
  const NeedsCrossSignatureException();
  @override
  String toString() =>
      'This account already has encryption keys. Link this phone from your other device, restore with your recovery phrase, or reset your keys.';
}

class RecoverySetup {
  RecoverySetup(this.entropy, this.mnemonic);
  final Uint8List entropy;
  final String mnemonic;
}

/// Result of "Check server record".
///
/// IMPORTANT: a match proves only that the server tells the same story as this
/// phone (consistency). It does NOT prove the server is honest to anyone else;
/// authenticity comes from comparing safety numbers in person.
class ServerRecordCheck {
  const ServerRecordCheck({
    required this.match,
    required this.registered,
    required this.revoked,
    this.serverFingerprint,
    this.localFingerprint,
    this.otherActive = const <DeviceKey>[],
    this.problem,
  });
  final bool match;
  final bool registered;
  final bool revoked;
  final String? serverFingerprint;
  final String? localFingerprint;

  /// Other ACTIVE keys on my account (my other phones, or an intruder).
  final List<DeviceKey> otherActive;
  final String? problem;
}

class PendingItem {
  const PendingItem(this.key, this.result);
  final DeviceKey key;
  final WrapDecisionResult result;
}

class PendingReport {
  const PendingReport({this.wrapped = 0, this.needConfirm = const <PendingItem>[], this.waiting = const <PendingItem>[], this.refused = const <PendingItem>[]});
  final int wrapped;
  final List<PendingItem> needConfirm;
  final List<PendingItem> waiting;
  final List<PendingItem> refused;
}

class LogSync {
  const LogSync(this.check, this.alarms, this.head);
  final LogCheck check;
  final List<E2eeAlarm> alarms;
  final LogHead? head;
}

class E2eeService {
  E2eeService({
    required this.api,
    required this.vault,
    required this.trust,
    required this.userIdProvider,
  });

  final E2eeApi api;
  final E2eeVault vault;
  final TrustStore trust;
  final Future<String> Function() userIdProvider;

  /// Capabilities advertised in device registration (see [kCapLanes]).
  static const List<String> capabilities = <String>[kCapLanes];

  static const String _seedName = 'identity_seed';
  static const String _deviceName = 'device_id';
  static const String _userName = 'identity_user';

  LocalIdentity? _cached;

  // ------------------------------------------------------------- identity

  Future<bool> hasIdentity() async => (await vault.read(_seedName)) != null;

  /// The account the stored identity belongs to (for the headless background
  /// isolate, which cannot ask the API who is signed in).
  Future<String> storedUserId() async {
    final Uint8List? u = await vault.read(_userName);
    return u == null ? '' : utf8.decode(u);
  }

  /// Loads (or, with [create], generates) this phone's identity. Generation
  /// happens on the device; only public keys are ever uploaded.
  Future<LocalIdentity?> identity({bool create = false}) async {
    final LocalIdentity? c = _cached;
    if (c != null) return c;
    final String uid = await userIdProvider();
    Uint8List? seed = await vault.read(_seedName);
    final Uint8List? owner = await vault.read(_userName);
    if (seed != null && owner != null && utf8.decode(owner) != uid) {
      // A different account signed in on this phone: its identity is not ours.
      await _wipeIdentity();
      seed = null;
    }
    String? deviceId;
    if (seed != null) {
      final Uint8List? d = await vault.read(_deviceName);
      deviceId = d == null ? null : utf8.decode(d);
    }
    if (seed == null || deviceId == null) {
      if (!create) return null;
      seed = E2ee.randomBytes(32);
      deviceId = E2ee.newUuid();
      await vault.write(_seedName, seed);
      await vault.write(_deviceName, Uint8List.fromList(utf8.encode(deviceId)));
      await vault.write(_userName, Uint8List.fromList(utf8.encode(uid)));
    }
    final (Uint8List es, Uint8List xs) = await E2ee.deriveIdentity(seed);
    final Uint8List ed = await E2ee.edPublicFromSeed(es);
    final Uint8List x = await E2ee.xPublicFromSecret(xs);
    return _cached = LocalIdentity._(uid, deviceId, es, xs, ed, x, await E2ee.fingerprint(ed, x));
  }

  Future<void> _wipeIdentity() async {
    _cached = null;
    for (final String n in await vault.names()) {
      await vault.delete(n);
    }
  }

  /// Forgets this phone's keys locally (sign out / "erase keys"). Does not touch
  /// the server; revoke the key first if you want peers to stop wrapping to it.
  Future<void> eraseLocalKeys() => _wipeIdentity();

  // ---------------------------------------------------------- registration

  Future<Map<String, dynamic>> _registrationBody(
    LocalIdentity id, {
    required String kind,
    required int action,
    required String actorDeviceId,
    required Uint8List actorEdSeed,
    required bool reset,
    String label = '',
  }) async {
    final Uint8List binding = await E2ee.sign(id.edSeed, E2ee.bindingMessage(id.userId, id.deviceId, id.edPub, id.xPub));
    final Uint8List msg = E2ee.logActionMessage(action, id.userId, actorDeviceId, subjectId: id.deviceId, ref: id.fingerprint);
    return <String, dynamic>{
      'device_id': id.deviceId,
      'kind': kind,
      'ed25519_pub': E2ee.b64(id.edPub),
      'x25519_pub': E2ee.b64(id.xPub),
      'signature': E2ee.b64(binding),
      'label': label,
      'actor_device_id': actorDeviceId,
      'log_signature': E2ee.b64(await E2ee.sign(actorEdSeed, msg)),
      'reset': reset,
      // What this app can read. An old app sends nothing and so can never be
      // handed a server-line key (the admin screen lists it as "update needed").
      LanesFields.caps: capabilities,
    };
  }

  /// Registers this phone's PUBLIC keys. The first key of an account is a root.
  /// Otherwise it needs [approval] (a cross-signature from another device or the
  /// recovery key) unless [reset] replaces all keys (peers must then re-approve).
  Future<DeviceKey> registerThisDevice({LinkApproval? approval, bool reset = false, String label = ''}) async {
    final LocalIdentity id = (await identity(create: true))!;
    final List<DeviceKey> mine = await api.myKeys();
    final bool anyActive = mine.any((DeviceKey k) => k.isActive);
    for (final DeviceKey k in mine) {
      if (k.isActive && k.deviceId == id.deviceId) return k; // already registered
    }
    if (approval != null) {
      // Cross-signed: the approver's signature was made on their phone.
      final Map<String, dynamic> body = await _registrationBody(id,
          kind: 'device', action: E2ee.actRegister, actorDeviceId: id.deviceId, actorEdSeed: id.edSeed, reset: false, label: label);
      body['actor_device_id'] = approval.actorDeviceId;
      body['log_signature'] = E2ee.b64(approval.signature);
      return api.register(body);
    }
    if (anyActive && !reset) throw const NeedsCrossSignatureException();
    final bool first = mine.isEmpty;
    return api.register(await _registrationBody(id,
        kind: 'device',
        action: first ? E2ee.actRegister : E2ee.actReset,
        actorDeviceId: id.deviceId,
        actorEdSeed: id.edSeed,
        reset: !first && anyActive,
        label: label));
  }

  // ---- linking a second phone (manual ping-pong, no server round trip)

  /// New phone: the code to show/copy to an already-registered phone.
  Future<String> createLinkRequest() async {
    final LocalIdentity id = (await identity(create: true))!;
    final Uint8List binding = await E2ee.sign(id.edSeed, E2ee.bindingMessage(id.userId, id.deviceId, id.edPub, id.xPub));
    return base64Url.encode(utf8.encode(jsonEncode(<String, String>{
      'u': id.userId, 'd': id.deviceId, 'e': E2ee.b64(id.edPub), 'x': E2ee.b64(id.xPub), 'b': E2ee.b64(binding),
    })));
  }

  /// Existing phone: parses and checks a link request; the user then compares
  /// [LinkRequestInfo.short] with the new phone's screen before approving.
  Future<LinkRequestInfo> inspectLinkRequest(String code) async {
    final Map<String, dynamic> m = jsonDecode(utf8.decode(base64Url.decode(code.trim()))) as Map<String, dynamic>;
    final Uint8List ed = E2ee.unb64(m['e']), x = E2ee.unb64(m['x']);
    final String uid = m['u'], did = m['d'];
    final LocalIdentity me = (await identity())!;
    if (uid != me.userId) throw const E2eeFormatException('this request is for another account');
    if (!await E2ee.verify(ed, E2ee.bindingMessage(uid, did, ed, x), E2ee.unb64(m['b']))) {
      throw const E2eeAuthException('the request is corrupted or forged');
    }
    final Uint8List fp = await E2ee.fingerprint(ed, x);
    // Optional device-member fields (phase 3): kind 'web' | 'service' | 'server' and a name.
    final Object? k = m['k'], n = m['n'];
    return LinkRequestInfo(did, fp, E2ee.shortFingerprint(fp), await E2ee.digitGroups(fp),
        kind: k is String ? k : null, name: n is String ? cleanDeviceName(n) : null);
  }

  /// Removes control characters and caps a viewer-supplied name at 40 chars.
  static String cleanDeviceName(String s) {
    final String t = s.replaceAll(RegExp(r'[\u0000-\u001f\u007f]'), ' ').trim();
    return t.runes.length <= 40 ? t : String.fromCharCodes(t.runes.take(40));
  }

  /// Phone: like [inspectLinkRequest], but only accepts the request of a browser
  /// viewer (kind 'web') or a bridge ('service'); a phone request (kind absent or
  /// 'device') is refused and the user is pointed to "Link another phone".
  Future<LinkRequestInfo> inspectViewerRequest(String code) async {
    final LinkRequestInfo i = await inspectLinkRequest(code);
    if (!i.isViewer) {
      throw const E2eeFormatException(
          'This is the request of a phone, not of a viewer or bridge. Use "Link another phone" in Encryption keys to approve a phone.');
    }
    return i;
  }

  /// Existing phone: signs the new phone's registration. Returns the approval
  /// code to type into the new phone.
  Future<String> approveLinkRequest(LinkRequestInfo info) async {
    final LocalIdentity me = (await identity())!;
    final Uint8List sig = await E2ee.sign(me.edSeed,
        E2ee.logActionMessage(E2ee.actRegister, me.userId, me.deviceId, subjectId: info.deviceId, ref: info.fingerprint));
    return base64Url.encode(utf8.encode(jsonEncode(<String, String>{'a': me.deviceId, 's': E2ee.b64(sig)})));
  }

  LinkApproval parseApproval(String code) {
    final Map<String, dynamic> m = jsonDecode(utf8.decode(base64Url.decode(code.trim()))) as Map<String, dynamic>;
    return LinkApproval(m['a'] as String, E2ee.unb64(m['s'] as String));
  }

  // -------------------------------------------------- server record check

  Future<ServerRecordCheck> checkServerRecord() async {
    final LocalIdentity? id = await identity();
    final List<DeviceKey> mine = await api.myKeys();
    if (id == null) {
      return const ServerRecordCheck(match: false, registered: false, revoked: false, problem: 'This phone has no keys yet.');
    }
    DeviceKey? rec;
    for (final DeviceKey k in mine) {
      if (k.deviceId == id.deviceId) rec = k;
    }
    final List<DeviceKey> others = mine.where((DeviceKey k) => k.isActive && k.deviceId != id.deviceId).toList();
    if (rec == null) {
      return ServerRecordCheck(match: false, registered: false, revoked: false, localFingerprint: id.fingerprintHex, otherActive: others);
    }
    final Uint8List serverFp = await E2ee.fingerprint(rec.edPub, rec.xPub);
    final bool same = E2ee.constEq(rec.edPub, id.edPub) &&
        E2ee.constEq(rec.xPub, id.xPub) &&
        E2ee.constEq(serverFp, id.fingerprint) &&
        rec.fingerprint == id.fingerprintHex;
    return ServerRecordCheck(
      match: same && rec.isActive,
      registered: true,
      revoked: !rec.isActive,
      serverFingerprint: rec.fingerprint,
      localFingerprint: id.fingerprintHex,
      otherActive: others,
      problem: !same ? 'The server holds different keys for this phone.' : (!rec.isActive ? 'This key was revoked.' : null),
    );
  }

  // ---------------------------------------------------------- circle keys

  String _ckName(String circleId, int epoch) => 'ck/$circleId/$epoch';

  Future<Uint8List?> circleKey(String circleId, int epoch) => vault.read(_ckName(circleId, epoch));

  Future<List<int>> heldEpochs(String circleId) async {
    final String p = 'ck/$circleId/';
    final List<int> out = <int>[];
    for (final String n in await vault.names()) {
      if (n.startsWith(p)) {
        final int? e = int.tryParse(n.substring(p.length));
        if (e != null) out.add(e);
      }
    }
    out.sort();
    return out;
  }

  // ------------------------------------------------ server line key (SK)
  // PRIVACY_PROCESSING sections 5.1 and 5.4. SK has its own generation counter
  // and its own vault names; CK code paths never touch it.

  String _skName(String circleId, int gen) => 'sk/$circleId/$gen';

  Future<Uint8List?> serverKey(String circleId, int gen) => vault.read(_skName(circleId, gen));

  Future<List<int>> heldServerGens(String circleId) async {
    final String p = 'sk/$circleId/';
    final List<int> out = <int>[];
    for (final String n in await vault.names()) {
      if (n.startsWith(p)) {
        final int? g = int.tryParse(n.substring(p.length));
        if (g != null && g >= 1) out.add(g);
      }
    }
    out.sort();
    return out;
  }

  Future<int> latestServerGen(String circleId) async {
    final List<int> g = await heldServerGens(circleId);
    return g.isEmpty ? 0 : g.last;
  }

  /// Stores a freshly generated SK (the admin phone that made it).
  Future<void> storeServerKey(String circleId, int gen, Uint8List key) async {
    if (await serverKeyEqualsCircleKey(circleId, key)) {
      await _raiseSkEqualsCk(circleId);
      throw StateError('refusing to store a server key that equals a circle key');
    }
    await vault.write(_skName(circleId, gen), key);
  }

  /// A fresh server line key from the CSPRNG, asserted different from every circle key epoch.
  Future<Uint8List> generateServerKey(String circleId, {CircleE2eeState? state, Uint8List Function()? random}) async {
    final Uint8List key = (random ?? () => E2ee.randomBytes(32))();
    if (key.length != 32 || await serverKeyEqualsCircleKey(circleId, key, state: state)) {
      await _raiseSkEqualsCk(circleId);
      throw StateError('generated server key collides with a circle key');
    }
    return key;
  }

  /// Alarms raised by the lane checks (never cleared by this class; the UI shows and clears them).
  final List<E2eeAlarm> laneAlarms = <E2eeAlarm>[];

  /// True when [key] (an SK candidate) is, or commits like, ANY circle key epoch of
  /// [circleId]: the held epoch keys byte for byte, and the signed epoch commitments
  /// of the circle state (covers epochs whose bytes this phone does not hold).
  /// A server line key that equals a CK would hand the server every phone-line item.
  Future<bool> serverKeyEqualsCircleKey(String circleId, Uint8List key, {CircleE2eeState? state}) async {
    for (final int e in await heldEpochs(circleId)) {
      final Uint8List? ck = await circleKey(circleId, e);
      if (ck != null && E2ee.constEq(ck, key)) return true;
    }
    final CircleE2eeState st = state ?? await api.circleState(circleId);
    for (final EpochRecord rec in st.epochs) {
      if (rec.epoch >= 1 && E2ee.constEq(await E2ee.keyCommitment(key, circleId, rec.epoch), rec.commitment)) return true;
    }
    return false;
  }

  static const String _skckIndex = 'alarm:skck:index';

  Future<void> _raiseSkEqualsCk(String circleId, {bool ckSide = false}) async {
    final E2eeAlarm a = _skckAlarm(circleId, ckSide);
    laneAlarms.add(a);
    // Recorded on this phone so the alert survives a restart, and listed in [laneAlarmList].
    try {
      await trust.kv.set('alarm:skck:$circleId', '${DateTime.now().toUtc().toIso8601String()}|${ckSide ? 'ck' : 'sk'}');
      final Set<String> idx = <String>{...(await trust.kv.get(_skckIndex) ?? '').split(',').where((String x) => x.isNotEmpty), circleId};
      await trust.kv.set(_skckIndex, idx.join(','));
    } catch (_) {}
  }

  static E2eeAlarm _skckAlarm(String circleId, bool ckSide) => ckSide
      ? E2eeAlarm(AlarmKind.serverKeyIsCircleKey, 'Circle key refused',
          'A circle key sent to this phone was identical to the server key of this circle, so it was NOT used. Someone may be trying to hand '
          'the server your phone-only data. Do not share anything new in this circle until a circle admin checked it.',
          circleId: circleId)
      : E2eeAlarm(AlarmKind.serverKeyIsCircleKey, 'Server key refused',
          'A server key for this circle was identical to the circle key and was NOT used. Someone may be trying to give the server your private data.',
          circleId: circleId);

  /// Severe alarms the lane checks raised on this phone (this run and earlier ones), for the key log and the circle screens.
  Future<List<E2eeAlarm>> laneAlarmList() async {
    final Map<String, E2eeAlarm> out = <String, E2eeAlarm>{for (final E2eeAlarm a in laneAlarms) '${a.circleId}/${a.title}': a};
    try {
      for (final String c in (await trust.kv.get(_skckIndex) ?? '').split(',')) {
        if (c.isEmpty) continue;
        final String v = await trust.kv.get('alarm:skck:$c') ?? '';
        if (v.isEmpty) continue;
        final E2eeAlarm a = _skckAlarm(c, v.endsWith('|ck'));
        out.putIfAbsent('$c/${a.title}', () => a);
      }
    } catch (_) {}
    return out.values.toList();
  }

  /// True when [ck] (a circle key just opened) is, or commits like, a server line key of [circleId]: a held SK
  /// byte for byte, or the commitment of any signed policy statement the server serves.
  Future<bool> circleKeyIsServerKey(String circleId, Uint8List ck) async {
    for (final int gen in await heldServerGens(circleId)) {
      final Uint8List? sk = await serverKey(circleId, gen);
      if (sk != null && E2ee.constEq(sk, ck)) return true;
    }
    try {
      final ProcessingServerState ps = await api.processingState(circleId);
      for (final PolicyStatement p in <PolicyStatement>[if (ps.policy != null) ps.policy!, ...ps.policyHistory]) {
        if (p.skGen >= 1 && p.commitment.any((int b) => b != 0) &&
            E2ee.constEq(await E2ee.keyCommitmentLine(ck, circleId, E2ee.lineServer, p.skGen), p.commitment)) {
          return true;
        }
      }
    } catch (_) {}
    return false;
  }

  /// One v3 wrap of the server line key.
  Future<Map<String, dynamic>> wrapServerKeyTo(LocalIdentity me, String circleId, int gen, Uint8List key, DeviceKey to,
      {Uint8List? wrapperEdSeed, String? wrapperId}) async {
    final String wid = wrapperId ?? me.deviceId;
    // Whatever the server claims about the line, never wrap a circle key under the server line.
    if (await serverKeyEqualsCircleKey(circleId, key)) {
      await _raiseSkEqualsCk(circleId);
      throw StateError('refusing to wrap a key that equals a circle key under the server line');
    }
    final Uint8List aad = E2ee.wrapAadLine(circleId, E2ee.lineServer, gen, to.deviceId, wid);
    final Uint8List blob = await E2ee.wrap(key, to.xPub, aad);
    final Uint8List sig = await E2ee.sign(wrapperEdSeed ?? me.edSeed, E2ee.wrapSigMessageLine(circleId, E2ee.lineServer, gen, to.deviceId, wid, blob));
    return <String, dynamic>{
      'recipient_device_id': to.deviceId,
      'wrapper_device_id': wid,
      'wrapped_key': E2ee.b64(blob),
      'signature': E2ee.b64(sig),
    };
  }

  /// Keys that get a wrap of the server line. [serverKey] non-null only when the
  /// caller verified policy on + pinned key + at least one member in lane server.
  Future<List<DeviceKey>> serverLineRecipients(CircleE2eeState st, LocalIdentity me, {DeviceKey? serverKey}) =>
      _recipients(st, me, line: E2ee.lineServer, serverKey: serverKey);

  /// How many wraps of server-line keys were refused in the last [syncServerKeys].
  int rejectedServerWraps = 0;

  /// Opens the server-line wraps addressed to this phone. [commitments] maps an
  /// SK generation to the commitment from a VERIFIED signed policy record (a
  /// wrap for a generation without one, or whose key does not match it, is
  /// refused). Returns the number of new keys stored.
  Future<int> syncServerKeys(String circleId, Map<int, Uint8List> commitments,
      {String? asDeviceId, Uint8List? xSecret, Uint8List? xPub}) async {
    final LocalIdentity me = (await identity())!;
    final String dev = asDeviceId ?? me.deviceId;
    final Uint8List sec = xSecret ?? me.xSecret;
    final Uint8List pub = xPub ?? me.xPub;
    int n = 0;
    rejectedServerWraps = 0;
    for (final WrapRecord w in await api.myWraps(circleId, dev)) {
      if (w.line != E2ee.lineServer || w.recipientDeviceId != dev) continue;
      if (await vault.read(_skName(circleId, w.epoch)) != null) continue;
      final Uint8List? commit = commitments[w.epoch];
      if (commit == null) {
        rejectedServerWraps++;
        continue;
      }
      try {
        final Uint8List key = await E2ee.openWrapLine(
            circleId,
            dev,
            sec,
            pub,
            LineWrap(
                line: w.line,
                gen: w.epoch,
                recipientDeviceId: w.recipientDeviceId,
                wrapperDeviceId: w.wrapperDeviceId,
                wrapperEdPub: w.wrapperEdPub,
                blob: w.blob,
                signature: w.signature),
            E2ee.lineServer,
            w.epoch,
            commit);
        if (await serverKeyEqualsCircleKey(circleId, key)) {
          rejectedServerWraps++;
          await _raiseSkEqualsCk(circleId);
          continue; // never stored, never used
        }
        await vault.write(_skName(circleId, w.epoch), key);
        n++;
      } on E2eeAuthException {
        rejectedServerWraps++;
      } on E2eeFormatException {
        rejectedServerWraps++;
      }
    }
    return n;
  }

  Future<Map<String, dynamic>> _wrapTo(LocalIdentity me, String circleId, int epoch, Uint8List key, DeviceKey to,
      {Uint8List? wrapperEdSeed, String? wrapperId}) async {
    final String wid = wrapperId ?? me.deviceId;
    // Hard rule (PRIVACY_PROCESSING 5.4.1): the phone key CK is NEVER wrapped to a server device.
    E2ee.checkWrapRecipient(E2ee.linePhone, to.kind, policyOn: false, hasServerLaneMember: false);
    final Uint8List aad = E2ee.wrapAad(circleId, epoch, to.deviceId, wid);
    final Uint8List blob = await E2ee.wrap(key, to.xPub, aad);
    final Uint8List sig = await E2ee.sign(wrapperEdSeed ?? me.edSeed, E2ee.wrapSigMessage(circleId, epoch, to.deviceId, wid, blob));
    return <String, dynamic>{
      'recipient_device_id': to.deviceId,
      'wrapper_device_id': wid,
      'wrapped_key': E2ee.b64(blob),
      'signature': E2ee.b64(sig),
    };
  }

  Future<Map<String, dynamic>> _epochBody(LocalIdentity me, int action, String circleId, int epoch, Uint8List key, List<Map<String, dynamic>> wraps) async {
    final Uint8List commit = await E2ee.keyCommitment(key, circleId, epoch);
    final Uint8List msg = E2ee.logActionMessage(action, me.userId, me.deviceId, circleId: circleId, epoch: epoch, ref: commit);
    return <String, dynamic>{
      'epoch': epoch,
      'wraps': wraps,
      'key_commitment': E2ee.b64(commit),
      'actor_device_id': me.deviceId,
      'log_signature': E2ee.b64(await E2ee.sign(me.edSeed, msg)),
    };
  }

  /// Keys to wrap a fresh key of [line] to: every approved active key whose
  /// registration verifies and that the wrap policy allows automatically.
  /// Others wait in the pending queue until the user confirms.
  ///
  /// The phone line (CK) NEVER includes a `server` key (a hard rule, checked
  /// again on the result). The server line (SK) includes the server key only
  /// when the caller passes [serverKey], i.e. it already verified that the
  /// admin policy is on, the key is the pinned one and at least one member is
  /// in lane server.
  Future<List<DeviceKey>> _recipients(CircleE2eeState st, LocalIdentity me,
      {int line = E2ee.linePhone, DeviceKey? serverKey, bool lanesOn = false}) async {
    final Set<String> own = st.allDevices.where((DeviceKey k) => k.userId == me.userId).map((DeviceKey k) => k.deviceId).toSet();
    final List<DeviceKey> out = <DeviceKey>[];
    for (final DeviceKey k in st.allDevices) {
      if (k.approved != true) continue;
      if (k.kind == 'server') {
        if (line == E2ee.lineServer && serverKey != null && k.deviceId == serverKey.deviceId) {
          E2ee.checkWrapRecipient(line, k.kind, policyOn: true, hasServerLaneMember: true);
          out.add(k);
        }
        continue;
      }
      if (k.deviceId == me.deviceId) {
        out.add(k);
        continue;
      }
      // In a circle with server processing (ADR 8.9) a bridge or a web viewer must NOT receive the phone key by default: it
      // would read phone-only members too. A bridge only ever gets the server key; a web viewer needs [confirmWrap]
      // with explicit informed approval.
      if (line == E2ee.linePhone && lanesOn && (k.kind == 'service' || k.kind == 'web')) continue;
      final WrapDecisionResult d = await decideWrap(key: k, selfUserId: me.userId, trust: trust, ownKnownDeviceIds: own);
      if (d.decision == WrapDecision.auto) out.add(k);
    }
    if (line == E2ee.linePhone && out.any((DeviceKey k) => k.kind == 'server')) {
      throw StateError('internal error: the phone key line must never be wrapped to a server key');
    }
    return out;
  }

  /// Whether server processing is on for [circleId] as far as the server says. Used only to WITHHOLD phone keys from
  /// bridges and web viewers (a wrong answer can only make the phone give less).
  Future<bool> lanesOn(String circleId) async {
    try {
      final ProcessingServerState ps = await api.processingState(circleId);
      return ps.serverAssist && !ps.legacy;
    } catch (_) {
      return false;
    }
  }

  /// Admin: switches a circle to Private mode. Generates the epoch-1 key on this
  /// phone, wraps it to every member key and sends only the wraps.
  Future<int> enableCircle(String circleId) async {
    final LocalIdentity me = (await identity())!;
    final CircleE2eeState st = await api.circleState(circleId);
    final int epoch = st.epoch + 1;
    final Uint8List key = E2ee.randomBytes(32);
    final List<Map<String, dynamic>> wraps = <Map<String, dynamic>>[
      for (final DeviceKey k in await _recipients(st, me)) await _wrapTo(me, circleId, epoch, key, k)
    ];
    await api.enable(circleId, await _epochBody(me, E2ee.actEnable, circleId, epoch, key, wraps));
    await vault.write(_ckName(circleId, epoch), key);
    return epoch;
  }

  /// Admin: publishes the next epoch after a member left or a key was revoked.
  Future<int> bumpEpoch(String circleId) async {
    final LocalIdentity me = (await identity())!;
    final CircleE2eeState st = await api.circleState(circleId);
    final int epoch = st.epoch + 1;
    final Uint8List key = E2ee.randomBytes(32);
    final bool lanes = await lanesOn(circleId);
    final List<Map<String, dynamic>> wraps = <Map<String, dynamic>>[
      for (final DeviceKey k in await _recipients(st, me, lanesOn: lanes)) await _wrapTo(me, circleId, epoch, key, k)
    ];
    await api.bumpEpoch(circleId, await _epochBody(me, E2ee.actEpoch, circleId, epoch, key, wraps));
    await vault.write(_ckName(circleId, epoch), key);
    return epoch;
  }

  /// Builds (but does not send) the next circle key epoch: the request body
  /// with the wraps under `epoch_wraps` and a commit step that stores the key on
  /// this phone. Used by the legacy upgrade, which sends it together with the
  /// signed policy in one request. The phone line is never wrapped to a server key.
  Future<({int epoch, Map<String, dynamic> body, Future<void> Function() commit})> prepareNextEpoch(String circleId) async {
    final LocalIdentity me = (await identity())!;
    final CircleE2eeState st = await api.circleState(circleId);
    final int epoch = st.epoch + 1;
    final Uint8List key = E2ee.randomBytes(32);
    // The upgrade turns server processing on in the same request: viewers and bridges get no phone key.
    final List<Map<String, dynamic>> wraps = <Map<String, dynamic>>[
      for (final DeviceKey k in await _recipients(st, me, lanesOn: true)) await _wrapTo(me, circleId, epoch, key, k)
    ];
    final Map<String, dynamic> b = await _epochBody(me, E2ee.actEpoch, circleId, epoch, key, wraps);
    b['epoch_wraps'] = b.remove('wraps');
    return (epoch: epoch, body: b, commit: () => vault.write(_ckName(circleId, epoch), key));
  }

  Future<void> disableCircle(String circleId) async {
    final LocalIdentity me = (await identity())!;
    final CircleE2eeState st = await api.circleState(circleId);
    final Uint8List msg = E2ee.logActionMessage(E2ee.actDisable, me.userId, me.deviceId, circleId: circleId, epoch: st.epoch);
    await api.disable(circleId, <String, dynamic>{
      'actor_device_id': me.deviceId,
      'log_signature': E2ee.b64(await E2ee.sign(me.edSeed, msg)),
    });
  }

  /// Wraps this phone refused in the last [syncCircleKeys] because the key did
  /// not match the publisher's signed commitment (or the epoch record was missing).
  int rejectedWraps = 0;

  /// Fetches wraps addressed to this phone and stores the circle keys. For each
  /// wrap: the wrapper signature must verify, the epoch's signed log record must
  /// verify (publisher signature), the AAD binds circle/epoch/recipient/wrapper,
  /// and the unwrapped key must match the publisher's KEY COMMITMENT. A bogus or
  /// substituted wrap therefore never gets stored. Returns the NEW keys stored.
  Future<int> syncCircleKeys(String circleId, {String? asDeviceId, Uint8List? xSecret, Uint8List? xPub}) async {
    final LocalIdentity me = (await identity())!;
    final String dev = asDeviceId ?? me.deviceId;
    final Uint8List sec = xSecret ?? me.xSecret;
    final Uint8List pub = xPub ?? me.xPub;
    final CircleE2eeState st = await api.circleState(circleId);
    int n = 0;
    rejectedWraps = 0;
    for (final WrapRecord w in await api.myWraps(circleId, dev)) {
      if (w.line != E2ee.linePhone) continue; // server-line wraps: syncServerKeys
      if (await vault.read(_ckName(circleId, w.epoch)) != null) continue;
      if (w.recipientDeviceId != dev) continue;
      final Uint8List sm = E2ee.wrapSigMessage(circleId, w.epoch, dev, w.wrapperDeviceId, w.blob);
      if (!await E2ee.verify(w.wrapperEdPub, sm, w.signature)) {
        rejectedWraps++;
        continue;
      }
      final EpochRecord? rec = st.epochRecord(w.epoch);
      if (rec == null || !await _epochRecordValid(circleId, rec)) {
        rejectedWraps++;
        continue;
      }
      try {
        final Uint8List key = await E2ee.unwrap(w.blob, sec, pub, E2ee.wrapAad(circleId, w.epoch, dev, w.wrapperDeviceId));
        final Uint8List commit = await E2ee.keyCommitment(key, circleId, w.epoch);
        if (!E2ee.constEq(commit, rec.commitment)) {
          rejectedWraps++;
          continue;
        }
        // The reverse of the SK check: a circle key that is (or commits like) a server line key
        // would hand the server every phone-line item. Refuse it and raise the severe alarm.
        if (await circleKeyIsServerKey(circleId, key)) {
          rejectedWraps++;
          await _raiseSkEqualsCk(circleId, ckSide: true);
          continue;
        }
        await vault.write(_ckName(circleId, w.epoch), key);
        n++;
      } on E2eeAuthException {
        rejectedWraps++;
        continue; // tampered or not for us
      }
    }
    return n;
  }

  Future<bool> _epochRecordValid(String circleId, EpochRecord rec) async {
    try {
      final Uint8List msg = E2ee.logActionMessage(rec.action, rec.publisherUserId, rec.publisherDeviceId,
          circleId: circleId, epoch: rec.epoch, ref: rec.commitment);
      return rec.action != E2ee.actDisable && await E2ee.verify(rec.publisherPub, msg, rec.signature);
    } catch (_) {
      return false;
    }
  }

  /// Wraps the current circle key for members' keys that lack one, following the
  /// policy: automatic where safe, otherwise returned for explicit confirmation.
  Future<PendingReport> processPending(String circleId) async {
    final LocalIdentity me = (await identity())!;
    final CircleE2eeState st = await api.circleState(circleId);
    if (!st.isPrivate) return const PendingReport();
    final Uint8List? key = await circleKey(circleId, st.epoch);
    // Only the publisher of the epoch (the admin who created it) may issue the key
    // to other people; anyone may wrap to their OWN other keys.
    final bool iAmPublisher = st.epochRecord(st.epoch)?.publisherUserId == me.userId;
    final List<DeviceKey> pending = await api.pending(circleId);
    final Set<String> own = st.allDevices.where((DeviceKey k) => k.userId == me.userId).map((DeviceKey k) => k.deviceId).toSet();
    final List<Map<String, dynamic>> wraps = <Map<String, dynamic>>[];
    final List<PendingItem> confirm = <PendingItem>[], waiting = <PendingItem>[], refused = <PendingItem>[];
    final bool lanes = await lanesOn(circleId);
    for (final DeviceKey k in pending) {
      if (k.kind == 'server') continue; // the server key never gets the phone key line
      if (lanes && k.kind == 'service') continue; // a bridge reads through the server line only
      if (lanes && k.kind == 'web') {
        confirm.add(PendingItem(k, const WrapDecisionResult(WrapDecision.confirm, 'a web viewer in a circle with server processing: needs your explicit approval')));
        continue;
      }
      final WrapDecisionResult d = await decideWrap(key: k, selfUserId: me.userId, trust: trust, ownKnownDeviceIds: own);
      switch (d.decision) {
        case WrapDecision.auto:
          if (key != null && (iAmPublisher || k.userId == me.userId)) wraps.add(await _wrapTo(me, circleId, st.epoch, key, k));
        case WrapDecision.confirm:
          confirm.add(PendingItem(k, d));
        case WrapDecision.waitingForApproval:
          waiting.add(PendingItem(k, d));
        case WrapDecision.refuse:
          refused.add(PendingItem(k, d));
      }
    }
    int stored = 0;
    if (wraps.isNotEmpty) stored = await api.submitWraps(circleId, st.epoch, wraps);
    return PendingReport(wrapped: stored, needConfirm: confirm, waiting: waiting, refused: refused);
  }

  /// After the user compared the safety number: wrap for [key] and (optionally)
  /// pin its owner as verified.
  Future<void> confirmWrap(String circleId, DeviceKey key, {bool markVerified = false, bool viewerInformed = false}) async {
    final LocalIdentity me = (await identity())!;
    final CircleE2eeState st = await api.circleState(circleId);
    final Uint8List? k = await circleKey(circleId, st.epoch);
    if (k == null) throw StateError('This phone does not hold the current circle key yet.');
    if (key.kind == 'server') {
      // The phone key never goes to the server key. The server line key (SK)
      // is wrapped by LanesService once the admin policy and a member's own
      // pref allow it.
      throw StateError('The server key never receives the phone circle key. Use the processing settings (server key line).');
    }
    if (key.kind == 'service' && await lanesOn(circleId)) {
      throw StateError('A bridge only gets the server key in a circle with server processing. It never receives the phone key.');
    }
    if (key.kind == 'web' && !viewerInformed && await lanesOn(circleId)) {
      throw StateError('Approving a web viewer for a circle with server processing needs the extra warning. Open Approve a viewer or bridge.');
    }
    if (st.epochRecord(st.epoch)?.publisherUserId != me.userId && key.userId != me.userId) {
      throw StateError('Only the admin who published this key epoch can share it with other members.');
    }
    await api.submitWraps(circleId, st.epoch, <Map<String, dynamic>>[await _wrapTo(me, circleId, st.epoch, k, key)]);
    if (markVerified) {
      final List<DeviceKey> all = await api.userKeys(key.userId);
      await trust.markVerified(key.userId, all.map((DeviceKey d) => d.fingerprint));
    }
  }

  // ------------------------------------------------ trusted-server mode

  /// The members that must consent before the server may read the circle: EVERY
  /// member (one without a phone key cannot consent, so the circle stays closed).
  static List<String> membersNeedingConsent(CircleE2eeState st) =>
      <String>[for (final CircleE2eeMember m in st.members) m.userId];

  /// Which members' consents verify (signature by one of THEIR active phone keys,
  /// naming this circle, this person and this exact server key). The server's own
  /// "server_member" claim is not used.
  Future<Set<String>> verifiedConsentUsers(CircleE2eeState st, ServerMemberState ss, DeviceKey serverKey) async {
    final Set<String> ok = <String>{};
    final Uint8List fp = E2ee.unhex(serverKey.fingerprint);
    for (final ServerConsent c in ss.consents) {
      final CircleE2eeMember? m = st.members.where((CircleE2eeMember x) => x.userId == c.userId).firstOrNull;
      final DeviceKey? d = m?.devices.where((DeviceKey x) => x.deviceId == c.approverDeviceId && x.kind == 'device' && x.isActive).firstOrNull;
      if (d == null) continue;
      try {
        if (await E2ee.verify(d.edPub, E2ee.serverConsentMessage(st.circleId, c.userId, serverKey.deviceId, fp), c.signature)) ok.add(c.userId);
      } catch (_) {}
    }
    return ok;
  }

  /// The pinned, active server key when the circle may give it the circle key:
  /// the server reports it as THE server device, its fingerprint matches the key
  /// in the circle state, and every member's consent verifies. Otherwise null.
  Future<DeviceKey?> allowedServerKey(CircleE2eeState st) async {
    if (!st.isPrivate) return null;
    final ServerMemberState ss;
    try {
      ss = await api.serverMemberState(st.circleId);
    } catch (_) {
      return null;
    }
    final DeviceKey? key = serverKeyOf(st, ss);
    if (key == null) return null;
    final Set<String> ok = await verifiedConsentUsers(st, ss, key);
    final List<String> need = membersNeedingConsent(st);
    return need.isNotEmpty && need.every(ok.contains) ? key : null;
  }

  /// The active `server` key of the circle state that matches the pinned device.
  static DeviceKey? serverKeyOf(CircleE2eeState st, ServerMemberState ss) {
    final ServerDeviceInfo? d = ss.device;
    if (!ss.enabled || d == null) return null;
    for (final DeviceKey k in st.allDevices) {
      if (k.deviceId == d.deviceId && k.kind == 'server' && k.isActive && k.approved == true && k.fingerprint == d.fingerprint) return k;
    }
    return null;
  }

  /// A member allows the OpenFamily server key to read this circle. The signature
  /// names the circle, this person and the exact key; it is made by this phone.
  Future<void> consentToServer(String circleId) async {
    final LocalIdentity me = (await identity())!;
    final CircleE2eeState st = await api.circleState(circleId);
    final ServerMemberState ss = await api.serverMemberState(circleId);
    final DeviceKey? key = serverKeyOf(st, ss);
    if (key == null) {
      throw StateError('This server has no approved server key for this circle. Enroll it first (see the docs), then approve it here.');
    }
    final Uint8List sig = await E2ee.sign(me.edSeed, E2ee.serverConsentMessage(circleId, me.userId, key.deviceId, E2ee.unhex(key.fingerprint)));
    await api.putServerConsent(circleId, <String, dynamic>{
      'server_device_id': key.deviceId,
      'approver_device_id': me.deviceId,
      'signature': E2ee.b64(sig),
    });
  }

  /// Withdraws this person's consent: the server stops reading the circle at once
  /// and the circle asks for a new key epoch (the server key is not wrapped again).
  Future<void> withdrawServerConsent(String circleId) => api.deleteServerConsent(circleId);

  /// Legacy trusted-server action. It used to wrap the CIRCLE key to the server
  /// key. That is no longer possible: the phone key line is never wrapped to a
  /// server key (PRIVACY_PROCESSING 5.4.1). The server line key is handled by
  /// `LanesService` (policy by the admin, pref by each member).
  Future<void> shareKeyWithServer(String circleId) async {
    throw StateError('The circle key is never shared with the server. Turn on server processing for this circle instead (each member decides for their own data).');
  }

  /// Deletes the plaintext copies the server made from this circle.
  Future<int> purgeServerCopies(String circleId, {bool wholeCircle = false}) =>
      api.purgeServerCopies(circleId, wholeCircle: wholeCircle);

  /// Circle admin: approves a replacement key for THIS circle after comparing
  /// its safety number out of band. Logged in the transparency log.
  Future<void> approveDevice(String circleId, DeviceKey key) async {
    final LocalIdentity me = (await identity())!;
    final Uint8List msg = E2ee.logActionMessage(E2ee.actApprove, me.userId, me.deviceId,
        circleId: circleId, subjectId: key.deviceId, ref: E2ee.unhex(key.fingerprint));
    await api.approve(circleId, <String, dynamic>{
      'device_id': key.deviceId,
      'actor_device_id': me.deviceId,
      'log_signature': E2ee.b64(await E2ee.sign(me.edSeed, msg)),
    });
  }

  Future<void> revokeKey(DeviceKey key) async {
    final LocalIdentity me = (await identity())!;
    final Uint8List msg = E2ee.logActionMessage(E2ee.actRevoke, me.userId, me.deviceId,
        subjectId: key.deviceId, ref: E2ee.unhex(key.fingerprint));
    await api.revoke(key.deviceId, <String, dynamic>{
      'actor_device_id': me.deviceId,
      'log_signature': E2ee.b64(await E2ee.sign(me.edSeed, msg)),
    });
  }

  // ---------------------------------------------------------- people

  /// Safety number between me and [userId], from the keys the server shows now.
  Future<({String number, List<DeviceKey> theirs, TrustAssessment trust})> safetyWith(String userId) async {
    final LocalIdentity me = (await identity())!;
    final List<DeviceKey> theirs = (await api.userKeys(userId)).where((DeviceKey k) => k.isActive).toList();
    final List<DeviceKey> mine = (await api.myKeys()).where((DeviceKey k) => k.isActive).toList();
    final String number = await E2ee.safetyNumber(
        me.userId, mine.map((DeviceKey k) => E2ee.unhex(k.fingerprint)).toList(),
        userId, theirs.map((DeviceKey k) => E2ee.unhex(k.fingerprint)).toList());
    TrustAssessment a = await trust.assess(userId, theirs.map((DeviceKey k) => k.fingerprint));
    if (a.level == TrustLevel.unseen && theirs.isNotEmpty) {
      // Trust on first use: remember what we saw so a later change is detected.
      await trust.rememberSeen(userId, theirs.map((DeviceKey k) => k.fingerprint));
      a = const TrustAssessment(TrustLevel.seen);
    }
    return (number: number, theirs: theirs, trust: a);
  }

  Future<void> markVerified(String userId) async {
    final List<DeviceKey> k = (await api.userKeys(userId)).where((DeviceKey d) => d.isActive).toList();
    await trust.markVerified(userId, k.map((DeviceKey d) => d.fingerprint));
  }

  /// Records what I saw so later changes are detected (trust on first use).
  Future<void> rememberPeers(CircleE2eeState st) async {
    for (final CircleE2eeMember m in st.members) {
      final List<String> fps = m.devices.map((DeviceKey d) => d.fingerprint).toList();
      if (fps.isEmpty) continue;
      if ((await trust.seenFingerprints(m.userId)).isEmpty) await trust.rememberSeen(m.userId, fps);
    }
  }

  // --------------------------------------------------------- invite anchor

  /// The fingerprint a link/QR should carry: this phone's own (non-recovery)
  /// key. It reaches the joiner outside the server.
  Future<String?> inviteFingerprint() async => (await identity())?.fingerprintHex;

  /// After joining via a link that carried the inviter's fingerprint [expected]:
  /// checks that the keys the SERVER now returns include it. Returns the inviter's
  /// user id when it matches (and pins them as verified), or null on a mismatch.
  Future<String?> checkInviter(String circleId, String expectedHex) async {
    final CircleE2eeState st = await api.circleState(circleId);
    for (final CircleE2eeMember m in st.members) {
      for (final DeviceKey d in m.devices) {
        if (E2ee.constEq(utf8.encode(d.fingerprint), utf8.encode(expectedHex.toLowerCase())) && await verifyRegistration(d)) {
          await trust.markVerified(m.userId, m.devices.map((DeviceKey x) => x.fingerprint), method: 'invite');
          return m.userId;
        }
      }
    }
    return null;
  }

  // ------------------------------------------------------------ recovery

  RecoverySetup newRecoverySetup() {
    final Uint8List entropy = E2ee.randomBytes(32);
    return RecoverySetup(entropy, bip39.entropyToMnemonic(E2ee.hex(entropy)));
  }

  /// Validates a typed phrase (checksum) and returns its entropy, or null.
  static Uint8List? entropyOf(String phrase) {
    final String p = phrase.trim().toLowerCase().split(RegExp(r'\s+')).join(' ');
    if (p.split(' ').length != 24 || !bip39.validateMnemonic(p)) return null;
    return E2ee.unhex(bip39.mnemonicToEntropy(p));
  }

  Future<({Uint8List edSeed, Uint8List edPub, Uint8List xSecret, Uint8List xPub, Uint8List fp})> _recoveryKeys(Uint8List entropy, String passphrase) async {
    final Uint8List seed = await E2ee.recoverySeed(entropy, passphrase: passphrase);
    final (Uint8List es, Uint8List xs) = await E2ee.recoveryIdentity(seed);
    final Uint8List ed = await E2ee.edPublicFromSeed(es), x = await E2ee.xPublicFromSecret(xs);
    return (edSeed: es, edPub: ed, xSecret: xs, xPub: x, fp: await E2ee.fingerprint(ed, x));
  }

  /// Registers the recovery identity (PUBLIC keys only), cross-signed by this
  /// phone, and wraps every circle key this phone holds to it.
  Future<DeviceKey> registerRecovery(Uint8List entropy, {String passphrase = ''}) async {
    final LocalIdentity me = (await identity())!;
    final r = await _recoveryKeys(entropy, passphrase);
    final String rid = E2ee.newUuid();
    final Uint8List binding = await E2ee.sign(r.edSeed, E2ee.bindingMessage(me.userId, rid, r.edPub, r.xPub));
    final Uint8List msg = E2ee.logActionMessage(E2ee.actRecovery, me.userId, me.deviceId, subjectId: rid, ref: r.fp);
    final DeviceKey rec = await api.register(<String, dynamic>{
      'device_id': rid,
      'kind': 'recovery',
      'ed25519_pub': E2ee.b64(r.edPub),
      'x25519_pub': E2ee.b64(r.xPub),
      'signature': E2ee.b64(binding),
      'label': 'Recovery phrase',
      'actor_device_id': me.deviceId,
      'log_signature': E2ee.b64(await E2ee.sign(me.edSeed, msg)),
    });
    await wrapHeldKeysTo(rec);
    return rec;
  }

  /// Wraps every epoch key this phone holds, per private circle, to [target]
  /// (the recovery identity or a new own device).
  Future<int> wrapHeldKeysTo(DeviceKey target, {LocalIdentity? as, Uint8List? wrapperEdSeed, String? wrapperId}) async {
    final LocalIdentity me = as ?? (await identity())!;
    int n = 0;
    final Set<String> circles = <String>{};
    for (final String name in await vault.names()) {
      if (name.startsWith('ck/')) circles.add(name.split('/')[1]);
    }
    // Only a phone or the recovery identity receives every phone key this way. A bridge, a web viewer or the server key
    // would read phone-only members too; they get phone keys only through [confirmWrap] (web, informed) and never as a bulk copy.
    final bool phoneKeys = target.kind == 'device' || target.kind == 'recovery';
    for (final String c in phoneKeys ? circles : <String>{}) {
      for (final int epoch in await heldEpochs(c)) {
        final Uint8List? key = await circleKey(c, epoch);
        if (key == null) continue;
        try {
          n += await api.submitWraps(c, epoch, <Map<String, dynamic>>[
            await _wrapTo(me, c, epoch, key, target, wrapperEdSeed: wrapperEdSeed, wrapperId: wrapperId)
          ]);
        } catch (_) {
          // Not a member any more, or the circle is no longer private: skip.
        }
      }
    }
    // Server-line keys follow the same rule, but a server-kind target never gets one here.
    final Set<String> skCircles = <String>{};
    for (final String name in await vault.names()) {
      if (name.startsWith('sk/')) skCircles.add(name.split('/')[1]);
    }
    if (target.kind != 'server') {
      for (final String c in skCircles) {
        for (final int gen in await heldServerGens(c)) {
          final Uint8List? key = await serverKey(c, gen);
          if (key == null) continue;
          try {
            n += await api.submitLineWraps(c, E2ee.lineServer, gen, <Map<String, dynamic>>[
              await wrapServerKeyTo(me, c, gen, key, target, wrapperEdSeed: wrapperEdSeed, wrapperId: wrapperId)
            ]);
          } catch (_) {}
        }
      }
    }
    return n;
  }

  /// New phone, nothing else available: derive the recovery identity from the
  /// typed phrase, register a NEW device key cross-signed by it, fetch and open
  /// the wraps addressed to the recovery identity, and wrap them to this phone.
  /// The caller should recommend rotating each circle's epoch afterwards.
  Future<RestoreResult> restoreFromPhrase(String phrase, {String passphrase = '', required List<String> circleIds}) async {
    final Uint8List? entropy = entropyOf(phrase);
    if (entropy == null) throw const E2eeFormatException('That is not a valid 24-word phrase (check spelling and order).');
    final r = await _recoveryKeys(entropy, passphrase);
    final List<DeviceKey> mine = await api.myKeys();
    DeviceKey? rec;
    for (final DeviceKey k in mine) {
      if (k.isRecovery && k.isActive && E2ee.constEq(k.edPub, r.edPub) && E2ee.constEq(k.xPub, r.xPub)) rec = k;
    }
    if (rec == null) {
      throw const E2eeAuthException('This phrase (and passphrase) does not match the recovery key registered for your account.');
    }
    final LocalIdentity me = (await identity(create: true))!;
    DeviceKey? self;
    for (final DeviceKey k in mine) {
      if (k.isActive && k.deviceId == me.deviceId) self = k;
    }
    self ??= await api.register(await _registrationBody(me,
        kind: 'device', action: E2ee.actRegister, actorDeviceId: rec.deviceId, actorEdSeed: r.edSeed, reset: false, label: 'Restored phone'));
    int opened = 0;
    final List<String> failed = <String>[];
    for (final String c in circleIds) {
      try {
        opened += await syncCircleKeys(c, asDeviceId: rec.deviceId, xSecret: r.xSecret, xPub: r.xPub);
        for (final int epoch in await heldEpochs(c)) {
          final Uint8List? key = await circleKey(c, epoch);
          if (key == null) continue;
          await api.submitWraps(c, epoch, <Map<String, dynamic>>[
            await _wrapTo(me, c, epoch, key, self, wrapperEdSeed: r.edSeed, wrapperId: rec.deviceId)
          ]);
        }
      } catch (_) {
        failed.add(c);
      }
    }
    return RestoreResult(opened, failed);
  }

  // ---------------------------------------------------------- transparency

  /// Fetches the log from the pinned head, verifies the chain and signatures,
  /// pins the new head and returns alarms. A problem is itself an alarm.
  Future<LogSync> syncLog({Map<String, String> userNames = const <String, String>{}, Map<String, String> circleNames = const <String, String>{}}) async {
    final LocalIdentity? me = await identity();
    final LogHead? pinned = await trust.pinnedHead();
    final int after = pinned == null ? 0 : (pinned.seq > 0 ? pinned.seq - 1 : 0);
    final r = await api.log(after);
    final LogCheck check = await verifyLogSlice(pinned: pinned, entries: r.entries, head: r.head);
    if (!check.ok) {
      return LogSync(check, <E2eeAlarm>[E2eeAlarm(AlarmKind.logProblem, 'Key log verification FAILED', check.detail)], r.head);
    }
    final List<E2eeAlarm> alarms = <E2eeAlarm>[
      if (me != null) ...await alarmsFromLog(events: check.events, selfUserId: me.userId, trust: trust, userNames: userNames, circleNames: circleNames),
      ...await laneAlarmList(),
    ];
    if (check.newHead != null && check.newHead!.seq > 0) await trust.pinHead(check.newHead!);
    return LogSync(check, alarms, check.newHead);
  }

  /// Compares a head someone read out to me ("seq:hash") with my pinned chain:
  /// true when the server's entry at that sequence number has that hash (so we
  /// were shown the same history). Different answers mean a split view.
  Future<bool?> compareHead(int seq, String hashHex) async {
    final r = await api.log(seq > 0 ? seq - 1 : 0);
    for (final LogEntry e in r.entries) {
      if (e.seq == seq) return E2ee.hex(e.entryHash) == hashHex.toLowerCase();
    }
    return null;
  }
}

class LinkApproval {
  const LinkApproval(this.actorDeviceId, this.signature);
  final String actorDeviceId;
  final Uint8List signature;
}

class LinkRequestInfo {
  const LinkRequestInfo(this.deviceId, this.fingerprint, this.short, this.digits, {this.kind, this.name});
  final String deviceId;

  /// 'web', 'service', 'device' or null (old request without the field = phone).
  final String? kind;
  final String? name;
  bool get isViewer => kind == 'web' || kind == 'service' || kind == 'server';
  bool get isServer => kind == 'server';
  final Uint8List fingerprint;
  final String short;
  final String digits;
}

class RestoreResult {
  const RestoreResult(this.keysRecovered, this.failedCircles);
  final int keysRecovered;
  final List<String> failedCircles;
}
