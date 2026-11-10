import 'dart:convert';
import 'dart:typed_data';

import 'e2ee_crypto.dart';
import 'e2ee_models.dart';

/// Minimal key-value store so the trust state can live in SharedPreferences in
/// the app and in a map in tests. Holds PUBLIC data only (fingerprints, log
/// head); private keys never pass through here.
abstract class TrustKv {
  Future<String?> get(String key);
  Future<void> set(String key, String value);
  Future<void> remove(String key);
}

class MemoryTrustKv implements TrustKv {
  final Map<String, String> data = <String, String>{};
  @override
  Future<String?> get(String key) async => data[key];
  @override
  Future<void> set(String key, String value) async => data[key] = value;
  @override
  Future<void> remove(String key) async => data.remove(key);
}

enum TrustLevel {
  /// Never seen this person's keys before.
  unseen,

  /// Seen before (trust on first use) and unchanged, but not verified in person.
  seen,

  /// Verified out of band and unchanged.
  verified,

  /// Seen before, keys changed, not verified: softer notice.
  changed,

  /// VERIFIED before and the keys changed: loud warning.
  verifiedChanged,
}

class TrustAssessment {
  const TrustAssessment(this.level, {this.added = const <String>[], this.removed = const <String>[]});
  final TrustLevel level;
  final List<String> added;
  final List<String> removed;
  bool get alarming => level == TrustLevel.verifiedChanged;
}

/// Local, pinned trust: which fingerprints I verified per person (never leaves
/// the phone), which I merely saw, and the last transparency-log head I saw.
class TrustStore {
  TrustStore(this.kv);
  final TrustKv kv;

  Future<List<String>> _list(String key) async {
    final String? raw = await kv.get(key);
    if (raw == null) return <String>[];
    try {
      return (jsonDecode(raw) as List<dynamic>).cast<String>();
    } catch (_) {
      return <String>[];
    }
  }

  static List<String> _norm(Iterable<String> fps) => fps.toSet().toList()..sort();

  Future<List<String>> verifiedFingerprints(String userId) => _list('verified:$userId');
  Future<List<String>> seenFingerprints(String userId) => _list('seen:$userId');
  Future<bool> isVerified(String userId) async => (await verifiedFingerprints(userId)).isNotEmpty;

  /// Pins [fps] as verified for [userId] (after an out-of-band comparison).
  Future<void> markVerified(String userId, Iterable<String> fps, {String method = 'safety-number'}) async {
    await kv.set('verified:$userId', jsonEncode(_norm(fps)));
    await kv.set('verified_at:$userId', DateTime.now().toUtc().toIso8601String());
    await kv.set('verified_via:$userId', method);
    await rememberSeen(userId, fps);
  }

  Future<void> clearVerified(String userId) async => kv.remove('verified:$userId');

  Future<String?> verifiedVia(String userId) => kv.get('verified_via:$userId');

  Future<void> rememberSeen(String userId, Iterable<String> fps) async =>
      kv.set('seen:$userId', jsonEncode(_norm(fps)));

  /// Compares the keys the server shows now with what I verified / saw.
  Future<TrustAssessment> assess(String userId, Iterable<String> current) async {
    final List<String> now = _norm(current);
    final List<String> ver = await verifiedFingerprints(userId);
    if (ver.isNotEmpty) {
      final List<String> added = now.where((String f) => !ver.contains(f)).toList();
      final List<String> removed = ver.where((String f) => !now.contains(f)).toList();
      if (added.isEmpty && removed.isEmpty) return const TrustAssessment(TrustLevel.verified);
      return TrustAssessment(TrustLevel.verifiedChanged, added: added, removed: removed);
    }
    final List<String> seen = await seenFingerprints(userId);
    if (seen.isEmpty) return const TrustAssessment(TrustLevel.unseen);
    final List<String> added = now.where((String f) => !seen.contains(f)).toList();
    final List<String> removed = seen.where((String f) => !now.contains(f)).toList();
    if (added.isEmpty && removed.isEmpty) return const TrustAssessment(TrustLevel.seen);
    return TrustAssessment(TrustLevel.changed, added: added, removed: removed);
  }

