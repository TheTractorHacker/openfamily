import 'dart:typed_data';

import '../api_client.dart' show ApiException;
import 'e2ee_api.dart';
import 'e2ee_crypto.dart';
import 'e2ee_models.dart';
import 'e2ee_service.dart';
import 'e2ee_trust.dart';
import 'lanes_store.dart';
import 'lanes_wire.dart';
import 'private_channel.dart';

// Phase 4 of docs/design/PRIVACY_PROCESSING.md: the phone's side of processing
// lanes. This service takes nothing on the server's word:
//
//  * a member's lane is the latest `processing_pref` entry of the TRANSPARENCY
//    LOG for that member, signed by one of THEIR phone keys; a server-lane
//    entry also needs the signed statement that names the exact server key;
//  * the circle policy is the latest `processing_policy` entry, signed by a
//    key of a CIRCLE ADMIN, whose statement signature and commitment verify
//    and which a hash in the log pins;
//  * the server line key SK is accepted only if it matches that commitment;
//  * anything that does not verify means: phone lane, assistance off.
//
// Nothing here logs keys, statements or coordinates.

/// An admin cannot enable server assistance while some member's app cannot read it.
class LanesNotReady implements Exception {
  const LanesNotReady(this.names);

  /// Display names (or user ids) of the members who must update their app.
  final List<String> names;
  @override
  String toString() => 'LanesNotReady(${names.length} members)';
}

/// One member of the circle with their VERIFIED lane.
class MemberLaneView {
  const MemberLaneView(this.userId, this.lane, this.sinceMs, {required this.verified});
  final String userId;

  /// [E2ee.linePhone] / [E2ee.lineServer].
  final int lane;
  final int sinceMs;

  /// Whether a signed pref backs this (false: no pref, so phone by default).
  final bool verified;

  bool get serverAssisted => lane == E2ee.lineServer;
}

/// The result of one verification pass over a circle.
class CircleLanes {
  const CircleLanes({
    required this.policy,
    required this.members,
    required this.status,
    this.problem,
    this.state,
    this.proc,
    this.serverKey,
  });
  final StoredPolicy policy;
  final List<MemberLaneView> members;
  final LaneStatus status;
  final String? problem;

  /// Inputs of the pass (for the publisher duties).
  final CircleE2eeState? state;
  final ProcessingServerState? proc;

  /// The pinned server device if it is valid in the circle (active, approved, fingerprint matches).
  final DeviceKey? serverKey;
}

class LanesService {
  LanesService({
    required this.service,
    required this.api,
    required this.kv,
    this.clock = const Clock(),
    this.onLaneChanged,
    this.logTtl = const Duration(seconds: 30),
  }) : store = LaneStore(kv);

  final E2eeService service;
  final E2eeApi api;
  final ChannelKv kv;
  final Clock clock;
  final LaneStore store;

  /// Called right after this phone's own effective lane for a circle changed,
  /// BEFORE any further network call, so the runtime can re-seal / drop queued items.
  Future<void> Function(String circleId)? onLaneChanged;
  Duration logTtl;

  ({DateTime at, List<LogEntry> entries})? _logCache;

  String _rotKey(String c) => 'lanes/rotdue/$c';

  // ------------------------------------------------------------------ log

  /// The whole key log, verified from entry 1 and against my pinned head. Null
  /// on a verification failure (rollback, fork, bad signature...). Throws on
  /// a transport error (the caller then keeps what it already has).
  Future<List<LogEntry>?> _verifiedLog({bool force = false}) async {
    final ({DateTime at, List<LogEntry> entries})? c = _logCache;
    if (!force && c != null && clock.now().difference(c.at) < logTtl) return c.entries;
    final List<LogEntry> all = <LogEntry>[];
    int after = 0;
    LogHead head = LogHead(0, E2ee.genesisHash);
    for (int page = 0; page < 200; page++) {
      final ({List<LogEntry> entries, LogHead head}) r = await api.log(after);
      head = r.head;
      all.addAll(r.entries);
      if (r.entries.isEmpty || r.entries.last.seq >= head.seq) break;
      after = r.entries.last.seq;
    }
    final LogCheck check = await verifyLogSlice(pinned: await service.trust.pinnedHead(), entries: all, head: head);
    if (!check.ok) {
      _logCache = null;
      return null;
    }
    _logCache = (at: clock.now(), entries: all);
    return all;
  }

