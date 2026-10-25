/// Data types for the account-security screens.

class AccountInfo {
  const AccountInfo({
    required this.id,
    required this.email,
    required this.role,
    required this.totpEnabled,
  });

  final String id;
  final String email;
  final String role;
  final bool totpEnabled;

  bool get isFamilyAdmin => role == 'admin';

  factory AccountInfo.fromJson(Map<String, dynamic> json) => AccountInfo(
        id: json['id'] as String? ?? '',
        email: json['email'] as String? ?? '',
        role: json['role'] as String? ?? 'member',
        totpEnabled: json['totp_enabled'] == true,
      );
}

/// Result of `POST /auth/totp/setup`.
class TotpSetup {
  const TotpSetup({required this.secret, required this.otpauthUri});

  final String secret;
  final String otpauthUri;

  factory TotpSetup.fromJson(Map<String, dynamic> json) => TotpSetup(
        secret: json['secret'] as String? ?? '',
        otpauthUri: json['otpauth_uri'] as String? ?? '',
      );
}

/// One signed-in session from `GET /auth/sessions`.
class SessionInfo {
  const SessionInfo({
    required this.id,
    required this.createdAt,
    required this.lastUsedAt,
    required this.expiresAt,
    required this.userAgent,
  });

  final String id;
  final DateTime? createdAt;
  final DateTime? lastUsedAt;
  final DateTime? expiresAt;
  final String userAgent;

  factory SessionInfo.fromJson(Map<String, dynamic> json) {
    DateTime? t(String k) {
      final dynamic v = json[k];
      return v is String ? DateTime.tryParse(v)?.toLocal() : null;
    }

    return SessionInfo(
      id: json['id'] as String? ?? '',
      createdAt: t('created_at'),
      lastUsedAt: t('last_used_at'),
      expiresAt: t('expires_at'),
      userAgent: json['user_agent'] as String? ?? '',
    );
  }
}

/// Result of issuing a password reset code for a member.
class ResetCodeResult {
  const ResetCodeResult({
    required this.code,
    required this.expiresAt,
    required this.smsSent,
    this.smsNote,
  });

  final String code;
  final DateTime? expiresAt;
  final bool smsSent;
  final String? smsNote;

  factory ResetCodeResult.fromJson(Map<String, dynamic> json) {
    final dynamic exp = json['expires_at'];
    return ResetCodeResult(
      code: json['code'] as String? ?? '',
      expiresAt: exp is String ? DateTime.tryParse(exp)?.toLocal() : null,
      smsSent: json['sms_sent'] == true,
      smsNote: json['sms_note'] as String?,
    );
  }
}

/// A family member the caller may issue a reset code for.
class ResettableMember {
  const ResettableMember({
    required this.id,
    required this.name,
    required this.role,
  });

  final String id;
  final String name;
  final String role;
}
