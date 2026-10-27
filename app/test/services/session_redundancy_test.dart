// Production incident: the app sent an OLD refresh token after newer ones had
// been saved, the server answered 401 and the whole session was cleared. The
// session now lives in two independent stores (newest `iat` wins), a rejected
// stale token never ends a session a newer token can continue, and saved
// credentials silently replace a dead session.
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openfamily/services/api_client.dart';
import 'package:openfamily/services/server_config.dart';
import 'package:openfamily/services/session_diary.dart';
import 'package:openfamily/services/session_gate.dart';
import 'package:openfamily/services/token_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

String jwt({required int iat, required int exp, String tag = ''}) {
  String enc(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  return '${enc(<String, dynamic>{'alg': 'HS256'})}.'
      '${enc(<String, dynamic>{'iat': iat, 'exp': exp, 'tag': tag})}.sig';
}

final String staleRefresh = jwt(iat: 1000, exp: 9999999999, tag: 'stale');
final String newRefresh = jwt(iat: 2000, exp: 9999999999, tag: 'new');
final String expiredAccess = jwt(iat: 1000, exp: 1500);
const String pw = 'hunter2-secret-password';

http.Response _json(Object body, int status) => http.Response(
    jsonEncode(body), status,
    headers: <String, String>{'content-type': 'application/json'});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> seed(Map<String, String> values) async {
    FlutterSecureStorage.setMockInitialValues(values);
    SharedPreferences.setMockInitialValues(
        <String, Object>{'wb_api_base_url': 'https://example.test'});
    await ServerConfig.instance.load();
    ApiClient.invalidateConfig();
    ApiClient.markSessionActive();
    ApiClient.onSessionExpired = null;
    TokenStorage.resetForTest();
    SessionDiary.instance.resetForTest();
  }

  Map<String, String> bothStores({String? a, String? b}) => <String, String>{
        if (a != null) 'access_token': expiredAccess,
        if (a != null) 'refresh_token': a,
        if (b != null) 'session_b_access': expiredAccess,
        if (b != null) 'session_b_refresh': b,
      };

  /// Server that accepts only [valid] refresh tokens and logs in the saved
  /// credentials (unless [loginStatus] says otherwise).
  MockClient server({
    Set<String> valid = const <String>{},
    int refreshStatus = 401,
    int loginStatus = 200,
    String loginError = 'invalid credentials',
    List<String>? calls,
    bool offline = false,
  }) {
    return MockClient((http.Request r) async {
      if (offline) throw http.ClientException('offline');
      if (r.url.path == '/auth/refresh') {
        final String token =
            (jsonDecode(r.body) as Map<String, dynamic>)['refresh_token']
                as String;
        calls?.add('refresh:$token');
        if (valid.contains(token)) {
          return _json(<String, String>{
            'access_token': 'fresh.access.token',
            'refresh_token': jwt(iat: 3000, exp: 9999999999, tag: 'rot'),
          }, 200);
        }
        return _json(<String, String>{'error': 'x'}, refreshStatus);
      }
      if (r.url.path == '/auth/login') {
        calls?.add('login');
        if (loginStatus == 200) {
          return _json(<String, String>{
            'access_token': 'login.access.token',
            'refresh_token': jwt(iat: 4000, exp: 9999999999, tag: 'login'),
          }, 200);
        }
        return _json(<String, String>{'error': loginError}, loginStatus);
      }
      return _json(<String, String>{'error': 'expired'}, 401);
    });
  }

  test('stale token in store A, newer in store B: the newer one is used',
      () async {
    await seed(bothStores(a: staleRefresh, b: newRefresh));
    expect(await TokenStorage.readRefreshToken(), newRefresh);
    expect(await TokenStorage.refreshCandidates(),
        <String>[newRefresh, staleRefresh]);
    // And the other way round.
    await seed(bothStores(a: newRefresh, b: staleRefresh));
    expect(await TokenStorage.readRefreshToken(), newRefresh);
  });

  test('saveTokens writes both stores', () async {
    await seed(<String, String>{});
    await TokenStorage.saveTokens(access: 'a.b.c', refresh: newRefresh);
    TokenStorage.resetForTest(); // force real reads, not the memory copy
    final List<StoredSession> all = await TokenStorage.readAllStores();
    expect(all.map((StoredSession s) => s.source), <String>['A', 'B']);
    expect(all.every((StoredSession s) => s.refresh == newRefresh), isTrue);
  });

  test('a rejected stale token does not end the session when a newer works',
      () async {
    await seed(bothStores(a: staleRefresh, b: newRefresh));
    final List<String> calls = <String>[];
    bool expired = false;
    ApiClient.onSessionExpired = () => expired = true;
    final SessionGateResult r = await http.runWithClient(
        ApiClient.checkSession, () => server(valid: {newRefresh}, calls: calls));
    expect(r, SessionGateResult.valid);
    expect(expired, isFalse);
    // Newest tried first; the stale one is never replayed.
    expect(calls.first, 'refresh:$newRefresh');
    expect(calls, isNot(contains('refresh:$staleRefresh')));
  });

  test('stale token first on the wire is retried with the other store',
      () async {
    // Same iat on both would be a tie; make the stale one look newer by
    // giving it no iat at all on the "newer" side to force the fallback path.
    const String noIatNew = 'opaque-new-token';
    await seed(<String, String>{
      'access_token': expiredAccess,
      'refresh_token': staleRefresh,
      'session_b_access': expiredAccess,
      'session_b_refresh': noIatNew,
    });
    final List<String> calls = <String>[];
    await http.runWithClient(() async {
      await expectLater(
          ApiClient.get('/family'), throwsA(isA<ApiException>()));
    }, () => server(valid: {noIatNew}, calls: calls));
    expect(calls.take(2), <String>['refresh:$staleRefresh', 'refresh:$noIatNew']);
    expect(await TokenStorage.hasStoredSession(), isTrue);
  });

  test('a token the server rejected is not retried', () async {
    await seed(bothStores(a: staleRefresh));
    final List<String> calls = <String>[];
    await http.runWithClient(() async {
      for (int i = 0; i < 2; i++) {
        await ApiClient.checkSession();
      }
    }, () => server(calls: calls));
    expect(calls.where((String c) => c.startsWith('refresh:')).length, 1);
  });

  test('all rejected + saved credentials: silent re-login replaces tokens',
      () async {
    await seed(bothStores(a: staleRefresh, b: staleRefresh));
    await TokenStorage.saveCredentials(email: 'a@b.test', password: pw);
    final List<String> calls = <String>[];
    final SessionGateResult r = await http.runWithClient(
        ApiClient.checkSession, () => server(calls: calls));
    expect(r, SessionGateResult.valid);
    expect(calls, contains('login'));
    expect(await TokenStorage.readAccessToken(), 'login.access.token');
    expect(jwtIssuedAtOf((await TokenStorage.readRefreshToken())!)!
        .millisecondsSinceEpoch, 4000000);
  });

  test('silent re-login also works through a normal API call', () async {
    await seed(bothStores(a: staleRefresh));
    await TokenStorage.saveCredentials(email: 'a@b.test', password: pw);
    bool expired = false;
    ApiClient.onSessionExpired = () => expired = true;
    await http.runWithClient(() async {
      // Retried request still 401s from the mock; what matters is no logout.
      await expectLater(ApiClient.get('/family'), throwsA(isA<ApiException>()));
    }, () => server());
    expect(expired, isFalse);
    expect(await TokenStorage.readAccessToken(), 'login.access.token');
  });

  test('all rejected + no credentials: session cleared', () async {
    await seed(bothStores(a: staleRefresh, b: newRefresh));
    final SessionGateResult r =
        await http.runWithClient(ApiClient.checkSession, () => server());
    expect(r, SessionGateResult.expired);
    await seed(bothStores(a: staleRefresh, b: newRefresh));
    bool expired = false;
    ApiClient.onSessionExpired = () => expired = true;
    await http.runWithClient(() async {
      await expectLater(
          ApiClient.get('/family'), throwsA(isA<SessionExpiredException>()));
    }, () => server());
    expect(expired, isTrue);
    expect(await TokenStorage.hasStoredSession(), isFalse);
  });

  test('TOTP required on re-login: not logged in, saved password dropped',
      () async {
    await seed(bothStores(a: staleRefresh));
    await TokenStorage.saveCredentials(email: 'a@b.test', password: pw);
    final SessionGateResult r = await http.runWithClient(
        ApiClient.checkSession,
        () => server(loginStatus: 401, loginError: 'invalid totp code'));
    expect(r, SessionGateResult.expired);
    expect(await TokenStorage.readCredentials(), isNull);
  });

  test('invalid credentials on re-login: saved password dropped', () async {
    await seed(bothStores(a: staleRefresh));
    await TokenStorage.saveCredentials(email: 'a@b.test', password: pw);
    final SessionGateResult r = await http.runWithClient(
        ApiClient.checkSession, () => server(loginStatus: 401));
    expect(r, SessionGateResult.expired);
    expect(await TokenStorage.readCredentials(), isNull);
  });

  test('saved credentials respect the toggle', () async {
    await seed(<String, String>{});
    expect(await TokenStorage.keepSignedInEnabled(), isTrue);
    await TokenStorage.saveCredentials(email: 'a@b.test', password: pw);
    expect(await TokenStorage.readCredentials(), isNotNull);
    await TokenStorage.setKeepSignedIn(false);
    expect(await TokenStorage.readCredentials(), isNull);
    await TokenStorage.saveCredentials(email: 'a@b.test', password: pw);
    expect(await TokenStorage.readCredentials(), isNull);
  });

  for (final int status in <int>[500, 502, 503, 429]) {
    test('gate: refresh answered $status keeps the session', () async {
      await seed(bothStores(a: staleRefresh, b: newRefresh));
      await TokenStorage.saveCredentials(email: 'a@b.test', password: pw);
      final SessionGateResult r = await http.runWithClient(
          ApiClient.checkSession, () => server(refreshStatus: status));
      expect(r, SessionGateResult.unreachable);
      expect(await TokenStorage.hasStoredSession(), isTrue);
      expect(await TokenStorage.readCredentials(), isNotNull);
    });
  }

  test('gate: offline keeps the session and the saved login', () async {
    await seed(bothStores(a: staleRefresh, b: newRefresh));
    await TokenStorage.saveCredentials(email: 'a@b.test', password: pw);
    final SessionGateResult r = await http.runWithClient(
        ApiClient.checkSession, () => server(offline: true));
    expect(r, SessionGateResult.unreachable);
    expect(await TokenStorage.hasStoredSession(), isTrue);
    expect(await TokenStorage.readCredentials(), isNotNull);
  });

  test('silent re-login hitting a 5xx keeps everything', () async {
    await seed(bothStores(a: staleRefresh));
    await TokenStorage.saveCredentials(email: 'a@b.test', password: pw);
    final SessionGateResult r = await http.runWithClient(
        ApiClient.checkSession, () => server(loginStatus: 503));
    expect(r, SessionGateResult.unreachable);
    expect(await TokenStorage.readCredentials(), isNotNull);
  });

  test('stores wiped but credentials saved: gate re-logs in', () async {
    await seed(<String, String>{});
    await TokenStorage.saveCredentials(email: 'a@b.test', password: pw);
    final SessionGateResult r =
        await http.runWithClient(ApiClient.checkSession, () => server());
    expect(r, SessionGateResult.valid);
  });

  test('clear() empties all three stores', () async {
    await seed(bothStores(a: staleRefresh, b: newRefresh));
    await TokenStorage.saveCredentials(email: 'a@b.test', password: pw);
    await TokenStorage.clear(reason: 'test');
    expect(await TokenStorage.readAllStores(), isEmpty);
    expect(await TokenStorage.readCredentials(), isNull);
    expect(await TokenStorage.hasStoredSession(), isFalse);
  });

  test('changing the password drops the saved one', () async {
    await seed(bothStores(a: newRefresh));
    await TokenStorage.saveCredentials(email: 'a@b.test', password: pw);
    final http.Client c = MockClient((http.Request r) async =>
        _json(<String, String>{'access_token': 'n.a.t', 'refresh_token': 'n.r.t'}, 200));
    await http.runWithClient(
        () => ApiClient.changePassword(currentPassword: pw, newPassword: 'x'),
        () => c);
    expect(await TokenStorage.readCredentials(), isNull);
  });

  test('the diary records events but never tokens or passwords', () async {
    await seed(bothStores(a: staleRefresh, b: newRefresh));
    await TokenStorage.saveCredentials(email: 'a@b.test', password: pw);
    await http.runWithClient(
        ApiClient.checkSession, () => server(valid: {newRefresh}));
    await TokenStorage.clear(reason: 'test');
    final String text = await SessionDiary.instance.render();
    expect(text, contains('gate_refresh'));
    expect(text, contains('clear reason=test'));
    for (final String secret in <String>[
      staleRefresh,
      newRefresh,
      expiredAccess,
      pw,
      'a@b.test',
      'fresh.access.token',
    ]) {
      expect(text, isNot(contains(secret)));
    }
    expect(text, contains(SessionDiary.shortHash(newRefresh)));
  });

  test('the diary keeps only the last 50 events', () async {
    await seed(<String, String>{});
    for (int i = 0; i < 70; i++) {
      SessionDiary.instance.record('e', '$i');
    }
    final List<String> ev = await SessionDiary.instance.events();
    expect(ev.length, SessionDiary.maxEvents);
    expect(ev.last, endsWith(' 69'));
  });
}
