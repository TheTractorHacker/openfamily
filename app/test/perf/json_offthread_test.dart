// Large JSON responses must not stall the UI isolate.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openfamily/services/api_client.dart';
import 'package:openfamily/services/server_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

String _bigTrips(int n) => jsonEncode(<Map<String, dynamic>>[
      for (int i = 0; i < n; i++)
        <String, dynamic>{
          'id': 'trip-$i',
          'start': '2026-01-01T10:00:00Z',
          'distance_m': 1234.5 + i,
          'points': <List<double>>[
            for (int p = 0; p < 40; p++) <double>[51.5 + p * 1e-4, -0.1 + i * 1e-5],
          ],
        },
    ]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues(
        <String, String>{'access_token': 'a.b.c', 'refresh_token': 'r'});
    SharedPreferences.setMockInitialValues(
        <String, Object>{'wb_api_base_url': 'https://example.test'});
    await ServerConfig.instance.load();
  });

  test('big bodies decode on a worker isolate with identical results',
      () async {
    final String body = _bigTrips(2500); // several MB
    expect(body.length, greaterThan(ApiClient.isolateDecodeThreshold));

    // Old behaviour: one synchronous decode on the calling isolate.
    final Stopwatch sw = Stopwatch()..start();
    final dynamic expected = jsonDecode(body);
    final int syncMs = sw.elapsedMilliseconds;

    // Encode outside the measured window: a real client receives bytes.
    final http.Response response = http.Response.bytes(
        utf8.encode(body), 200,
        headers: <String, String>{'content-type': 'application/json'});

    // New behaviour: measure the longest time the event loop is unavailable.
    int maxGapMs = 0;
    int last = sw.elapsedMilliseconds;
    final Timer ticker = Timer.periodic(const Duration(milliseconds: 1), (_) {
      final int now = sw.elapsedMilliseconds;
      if (now - last > maxGapMs) maxGapMs = now - last;
      last = now;
    });
    final dynamic actual = await http.runWithClient(
      () => ApiClient.get('/trips'),
      () => MockClient((_) async => response),
    );
    ticker.cancel();

    // ignore: avoid_print
    print('PERFMETRIC json ${(body.length / 1e6).toStringAsFixed(1)} MB: '
        'sync decode blocks ${syncMs} ms; via ApiClient the longest '
        'event-loop gap is $maxGapMs ms');
    expect(actual, expected);
    expect(maxGapMs, lessThan(syncMs));
  });

  test('small bodies still decode inline', () async {
    final dynamic r = await http.runWithClient(
      () => ApiClient.get('/family/places'),
      () => MockClient((_) async => http.Response('[{"a":1}]', 200)),
    );
    expect(r, <dynamic>[
      <String, dynamic>{'a': 1}
    ]);
  });

  test('error bodies still raise ApiException', () async {
    await expectLater(
      http.runWithClient(
        () => ApiClient.get('/x'),
        () => MockClient(
            (_) async => http.Response('{"error":"nope"}', 400)),
      ),
      throwsA(isA<ApiException>()),
    );
  });
}
