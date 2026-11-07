import 'dart:typed_data';

import 'package:openfamily/services/e2ee/e2ee_api.dart';
import 'package:openfamily/services/e2ee/e2ee_crypto.dart';
import 'package:openfamily/services/e2ee/e2ee_models.dart';
import 'package:openfamily/services/e2ee/lanes_wire.dart';
import 'package:openfamily/services/e2ee/private_channel.dart';

/// An in-memory stand-in for the Go server's E2EE endpoints. It keeps the same
/// rules that matter to the client (signatures are checked, wraps only to
/// approved keys, epochs strictly increasing, a real hash-chained log) so the
/// service can be tested end to end without HTTP.
class FakeE2eeServer {
  final Map<String, List<DeviceKey>> keys = <String, List<DeviceKey>>{};
  final Map<String, FakeCircle> circles = <String, FakeCircle>{};
  final Map<String, String> names = <String, String>{};
  final List<Map<String, dynamic>> log = <Map<String, dynamic>>[];

  /// When set, the next /e2ee/log call returns this instead (to simulate a
  /// malicious server).
  ({List<LogEntry> entries, LogHead head})? logOverride;

  FakeE2eeClient client(String userId) => FakeE2eeClient(this, userId);

  /// Trusted-server mode switch and the pinned server key (null = none yet).
  bool serverModeEnabled = false;
  bool trustedServerDefault = false;
  ServerProfile serverProfileValue = ServerProfile.unknown;
  String? pinnedServerDevice;

  /// Server clock (tests that use a fake clock set this to it).
  DateTime Function() now = () => DateTime.now().toUtc();

  /// Users whose registrations lose their `caps` (an app that predates lanes).
  final Set<String> oldAppUsers = <String>{};

  /// Every wrap the server ever accepted, as "line/gen/recipient" (never removed).
  final List<String> acceptedWraps = <String>[];

  FakeCircle circle(String id, {required List<String> members, required String admin}) =>
      circles[id] = FakeCircle(id, members, admin);

  Future<void> appendLog(int action, String userId, String actor, Uint8List actorPub,
      {String? circleId, String? subjectId, int epoch = 0, Uint8List? ref, required Uint8List sig}) async {
    final Uint8List msg = E2ee.logActionMessage(action, userId, actor,
        circleId: circleId, subjectId: subjectId, epoch: epoch, ref: ref);
    final Uint8List prev = log.isEmpty ? E2ee.genesisHash : log.last['entry_hash'] as Uint8List;
    final int seq = log.length + 1;
    log.add(<String, dynamic>{
      'seq': seq, 'prev': prev, 'entry_hash': await E2ee.logEntryHash(prev, seq, msg, sig),
      'action': action, 'user': userId, 'actor': actor, 'pub': actorPub, 'circle': circleId,
      'subject': subjectId, 'epoch': epoch, 'ref': ref ?? Uint8List(32), 'sig': sig,
    });
  }

  /// A member leaves or is removed: their wraps (both lines) and prefs go and the circle asks for a rekey.
  void removeMember(String circleId, String userId) {
    final FakeCircle c = circles[circleId]!;
    final Set<String> devs = <String>{for (final DeviceKey d in activeOf(userId)) d.deviceId};
    c.members.remove(userId);
    c.wraps.removeWhere((String _, WrapRecord w) => devs.contains(w.recipientDeviceId));
    c.skWraps.removeWhere((String _, WrapRecord w) => devs.contains(w.recipientDeviceId));
    c.prefs.remove(userId);
    c.rekey = true;
    if (c.assist) c.skRekey = true;
  }

  List<DeviceKey> activeOf(String user) => (keys[user] ?? <DeviceKey>[]).where((DeviceKey k) => k.isActive).toList();

  /// Transitive approval, like migration 000151: the key or ANY ancestor in its
  /// registration chain is the user's first key or was approved for the circle.
  bool approved(DeviceKey d, String circleId) {
    final Set<String> seen = <String>{};
    DeviceKey? cur = d;
    while (cur != null && seen.add(cur.deviceId)) {
      if (cur.initial || circles[circleId]!.approvals.contains(cur.deviceId)) return true;
      if (cur.isRoot) return false;
      cur = anyKey(cur.registeredByDeviceId);
    }
    return false;
  }

