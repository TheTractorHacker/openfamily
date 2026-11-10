// "Keep me signed in, sign in automatically if needed": what it really does.
//
// The app saves the email and password in the Keystore at a password sign-in
// WITHOUT a two-factor code, and uses them only when every refresh token has
// been refused (ApiClient.silentRelogin posts email and password, never a
// code). So for an account with two-factor sign-in nothing is saved and the
// toggle cannot sign anyone in; a refused saved login is deleted and the
// person is asked to sign in.
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openfamily/screens/settings_screen.dart';
import 'package:openfamily/services/api_client.dart';
import 'package:openfamily/services/auth_service.dart';
import 'package:openfamily/services/server_config.dart';
import 'package:openfamily/services/session_diary.dart';
import 'package:openfamily/services/session_gate.dart';
import 'package:openfamily/services/token_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _jwt({required int iat, String sub = 'user-1', String tag = ''}) {
  String enc(Map<String, dynamic> m) => base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  return '${enc(<String, dynamic>{'alg': 'HS256'})}.'
      '${enc(<String, dynamic>{'iat': iat, 'exp': 9999999999, 'sub': sub, 'tag': tag})}.sig';
}

http.Response _json(Object body, int status) =>
    http.Response(jsonEncode(body), status, headers: <String, String>{'content-type': 'application/json'});

