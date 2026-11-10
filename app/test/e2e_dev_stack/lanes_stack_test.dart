@Timeout(Duration(minutes: 10))
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/e2ee/e2ee_api.dart';
import 'package:openfamily/services/e2ee/e2ee_crypto.dart';
import 'package:openfamily/services/e2ee/e2ee_models.dart';
import 'package:openfamily/services/e2ee/e2ee_service.dart';
import 'package:openfamily/services/e2ee/lanes_store.dart';
import 'package:openfamily/services/e2ee/lanes_wire.dart';
import 'package:openfamily/services/e2ee/private_channel.dart';

import '../e2e_real_server/harness.dart';
import 'support.dart';

// Scenarios (b), (c), (d) against the dev stack's REAL server (the production API image, the built-in server
// device, no sidecar, no ingest token) with the app's own crypto client:
//
//   (b) a phone registers its device key, joins a circle, uploads sealed fixes on the phone lane and on the
//       server lane, another member pulls and decrypts, and the server device processes the server-lane fix;
//   (d) refused uploads produce the log lines the server emits (device_revoked, lane_not_server, bad_epoch);
//   (c) the owner resets keys: what the server state looks like afterwards (devices revoked, server key
//       replaced, wraps, policy and pref statements) and which uploads are refused with which reason.
//
// The groups run in this order on purpose: (c) is destructive for the circle. Tests marked
// EXPECTED-FAILING describe features other tracks are still building; each must fail today and starts
// failing the run ("now PASSES") when its feature lands, so it gets promoted to a real check.
//
// Run through scripts/dev/e2e.sh (it streams the API log the log checks read).

const double bLat = 52.52345, bLon = 13.40123; // Ben: server lane
const double cLat = 41.31415, cLon = 2.17403; // Cleo: phone lane, must never reach the server in plaintext

