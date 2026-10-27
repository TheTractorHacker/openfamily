// The session is kept in two stores and a stale or stuck copy must never
// shadow a fresh login.
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/server_config.dart';
import 'package:openfamily/services/token_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _jwt(int expSeconds) {
  String enc(Map<String, Object?> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  return '${enc(<String, Object?>{'alg': 'none'})}.'
      '${enc(<String, Object?>{'exp': expSeconds, 'iat': expSeconds - 1000})}.sig';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    TokenStorage.resetForTest();
    SharedPreferences.setMockInitialValues(
        <String, Object>{'wb_api_base_url': 'https://example.test'});
    await ServerConfig.instance.load();
  });

  test('save then read round-trips and drops the legacy entries', () async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'access_token': 'old.access',
      'refresh_token': 'old.refresh',
    });
    final String access = _jwt(2000000000);
    final String refresh = _jwt(2100000000);
    await TokenStorage.saveTokens(access: access, refresh: refresh);
    expect(await TokenStorage.readAccessToken(), access);
    expect(await TokenStorage.readRefreshToken(), refresh);
    const FlutterSecureStorage s = FlutterSecureStorage();
    expect(await s.read(key: 'refresh_token'), isNull);
    expect(await s.read(key: 'access_token'), isNull);
  });

  test('a legacy-only session still reads (upgrade keeps users signed in)',
      () async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'access_token': 'legacy.access',
      'refresh_token': 'legacy.refresh',
    });
    expect(await TokenStorage.readRefreshToken(), 'legacy.refresh');
    expect(await TokenStorage.hasStoredSession(), isTrue);
  });

  test('a fresh v2 pair beats a stale legacy token', () async {
    final String fresh = _jwt(2100000000);
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'refresh_token': _jwt(1900000000),
      'refresh_token_v2': fresh,
    });
    expect(await TokenStorage.readRefreshToken(), fresh);
  });

  test('the newest copy wins when the two stores disagree', () async {
    final String stale = _jwt(1900000000);
    final String fresh = _jwt(2100000000);
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'refresh_token_v2': stale,
      'session_b_refresh': fresh,
    });
    expect(await TokenStorage.readRefreshToken(), fresh);
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'refresh_token_v2': fresh,
      'session_b_refresh': stale,
    });
    expect(await TokenStorage.readRefreshToken(), fresh);
  });

  test('clear removes every copy', () async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'access_token': 'a',
      'refresh_token': 'r',
      'access_token_v2': 'a2',
      'refresh_token_v2': 'r2',
      'session_b_access': 'ba',
      'session_b_refresh': 'br',
    });
    await TokenStorage.clear();
    expect(await TokenStorage.readAccessToken(), isNull);
    expect(await TokenStorage.readRefreshToken(), isNull);
    expect(await TokenStorage.hasStoredSession(), isFalse);
  });
}