  DeviceKey? anyKey(String deviceId) {
    for (final List<DeviceKey> l in keys.values) {
      for (final DeviceKey k in l) {
        if (k.deviceId == deviceId) return k;
      }
    }
    return null;
  }

  DeviceKey? findActive(String deviceId) {
    for (final List<DeviceKey> l in keys.values) {
      for (final DeviceKey k in l) {
        if (k.deviceId == deviceId && k.isActive) return k;
      }
    }
    return null;
  }
}

class FakeCircle {
  FakeCircle(this.id, this.members, this.admin);
  final String id;
  final List<String> members;
  final String admin;
  String mode = 'off';
  int epoch = 0;
  bool rekey = false;
  final Set<String> approvals = <String>{};
  final Map<String, WrapRecord> wraps = <String, WrapRecord>{}; // "epoch/recipient"
  final Map<int, EpochRecord> epochRecords = <int, EpochRecord>{};

  /// Trusted-server mode: user -> {approver_device_id, signature}.
  final Map<String, ({String dev, Uint8List sig})> serverConsents = <String, ({String dev, Uint8List sig})>{};
  final List<String> serverPurges = <String>[];

  // ---- processing lanes (the server side of docs/design/PRIVACY_PROCESSING.md) ----
  PolicyStatement? policy;
  final List<PolicyStatement> policyHistory = <PolicyStatement>[];
  bool assist = false;
  int skGen = 0;
  final Map<String, PrefStatement> prefs = <String, PrefStatement>{}; // user -> latest
  final Map<String, WrapRecord> skWraps = <String, WrapRecord>{}; // "gen/recipient"

  /// The server line key must rotate (member removed / key revoked); cleared by a new generation.
  bool skRekey = false;

  /// Old trusted-server mode (server_legacy_ck): the circle can be upgraded by its admin.
  bool legacy = false;
  bool endedLegacyAccess = false;

  /// Upgraded circle whose server key still holds wraps of the old phone-key epochs.
  bool legacyAccessOpen = false;
}

class FakeE2eeClient implements E2eeApi {
  FakeE2eeClient(this.s, this.uid);
  final FakeE2eeServer s;
  final String uid;

  DeviceKey _mk(Map<String, dynamic> b, int action, Uint8List actorPub, bool initial, Uint8List fp) => DeviceKey(
        deviceId: b['device_id'] as String,
        userId: uid,
        kind: b['kind'] as String,
        edPub: E2ee.unb64(b['ed25519_pub']),
        xPub: E2ee.unb64(b['x25519_pub']),
        fingerprint: E2ee.hex(fp),
        digits: '',
        short: E2ee.shortFingerprint(fp),
        registeredByDeviceId: b['actor_device_id'] as String,
        registeredByPub: actorPub,
        registrationAction: action,
        registrationSignature: E2ee.unb64(b['log_signature']),
        initial: initial,
        label: (b['label'] as String?) ?? '',
        createdAt: DateTime.now().toUtc(),
        caps: s.oldAppUsers.contains(uid) || b['caps'] is! List ? const <String>[] : (b['caps'] as List<dynamic>).cast<String>(),
      );

  @override
  Future<DeviceKey> register(Map<String, dynamic> b) async {
    final List<DeviceKey> mine = s.keys.putIfAbsent(uid, () => <DeviceKey>[]);
    final Uint8List ed = E2ee.unb64(b['ed25519_pub']), x = E2ee.unb64(b['x25519_pub']);
    final String did = b['device_id'] as String;
    if (!await E2ee.verify(ed, E2ee.bindingMessage(uid, did, ed, x), E2ee.unb64(b['signature']))) {
      throw StateError('bad binding');
    }
    final Uint8List fp = await E2ee.fingerprint(ed, x);
    final String actor = (b['actor_device_id'] as String?) ?? did;
    final bool root = actor == did;
    final Uint8List signerPub = root ? ed : mine.firstWhere((DeviceKey k) => k.deviceId == actor && k.isActive).edPub;
    final bool anyActive = mine.any((DeviceKey k) => k.isActive);
    int action;
    bool initial = false;
    if (root) {
      if (mine.isEmpty) {
        action = E2ee.actRegister;
        initial = true;
      } else if (anyActive && b['reset'] != true) {
        throw StateError('cross_signature_required');
      } else {
        action = E2ee.actReset;
      }
    } else {
      action = b['kind'] == 'recovery' ? E2ee.actRecovery : E2ee.actRegister;
    }
    if (!await E2ee.verify(signerPub, E2ee.logActionMessage(action, uid, actor, subjectId: did, ref: fp), E2ee.unb64(b['log_signature']))) {
      throw StateError('bad log signature');
    }
    if (root && action == E2ee.actReset) {
      for (int i = 0; i < mine.length; i++) {
        if (mine[i].isActive) mine[i] = _revoked(mine[i]);
      }
    }
    final DeviceKey d = _mk(b, action, signerPub, initial, fp);
    mine.add(d);
    await s.appendLog(action, uid, actor, signerPub, subjectId: did, ref: fp, sig: E2ee.unb64(b['log_signature']));
    return d;
  }

