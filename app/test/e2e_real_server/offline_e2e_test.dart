@Timeout(Duration(minutes: 6))
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:openfamily/services/api_client.dart';
import 'package:openfamily/services/offline/offline_queue.dart';

import 'harness.dart';

// Offline-first against the REAL server (docs/design/OFFLINE_RESILIENCE.md): the server container is
// stopped while two phones keep acting, then started again. Everything the phones did arrives exactly
// once and in order. scripts/e2e-lanes.sh provides the control channel (E2E_CTL_DIR) that stops and
// starts the container; run it on its own:
//   scripts/e2e-lanes.sh test/e2e_real_server/offline_e2e_test.dart

Future<void> serverCtl(String cmd) async {
  final String dir = Platform.environment['E2E_CTL_DIR'] ?? '';
  if (dir.isEmpty) throw StateError('E2E_CTL_DIR is not set: run through scripts/e2e-lanes.sh');
  final File ack = File('$dir/ack');
  if (ack.existsSync()) ack.deleteSync();
  File('$dir/request').writeAsStringSync(cmd);
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 120));
  while (!ack.existsSync()) {
    if (DateTime.now().isAfter(deadline)) throw StateError('control channel: no answer to "$cmd"');
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  ack.deleteSync();
}

void main() {
  final E2eEnv? env = E2eEnv.fromEnvironment();
  if (env == null || (Platform.environment['E2E_CTL_DIR'] ?? '').isEmpty) {
    test('real-server offline e2e', () {}, skip: 'run through scripts/e2e-lanes.sh (needs E2E_BASE_URL and E2E_CTL_DIR)');
    return;
  }

  final String stamp = DateTime.now().millisecondsSinceEpoch.toString();
  late Phone a, b;
  late String circle;
  late Db db;

  QueuedItem chat(String id, String text) => QueuedItem(
        id: id,
        kind: QueueKind.chat,
        method: 'POST',
        path: '/circles/$circle/chat',
        body: <String, dynamic>{'body': text, 'client_id': id},
        meta: <String, dynamic>{'circle': circle},
      );

  setUpAll(() async {
    await bootstrap(env);
    db = Db(env);
    a = Phone('Anna', 'off-$stamp-a@example.test', 'correct horse battery');
    b = Phone('Ben', 'off-$stamp-b@example.test', 'correct horse battery');
    for (final Phone p in <Phone>[a, b]) {
      await p.signUpAndLogin(env);
    }
    final Map<String, dynamic> created = await rawJson(env, 'POST', '/circles', body: <String, dynamic>{'name': 'Offline e2e'}, token: a.token);
    circle = (created['id'] ?? (created['circle'] as Map<String, dynamic>)['id']) as String;
    final Map<String, dynamic> inv = await rawJson(env, 'POST', '/circles/$circle/invites',
        body: <String, dynamic>{'role': 'member', 'max_uses': 5, 'expires_in_hours': 24}, token: a.token);
    final String code = (inv['code'] ?? (inv['invite'] as Map<String, dynamic>)['code']) as String;
    await rawJson(env, 'POST', '/circles/join', body: <String, dynamic>{'code': code}, token: b.token);
  });

  tearDownAll(() async {
    // Never leave the stack stopped.
    try {
      await serverCtl('start');
    } catch (_) {}
  });

  test('the server stops mid-test: phones keep queuing, nothing is lost, and after the restart everything arrives once and in order', () async {
    final OfflineQueue q = OfflineQueue(storage: MemoryQueueStorage());

    // 1. Online: a message goes straight through.
    final Submitted first = await a.run(() => q.submit(chat('off-$stamp-m0', 'before the outage')));
    expect(first.queued, isFalse);

    // 2. The server container is stopped.
    await serverCtl('stop');
    await expectLater(a.run(() => ApiClient.healthz()), throwsA(isA<ApiException>()));

    // 3. Phones keep acting. Nothing throws, everything is saved on the phone.
    final List<Submitted> offline = <Submitted>[
      await a.run(() => q.submit(chat('off-$stamp-m1', 'one'))),
      await a.run(() => q.submit(chat('off-$stamp-m2', 'two'))),
      await a.run(() => q.submit(chat('off-$stamp-m3', 'three'))),
      await a.run(() => q.submit(QueuedItem(
            id: 'off-$stamp-ci',
            kind: QueueKind.checkin,
            method: 'POST',
            path: '/checkins',
            body: <String, dynamic>{'recipient_ids': <String>[b.userId], 'note': 'home', 'client_id': 'off-$stamp-ci', 'lat': 52.5, 'lon': 13.4},
          ))),
      await a.run(() => q.submit(QueuedItem(
            id: 'off-$stamp-sos',
            kind: QueueKind.sos,
            method: 'POST',
            path: '/alerts/sos',
            body: <String, dynamic>{'lat': 52.5, 'lon': 13.4, 'client_id': 'off-$stamp-sos'},
          ))),
    ];
    expect(offline.every((Submitted s) => s.queued), isTrue);
    expect(await q.size(), 5);
    // A storm of failed flushes loses nothing.
    for (int i = 0; i < 5; i++) {
      expect(await a.run(() => q.flush()), 0);
    }
    expect(await q.size(), 5);
    // The queue survives a "kill": a new instance on the same storage.
    q.forgetMemory();

    // 4. The server comes back.
    await serverCtl('start');
    await a.run(() => ApiClient.healthz());
    expect(await a.run(() => q.flush()), 5);
    expect(await q.size(), 0);

    // 5. A replay whose answer was lost (same client ids) changes nothing.
    await a.run(() => q.submit(chat('off-$stamp-m2', 'two')));
    await a.run(() => q.submit(chat('off-$stamp-m3', 'three')));
    final Submitted ciAgain = await a.run(() => q.submit(QueuedItem(
          id: 'off-$stamp-ci',
          kind: QueueKind.checkin,
          method: 'POST',
          path: '/checkins',
          body: <String, dynamic>{'recipient_ids': <String>[b.userId], 'note': 'home', 'client_id': 'off-$stamp-ci', 'lat': 52.5, 'lon': 13.4},
        )));
    final Submitted sosAgain = await a.run(() => q.submit(QueuedItem(
          id: 'off-$stamp-sos',
          kind: QueueKind.sos,
          method: 'POST',
          path: '/alerts/sos',
          body: <String, dynamic>{'lat': 52.5, 'lon': 13.4, 'client_id': 'off-$stamp-sos'},
        )));
    expect(ciAgain.queued, isFalse);
    expect(sosAgain.queued, isFalse);

    // 6. The database holds each exactly once, the messages in the order they were written.
    final List<List<dynamic>> rows = await db.query(
        "SELECT body FROM chat_messages WHERE circle_id = '$circle' AND sender_id = '${a.userId}' ORDER BY seq");
    expect(rows.map((List<dynamic> r) => r[0]).toList(), <String>['before the outage', 'one', 'two', 'three']);
    expect(await db.count("SELECT count(*) FROM checkins WHERE user_id = '${a.userId}' AND client_id = 'off-$stamp-ci'"), 1);
    expect(await db.count("SELECT count(*) FROM alerts WHERE user_id = '${a.userId}' AND type = 'sos' AND client_id = 'off-$stamp-sos'"), 1);

    // 7. Ben sees it through the normal API.
    final http.Response res = await b.run(() async => http.get(Uri.parse('$kPretendBase/circles/$circle/chat')));
    expect(res.statusCode, 200);
    expect(res.body, contains('three'));
  });
}