  // ---- transparency log pin
  Future<LogHead?> pinnedHead() async {
    final String? raw = await kv.get('log_head');
    if (raw == null) return null;
    try {
      final Map<String, dynamic> m = jsonDecode(raw) as Map<String, dynamic>;
      return LogHead(m['seq'] as int, E2ee.unhex(m['hash'] as String));
    } catch (_) {
      return null;
    }
  }

  Future<void> pinHead(LogHead h) async =>
      kv.set('log_head', jsonEncode(<String, dynamic>{'seq': h.seq, 'hash': h.hex}));

  Future<int> ackedSeq() async => int.tryParse(await kv.get('log_ack') ?? '') ?? 0;
  Future<void> ackSeq(int s) async => kv.set('log_ack', '$s');

  // ---- inviter fingerprint carried by the invite link (never from the server)
  static const String _pendingInviter = 'pending_inviter_fp';
  Future<String?> pendingInviter() => kv.get(_pendingInviter);
  Future<void> savePendingInviter(String fp) => kv.set(_pendingInviter, fp);
  Future<void> clearPendingInviter() => kv.remove(_pendingInviter);

  // ---- invite expectation (a value that never came from the server)
  Future<void> expectInviter(String circleId, String fingerprintHex) =>
      kv.set('invite:$circleId', fingerprintHex);
  Future<String?> expectedInviter(String circleId) => kv.get('invite:$circleId');

  // ---- owner approval (docs/design/E2EE.md "Owner approval")

