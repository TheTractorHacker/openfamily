// Wire-efficiency layer of ApiClient: conditional GETs, coalescing, retries,
// cancellation, delta merge and the QUERY -> POST fallback. All with fakes.
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openfamily/services/api_client.dart';
import 'package:openfamily/services/api_wire.dart';
import 'package:openfamily/services/server_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _json(Object body, {int status = 200, Map<String, String>? headers}) =>
    http.Response(jsonEncode(body), status, headers: <String, String>{
      'content-type': 'application/json',
      ...?headers,
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues(
        <String, String>{'access_token': 'a.b.c', 'refresh_token': 'r'});
    SharedPreferences.setMockInitialValues(
        <String, Object>{'wb_api_base_url': 'https://example.test'});
    await ServerConfig.instance.load();
    ApiWire.resetForTest();
    ApiWire.maxGetRetries = 0;
  });

  group('conditional GET', () {
    test('sends If-None-Match after a validated response and reuses the body on 304', () async {
      final List<String?> sent = <String?>[];
      final MockClient client = MockClient((http.Request r) async {
        sent.add(r.headers['If-None-Match']);
        if (r.headers['If-None-Match'] == 'W/"v1"') {
          return http.Response('', 304, headers: <String, String>{'etag': 'W/"v1"'});
        }
        return _json(<String, Object>{'a': 1}, headers: <String, String>{'etag': 'W/"v1"'});
      });
      final dynamic first = await http.runWithClient(() => ApiClient.get('/circles'), () => client);
      final dynamic second = await http.runWithClient(() => ApiClient.get('/circles'), () => client);
      expect(first, <String, Object>{'a': 1});
      expect(second, <String, Object>{'a': 1});
      expect(sent, <String?>[null, 'W/"v1"']);
    });

    test('a changed body replaces the cached one', () async {
      int n = 0;
      final MockClient client = MockClient((http.Request r) async {
        n++;
        return _json(<String, Object>{'n': n}, headers: <String, String>{'etag': 'W/"e$n"'});
      });
      await http.runWithClient(() => ApiClient.get('/circles'), () => client);
      final dynamic b = await http.runWithClient(() => ApiClient.get('/circles'), () => client);
      expect(b, <String, Object>{'n': 2});
    });

    test('responses without an ETag are never cached', () async {
      final List<String?> sent = <String?>[];
      final MockClient client = MockClient((http.Request r) async {
        sent.add(r.headers['If-None-Match']);
        return _json(<String, Object>{'a': 1});
      });
      await http.runWithClient(() => ApiClient.get('/x'), () => client);
      await http.runWithClient(() => ApiClient.get('/x'), () => client);
      expect(sent, <String?>[null, null]);
    });

    test('cache is bounded in entries and bytes', () {
      final ConditionalCache c = ConditionalCache(maxEntries: 3, maxEntryBytes: 100, maxTotalBytes: 200);
      CachedResponse r(int n) => CachedResponse('e', Uint8List(n), 'application/json');
      c.put('a', r(80));
      c.put('b', r(80));
      expect(c.length, 2);
      c.put('c', r(80)); // 240 > 200: the oldest goes
      expect(c.get('a'), isNull);
      expect(c.totalBytes, lessThanOrEqualTo(200));
      c.put('big', r(101)); // over the per-entry cap: ignored
      expect(c.get('big'), isNull);
      c.put('d', r(1));
      c.put('e', r(1));
      c.put('f', r(1));
      expect(c.length, lessThanOrEqualTo(3));
    });
  });

  group('coalescing and retry', () {
    test('simultaneous identical GETs share one request', () async {
      int calls = 0;
      final Completer<void> gate = Completer<void>();
      final MockClient client = MockClient((http.Request r) async {
        calls++;
        await gate.future;
        return _json(<String, Object>{'ok': true});
      });
      final List<Future<dynamic>> fs = http.runWithClient(
        () => <Future<dynamic>>[
          ApiClient.get('/family/members'),
          ApiClient.get('/family/members'),
          ApiClient.get('/family/members'),
        ],
        () => client,
      );
      gate.complete();
      final List<dynamic> out = await Future.wait(fs);
      expect(calls, 1);
      expect(out.every((dynamic v) => v['ok'] == true), isTrue);
      // A different URL is a different request.
      await http.runWithClient(() => ApiClient.get('/family/places'), () => client);
      expect(calls, 2);
    });

    test('transient failures retry with jitter, 4xx do not', () async {
      ApiWire.maxGetRetries = 2;
      int calls = 0;
      final MockClient flaky = MockClient((http.Request r) async {
        calls++;
        return calls < 3 ? http.Response('', 503) : _json(<String, Object>{'ok': 1});
      });
      final dynamic ok = await http.runWithClient(() => ApiClient.get('/me'), () => flaky);
      expect(ok, <String, Object>{'ok': 1});
      expect(calls, 3);

      calls = 0;
      final MockClient forbidden = MockClient((http.Request r) async {
        calls++;
        return _json(<String, Object>{'error': 'no'}, status: 403);
      });
      await expectLater(
          http.runWithClient(() => ApiClient.get('/me2'), () => forbidden), throwsA(isA<ApiException>()));
      expect(calls, 1);
    });

    test('POST is never retried', () async {
      ApiWire.maxGetRetries = 2;
      int calls = 0;
      final MockClient client = MockClient((http.Request r) async {
        calls++;
        return http.Response('', 503);
      });
      await expectLater(
          http.runWithClient(() => ApiClient.post('/alerts/sos', body: <String, Object>{}), () => client),
          throwsA(isA<ApiException>()));
      expect(calls, 1);
    });

    test('retry delay grows, is jittered and capped', () {
      final math.Random rng = math.Random(7);
      final List<int> d = <int>[for (int i = 0; i < 8; i++) retryDelay(i, rng).inMilliseconds];
      expect(d[0], inInclusiveRange(125, 250));
      expect(d[1], inInclusiveRange(250, 500));
      expect(d.every((int v) => v <= 4000), isTrue);
      expect(isTransientStatus(0), isTrue);
      expect(isTransientStatus(503), isTrue);
      expect(isTransientStatus(404), isFalse);
      expect(isTransientStatus(401), isFalse);
    });
  });

  group('cancellation', () {
    test('a cancelled token stops the caller waiting, not other callers', () async {
      final Completer<void> gate = Completer<void>();
      int calls = 0;
      final MockClient client = MockClient((http.Request r) async {
        calls++;
        await gate.future;
        return _json(<String, Object>{'ok': true});
      });
      final ApiCancelToken token = ApiCancelToken();
      final List<Future<dynamic>> fs = http.runWithClient(
        () => <Future<dynamic>>[
          ApiClient.get('/family/members', cancel: token),
          ApiClient.get('/family/members'),
        ],
        () => client,
      );
      final Future<void> cancelled = expectLater(fs[0], throwsA(isA<ApiCancelled>()));
      token.cancel();
      await cancelled;
      gate.complete();
      expect((await fs[1])['ok'], isTrue);
      expect(calls, 1);
    });

    test('an already cancelled token fails immediately', () async {
      final ApiCancelToken token = ApiCancelToken()..cancel();
      await expectLater(token.guard(Future<int>.value(1)), throwsA(isA<ApiCancelled>()));
    });
  });

  group('delta merge', () {
    List<Map<String, dynamic>> local() => <Map<String, dynamic>>[
          <String, dynamic>{'id': 'a', 'name': 'A', 'lat': 1.0},
          <String, dynamic>{'id': 'b', 'name': 'B', 'lat': 2.0},
          <String, dynamic>{'id': 'c', 'name': 'C', 'lat': 3.0},
        ];

    test('full replaces everything', () {
      final List<Map<String, dynamic>> out = mergeDelta(local(), <String, dynamic>{
        'full': true,
        'items': <Map<String, dynamic>>[<String, dynamic>{'id': 'z'}],
        'ids': <String>['z'],
      });
      expect(out.map((Map<String, dynamic> m) => m['id']), <String>['z']);
    });

    test('delta merges changed fields and drops ids that disappeared', () {
      final List<Map<String, dynamic>> out = mergeDelta(local(), <String, dynamic>{
        'full': false,
        'items': <Map<String, dynamic>>[<String, dynamic>{'id': 'b', 'lat': 9.0}],
        'ids': <String>['a', 'b'], // c is gone: that is the tombstone
      });
      expect(out.map((Map<String, dynamic> m) => m['id']), <String>['a', 'b']);
      expect(out[1]['lat'], 9.0);
      expect(out[1]['name'], 'B'); // untouched fields survive
    });

    test('a new member appears from items', () {
      final List<Map<String, dynamic>> out = mergeDelta(local(), <String, dynamic>{
        'full': false,
        'items': <Map<String, dynamic>>[<String, dynamic>{'id': 'd', 'name': 'D'}],
        'ids': <String>['a', 'b', 'c', 'd'],
      });
      expect(out.map((Map<String, dynamic> m) => m['id']), <String>['a', 'b', 'c', 'd']);
    });
  });

  group('QUERY with POST fallback', () {
    final Map<String, Object> body = <String, Object>{'member_id': 'm', 'windows': <Object>[]};

    test('uses QUERY when the whole path supports it and remembers it', () async {
      final List<String> methods = <String>[];
      final MockClient client = MockClient((http.Request r) async {
        methods.add(r.method);
        expect(r.headers['Content-Type'], contains('application/json'));
        expect(jsonDecode(r.body), body);
        return _json(<String, Object>{'results': <Object>[]});
      });
      await http.runWithClient(() => ApiClient.query('/family/history/query', body: body), () => client);
      await http.runWithClient(() => ApiClient.query('/family/history/query', body: body), () => client);
      expect(methods, <String>['QUERY', 'QUERY']);
    });

    for (final int status in <int>[405, 501, 400]) {
      test('falls back to POST on $status and stops probing for a day', () async {
        final List<String> methods = <String>[];
        final MockClient client = MockClient((http.Request r) async {
          methods.add(r.method);
          if (r.method == 'QUERY') return _json(<String, Object>{'error': 'x'}, status: status);
          return _json(<String, Object>{'results': <Object>[]});
        });
        final dynamic a = await http.runWithClient(() => ApiClient.query('/family/history/query', body: body), () => client);
        final dynamic b = await http.runWithClient(() => ApiClient.query('/family/history/query', body: body), () => client);
        expect(a, <String, Object>{'results': <Object>[]});
        expect(b, a);
        expect(methods, <String>['QUERY', 'POST', 'POST']);
      });
    }

    test('falls back to POST when the connection drops the unknown verb', () async {
      final List<String> methods = <String>[];
      final MockClient client = MockClient((http.Request r) async {
        methods.add(r.method);
        if (r.method == 'QUERY') throw http.ClientException('connection reset');
        return _json(<String, Object>{'ok': true});
      });
      final dynamic out = await http.runWithClient(() => ApiClient.query('/p', body: body), () => client);
      expect(out, <String, Object>{'ok': true});
      expect(methods, <String>['QUERY', 'POST']);
    });

    test('a real answer such as 403 is returned, not retried as POST', () async {
      final List<String> methods = <String>[];
      final MockClient client = MockClient((http.Request r) async {
        methods.add(r.method);
        return _json(<String, Object>{'error': 'forbidden'}, status: 403);
      });
      await expectLater(http.runWithClient(() => ApiClient.query('/p', body: body), () => client),
          throwsA(isA<ApiException>().having((ApiException e) => e.status, 'status', 403)));
      expect(methods, <String>['QUERY']);
    });

    test('both failing surfaces the POST error and records nothing', () async {
      final MockClient client = MockClient((http.Request r) async =>
          r.method == 'QUERY' ? http.Response('', 405) : _json(<String, Object>{'error': 'bad'}, status: 400));
      await expectLater(http.runWithClient(() => ApiClient.query('/p', body: body), () => client),
          throwsA(isA<ApiException>().having((ApiException e) => e.status, 'status', 400)));
      expect(await ApiWire.queryCapability.shouldTryQuery('https://example.test'), isTrue);
    });
  });

  group('QueryCapability', () {
    test('probe, remember, re-probe after a day, honour the server flag', () async {
      DateTime now = DateTime(2026, 1, 1, 12);
      final QueryCapability cap =
          QueryCapability(store: MemoryQueryCapabilityStore(), clock: () => now);
      const String s = 'https://x.test';
      expect(await cap.shouldTryQuery(s), isTrue); // never probed
      await cap.recordFellBack(s);
      expect(await cap.shouldTryQuery(s), isFalse);
      now = now.add(const Duration(hours: 23));
      expect(await cap.shouldTryQuery(s), isFalse);
      now = now.add(const Duration(hours: 2));
      expect(await cap.shouldTryQuery(s), isTrue); // re-probe
      await cap.recordQueryWorked(s);
      expect(await cap.shouldTryQuery(s), isTrue);
      cap.noteServerFlag(s, false); // server says QUERY is off: no probe at all
      expect(await cap.shouldTryQuery(s), isFalse);
      expect(await cap.shouldTryQuery('https://other.test'), isTrue); // per server
    });
  });

  group('bootstrap', () {
    test('returns the document and passes the server QUERY flag on', () async {
      final MockClient client = MockClient((http.Request r) async {
        expect(r.url.path, '/app/bootstrap');
        return _json(<String, Object>{
          'wire': <String, Object>{'query': false},
          'circles': <Object>[],
        });
      });
      final Map<String, dynamic>? d = await http.runWithClient(() => ApiClient.bootstrap(), () => client);
      expect(d!['circles'], isEmpty);
      expect(await ApiWire.queryCapability.shouldTryQuery('https://example.test'), isFalse);
    });

    test('an older server (404) means "use the individual requests"', () async {
      final MockClient client = MockClient((http.Request r) async => _json(<String, Object>{'error': 'nf'}, status: 404));
      expect(await http.runWithClient(() => ApiClient.bootstrap(), () => client), isNull);
    });
  });
}
