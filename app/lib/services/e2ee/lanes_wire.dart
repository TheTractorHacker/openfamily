import 'dart:typed_data';

import 'e2ee_crypto.dart';

// Everything about the SERVER side of processing lanes that the phone has to
// agree on with backend/ lives in this file: URL paths, JSON field names and
// the (de)serialisation of the signed statements. When the server lands and a
// name differs, this is the only place to change (plus the fake in
// app/test/support/fake_e2ee_server.dart, which uses the same helpers).
//
// Nothing here is trusted: every record below is only a CLAIM by the server
// until `LanesService` has checked its signature and the transparency log.

/// Paths (relative to the API base).
class LanesPaths {
  LanesPaths._();
  static String state(String circle) => '/circles/$circle/e2ee/processing';
  static String policy(String circle) => '/circles/$circle/e2ee/processing-policy';
  static String pref(String circle) => '/circles/$circle/e2ee/processing-pref';
  static String upgrade(String circle) => '/circles/$circle/e2ee/processing-upgrade';
  static String legacyAccess(String circle) => '/circles/$circle/e2ee/legacy-server-access';

  /// Existing wrap routes; the line travels in the body / records (`key_line`).
  static String wraps(String circle) => '/circles/$circle/e2ee/wraps';
}

/// JSON field names. `key_line` is also the item field of upload / download.
class LanesFields {
  LanesFields._();
  static const String keyLine = 'key_line';
  static const String caps = 'caps';
  static const String lane = 'lane';
}

/// A signed `processing_policy` statement as the server stores and relays it.
class PolicyStatement {
  const PolicyStatement({
    required this.serverAssist,
    required this.defaultForNew,
    required this.memberOptOut,
    required this.skGen,
    required this.commitment,
    required this.nonce,
    required this.adminUserId,
    required this.actorDeviceId,
    required this.signature,
    this.sinceMs = 0,
  });

  final bool serverAssist;

  /// 0 phone / 1 server (a lane value).
  final int defaultForNew;

  /// [E2ee.optOutAllowed] / [E2ee.optOutRequiredServer].
  final int memberOptOut;
  final int skGen;
  final Uint8List commitment;
  final Uint8List nonce;
  final String adminUserId;
  final String actorDeviceId;
  final Uint8List signature;

  /// Advisory (server recorded).
  final int sinceMs;

  /// The exact bytes that were signed; throws [E2eeFormatException] for a
  /// statement that is not well formed.
  Uint8List message(String circleId) => E2ee.processingPolicyMessage(
      circleId, adminUserId, serverAssist, defaultForNew, memberOptOut, skGen, commitment, nonce);

  Future<Uint8List> ref(String circleId) async => E2ee.processingRef(message(circleId));

  Map<String, dynamic> toJson() => <String, dynamic>{
        'server_assist': serverAssist,
        'default_for_new': E2ee.lineName(defaultForNew),
        'member_opt_out': E2ee.optOutName(memberOptOut),
        'sk_gen': skGen,
        'commitment': E2ee.b64(commitment),
        'nonce': E2ee.b64(nonce),
        'admin_user_id': adminUserId,
        'actor_device_id': actorDeviceId,
        'signature': E2ee.b64(signature),
      };

  /// Null for a malformed record or an unknown enum value (fail closed).
  static PolicyStatement? tryParse(Object? j) {
    if (j is! Map<String, dynamic>) return null;
    try {
      return PolicyStatement(
        serverAssist: j['server_assist'] == true,
        defaultForNew: E2ee.parseLine(j['default_for_new'] as String),
        memberOptOut: E2ee.parseOptOut((j['member_opt_out'] as String?) ?? 'allowed'),
        skGen: (j['sk_gen'] as num).toInt(),
        commitment: E2ee.unb64(j['commitment'] as String),
        nonce: E2ee.unb64(j['nonce'] as String),
        adminUserId: j['admin_user_id'] as String,
        actorDeviceId: j['actor_device_id'] as String,
        signature: E2ee.unb64(j['signature'] as String),
        sinceMs: _ms(j['since']),
      );
    } catch (_) {
      return null;
    }
  }
}

/// A signed `processing_pref` statement (one member, one circle).
class PrefStatement {
  const PrefStatement({
    required this.userId,
    required this.lane,
    required this.skGen,
    required this.serverDeviceId,
    required this.nonce,
    required this.approverDeviceId,
    required this.signature,
    this.sinceMs = 0,
  });

  final String userId;
  final int lane;
  final int skGen;

  /// [E2ee.zeroUuid] for lane phone.
  final String serverDeviceId;
  final Uint8List nonce;
  final String approverDeviceId;
  final Uint8List signature;
  final int sinceMs;

  /// The statement bytes; [serverFingerprint] must be the fingerprint of the
  /// server key (all zero for lane phone). Throws on malformed combinations.
  Uint8List message(String circleId, Uint8List serverFingerprint) =>
      E2ee.processingPrefMessage(circleId, userId, lane, skGen, serverDeviceId, serverFingerprint, nonce);

  /// Request body of PUT .../processing-pref. [serverFingerprint]: 32 raw bytes (zero for lane phone), sent as base64.
  /// The user is never part of the body (the server takes it from the session).
  Map<String, dynamic> toRequest(Uint8List serverFingerprint) => <String, dynamic>{
        LanesFields.lane: E2ee.lineName(lane),
        'sk_gen': skGen,
        'server_device_id': serverDeviceId,
        'server_fingerprint': E2ee.b64(serverFingerprint),
        'nonce': E2ee.b64(nonce),
        'approver_device_id': approverDeviceId,
        'signature': E2ee.b64(signature),
      };