  DeviceKey _revoked(DeviceKey k) => DeviceKey(
        deviceId: k.deviceId, userId: k.userId, kind: k.kind, edPub: k.edPub, xPub: k.xPub,
        fingerprint: k.fingerprint, digits: k.digits, short: k.short,
        registeredByDeviceId: k.registeredByDeviceId, registeredByPub: k.registeredByPub,
        registrationAction: k.registrationAction, registrationSignature: k.registrationSignature,
        initial: k.initial, label: k.label, createdAt: k.createdAt, revokedAt: DateTime.now().toUtc(), revokedReason: 'revoked', caps: k.caps);

  @override
  Future<List<DeviceKey>> myKeys() async => List<DeviceKey>.of(s.keys[uid] ?? <DeviceKey>[]);

  @override
  Future<void> revoke(String deviceId, Map<String, dynamic> a) async {
    final List<DeviceKey> l = s.keys[uid]!;
    final int i = l.indexWhere((DeviceKey k) => k.deviceId == deviceId && k.isActive);
    if (i < 0) throw StateError('not found');
    l[i] = _revoked(l[i]);
    for (final FakeCircle c in s.circles.values) {
      c.wraps.removeWhere((String _, WrapRecord w) => w.recipientDeviceId == deviceId);
      c.skWraps.removeWhere((String _, WrapRecord w) => w.recipientDeviceId == deviceId);
      if (c.mode == 'private') c.rekey = true;
      if (c.assist) c.skRekey = true;
    }
  }

  @override
  Future<List<DeviceKey>> userKeys(String userId) async => s.activeOf(userId);

  @override
  Future<bool> trustedServerDefault() async => s.trustedServerDefault;

  @override
  Future<ServerProfile> serverProfile() async => s.serverProfileValue;

  @override
  Future<ServerMemberState> serverMemberState(String circleId) async {
    final FakeCircle c = s.circles[circleId]!;
    if (!s.serverModeEnabled) return ServerMemberState.off;
    final DeviceKey? d = s.pinnedServerDevice == null ? null : s.findActive(s.pinnedServerDevice!);
    return ServerMemberState(
      enabled: true,
      device: d == null
          ? null
          : ServerDeviceInfo(deviceId: d.deviceId, fingerprint: d.fingerprint, short: d.short, digits: d.digits, label: d.label, ownerUserId: d.userId),
      wrapped: d != null && c.wraps.containsKey('${c.epoch}/${d.deviceId}'),
      myConsent: c.serverConsents.containsKey(uid),
      consents: <ServerConsent>[
        for (final MapEntry<String, ({String dev, Uint8List sig})> e in c.serverConsents.entries)
          ServerConsent(e.key, e.value.dev, e.value.sig)
      ],
    );
  }

  @override
  Future<void> putServerConsent(String circleId, Map<String, dynamic> body) async {
    final FakeCircle c = s.circles[circleId]!;
    final DeviceKey a = s.findActive(body['approver_device_id'] as String)!;
    if (a.userId != uid || a.kind != 'device') throw StateError('approver must be my phone key');
    final DeviceKey srv = s.findActive(body['server_device_id'] as String)!;
    final Uint8List sig = E2ee.unb64(body['signature']);
    if (!await E2ee.verify(a.edPub, E2ee.serverConsentMessage(circleId, uid, srv.deviceId, E2ee.unhex(srv.fingerprint)), sig)) {
      throw StateError('consent signature does not verify');
    }
    c.serverConsents[uid] = (dev: a.deviceId, sig: sig);
  }