  void invalidateLog() => _logCache = null;

  // --------------------------------------------------------------- refresh

  /// Fetches the processing records, verifies them against the key log and
  /// stores the result for the sealer, the queue and the receiver. Also opens
  /// SK wraps addressed to this phone. Returns the verified view.
  ///
  /// A transport error leaves the previously verified state untouched and
  /// rethrows. A VERIFICATION failure drops this phone to the phone lane.
  Future<CircleLanes> refresh(String circleId, {bool force = false}) async {
    final LocalIdentity? me = await service.identity();
    if (me == null) return _failClosed(circleId, 'no identity');
    final CircleE2eeState st = await api.circleState(circleId);
    if (!st.isPrivate) {
      await store.clearCircle(circleId);
      if (onLaneChanged != null) await onLaneChanged!(circleId);
      return const CircleLanes(policy: StoredPolicy.off, members: <MemberLaneView>[], status: LaneStatus.phoneOnly);
    }
    final ProcessingServerState proc = await api.processingState(circleId);
    final List<LogEntry>? log = await _verifiedLog(force: force);
    if (log == null) return _failClosed(circleId, 'the key log did not verify');

    final Map<String, DeviceKey> deviceById = <String, DeviceKey>{for (final DeviceKey d in st.allDevices) d.deviceId: d};
    final Set<String> admins = <String>{for (final CircleE2eeMember m in st.members) if (m.role == 'admin') m.userId};

    // ---- policy: newest entry of the log, backed by a verified statement ----
    final List<LogEntry> policyEntries = <LogEntry>[
      for (final LogEntry e in log)
        if (!e.redacted && e.action == E2ee.actProcessingPolicy && e.circleId == circleId) e
    ];
    final Map<int, Uint8List> commitments = <int, Uint8List>{};
    final Map<int, bool> entryVerifiedOn = <int, bool>{}; // entry seq -> verified statement says assistance ON
    // The newest statement plus the older ones the server serves (`policy.history`, up to 30). Each is
    // verified on its own against the admin's signature and the log; a statement that does not verify
    // counts as "failed" below. Entries older than the served history are unknown, so they fail too:
    // that is fail-closed and only voids prefs signed before them.
    final List<PolicyStatement> stmts = <PolicyStatement>[
      if (proc.policy != null) proc.policy!,
      ...proc.policyHistory,
    ];
    final Set<int> seenStmt = <int>{};
    for (final PolicyStatement s in stmts) {
      final LogEntry? e = await _policyEntryFor(circleId, s, policyEntries, admins, deviceById);
      if (e == null || !seenStmt.add(e.seq)) continue;
      entryVerifiedOn[e.seq] = s.serverAssist && s.skGen >= 1;
      if (s.serverAssist && s.skGen >= 1) commitments[s.skGen] = s.commitment;
    }
    StoredPolicy policy = StoredPolicy.off;
    if (policyEntries.isNotEmpty) {
      final LogEntry newest = policyEntries.reduce((LogEntry a, LogEntry b) => a.seq >= b.seq ? a : b);
      PolicyStatement? ns;
      if (proc.policy != null && entryVerifiedOn.containsKey(newest.seq) && await _statementMatches(circleId, proc.policy!, newest)) ns = proc.policy;
      if (ns != null) {
        policy = StoredPolicy(assist: ns.serverAssist && ns.skGen >= 1, skGen: ns.skGen, defaultForNew: ns.defaultForNew, memberOptOut: ns.memberOptOut);
      }
    }
    // A server-lane pref older than a policy entry that is OFF or that we cannot verify is void
    // (turning assistance off ends every member's consent; nobody is silently re-opted-in).
    int voidBefore = 0;
    for (final LogEntry e in policyEntries) {
      if (entryVerifiedOn[e.seq] != true && e.seq > voidBefore) voidBefore = e.seq;
    }
    await store.setPolicy(circleId, policy);

    // ---- SK wraps addressed to this phone (verified commitments only) ----
    if (commitments.isNotEmpty) {
      try {
        await service.syncServerKeys(circleId, commitments);
      } catch (_) {}
    }

    // ---- member prefs ----
    DeviceKey? serverKey;
    if (proc.serverDeviceId != null) {
      final DeviceKey? k = deviceById[proc.serverDeviceId];
      if (k != null && k.kind == 'server' && k.isActive && k.approved == true && k.fingerprint == proc.serverFingerprint) serverKey = k;
    }
    final List<StoredMember> members = <StoredMember>[];
    final List<MemberLaneView> views = <MemberLaneView>[];
    final Map<String, int> claimedSince = <String, int>{for (final ClaimedMember m in proc.claimedMembers) m.userId: m.sinceMs};
    int ownLane = E2ee.linePhone;
    for (final CircleE2eeMember m in st.members) {
      final ({int seq, int lane})? v = await _verifiedPref(circleId, m.userId, log, proc, deviceById, serverKey, policy, voidBefore);
      final int trueLane = v?.lane ?? E2ee.linePhone;
      final int seq = v?.seq ?? 0;
      final int since = (claimedSince[m.userId] ?? 0) > 0 ? claimedSince[m.userId]! : clock.now().millisecondsSinceEpoch;
      if (v != null) await store.appendHistory(circleId, m.userId, seq, trueLane, since);
      final int shown = trueLane == E2ee.lineServer && policy.assist ? E2ee.lineServer : E2ee.linePhone;
      members.add(StoredMember(m.userId, shown, seq, since));
      views.add(MemberLaneView(m.userId, shown, since, verified: v != null));
      if (m.userId == me.userId) ownLane = shown;
    }
    await store.setMembers(circleId, members);

    // ---- this member's own effective lane ----
    // Server lane only while the policy is on AND the verified pref says so. A pending local
    // opt-out (not yet visible in the log) wins over anything the server shows.
    final String? pending = await store.pendingPhoneRef(circleId);
    bool pendingActive = false;
    if (pending != null) {
      final bool seen = log.any((LogEntry e) =>
          !e.redacted &&
          e.action == E2ee.actProcessingPref &&
          e.userId == me.userId &&
          e.circleId == circleId &&
          e.ref != null &&
          E2ee.hex(e.ref!) == pending);
      if (seen) {
        await store.clearPending(circleId);
      } else {
        pendingActive = true;
      }
    }
    final bool serverLane = policy.assist && ownLane == E2ee.lineServer && !pendingActive;
    await store.setOwnLane(circleId, serverLane ? LaneChoice(E2ee.lineServer, policy.skGen) : LaneChoice.phone);
    final LaneStatus status = serverLane
        ? LaneStatus.serverAssisted
        : (policy.assist && policy.memberOptOut == E2ee.optOutRequiredServer ? LaneStatus.consentRequired : LaneStatus.phoneOnly);
    await store.setStatus(circleId, status);
    // Remember that the server line key must rotate (member removed / key revoked) even if the
    // circle key epoch is bumped first and clears the server's flag.
    if (proc.rekeyRequired && policy.assist) await kv.set(_rotKey(circleId), '1');
    if (onLaneChanged != null) await onLaneChanged!(circleId);
    return CircleLanes(policy: policy, members: views, status: status, state: st, proc: proc, serverKey: serverKey);
  }

