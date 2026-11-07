import '../services/app_compat.dart';

/// A circle the signed-in user belongs to, from `GET /circles`.
class Circle {
  const Circle({
    required this.id,
    required this.name,
    required this.role,
    required this.sharingEnabled,
    required this.memberCount,
    this.icon,
    this.isPrimary = false,
    this.expiresAt,
    this.e2eeMode = 'off',
    this.e2eeEpoch = 0,
    this.e2eeServerMember = false,
    this.serverAssist = false,
    this.memberOptOut = 'allowed',
    this.myLaneServer = false,
    this.needsNewerApp = false,
  });

  final String id;
  final String name;

  /// Free-form short icon string chosen at creation (usually one emoji).
  final String? icon;

  /// The caller's role in this circle: "admin" or "member".
  final String role;

  /// Whether the caller currently shares their location with this circle.
  final bool sharingEnabled;
  final int memberCount;

  /// True for the circle the legacy single-family endpoints operate on.
  final bool isPrimary;

  /// When a temporary circle stops sharing (UTC); null for a permanent one.
  final DateTime? expiresAt;

  /// "off" or "private" (end-to-end encrypted, docs/design/E2EE.md).
  final String e2eeMode;
  final int e2eeEpoch;

  /// Private AND an approved, consented OpenFamily server device can read it
  /// (trusted-server mode): the server, not only the members, can see positions.
  final bool e2eeServerMember;

  /// The server's CLAIM that the circle admin turned server assistance on (the phone
  /// verifies the signed policy before relying on it). 'allowed' | 'required_server'.
  final bool serverAssist;
  final String memberOptOut;

  /// The server's claim that the caller's data is processed by the server.
  final bool myLaneServer;
  /// The server says this app is too old to open the circle (its
  /// `min_app_version` is newer than the app, or it uses a mode this app does
  /// not know). The UI then asks for an update instead of showing an empty map.
  final bool needsNewerApp;

  /// True for a Private (end-to-end encrypted) circle.
  bool get isPrivate => e2eeMode == 'private';

  bool get isAdmin => role == 'admin';
  bool get isTemporary => expiresAt != null;

  /// True once a temporary circle's expiry has passed at [now].
  bool isExpiredAt(DateTime now) =>
      expiresAt != null && !expiresAt!.isAfter(now);

  factory Circle.fromJson(Map<String, dynamic> json) {
    final dynamic icon = json['icon'];
    return Circle(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? 'Circle',
      icon: icon is String && icon.trim().isNotEmpty ? icon : null,
      role: json['role'] as String? ?? 'member',
      sharingEnabled: json['sharing_enabled'] != false,
      memberCount: json['member_count'] is num ? (json['member_count'] as num).toInt() : 0,
      isPrimary: json['is_primary'] == true,
      expiresAt: json['expires_at'] is String
          ? DateTime.tryParse(json['expires_at'] as String)?.toUtc()
          : null,
      e2eeMode: json['e2ee_mode'] == 'private' ? 'private' : 'off',
      needsNewerApp: json['update_required'] == true ||
          AppCompat.requiresNewer(json['min_app_version'] as String?) ||
          // A mode value this app has never heard of must not be shown as a
          // plain circle with nobody sharing.
          (json['e2ee_mode'] is String &&
              json['e2ee_mode'] != 'off' &&
              json['e2ee_mode'] != 'private'),
      e2eeEpoch: json['e2ee_epoch'] is num ? (json['e2ee_epoch'] as num).toInt() : 0,
      e2eeServerMember: json['e2ee_mode'] == 'private' && json['e2ee_server_member'] == true,
      serverAssist: json['e2ee_mode'] == 'private' && json['server_assist'] == true,
      memberOptOut: json['member_opt_out'] == 'required_server' ? 'required_server' : 'allowed',
      myLaneServer: json['e2ee_mode'] == 'private' && json['my_lane_server'] == true,
    );
  }

  Circle copyWith({
    String? name,
    String? icon,
    String? role,
    bool? sharingEnabled,
    int? memberCount,
    DateTime? expiresAt,
    String? e2eeMode,
    int? e2eeEpoch,
    bool? e2eeServerMember,
    bool? serverAssist,
    String? memberOptOut,
    bool? myLaneServer,
    bool? needsNewerApp,
  }) {
    return Circle(
      id: id,
      name: name ?? this.name,
      icon: icon ?? this.icon,
      role: role ?? this.role,
      sharingEnabled: sharingEnabled ?? this.sharingEnabled,
      memberCount: memberCount ?? this.memberCount,
      isPrimary: isPrimary,
      expiresAt: expiresAt ?? this.expiresAt,
      e2eeMode: e2eeMode ?? this.e2eeMode,
      e2eeEpoch: e2eeEpoch ?? this.e2eeEpoch,
      e2eeServerMember: e2eeServerMember ?? this.e2eeServerMember,
      serverAssist: serverAssist ?? this.serverAssist,
      memberOptOut: memberOptOut ?? this.memberOptOut,
      myLaneServer: myLaneServer ?? this.myLaneServer,
      needsNewerApp: needsNewerApp ?? this.needsNewerApp,
    );
  }
}

/// One row of `GET /circles/{id}/members` (never carries a location).
class CircleMember {
  const CircleMember({
    required this.userId,
    required this.name,
    required this.role,
    required this.sharingEnabled,
  });

  final String userId;
  final String name;
  final String role;
  final bool sharingEnabled;

  bool get isAdmin => role == 'admin';

  factory CircleMember.fromJson(Map<String, dynamic> json) {
    return CircleMember(
      userId: json['user_id'] as String? ?? '',
      name: json['name'] as String? ?? 'Member',
      role: json['role'] as String? ?? 'member',
      sharingEnabled: json['sharing_enabled'] != false,
    );
  }
}

/// An invitation code for a circle (admin only).
class CircleInvite {
  const CircleInvite({
    required this.id,
    required this.code,
    required this.role,
    required this.maxUses,
    required this.uses,
    this.expiresAt,
  });

  final String id;
  final String code;
  final String role;
  final int maxUses;
  final int uses;
  final DateTime? expiresAt;

  factory CircleInvite.fromJson(Map<String, dynamic> json) {
    final dynamic exp = json['expires_at'];
    return CircleInvite(
      id: json['id'] as String? ?? '',
      code: json['code'] as String? ?? '',
      role: json['role'] as String? ?? 'member',
      maxUses: (json['max_uses'] as num?)?.toInt() ?? 0,
      uses: (json['uses'] as num?)?.toInt() ?? 0,
      expiresAt: exp is String ? DateTime.tryParse(exp)?.toUtc() : null,
    );
  }
}
