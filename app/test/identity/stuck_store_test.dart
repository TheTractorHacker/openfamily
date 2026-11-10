// ignore_for_file: depend_on_referenced_packages
// Production incident (Samsung, Android 17): a Keystore-backed store hung instead of failing. The refresh had
// already been rotated by the server, but saving the new token stopped at the stuck store, the plain-file copy
// was never written, and the phone later presented the spent token and was signed out. A stuck store must never
// stop the other copies from being written, nor the session from being read.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/token_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _b64(Map<String, Object> m) => base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
String jwt(int iat, String tag) =>
    '${_b64(<String, Object>{'alg': 'none'})}.${_b64(<String, Object>{'iat': iat, 'exp': iat + 100000, 'uid': 'u1', 't': tag})}.sig';

/// A secure-storage platform where chosen operations never complete.
class HangingPlatform extends FlutterSecureStoragePlatform {
  final Map<String, String> data = <String, String>{};
  bool hangWrites = false;
  bool hangReads = false;

  @override
  Future<bool> containsKey({required String key, required Map<String, String> options}) async => data.containsKey(key);
  @override
  Future<void> delete({required String key, required Map<String, String> options}) async => data.remove(key);
  @override
  Future<void> deleteAll({required Map<String, String> options}) async => data.clear();
  @override
  Future<String?> read({required String key, required Map<String, String> options}) {
    if (hangReads) return Completer<String?>().future;
    return Future<String?>.value(data[key]);
  }

  @override
  Future<Map<String, String>> readAll({required Map<String, String> options}) async => Map<String, String>.of(data);
  @override
  Future<void> write({required String key, required String value, required Map<String, String> options}) {
    if (hangWrites) return Completer<void>().future;
    data[key] = value;
    return Future<void>.value();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HangingPlatform platform;
  final String oldRefresh = jwt(1000, 'old');
  final String newRefresh = jwt(2000, 'new');
  final String access = jwt(2000, 'access');

  setUp(() {
    platform = HangingPlatform();
    FlutterSecureStoragePlatform.instance = platform;
    TokenStorage.resetForTest();
    TokenStorage.storeTimeout = const Duration(milliseconds: 200);
    TokenStorage.retryDelays = const <Duration>[Duration.zero];
    SharedPreferences.setMockInitialValues(<String, Object>{
      'wb_api_base_url': 'https://example.test',
      'wb_session_access': jwt(1000, 'old-access'),
      'wb_session_refresh': oldRefresh,
    });
  });

  tearDown(() => TokenStorage.storeTimeout = const Duration(seconds: 5));

  test('writes that hang never stop the plain-file copy: the new token is saved, the old one is spent', () async {
    platform.hangWrites = true;
    await TokenStorage.saveTokens(access: access, refresh: newRefresh).timeout(const Duration(seconds: 10));
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    expect(prefs.getString('wb_session_refresh'), newRefresh);
    expect(TokenStorage.isRejected(oldRefresh), isTrue, reason: 'the replaced token must never be offered again');
  });

  test('reads that hang do not block reading the session from the plain file', () async {
    platform.hangReads = true;
    SharedPreferences.setMockInitialValues(<String, Object>{
      'wb_api_base_url': 'https://example.test',
      'wb_session_access': access,
      'wb_session_refresh': newRefresh,
    });
    final String? r = await TokenStorage.readRefreshToken().timeout(const Duration(seconds: 10));
    expect(r, newRefresh);
  });

  test('when every store fails the save is still a loud failure', () async {
    platform.hangWrites = true;
    SharedPreferences.setMockInitialValues(<String, Object>{'wb_api_base_url': 'https://example.test'});
    // The plain file works in the test harness, so one copy is saved: no exception.
    await TokenStorage.saveTokens(access: access, refresh: newRefresh).timeout(const Duration(seconds: 10));
  });
}