  Future<CircleLanes> _failClosed(String circleId, String why) async {
    await store.setPolicy(circleId, StoredPolicy.off);
    await store.setOwnLane(circleId, LaneChoice.phone);
    await store.setStatus(circleId, LaneStatus.verificationFailed);
    if (onLaneChanged != null) await onLaneChanged!(circleId);
    return CircleLanes(policy: StoredPolicy.off, members: const <MemberLaneView>[], status: LaneStatus.verificationFailed, problem: why);
  }

  Future<bool> _statementMatches(String circleId, PolicyStatement s, LogEntry e) async {
    try {
      final Uint8List ref = await s.ref(circleId);
      return e.ref != null && E2ee.constEq(ref, e.ref!) && e.epoch == s.skGen && e.userId == s.adminUserId && e.actorDeviceId == s.actorDeviceId;
    } catch (_) {
      return false;
    }
  }

  /// The log entry that proves [s] if the statement is genuine: a circle admin's
  /// phone key signed the statement, and a log entry (itself signed by that key)
  /// carries the statement's hash. Null otherwise.
  Future<LogEntry?> _policyEntryFor(String circleId, PolicyStatement s, List<LogEntry> entries, Set<String> admins,
      Map<String, DeviceKey> deviceById) async {
    try {
      if (!admins.contains(s.adminUserId)) return null;
      final DeviceKey? actor = deviceById[s.actorDeviceId];
      if (actor == null || actor.userId != s.adminUserId || actor.kind != 'device' || !actor.isActive) return null;
      final Uint8List msg = s.message(circleId);
      if (!await E2ee.verify(actor.edPub, msg, s.signature)) return null;
      for (final LogEntry e in entries) {
        if (await _statementMatches(circleId, s, e)) return e;
      }
    } catch (_) {}
    return null;
  }