  @override
  Future<void> deleteServerConsent(String circleId) async {
    final FakeCircle c = s.circles[circleId]!;
    c.serverConsents.remove(uid);
    c.rekey = true;
  }

  @override
  Future<int> purgeServerCopies(String circleId, {bool wholeCircle = false}) async {
    s.circles[circleId]!.serverPurges.add(wholeCircle ? 'circle' : 'mine');
    return 3;
  }

  @override
  Future<CircleE2eeState> circleState(String circleId) async {
    final FakeCircle c = s.circles[circleId]!;
    if (!c.members.contains(uid)) throw StateError('404');
    return CircleE2eeState(
      circleId: circleId, mode: c.mode, epoch: c.epoch, rekeyRequired: c.rekey,
      epochs: c.epochRecords.values.toList(),
      members: <CircleE2eeMember>[
        for (final String m in c.members)
          CircleE2eeMember(userId: m, name: s.names[m] ?? m, role: m == c.admin ? 'admin' : 'member', devices: <DeviceKey>[
            for (final DeviceKey d in s.activeOf(m)) _withApproval(d, s.approved(d, circleId), s.names[m])
          ])
      ],
    );
  }

  DeviceKey _withApproval(DeviceKey d, bool ok, String? name) => DeviceKey(
        deviceId: d.deviceId, userId: d.userId, kind: d.kind, edPub: d.edPub, xPub: d.xPub,
        fingerprint: d.fingerprint, digits: d.digits, short: d.short, registeredByDeviceId: d.registeredByDeviceId,
        registeredByPub: d.registeredByPub, registrationAction: d.registrationAction,
        registrationSignature: d.registrationSignature, initial: d.initial, label: d.label,
        createdAt: d.createdAt, approved: ok, userName: name, caps: d.caps);

  @override
  Future<List<WrapRecord>> myWraps(String circleId, String deviceId) async {
    final FakeCircle c = s.circles[circleId]!;
    final DeviceKey? d = s.findActive(deviceId);
    if (d == null || d.userId != uid) return <WrapRecord>[];
    return <WrapRecord>[
      ...c.wraps.values.where((WrapRecord w) => w.recipientDeviceId == deviceId),
      ...c.skWraps.values.where((WrapRecord w) => w.recipientDeviceId == deviceId),
    ];
  }

  @override
  Future<List<DeviceKey>> pending(String circleId) async {
    final FakeCircle c = s.circles[circleId]!;
    return <DeviceKey>[
      for (final String m in c.members)
        for (final DeviceKey d in s.activeOf(m))
          if (!c.wraps.containsKey('${c.epoch}/${d.deviceId}')) _withApproval(d, s.approved(d, circleId), s.names[m])
    ];
  }

  Future<void> _store(FakeCircle c, int epoch, List<Map<String, dynamic>> wraps) async {
    for (final Map<String, dynamic> w in wraps) {
      final DeviceKey r = s.findActive(w['recipient_device_id'] as String)!;
      if (!c.members.contains(r.userId)) throw StateError('recipient not a member');
      if (r.kind == 'server') throw StateError('403 the phone key line is never wrapped to a server key'); // mirrors the DB trigger
      if (!s.approved(r, c.id)) throw StateError('waiting for approval');
      if (r.userId != uid && c.epochRecords[epoch]?.publisherUserId != uid) {
        throw StateError('only the epoch publisher may wrap for other members');
      }
      final DeviceKey wr = s.findActive(w['wrapper_device_id'] as String)!;
      if (wr.userId != uid) throw StateError('wrapper not mine');
      final Uint8List blob = E2ee.unb64(w['wrapped_key']);
      final Uint8List sm = E2ee.wrapSigMessage(c.id, epoch, r.deviceId, wr.deviceId, blob);
      if (!await E2ee.verify(wr.edPub, sm, E2ee.unb64(w['signature']))) throw StateError('bad wrap sig');
      c.wraps['$epoch/${r.deviceId}'] = WrapRecord(
          epoch: epoch, recipientDeviceId: r.deviceId, wrapperDeviceId: wr.deviceId,
          wrapperEdPub: wr.edPub, blob: blob, signature: E2ee.unb64(w['signature']));
    }
  }

