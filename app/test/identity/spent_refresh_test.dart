// Production incident (v0.26.x, after an update): the app held an OLDER, already used copy of its refresh token in
// one store next to the live one, presented the old one first, and the server revoked the whole session as theft.
// A refresh token this phone has replaced or used must never be presented again.
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/background_credential_store.dart';
import 'package:openfamily/services/session_diary.dart';
import 'package:openfamily/services/token_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _b64(Map<String, Object> m) => base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
String jwt(int iat, String tag) =>
    '${_b64(<String, Object>{'alg': 'none'})}.${_b64(<String, Object>{'iat': iat, 'exp': iat + 100000, 'uid': 'u1', 't': tag})}.sig';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final String stale = jwt(1000, 'stale');
  final String live = jwt(1001, 'live');
  final String access = jwt(1001, 'access');

  setUp(() {
    TokenStorage.resetForTest();
    TokenStorage.retryDelays = const <Duration>[Duration.zero];
  });

  test('saving a newer pair marks the older copies in every store as spent, so they are never candidates', () async {
    // The stale copy sits in the plain store (D); the pair just refreshed is saved over A and B.
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    SharedPreferences.setMockInitialValues(<String, Object>{
      'wb_api_base_url': 'https://example.test',
      'wb_session_access': access,
      'wb_session_refresh': stale,
    });
    await TokenStorage.saveTokens(access: access, refresh: live);
    expect(await TokenStorage.refreshCandidates(), <String>[live]);
    expect(TokenStorage.isRejected(stale), isTrue);
  });

  test('the spent list survives a restart: a stale copy that turns up later is still not presented', () async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    SharedPreferences.setMockInitialValues(<String, Object>{
      'wb_api_base_url': 'https://example.test',
      'wb_session_access': access,
      'wb_session_refresh': stale,
    });
    await TokenStorage.saveTokens(access: access, refresh: live);
    final Map<String, Object> persisted = <String, Object>{
      for (final String k in (await SharedPreferences.getInstance()).getKeys())
        k: (await SharedPreferences.getInstance()).get(k)!,
    };
    // "Restart": process memory is gone, the stale copy is back in a store (an update restored an old backup).
    TokenStorage.resetForTest();
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'access_token_v2': access,
      'refresh_token_v2': stale,
      'session_b_access': access,
      'session_b_refresh': live,
    });
    SharedPreferences.setMockInitialValues(persisted);
    final List<String> candidates = await TokenStorage.refreshCandidates();
    expect(candidates, <String>[live], reason: 'only the live token is ever offered to the server');
  });

  test('a token with the same issue time (or an unknown one) is never marked spent', () async {
    final String sameSecond = jwt(1001, 'other');
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    SharedPreferences.setMockInitialValues(<String, Object>{
      'wb_api_base_url': 'https://example.test',
      'wb_session_access': access,
      'wb_session_refresh': sameSecond,
    });
    await TokenStorage.saveTokens(access: access, refresh: live);
    expect(TokenStorage.isRejected(sameSecond), isFalse);
    expect(TokenStorage.isRejected(live), isFalse);
  });

  test('a newer token already stored is never marked spent by an older save (out-of-order write)', () async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    SharedPreferences.setMockInitialValues(<String, Object>{
      'wb_api_base_url': 'https://example.test',
      'wb_session_access': access,
      'wb_session_refresh': live,
    });
    await TokenStorage.saveTokens(access: access, refresh: stale);
    expect(TokenStorage.isRejected(live), isFalse, reason: 'the live token must never be marked spent');
  });

  test('readRefreshToken never returns a token the phone already used (a store that cannot be cleaned)', () async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{'access_token_v2': access, 'refresh_token_v2': stale});
    SharedPreferences.setMockInitialValues(<String, Object>{
      'wb_api_base_url': 'https://example.test',
      'wb_spent_refresh': <String>[SessionDiary.shortHash(stale)],
    });
    expect(await TokenStorage.readRefreshToken(), isNull);
    expect(await TokenStorage.refreshCandidates(), isEmpty);
  });

  test('sign-out remembers what every store held, so a store that keeps its copy cannot resurrect the session',
      () async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{'access_token_v2': access, 'refresh_token_v2': stale});
    SharedPreferences.setMockInitialValues(<String, Object>{'wb_api_base_url': 'https://example.test'});
    await TokenStorage.clear(reason: 'test');
    // The store "ignored the delete": the same token is back in it.
    FlutterSecureStorage.setMockInitialValues(<String, String>{'access_token_v2': access, 'refresh_token_v2': stale});
    TokenStorage.resetForTest();
    expect(await TokenStorage.refreshCandidates(), isEmpty);
    expect(await TokenStorage.readRefreshToken(), isNull);
  });

  group('a session that ran out keeps the phone reporting in the background', () {
    String uidJwt(String uid, int iat) =>
        '${_b64(<String, Object>{'alg': 'none'})}.${_b64(<String, Object>{'iat': iat, 'exp': iat + 100000, 'uid': uid})}.sig';

    Future<void> seed(String uid) async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{
        'access_token_v2': uidJwt(uid, 1000),
        'refresh_token_v2': uidJwt(uid, 1000),
      });
      SharedPreferences.setMockInitialValues(<String, Object>{'wb_api_base_url': 'https://example.test'});
      await BackgroundCredentialStore.saveIngestKey('device-key');
      await BackgroundCredentialStore.sync(apiBaseUrl: 'https://example.test', deviceId: 'dev-1');
    }

    test('an expired session (keepOfflineData) keeps the device key and id; the tokens are gone', () async {
      await seed('u1');
      await TokenStorage.clear(reason: 'refresh rejected', keepOfflineData: true);
      expect(await BackgroundCredentialStore.readIngestKey(), 'device-key');
      expect(await BackgroundCredentialStore.readDeviceId(), 'dev-1');
      expect(await TokenStorage.readRefreshToken(), isNull);
    });

    test('an explicit sign-out removes the device key and id', () async {
      await seed('u1');
      await TokenStorage.clear(reason: 'logout');
      expect(await BackgroundCredentialStore.readIngestKey(), isNull);
      expect(await BackgroundCredentialStore.readDeviceId(), isNull);
    });

    test('the same person signing in again carries on with the kept device key', () async {
      await seed('u1');
      await TokenStorage.clear(reason: 'refresh rejected', keepOfflineData: true);
      await TokenStorage.saveTokens(access: uidJwt('u1', 5000), refresh: uidJwt('u1', 5000));
      expect(await BackgroundCredentialStore.readIngestKey(), 'device-key');
    });

    test('a DIFFERENT account signing in inherits nothing of the previous one', () async {
      await seed('u1');
      await TokenStorage.clear(reason: 'refresh rejected', keepOfflineData: true);
      await TokenStorage.saveTokens(access: uidJwt('u2', 5000), refresh: uidJwt('u2', 5000));
      expect(await BackgroundCredentialStore.readIngestKey(), isNull);
      expect(await BackgroundCredentialStore.readDeviceId(), isNot('dev-1'));
    });

    test('when whose credentials they are cannot be told, nothing is kept (fail closed)', () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{'access_token_v2': 'opaque', 'refresh_token_v2': 'opaque'});
      SharedPreferences.setMockInitialValues(<String, Object>{'wb_api_base_url': 'https://example.test'});
      await BackgroundCredentialStore.saveIngestKey('device-key');
      await TokenStorage.clear(reason: 'refresh rejected', keepOfflineData: true);
      expect(await BackgroundCredentialStore.readIngestKey(), isNull);
    });
  });
}
