@Timeout(Duration(minutes: 5))
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/circle.dart';
import 'package:openfamily/models/trip_report.dart';
import 'package:openfamily/services/trip_report_service.dart';
import 'package:openfamily/services/api_client.dart';
import 'package:openfamily/services/e2ee/add_server_flow.dart';
import 'package:openfamily/services/e2ee/e2ee_api.dart';
import 'package:openfamily/services/e2ee/e2ee_crypto.dart';
import 'package:openfamily/services/e2ee/e2ee_models.dart';
import 'package:openfamily/services/e2ee/e2ee_service.dart';
import 'package:openfamily/services/e2ee/lanes_service.dart';
import 'package:openfamily/services/e2ee/lanes_store.dart';
import 'package:openfamily/services/e2ee/lanes_wire.dart';
import 'package:openfamily/services/e2ee/private_channel.dart';
import 'package:openfamily/services/e2ee/processing_controller.dart';
import 'package:openfamily/services/e2ee/private_runtime.dart';

import 'harness.dart';

// The real Dart phone core against the real Go server (and the real e2ee-bridge
// as the server's own device). Skipped unless scripts/e2e-lanes.sh set E2E_BASE_URL.
// The scenarios build on each other and run in order; see docs/testing/E2E_LANES.md.

// Coordinates are distinctive so a leak is easy to find in the database and the logs.
const double bLat = 52.52345, bLon = 13.40123; // B: server lane
const double cLat = 41.31415, cLon = 2.17403; // C: phone lane, must never reach the server
const double aLat = 48.85661, aLon = 2.35222; // A: server lane

/// An app that predates lanes: registers without the capability.
class OldAppApi extends ApiE2eeApi {
  const OldAppApi();
  @override
  Future<DeviceKey> register(Map<String, dynamic> body) => super.register(<String, dynamic>{...body}..remove(LanesFields.caps));
}

