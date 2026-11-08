import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:openfamily/services/api_client.dart';
import 'package:openfamily/services/offline/offline_queue.dart';
import 'package:openfamily/services/server_config.dart';
import 'package:openfamily/services/token_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

QueuedItem item(String id, String kind, {int? at, String? key, Map<String, dynamic>? meta}) => QueuedItem(
      id: id,
      kind: kind,
      method: 'POST',
      path: '/x/$id',
      body: <String, dynamic>{'client_id': id, 'note': 'n'},
      at: at,
      coalesceKey: key,
      meta: meta ?? const <String, dynamic>{},
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MemoryQueueStorage storage;
  late DateTime now;
  late OfflineQueue q;

  OfflineQueue build({int protectedCap = 1000, int softCap = 300}) =>
      OfflineQueue(storage: storage, protectedCap: protectedCap, softCap: softCap, clock: () => now);

  setUp(() {
    storage = MemoryQueueStorage();
    now = DateTime(2026, 11, 7, 12);
    q = build();
  });

  int t(int minutes) => now.add(Duration(minutes: minutes)).millisecondsSinceEpoch;

  test('survives an app kill: a new instance on the same storage sees every item in order', () async {
    await q.enqueue(item('a', QueueKind.chat, at: t(1)));
    await q.enqueue(item('b', QueueKind.checkin, at: t(2)));
    await q.enqueue(item('c', QueueKind.sos, at: t(3)));
    final OfflineQueue reborn = build();
    expect((await reborn.items()).map((QueuedItem i) => i.id).toList(), <String>['a', 'b', 'c']);
    expect(reborn.count.value, 3);
  });

  test('replays in order, SOS first, each item exactly once', () async {
    await q.enqueue(item('m1', QueueKind.chat, at: t(1)));
    await q.enqueue(item('m2', QueueKind.chat, at: t(2)));
    await q.enqueue(item('ci', QueueKind.checkin, at: t(3)));
    await q.enqueue(item('sos', QueueKind.sos, at: t(4)));
    final List<String> sent = <String>[];
    final int n = await q.flush(send: (QueuedItem i) async {
      sent.add(i.id);
      return <String, dynamic>{'id': 'srv-${i.id}'};
    });
    expect(n, 4);
    expect(sent, <String>['sos', 'm1', 'm2', 'ci']);
    expect(await q.size(), 0);
    expect(await q.flush(send: (QueuedItem i) async => fail('nothing is left to send')), 0);
  });

  test('a connection that drops half way keeps the rest; the next run sends only what is left (idempotent replay)', () async {
    for (int i = 1; i <= 4; i++) {
      await q.enqueue(item('m$i', QueueKind.chat, at: t(i)));
    }
    final List<String> delivered = <String>[];
    int calls = 0;
    await q.flush(send: (QueuedItem i) async {
      if (++calls == 3) throw const ApiException(0, 'Could not reach the server.');
      delivered.add(i.id);
    });
    expect(delivered, <String>['m1', 'm2']);
    expect((await q.items()).map((QueuedItem i) => i.id).toList(), <String>['m3', 'm4']);
    await q.flush(send: (QueuedItem i) async => delivered.add(i.id));
    expect(delivered, <String>['m1', 'm2', 'm3', 'm4'], reason: 'no duplicates, order kept');
  });

  test('a 5xx / rate-limit storm never drops anything, however long it lasts', () async {
    await q.enqueue(item('sos', QueueKind.sos, at: t(1)));
    await q.enqueue(item('msg', QueueKind.chat, at: t(2)));
    for (final int status in <int>[500, 502, 503, 504, 429, 408, 0]) {
      for (int i = 0; i < 30; i++) {
        await q.flush(send: (QueuedItem _) async => throw ApiException(status, 'down'));
      }
    }
    expect(await q.size(), 2);
    expect(await q.rejectedCount(), 0);
  });

  test('the server refusing one item for good moves it aside and the rest still go out', () async {
    await q.enqueue(item('bad', QueueKind.chat, at: t(1)));
    await q.enqueue(item('ok', QueueKind.chat, at: t(2)));
    final List<String> sent = <String>[];
    await q.flush(send: (QueuedItem i) async {
      if (i.id == 'bad') throw const ApiException(400, 'message is empty');
      sent.add(i.id);
    });
    expect(sent, <String>['ok']);
    expect(await q.size(), 0);
    expect(await q.rejectedCount(), 1, reason: 'kept visible for Diagnostics, not silently forgotten');
  });

  test('an SOS the server calls "already notified a moment ago" counts as delivered', () async {
    await q.enqueue(item('sos', QueueKind.sos, at: t(1)));
    await q.flush(send: (QueuedItem _) async => throw const ApiException(429, 'wait'));
    expect(await q.size(), 0);
  });

  test('a dead session stops the run and keeps everything for after sign-in', () async {
    await q.enqueue(item('m', QueueKind.chat, at: t(1)));
    await q.flush(send: (QueuedItem _) async => throw const SessionExpiredException());
    expect(await q.size(), 1);
  });

  group('bounds', () {
    test('SOS, check-ins and chat are never dropped for age', () async {
      final int old = now.subtract(const Duration(days: 60)).millisecondsSinceEpoch;
      await q.enqueue(item('sos', QueueKind.sos, at: old));
      await q.enqueue(item('ci', QueueKind.checkin, at: old));
      await q.enqueue(item('chat', QueueKind.chat, at: old));
      await q.enqueue(item('set', QueueKind.setting, at: old, key: 'units'));
      await q.enqueue(item('new', QueueKind.chat, at: t(1)));
      expect((await q.items()).map((QueuedItem i) => i.id).toSet(), <String>{'sos', 'ci', 'chat', 'new'}, reason: 'the 60 day old setting expired');
    });

    test('over the cap the oldest soft item goes, a protected item is refused instead of displacing another', () async {
      final OfflineQueue small = build(protectedCap: 3, softCap: 2);
      for (int i = 0; i < 4; i++) {
        await small.enqueue(item('p$i', QueueKind.place, at: t(i)));
      }
      expect((await small.items()).map((QueuedItem i) => i.id).toList(), <String>['p2', 'p3']);
      expect(await small.enqueue(item('c1', QueueKind.chat)), isTrue);
      expect(await small.enqueue(item('c2', QueueKind.chat)), isTrue);
      expect(await small.enqueue(item('sos', QueueKind.sos)), isTrue);
      expect(await small.enqueue(item('c3', QueueKind.chat)), isFalse);
      expect((await small.items(kind: QueueKind.chat)).map((QueuedItem i) => i.id).toList(), <String>['c1', 'c2']);
      expect((await small.items(kind: QueueKind.sos)).length, 1, reason: 'the SOS is still there');
    });

    test('a newer setting with the same key replaces the older one; the same id twice is stored once', () async {
      await q.enqueue(item('s1', QueueKind.setting, key: 'units', at: t(1)));
      await q.enqueue(item('s2', QueueKind.setting, key: 'units', at: t(2)));
      await q.enqueue(item('s2', QueueKind.setting, key: 'units', at: t(2)));
      expect((await q.items()).map((QueuedItem i) => i.id).toList(), <String>['s2']);
    });
  });

  group('submit', () {
    test('online: sent at once, nothing queued', () async {
      final Submitted r = await q.submit(item('a', QueueKind.chat), send: (QueuedItem _) async => <String, dynamic>{'ok': 1});
      expect(r.queued, isFalse);
      expect(await q.size(), 0);
    });

    test('offline (timeout, refused, 503): queued and reported as not sent yet', () async {
      for (final Object e in <Object>[const ApiException(0, 'timeout'), const ApiException(503, 'x'), http.ClientException('refused')]) {
        final Submitted r = await q.submit(item('a${e.hashCode}', QueueKind.checkin), send: (QueuedItem _) async => throw e);
        expect(r.queued, isTrue, reason: '$e');
      }
      expect(await q.size(), 3);
    });

    test('the server saying no is an error for the screen, not a queued item', () async {
      await expectLater(
        q.submit(item('a', QueueKind.chat), send: (QueuedItem _) async => throw const ApiException(403, 'no')),
        throwsA(isA<ApiException>()),
      );
      expect(await q.size(), 0);
    });

    test('while the server is known to be down nothing waits on a dead connection', () async {
      final Submitted r = await q.submit(item('a', QueueKind.sos),
          send: (QueuedItem _) async => fail('must not even try'), serverKnownDown: () => true);
      expect(r.queued, isTrue);
    });

    test('a chat message waits behind earlier queued ones of the same circle (order)', () async {
      await q.enqueue(item('first', QueueKind.chat, meta: <String, dynamic>{'circle': 'c1'}, at: t(1)));
      final Submitted r = await q.submit(item('second', QueueKind.chat, meta: <String, dynamic>{'circle': 'c1'}),
          send: (QueuedItem _) async => fail('would overtake the first message'));
      expect(r.queued, isTrue);
      final Submitted other = await q.submit(item('x', QueueKind.chat, meta: <String, dynamic>{'circle': 'c2'}),
          send: (QueuedItem _) async => 'sent');
      expect(other.queued, isFalse);
    });

    test('a full queue refuses a new message loudly instead of dropping an old one', () async {
      final OfflineQueue small = build(protectedCap: 1);
      await small.enqueue(item('c1', QueueKind.chat));
      await expectLater(
        small.submit(item('c2', QueueKind.chat, meta: <String, dynamic>{'circle': 'z'}),
            send: (QueuedItem _) async => throw const ApiException(0, 'x')),
        throwsA(isA<QueueFull>()),
      );
      expect((await small.items()).single.id, 'c1');
    });
  });

  test('delivery callbacks get the stored answer (the chat bubble swap)', () async {
    await q.enqueue(item('m', QueueKind.chat));
    final List<dynamic> answers = <dynamic>[];
    q.onDelivered.add((QueuedItem i, dynamic r) => answers.add(<dynamic>[i.id, r]));
    await q.flush(send: (QueuedItem _) async => <String, dynamic>{'id': 'srv'});
    expect(answers.single[0], 'm');
    expect(answers.single[1], <String, dynamic>{'id': 'srv'});
  });

  test('sign-out empties the queue', () async {
    await q.enqueue(item('m', QueueKind.chat));
    await q.clear();
    expect(await build().size(), 0);
  });

  group('over real HTTP (fake transport)', () {
    setUp(() async {
      TokenStorage.resetForTest();
      FlutterSecureStorage.setMockInitialValues(<String, String>{'access_token_v2': 'a', 'refresh_token_v2': 'r'});
      SharedPreferences.setMockInitialValues(<String, Object>{'wb_api_base_url': 'https://example.test'});
      await ServerConfig.instance.load();
      ApiClient.invalidateConfig();
      ApiClient.markSessionActive();
    });

    test('an SOS pressed 10 minutes ago is sent with its client id and says it is late', () async {
      final QueuedItem sos = QueuedItem(
        id: 'sos-1',
        kind: QueueKind.sos,
        method: 'POST',
        path: '/alerts/sos',
        body: <String, dynamic>{'lat': 1.0, 'lon': 2.0, 'client_id': 'sos-1', 'note': 'x' * 400},
        at: now.subtract(const Duration(minutes: 10)).millisecondsSinceEpoch,
      );
      await q.enqueue(sos);
      Map<String, dynamic>? seen;
      await http.runWithClient(() => q.flush(), () => MockClient((http.Request r) async {
            seen = jsonDecode(r.body) as Map<String, dynamic>;
            return http.Response('{"id":"srv"}', 201, headers: <String, String>{'content-type': 'application/json'});
          }));
      expect(seen!['client_id'], 'sos-1');
      expect(seen!['note'] as String, contains('sent late'));
      expect((seen!['note'] as String).length, lessThanOrEqualTo(280), reason: 'the server rejects longer notes; an SOS must not be lost to that');
      expect(await q.size(), 0);
    });

    test('server restarting (502 from the proxy) then back: delivered once, in order', () async {
      await q.enqueue(item('m1', QueueKind.chat, at: t(1)));
      await q.enqueue(item('m2', QueueKind.chat, at: t(2)));
      bool up = false;
      final List<String> got = <String>[];
      final MockClient c = MockClient((http.Request r) async {
        if (!up) return http.Response('<html>Bad gateway</html>', 502);
        got.add(r.url.path);
        return http.Response('{}', 201, headers: <String, String>{'content-type': 'application/json'});
      });
      await http.runWithClient(() async {
        for (int i = 0; i < 5; i++) {
          expect(await q.flush(), 0);
        }
        up = true;
        expect(await q.flush(), 2);
      }, () => c);
      expect(got, <String>['/x/m1', '/x/m2']);
    });
  });
}