  /// The circle's owner-approval rule as this phone last verified it from the
  /// signed key log, or null when it never saw an entry.
  Future<OwnerPolicy?> ownerPolicy(String circleId) async {
    final String? raw = await kv.get('owner_policy:$circleId');
    if (raw == null) return null;
    try {
      return OwnerPolicy.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> setOwnerPolicy(String circleId, OwnerPolicy p) => kv.set('owner_policy:$circleId', jsonEncode(p.toJson()));

  /// Keys this phone saw approved by their own owner under the rule (device id
  /// -> circle id). Shown as "approved by the owner without a second admin".
  Future<Map<String, String>> ownerApprovedKeys() async {
    final String? raw = await kv.get('owner_approved');
    if (raw == null) return <String, String>{};
    try {
      return (jsonDecode(raw) as Map<String, dynamic>).cast<String, String>();
    } catch (_) {
      return <String, String>{};
    }
  }

  Future<void> markOwnerApproved(String deviceId, String circleId) async {
    final Map<String, String> m = await ownerApprovedKeys();
    m[deviceId] = circleId;
    await kv.set('owner_approved', jsonEncode(m));
  }
}

/// The owner-approval rule of one circle, from a verified log entry.
class OwnerPolicy {
  const OwnerPolicy({required this.on, required this.byUserId, required this.seq});
  final bool on;
  final String byUserId;
  final int seq;

  Map<String, dynamic> toJson() => <String, dynamic>{'on': on, 'by': byUserId, 'seq': seq};
  factory OwnerPolicy.fromJson(Map<String, dynamic> j) =>
      OwnerPolicy(on: j['on'] == true, byUserId: j['by'] as String, seq: (j['seq'] as num).toInt());
}

/// Who may do what in a circle, as the server reports it (roles are not signed).
class CircleRoles {
  const CircleRoles({this.creatorId, this.adminIds = const <String>{}});
  final String? creatorId;
  final Set<String> adminIds;
}

/// Reads an owner-approval log entry (action 12): the rule it sets, when it is
/// well formed AND signed by someone allowed to set it. Turning it ON is valid
/// only from the circle's creator who is also an admin; any admin may turn it
/// OFF. Returns null for an entry that sets nothing valid. The entry's own
/// signature is checked by [verifyLogSlice].
Future<OwnerPolicy?> readOwnerPolicyEntry(LogEntry e, CircleRoles? roles) async {
  if (e.redacted || e.action != E2ee.actOwnerApproval || e.circleId == null || e.userId == null || e.ref == null) return null;
  if (roles == null || !roles.adminIds.contains(e.userId)) return null;
  try {
    if (E2ee.constEq(e.ref!, await E2ee.ownerApprovalRef(e.circleId!, e.userId!, true))) {
      if (roles.creatorId == null || roles.creatorId != e.userId) return null;
      return OwnerPolicy(on: true, byUserId: e.userId!, seq: e.seq);
    }
    if (E2ee.constEq(e.ref!, await E2ee.ownerApprovalRef(e.circleId!, e.userId!, false))) {
      return OwnerPolicy(on: false, byUserId: e.userId!, seq: e.seq);
    }
  } catch (_) {}
  return null;
}

enum ApprovalKind {
  /// Approved by another person's admin key: the normal rule.
  byOtherAdmin,

  /// Approved by the key's own owner while that circle's owner-approval rule,
  /// set by the same person as creator and admin, was on.
  byOwnerWithoutSecondAdmin,

  /// A self-approval that no verified rule allows: the server should never
  /// have accepted it.
  invalidSelfApproval,
}

/// Classifies an approval log entry (action 9). [subjectOwner] is the user the
/// approved device belongs to; [policy] is the circle's owner-approval rule in
/// effect just before this entry (from earlier verified entries).
ApprovalKind classifyApproval(LogEntry e, {required String? subjectOwner, required OwnerPolicy? policy, required CircleRoles? roles}) {
  if (subjectOwner == null || subjectOwner != e.userId) return ApprovalKind.byOtherAdmin;
  final bool ok = policy != null &&
      policy.on &&
      policy.seq < e.seq &&
      policy.byUserId == e.userId &&
      roles != null &&
      roles.creatorId == e.userId &&
      roles.adminIds.contains(e.userId);
  return ok ? ApprovalKind.byOwnerWithoutSecondAdmin : ApprovalKind.invalidSelfApproval;
}

// --------------------------------------------------------------------------
// Registration chain

/// Verifies that a key is vouched for by the key named in its record: the
/// registrant itself (root) or an earlier key of the same user. This checks the
/// signature only; whether the voucher is itself trusted is a separate matter.
Future<bool> verifyRegistration(DeviceKey d) async {
  try {
    final Uint8List ref = E2ee.unhex(d.fingerprint);
    final Uint8List msg = E2ee.logActionMessage(
        d.registrationAction, d.userId, d.registeredByDeviceId,
        subjectId: d.deviceId, ref: ref);
    if (d.isRoot && !E2ee.constEq(d.registeredByPub, d.edPub)) return false;
    // The fingerprint must really be the hash of the published keys.
    final Uint8List fp = await E2ee.fingerprint(d.edPub, d.xPub);
    if (!E2ee.constEq(fp, ref)) return false;
    return await E2ee.verify(d.registeredByPub, msg, d.registrationSignature);
  } catch (_) {
    return false;
  }
}

/// Whether a `server` key that is still listed as active survived every key reset of its owner. A reset retires every
/// earlier key of the account without a per-key entry, so a server key registered BEFORE the owner's latest reset is
/// only still the server key if the new root phone signed a re-attachment (log action 13) of exactly that key after the
/// reset: same device id, same fingerprint, signed by a currently listed, approved phone key of the same owner. A key
/// registered after the latest reset (the server made a new one and a phone approved it) needs nothing. [log] is the
/// verified log (an attachment the server withheld simply is not there, so the key is not accepted: fail closed).
/// A key whose registration the log does not show cannot be judged and keeps today's behaviour (the circle list's own
/// checks apply).
///
/// Also required: the key belongs to a circle ADMIN ([admins]). The Orbitly server's key is the owner's own key, vouched
/// for by the owner's approved phone; a `server` key of an ordinary member (whose own first key approves it in a
/// circle, by design) is never the server key, whatever the server reports as pinned.
bool serverKeySurvivedResets(List<LogEntry> log, DeviceKey k, Map<String, DeviceKey> deviceById, Set<String> admins) {
  if (!admins.contains(k.userId)) return false;
  int registered = 0, lastReset = 0;
  for (final LogEntry e in log) {
    if (e.redacted) continue;
    final int? a = e.action;
    if (e.subjectId == k.deviceId && (a == E2ee.actRegister || a == E2ee.actRecovery || a == E2ee.actReset) && e.seq > registered) registered = e.seq;
    if (a == E2ee.actReset && e.userId == k.userId && e.seq > lastReset) lastReset = e.seq;
  }
  if (registered == 0 || lastReset < registered) return true;
  final Uint8List fp;
  try {
    fp = E2ee.unhex(k.fingerprint);
  } catch (_) {
    return false;
  }
  for (final LogEntry e in log) {
    if (e.redacted || e.action != E2ee.actServerAttach || e.seq <= lastReset) continue;
    if (e.subjectId != k.deviceId || e.userId != k.userId || e.ref == null || !E2ee.constEq(e.ref!, fp)) continue;
    if (e.circleId != null && e.circleId != E2ee.zeroUuid) continue;
    final DeviceKey? actor = deviceById[e.actorDeviceId];
    if (actor == null || actor.userId != k.userId || actor.kind != 'device' || !actor.isActive || actor.approved != true) continue;
    if (e.actorPub == null || !E2ee.constEq(e.actorPub!, actor.edPub)) continue;
    return true;
  }
  return false;
}

// --------------------------------------------------------------------------
// Wrap policy: when may my phone issue a circle key to someone's key?

enum WrapDecision {
  /// Cross-signed by a key I already trust, or a first-seen member key
  /// (trust on first use); wrap automatically.
  auto,

  /// A new key of someone I verified, an unchained key, or a recovery request:
  /// show who/which circles/safety number and ask the user first.
  confirm,

  /// The server says it is not approved for this circle: do not wrap. A circle
  /// admin must approve it first.
  waitingForApproval,

  /// The key's own registration signature is invalid: refuse.
  refuse,
}

class WrapDecisionResult {
  const WrapDecisionResult(this.decision, this.reason);
  final WrapDecision decision;
  final String reason;
}

/// Decides how to treat a pending [key]. [known] are the active keys of the
/// same user already trusted (verified or previously seen) by this phone.
Future<WrapDecisionResult> decideWrap({
  required DeviceKey key,
  required String selfUserId,
  required TrustStore trust,
  required Set<String> ownKnownDeviceIds,
}) async {
  if (!await verifyRegistration(key)) {
    return const WrapDecisionResult(WrapDecision.refuse, 'registration signature invalid');
  }
  if (key.approved == false) {
    return const WrapDecisionResult(WrapDecision.waitingForApproval,
        'Waiting for approval by a circle admin');
  }
  final List<String> verified = await trust.verifiedFingerprints(key.userId);
  final bool userVerified = verified.isNotEmpty;
  final bool voucherKnown = !key.isRoot &&
      (key.userId == selfUserId
          ? ownKnownDeviceIds.contains(key.registeredByDeviceId)
          : true);
  if (key.userId == selfUserId) {
    if (voucherKnown) {
      return const WrapDecisionResult(WrapDecision.auto, 'cross-signed by one of my own devices');
    }
    return const WrapDecisionResult(WrapDecision.confirm, 'a new key on my own account');
  }
  if (userVerified && !verified.contains(key.fingerprint)) {
    if (!key.isRoot) {
      // Cross-signed by an earlier key of a person I verified: if that voucher
      // is a verified fingerprint, the chain is rooted in something I checked.
      // The voucher's fingerprint is not in the record, so ask the user.
      return const WrapDecisionResult(WrapDecision.confirm,
          'a new device of a member you verified; compare the safety number');
    }
    return const WrapDecisionResult(WrapDecision.confirm,
        'a replacement key for a member you verified; compare the safety number');
  }
  if (key.initial || userVerified) {
    return const WrapDecisionResult(WrapDecision.auto, 'first key of a member (trust on first use)');
  }
  if (!key.isRoot) {
    return const WrapDecisionResult(WrapDecision.auto, 'cross-signed new device of a member');
  }
  return const WrapDecisionResult(WrapDecision.confirm, 'a replacement key; compare the safety number');
}

// --------------------------------------------------------------------------
// Transparency log verification

enum LogProblem { none, rollback, fork, brokenChain, badSignature, badHash, gap, malformed }

class LogCheck {
  const LogCheck(this.problem, {this.detail = '', this.newHead, this.events = const <LogEntry>[]});
  final LogProblem problem;
  final String detail;

  /// The head to pin when [ok].
  final LogHead? newHead;

  /// Visible (non-redacted) entries newer than the previously pinned head.
  final List<LogEntry> events;
  bool get ok => problem == LogProblem.none;
}

/// Verifies a server-served log slice against my pinned head. [entries] must
/// start at `max(pinned.seq - 1, 0) + 1`, i.e. include the pinned entry itself.
/// Detects: rollback (head older than pinned), fork/rewrite (the pinned entry
/// now has another hash), broken linkage, forged signatures and altered
/// content. A server that shows different logs to different people (split view)
/// is only caught when members compare heads out of band.
Future<LogCheck> verifyLogSlice({
  required LogHead? pinned,
  required List<LogEntry> entries,
  required LogHead head,
}) async {
  if (pinned != null && head.seq < pinned.seq) {
    return LogCheck(LogProblem.rollback,
        detail: 'the server log is shorter (${head.seq}) than the one you pinned (${pinned.seq})');
  }
  if (entries.isEmpty) {
    if (pinned == null && head.seq == 0) return LogCheck(LogProblem.none, newHead: head);
    if (pinned != null && head.seq == pinned.seq && E2ee.constEq(head.hash, pinned.hash)) {
      return LogCheck(LogProblem.none, newHead: head);
    }
    return const LogCheck(LogProblem.gap, detail: 'the server returned no entries but a different head');
  }
  Uint8List? prev;
  int? lastSeq;
  final List<LogEntry> events = <LogEntry>[];
  for (final LogEntry e in entries) {
    if (lastSeq != null && e.seq != lastSeq + 1) {
      return LogCheck(LogProblem.gap, detail: 'entry ${lastSeq + 1} is missing');
    }
    if (lastSeq == null) {
      if (pinned == null && e.seq != 1) return const LogCheck(LogProblem.gap, detail: 'the log does not start at entry 1');
      if (e.seq == 1 && !E2ee.constEq(e.prevHash, E2ee.genesisHash)) {
        return const LogCheck(LogProblem.brokenChain, detail: 'entry 1 does not start from the genesis hash');
      }
    } else if (!E2ee.constEq(e.prevHash, prev!)) {
      return LogCheck(LogProblem.brokenChain, detail: 'entry ${e.seq} does not extend entry ${e.seq - 1}');
    }
    if (!e.redacted) {
      try {
        final Uint8List msg = E2ee.logActionMessage(e.action!, e.userId!, e.actorDeviceId!,
            circleId: e.circleId, subjectId: e.subjectId, epoch: e.epoch ?? 0, ref: e.ref);
        if (!await E2ee.verify(e.actorPub!, msg, e.signature!)) {
          return LogCheck(LogProblem.badSignature, detail: 'entry ${e.seq} has an invalid signature');
        }
        final Uint8List h = await E2ee.logEntryHash(e.prevHash, e.seq, msg, e.signature!);
        if (!E2ee.constEq(h, e.entryHash)) {
          return LogCheck(LogProblem.badHash, detail: 'entry ${e.seq} does not match its hash');
        }
      } catch (_) {
        return LogCheck(LogProblem.malformed, detail: 'entry ${e.seq} is malformed');
      }
    }
    if (pinned != null && e.seq == pinned.seq && !E2ee.constEq(e.entryHash, pinned.hash)) {
      return LogCheck(LogProblem.fork,
          detail: 'entry ${pinned.seq} is not the one you pinned: the history was rewritten or you are being shown another log');
    }
    if (pinned == null || e.seq > pinned.seq) events.add(e);
    prev = e.entryHash;
    lastSeq = e.seq;
  }
  if (pinned != null && lastSeq! < pinned.seq) {
    return const LogCheck(LogProblem.gap, detail: 'the pinned entry was not returned');
  }
  if (lastSeq != head.seq || !E2ee.constEq(prev!, head.hash)) {
    return const LogCheck(LogProblem.brokenChain, detail: 'the reported head is not the last entry');
  }
  return LogCheck(LogProblem.none, newHead: head, events: events.where((LogEntry e) => !e.redacted).toList());
}

// --------------------------------------------------------------------------
// Alarms

enum AlarmKind {
  verifiedKeyChanged,
  keyChanged,
  userReset,
  epochByUnverified,
  logProblem,
  inviterMismatch,
  serverKeyIsCircleKey,

  /// The circle owner approved their own new key under the owner-approval rule.
  ownerApproved,

  /// The owner-approval rule of a circle was switched.
  ownerApprovalPolicy,

  /// Someone approved their own key and no verified rule allows it.
  invalidSelfApproval,
}

class E2eeAlarm {
  const E2eeAlarm(this.kind, this.title, this.body, {this.userId, this.circleId, this.seq});
  final AlarmKind kind;
  final String title;
  final String body;
  final String? userId;
  final String? circleId;
  final int? seq;
  bool get severe =>
      kind == AlarmKind.serverKeyIsCircleKey ||
      kind == AlarmKind.verifiedKeyChanged ||
      kind == AlarmKind.logProblem ||
      kind == AlarmKind.inviterMismatch ||
      kind == AlarmKind.invalidSelfApproval;
}

/// Alarms from NEW visible log entries: a member resetting all their keys, and
/// a circle epoch published by someone this phone never verified (a verified
/// admin is the only comfortable source of a new key).
///
/// Owner approval: [circleRoles] (creator and admins per circle) and
/// [deviceOwners] (device id -> user id) let it check self-approvals. A rule
/// change and every owner approval become notices; a self-approval without a
/// verified rule is a severe alarm. [policyFallback] fetches and verifies the
/// circle's latest rule entry when this phone never saw one (it may have been
/// redacted for an older app version).
Future<List<E2eeAlarm>> alarmsFromLog({
  required List<LogEntry> events,
  required String selfUserId,
  required TrustStore trust,
  required Map<String, String> userNames,
  required Map<String, String> circleNames,
  Map<String, CircleRoles> circleRoles = const <String, CircleRoles>{},
  Map<String, String> deviceOwners = const <String, String>{},
  Future<OwnerPolicy?> Function(String circleId)? policyFallback,
}) async {
  final List<E2eeAlarm> out = <E2eeAlarm>[];
  final Map<String, String> owners = Map<String, String>.of(deviceOwners);
  for (final LogEntry e in events) {
    final String who = userNames[e.userId] ?? 'A member';
    if (e.subjectId != null && e.userId != null &&
        (e.action == E2ee.actRegister || e.action == E2ee.actRotate || e.action == E2ee.actRecovery || e.action == E2ee.actReset)) {
      owners[e.subjectId!] = e.userId!;
    }
    if (e.action == E2ee.actOwnerApproval && e.circleId != null) {
      // Roles unknown (the circle state could not be loaded): nothing to check against yet.
      if (circleRoles[e.circleId] == null) continue;
      final String c = circleNames[e.circleId] ?? 'a circle';
      final OwnerPolicy? p = await readOwnerPolicyEntry(e, circleRoles[e.circleId]);
      if (p == null) {
        out.add(E2eeAlarm(AlarmKind.invalidSelfApproval, 'Owner approval changed by someone not allowed to',
            'The key log of $c has an owner-approval change by $who that this circle\'s roles do not allow. Phones will not accept owner approvals based on it.',
            userId: e.userId, circleId: e.circleId, seq: e.seq));
        continue;
      }
      await trust.setOwnerPolicy(e.circleId!, p);
      if (e.userId != selfUserId) {
        out.add(E2eeAlarm(AlarmKind.ownerApprovalPolicy, p.on ? 'Owner approval turned on in $c' : 'Owner approval turned off in $c',
            p.on
                ? '$who, who created $c, can now approve their own new phone without a second admin. You will be told when that happens.'
                : 'A new phone of the owner of $c needs a second admin again.',
            userId: e.userId, circleId: e.circleId, seq: e.seq));
      }
      continue;
    }
    if (e.action == E2ee.actApprove && e.circleId != null && e.subjectId != null) {
      final String? owner = owners[e.subjectId];
      if (owner != null && owner == e.userId && circleRoles[e.circleId] != null) {
        OwnerPolicy? policy = await trust.ownerPolicy(e.circleId!);
        if (policy == null && policyFallback != null) {
          policy = await policyFallback(e.circleId!);
          if (policy != null) await trust.setOwnerPolicy(e.circleId!, policy);
        }
        final String c = circleNames[e.circleId] ?? 'a circle';
        switch (classifyApproval(e, subjectOwner: owner, policy: policy, roles: circleRoles[e.circleId])) {
          case ApprovalKind.byOwnerWithoutSecondAdmin:
            await trust.markOwnerApproved(e.subjectId!, e.circleId!);
            if (e.userId != selfUserId) {
              out.add(E2eeAlarm(AlarmKind.ownerApproved, '$who approved their own new phone',
                  '$who set up a new phone and approved it in $c as the circle owner, without a second admin. If you did not expect this, compare your safety number with $who in person.',
                  userId: e.userId, circleId: e.circleId, seq: e.seq));
            }
          case ApprovalKind.invalidSelfApproval:
            out.add(E2eeAlarm(AlarmKind.invalidSelfApproval, '$who approved their own key without permission',
                'The key log of $c shows $who approving their own key, but owner approval is not on for $c (or $who did not create it). Do not trust new messages from $who until you compare your safety number in person.',
                userId: e.userId, circleId: e.circleId, seq: e.seq));
          case ApprovalKind.byOtherAdmin:
            break;
        }
      }
    }
    if (e.action == E2ee.actReset && e.userId != selfUserId) {
      final bool ver = await trust.isVerified(e.userId!);
      out.add(E2eeAlarm(
        ver ? AlarmKind.verifiedKeyChanged : AlarmKind.userReset,
        ver ? 'A verified member replaced all their keys' : 'A member replaced all their keys',
        '$who registered a brand-new identity. This happens when they lose their phone and have no backup, but it is also what an attacker would do. Compare your safety number with $who in person before approving.',
        userId: e.userId, seq: e.seq));
    }
    if ((e.action == E2ee.actEpoch || e.action == E2ee.actEnable) && e.userId != selfUserId) {
      if (!await trust.isVerified(e.userId!)) {
        final String c = circleNames[e.circleId] ?? 'a circle';
        out.add(E2eeAlarm(
          AlarmKind.epochByUnverified,
          'New encryption key in $c',
          'A new key (epoch ${e.epoch}) was published by $who, whom you have not verified. Verify $who in person so you know the key really comes from them.',
          userId: e.userId, circleId: e.circleId, seq: e.seq));
      }
    }
  }
  return out;
}
