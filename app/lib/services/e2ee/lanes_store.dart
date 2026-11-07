import 'dart:convert';

import 'e2ee_crypto.dart';
import 'private_channel.dart';

// Persisted, ALREADY VERIFIED lane facts of this phone (PRIVACY_PROCESSING
// sections 3 and 5.3). Only `LanesService` writes here, and only after it
// checked signatures and the transparency log; the sealer, the upload queue and
// the receiver read it through [KvLaneSource]. The background isolate has no
// network or vault session but shares this key/value store, so it seals and
// uploads in the right lane too.
//
// Everything fails closed: a missing, unreadable or inconsistent record means
// the phone lane / "server assistance off".

/// What a screen should tell the member about their own situation.
enum LaneStatus {
  /// Server assistance is off, or this member chose the phone lane.
  phoneOnly,

  /// This member's signed pref is the server lane and the policy is on.
  serverAssisted,

  /// The circle requires server processing (`required_server`) and this member
  /// has not signed their own consent: they must consent or leave. Nothing of
  /// theirs is sealed or sent to this circle meanwhile.
  consentRequired,

  /// The key log or the processing records failed verification; the phone lane is used.
  verificationFailed,
}

/// The verified admin policy of one circle.
class StoredPolicy {
  const StoredPolicy({
    required this.assist,
    required this.skGen,
    required this.defaultForNew,
    required this.memberOptOut,
  });
  static const StoredPolicy off =
      StoredPolicy(assist: false, skGen: 0, defaultForNew: E2ee.linePhone, memberOptOut: E2ee.optOutAllowed);
  final bool assist;
  final int skGen;
  final int defaultForNew;
  final int memberOptOut;

  Map<String, dynamic> toJson() =>
      <String, dynamic>{'a': assist, 'g': skGen, 'd': defaultForNew, 'o': memberOptOut};

  static StoredPolicy fromJson(Object? j) {
    if (j is! Map<String, dynamic>) return off;
    try {
      final int d = (j['d'] as num).toInt(), o = (j['o'] as num).toInt(), g = (j['g'] as num).toInt();
      if (!E2ee.validLine(d) || (o != E2ee.optOutAllowed && o != E2ee.optOutRequiredServer) || g < 0) return off;
      return StoredPolicy(assist: j['a'] == true && g >= 1, skGen: g, defaultForNew: d, memberOptOut: o);
    } catch (_) {
      return off;
    }
  }
}

/// A member's verified current lane.
class StoredMember {
  const StoredMember(this.userId, this.lane, this.seq, this.sinceMs);
  final String userId;
  final int lane;

  /// Position of the signed log entry that established it.
  final int seq;
  final int sinceMs;
}

class LaneStore {
  LaneStore(this.kv);
  final ChannelKv kv;

  String _own(String c) => 'lanes/own/$c';
  String _policy(String c) => 'lanes/policy/$c';
  String _status(String c) => 'lanes/status/$c';
  String _pending(String c) => 'lanes/pending/$c';
  String _members(String c) => 'lanes/members/$c';
  String _hist(String c, String u) => 'lanes/hist/$c/$u';

  Future<Map<String, dynamic>?> _json(String key) async {
    final String? raw = await kv.get(key);
    if (raw == null || raw.isEmpty) return null;
    try {
      final Object? d = jsonDecode(raw);
      return d is Map<String, dynamic> ? d : null;
    } catch (_) {
      return null;
    }
  }

  // ---- own lane (what the sealer uses)
  Future<LaneChoice> ownLane(String circleId) async {
    final Map<String, dynamic>? j = await _json(_own(circleId));
    if (j == null) return LaneChoice.phone;
    final int? l = (j['l'] as num?)?.toInt(), g = (j['g'] as num?)?.toInt();
    if (l == E2ee.lineServer && g != null && g >= 1) return LaneChoice(E2ee.lineServer, g);
    return LaneChoice.phone;
  }

  Future<void> setOwnLane(String circleId, LaneChoice c) =>
      kv.set(_own(circleId), jsonEncode(<String, dynamic>{'l': c.line, 'g': c.skGen}));

  // ---- policy
  Future<StoredPolicy> policy(String circleId) async => StoredPolicy.fromJson(await _json(_policy(circleId)));
  Future<void> setPolicy(String circleId, StoredPolicy p) => kv.set(_policy(circleId), jsonEncode(p.toJson()));

  // ---- status
  Future<LaneStatus> status(String circleId) async {
    final String? raw = await kv.get(_status(circleId));
    for (final LaneStatus s in LaneStatus.values) {
      if (s.name == raw) return s;
    }
    return LaneStatus.phoneOnly;
  }

