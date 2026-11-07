@Timeout(Duration(minutes: 6))
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/e2ee/add_server_flow.dart';
import 'package:openfamily/services/e2ee/e2ee_api.dart';
import 'package:openfamily/services/e2ee/e2ee_crypto.dart';
import 'package:openfamily/services/e2ee/e2ee_models.dart';
import 'package:openfamily/services/e2ee/lanes_store.dart';
import 'package:openfamily/services/e2ee/lanes_wire.dart';
import 'package:openfamily/services/e2ee/processing_controller.dart';

import 'harness.dart';

// The built-in server participant (docs/design/PRIVACY_PROCESSING.md section 22) against the REAL
// Go server with NO sidecar process and NO ingest token in the environment: the API made its own
// key; Anna's phone approves "Your server wants to join"; Ben taps "Use the server"; Cleo keeps her
// phone. The in-process loop then stores Ben's readable location and never Cleo's.
// Run with: E2E_BUILTIN=1 scripts/e2e-lanes.sh test/e2e_real_server/builtin_e2e_test.dart
// (own invocation: registration rate limits are shared with the other e2e files).

const double bLat = 52.52345, bLon = 13.40123; // Ben: server lane
const double cLat = 41.31415, cLon = 2.17403; // Cleo: phone lane, must never reach the server

void main() {
  final E2eEnv? env = E2eEnv.fromEnvironment();
  if (env == null) {
    test('built-in server device e2e', () {}, skip: 'set E2E_BASE_URL (scripts/e2e-lanes.sh with E2E_BUILTIN=1) to run against a real server');
    return;
  }
  final String stamp = DateTime.now().millisecondsSinceEpoch.toString();
  late Phone a, b, c;
  late String circle;
  late Db db;

  setUpAll(() async {
    await bootstrap(env);
    db = Db(env);
    a = Phone('Anna', 'bi-$stamp-a@example.test', 'correct horse battery');
    b = Phone('Ben', 'bi-$stamp-b@example.test', 'correct horse battery');
    c = Phone('Cleo', 'bi-$stamp-c@example.test', 'correct horse battery');
    for (final Phone p in <Phone>[a, b, c]) {
      await p.signUpAndLogin(env);
      p.startRuntime();
    }
    // Test plumbing: a real install makes the first admin with PLATFORM_ADMIN_EMAIL at start-up.
    await db.query("UPDATE users SET platform_admin = TRUE WHERE id = '${a.userId}' RETURNING 1");
    final Map<String, dynamic> created = await rawJson(env, 'POST', '/circles', body: <String, dynamic>{'name': 'Builtin private'}, token: a.token);
    circle = (created['id'] ?? (created['circle'] as Map<String, dynamic>)['id']) as String;
    final Map<String, dynamic> inv = await rawJson(env, 'POST', '/circles/$circle/invites', body: <String, dynamic>{'role': 'member', 'max_uses': 10, 'expires_in_hours': 24}, token: a.token);
    final String code = (inv['code'] ?? (inv['invite'] as Map<String, dynamic>)['code']) as String;
    for (final Phone p in <Phone>[b, c]) {
      await rawJson(env, 'POST', '/circles/join', body: <String, dynamic>{'code': code}, token: p.token);
    }
    for (final Phone p in <Phone>[a, b, c]) {
      await p.run(() => p.service.registerThisDevice());
    }
    await a.run(() => a.service.enableCircle(circle));
    await b.run(() => b.service.syncCircleKeys(circle));
    await c.run(() => c.service.syncCircleKeys(circle));
    for (final Phone p in <Phone>[a, b, c]) {
      await p.syncCircle(circle);
    }
  });

  test('the server asks to join on its own; only the server admin gets the request', () async {
    final ServerJoinInfo forB = await b.run(() => const ApiE2eeApi().serverJoin());
    expect(forB.builtin, isTrue, reason: 'the API made its own server device (no sidecar, no token)');
    expect(forB.waiting, isTrue);
    expect(forB.canApprove, isFalse);
    expect(forB.requestCode, isEmpty);
    final ServerJoinInfo forA = await a.run(() => const ApiE2eeApi().serverJoin());
    expect(forA.waiting && forA.canApprove, isTrue, reason: 'Anna is the server admin');
    expect(forA.short.split(' ').length, 4);
    expect(await db.count("SELECT count(*) FROM e2ee_server_device"), 0);
  });

  test('Anna compares the code and approves; the server pins its own key; no sidecar involved', () async {
    final AddServerFlow flow = AddServerFlow(LanesProcessingController(a.lanes));
    final AddServerPlan plan = await a.run(() => flow.plan(circle));
    expect(plan.state, AddServerState.approveServer);
    final ServerJoinInfo j = await a.run(() => const ApiE2eeApi().serverJoin());
    expect(plan.words, j.short);
    await a.run(() => flow.confirm(circle, plan));
    expect(await db.count("SELECT count(*) FROM e2ee_server_device"), 1);
    expect(await db.count("SELECT count(*) FROM device_keys WHERE kind = 'server' AND revoked_at IS NULL"), 1);
    final ServerJoinInfo after = await a.run(() => const ApiE2eeApi().serverJoin());
    expect(after.waiting, isFalse);
    final ProcessingServerState proc = await a.run(() => const ApiE2eeApi().processingState(circle));
    expect(proc.serverAssist, isTrue);
  });

  test('Ben taps "Use the server" (his own signed lane); Cleo does nothing', () async {
    final AddServerFlow flow = AddServerFlow(LanesProcessingController(b.lanes));
    final AddServerPlan plan = await b.run(() => flow.plan(circle));
    expect(plan.state, AddServerState.ready);
    await b.run(() => flow.confirm(circle, plan));
    await a.run(() => a.lanes.maintain(circle));
    expect(await c.run(() => c.store.status(circle)), isNot(LaneStatus.serverAssisted));
  });

  test('the in-process server device stores Ben\'s readable location and never Cleo\'s', () async {
    expect(await b.sendFix(bLat, bLon), 1);
    expect(await c.sendFix(cLat, cLon), 1);
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 90));
    while (await db.userRowsNear(b.userId, bLat, bLon) == 0 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    expect(await db.userRowsNear(b.userId, bLat, bLon), greaterThan(0), reason: 'the built-in loop never delivered Ben\'s fix');
    expect(await db.locationsOf(c.userId), 0);
    expect(await db.positionRows(c.userId), 0);
    expect(await db.anyRowNear(cLat, cLon), 0);
    expect(E2ee.hex(List<int>.filled(1, 0)), isNotEmpty);
  });
}
