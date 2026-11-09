import 'dart:typed_data';

import 'e2ee_crypto.dart';

/// Public record of one registered key (device or recovery identity), as the
/// server returns it. Only public data; nothing here can decrypt anything.
class DeviceKey {
  const DeviceKey({
    required this.deviceId,
    required this.userId,
    required this.kind,
    required this.edPub,
    required this.xPub,
    required this.fingerprint,
    required this.digits,
    required this.short,
    required this.registeredByDeviceId,
    required this.registeredByPub,
    required this.registrationAction,
    required this.registrationSignature,
    required this.initial,
    required this.label,
    required this.createdAt,
    this.revokedAt,
    this.revokedReason,
    this.approved,
    this.userName,
    this.caps = const <String>[],
    this.ownerApproved = false,
  });

  final String deviceId;
  final String userId;

  /// 'device' or 'recovery'.
  final String kind;
  final Uint8List edPub;
  final Uint8List xPub;

  /// Lower-case hex SHA-256 fingerprint as stored by the server.
  final String fingerprint;
  final String digits;
  final String short;
  final String registeredByDeviceId;
  final Uint8List registeredByPub;
  final int registrationAction;
  final Uint8List registrationSignature;
  final bool initial;
  final String label;
  final DateTime createdAt;
  final DateTime? revokedAt;
  final String? revokedReason;

  /// Circle context only: false means "waiting for approval".
  final bool? approved;
  final String? userName;

  /// Circle context only, as the server reports it: approved by its owner under
  /// the circle's owner-approval rule, without a second admin. Phones confirm
  /// it from the signed key log (see e2ee_trust.dart, owner approval).
  final bool ownerApproved;

  /// Capabilities the app advertised at registration (e.g. `lanes2`). Self
  /// reported by that key's owner and relayed by the server: it gates whether
  /// an admin may enable server assistance, it never grants access to anything.
  final List<String> caps;

  bool get supportsLanes => caps.contains(kCapLanes);
  bool get supportsChat => caps.contains(kCapChat);

  bool get isRecovery => kind == 'recovery';
  bool get isActive => revokedAt == null;
  bool get isRoot => registeredByDeviceId == deviceId;

  factory DeviceKey.fromJson(Map<String, dynamic> j) => DeviceKey(
        deviceId: j['device_id'] as String,
        userId: j['user_id'] as String,
        kind: (j['kind'] as String?) ?? 'device',
        edPub: E2ee.unb64(j['ed25519_pub'] as String),
        xPub: E2ee.unb64(j['x25519_pub'] as String),
        fingerprint: j['fingerprint'] as String,
        digits: (j['digits'] as String?) ?? '',
        short: (j['short'] as String?) ?? '',
        registeredByDeviceId: j['registered_by_device_id'] as String,
        registeredByPub: E2ee.unb64(j['registered_by_ed25519_pub'] as String),
        registrationAction: (j['registration_action'] as num).toInt(),
        registrationSignature: E2ee.unb64(j['registration_signature'] as String),
        initial: j['initial'] == true,
        label: (j['label'] as String?) ?? '',
        createdAt: DateTime.parse(j['created_at'] as String).toUtc(),
        revokedAt: j['revoked_at'] is String
            ? DateTime.parse(j['revoked_at'] as String).toUtc()
            : null,
        revokedReason: j['revoked_reason'] as String?,
        approved: j['approved'] as bool?,
        ownerApproved: j['owner_approved'] == true,
        userName: j['user_name'] as String?,
        caps: j['caps'] is List ? (j['caps'] as List<dynamic>).whereType<String>().toList() : const <String>[],
      );
}

/// Capability string of the processing-lanes format (v2 items, SK wraps).
const String kCapLanes = 'lanes2';

/// Capability string of encrypted chat (docs/design/E2EE_CHAT.md).
const String kCapChat = 'chat2';

class CircleE2eeMember {
  const CircleE2eeMember({
    required this.userId,
    required this.name,
    required this.role,
    required this.devices,
  });
  final String userId;
  final String name;
  final String role;
  final List<DeviceKey> devices;
}

/// The signed log record of one circle key epoch: who published it and the key
/// commitment they signed. Copied by the server from the immutable log; phones
/// verify the signature themselves.
class EpochRecord {
  const EpochRecord({
    required this.epoch,
    required this.action,
    required this.publisherUserId,
    required this.publisherDeviceId,
    required this.publisherPub,
    required this.commitment,
    required this.signature,
  });
  final int epoch;
  final int action;
  final String publisherUserId;
  final String publisherDeviceId;
  final Uint8List publisherPub;
  final Uint8List commitment;
  final Uint8List signature;

