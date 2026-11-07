// App/server compatibility: version helpers, the handshake headers, circle
// flags and defensive parsing (docs/api-compat.md).
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openfamily/models/bubble.dart';
import 'package:openfamily/models/circle.dart';
import 'package:openfamily/services/api_client.dart';
import 'package:openfamily/services/app_compat.dart';
import 'package:openfamily/services/server_config.dart';
import 'package:openfamily/services/token_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    AppCompat.debugReset();
    AppCompat.debugSetVersion('0.20.1');
    TokenStorage.resetForTest();
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    SharedPreferences.setMockInitialValues(
        <String, Object>{'wb_api_base_url': 'https://example.test'});
    await ServerConfig.instance.load();
    ApiClient.invalidateConfig();
  });

  test('parseVersion / compareVersions', () {
    expect(parseVersion('0.20.1+45'), <int>[0, 20, 1]);
    expect(parseVersion('v0.21.0-rc1'), <int>[0, 21, 0]);
    expect(parseVersion('1.2'), <int>[1, 2, 0]);
    expect(parseVersion('nope'), isNull);
    expect(parseVersion(null), isNull);
    expect(compareVersions('0.9.5', '0.10.0'), -1);
    expect(compareVersions('0.20.1', '0.20.1'), 0);
    expect(compareVersions('0.20.2', '0.20.1'), 1);
    expect(compareVersions('x', '0.1.0'), isNull);
  });

  test('requests carry X-App-Version and the compat headers are observed',
      () async {
    late Map<String, String> sent;
    final http.Client client = MockClient((http.Request r) async {
      sent = r.headers;
      return http.Response('{}', 200, headers: <String, String>{
        'content-type': 'application/json',
        'x-openfamily-compat': 'required',
        'x-openfamily-min-app-version': '0.16.0',
        'x-openfamily-latest-app-version': '0.20.0',
      });
    });
    await http.runWithClient(
        () => ApiClient.get('/config'), () => client);
    expect(sent['X-App-Version'], '0.20.1');
    expect(AppCompat.state.value.status, CompatStatus.required);
    expect(AppCompat.state.value.minSupported, '0.16.0');
    expect(AppCompat.state.value.latest, '0.20.0');
  });

  test('a 426 answer marks the app as update-required', () async {
    final http.Client client = MockClient((http.Request r) async =>
        http.Response('{"error":"old","code":"upgrade_required"}', 426,
            headers: <String, String>{'content-type': 'application/json'}));
    await expectLater(
        http.runWithClient(
            () => ApiClient.post('/locations', body: <String, dynamic>{}),
            () => client),
        throwsA(isA<ApiException>()));
    expect(AppCompat.state.value.status, CompatStatus.required);
  });

  test('no version known: header is not sent', () async {
    AppCompat.debugSetVersion('');
    late Map<String, String> sent;
    final http.Client client = MockClient((http.Request r) async {
      sent = r.headers;
      return http.Response('{}', 200);
    });
    await http.runWithClient(
        () => ApiClient.get('/config'), () => client);
    expect(sent.containsKey('X-App-Version'), isFalse);
  });

  group('Circle', () {
    Map<String, dynamic> json(Map<String, dynamic> extra) => <String, dynamic>{
          'id': 'c1',
          'name': 'Family',
          'role': 'member',
          ...extra,
        };

    test('min_app_version newer than the app flags needsNewerApp', () {
      expect(
          Circle.fromJson(json(<String, dynamic>{
            'e2ee_mode': 'private',
            'min_app_version': '0.15.0'
          })).needsNewerApp,
          isFalse);
      expect(
          Circle.fromJson(json(<String, dynamic>{'min_app_version': '0.30.0'}))
              .needsNewerApp,
          isTrue);
    });

    test('server-side update_required and unknown modes flag it too', () {
      expect(Circle.fromJson(json(<String, dynamic>{'update_required': true}))
          .needsNewerApp, isTrue);
      expect(Circle.fromJson(json(<String, dynamic>{'e2ee_mode': 'hybrid'}))
          .needsNewerApp, isTrue);
      expect(Circle.fromJson(json(<String, dynamic>{'e2ee_mode': 'off'}))
          .needsNewerApp, isFalse);
    });

    test('unknown extra fields and missing optional ones are ignored', () {
      final Circle c = Circle.fromJson(json(<String, dynamic>{
        'brand_new_field': <String, dynamic>{'x': 1},
        'member_count': 'seven',
      }));
      expect(c.name, 'Family');
      expect(c.memberCount, 0);
    });

    test('noteCircles counts circles needing an update', () {
      AppCompat.noteCircles(<bool>[true, false, true]);
      expect(AppCompat.circlesNeedingUpdate.value, 2);
    });
  });

  test('one malformed bubble does not blank the list', () {
    final BubbleList l = BubbleList.fromJson(<String, dynamic>{
      'bubbles': <dynamic>[
        <String, dynamic>{'id': 'broken'},
        <String, dynamic>{
          'id': 'b1',
          'subject_id': 's',
          'lat': 1.0,
          'lon': 2.0,
          'radius_m': 100,
          'expires_at': '2099-01-01T00:00:00Z',
        },
      ],
      'about_me': 'not a list',
    });
    expect(l.mine.map((Bubble b) => b.id), <String>['b1']);
    expect(l.aboutMe, isEmpty);
  });
}