  Future<void> _epoch(String circleId, Map<String, dynamic> body, int action, {required bool enabling}) async {
    final FakeCircle c = s.circles[circleId]!;
    if (c.admin != uid) throw StateError('403');
    final int epoch = body['epoch'] as int;
    if (epoch != c.epoch + 1) throw StateError('409 epoch');
    if (enabling != (c.mode == 'off')) throw StateError('409 mode');
    final List<Map<String, dynamic>> wraps = (body['wraps'] as List<dynamic>).cast<Map<String, dynamic>>();
    final String actor = body['actor_device_id'] as String;
    final DeviceKey a = s.findActive(actor)!;
    final Uint8List commit = E2ee.unb64(body['key_commitment']);
    final Uint8List sig = E2ee.unb64(body['log_signature']);
    if (!await E2ee.verify(a.edPub, E2ee.logActionMessage(action, uid, actor, circleId: circleId, epoch: epoch, ref: commit), sig)) {
      throw StateError('bad log signature');
    }
    c.epochRecords[epoch] = EpochRecord(
        epoch: epoch, action: action, publisherUserId: uid, publisherDeviceId: actor,
        publisherPub: a.edPub, commitment: commit, signature: sig);
    await _store(c, epoch, wraps);
    await s.appendLog(action, uid, actor, a.edPub, circleId: circleId, epoch: epoch, ref: commit, sig: sig);
    c.mode = 'private';
    c.epoch = epoch;
    c.rekey = false;
  }

  @override
  Future<void> enable(String circleId, Map<String, dynamic> body) => _epoch(circleId, body, E2ee.actEnable, enabling: true);

  @override
  Future<void> bumpEpoch(String circleId, Map<String, dynamic> body) => _epoch(circleId, body, E2ee.actEpoch, enabling: false);

  @override
  Future<void> disable(String circleId, Map<String, dynamic> a) async {
    final FakeCircle c = s.circles[circleId]!;
    if (c.admin != uid) throw StateError('403');
    c.mode = 'off';
    c.wraps.clear();
  }

  @override
  Future<int> submitWraps(String circleId, int epoch, List<Map<String, dynamic>> wraps) async {
    final FakeCircle c = s.circles[circleId]!;
    if (!c.members.contains(uid)) throw StateError('404');
    if (epoch < 1 || epoch > c.epoch) throw StateError('409');
    final int before = c.wraps.length;
    await _store(c, epoch, wraps);
    return c.wraps.length - before;
  }

  @override
  Future<void> approve(String circleId, Map<String, dynamic> body) async {
    final FakeCircle c = s.circles[circleId]!;
    if (c.admin != uid) throw StateError('403');
    final DeviceKey d = s.findActive(body['device_id'] as String)!;
    if (d.userId == uid) throw StateError('403 self');
    final DeviceKey a = s.findActive(body['actor_device_id'] as String)!;
    final Uint8List sig = E2ee.unb64(body['log_signature']);
    final Uint8List fp = E2ee.unhex(d.fingerprint);
    if (!await E2ee.verify(a.edPub, E2ee.logActionMessage(E2ee.actApprove, uid, a.deviceId, circleId: circleId, subjectId: d.deviceId, ref: fp), sig)) {
      throw StateError('bad approval signature');
    }
    await s.appendLog(E2ee.actApprove, uid, a.deviceId, a.edPub, circleId: circleId, subjectId: d.deviceId, ref: fp, sig: sig);
    c.approvals.add(d.deviceId);
  }

  // ------------------------------------------------------ processing lanes

  DeviceKey? _serverDevice() => s.pinnedServerDevice == null ? null : s.findActive(s.pinnedServerDevice!);

  @override
  Future<ProcessingServerState> processingState(String circleId) async {
    final FakeCircle c = s.circles[circleId]!;
    if (!c.members.contains(uid)) throw StateError('404');
    final DeviceKey? srv = _serverDevice();
    return ProcessingServerState(
      serverAssist: c.assist,
      skGen: c.skGen,
      policy: c.policy,
      policyHistory: c.policyHistory,
      prefs: c.prefs.values.toList(),
      claimedMembers: <ClaimedMember>[
        for (final String m in c.members)
          ClaimedMember(m, c.prefs[m]?.lane ?? E2ee.linePhone, c.prefs[m]?.sinceMs ?? 0),
      ],
      serverDeviceId: srv?.deviceId,
      serverFingerprint: srv?.fingerprint,
      rekeyRequired: c.skRekey,
      inEffect: srv != null && c.assist && c.skWraps.containsKey('${c.skGen}/${srv.deviceId}'),
      legacy: c.legacy,
      legacyAccessOpen: c.legacyAccessOpen,
    );
  }