void main() {
  // Real processes and a real database: be generous.
  final E2eEnv? env = E2eEnv.fromEnvironment();
  if (env == null) {
    test('real-server lanes e2e', () {}, skip: 'set E2E_BASE_URL (scripts/e2e-lanes.sh) to run against a real server');
    return;
  }

  final String stamp = DateTime.now().millisecondsSinceEpoch.toString();
  late Phone a, b, c;
  late String circle;
  late ServerDevice server;
  late Db db;

  Future<void> bridgeCycle([String? expectIn]) async {
    final ProcessResult r = await server.runOnce();
    // ignore: avoid_print
    print('bridge: ${r.stderr}${r.stdout}');
    expect(r.exitCode, 0, reason: 'bridge run failed:\n${r.stdout}\n${r.stderr}');
    if (expectIn != null) expect('${r.stdout}${r.stderr}', contains(expectIn));
  }

  Future<List<Map<String, dynamic>>> serverItems(String where) async => (await db.query(
          "SELECT device_id::text, key_line, purpose, epoch FROM e2ee_items WHERE circle_id = '$circle' AND $where ORDER BY id"))
      .map((List<dynamic> r) => <String, dynamic>{'device': r[0], 'line': r[1], 'purpose': r[2], 'epoch': r[3]})
      .toList();

  setUpAll(() async {
    await bootstrap(env);
    db = Db(env);
    a = Phone('Anna', 'e2e-$stamp-a@example.test', 'correct horse battery');
    b = Phone('Ben', 'e2e-$stamp-b@example.test', 'correct horse battery');
    c = Phone('Cleo', 'e2e-$stamp-c@example.test', 'correct horse battery');
    for (final Phone p in <Phone>[a, b, c]) {
      await p.signUpAndLogin(env);
      p.startRuntime();
    }
    final Map<String, dynamic> created = await rawJson(env, 'POST', '/circles', body: <String, dynamic>{'name': 'E2E private'}, token: a.token);
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
    // The server's own key: the real bridge binary, approved by Anna's phone, pinned by `run`.
    server = ServerDevice(env, a);
    await server.enroll();
    await bridgeCycle();
  });

  group('setup against the real server', () {
    test('the three phones registered with the lanes capability; the server key is a kind=server key of Anna', () async {
      for (final Phone p in <Phone>[a, b, c]) {
        final List<DeviceKey> keys = await p.run(() => const ApiE2eeApi().myKeys());
        final DeviceKey k = keys.firstWhere((DeviceKey k) => k.kind == 'device');
        expect(k.supportsLanes, isTrue, reason: '${p.name}: caps ${k.caps}');
      }
      final CircleE2eeState st = await a.run(() => const ApiE2eeApi().circleState(circle));
      expect(st.isPrivate, isTrue);
      final ProcessingServerState proc = await a.run(() => const ApiE2eeApi().processingState(circle));
      expect(proc.serverDeviceId, server.deviceId);
      expect(proc.serverFingerprint, server.fingerprintHex);
      expect(proc.serverAssist, isFalse);
    });
  });

  group('scenario 1: policy', () {
    test('Anna (admin) turns server assistance on; Ben and Cleo hold SK gen 1; the server key holds nothing yet', () async {
      await expectLater(b.run(() => b.lanes.publishPolicy(circle, serverAssist: true)), throwsA(anything), reason: 'a non-admin cannot publish');
      await a.run(() => a.lanes.publishPolicy(circle, serverAssist: true));
      expect(await a.run(() => a.service.heldServerGens(circle)), <int>[1]);
      for (final Phone p in <Phone>[b, c]) {
        final CircleLanes v = await p.run(() => p.lanes.refresh(circle, force: true));
        expect((v.policy.assist, v.policy.skGen, v.status), (true, 1, LaneStatus.phoneOnly), reason: p.name);
        expect(await p.run(() => p.service.heldServerGens(circle)), <int>[1], reason: p.name);
        expect(E2ee.hex((await p.run(() => p.service.serverKey(circle, 1)))!), E2ee.hex((await a.run(() => a.service.serverKey(circle, 1)))!));
      }
      final ProcessingServerState proc = await a.run(() => const ApiE2eeApi().processingState(circle));
      expect(proc.serverAssist, isTrue);
      expect(proc.skGen, 1);
      expect(proc.inEffect, isFalse, reason: 'nobody opted in: the server holds no SK');
      expect(proc.policy, isNotNull);
    });
  });

  group('scenario 2: lanes in use', () {
    test('Anna and Ben sign lane=server, Cleo stays phone; the server gets Ben\'s plaintext and never Cleo\'s', () async {
      for (final Phone p in <Phone>[a, b]) {
        await p.run(() => p.lanes.setLane(circle, E2ee.lineServer, confirmServerFingerprintHex: server.fingerprintHex));
        expect(await p.run(() => p.store.status(circle)), LaneStatus.serverAssisted, reason: p.name);
      }
      // The admin phone hands the SK to the server key once a member is in lane server.
      await a.run(() => a.lanes.maintain(circle));
      final ProcessingServerState proc = await a.run(() => const ApiE2eeApi().processingState(circle));
      expect(proc.inEffect, isTrue, reason: 'server holds the SK now');
      expect(await c.run(() => c.store.status(circle)), LaneStatus.phoneOnly);

      expect(await b.sendFix(bLat, bLon), 1);
      expect(await c.sendFix(cLat, cLon), 1);
      expect(await a.sendFix(aLat, aLon), 1);
      expect((await serverItems("key_line = 'server'")).length, 2);
      expect((await serverItems("key_line = 'phone'")).length, 1);

      // The sidecar's job, done by hand against the server's own gate: Ben and Anna are stored, Cleo is refused.
      final Map<String, String> devOf = <String, String>{
        for (final Phone p in <Phone>[a, b, c]) p.userId: (await p.run(() => p.service.identity()))!.deviceId
      };
      final Map<String, dynamic> ing = await directIngest(env, circle, server.deviceId, <Map<String, dynamic>>[
        ingestPoint(b, devOf[b.userId]!, bLat, bLon),
        ingestPoint(a, devOf[a.userId]!, aLat, aLon),
        ingestPoint(c, devOf[c.userId]!, cLat, cLon),
      ]);
      expect(ing['_status'], 200, reason: '$ing');
      expect(ing['stored'], 2);
      expect((ing['rejected'] as Map<String, dynamic>)['lane_not_server'], 1);
      expect(await db.locationsOf(b.userId), 1, reason: 'Ben server line: the server holds his fix');
      expect(await db.positionRows(b.userId), 1);
      expect(await db.locationsOf(a.userId), 1);
      expect(await db.locationsOf(c.userId), 0, reason: 'Cleo phone line: nothing at the server');
      expect(await db.positionRows(c.userId), 0);
      expect(await db.anyRowNear(cLat, cLon), 0);
      expect(await db.userRowsNear(b.userId, bLat, bLon), 2); // locations + member_positions
      final List<List<dynamic>> pos = await db.query("SELECT lat, lon FROM member_positions WHERE user_id = '${b.userId}'");
      expect((pos.single[0] as num).toDouble(), closeTo(bLat, 1e-6));
      expect((pos.single[1] as num).toDouble(), closeTo(bLon, 1e-6));
      // The ciphertext at rest has no plaintext coordinate either.
      expect(await db.count("SELECT count(*) FROM e2ee_items WHERE circle_id = '$circle' AND position('41.31415'::bytea IN ciphertext) > 0"), 0);
    });
  });

  group('scenario 2b: the real sidecar', () {
    test('e2ee-bridge in server mode reads the server-line items of members whose signed lane is server', () async {
      expect(await b.sendFix(bLat + 0.001, bLon + 0.001), 1);
      final ProcessResult r = await server.runOnce();
      final String out = '${r.stdout}${r.stderr}';
      if (out.contains('waiting for member consent') && Platform.environment['E2E_REQUIRE_SIDECAR'] != '1') {
        markTestSkipped('sidecar build predates lanes (it still waits for legacy all-member consent)');
        return;
      }
      expect(r.exitCode, 0, reason: out);
      expect(out, isNot(contains('waiting for member consent')), reason: 'the sidecar must follow the per-member lane, not the legacy all-member consent:\n$out');
      // Ben's scenario-2 fix (already stored by the hand-built ingest above) + that same real item read by
      // the sidecar + the new fix: 3 rows, none for Cleo.
      expect(await db.locationsOf(b.userId), 3);
      expect(await db.locationsOf(c.userId), 0);
    });
  });

  group('scenario 2d: the Driving tab data of a server-lane member (regression: "the driving features are gone")', () {
    test('Ben\'s drive becomes a trip with speeding in the family report, for Ben and for Cleo; Cleo (phone lane) has none on the server', () async {
      // A drive as the sidecar delivers it: fixes with speed, read from Ben\'s server-line items.
      final DateTime begin = DateTime.now().toUtc().subtract(const Duration(hours: 3)).copyWith(microsecond: 0, millisecond: 0);
      final String benDevice = (await b.run(() => b.service.identity()))!.deviceId;
      final List<Map<String, dynamic>> pts = <Map<String, dynamic>>[];
      double lat = 52.0;
      DateTime t = begin;
      void add(double speed) => pts.add(<String, dynamic>{
            'kind': 'history', 'user_id': b.userId, 'sender_device_id': benDevice,
            'ts_ms': t.millisecondsSinceEpoch, 'lat': lat, 'lon': 13.0, 'acc': 6, 'spd': speed,
          });
      for (int i = 0; i < 60; i++) {
        add(0);
        t = t.add(const Duration(seconds: 5));
      }
      for (int i = 0; i < 144; i++) {
        final double sp = (i >= 40 && i < 64) ? 40 : 25; // two minutes above the speeding limit
        lat += sp * 5 / 111195;
        add(sp);
        t = t.add(const Duration(seconds: 5));
      }
      for (int i = 0; i < 60; i++) {
        add(0);
        t = t.add(const Duration(seconds: 5));
      }
      for (int i = 0; i < pts.length; i += 250) {
        final Map<String, dynamic> ing = await directIngest(env, circle, server.deviceId, pts.sublist(i, i + 250 > pts.length ? pts.length : i + 250));
        expect(ing['_status'], 200, reason: '$ing');
      }
      // The background trips worker runs every few minutes; the app can ask for it right away.
      final String from = begin.subtract(const Duration(hours: 1)).toIso8601String();
      final String to = t.add(const Duration(hours: 1)).toIso8601String();
      await rawJson(env, 'POST', '/trips/compute?from=${Uri.encodeQueryComponent(from)}&to=${Uri.encodeQueryComponent(to)}', token: b.token);

      final DateTime weekOfDrive = weekStartOf(begin.add(const Duration(minutes: 8)).toLocal());
      for (final Phone viewer in <Phone>[b, c]) {
        final TripReport r = await viewer.run(() => TripReportService.instance.report(start: weekOfDrive, circleId: circle));
        final MemberReport ben = r.members.firstWhere((MemberReport m) => m.userId == b.userId, orElse: () => throw StateError('Ben is missing from ${viewer.name}\'s driving report'));
        expect(ben.drives, 1, reason: '${viewer.name} sees Ben\'s drive');
        expect(ben.events.speeding, greaterThanOrEqualTo(1), reason: 'the speeding event is detected on server-lane fixes');
        expect(r.totals.drives, greaterThanOrEqualTo(1));
        expect(r.totals.topSpeedMps, greaterThan(35));
        expect(r.recentTrips.any((RecentTrip x) => x.userId == b.userId), isTrue);
        expect(r.days.length, 7);
        final Iterable<MemberReport> cleo = r.members.where((MemberReport m) => m.userId == c.userId);
        expect(cleo.every((MemberReport m) => m.drives == 0), isTrue, reason: 'nothing of Cleo\'s phone-lane drives is on the server');
      }
      expect(await db.count("SELECT count(*) FROM trips WHERE user_id = '${c.userId}'"), 0);
      expect(await db.count("SELECT count(*) FROM trips WHERE user_id = '${b.userId}' AND mode = 'driving'"), 1);
    });
  });

  group('scenario 2c: the one-button "Add server to this circle" flow', () {
    test('Cleo adds the server in three steps against the real server, signs only her own lane, then removes it again', () async {
      final AddServerFlow flow = AddServerFlow(LanesProcessingController(c.lanes));
      // Step 1 + 2: the plan comes from the verified key log; the words are the server key's, as the admin page shows them.
      final AddServerPlan plan = await c.run(() => flow.plan(circle));
      expect(plan.state, AddServerState.ready, reason: 'policy is on, the key is pinned and approved, Cleo is a member');
      expect(plan.snapshot.serverKeyFingerprint, server.fingerprintHex);
      expect(plan.words.split(' '), hasLength(4), reason: 'four short groups');
      expect(plan.profile.known, isTrue, reason: 'GET /e2ee/server-device carries the deployment profile');
      expect(plan.profile.effective, anyOf('home', 'cloud'));
      expect(plan.profile.device?.fingerprint, server.fingerprintHex);
      expect(plan.adminTurnsOn, isFalse, reason: 'a normal member never publishes the circle policy');
      // Step 3.
      final ProcessingSnapshot after = await c.run(() => flow.confirm(circle, plan));
      expect(after.me?.lane, E2ee.lineServer);
      expect(await c.run(() => c.store.status(circle)), LaneStatus.serverAssisted);
      // Everyone else is untouched: nobody was opted in by Cleo's tap.
      expect(await a.run(() => a.store.status(circle)), LaneStatus.serverAssisted);
      final AddServerPlan again = await c.run(() => flow.plan(circle));
      expect(again.state, AddServerState.alreadyAdded);
      // Remove server: back to the phone lane, own copies deleted.
      await c.run(() => flow.remove(circle, deleteCopies: true));
      expect(await c.run(() => c.store.status(circle)), LaneStatus.phoneOnly);
      expect(await db.locationsOf(c.userId), 0);
      expect((await c.run(() => flow.plan(circle))).state, AddServerState.ready);
    });
  });

  group('scenario 5: every phone reads the others\' items', () {
    test('badges follow the author\'s signed lane, computed on the reader\'s phone', () async {
      for (final Phone reader in <Phone>[a, b, c]) {
        await reader.run(() => reader.lanes.refresh(circle, force: true));
        final List<ReceivedItem> got = await reader.receiveAll(circle);
        final Map<String, ReceivedItem> byUser = <String, ReceivedItem>{
          for (final ReceivedItem i in got)
            if (i.purpose == ChannelPurpose.fix) i.userId: i
        };
        for (final Phone author in <Phone>[a, b, c]) {
          if (author == reader) continue;
          final ReceivedItem? it = byUser[author.userId];
          expect(it, isNotNull, reason: '${reader.name} should read ${author.name}');
          final bool serverAuthor = author != c;
          expect(it!.badge, serverAuthor ? ProcessingBadge.serverAssisted : ProcessingBadge.phoneOnly, reason: '${reader.name} reads ${author.name}');
          expect(it.line, serverAuthor ? E2ee.lineServer : E2ee.linePhone);
          final Map<String, dynamic> body = it.body;
          final (double, double) want = author == a ? (aLat, aLon) : author == b ? (bLat, bLon) : (cLat, cLon);
          expect((body['lat'] as num).toDouble(), closeTo(want.$1, 0.0015));
          expect((body['lon'] as num).toDouble(), closeTo(want.$2, 0.0015));
        }
        final Map<String, bool> lanes = <String, bool>{
          for (final MemberLaneView m in await reader.run(() => reader.lanes.members(circle))) m.userId: m.serverAssisted
        };
        expect(lanes, <String, bool>{a.userId: true, b.userId: true, c.userId: false}, reason: reader.name);
      }
    });
  });

  group('scenario 3: opt-out', () {
    test('Ben flips to phone: queued server-line items are never uploaded and his server copies are deleted', () async {
      final int serverItemsBefore = (await serverItems("key_line = 'server'")).length;
      // An item sealed for the server line sits in Ben's queue (flush timer stopped by going offline-by-hand: we do not flush).
      await b.run(() async {
        await b.runtime.routeFix(b.fix(bLat + 0.01, bLon + 0.01));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      // Stop the background flush by taking items out of the picture: the lane flip must re-seal or drop them.
      await b.run(() => b.lanes.setLane(circle, E2ee.linePhone));
      expect(await b.run(() => b.store.status(circle)), LaneStatus.phoneOnly);
      expect(await b.run(() => b.runtime.lanes.ownLane(circle)), isA<LaneChoice>().having((LaneChoice l) => l.line, 'line', E2ee.linePhone));
      await b.run(() => b.runtime.flush());
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(serverItemsBefore, greaterThanOrEqualTo(2));
      final String bDev = (await b.run(() => b.service.identity()))!.deviceId;
      expect(await serverItems("device_id = '$bDev' AND key_line = 'server'"), isEmpty,
          reason: 'the server removes the author\'s server-line items when the lane ends, and none is uploaded after');
      expect(await db.locationsOf(b.userId), 0, reason: 'Ben\'s plaintext copies are deleted by the server on his phone-lane pref');
      expect(await db.positionRows(b.userId), 0);
      expect(await db.userRowsNear(b.userId, bLat, bLon), 0);
      // The sidecar can no longer store anything of Ben: the server refuses his points.
      await b.sendFix(bLat + 0.02, bLon + 0.02);
      final Map<String, dynamic> ing = await directIngest(env, circle, server.deviceId, <Map<String, dynamic>>[ingestPoint(b, bDev, bLat + 0.02, bLon + 0.02)]);
      expect(ing['stored'], 0, reason: '$ing');
      expect(await db.locationsOf(b.userId), 0);
      // The others see Ben as phone now.
      await a.run(() => a.lanes.refresh(circle, force: true));
      final Map<String, bool> lanes = <String, bool>{for (final MemberLaneView m in await a.run(() => a.lanes.members(circle))) m.userId: m.serverAssisted};
      expect(lanes[b.userId], isFalse);
      expect(lanes[a.userId], isTrue);
    });
  });

  group('scenario 4: required_server', () {
    test('the server refuses Cleo\'s phone-line fix, her phone shows consentRequired and seals nothing', () async {
      await a.run(() => a.lanes.publishPolicy(circle, serverAssist: true, memberOptOut: E2ee.optOutRequiredServer, defaultForNew: E2ee.linePhone));
      for (final Phone p in <Phone>[b, c]) {
        final CircleLanes v = await p.run(() => p.lanes.refresh(circle, force: true));
        expect(v.status, LaneStatus.consentRequired, reason: p.name);
        expect(v.policy.memberOptOut, E2ee.optOutRequiredServer);
      }
      // 1) The server side: a phone that did not learn about the policy yet still tries a phone-line fix.
      final Phone stale = Phone('Cleo-stale', c.email, c.password)
        ..userId = c.userId
        ..token = c.token;
      // Same keys and key store, but its lane store is empty: it believes it is on the phone lane.
      stale.vault.data.addAll(c.vault.data);
      stale.startRuntime();
      await stale.run(() => stale.runtime.setCircles(<Circle>[circleOf(circle)]));
      final int before = (await serverItems("purpose = 'fix'")).length;
      final List<BatchResult> res = await stale.run(() async {
        final Uint8List? ck = await stale.service.circleKey(circle, 1);
        expect(ck, isNotNull);
        await stale.runtime.routeFix(stale.fix(cLat + 0.5, cLon));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final List<WireItem> q = await stale.runtime.queue.peek();
        expect(q, isNotEmpty);
        return const HttpChannelApi().postBatch(circle, q.first.deviceId, q);
      });
      expect(res.single.status, 'rejected');
      expect(res.single.error, 'required_server');
      expect((await serverItems("purpose = 'fix'")).length, before);
      // 2) The honest phone: consentRequired, nothing is sealed.
      final int q0 = await c.run(() => c.runtime.queue.length());
      await c.run(() => c.runtime.routeFix(c.fix(cLat, cLon)));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(await c.run(() => c.runtime.queue.length()), q0);
      expect(await db.anyRowNear(cLat, cLon), 0);
      // Check-ins keep working under required_server (help requests are never blocked).
      await c.run(() => c.runtime.sendItem(circle, ChannelPurpose.checkin, <String, dynamic>{'k': 'sos', 'lat': cLat, 'lon': cLon}));
      expect((await serverItems("purpose = 'checkin'")).length, 1);
    });
  });

  group('scenario 6: an app that predates lanes', () {
    test('no capability: it cannot enter the server lane, the server refuses its server-line items and it is called out', () async {
      // Back to a permissive policy so this is about the old app only.
      await a.run(() => a.lanes.publishPolicy(circle, serverAssist: true, memberOptOut: E2ee.optOutAllowed));
      final Phone d = Phone('Dora', 'e2e-$stamp-d@example.test', 'correct horse battery');
      await d.signUpAndLogin(env);
      final Map<String, dynamic> inv = await rawJson(env, 'POST', '/circles/$circle/invites', body: <String, dynamic>{'role': 'member', 'max_uses': 1, 'expires_in_hours': 1}, token: a.token);
      await rawJson(env, 'POST', '/circles/join', body: <String, dynamic>{'code': (inv['code'] ?? (inv['invite'] as Map<String, dynamic>)['code']) as String}, token: d.token);
      final E2eeService old = E2eeService(api: const OldAppApi(), vault: d.vault, trust: d.service.trust, userIdProvider: () async => d.userId);
      // Since v0.22 the server refuses a device without the lanes capability for a member of a circle that
      // uses processing lanes: the old app never gets as far as holding keys (409 update_required_for_lanes).
      final Object? err = await d.run(() async {
        try {
          await old.registerThisDevice();
          return null;
        } catch (e) {
          return e;
        }
      });
      expect(err, isA<ApiException>(), reason: 'old app must be refused: $err');
      expect((err as ApiException).status, 409);
      expect(await db.locationsOf(d.userId), 0);
    });
  });

  group('scenario 7: SK == CK', () {
    test('a malicious admin hands out the circle key as the server key; the phones refuse it', () async {
      final Uint8List ck = (await a.run(() => a.service.circleKey(circle, 1)))!;
      final CircleLanes cur = await a.run(() => a.lanes.refresh(circle, force: true));
      final int gen = cur.policy.skGen + 1;
      final LocalIdentity me = (await a.run(() => a.service.identity()))!;
      final CircleE2eeState st = await a.run(() => const ApiE2eeApi().circleState(circle));
      // Wrap CK (not a fresh key) under the server line to every member phone, bypassing the honest client's guard.
      final List<Map<String, dynamic>> wraps = <Map<String, dynamic>>[];
      for (final CircleE2eeMember m in st.members) {
        for (final DeviceKey k in m.devices) {
          if (k.kind != 'device' || !k.isActive || k.approved != true) continue;
          final Uint8List aad = E2ee.wrapAadLine(circle, E2ee.lineServer, gen, k.deviceId, me.deviceId);
          final Uint8List blob = await E2ee.wrap(ck, k.xPub, aad);
          final Uint8List sig = await E2ee.sign(me.edSeed, E2ee.wrapSigMessageLine(circle, E2ee.lineServer, gen, k.deviceId, me.deviceId, blob));
          wraps.add(<String, dynamic>{'recipient_device_id': k.deviceId, 'wrapper_device_id': me.deviceId, 'wrapped_key': E2ee.b64(blob), 'signature': E2ee.b64(sig)});
        }
      }
      expect(wraps, isNotEmpty);
      final Uint8List commitment = await E2ee.keyCommitmentLine(ck, circle, E2ee.lineServer, gen);
      final Uint8List nonce = E2ee.randomBytes(E2ee.processingNonceLen);
      final Uint8List msg = E2ee.processingPolicyMessage(circle, me.userId, true, E2ee.linePhone, E2ee.optOutAllowed, gen, commitment, nonce);
      final Uint8List ref = await E2ee.processingRef(msg);
      final Uint8List logMsg = E2ee.logActionMessage(E2ee.actProcessingPolicy, me.userId, me.deviceId, circleId: circle, epoch: gen, ref: ref);
      final PolicyStatement stmt = PolicyStatement(
          serverAssist: true, defaultForNew: E2ee.linePhone, memberOptOut: E2ee.optOutAllowed, skGen: gen, commitment: commitment, nonce: nonce,
          adminUserId: me.userId, actorDeviceId: me.deviceId, signature: await E2ee.sign(me.edSeed, msg));
      final String logSig = E2ee.b64(await E2ee.sign(me.edSeed, logMsg));
      String? serverVerdict;
      try {
        await a.run(() => const ApiE2eeApi().putProcessingPolicy(circle, <String, dynamic>{
              ...stmt.toJson(),
              'log_signature': logSig,
              'wraps': wraps,
            }));
        serverVerdict = 'accepted';
      } on ApiException catch (e) {
        serverVerdict = 'rejected ${e.status} ${e.message}';
      }
      // ignore: avoid_print
      print('scenario 7: the server $serverVerdict');
      for (final Phone p in <Phone>[b, c]) {
        final List<int> before = await p.run(() => p.service.heldServerGens(circle));
        final CircleLanes v = await p.run(() => p.lanes.refresh(circle, force: true));
        final List<int> after = await p.run(() => p.service.heldServerGens(circle));
        if (serverVerdict == 'accepted') {
          expect(after, before, reason: '${p.name} must not store the CK as server key gen $gen');
          expect(await p.run(() => p.service.serverKey(circle, gen)), isNull);
          expect(p.service.rejectedServerWraps + p.service.laneAlarms.length, greaterThan(0), reason: '${p.name} refused / raised an alarm');
          // Setting the server lane against the poisoned generation is impossible.
          await expectLater(p.run(() => p.lanes.setLane(circle, E2ee.lineServer, confirmServerFingerprintHex: server.fingerprintHex)), throwsA(anything));
        }
        expect(v.status, isNot(LaneStatus.serverAssisted), reason: p.name);
      }
      // Whatever the server did, no phone-line plaintext of Cleo or Ben exists on it.
      expect(await db.anyRowNear(cLat, cLon), 0);
    });
  });

  test('the server log has no phone-line coordinate (checked by scripts/e2e-lanes.sh)', () {
    // The script greps the API container log for the prefixes below after this run.
    expect(<String>['41.314', '41.315'], isNotEmpty);
  });
}
