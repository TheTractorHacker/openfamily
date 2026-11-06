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

enum AlarmKind { verifiedKeyChanged, keyChanged, userReset, epochByUnverified, logProblem, inviterMismatch }

class E2eeAlarm {
  const E2eeAlarm(this.kind, this.title, this.body, {this.userId, this.circleId, this.seq});
  final AlarmKind kind;
  final String title;
  final String body;
  final String? userId;
  final String? circleId;
  final int? seq;
  bool get severe =>
      kind == AlarmKind.verifiedKeyChanged ||
      kind == AlarmKind.logProblem ||
      kind == AlarmKind.inviterMismatch;
}

/// Alarms from NEW visible log entries: a member resetting all their keys, and
/// a circle epoch published by someone this phone never verified (a verified
/// admin is the only comfortable source of a new key).
Future<List<E2eeAlarm>> alarmsFromLog({
  required List<LogEntry> events,
  required String selfUserId,
  required TrustStore trust,
  required Map<String, String> userNames,
  required Map<String, String> circleNames,
}) async {
  final List<E2eeAlarm> out = <E2eeAlarm>[];
  for (final LogEntry e in events) {
    final String who = userNames[e.userId] ?? 'A member';
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
