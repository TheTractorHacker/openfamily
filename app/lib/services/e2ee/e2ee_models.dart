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
        userName: j['user_name'] as String?,
      );
}

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

class CircleE2eeState {
  const CircleE2eeState({
    required this.circleId,
    required this.mode,
    required this.epoch,
    required this.rekeyRequired,
    required this.members,
  });
  final String circleId;
  final String mode;
  final int epoch;
  final bool rekeyRequired;
  final List<CircleE2eeMember> members;

  bool get isPrivate => mode == 'private';

  Iterable<DeviceKey> get allDevices =>
      members.expand((CircleE2eeMember m) => m.devices);

  factory CircleE2eeState.fromJson(Map<String, dynamic> j) => CircleE2eeState(
        circleId: j['circle_id'] as String,
        mode: j['mode'] as String? ?? 'off',
        epoch: (j['epoch'] as num?)?.toInt() ?? 0,
        rekeyRequired: j['rekey_required'] == true,
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
  });
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
      );
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
