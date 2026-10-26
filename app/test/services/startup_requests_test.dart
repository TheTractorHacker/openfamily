// Records the HTTP requests the app makes at startup, on a circle switch and
// on resume / pull-to-refresh, with a fake client. The sequence below calls
// the same service methods, in the same order, as the session gate
// (lib/main.dart), MapScreen.initState/_load and PushService.sync.
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openfamily/services/api_client.dart';
import 'package:openfamily/services/circle_service.dart';
import 'package:openfamily/services/family_service.dart';
import 'package:openfamily/services/place_service.dart';
import 'package:openfamily/services/server_config.dart';
import 'package:openfamily/services/tile_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Recorder {
  final List<String> requests = <String>[];

  http.Client client() => MockClient((http.Request r) async {
        requests.add('${r.method} ${r.url.path}');
        final String p = r.url.path;
        Object body;
        if (p == '/config') {
          body = <String, dynamic>{'direct_push': false};
        } else if (p == '/circles') {
          body = <dynamic>[];
        } else if (p == '/family') {
          body = <String, dynamic>{'name': 'Fam', 'role': 'admin', 'user_id': 'me'};
        } else if (p == '/family/members') {
          body = <dynamic>[];
        } else if (p == '/family/places') {
          body = <dynamic>[];
        } else {
          body = <String, dynamic>{};
        }
        return http.Response(jsonEncode(body), 200,
            headers: <String, String>{'content-type': 'application/json'});
      });

  int count(String path) =>
      requests.where((String r) => r.endsWith(' $path')).length;
}

/// Gate + map screen + push registration, as the app runs them at launch.
Future<void> startup() async {
  // main.dart session gate: operator config (tile style), concurrent with the
  // session check (no request: token still valid).
  await TileConfig.instance.refresh();
  // MapScreen.initState: PushService.sync() -> _registerAndroid() reads the
  // config; unawaited(_refreshServerFeatures()) -> TileConfig.refresh().
  await Future.wait<void>(<Future<void>>[
    ApiClient.getPushConfig().then((_) {}),
    TileConfig.instance.refresh(),
    // MapScreen._load: circles, then family name + roster.
    () async {
      await CircleService.instance.listCircles();
      final FamilyService f = FamilyService();
      await Future.wait<Object>(<Future<Object>>[
        f.fetchFamilyName(),
        f.fetchMembers(),
      ]);
    }(),
  ]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'access_token': 'a.b.c',
      'refresh_token': 'r',
    });
    SharedPreferences.setMockInitialValues(
        <String, Object>{'wb_api_base_url': 'https://example.test'});
    await ServerConfig.instance.load();
    PlaceService.invalidateCache();
    ApiClient.invalidateConfig();
  });

  test('startup request count', () async {
    final Recorder rec = Recorder();
    await http.runWithClient(startup, rec.client);
    // ignore: avoid_print
    print('PERFMETRIC startup requests=${rec.requests.length} '
        '/config=${rec.count('/config')} /circles=${rec.count('/circles')} '
        '/family=${rec.count('/family')} '
        '/family/members=${rec.count('/family/members')} '
        '/family/places=${rec.count('/family/places')}');
    expect(rec.count('/config'), 1);
    expect(rec.count('/circles'), 1);
    expect(rec.count('/family'), 1);
    expect(rec.count('/family/members'), 1);
    expect(rec.count('/family/places'), 1);
    expect(rec.requests.length, 5);
  });

  test('resume / pull-to-refresh refetches the roster only', () async {
    final Recorder rec = Recorder();
    await http.runWithClient(() async {
      await startup();
      rec.requests.clear();
      // MapScreen._onResumed: refreshMembers() + _refreshServerFeatures().
      final FamilyService f = FamilyService();
      await f.refreshMembers();
      await TileConfig.instance.refresh();
    }, rec.client);
    // ignore: avoid_print
    print('PERFMETRIC resume requests=${rec.requests.length} '
        '(${rec.requests.join(', ')})');
    expect(rec.requests, <String>['GET /family/members']);
  });

  test('circle switch fetches the new roster, not places or config', () async {
    final Recorder rec = Recorder();
    await http.runWithClient(() async {
      final FamilyService f = FamilyService();
      await startup();
      rec.requests.clear();
      await f.setCircle('c2');
    }, rec.client);
    // ignore: avoid_print
    print('PERFMETRIC circle-switch requests=${rec.requests.length} '
        '(${rec.requests.join(', ')})');
    expect(rec.requests, <String>['GET /family/members']);
  });

  test('config cache honours its TTL and force', () async {
    final Recorder rec = Recorder();
    DateTime now = DateTime(2026, 1, 1);
    ApiClient.configClock = () => now;
    addTearDown(() => ApiClient.configClock = DateTime.now);
    await http.runWithClient(() async {
      await ApiClient.getPushConfig();
      await ApiClient.getPushConfig();
      expect(rec.count('/config'), 1);
      now = now.add(ApiClient.configTtl + const Duration(seconds: 1));
      await ApiClient.getPushConfig();
      expect(rec.count('/config'), 2);
      await ApiClient.getPushConfig(force: true);
      expect(rec.count('/config'), 3);
    }, rec.client);
  });

  test('concurrent config callers share one request', () async {
    final Recorder rec = Recorder();
    await http.runWithClient(() async {
      await Future.wait<Object>(<Future<Object>>[
        ApiClient.getPushConfig(),
        ApiClient.getPushConfig(),
        ApiClient.getPushConfig(),
      ]);
    }, rec.client);
    expect(rec.count('/config'), 1);
  });

  test('place cache: TTL, single flight and invalidation on mutation',
      () async {
    final Recorder rec = Recorder();
    DateTime now = DateTime(2026, 1, 1);
    PlaceService.clock = () => now;
    addTearDown(() => PlaceService.clock = DateTime.now);
    await http.runWithClient(() async {
      await Future.wait<Object>(<Future<Object>>[
        PlaceService.fetchPlaces(),
        PlaceService.fetchPlaces(),
      ]);
      await PlaceService.fetchPlaces();
      expect(rec.count('/family/places'), 1);
      await PlaceService.fetchPlaces(force: true);
      expect(rec.count('/family/places'), 2);
      now = now.add(PlaceService.cacheTtl + const Duration(seconds: 1));
      await PlaceService.fetchPlaces();
      expect(rec.count('/family/places'), 3);
      await PlaceService.deletePlace('p1');
      await PlaceService.fetchPlaces();
      expect(rec.count('/family/places'), 4, reason: 'delete invalidates');
    }, rec.client);
  });
}