void main() {
  final DevEnv? env = DevEnv.fromEnvironment();
  if (env == null) {
    test('lanes e2e on the dev stack', () {}, skip: skipReason);
    return;
  }
  late DevStack stack;
  late Db db;
  late Phone anna, ben, cleo;
  late Phone annaNew; // the owner's phone after she lost her keys
  late String circle;
  late String serverKeyBefore; // device id of the server key before the owner's reset
  late String annaOldDevice;
  final LogTail log = LogTail(env, 'api');

  Future<List<List<dynamic>>> q(String sql) => db.query(sql);
  Future<String> deviceOf(Phone p) async => (await p.run(() => p.service.identity()))!.deviceId;

  Future<String?> activeServerKey() async {
    final List<List<dynamic>> r = await q("SELECT device_id::text FROM device_keys WHERE kind = 'server' AND revoked_at IS NULL");
    return r.isEmpty ? null : r.single.single as String;
  }

  Future<int> itemCount(String where) => db.count("SELECT count(*) FROM e2ee_items WHERE circle_id = '$circle' AND $where");

  /// Waits for the built-in server device (it polls every 15 s) to have a pinned server key.
  Future<void> waitPinned({Duration timeout = const Duration(seconds: 90)}) async {
    final DateTime end = DateTime.now().add(timeout);
    while (await db.count('SELECT count(*) FROM e2ee_server_device') == 0 && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    expect(await db.count('SELECT count(*) FROM e2ee_server_device'), 1, reason: 'the built-in server device never pinned its key');
  }

  setUpAll(() async {
    await bootstrap(env.e2e);
    requireLogs(log);
    db = Db(env.e2e);
    stack = DevStack(env);
    anna = await stack.ownerPhone('Anna');
    expect(await db.count("SELECT count(*) FROM device_keys WHERE user_id = '${anna.userId}'"), 0,
        reason: 'the owner already has device keys: this scenario needs a FRESH stack (scripts/dev/e2e.sh without --keep)');
    ben = await stack.newUser('Ben');
    cleo = await stack.newUser('Cleo');
    circle = await stack.createCircle(anna, <Phone>[ben, cleo], name: 'Dev lanes circle');
    await stack.makePrivate(circle, anna, <Phone>[ben, cleo]);
    annaOldDevice = await deviceOf(anna);

    // The server's own key asks to join; Anna's phone approves it (one OK in the app), turns the policy on and
    // goes on the server lane herself. Ben signs the server lane; Cleo stays on her phone.
    await addServerThroughApp(anna, circle);
    await waitPinned();
    final String fp = (await anna.run(() => const ApiE2eeApi().processingState(circle))).serverFingerprint!;
    await ben.run(() => ben.lanes.refresh(circle, force: true));
    await ben.run(() => ben.lanes.setLane(circle, E2ee.lineServer, confirmServerFingerprintHex: fp));
    await cleo.run(() => cleo.lanes.refresh(circle, force: true));
    await anna.run(() => anna.lanes.maintain(circle));
    serverKeyBefore = (await activeServerKey())!;
  });

  // ---------------------------------------------------------------- (b)
  group('(b) register, join, upload on both lanes, pull and decrypt, the server processes', () {
    test('every phone registered a device key with the lanes capability; the server key is a kind=server key of the owner', () async {
      for (final Phone p in <Phone>[anna, ben, cleo]) {
        final List<DeviceKey> keys = await p.run(() => const ApiE2eeApi().myKeys());
        final DeviceKey k = keys.firstWhere((DeviceKey k) => k.kind == 'device');
        expect(k.isActive, isTrue, reason: p.name);
        expect(k.supportsLanes, isTrue, reason: '${p.name}: caps ${k.caps}');
      }
      expect(await q("SELECT user_id::text FROM device_keys WHERE device_id = '$serverKeyBefore'"), <List<dynamic>>[<dynamic>[anna.userId]]);
      final CircleE2eeState st = await anna.run(() => const ApiE2eeApi().circleState(circle));
      expect(st.isPrivate, isTrue);
      final ProcessingServerState proc = await anna.run(() => const ApiE2eeApi().processingState(circle));
      expect(proc.serverAssist, isTrue);
      expect(proc.inEffect, isTrue);
      expect(proc.serverDeviceId, serverKeyBefore);
      expect(await ben.run(() => ben.store.status(circle)), LaneStatus.serverAssisted);
      expect(await cleo.run(() => cleo.store.status(circle)), LaneStatus.phoneOnly);
    });

    test('sealed fixes are uploaded: Cleo on the phone lane, Ben on the server lane', () async {
      expect(await cleo.sendFix(cLat, cLon), 1);
      expect(await ben.sendFix(bLat, bLon), 1);
      expect(await itemCount("key_line = 'server' AND device_id = '${await deviceOf(ben)}'"), 1);
      expect(await itemCount("key_line IN ('phone', '') AND device_id = '${await deviceOf(cleo)}'"), 1);
      // At rest the server holds ciphertext only for Cleo.
      expect(await db.count("SELECT count(*) FROM e2ee_items WHERE circle_id = '$circle' AND position('41.31415'::bytea IN ciphertext) > 0"), 0);
    });

    test('another member pulls and decrypts both lanes; the badge follows the author\'s signed lane', () async {
      for (final Phone reader in <Phone>[anna, ben, cleo]) {
        await reader.run(() => reader.lanes.refresh(circle, force: true));
        final List<ReceivedItem> got = await reader.receiveAll(circle);
        final Map<String, ReceivedItem> fixes = <String, ReceivedItem>{
          for (final ReceivedItem i in got)
            if (i.purpose == ChannelPurpose.fix) i.userId: i
        };
        for (final (Phone author, double lat, double lon, bool server) in <(Phone, double, double, bool)>[
          (ben, bLat, bLon, true),
          (cleo, cLat, cLon, false),
        ]) {
          if (author == reader) continue;
          final ReceivedItem? it = fixes[author.userId];
          expect(it, isNotNull, reason: '${reader.name} should read ${author.name}');
          expect(it!.line, server ? E2ee.lineServer : E2ee.linePhone, reason: '${reader.name} reads ${author.name}');
          expect((it.body['lat'] as num).toDouble(), closeTo(lat, 0.0015));
          expect((it.body['lon'] as num).toDouble(), closeTo(lon, 0.0015));
        }
      }
    });

    test('the built-in server device processes Ben\'s server-lane fix and never Cleo\'s', () async {
      final DateTime end = DateTime.now().add(const Duration(seconds: 90));
      while (await db.userRowsNear(ben.userId, bLat, bLon) == 0 && DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(seconds: 3));
      }
      expect(await db.userRowsNear(ben.userId, bLat, bLon), greaterThan(0), reason: 'the server device never delivered Ben\'s fix');
      expect(await db.locationsOf(cleo.userId), 0);
      expect(await db.positionRows(cleo.userId), 0);
      expect(await db.anyRowNear(cLat, cLon), 0);
    });
  });

  // ---------------------------------------------------------------- (d), before the reset
  group('(d) refused uploads, and the log lines the server emits', () {
    test('bad_epoch: an item sealed for a circle key epoch that does not exist (phone line) is rejected per item and logged', () async {
      final int mark = log.mark();
      final Resp r = await postBatch(env, cleo, circle, await deviceOf(cleo), <Map<String, dynamic>>[craftItem(epoch: 99)]);
      expect(r.status, 200, reason: 'nothing stored: $r');
      expect(batchResults(r).single['status'], 'rejected');
      expect(batchResults(r).single['error'], 'bad_epoch');
      final List<String> lines = await log.waitFor(mark, <String>['e2ee items rejected', 'bad_epoch']);
      expect(lines, isNotEmpty, reason: 'expected: msg="e2ee items rejected" ... rejected=map[bad_epoch:1]\n${log.since(mark)}');
      expect(lines.first, contains('level=WARN'));
      expect(lines.first, contains('stored=0'));
      expect(lines.first, contains('device=${(await deviceOf(cleo)).substring(0, 8)}'));
    });

    test('bad_epoch on the server line: a server key generation that does not exist', () async {
      final int mark = log.mark();
      final Resp r = await postBatch(env, ben, circle, await deviceOf(ben), <Map<String, dynamic>>[craftItem(epoch: 7, line: 'server')]);
      expect(batchResults(r).single['error'], 'bad_epoch', reason: '$r');
      expect(await log.waitFor(mark, <String>['e2ee items rejected', 'bad_epoch']), isNotEmpty);
    });

    test('lane_not_server: Cleo\'s phone still believes it is on the server lane, her signed lane says phone', () async {
      final int mark = log.mark();
      // A server-line item (valid header: line server, generation 1) from a member without a signed server lane.
      final Resp r = await postBatch(env, cleo, circle, await deviceOf(cleo), <Map<String, dynamic>>[craftItem(epoch: 1, line: 'server')]);
      expect(batchResults(r).single['status'], 'rejected', reason: '$r');
      expect(batchResults(r).single['error'], 'lane_not_server');
      final List<String> lines = await log.waitFor(mark, <String>['e2ee items rejected', 'lane_not_server']);
      expect(lines, isNotEmpty, reason: log.since(mark));
      expect(lines.first, contains('stored=0'));
    });

    test('a partly good batch stores the good item and names only the refused one in the log', () async {
      final int mark = log.mark();
      final int before = await itemCount("device_id = '${await deviceOf(cleo)}'");
      // One real sealed fix of Cleo\'s (queued by her runtime, not yet flushed) next to a bad-epoch one.
      await cleo.run(() async {
        await cleo.runtime.routeFix(cleo.fix(cLat + 0.0004, cLon));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      final List<WireItem> queued = await cleo.run(() => cleo.runtime.queue.peek());
      expect(queued, isNotEmpty);
      final Resp r = await postBatch(env, cleo, circle, await deviceOf(cleo), <Map<String, dynamic>>[
        queued.first.toUpload(),
        craftItem(epoch: 50),
      ]);
      expect(r.status, 201, reason: '$r');
      expect(batchResults(r).map((Map<String, dynamic> e) => e['status']).toList(), <String>['stored', 'rejected']);
      expect(await itemCount("device_id = '${await deviceOf(cleo)}'"), before + 1);
      final List<String> lines = await log.waitFor(mark, <String>['e2ee items rejected', 'bad_epoch']);
      expect(lines.first, contains('stored=1'));
    });

    test('a device that is not this account\'s is not found, and says nothing in the log', () async {
      final int mark = log.mark();
      final Resp r = await postBatch(env, cleo, circle, await deviceOf(ben), <Map<String, dynamic>>[craftItem(epoch: 1)]);
      expect(r.status, 404, reason: '$r');
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(log.since(mark), isNot(contains('e2ee upload refused')));
    });
  });

  // ---------------------------------------------------------------- (c)
  group('(c) the owner resets keys', () {
    late int epochBefore;
    late int statementsBefore;
    late String annaServerLanePref;
    late KeyResetResult reset;
    late int resetMark;

    test('before: the state the reset starts from', () async {
      epochBefore = (await q("SELECT e2ee_epoch FROM circles WHERE id = '$circle'")).single.single as int;
      statementsBefore = await db.count("SELECT count(*) FROM e2ee_processing_statements WHERE circle_id = '$circle'");
      annaServerLanePref = (await q("SELECT lane FROM e2ee_processing_pref WHERE circle_id = '$circle' AND user_id = '${anna.userId}'")).single.single as String;
      expect(annaServerLanePref, 'server');
      expect(await db.count("SELECT count(*) FROM circle_key_wraps w JOIN device_keys k ON k.device_id = w.recipient_device_id WHERE w.circle_id = '$circle' AND k.kind = 'server' AND k.revoked_at IS NULL"), greaterThan(0),
          reason: 'the server key holds the server key SK');
      expect(await db.count("SELECT count(*) FROM e2ee_processing_pref WHERE circle_id = '$circle'"), 2, reason: 'Anna and Ben signed the server lane; Cleo\'s phone lane is the default');
    });

    test('Anna resets her keys on a new phone: it registers a new root key, the built-in server key is revoked and replaced, and the new server key is registered under the new phone\'s key', () async {
      // "Reset my keys" is what an owner does on a phone that no longer has its key (a new phone, a reinstall without
      // restore): an empty key store, same account. On a phone whose key is still active it does nothing.
      resetMark = log.mark();
      annaNew = Phone('Anna-new-phone', env.ownerEmail, env.ownerPassword)..ip = nextIp();
      await annaNew.loginExisting(env.e2e, anna.userId);
      annaNew.startRuntime();
      reset = await annaNew.run(() => annaNew.service.resetThisDevice(serverWait: const Duration(seconds: 60)));
      expect(reset.serverKeyRevoked, isTrue, reason: 'the account held the server key');
      // The reset phone approves the server's new key without asking. On a busy disk the approval answer can
      // miss the app's 15 second limit while the server still finishes it, so the END STATE decides, not
      // reset.serverRejoined (printed for the record).
      final DateTime end = DateTime.now().add(const Duration(seconds: 90));
      while ((await activeServerKey()) == null && DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      final String? now = await activeServerKey();
      // ignore: avoid_print
      print('reset result: serverKeyRevoked=${reset.serverKeyRevoked} serverRejoined=${reset.serverRejoined}');
      expect(now, isNotNull, reason: 'a new server key exists (serverRejoined=${reset.serverRejoined})');
      final String newPhone = await deviceOf(annaNew);
      expect(await q("SELECT registered_by_device_id::text, user_id::text FROM device_keys WHERE device_id = '$now'"),
          <List<dynamic>>[<dynamic>[newPhone, anna.userId]],
          reason: 'the new server key is approved by the owner\'s NEW phone key (serverRejoined=${reset.serverRejoined})');
    });

    test('devices: every older key of the owner is revoked (reason "revoked"); the new key is a root that is not approved anywhere yet', () async {
      final List<List<dynamic>> old = await q("SELECT device_id::text, revoked_at IS NOT NULL, revoked_reason FROM device_keys WHERE user_id = '${anna.userId}' AND device_id IN ('$annaOldDevice', '$serverKeyBefore') ORDER BY kind");
      expect(old.length, 2);
      for (final List<dynamic> row in old) {
        expect(row[1], isTrue, reason: '${row[0]} must be revoked');
        expect(row[2], 'revoked');
      }
      final String newDevice = await deviceOf(annaNew);
      expect(newDevice, isNot(annaOldDevice));
      expect(await db.count("SELECT count(*) FROM device_keys WHERE user_id = '${anna.userId}' AND revoked_at IS NULL AND kind = 'device'"), 1);
      // Members' keys are untouched.
      expect(await db.count("SELECT count(*) FROM device_keys WHERE user_id IN ('${ben.userId}', '${cleo.userId}') AND revoked_at IS NULL"), 2);
      // The new key can read nothing until an admin approves it: no wraps for it, upload says device_not_approved (below).
      expect(await db.count("SELECT count(*) FROM circle_key_wraps WHERE circle_id = '$circle' AND recipient_device_id = '$newDevice'"), 0);
    });

    test('server key (today): REPLACED by a new key under a new device id, approved by the owner; the old pin is gone until the new key pins itself', () async {
      final String? now = await activeServerKey();
      expect(now, isNotNull, reason: 'the owner phone approved the new server key');
      expect(now, isNot(serverKeyBefore), reason: 'today the server makes a NEW key after a reset (the owner key that vouched for the old one is revoked)');
      expect(await db.count("SELECT count(*) FROM device_keys WHERE kind = 'server' AND device_id = '$serverKeyBefore' AND revoked_at IS NOT NULL"), 1);
      final DateTime end = DateTime.now().add(const Duration(seconds: 90));
      Object? pinned;
      while (DateTime.now().isBefore(end)) {
        final List<List<dynamic>> pin = await q('SELECT device_id::text FROM e2ee_server_device');
        pinned = pin.isEmpty ? null : pin.single.single;
        if (pinned == now) break;
        await Future<void>.delayed(const Duration(seconds: 3));
      }
      expect(pinned, now, reason: 'the built-in device pins its new key on its next pass (within ~30 s)');
      // The server settled: every ERROR line of the whole reset must be one of the built-in device's own, announced
      // transitions. The log stream is followed by `docker logs -f`, so wait until it stopped growing first.
      await log.settle();
      final List<String> errors = log.since(resetMark).split('\n').where((String l) => l.contains('level=ERROR')).toList();
      expect(errors.where((String l) => !l.contains('STOPPING:')).toList(), isEmpty,
          reason: 'an ERROR other than the built-in device\'s "STOPPING:" transition during the reset');
    });

    test('wraps, rekey flags, prefs and statements: the revoked keys\' wraps and the owner\'s server-lane pref are gone, the policy statements stay (append-only)', () async {
      // Wraps addressed to a revoked key are deleted by the database.
      expect(await db.count("SELECT count(*) FROM circle_key_wraps w JOIN device_keys k ON k.device_id = w.recipient_device_id WHERE w.circle_id = '$circle' AND k.revoked_at IS NOT NULL"), 0);
      expect(await db.count("SELECT count(*) FROM circle_key_wraps WHERE circle_id = '$circle' AND recipient_device_id = '$serverKeyBefore'"), 0);
      // The new server key holds no server key SK until the owner's phone re-wraps it.
      final String now = (await activeServerKey())!;
      expect(await db.count("SELECT count(*) FROM circle_key_wraps WHERE circle_id = '$circle' AND recipient_device_id = '$now'"), 0);
      // The circle asks for a new epoch / server key generation but does not bump them by itself.
      final List<dynamic> circleRow = (await q("SELECT e2ee_epoch, e2ee_rekey_required, e2ee_server_rekey_required FROM circles WHERE id = '$circle'")).single;
      expect(circleRow[0], epochBefore);
      expect(circleRow[1], isTrue, reason: 'an admin must rotate the circle key');
      expect(circleRow[2], isTrue, reason: 'and the server key');
      // Prefs signed by a now-revoked key are deleted; others keep theirs.
      expect(await db.count("SELECT count(*) FROM e2ee_processing_pref WHERE circle_id = '$circle' AND user_id = '${anna.userId}'"), 0);
      expect(await db.count("SELECT count(*) FROM e2ee_processing_pref WHERE circle_id = '$circle' AND user_id = '${ben.userId}' AND lane = 'server'"), 1);
      // The signed statements are an append-only log: nothing was removed.
      expect(await db.count("SELECT count(*) FROM e2ee_processing_statements WHERE circle_id = '$circle'"), greaterThanOrEqualTo(statementsBefore));
    });

    test('policy: server assistance stays "on" in the circle but is no longer IN EFFECT (its signer is revoked, the server holds no SK)', () async {
      final ProcessingServerState proc = await ben.run(() => const ApiE2eeApi().processingState(circle));
      expect(proc.serverAssist, isTrue);
      expect(proc.inEffect, isFalse);
    });

    test('uploads: the owner\'s OLD device is refused as a whole with 403 device_revoked, and the server logs it', () async {
      final int mark = log.mark();
      final Resp r = await postBatch(env, anna, circle, annaOldDevice, <Map<String, dynamic>>[craftItem(epoch: 1)]);
      expect(r.status, 403, reason: '$r');
      expect(r.code, 'device_revoked');
      final List<String> lines = await log.waitFor(mark, <String>['e2ee upload refused', 'code=device_revoked']);
      expect(lines, isNotEmpty, reason: 'expected: level=WARN msg="e2ee upload refused" user=.. device=.. code=device_revoked\n${log.since(mark)}');
      expect(lines.first, contains('level=WARN'));
      expect(lines.first, contains('device=${annaOldDevice.substring(0, 8)}'));
      expect(lines.first, contains('user=${anna.userId.substring(0, 8)}'));
    });

    test('uploads: the owner\'s NEW key is refused with 403 device_not_approved until an admin approves it', () async {
      final int mark = log.mark();
      final Resp r = await postBatch(env, annaNew, circle, await deviceOf(annaNew), <Map<String, dynamic>>[craftItem(epoch: 1)]);
      expect(r.status, 403, reason: '$r');
      expect(r.code, 'device_not_approved');
      expect(await log.waitFor(mark, <String>['e2ee upload refused', 'code=device_not_approved']), isNotEmpty);
    });

    test('uploads: Ben (still on the server lane on his phone) is refused per item with lane_not_server; Cleo\'s phone lane keeps working', () async {
      final int mark = log.mark();
      final int benBefore = await itemCount("device_id = '${await deviceOf(ben)}'");
      // Ben's REAL sealed server-lane fix, posted without dequeuing it.
      await ben.run(() async {
        await ben.runtime.routeFix(ben.fix(bLat + 0.001, bLon));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      final List<WireItem> queued = await ben.run(() => ben.runtime.queue.peek());
      final WireItem it = queued.firstWhere((WireItem w) => w.line == E2ee.lineServer, orElse: () => throw StateError('Ben sealed nothing on the server line'));
      final Resp r = await postBatch(env, ben, circle, await deviceOf(ben), <Map<String, dynamic>>[
        it.toUpload(),
      ]);
      expect(batchResults(r).single['error'], 'lane_not_server', reason: 'the policy no longer verifies, so nobody is on the server lane: $r');
      expect(await itemCount("device_id = '${await deviceOf(ben)}'"), benBefore);
      expect(await log.waitFor(mark, <String>['e2ee items rejected', 'lane_not_server']), isNotEmpty, reason: log.since(mark));
      // Phone-lane uploads still work (the circle key epoch did not change).
      expect(await cleo.sendFix(cLat + 0.0002, cLon), greaterThanOrEqualTo(1));
    });

    test('the server device no longer processes members after the reset (no new plaintext for Ben)', () async {
      final int before = await db.locationsOf(ben.userId);
      await Future<void>.delayed(const Duration(seconds: 35)); // two passes of the built-in device
      expect(await db.locationsOf(ben.userId), before);
    });

    expectedFailing('stable server key: the server key survives an owner reset (same device id, still active, wraps intact)',
        'stable server key (the server key no longer depends on the key of whoever approved it)', () async {
      // The set-up must hold with and without the feature: the owner's reset happened (her old phone key is revoked).
      precondition(await db.count("SELECT count(*) FROM device_keys WHERE device_id = '$annaOldDevice' AND revoked_at IS NOT NULL") == 1, 'the owner reset did not run');
      precondition(await activeServerKey() != null, 'the server has an active key after the reset');
      expect(await activeServerKey(), serverKeyBefore, reason: 'the original server key must still be the active one');
      expect(await db.count("SELECT count(*) FROM circle_key_wraps WHERE circle_id = '$circle' AND recipient_device_id = '$serverKeyBefore'"), greaterThan(0));
      expect(await db.count("SELECT count(*) FROM e2ee_processing_pref WHERE circle_id = '$circle' AND user_id = '${anna.userId}'"), 1,
          reason: 'the owner\'s signed server-lane pref survives a reset');
    });
  });

  // ---------------------------------------------------------------- features still being built
  group('features other tracks are still building', () {
    late Phone dan;
    late Phone cleoReinstalled;

    // The set-up of these checks is real and must succeed; only the final assertion is the feature.
    setUpAll(() async {
      dan = await stack.newUser('Dan');
      final String code = (await rawJson(env.e2e, 'POST', '/circles/$circle/invites',
          body: <String, dynamic>{'role': 'member', 'max_uses': 1, 'expires_in_hours': 1}, token: (await stack.ownerToken()), ip: stack.ownerIp))['code'] as String;
      await rawJson(env.e2e, 'POST', '/circles/join', body: <String, dynamic>{'code': code}, token: dan.token, ip: dan.ip);
      cleoReinstalled = Phone('Cleo-reinstalled', cleo.email, cleo.password)..ip = nextIp();
      await cleoReinstalled.loginExisting(env.e2e, cleo.userId);
      cleoReinstalled.startRuntime(); // an empty key store, like a fresh install
    });

    expectedFailing('forced server processing: an admin-forced server lane puts a member on it without the member signing anything',
        'forced server processing', () async {
      // Set-up that holds with and without the feature: Dan is a member of the Private circle and never opened the
      // app (no device key of his own), so nothing he signed can put him on the server lane.
      precondition(await db.count("SELECT count(*) FROM circle_members WHERE circle_id = '$circle' AND user_id = '${dan.userId}'") == 1, 'Dan is a member of the circle');
      precondition(await db.count("SELECT count(*) FROM device_keys WHERE user_id = '${dan.userId}'") == 0, 'Dan has no device key');
      // Poll instead of a fixed sleep: the feature has until the deadline (two passes of the built-in device).
      final String prefSql = "SELECT count(*) FROM e2ee_processing_pref WHERE circle_id = '$circle' AND user_id = '${dan.userId}' AND lane = 'server'";
      final DateTime end = DateTime.now().add(const Duration(seconds: 40));
      while (await db.count(prefSql) == 0 && DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      expect(await db.count(prefSql), 1, reason: 'the server put the member on the server lane');
    });

    expectedFailing('reinstall restore: a reinstalled app (empty key store) gets its device identity back without a new key',
        'reinstall restore', () async {
      final String id = await deviceOf(cleo);
      precondition(await db.count("SELECT count(*) FROM device_keys WHERE device_id = '$id' AND revoked_at IS NULL") == 1, 'Cleo\'s original device key is active');
      precondition(cleoReinstalled.token != null, 'the reinstalled phone is signed in');
      final int keysBefore = await db.count("SELECT count(*) FROM device_keys WHERE user_id = '${cleo.userId}'");
      final DeviceKey restored;
      try {
        restored = await cleoReinstalled.run(() => cleoReinstalled.service.registerThisDevice());
      } on NeedsCrossSignatureException {
        // Today's observable outcome: an empty key store cannot take its old identity back, the app asks to link
        // from another phone, restore with a phrase or reset. THIS (and nothing else) is the missing feature.
        fail('the reinstalled app cannot get its device identity back: registerThisDevice demands a cross-signature');
      }
      expect(restored.deviceId, id, reason: 'the same device identity comes back');
      expect(await db.count("SELECT count(*) FROM device_keys WHERE user_id = '${cleo.userId}'"), keysBefore, reason: 'no additional key is registered');
    });
  });
}