  /// The member's lane from the NEWEST pref entry of the log, or null when
  /// there is none or it does not verify (then the member is phone-only).
  Future<({int seq, int lane})?> _verifiedPref(String circleId, String userId, List<LogEntry> log, ProcessingServerState proc,
      Map<String, DeviceKey> deviceById, DeviceKey? serverKey, StoredPolicy policy, int voidBefore) async {
    LogEntry? e;
    for (final LogEntry x in log) {
      if (!x.redacted && x.action == E2ee.actProcessingPref && x.userId == userId && x.circleId == circleId) {
        if (e == null || x.seq > e.seq) e = x;
      }
    }
    if (e == null) return null;
    final DeviceKey? actor = deviceById[e.actorDeviceId];
    if (actor == null || actor.userId != userId || actor.kind != 'device' || !actor.isActive) return null;
    final String subject = e.subjectId ?? E2ee.zeroUuid;
    if (subject == E2ee.zeroUuid) return (seq: e.seq, lane: E2ee.linePhone);
    // Server lane: the statement must name the exact pinned server key and verify.
    try {
      if (serverKey == null || subject != serverKey.deviceId || e.seq < voidBefore) return null;
      final int gen = e.epoch ?? 0;
      if (gen < 1 || gen > policy.skGen) return null;
      PrefStatement? s;
      for (final PrefStatement p in proc.prefs) {
        if (p.userId == userId && p.lane == E2ee.lineServer && p.serverDeviceId == subject && p.skGen == gen && p.approverDeviceId == actor.deviceId) s = p;
      }
      if (s == null) return null;
      final Uint8List msg = s.message(circleId, E2ee.unhex(serverKey.fingerprint));
      if (e.ref == null || !E2ee.constEq(await E2ee.processingRef(msg), e.ref!)) return null;
      if (!await E2ee.verify(actor.edPub, msg, s.signature)) return null;
      return (seq: e.seq, lane: E2ee.lineServer);
    } catch (_) {
      return null;
    }
  }

  // ----------------------------------------------------------- read helpers

  Future<LaneStatus> status(String circleId) => store.status(circleId);

  /// Verified lane of every member as of the last [refresh]. Members without a
  /// verified pref are phone-only.
  Future<List<MemberLaneView>> members(String circleId) async => <MemberLaneView>[
        for (final StoredMember m in await store.members(circleId)) MemberLaneView(m.userId, m.lane, m.sinceMs, verified: m.seq > 0)
      ];

  // ------------------------------------------------------------ own pref