  Future<void> setStatus(String circleId, LaneStatus s) => kv.set(_status(circleId), s.name);

  // ---- pending local opt-out (effective at once, before the server confirms)
  Future<String?> pendingPhoneRef(String circleId) async => (await _json(_pending(circleId)))?['ref'] as String?;
  Future<void> setPendingPhone(String circleId, String refHex) => kv.set(_pending(circleId), jsonEncode(<String, dynamic>{'ref': refHex}));
  Future<void> clearPending(String circleId) => kv.remove(_pending(circleId));

  // ---- members
  Future<List<StoredMember>> members(String circleId) async {
    final String? raw = await kv.get(_members(circleId));
    if (raw == null || raw.isEmpty) return <StoredMember>[];
    try {
      return <StoredMember>[
        for (final dynamic e in jsonDecode(raw) as List<dynamic>)
          if (e is List && e.length == 4 && e[0] is String && E2ee.validLine((e[1] as num).toInt()))
            StoredMember(e[0] as String, (e[1] as num).toInt(), (e[2] as num).toInt(), (e[3] as num).toInt())
      ];
    } catch (_) {
      return <StoredMember>[];
    }
  }

  Future<void> setMembers(String circleId, List<StoredMember> m) => kv.set(
      _members(circleId),
      jsonEncode(<List<dynamic>>[for (final StoredMember x in m) <dynamic>[x.userId, x.lane, x.seq, x.sinceMs]]));

  // ---- per-author pref history (for badges of received items)
  Future<List<({int seq, int lane, int sinceMs})>> history(String circleId, String userId) async {
    final String? raw = await kv.get(_hist(circleId, userId));
    if (raw == null || raw.isEmpty) return <({int seq, int lane, int sinceMs})>[];
    try {
      return <({int seq, int lane, int sinceMs})>[
        for (final dynamic e in jsonDecode(raw) as List<dynamic>)
          if (e is List && e.length == 3 && E2ee.validLine((e[1] as num).toInt()))
            (seq: (e[0] as num).toInt(), lane: (e[1] as num).toInt(), sinceMs: (e[2] as num).toInt())
      ];
    } catch (_) {
      return <({int seq, int lane, int sinceMs})>[];
    }
  }

  /// Appends a newly verified pref (a higher log position than any stored one).
  Future<void> appendHistory(String circleId, String userId, int seq, int lane, int sinceMs) async {
    final List<({int seq, int lane, int sinceMs})> h = await history(circleId, userId);
    if (h.isNotEmpty && h.last.seq >= seq) return;
    h.add((seq: seq, lane: lane, sinceMs: sinceMs));
    final List<({int seq, int lane, int sinceMs})> kept = h.length > 50 ? h.sublist(h.length - 50) : h;
    await kv.set(_hist(circleId, userId), jsonEncode(<List<int>>[for (final e in kept) <int>[e.seq, e.lane, e.sinceMs]]));
  }

  /// Forgets every stored lane fact of a circle (no longer private / left).
  Future<void> clearCircle(String circleId) async {
    for (final String k in <String>[_own(circleId), _policy(circleId), _status(circleId), _pending(circleId), _members(circleId)]) {
      await kv.remove(k);
    }
  }
}

/// [LaneSource] over the persisted, verified facts.
class KvLaneSource implements LaneSource {
  KvLaneSource(ChannelKv kv) : store = LaneStore(kv);
  final LaneStore store;

  @override
  Future<LaneChoice> ownLane(String circleId) async {
    try {
      final StoredPolicy p = await store.policy(circleId);
      if (!p.assist) return LaneChoice.phone;
      final LaneChoice c = await store.ownLane(circleId);
      return c.line == E2ee.lineServer ? LaneChoice(E2ee.lineServer, p.skGen) : LaneChoice.phone;
    } catch (_) {
      return LaneChoice.phone;
    }
  }

  @override
  Future<bool> serverLaneAllowed(String circleId) async {
    try {
      final StoredPolicy p = await store.policy(circleId);
      if (!p.assist) return false;
      final LaneChoice c = await store.ownLane(circleId);
      return c.line == E2ee.lineServer;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> serverAssistOn(String circleId) async {
    try {
      return (await store.policy(circleId)).assist;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<List<PrefEntry>> prefsOf(String circleId, String userId) async {
    try {
      return <PrefEntry>[for (final e in await store.history(circleId, userId)) PrefEntry(e.lane, e.sinceMs)];
    } catch (_) {
      return <PrefEntry>[];
    }
  }
}
