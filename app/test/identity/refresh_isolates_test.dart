// Two isolates (UI + background/push) must never present the same single-use refresh token, and a dead login
// must read as "sign in again", never as "couldn't reach the server".
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openfamily/services/api_client.dart';
import 'package:openfamily/services/offline/offline_queue.dart';
import 'package:openfamily/services/offline/server_reachability.dart';
import 'package:openfamily/services/refresh_lease.dart';
import 'package:openfamily/services/server_config.dart';
import 'package:openfamily/services/token_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _b64(Map<String, Object> m) => base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
String jwt(int iat, String tag) => '${_b64(<String, Object>{'alg': 'none'})}.${_b64(<String, Object>{'iat': iat, 'exp': iat + 100000, 'uid': 'u1', 't': tag})}.sig';

http.Response _json(Object body, int status) =>
    http.Response(jsonEncode(body), status, headers: <String, String>{'content-type': 'application/json'});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  final String oldRefresh = jwt(1000, 'old-refresh');
  final String newRefresh = jwt(2000, 'new-refresh');
  final String oldAccess = jwt(1000, 'old-access');
  final String newAccess = jwt(2000, 'new-access');

  Future<void> storePair(String access, String refresh) async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{'access_token_v2': access, 'refresh_token_v2': refresh});
    SharedPreferences.setMockInitialValues(<String, Object>{
      'wb_api_base_url': 'https://example.test',
      'wb_session_access': access,
      'wb_session_refresh': refresh,
    });
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('lease');
    RefreshLease.directory = () => tmp;
    RefreshLease.maxWait = const Duration(seconds: 5);
    TokenStorage.resetForTest();
    await storePair(oldAccess, oldRefresh);
    await ServerConfig.instance.load();
    ApiClient.invalidateConfig();
    ApiClient.markSessionActive();
    ApiClient.onSessionExpired = null;
    OfflineQueue.instance = OfflineQueue(storage: MemoryQueueStorage());
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  group('refresh lease', () {
    test('a second taker waits until the first lets go', () async {
      final RefreshLease a = await RefreshLease.acquire();
      bool got = false;
      final Future<void> second = RefreshLease.acquire().then((RefreshLease l) async {
        got = true;
        await l.release();
      });
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(got, isFalse, reason: 'two isolates must not refresh at once');
      await a.release();
      await second;
      expect(got, isTrue);
    });

    test('an abandoned lease (crashed isolate) is taken over', () async {
      RefreshLease.staleAfter = const Duration(milliseconds: 100);
      addTearDown(() => RefreshLease.staleAfter = const Duration(seconds: 20));
      await RefreshLease.acquire(); // never released
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final RefreshLease b = await RefreshLease.acquire();
      await b.release();
    });
  });

  test('another isolate rotated the pair while we waited: adopt it, present nothing spent', () async {
    final List<String> refreshBodies = <String>[];
    final http.Client c = MockClient((http.Request r) async {
      if (r.url.path == '/auth/refresh') {
        refreshBodies.add(r.body);
        return _json(<String, String>{'error': 'invalid refresh token'}, 401); // the old one is spent
      }
      return r.headers['Authorization'] == 'Bearer $newAccess' ? _json(<String, bool>{'ok': true}, 200) : _json(<String, String>{'error': 'expired'}, 401);
    });
    final RefreshLease other = await RefreshLease.acquire(); // the background isolate is refreshing right now
    final Future<dynamic> call = http.runWithClient(() => ApiClient.get('/family'), () => c);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await storePair(newAccess, newRefresh); // ...and it finished: new pair is in the shared stores
    await other.release();
    final dynamic r = await call;
    expect(r, <String, dynamic>{'ok': true});
    expect(refreshBodies, isEmpty, reason: 'the spent token must never be presented again');
  });

  test('"invalid refresh" with a newer token stored meanwhile retries once with the newer token', () async {
    final List<String> presented = <String>[];
    final http.Client c = MockClient((http.Request r) async {
      if (r.url.path == '/auth/refresh') {
        final String t = (jsonDecode(r.body) as Map<String, dynamic>)['refresh_token'] as String;
        presented.add(t);
        if (t == oldRefresh) {
          await storePair(newAccess, newRefresh); // the other isolate saved its pair while we were refused
          return _json(<String, String>{'error': 'invalid refresh token'}, 401);
        }
        return _json(<String, String>{'access_token': jwt(3000, 'a3'), 'refresh_token': jwt(3000, 'r3')}, 200);
      }
      return r.headers['Authorization'] == 'Bearer ${jwt(3000, 'a3')}' ? _json(<String, bool>{'ok': true}, 200) : _json(<String, String>{'error': 'expired'}, 401);
    });
    bool expired = false;
    ApiClient.onSessionExpired = () => expired = true;
    final dynamic r = await http.runWithClient(() => ApiClient.get('/family'), () => c);
    expect(r, <String, dynamic>{'ok': true});
    expect(presented, <String>[oldRefresh, newRefresh]);
    expect(expired, isFalse);
  });

  test('a refresh the server really refuses reads as signed out, not unreachable, and keeps queued SOS', () async {
    await OfflineQueue.instance.enqueue(QueuedItem(id: 'sos1', kind: QueueKind.sos, method: 'POST', path: '/alerts/sos'));
    final http.Client c = MockClient((http.Request r) async =>
        r.url.path == '/auth/refresh' ? _json(<String, String>{'error': 'invalid refresh token'}, 401) : _json(<String, String>{'error': 'expired'}, 401));
    bool expired = false;
    ApiClient.onSessionExpired = () => expired = true;
    await http.runWithClient(() async {
      await expectLater(ApiClient.get('/family'), throwsA(isA<SessionExpiredException>()));
    }, () => c);
    expect(expired, isTrue);
    expect(ServerReachability.instance.state.value, SyncState.signedOut);
    expect(await OfflineQueue.instance.size(), 1, reason: 'the SOS waits for the next sign-in instead of being thrown away');
    ApiClient.markSessionActive();
    expect(ServerReachability.instance.state.value, isNot(SyncState.signedOut));
  });

  test('a 401 even after a fresh pair is "please sign in again" (status 401), not a status-0 unreachable', () async {
    final http.Client c = MockClient((http.Request r) async => r.url.path == '/auth/refresh'
        ? _json(<String, String>{'access_token': newAccess, 'refresh_token': newRefresh}, 200)
        : _json(<String, String>{'error': 'revoked'}, 401));
    await http.runWithClient(() async {
      await expectLater(
          ApiClient.get('/family'),
          throwsA(isA<ApiException>().having((ApiException e) => e.status, 'status', 401).having((ApiException e) => e.message, 'message', contains('sign in'))));
    }, () => c);
    expect(ServerReachability.instance.state.value, SyncState.signedOut);
    ApiClient.markSessionActive();
  });
}