  Map<String, dynamic> toJson() => <String, dynamic>{
        'user_id': userId,
        LanesFields.lane: E2ee.lineName(lane),
        'sk_gen': skGen,
        'server_device_id': serverDeviceId,
        'nonce': E2ee.b64(nonce),
        'approver_device_id': approverDeviceId,
        'signature': E2ee.b64(signature),
      };

  static PrefStatement? tryParse(Object? j, {String? userId}) {
    if (j is! Map<String, dynamic>) return null;
    try {
      return PrefStatement(
        userId: userId ?? j['user_id'] as String,
        lane: E2ee.parseLine(j[LanesFields.lane] as String),
        skGen: (j['sk_gen'] as num).toInt(),
        serverDeviceId: ((j['server_device_id'] as String?) ?? '').isEmpty ? E2ee.zeroUuid : j['server_device_id'] as String,
        nonce: E2ee.unb64(j['nonce'] as String),
        approverDeviceId: j['approver_device_id'] as String,
        signature: E2ee.unb64(j['signature'] as String),
        sinceMs: _ms(j['since']),
      );
    } catch (_) {
      return null;
    }
  }
}

int _ms(Object? v) {
  if (v is num) return v.toInt();
  if (v is String) return DateTime.tryParse(v)?.toUtc().millisecondsSinceEpoch ?? 0;
  return 0;
}

/// The server's CLAIMED member rows. Used for display fallbacks only, never to
/// decide a lane.
class ClaimedMember {
  const ClaimedMember(this.userId, this.lane, this.sinceMs);
  final String userId;
  final int lane;
  final int sinceMs;
}

/// Raw `GET /circles/{id}/e2ee/processing` response (server doc section 18.2).
/// Every field is a claim; `LanesService` verifies against the key log.
class ProcessingServerState {
  const ProcessingServerState({
    this.serverAssist = false,
    this.skGen = 0,
    this.policy,
    this.prefs = const <PrefStatement>[],
    this.claimedMembers = const <ClaimedMember>[],
    this.serverDeviceId,
    this.serverFingerprint,
    this.rekeyRequired = false,
    this.inEffect = false,
    this.legacy = false,
  });

  static const ProcessingServerState off = ProcessingServerState();

  /// Claimed (not used to decide anything).
  final bool serverAssist;
  final int skGen;

  /// The newest signed policy statement the server holds (`policy.statement`).
  final PolicyStatement? policy;
  final List<PrefStatement> prefs;
  final List<ClaimedMember> claimedMembers;

  /// The pinned server device (`device`), lower-case hex fingerprint.
  final String? serverDeviceId;
  final String? serverFingerprint;

  /// `policy.rekey_required`: the server line key must rotate (member removed / key revoked).
  final bool rekeyRequired;

  /// `in_effect`: the server says assistance is in effect, i.e. it holds the current SK.
  final bool inEffect;

  /// `legacy`: the circle is still in the old trusted-server mode (the server
  /// holds the phone key of some epochs). An admin can upgrade it.
  final bool legacy;

  factory ProcessingServerState.fromJson(Map<String, dynamic> j) {
    final Object? sd = j['device'];
    final Object? pol = j['policy'];
    final Map<String, dynamic> polMap = pol is Map<String, dynamic> ? pol : const <String, dynamic>{};
    final List<PrefStatement> prefs = <PrefStatement>[];
    final List<ClaimedMember> claimed = <ClaimedMember>[];
    for (final dynamic m in (j['members'] as List<dynamic>?) ?? <dynamic>[]) {
      if (m is! Map<String, dynamic> || m['user_id'] is! String) continue;
      final String uid = m['user_id'] as String;
      final int? lane = m[LanesFields.lane] is String ? _laneOrNull(m[LanesFields.lane] as String) : null;
      if (lane != null) claimed.add(ClaimedMember(uid, lane, _ms(m['since'])));
      final PrefStatement? p = PrefStatement.tryParse(m['pref'], userId: uid);
      if (p != null) {
        prefs.add(PrefStatement(
            userId: p.userId, lane: p.lane, skGen: p.skGen, serverDeviceId: p.serverDeviceId, nonce: p.nonce,
            approverDeviceId: p.approverDeviceId, signature: p.signature, sinceMs: _ms(m['since'])));
      }
    }
    return ProcessingServerState(
      serverAssist: polMap['server_assist'] == true,
      skGen: (polMap['sk_gen'] as num?)?.toInt() ?? 0,
      policy: PolicyStatement.tryParse(polMap['statement']),
      prefs: prefs,
      claimedMembers: claimed,
      serverDeviceId: sd is Map<String, dynamic> ? sd['device_id'] as String? : null,
      serverFingerprint: sd is Map<String, dynamic> ? sd['fingerprint'] as String? : null,
      rekeyRequired: polMap['rekey_required'] == true,
      inEffect: j['in_effect'] == true,
      legacy: j['legacy'] == true,
    );
  }

  static int? _laneOrNull(String s) {
    try {
      return E2ee.parseLine(s);
    } catch (_) {
      return null;
    }
  }
}