  /// Signs and publishes this member's OWN pref. Only this phone can do it; no
  /// admin and no server call can write it for someone else.
  ///
  /// [lane] = phone: effective IMMEDIATELY and locally (a pending marker plus
  /// the stored lane flip before any network call), the queue is re-sealed or
  /// purged through [onLaneChanged]; if publishing then fails the phone lane
  /// stays in force and the error is rethrown.
  ///
  /// [lane] = server: needs the verified policy on, the SK of the current
  /// generation on this phone, a valid pinned server key and
  /// [confirmServerFingerprintHex], the fingerprint the member compared. It
  /// only takes effect once the signed entry shows up in the verified log.
  Future<void> setLane(String circleId, int lane, {String? confirmServerFingerprintHex}) async {
    if (!E2ee.validLine(lane)) throw const E2eeFormatException('unknown lane');
    final LocalIdentity me = (await service.identity())!;
    final Uint8List nonce = E2ee.randomBytes(E2ee.processingNonceLen);
    if (lane == E2ee.linePhone) {
      final Uint8List msg = E2ee.processingPrefMessage(circleId, me.userId, E2ee.linePhone, 0, E2ee.zeroUuid, Uint8List(32), nonce);
      final Uint8List ref = await E2ee.processingRef(msg);
      await store.setPendingPhone(circleId, E2ee.hex(ref));
      await store.setOwnLane(circleId, LaneChoice.phone);
      if (onLaneChanged != null) await onLaneChanged!(circleId);
      final Uint8List sig = await E2ee.sign(me.edSeed, msg);
      final Uint8List logMsg = E2ee.logActionMessage(E2ee.actProcessingPref, me.userId, me.deviceId, circleId: circleId, epoch: 0, ref: ref);
      final Map<String, dynamic> body = <String, dynamic>{
        ...PrefStatement(
                userId: me.userId, lane: E2ee.linePhone, skGen: 0, serverDeviceId: E2ee.zeroUuid, nonce: nonce, approverDeviceId: me.deviceId, signature: sig)
            .toRequest(Uint8List(32)),
        'log_signature': E2ee.b64(await E2ee.sign(me.edSeed, logMsg)),
      };
      // Kept until the server has it: if this call fails the opt-out stays in force on this phone and is sent again later.
      await store.setPendingBody(circleId, body);
      await api.putProcessingPref(circleId, body);
      await store.clearPendingBody(circleId);
      invalidateLog();
      try {
        await refresh(circleId, force: true);
      } catch (_) {}
      return;
    }
    final CircleLanes cl = await refresh(circleId, force: true);
    if (!cl.policy.assist) throw StateError('Server processing is not turned on for this circle.');
    final DeviceKey? sk = cl.serverKey;
    if (sk == null) throw StateError('This circle has no approved Orbitly server key.');
    if (confirmServerFingerprintHex == null || confirmServerFingerprintHex.toLowerCase() != sk.fingerprint) {
      throw StateError('Compare the server key shown to you before allowing server processing.');
    }
    if (await service.serverKey(circleId, cl.policy.skGen) == null) {
      throw StateError('This phone does not hold the server key yet. Open the app while an admin phone is online, then try again.');
    }
    final Uint8List fp = E2ee.unhex(sk.fingerprint);
    final Uint8List msg = E2ee.processingPrefMessage(circleId, me.userId, E2ee.lineServer, cl.policy.skGen, sk.deviceId, fp, nonce);
    final Uint8List ref = await E2ee.processingRef(msg);
    final Uint8List sig = await E2ee.sign(me.edSeed, msg);
    final Uint8List logMsg =
        E2ee.logActionMessage(E2ee.actProcessingPref, me.userId, me.deviceId, circleId: circleId, subjectId: sk.deviceId, epoch: cl.policy.skGen, ref: ref);
    await api.putProcessingPref(circleId, <String, dynamic>{
      ...PrefStatement(
              userId: me.userId, lane: E2ee.lineServer, skGen: cl.policy.skGen, serverDeviceId: sk.deviceId, nonce: nonce, approverDeviceId: me.deviceId, signature: sig)
          .toRequest(fp),
      'log_signature': E2ee.b64(await E2ee.sign(me.edSeed, logMsg)),
    });
    await store.clearPending(circleId);
    invalidateLog();
    final CircleLanes after = await refresh(circleId, force: true);
    if (after.status == LaneStatus.serverAssisted) await _wrapForServerIfDue(circleId, after);
  }