const String pw = 'correct horse battery';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Logging out stops the background locator (a native plugin).
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('app.yukams/locator_plugin'), (MethodCall c) async => null);

  Future<void> seed([Map<String, String> secure = const <String, String>{}]) async {
    FlutterSecureStorage.setMockInitialValues(Map<String, String>.of(secure));
    SharedPreferences.setMockInitialValues(<String, Object>{'wb_api_base_url': 'https://example.test'});
    await ServerConfig.instance.load();
    ApiClient.invalidateConfig();
    ApiClient.markSessionActive();
    ApiClient.onSessionExpired = null;
    TokenStorage.resetForTest();
    SessionDiary.instance.resetForTest();
  }

  /// A server for an account with ([twoFactor]) or without two-factor sign-in.
  /// A login without the code is refused (401, "invalid totp code") for a
  /// two-factor account, like backend/internal/handlers/auth.go.
  MockClient server({required bool twoFactor, List<String>? calls, bool refreshAlive = false}) =>
      MockClient((http.Request r) async {
        final Map<String, dynamic> body = r.body.isEmpty ? <String, dynamic>{} : jsonDecode(r.body) as Map<String, dynamic>;
        if (r.url.path == '/auth/login') {
          calls?.add('login${body.containsKey('totp_code') ? '+code' : ''}');
          if (twoFactor && !body.containsKey('totp_code')) return _json(<String, String>{'error': 'invalid totp code'}, 401);
          return _json(<String, String>{
            'access_token': _jwt(iat: 5000, tag: 'login-access'),
            'refresh_token': _jwt(iat: 5000, tag: 'login-refresh'),
          }, 200);
        }
        if (r.url.path == '/auth/refresh') {
          calls?.add('refresh');
          return _json(<String, String>{'error': 'invalid refresh'}, 401);
        }
        if (r.url.path.endsWith('/logout')) return _json(<String, String>{}, 200);
        return _json(<String, String>{'error': 'expired'}, 401);
      });

  group('what is saved at sign-in', () {
    test('a password sign-in saves the login, and the toggle reads "active"', () async {
      await seed();
      await http.runWithClient(() => AuthService.login(identifier: 'a@b.test', password: pw), () => server(twoFactor: false));
      final creds = await TokenStorage.readCredentials();
      expect(creds?.email, 'a@b.test');
      expect(creds?.password, pw);
      expect(await TokenStorage.keepSignedInStatus(), KeepSignedInStatus.active);
    });

    test('a two-factor sign-in saves nothing, deletes an older saved login, and the status says two-factor', () async {
      await seed();
      await TokenStorage.saveCredentials(email: 'a@b.test', password: 'old-password');
      expect(await TokenStorage.readCredentials(), isNotNull);
      await http.runWithClient(
          () => AuthService.login(identifier: 'a@b.test', password: pw, totpCode: '123456'), () => server(twoFactor: true));
      expect(await TokenStorage.readCredentials(), isNull);
      expect(await TokenStorage.keepSignedInStatus(), KeepSignedInStatus.twoFactor);
    });

    test('the two-factor account is refused without a code: TotpRequiredException, nothing saved', () async {
      await seed();
      await expectLater(
        http.runWithClient(() => AuthService.login(identifier: 'a@b.test', password: pw), () => server(twoFactor: true)),
        throwsA(isA<TotpRequiredException>()),
      );
      expect(await TokenStorage.readCredentials(), isNull);
    });

    test('with the switch off nothing is saved at sign-in and the status is off', () async {
      await seed();
      await TokenStorage.setKeepSignedIn(false);
      await http.runWithClient(() => AuthService.login(identifier: 'a@b.test', password: pw), () => server(twoFactor: false));
      expect(await TokenStorage.readCredentials(), isNull);
      expect(await TokenStorage.keepSignedInStatus(), KeepSignedInStatus.off);
    });

    test('turning it on later saves nothing until the next password sign-in', () async {
      await seed();
      await TokenStorage.setKeepSignedIn(false);
      await TokenStorage.setKeepSignedIn(true);
      expect(await TokenStorage.readCredentials(), isNull);
      expect(await TokenStorage.keepSignedInStatus(), KeepSignedInStatus.waitingForSignIn);
      await http.runWithClient(() => AuthService.login(identifier: 'a@b.test', password: pw), () => server(twoFactor: false));
      expect(await TokenStorage.keepSignedInStatus(), KeepSignedInStatus.active);
    });

    test('turning it off deletes the saved login', () async {
      await seed();
      await TokenStorage.saveCredentials(email: 'a@b.test', password: pw);
      await TokenStorage.setKeepSignedIn(false);
      expect(await TokenStorage.readCredentials(), isNull);
      expect(await TokenStorage.keepSignedInStatus(), KeepSignedInStatus.off);
    });

    test('logging out deletes the saved login', () async {
      await seed();
      await http.runWithClient(() => AuthService.login(identifier: 'a@b.test', password: pw), () => server(twoFactor: false));
      expect(await TokenStorage.readCredentials(), isNotNull);
      await http.runWithClient(AuthService.logout, () => server(twoFactor: false));
      expect(await TokenStorage.readCredentials(), isNull);
    });
  });

  group('what the saved login does when the session ends', () {
    test('no saved login: silentRelogin is unavailable and asks the server nothing', () async {
      await seed();
      final List<String> calls = <String>[];
      final SilentLoginOutcome o = await http.runWithClient(ApiClient.silentRelogin, () => server(twoFactor: false, calls: calls));
      expect(o, SilentLoginOutcome.unavailable);
      expect(calls, isEmpty);
    });

    test('no two-factor: the saved password signs in again by itself and replaces the tokens', () async {
      await seed(<String, String>{'access_token_v2': 'x.y.z', 'refresh_token_v2': _jwt(iat: 1000, tag: 'dead')});
      await TokenStorage.saveCredentials(email: 'a@b.test', password: pw);
      final List<String> calls = <String>[];
      final SessionGateResult r = await http.runWithClient(ApiClient.checkSession, () => server(twoFactor: false, calls: calls));
      expect(r, SessionGateResult.valid);
      expect(calls, <String>['refresh', 'login'], reason: 'refresh refused, then the saved login, without a code');
      expect(await TokenStorage.readCredentials(), isNotNull, reason: 'kept for the next time');
    });

    test('two-factor: the saved login is refused, deleted, and the person must sign in (no silent login)', () async {
      // Possible only if a login was saved before two-factor was switched on.
      await seed(<String, String>{'access_token_v2': 'x.y.z', 'refresh_token_v2': _jwt(iat: 1000, tag: 'dead')});
      await TokenStorage.saveCredentials(email: 'a@b.test', password: pw);
      final List<String> calls = <String>[];
      final SessionGateResult r = await http.runWithClient(ApiClient.checkSession, () => server(twoFactor: true, calls: calls));
      expect(r, SessionGateResult.expired);
      expect(calls, <String>['refresh', 'login'], reason: 'one try with the saved password, never with a code');
      expect(await TokenStorage.readCredentials(), isNull, reason: 'the refused password is deleted');
    });

    test('server unreachable: the saved login is kept for later', () async {
      await seed();
      await TokenStorage.saveCredentials(email: 'a@b.test', password: pw);
      final SilentLoginOutcome o = await http.runWithClient(
          ApiClient.silentRelogin, () => MockClient((http.Request r) async => throw http.ClientException('down')));
      expect(o, SilentLoginOutcome.unreachable);
      expect(await TokenStorage.readCredentials(), isNotNull);
    });

    test('changing the password deletes the saved login (it would be wrong now)', () async {
      await seed(<String, String>{'access_token_v2': _jwt(iat: 1000), 'refresh_token_v2': _jwt(iat: 1000)});
      await TokenStorage.saveCredentials(email: 'a@b.test', password: pw);
      await http.runWithClient(
        () => ApiClient.changePassword(currentPassword: pw, newPassword: 'another long password'),
        () => MockClient((http.Request r) async => _json(<String, String>{}, 200)),
      );
      expect(await TokenStorage.readCredentials(), isNull);
      expect(await TokenStorage.keepSignedInStatus(), KeepSignedInStatus.waitingForSignIn);
    });
  });

  group('what Settings says', () {
    test('one short line per state', () {
      for (final KeepSignedInStatus s in KeepSignedInStatus.values) {
        expect(keepSignedInSubtitle(s).length, lessThanOrEqualTo(40), reason: '$s');
      }
    });

    test('the two-factor limit is stated, and nothing promises a silent login for everyone', () {
      expect(keepSignedInSubtitle(KeepSignedInStatus.twoFactor), contains('two-factor'));
      final String info = keepSignedInInfo(iOS: false);
      expect(info, contains('two-factor'));
      expect(info, contains('cannot'));
      expect(info, contains('Android Keystore'));
      expect(keepSignedInInfo(iOS: true), contains('iPhone Keychain'));
      for (final KeepSignedInStatus s in KeepSignedInStatus.values) {
        expect(keepSignedInSubtitle(s).toLowerCase(), isNot(contains('automatically if needed')));
      }
    });
  });
}
