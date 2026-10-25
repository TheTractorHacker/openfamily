import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/security_models.dart';
import 'package:openfamily/services/api_client.dart';
import 'package:openfamily/services/auth_service.dart';
import 'package:openfamily/services/otpauth_launcher.dart';
import 'package:openfamily/services/security_format.dart';

void main() {
  test('formatSecret groups by four', () {
    expect(formatSecret('JBSWY3DPEHPK3PXP'), 'JBSW Y3DP EHPK 3PXP');
  });

  test('code helpers', () {
    expect(normalizeCode(' 123 456 '), '123456');
    expect(isTotpShape('123 456'), isTrue);
    expect(isTotpShape('ABCDE-FGHJK'), isFalse);
  });

  test('error messages: offline, throttled, server, generic', () {
    expect(securityErrorMessage(const ApiException(0, 'x')),
        contains('offline'));
    expect(securityErrorMessage(const ApiException(429, 'x')),
        contains('Too many'));
    expect(securityErrorMessage(const ApiException(503, 'x')),
        contains('server'));
    expect(securityErrorMessage(const ApiException(400, 'password is incorrect')),
        'password is incorrect');
    expect(securityErrorMessage(StateError('boom')), contains('Something'));
  });

  test('password validation', () {
    expect(validateNewPassword('short', 'short'), isNotNull);
    expect(validateNewPassword('longenough', 'different'), isNotNull);
    expect(validateNewPassword('longenough', 'longenough'), isNull);
  });

  test('relativeTime and user agent', () {
    final DateTime now = DateTime(2026, 1, 1, 12);
    expect(relativeTime(now.subtract(const Duration(minutes: 5)), now: now),
        '5 min ago');
    expect(relativeTime(null), 'unknown');
    expect(describeUserAgent('Dart/3.4 (dart:io) Android'),
        'OpenFamily app on Android');
    expect(describeUserAgent(''), 'Unknown device');
  });

  test('models parse', () {
    final AccountInfo a = AccountInfo.fromJson(
        {'id': '1', 'email': 'e', 'role': 'admin', 'totp_enabled': true});
    expect(a.totpEnabled && a.isFamilyAdmin, isTrue);
    final SessionInfo s = SessionInfo.fromJson({
      'id': 's',
      'last_used_at': '2026-01-01T00:00:00Z',
      'user_agent': 'ua',
    });
    expect(s.lastUsedAt, isNotNull);
    expect(s.createdAt, isNull);
    final ResetCodeResult r = ResetCodeResult.fromJson(
        {'code': 'X', 'expires_at': '2026-01-01T00:00:00Z', 'sms_sent': true});
    expect(r.smsSent, isTrue);
  });

  test('only otpauth totp URIs are launchable', () {
    expect(OtpauthLauncher.isValidUri('otpauth://totp/A?secret=X'), isTrue);
    expect(OtpauthLauncher.isValidUri('https://evil.example'), isFalse);
    expect(OtpauthLauncher.isValidUri('otpauth://hotp/A'), isFalse);
  });

  test('export completeness marker', () {
    expect(ApiClient.isCompleteExport('{"a":[],"complete":true}\n'), isTrue);
    expect(ApiClient.isCompleteExport('{"a":[1,2,'), isFalse);
  });

  test('duplicate-registration message never claims the email is taken', () {
    final String m = AccountCreatedException.neutralMessage.toLowerCase();
    expect(m, isNot(contains('already registered')));
    expect(m, isNot(contains('taken')));
    expect(m, contains('try signing in'));
  });
}