  /// Sends an opt-out again that the server has not accepted yet. True when there is nothing left to confirm or the
  /// server took it now (a 409 means it already did). Until then the phone lane stays in force and the screens say
  /// "not yet confirmed". Safe to call often.
  Future<bool> retryPendingOptOut(String circleId) async {
    final Map<String, dynamic>? body = await store.pendingBody(circleId);
    if (body == null) return (await store.pendingPhoneRef(circleId)) == null;
    try {
      await api.putProcessingPref(circleId, body);
    } on ApiException catch (e) {
      if (e.status != 409) return false;
    } catch (_) {
      return false;
    }
    await store.clearPendingBody(circleId);
    invalidateLog();
    try {
      await refresh(circleId, force: true);
    } catch (_) {}
    return true;
  }

  // ---------------------------------------------------------- admin policy

  /// Circle admin: publishes the signed policy. Turning assistance ON (from off)
  /// makes a new SK generation on this phone and wraps it to every approved
  /// member key; the server key gets nothing until a member opts in. Refuses
  /// while some member's app cannot read the server line ([LanesNotReady]) or
  /// when no valid server key is pinned. [rotate] makes a new SK generation
  /// while staying on.
  Future<void> publishPolicy(
    String circleId, {
    required bool serverAssist,
    int defaultForNew = E2ee.linePhone,
    int memberOptOut = E2ee.optOutAllowed,
    bool rotate = false,
  }) async {
    final LocalIdentity me = (await service.identity())!;
    final CircleLanes cur = await refresh(circleId, force: true);
    final CircleE2eeState st = cur.state ?? await api.circleState(circleId);
    final ProcessingServerState proc = cur.proc ?? await api.processingState(circleId);
    if (!st.members.any((CircleE2eeMember m) => m.userId == me.userId && m.role == 'admin')) {
      throw StateError('Only a circle admin can change the processing policy.');
    }
    if (memberOptOut == E2ee.optOutRequiredServer && !serverAssist) {
      throw ArgumentError('required_server needs server assistance on');
    }
    final bool wasOn = cur.policy.assist;
    final bool newKey = serverAssist && (!wasOn || rotate);
    if (serverAssist) {
      if (cur.serverKey == null) throw StateError('This server has no approved server key for this circle.');
      final List<String> stale = <String>[
        for (final CircleE2eeMember m in st.members)
          if (m.devices.any((DeviceKey d) => d.kind == 'device' && d.approved == true && d.isActive && !d.supportsLanes)) (m.name.isEmpty ? m.userId : m.name)
      ];
      if (!wasOn && stale.isNotEmpty) throw LanesNotReady(stale);
    }
    int gen = cur.policy.skGen;
    Uint8List commitment = Uint8List(32);
    Uint8List? key;
    List<Map<String, dynamic>> wraps = <Map<String, dynamic>>[];
    if (newKey) {
      final List<int> held = await service.heldServerGens(circleId);
      gen = <int>[cur.policy.skGen, proc.skGen, if (held.isNotEmpty) held.last].reduce((int a, int b) => a > b ? a : b) + 1;
      key = await service.generateServerKey(circleId, state: st);
      commitment = await E2ee.keyCommitmentLine(key, circleId, E2ee.lineServer, gen);
      final bool serverToo = rotate && cur.members.any((MemberLaneView v) => v.serverAssisted) && cur.serverKey != null;
      wraps = <Map<String, dynamic>>[
        for (final DeviceKey k in await service.serverLineRecipients(st, me, serverKey: serverToo ? cur.serverKey : null))
          await service.wrapServerKeyTo(me, circleId, gen, key, k)
      ];
    } else if (gen >= 1) {
      key = await service.serverKey(circleId, gen);
      final PolicyStatement? p = proc.policy;
      if (p != null && p.skGen == gen) commitment = p.commitment;
      if (key != null) commitment = await E2ee.keyCommitmentLine(key, circleId, E2ee.lineServer, gen);
      if (commitment.every((int b) => b == 0)) gen = 0; // no commitment known for the old key: record "no key"
    }
    final Uint8List nonce = E2ee.randomBytes(E2ee.processingNonceLen);
    final Uint8List msg = E2ee.processingPolicyMessage(circleId, me.userId, serverAssist, defaultForNew, memberOptOut, gen, commitment, nonce);
    final Uint8List ref = await E2ee.processingRef(msg);
    final Uint8List logMsg = E2ee.logActionMessage(E2ee.actProcessingPolicy, me.userId, me.deviceId, circleId: circleId, epoch: gen, ref: ref);
    final PolicyStatement stmt = PolicyStatement(
        serverAssist: serverAssist,
        defaultForNew: defaultForNew,
        memberOptOut: memberOptOut,
        skGen: gen,
        commitment: commitment,
        nonce: nonce,
        adminUserId: me.userId,
        actorDeviceId: me.deviceId,
        signature: await E2ee.sign(me.edSeed, msg));
    await api.putProcessingPolicy(circleId, <String, dynamic>{
      ...stmt.toJson(),
      'log_signature': E2ee.b64(await E2ee.sign(me.edSeed, logMsg)),
      if (newKey) 'wraps': wraps,
    });
    if (newKey && key != null) {
      await service.storeServerKey(circleId, gen, key);
      await kv.remove(_rotKey(circleId));
    }
    invalidateLog();
    await refresh(circleId, force: true);
  }

