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
  /// [fresh]: read every fact straight from the store (never a cache). The sealer and the
  /// upload queue use it, because the background isolate and the app both write.
  LaneStore(this.kv, {this.fresh = false});
  final ChannelKv kv;
  final bool fresh;

  Future<String?> _get(String key) => fresh ? kv.getFresh(key) : kv.get(key);
  String _ver(String c) => 'lanes/ver/$c';
  String _histUsers(String c) => 'lanes/histusers/$c';

  /// A counter that changes whenever a lane fact of [circleId] is written.
  Future<int> version(String circleId) async => int.tryParse(await kv.getFresh(_ver(circleId)) ?? '') ?? 0;
  Future<void> _bumpVer(String circleId) async => kv.set(_ver(circleId), '${await version(circleId) + 1}');

  String _own(String c) => 'lanes/own/$c';
  String _policy(String c) => 'lanes/policy/$c';
  String _status(String c) => 'lanes/status/$c';
  String _pending(String c) => 'lanes/pending/$c';
  String _members(String c) => 'lanes/members/$c';
  String _hist(String c, String u) => 'lanes/hist/$c/$u';

  Future<Map<String, dynamic>?> _json(String key) async {
    final String? raw = await _get(key);
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

  /// [prefGen]: the server-key generation this member's verified signed pref names (it may be older than the
  /// policy's current one, which both the phone and the server accept). Diagnostics only; the sealer never uses it.
  Future<void> setOwnLane(String circleId, LaneChoice c, {int prefGen = 0}) async {
    await kv.set(_own(circleId), jsonEncode(<String, dynamic>{'l': c.line, 'g': c.skGen, if (prefGen > 0) 'pg': prefGen}));
    await _bumpVer(circleId);
  }

  /// The server-key generation named by this member's own verified server-lane pref (0: none / phone lane / unknown).
  Future<int> ownPrefGen(String circleId) async => ((await _json(_own(circleId)))?['pg'] as num?)?.toInt() ?? 0;

  // ---- policy
  Future<StoredPolicy> policy(String circleId) async => StoredPolicy.fromJson(await _json(_policy(circleId)));
  Future<void> setPolicy(String circleId, StoredPolicy p) async {
    await kv.set(_policy(circleId), jsonEncode(p.toJson()));
    await _bumpVer(circleId);
  }

  // ---- status
  Future<LaneStatus> status(String circleId) async {
    final String? raw = await _get(_status(circleId));
    for (final LaneStatus s in LaneStatus.values) {
      if (s.name == raw) return s;
    }
    return LaneStatus.phoneOnly;
  }

  Future<void> setStatus(String circleId, LaneStatus s) => kv.set(_status(circleId), s.name);

  // ---- pending local opt-out (effective at once, before the server confirms)
  Future<String?> pendingPhoneRef(String circleId) async => (await _json(_pending(circleId)))?['ref'] as String?;
  Future<void> setPendingPhone(String circleId, String refHex) async {
    await kv.set(_pending(circleId), jsonEncode(<String, dynamic>{'ref': refHex, 'at': DateTime.now().millisecondsSinceEpoch}));
    await _bumpVer(circleId);
  }

  String _pendingBody(String c) => 'lanes/pendingbody/$c';

  /// The signed request of an opt-out that the server has not accepted yet (kept so it can be sent again).
  Future<Map<String, dynamic>?> pendingBody(String circleId) => _json(_pendingBody(circleId));
  Future<void> setPendingBody(String circleId, Map<String, dynamic> body) => kv.set(_pendingBody(circleId), jsonEncode(body));
  Future<void> clearPendingBody(String circleId) => kv.remove(_pendingBody(circleId));

  Future<void> clearPending(String circleId) async {
    await kv.remove(_pendingBody(circleId));
    await kv.remove(_pending(circleId));
    await _bumpVer(circleId);
  }

  /// When the local opt-out was made while the server has not confirmed it yet, else null.
  Future<DateTime?> pendingSince(String circleId) async {
    final int? at = ((await _json(_pending(circleId)))?['at'] as num?)?.toInt();
    return at == null ? null : DateTime.fromMillisecondsSinceEpoch(at);
  }

  // ---- members
  Future<List<StoredMember>> members(String circleId) async {
    final String? raw = await _get(_members(circleId));
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
    final String? raw = await _get(_hist(circleId, userId));
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
    final Set<String> users = await _histUserSet(circleId)
      ..add(userId);
    await kv.set(_histUsers(circleId), jsonEncode(users.toList()));
  }

  Future<Set<String>> _histUserSet(String circleId) async {
    try {
      return <String>{for (final dynamic u in jsonDecode(await _get(_histUsers(circleId)) ?? '[]') as List<dynamic>) '$u'};
    } catch (_) {
      return <String>{};
    }
  }

  // ---- auto-apply record (section 23). Deliberately NOT cleared with the circle facts: an opt-out stays sticky.
  String _auto(String c) => 'lanes/auto/$c';

  Future<AutoApplyRecord?> autoRecord(String circleId) async => AutoApplyRecord.fromJson(await _json(_auto(circleId)));
  Future<void> setAutoRecord(String circleId, AutoApplyRecord r) => kv.set(_auto(circleId), jsonEncode(r.toJson()));

  /// Circles with a notice the member has not dismissed yet ("Your circle uses the server...").
  Future<void> dismissAutoNotice(String circleId) async {
    final AutoApplyRecord? r = await autoRecord(circleId);
    if (r != null && !r.dismissed) await setAutoRecord(circleId, r.copyWith(dismissed: true));
  }

  /// Forgets every stored lane fact of a circle (no longer private / left).
  Future<void> clearCircle(String circleId) async {
    // The pref history of every member we know of goes too (it names who chose what).
    final Set<String> users = <String>{for (final StoredMember m in await members(circleId)) m.userId, ...await _histUserSet(circleId)};
    await kv.remove(_histUsers(circleId));
    for (final String u in users) {
      await kv.remove(_hist(circleId, u));
    }
    for (final String k in <String>[_own(circleId), _policy(circleId), _status(circleId), _pending(circleId), _pendingBody(circleId), _members(circleId)]) {
      await kv.remove(k);
    }
    await _bumpVer(circleId);
  }
}

/// What this phone did on its own for the member in one circle (section 23).
class AutoApplyRecord {
  const AutoApplyRecord({required this.state, required this.atMs, this.dismissed = false});

  /// 'applied': this phone signed the server lane by itself. 'declined': the member kept their data on the phone (sticky).
  final String state;
  final int atMs;

  /// The in-app notice was dismissed.
  final bool dismissed;

  bool get applied => state == 'applied';
  bool get declined => state == 'declined';

  AutoApplyRecord copyWith({String? state, bool? dismissed}) => AutoApplyRecord(state: state ?? this.state, atMs: atMs, dismissed: dismissed ?? this.dismissed);
  Map<String, dynamic> toJson() => <String, dynamic>{'s': state, 'at': atMs, 'd': dismissed};
  static AutoApplyRecord? fromJson(Map<String, dynamic>? j) {
    if (j == null) return null;
    final Object? s = j['s'];
    if (s != 'applied' && s != 'declined') return null;
    return AutoApplyRecord(state: s as String, atMs: (j['at'] as num?)?.toInt() ?? 0, dismissed: j['d'] == true);
  }
}

/// [LaneSource] over the persisted, verified facts.
class KvLaneSource implements LaneSource, VersionedLaneSource {
  KvLaneSource(ChannelKv kv) : store = LaneStore(kv, fresh: true);
  final LaneStore store;

  @override
  Future<int> laneVersion(String circleId) => store.version(circleId);

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
