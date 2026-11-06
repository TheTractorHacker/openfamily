// ApiGeocodingBackend must send the viewer location and the result language,
// so the server can search locally first and answer in the user's language.
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:openfamily/services/api_client.dart';
import 'package:openfamily/services/geocoding_service.dart';
import 'package:openfamily/services/server_config.dart';
import 'package:openfamily/services/token_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    TokenStorage.resetForTest();
    FlutterSecureStorage.setMockInitialValues(<String, String>{
      'access_token_v2': 'a.b.c',
      'refresh_token_v2': 'r.r.r',
    });
    SharedPreferences.setMockInitialValues(
        <String, Object>{'wb_api_base_url': 'https://example.test'});
    await ServerConfig.instance.load();
    ApiClient.invalidateConfig();
    ApiClient.markSessionActive();
  });

  test('suggest sends lat, lon and lang', () async {
    final List<Uri> seen = <Uri>[];
    await http.runWithClient(() async {
      await const ApiGeocodingBackend(languageCode: 'de').suggest(
        'Alma Highschool',
        near: const LatLng(35.50652, -94.05592),
      );
    }, () => MockClient((http.Request r) async {
          seen.add(r.url);
          return http.Response('{"results":[]}', 200,
              headers: <String, String>{'content-type': 'application/json'});
        }));
    expect(seen, hasLength(1));
    final Map<String, String> q = seen.single.queryParameters;
    expect(seen.single.path, '/geocode/search');
    expect(q['lat'], '35.507');
    expect(q['lon'], '-94.056');
    expect(q['lang'], 'de');
    expect(q['q'], 'Alma Highschool');
  });

  test('without near, no coordinates are sent; lang always is', () async {
    final List<Uri> seen = <Uri>[];
    await http.runWithClient(() async {
      await const ApiGeocodingBackend(languageCode: 'en').suggest('Main St');
      await const ApiGeocodingBackend(languageCode: 'en')
          .reverse(const LatLng(1, 2));
    }, () => MockClient((http.Request r) async {
          seen.add(r.url);
          return http.Response('{"results":[]}', 200,
              headers: <String, String>{'content-type': 'application/json'});
        }));
    expect(seen[0].queryParameters.containsKey('lat'), isFalse);
    expect(seen[0].queryParameters['lang'], 'en');
    expect(seen[1].path, '/geocode/reverse');
    expect(seen[1].queryParameters['lang'], 'en');
  });
}