  @override
  Future<void> endLegacyServerAccess(String circleId) async {
    final FakeCircle c = s.circles[circleId]!;
    if (c.admin != uid) throw StateError('403');
    c.endedLegacyAccess = true;
    c.legacyAccessOpen = false;
  }

  @override
  Future<void> upgradeProcessing(String circleId, Map<String, dynamic> body) async {
    final FakeCircle c = s.circles[circleId]!;
    if (c.admin != uid) throw StateError('403');
    if (!c.legacy) throw StateError('409 not_legacy');
    final Map<String, dynamic> pol = (body['policy'] as Map<String, dynamic>);
    await _epoch(circleId, <String, dynamic>{...body, 'wraps': body['epoch_wraps']}, E2ee.actEpoch, enabling: false);
    c.legacy = false;
    c.legacyAccessOpen = true;
    await putProcessingPolicy(circleId, pol);
  }

  @override
  Future<List<DeviceKey>> pendingLine(String circleId, int line) async {
    if (line == E2ee.linePhone) return pending(circleId);
    final FakeCircle c = s.circles[circleId]!;
    if (!c.assist) return <DeviceKey>[];
    return <DeviceKey>[
      for (final String m in c.members)
        for (final DeviceKey d in s.activeOf(m))
          if (d.kind != 'server' && !c.skWraps.containsKey('${c.skGen}/${d.deviceId}')) _withApproval(d, s.approved(d, circleId), s.names[m])
    ];
  }

  bool _hasServerPref(FakeCircle c) => c.prefs.values.any((PrefStatement p) => p.lane == E2ee.lineServer);

  /// Stores SK wraps like the DB trigger and the handler would: no CK semantics,
  /// server key only while the policy is on and a member is in lane server.
  Future<void> _storeSk(FakeCircle c, int gen, List<Map<String, dynamic>> wraps) async {
    for (final Map<String, dynamic> w in wraps) {
      final DeviceKey r = s.findActive(w['recipient_device_id'] as String)!;
      if (!c.members.contains(r.userId)) throw StateError('recipient not a member');
      if (!s.approved(r, c.id)) throw StateError('waiting for approval');
      if (r.kind == 'server' && (!c.assist || !_hasServerPref(c))) {
        throw StateError('403 the server key may only get SK while assistance is on and a member is in lane server');
      }
      final DeviceKey wr = s.findActive(w['wrapper_device_id'] as String)!;
      if (wr.userId != uid) throw StateError('wrapper not mine');
      if (r.userId != uid && c.admin != uid) throw StateError('only an admin may wrap SK for other members');
      final Uint8List blob = E2ee.unb64(w['wrapped_key']);
      final Uint8List sig = E2ee.unb64(w['signature']);
      if (!await E2ee.verifyWrapSignatureLine(wr.edPub, c.id, E2ee.lineServer, gen, r.deviceId, wr.deviceId, blob, sig)) {
        throw StateError('bad wrap sig');
      }
      c.skWraps['$gen/${r.deviceId}'] = WrapRecord(
          line: E2ee.lineServer, epoch: gen, recipientDeviceId: r.deviceId, wrapperDeviceId: wr.deviceId,
          wrapperEdPub: wr.edPub, blob: blob, signature: sig);
      s.acceptedWraps.add('server/$gen/${r.deviceId}');
    }
  }

  @override
  Future<int> submitLineWraps(String circleId, int line, int gen, List<Map<String, dynamic>> wraps) async {
    final FakeCircle c = s.circles[circleId]!;
    if (!c.members.contains(uid)) throw StateError('404');
    if (line != E2ee.lineServer) throw StateError('use submitWraps for the phone line');
    if (gen < 1 || gen > c.skGen) throw StateError('409 gen');
    final int before = c.skWraps.length;
    await _storeSk(c, gen, wraps);
    return c.skWraps.length - before;
  }