  factory EpochRecord.fromJson(Map<String, dynamic> j) => EpochRecord(
        epoch: (j['epoch'] as num).toInt(),
        action: (j['action'] as num).toInt(),
        publisherUserId: j['publisher_user_id'] as String,
        publisherDeviceId: j['publisher_device_id'] as String,
        publisherPub: E2ee.unb64(j['publisher_ed25519_pub'] as String),
        commitment: E2ee.unb64(j['key_commitment'] as String),
        signature: E2ee.unb64(j['signature'] as String),
      );
}

class CircleE2eeState {
  const CircleE2eeState({
    required this.circleId,
    required this.mode,
    required this.epoch,
    required this.rekeyRequired,
    required this.members,
    this.epochs = const <EpochRecord>[],
    this.createdBy,
    this.ownerApproval = false,
    this.ownerApprovalSeq,
  });
  final List<EpochRecord> epochs;

  /// The user who created the circle (older servers: null).
  final String? createdBy;

  /// The circle's owner-approval rule is on (server view; the signed log entry
  /// is what phones trust).
  final bool ownerApproval;

  /// Key-log seq of the latest owner-approval entry of this circle, if any.
  final int? ownerApprovalSeq;

  /// Live admins of the circle.
  Iterable<String> get adminIds => members.where((CircleE2eeMember m) => m.role == 'admin').map((CircleE2eeMember m) => m.userId);
  final String circleId;
  final String mode;
  final int epoch;
  final bool rekeyRequired;
  final List<CircleE2eeMember> members;

  bool get isPrivate => mode == 'private';

  /// The latest signed record for [epoch] (a re-enable reuses nothing, but be safe).
  EpochRecord? epochRecord(int epoch) {
    EpochRecord? r;
    for (final EpochRecord e in epochs) {
      if (e.epoch == epoch) r = e;
    }
    return r;
  }

  Iterable<DeviceKey> get allDevices =>
      members.expand((CircleE2eeMember m) => m.devices);

  factory CircleE2eeState.fromJson(Map<String, dynamic> j) => CircleE2eeState(
        circleId: j['circle_id'] as String,
        mode: j['mode'] as String? ?? 'off',
        epoch: (j['epoch'] as num?)?.toInt() ?? 0,
        rekeyRequired: j['rekey_required'] == true,
        createdBy: j['created_by'] as String?,
        ownerApproval: j['owner_approval'] == true,
        ownerApprovalSeq: (j['owner_approval_seq'] as num?)?.toInt(),
        epochs: ((j['epochs'] as List<dynamic>?) ?? <dynamic>[])
            .cast<Map<String, dynamic>>()
            .map(EpochRecord.fromJson)
            .toList(),
        members: ((j['members'] as List<dynamic>?) ?? <dynamic>[])
            .cast<Map<String, dynamic>>()
            .map((Map<String, dynamic> m) => CircleE2eeMember(
                  userId: m['user_id'] as String,
                  name: m['name'] as String? ?? '',
                  role: m['role'] as String? ?? 'member',
                  devices: ((m['devices'] as List<dynamic>?) ?? <dynamic>[])
                      .cast<Map<String, dynamic>>()
                      .map(DeviceKey.fromJson)
                      .toList(),
                ))
            .toList(),
      );
}

class WrapRecord {
  const WrapRecord({
    required this.epoch,
    required this.recipientDeviceId,
    required this.wrapperDeviceId,
    required this.wrapperEdPub,
    required this.blob,
    required this.signature,
    this.line = E2ee.linePhone,
  });

  /// Key line of the wrap (0 phone = CK, 1 server = SK). For the server line
  /// [epoch] is the SK generation. A missing `key_line` is the phone line.
  final int line;
  final int epoch;
  final String recipientDeviceId;
  final String wrapperDeviceId;
  final Uint8List wrapperEdPub;
  final Uint8List blob;
  final Uint8List signature;

  factory WrapRecord.fromJson(Map<String, dynamic> j) => WrapRecord(
        epoch: (j['epoch'] as num).toInt(),
        recipientDeviceId: j['recipient_device_id'] as String,
        wrapperDeviceId: j['wrapper_device_id'] as String,
        wrapperEdPub: E2ee.unb64(j['wrapper_ed25519_pub'] as String),
        blob: E2ee.unb64(j['wrapped_key'] as String),
        signature: E2ee.unb64(j['signature'] as String),
        line: j['key_line'] == null ? E2ee.linePhone : E2ee.parseLine(j['key_line'] as String),
      );

