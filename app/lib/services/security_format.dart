import '../services/api_client.dart';

/// Pure helpers shared by the security screens.

/// Groups a base32 TOTP secret in blocks of four for reading aloud / typing.
String formatSecret(String secret) {
  final String s = secret.replaceAll(RegExp(r'\s+'), '');
  final StringBuffer b = StringBuffer();
  for (int i = 0; i < s.length; i++) {
    if (i > 0 && i % 4 == 0) b.write(' ');
    b.write(s[i]);
  }
  return b.toString();
}

/// Strips spaces so a pasted "123 456" code is accepted.
String normalizeCode(String raw) => raw.replaceAll(RegExp(r'\s+'), '');

/// Whether [code] has the shape of an authenticator code (6 digits).
bool isTotpShape(String code) => RegExp(r'^\d{6}$').hasMatch(normalizeCode(code));

/// A locally detected failure with user-facing [message].
class SecurityException implements Exception {
  const SecurityException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Converts any failure into short, user-facing copy.
String securityErrorMessage(Object error) {
  if (error is ApiException) {
    if (error.status == 0) {
      return 'You appear to be offline or the server is unreachable. '
          'Check your connection and try again.';
    }
    if (error.status == 429) {
      return 'Too many attempts. Wait a few minutes and try again.';
    }
    if (error.status >= 500) {
      return 'The server had a problem. Try again shortly.';
    }
    return error.message;
  }
  if (error is SecurityException) return error.message;
  return 'Something went wrong. Please try again.';
}

/// Whether the failure means the device could not reach the server.
bool isOfflineError(Object error) => error is ApiException && error.status == 0;

/// Minimum password length enforced client-side (server enforces its own).
const int minPasswordLength = 8;

String? validateNewPassword(String next, String confirm) {
  if (next.length < minPasswordLength) {
    return 'New password must be at least $minPasswordLength characters.';
  }
  if (next != confirm) return 'New passwords do not match.';
  return null;
}

/// Human "5 minutes ago" style text without extra packages.
String relativeTime(DateTime? t, {DateTime? now}) {
  if (t == null) return 'unknown';
  final Duration d = (now ?? DateTime.now()).difference(t);
  if (d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}

/// Short device label from a raw User-Agent string.
String describeUserAgent(String ua) {
  final String u = ua.toLowerCase();
  if (u.isEmpty) return 'Unknown device';
  final String os = u.contains('android')
      ? 'Android'
      : (u.contains('iphone') || u.contains('ipad') || u.contains('ios'))
          ? 'iOS'
          : u.contains('windows')
              ? 'Windows'
              : u.contains('mac')
                  ? 'Mac'
                  : u.contains('linux')
                      ? 'Linux'
                      : '';
  final String app = u.contains('dart')
      ? 'OpenFamily app'
      : u.contains('firefox')
          ? 'Firefox'
          : u.contains('edg')
              ? 'Edge'
              : u.contains('chrome')
                  ? 'Chrome'
                  : u.contains('safari')
                      ? 'Safari'
                      : '';
  final String label = <String>[app, os].where((e) => e.isNotEmpty).join(' on ');
  return label.isEmpty ? ua : label;
}