  @override
  Future<void> putProcessingPolicy(String circleId, Map<String, dynamic> body) async {
    final FakeCircle c = s.circles[circleId]!;
    if (c.admin != uid) throw StateError('403');
    final PolicyStatement? st = PolicyStatement.tryParse(<String, dynamic>{...body, 'since': s.now().toIso8601String()});
    if (st == null) throw StateError('400');
    if (st.adminUserId != uid) throw StateError('403 admin mismatch');
    final DeviceKey a = s.findActive(st.actorDeviceId)!;
    if (a.userId != uid || a.kind != 'device') throw StateError('actor must be my phone key');
    final Uint8List msg = st.message(circleId);
    if (!await E2ee.verify(a.edPub, msg, st.signature)) throw StateError('bad statement signature');
    final Uint8List ref = await E2ee.processingRef(msg);
    final Uint8List logSig = E2ee.unb64(body['log_signature']);
    if (!await E2ee.verify(
        a.edPub, E2ee.logActionMessage(E2ee.actProcessingPolicy, uid, a.deviceId, circleId: circleId, epoch: st.skGen, ref: ref), logSig)) {
      throw StateError('bad log signature');
    }
    final List<Map<String, dynamic>> wraps = ((body['wraps'] as List<dynamic>?) ?? <dynamic>[]).cast<Map<String, dynamic>>();
    if (st.serverAssist) {
      // lanes2 gate, like the real handler: every approved phone key must advertise it to TURN ON.
      if (!c.assist) {
        for (final String m in c.members) {
          for (final DeviceKey d in s.activeOf(m)) {
            if (d.kind == 'device' && s.approved(d, circleId) && !d.supportsLanes) throw StateError('409 member app too old');
          }
        }
      }
      if (_serverDevice() == null) throw StateError('409 no server key');
      if (st.skGen > c.skGen) {
        if (st.skGen != c.skGen + 1) throw StateError('409 sk gen');
        // a new generation: the server key loses every old wrap (it must be re-wrapped by a phone)
        c.skGen = st.skGen;
        c.skRekey = false;
        final String? sd = _serverDevice()?.deviceId;
        if (sd != null) c.skWraps.removeWhere((String _, WrapRecord w) => w.recipientDeviceId == sd);
      } else if (wraps.isNotEmpty) {
        throw StateError('409 wraps without a new generation');
      }
      c.assist = true;
    } else {
      c.assist = false;
      // switching off ends every consent and takes the server key's SK wraps away
      c.prefs.removeWhere((String _, PrefStatement p) => p.lane == E2ee.lineServer);
      final String? sd = _serverDevice()?.deviceId;
      if (sd != null) c.skWraps.removeWhere((String _, WrapRecord w) => w.recipientDeviceId == sd);
    }
    if (wraps.isNotEmpty) await _storeSk(c, st.skGen, wraps);
    if (c.policy != null) c.policyHistory.add(c.policy!);
    c.policy = st;
    c.policyHistory.add(st);
    await s.appendLog(E2ee.actProcessingPolicy, uid, a.deviceId, a.edPub, circleId: circleId, epoch: st.skGen, ref: ref, sig: logSig);
  }

  @override
  Future<void> putProcessingPref(String circleId, Map<String, dynamic> body) async {
    final FakeCircle c = s.circles[circleId]!;
    if (!c.members.contains(uid)) throw StateError('404');
    final PrefStatement? st = PrefStatement.tryParse(<String, dynamic>{...body, 'user_id': uid, 'since': s.now().toIso8601String()});
    if (st == null) throw StateError('400');
    final DeviceKey a = s.findActive(st.approverDeviceId)!;
    if (a.userId != uid || a.kind != 'device') throw StateError('approver must be my phone key');
    Uint8List fp = Uint8List(32);
    if (st.lane == E2ee.lineServer) {
      final DeviceKey? srv = _serverDevice();
      if (!c.assist || srv == null || srv.deviceId != st.serverDeviceId || st.skGen < 1 || st.skGen > c.skGen) {
        throw StateError('409 server lane not possible');
      }
      fp = E2ee.unhex(srv.fingerprint);
    }
    final Uint8List msg = st.message(circleId, fp);
    if (!await E2ee.verify(a.edPub, msg, st.signature)) throw StateError('bad statement signature');
    final Uint8List ref = await E2ee.processingRef(msg);
    final Uint8List logSig = E2ee.unb64(body['log_signature']);
    final String? subject = st.lane == E2ee.lineServer ? st.serverDeviceId : null;
    if (!await E2ee.verify(
        a.edPub, E2ee.logActionMessage(E2ee.actProcessingPref, uid, a.deviceId, circleId: circleId, subjectId: subject, epoch: st.skGen, ref: ref), logSig)) {
      throw StateError('bad log signature');
    }
    c.prefs[uid] = st;
    await s.appendLog(E2ee.actProcessingPref, uid, a.deviceId, a.edPub, circleId: circleId, subjectId: subject, epoch: st.skGen, ref: ref, sig: logSig);
  }

