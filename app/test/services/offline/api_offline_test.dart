// What the API client does when the server is unreachable, times out or storms with 5xx.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openfamily/services/api_client.dart';
import 'package:openfamily/services/offline/offline_errors.dart';
import 'package:openfamily/services/offline/server_reachability.dart';
import 'package:openfamily/services/server_config.dart';
import 'package:openfamily/services/session_gate.dart';
import 'package:openfamily/services/token_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Not a type the http package wraps for us (a TLS failure on dart:io).
class HandshakeException implements Exception {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    TokenStorage.resetForTest();
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'access_token_v2': 'old.access',
      'refresh_token_v2': 'old.refresh',
    });
    SharedPreferences.setMockInitialValues(<String, Object>{'wb_api_base_url': 'https://example.test'});
    await ServerConfig.instance.load();
    ApiClient.invalidateConfig();
    ApiClient.markSessionActive();
    ApiClient.onSessionExpired = null;
  });

  group('every way a request can fail becomes an offline ApiException, never a crash or a sign-out', () {
    final Map<String, Object> failures = <String, Object>{
      'refused': http.ClientException('Connection refused'),
      'timeout': TimeoutException('slow'),
      'tls handshake': HandshakeException(),
      'state error from a half-open socket': StateError('Bad state: connection closed'),
    };
    failures.forEach((String name, Object error) {
      test(name, () async {
        bool expired = false;
        ApiClient.onSessionExpired = () => expired = true;
        await http.runWithClient(() async {
          await expectLater(
            ApiClient.get('/family/members'),
            throwsA(isA<ApiException>().having((ApiException e) => e.status, 'status', 0)),
          );
        }, () => MockClient((http.Request r) async => throw error));
        expect(expired, isFalse);
        expect(await TokenStorage.readRefreshToken(), 'old.refresh', reason: 'tokens stay');
        expect(isOfflineError(const ApiException(0, 'x')), isTrue);
      });
    });
  });

  test('an HTML 502 error page from the proxy is an error, not a JSON crash', () async {
    await http.runWithClient(() async {
      await expectLater(
        ApiClient.get('/family/members'),
        throwsA(isA<ApiException>().having((ApiException e) => e.status, 'status', 502)),
      );
    }, () => MockClient((http.Request r) async => http.Response('<html><h1>502 Bad Gateway</h1></html>', 502)));
  });

  test('a 200 with a broken body (half-written response, captive portal) counts as offline, so cached data is shown', () async {
    await http.runWithClient(() async {
      await expectLater(ApiClient.get('/family/members'),
          throwsA(isA<ApiException>().having((ApiException e) => e.status, 'status', 0)));
    }, () => MockClient((http.Request r) async => http.Response('{"truncated":', 200)));
  });

  test('token refresh failing on the network (access token expired) keeps the user signed in', () async {
    bool expired = false;
    ApiClient.onSessionExpired = () => expired = true;
    await http.runWithClient(() async {
      await expectLater(ApiClient.get('/family'), throwsA(isA<ApiException>().having((ApiException e) => e.status, 'status', 0)));
    }, () => MockClient((http.Request r) async {
          if (r.url.path == '/auth/refresh') throw http.ClientException('offline');
          return http.Response('{"error":"expired"}', 401);
        }));
    expect(expired, isFalse);
    expect(await TokenStorage.readRefreshToken(), 'old.refresh');
  });

  test('only an explicit refresh rejection (401) ends the session', () async {
    bool expired = false;
    ApiClient.onSessionExpired = () => expired = true;
    await http.runWithClient(() async {
      await expectLater(ApiClient.get('/family'), throwsA(isA<SessionExpiredException>()));
    }, () => MockClient((http.Request r) async => http.Response('{"error":"invalid"}', 401)));
    expect(expired, isTrue);
  });

  group('start-up never waits on a dead network', () {
    test('a refresh that hangs is cut after the limit and the session is presumed alive', () async {
      final Completer<SessionGateResult> never = Completer<SessionGateResult>();
      final SessionGateResult r = await checkSessionWithin(
        never.future,
        const Duration(milliseconds: 50),
        hasRefreshToken: () async => true,
      );
      expect(r, SessionGateResult.unreachable);
    });

    test('no stored token: it is the sign-in screen, not a fake session', () async {
      final SessionGateResult r = await checkSessionWithin(
        Completer<SessionGateResult>().future,
        const Duration(milliseconds: 50),
        hasRefreshToken: () async => false,
      );
      expect(r, SessionGateResult.none);
    });

    test('a fast answer passes through untouched, including a real rejection', () async {
      expect(
        await checkSessionWithin(Future<SessionGateResult>.value(SessionGateResult.expired), const Duration(seconds: 4),
            hasRefreshToken: () async => true),
        SessionGateResult.expired,
      );
    });
  });

  testWidgets('requests that fail feed the reachability probe; a 404 does not', (WidgetTester t) async {
    int probes = 0;
    final ServerReachability r = ServerReachability.instance;
    final Future<bool> Function() old = r.probe;
    r.probe = () async {
      probes++;
      return false;
    };
    await http.runWithClient(() async {
      await expectLater(ApiClient.get('/x'), throwsA(isA<ApiException>()));
      await t.pump(const Duration(seconds: 3));
    }, () => MockClient((http.Request req) async => http.Response(jsonEncode(<String, String>{'error': 'nope'}), 404)));
    expect(probes, 0);
    await http.runWithClient(() async {
      await expectLater(ApiClient.get('/x'), throwsA(isA<ApiException>()));
      await t.pump(const Duration(seconds: 3));
    }, () => MockClient((http.Request req) async => throw http.ClientException('refused')));
    expect(probes, 1);
    expect(r.unreachable, isTrue);
    r.probe = old;
    r.noteResponse(200);
  });

  test('healthz uses its own short timeout and needs no login', () async {
    String? auth;
    await http.runWithClient(() async {
      await ApiClient.healthz();
    }, () => MockClient((http.Request req) async {
          auth = req.headers['Authorization'];
          return http.Response('ok', 200);
        }));
    expect(auth, isNull);
    await http.runWithClient(() async {
      await expectLater(ApiClient.healthz(), throwsA(isA<ApiException>()));
    }, () => MockClient((http.Request req) async => http.Response('', 503)));
  });
}