  /// Circle admin: upgrades a LEGACY trusted-server circle in one request: a new
  /// circle key epoch that the server key does not get, plus the first server
  /// line key generation and a signed policy (assistance on, members choose for
  /// themselves, default phone). The server turns old consents into prefs. The
  /// admin screen must have shown the plain warnings first. Refuses while a
  /// member's app cannot read the server line ([LanesNotReady]).
  Future<void> upgradeLegacy(String circleId) async {
    final LocalIdentity me = (await service.identity())!;
    final CircleLanes cur = await refresh(circleId, force: true);
    final CircleE2eeState st = cur.state ?? await api.circleState(circleId);
    final ProcessingServerState proc = cur.proc ?? await api.processingState(circleId);
    if (!st.members.any((CircleE2eeMember m) => m.userId == me.userId && m.role == 'admin')) {
      throw StateError('Only a circle admin can upgrade this circle.');
    }
    if (!proc.legacy) throw StateError('This circle is not in the old trusted-server mode.');
    if (cur.serverKey == null) throw StateError('This server has no approved server key for this circle.');
    final List<String> stale = <String>[
      for (final CircleE2eeMember m in st.members)
        if (m.devices.any((DeviceKey d) => d.kind == 'device' && d.approved == true && d.isActive && !d.supportsLanes)) (m.name.isEmpty ? m.userId : m.name)
    ];
    if (stale.isNotEmpty) throw LanesNotReady(stale);
    final next = await service.prepareNextEpoch(circleId);
    const int gen = 1;
    final Uint8List key = await service.generateServerKey(circleId, state: st);
    final Uint8List commitment = await E2ee.keyCommitmentLine(key, circleId, E2ee.lineServer, gen);
    final List<Map<String, dynamic>> wraps = <Map<String, dynamic>>[
      for (final DeviceKey k in await service.serverLineRecipients(st, me)) await service.wrapServerKeyTo(me, circleId, gen, key, k)
    ];
    final Uint8List nonce = E2ee.randomBytes(E2ee.processingNonceLen);
    final Uint8List msg =
        E2ee.processingPolicyMessage(circleId, me.userId, true, E2ee.linePhone, E2ee.optOutAllowed, gen, commitment, nonce);
    final Uint8List ref = await E2ee.processingRef(msg);
    final Uint8List logMsg = E2ee.logActionMessage(E2ee.actProcessingPolicy, me.userId, me.deviceId, circleId: circleId, epoch: gen, ref: ref);
    final PolicyStatement stmt = PolicyStatement(
        serverAssist: true,
        defaultForNew: E2ee.linePhone,
        memberOptOut: E2ee.optOutAllowed,
        skGen: gen,
        commitment: commitment,
        nonce: nonce,
        adminUserId: me.userId,
        actorDeviceId: me.deviceId,
        signature: await E2ee.sign(me.edSeed, msg));
    await api.upgradeProcessing(circleId, <String, dynamic>{
      ...next.body,
      'policy': <String, dynamic>{
        ...stmt.toJson(),
        'log_signature': E2ee.b64(await E2ee.sign(me.edSeed, logMsg)),
        'wraps': wraps,
      },
    });
    await next.commit();
    await service.storeServerKey(circleId, gen, key);
    invalidateLog();
    await refresh(circleId, force: true);
  }