  /// Null for a malformed record, including an unknown key line (fail closed:
  /// a wrap we cannot classify is never used).
  static WrapRecord? tryParse(Map<String, dynamic> j) {
    try {
      return WrapRecord.fromJson(j);
    } catch (_) {
      return null;
    }
  }
}

/// One entry of the key transparency log. Redacted entries (about people the
/// caller shares no circle with) only carry the hashes.
class LogEntry {
  const LogEntry({
    required this.seq,
    required this.prevHash,
    required this.entryHash,
    required this.redacted,
    this.action,
    this.userId,
    this.actorDeviceId,
    this.actorPub,
    this.circleId,
    this.subjectId,
    this.epoch,
    this.ref,
    this.signature,
  });
  final int seq;
  final Uint8List prevHash;
  final Uint8List entryHash;
  final bool redacted;
  final int? action;
  final String? userId;
  final String? actorDeviceId;
  final Uint8List? actorPub;
  final String? circleId;
  final String? subjectId;
  final int? epoch;
  final Uint8List? ref;
  final Uint8List? signature;

  factory LogEntry.fromJson(Map<String, dynamic> j) {
    final bool red = j['redacted'] == true;
    return LogEntry(
      seq: (j['seq'] as num).toInt(),
      prevHash: E2ee.unhex(j['prev_hash'] as String),
      entryHash: E2ee.unhex(j['entry_hash'] as String),
      redacted: red,
      action: (j['action'] as num?)?.toInt(),
      userId: j['user_id'] as String?,
      actorDeviceId: j['actor_device_id'] as String?,
      actorPub: j['actor_ed25519_pub'] is String ? E2ee.unb64(j['actor_ed25519_pub'] as String) : null,
      circleId: j['circle_id'] as String?,
      subjectId: j['subject_id'] as String?,
      epoch: (j['epoch'] as num?)?.toInt(),
      ref: j['ref'] is String ? E2ee.unhex(j['ref'] as String) : null,
      signature: j['signature'] is String ? E2ee.unb64(j['signature'] as String) : null,
    );
  }
}

class LogHead {
  const LogHead(this.seq, this.hash);
  final int seq;
  final Uint8List hash;
  String get hex => E2ee.hex(hash);
}

/// One member's signed consent for the Orbitly server to read a circle.
class ServerConsent {
  const ServerConsent(this.userId, this.approverDeviceId, this.signature);
  final String userId;
  final String approverDeviceId;
  final Uint8List signature;
}

/// The Orbitly server's own device key, as pinned by the server.
class ServerDeviceInfo {
  const ServerDeviceInfo({required this.deviceId, required this.fingerprint, required this.short, required this.digits, required this.label, required this.ownerUserId});
  final String deviceId;

  /// Lower-case hex SHA-256 fingerprint.
  final String fingerprint;
  final String short;
  final String digits;
  final String label;
  final String ownerUserId;

  static ServerDeviceInfo? fromJson(Object? j) {
    if (j is! Map<String, dynamic>) return null;
    final Object? id = j['device_id'], fp = j['fingerprint'];
    if (id is! String || fp is! String) return null;
    return ServerDeviceInfo(
      deviceId: id,
      fingerprint: fp,
      short: (j['short'] as String?) ?? '',
      digits: (j['digits'] as String?) ?? '',
      label: (j['label'] as String?) ?? 'Orbitly server',
      ownerUserId: (j['owner_user_id'] as String?) ?? '',
    );
  }
}

/// Trusted-server mode state of one circle (GET /circles/{id}/e2ee/server-member).
class ServerMemberState {
  const ServerMemberState({
    this.enabled = false,
    this.device,
    this.serverMember = false,
    this.wrapped = false,
    this.consents = const <ServerConsent>[],
    this.myConsent = false,
  });
  final bool enabled;
  final ServerDeviceInfo? device;

  /// The server says it can read the circle (a claim; the phone re-checks the consents).
  final bool serverMember;
  final bool wrapped;
  final List<ServerConsent> consents;
  final bool myConsent;

  static const ServerMemberState off = ServerMemberState();

  factory ServerMemberState.fromJson(Map<String, dynamic> j) => ServerMemberState(
        enabled: j['enabled'] == true,
        device: ServerDeviceInfo.fromJson(j['device']),
        serverMember: j['server_member'] == true,
        wrapped: j['wrapped'] == true,
        myConsent: j['my_consent'] == true,
        consents: ((j['consents'] as List<dynamic>?) ?? <dynamic>[])
            .cast<Map<String, dynamic>>()
            .map((Map<String, dynamic> c) => ServerConsent(
                c['user_id'] as String, c['approver_device_id'] as String, E2ee.unb64(c['signature'] as String)))
            .toList(),
      );
}

