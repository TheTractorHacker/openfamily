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

  bool get isAdmin => role == 'admin';

  factory Circle.fromJson(Map<String, dynamic> json) {
    final dynamic icon = json['icon'];
    return Circle(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? 'Circle',
      icon: icon is String && icon.trim().isNotEmpty ? icon : null,
      role: json['role'] as String? ?? 'member',
      sharingEnabled: json['sharing_enabled'] != false,
      memberCount: (json['member_count'] as num?)?.toInt() ?? 0,
      isPrimary: json['is_primary'] == true,
    );
  }

  Circle copyWith({
    String? name,
    String? icon,
    String? role,
    bool? sharingEnabled,
    int? memberCount,
  }) {
    return Circle(
      id: id,
      name: name ?? this.name,
      icon: icon ?? this.icon,
      role: role ?? this.role,
      sharingEnabled: sharingEnabled ?? this.sharingEnabled,
      memberCount: memberCount ?? this.memberCount,
      isPrimary: isPrimary,
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