  /// Circle admin, after an upgrade: ends the server's access to the OLD
  /// phone-key epochs. Irreversible.
  Future<void> endLegacyServerAccess(String circleId) => api.endLegacyServerAccess(circleId);

  /// Admin: new SK generation (same settings), after a member was removed or a key revoked.
  Future<void> rotateServerKey(String circleId) async {
    final CircleLanes cur = await refresh(circleId, force: true);
    if (!cur.policy.assist) return;
    await publishPolicy(circleId,
        serverAssist: true, defaultForNew: cur.policy.defaultForNew, memberOptOut: cur.policy.memberOptOut, rotate: true);
  }

  // ------------------------------------------------------------ duties

  /// Verifies, then does what this phone owes the circle: rotates SK when due
  /// (admin), wraps the current SK to approved devices that lack it (admin, or
  /// my own other devices) and, only when a verified member is in lane server,
  /// to the pinned server key (admin).
  Future<CircleLanes> maintain(String circleId) async {
    try {
      await retryPendingOptOut(circleId);
    } catch (_) {}
    CircleLanes cl = await refresh(circleId);
    if (!cl.policy.assist) return cl;
    final LocalIdentity me = (await service.identity())!;
    final CircleE2eeState st = cl.state!;
    final ProcessingServerState proc = cl.proc!;
    final bool admin = st.members.any((CircleE2eeMember m) => m.userId == me.userId && m.role == 'admin');
    final int gen = cl.policy.skGen;
    final Uint8List? key = await service.serverKey(circleId, gen);
    if (key == null) return cl;
    final bool hasServerMember = cl.members.any((MemberLaneView v) => v.serverAssisted);
    if (admin && (await kv.get(_rotKey(circleId))) == '1') {
      await rotateServerKey(circleId);
      return refresh(circleId, force: true);
    }
    final Set<String> lacking = <String>{for (final DeviceKey d in await api.pendingLine(circleId, E2ee.lineServer)) d.deviceId};
    final DeviceKey? srv = admin && hasServerMember ? cl.serverKey : null;
    final List<Map<String, dynamic>> wraps = <Map<String, dynamic>>[];
    for (final DeviceKey k in await service.serverLineRecipients(st, me, serverKey: srv)) {
      final bool isServer = k.kind == 'server';
      if (isServer ? proc.inEffect : !lacking.contains(k.deviceId)) continue;
      if (!admin && k.userId != me.userId) continue;
      wraps.add(await service.wrapServerKeyTo(me, circleId, gen, key, k));
    }
    if (wraps.isNotEmpty) await api.submitLineWraps(circleId, E2ee.lineServer, gen, wraps);
    return cl;
  }

  /// After a member opted in: the admin phone gives the pinned server key the SK.
  Future<void> _wrapForServerIfDue(String circleId, CircleLanes cl) async {
    try {
      await maintain(circleId);
    } catch (_) {}
  }
}