/// The server's deployment profile as the app sees it (GET /e2ee/server-device;
/// docs/design/PRIVACY_PROCESSING.md section 21). Advice and wording only: it
/// never signs or consents for anybody. An older server sends none of these
/// fields, which reads as [unknown] and gets the careful (hosted) wording.
class ServerProfile {
  const ServerProfile({
    this.known = false,
    this.profile = '',
    this.effective = 'cloud',
    this.recommendedLane = 'phone',
    this.dataAtRestKey = false,
    this.enabled = false,
    this.device,
    this.builtin = false,
    this.memberDefaultLane = 'phone',
    this.autoApply = false,
    this.followCircleDefault = false,
  });

  /// Section 24: no administrator saved a member default, so a circle whose admin-signed policy says "server by
  /// default" (`default_for_new = server`) also puts its members on the server (their OWN phone signs, with a notice).
  /// An older server sends nothing: false, so nothing changes.
  final bool followCircleDefault;

  /// Section 23: the admin's member default ('server' | 'phone') and whether members' own phones sign it on next open.
  /// An older server sends none: read as phone, no auto-apply, so nothing changes for anyone.
  final String memberDefaultLane;
  final bool autoApply;

  /// The server is its own device (no separate sidecar to set up).
  final bool builtin;

  /// False when the server sent no profile fields (an older server).
  final bool known;

  /// 'home' | 'cloud' | '' (nobody chose yet).
  final String profile;

  /// What to act on: 'home' only when the owner chose it, otherwise 'cloud'.
  final String effective;

  /// 'server' only for a home server with an enrolled key; otherwise 'phone'.
  final String recommendedLane;
  final bool dataAtRestKey;

  /// The server runs the trusted-server component (has an ingest token).
  final bool enabled;
  final ServerDeviceInfo? device;

  bool get isHome => effective == 'home';
  /// The server recommends its own lane (a key is enrolled and the server runs at home, or the admin chose it).
  bool get serverRecommended => recommendedLane == 'server';

  static const ServerProfile unknown = ServerProfile();

  factory ServerProfile.fromJson(Map<String, dynamic> j) {
    final bool has = j.containsKey('profile_effective');
    return ServerProfile(
      known: has,
      profile: (j['deployment_profile'] as String?) ?? '',
      effective: j['profile_effective'] == 'home' ? 'home' : 'cloud',
      recommendedLane: j['recommended_lane'] == 'server' ? 'server' : 'phone',
      dataAtRestKey: j['data_at_rest_key'] == true,
      enabled: j['enabled'] == true,
      device: ServerDeviceInfo.fromJson(j['device']),
      builtin: j['builtin'] == true,
      memberDefaultLane: (j['member_defaults'] is Map && (j['member_defaults'] as Map)['default_lane'] == 'server') ? 'server' : 'phone',
      autoApply: j['member_defaults'] is Map && (j['member_defaults'] as Map)['auto_apply'] == true && (j['member_defaults'] as Map)['default_lane'] == 'server',
      followCircleDefault: j['member_defaults'] is Map && (j['member_defaults'] as Map)['follow_circle_default'] == true,
    );
  }
}

/// "Your server wants to join": the built-in server device waiting for a phone to approve its key
/// (GET /e2ee/server-join).
class ServerJoinInfo {
  const ServerJoinInfo({this.builtin = false, this.waiting = false, this.canApprove = false, this.requestCode = '', this.deviceId = '', this.short = '', this.digits = '', this.state = '', this.replaces = ''});
  final bool builtin;
  final bool waiting;
  final bool canApprove;
  final String requestCode;
  final String deviceId;
  final String short;
  final String digits;
  final String state;

  /// The device id of the revoked server key this waiting key replaces ('' for a first key or an older server).
  final String replaces;

  static const ServerJoinInfo none = ServerJoinInfo();

  factory ServerJoinInfo.fromJson(Map<String, dynamic> j) {
    final Object? r = j['request'];
    final Map<String, dynamic> req = r is Map<String, dynamic> ? r : const <String, dynamic>{};
    return ServerJoinInfo(
      builtin: j['builtin'] == true,
      waiting: j['waiting'] == true,
      canApprove: j['can_approve'] == true,
      requestCode: (req['request_code'] as String?) ?? '',
      deviceId: (req['device_id'] as String?) ?? (j['device_id'] as String?) ?? '',
      short: (req['short'] as String?) ?? (j['short'] as String?) ?? '',
      digits: (req['digits'] as String?) ?? (j['digits'] as String?) ?? '',
      state: (j['state'] as String?) ?? '',
      replaces: (req['replaces'] as String?) ?? '',
    );
  }
}