  @override
  Future<({List<LogEntry> entries, LogHead head})> log(int after) async {
    if (s.logOverride != null) return s.logOverride!;
    final List<Map<String, dynamic>> rows = s.log.where((Map<String, dynamic> e) => (e['seq'] as int) > after).toList();
    return (
      entries: <LogEntry>[
        for (final Map<String, dynamic> e in rows)
          LogEntry(
            seq: e['seq'] as int, prevHash: e['prev'] as Uint8List, entryHash: e['entry_hash'] as Uint8List, redacted: false,
            action: e['action'] as int, userId: e['user'] as String, actorDeviceId: e['actor'] as String,
            actorPub: e['pub'] as Uint8List, circleId: e['circle'] as String?, subjectId: e['subject'] as String?,
            epoch: e['epoch'] as int, ref: e['ref'] as Uint8List, signature: e['sig'] as Uint8List),
      ],
      head: s.log.isEmpty ? LogHead(0, Uint8List(32)) : LogHead(s.log.length, s.log.last['entry_hash'] as Uint8List),
    );
  }
}

/// Item relay with the server's lane rules, for tests (stands in for
/// POST/GET /circles/{id}/e2ee/batch|items): idempotent by (circle, device,
/// seq), routing label `key_line`, and the checks the real handler makes:
/// a server-line item is refused while assistance is off or for a generation
/// that does not exist yet. Everything it stores is what the real server would
/// see, so tests can assert what reached it.
class FakeLaneChannel implements ChannelApi {
  FakeLaneChannel(this.server);
  final FakeE2eeServer server;
  final List<WireItem> items = <WireItem>[];

  /// Every item that was POSTed in a request, in order, as "circle/device/seq/line".
  final List<String> uploaded = <String>[];
  bool offline = false;

  /// When set, GET answers with this `key_line` instead of the stored one (a lying server).
  int? lieLine;

  /// When true, GET leaves `key_line` out.
  bool omitLine = false;

  int posts = 0;

  @override
  Future<List<BatchResult>> postBatch(String circleId, String deviceId, List<WireItem> batch) async {
    posts++;
    if (offline) throw StateError('offline');
    final FakeCircle c = server.circles[circleId]!;
    final List<BatchResult> out = <BatchResult>[];
    for (final WireItem i in batch) {
      uploaded.add('$circleId/$deviceId/${i.seq}/${i.line}');
      if (i.line == E2ee.lineServer && (!c.assist || i.epoch < 1 || i.epoch > c.skGen)) {
        out.add(BatchResult(i.seq, 'rejected', error: 'server line not available'));
        continue;
      }
      final bool dup = items.any((WireItem x) => x.circleId == circleId && x.deviceId == deviceId && x.seq == i.seq);
      if (dup) {
        out.add(BatchResult(i.seq, 'duplicate'));
      } else {
        items.add(WireItem(
            circleId: circleId, deviceId: deviceId, seq: i.seq, purpose: i.purpose, epoch: i.epoch, sizeBucket: i.sizeBucket,
            ciphertext: i.ciphertext, id: items.length + 1, line: i.line));
        out.add(BatchResult(i.seq, 'stored'));
      }
    }
    return out;
  }

  @override
  Future<Page> pull(String circleId, int after, {List<String>? purposes, int limit = 200}) async {
    final List<WireItem> all = items
        .where((WireItem i) => i.circleId == circleId && i.id! > after && (purposes == null || purposes.contains(i.purpose)))
        .toList();
    final List<WireItem> page = all.take(limit).toList();
    return Page(
        <WireItem>[
          for (final WireItem i in page)
            WireItem(
                circleId: i.circleId, deviceId: i.deviceId, seq: i.seq, purpose: i.purpose, epoch: i.epoch, sizeBucket: i.sizeBucket,
                ciphertext: i.ciphertext, id: i.id, line: i.line, declaredLine: omitLine ? null : (lieLine ?? i.line))
        ],
        page.isEmpty ? after : page.last.id!,
        all.length > page.length);
  }
}
