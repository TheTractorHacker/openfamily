// A server restart during an app update must not sign the user out. Only a
// definitive rejection of the refresh token may clear the stored session.
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openfamily/services/api_client.dart';
import 'package:openfamily/services/server_config.dart';
import 'package:openfamily/services/token_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Client _client(int refreshStatus, {bool refreshThrows = false}) =>
    MockClient((http.Request r) async {
      if (r.url.path == '/auth/refresh') {
        if (refreshThrows) throw http.ClientException('connection reset');
        return http.Response(
          refreshStatus == 200
              ? jsonEncode(<String, String>{
                  'access_token': 'new.access.token',
                  'refresh_token': 'new.refresh.token',
                })
              : '{"error":"x"}',
          refreshStatus,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }
      // Every other call: the access token is expired.
      final String? auth = r.headers['Authorization'];
      if (auth == 'Bearer new.access.token') {
        return http.Response('{"ok":true}', 200,
            headers: <String, String>{'content-type': 'application/json'});
      }
      return http.Response('{"error":"expired"}', 401,
          headers: <String, String>{'content-type': 'application/json'});
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    TokenStorage.resetForTest();
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'access_token_v2': 'old.access.token',
      'refresh_token_v2': 'old.refresh.token',
    });
    SharedPreferences.setMockInitialValues(
        <String, Object>{'wb_api_base_url': 'https://example.test'});
    await ServerConfig.instance.load();
    ApiClient.invalidateConfig();
    ApiClient.markSessionActive();
    ApiClient.onSessionExpired = null;
  });

  for (final int status in <int>[500, 502, 503, 504, 429]) {
    test('refresh answered $status keeps the session', () async {
      bool expired = false;
      ApiClient.onSessionExpired = () => expired = true;
      await http.runWithClient(() async {
        await expectLater(
          ApiClient.get('/family'),
          throwsA(isA<ApiException>()
              .having((ApiException e) => e.status, 'status', 0)),
        );
      }, () => _client(status));
      expect(expired, isFalse);
      expect(await TokenStorage.readRefreshToken(), 'old.refresh.token');
    });
  }

  test('a 401 right after a successful refresh keeps the session', () async {
    bool expired = false;
    ApiClient.onSessionExpired = () => expired = true;
    final http.Client always401 = MockClient((http.Request r) async {
      if (r.url.path == '/auth/refresh') {
        return http.Response(
          jsonEncode(<String, String>{
            'access_token': 'new.access.token',
            'refresh_token': 'new.refresh.token',
          }),
          200,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }
      return http.Response('{"error":"x"}', 401,
          headers: <String, String>{'content-type': 'application/json'});
    });
    await http.runWithClient(() async {
      await expectLater(ApiClient.get('/family'), throwsA(isA<ApiException>()));
    }, () => always401);
    expect(expired, isFalse);
    expect(await TokenStorage.readRefreshToken(), 'new.refresh.token');
  });

  test('refresh that cannot connect keeps the session', () async {
    bool expired = false;
    ApiClient.onSessionExpired = () => expired = true;
    await http.runWithClient(() async {
      await expectLater(
        ApiClient.get('/family'),
        throwsA(isA<ApiException>()),
      );
    }, () => _client(0, refreshThrows: true));
    expect(expired, isFalse);
    expect(await TokenStorage.readRefreshToken(), 'old.refresh.token');
  });

  for (final int status in <int>[400, 401, 403]) {
    test('refresh rejected with $status ends the session', () async {
      bool expired = false;
      ApiClient.onSessionExpired = () => expired = true;
      await http.runWithClient(() async {
        await expectLater(
          ApiClient.get('/family'),
          throwsA(isA<SessionExpiredException>()),
        );
      }, () => _client(status));
      expect(expired, isTrue);
      expect(await TokenStorage.readRefreshToken(), isNull);
    });
  }

  test('a working refresh retries the request with the new token', () async {
    await http.runWithClient(() async {
      await ApiClient.get('/family');
    }, () => _client(200));
    expect(await TokenStorage.readRefreshToken(), 'new.refresh.token');
  });
}
