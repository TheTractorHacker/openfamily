import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/circle.dart';
import 'package:openfamily/services/e2ee/e2ee_crypto.dart';
import 'package:openfamily/services/e2ee/e2ee_models.dart';
import 'package:openfamily/services/e2ee/e2ee_service.dart';
import 'package:openfamily/services/e2ee/e2ee_trust.dart';
import 'package:openfamily/services/e2ee/e2ee_vault.dart';
import 'package:openfamily/services/e2ee/lanes_service.dart';
import 'package:openfamily/services/e2ee/lanes_wire.dart';
import 'package:openfamily/services/e2ee/lanes_store.dart';
import 'package:openfamily/services/e2ee/private_channel.dart';
import 'package:openfamily/services/e2ee/private_runtime.dart';

import '../../support/fake_e2ee_server.dart';
import '../../support/viewer_fixture.dart';
import 'lanes_service_test.dart' show FlakyClient, circleOf, priv, uA, uB, uC;
import 'private_channel_test.dart' show FakeClock;

// The production state of 2026-11-10, rebuilt, and the proof that the app converges by itself:
//
//   * the owner (Alice) resets her keys on a new phone: every key of her account is revoked (her old phone, which
//     signed the circle's policy, and the built-in server key, which is hers too);
//   * the other member (Bob) is still in the server lane, his signed choice names the server key, and his phone still
//     queues server-line copies of his positions;
//   * the policy is unverifiable (its signer is revoked), so the server refuses every server copy (lane_not_server);
//   * an old background isolate keeps uploading with the revoked key (device_revoked).
//
// Then nobody taps anything: the app opens, heals, and the circle works again, on the SAME server key when the server
// supports keeping it, and on a replaced one (silently) when it does not. No position is dropped, none goes out in
// the clear, no secret ends up in any log or output.

class Phone {
  Phone(FakeE2eeServer server, FakeLaneChannel channel, this.user, FakeClock clock, {MemoryVault? vault, MemoryKv? kv})
      : vault = vault ?? MemoryVault(),
        kv = kv ?? MemoryKv(),
        client = FlakyClient(server, user) {
    service = E2eeService(api: client, vault: this.vault, trust: TrustStore(MemoryTrustKv()), userIdProvider: () async => user);
    runtime = PrivateRuntime(
        service: service, api: client, kv: this.kv, clock: clock, channel: channel, directory: StateSenderDirectory(client));
    runtime.lanesService.logTtl = Duration.zero;
    runtime.notify = (String t, String b) async {};
    runtime.chatNotify = (String t, String b) async {};
  }
  final String user;
  final MemoryVault vault;
  final MemoryKv kv;
  final FlakyClient client;
  late final E2eeService service;
  late final PrivateRuntime runtime;
  LanesService get lanes => runtime.lanesService;
  LaneStore get store => lanes.store;
}

void main() {
  late FakeE2eeServer server;
  late FakeLaneChannel channel;
  late FakeClock clock;
  late Phone alice1, bob;
  late ViewerFixture srv;
  late String srvId, srvFp;

  Future<void> seal(Phone p, int n, {double lat = 10}) async {
    for (int i = 0; i < n; i++) {
      clock.t = clock.t.add(const Duration(seconds: 5));
      await p.runtime.routeFix(<String, dynamic>{
        'device_id': 'x', 'ts': clock.t.toIso8601String(), 'lat': lat + i * 0.0001, 'lon': 20.0,
        'accuracy_meters': 8, 'speed_mps': 1.0, 'battery_pct': 70, 'motion_state': '',
      });
    }
    await Future<void>.delayed(const Duration(milliseconds: 150));
  }

  Future<DeviceKey> registerServerKey(Phone approver, {String label = 'Orbitly server'}) async {
    srv = await ViewerFixture.create(uA);
    final String ap = await approver.service.approveLinkRequest(await approver.service.inspectViewerRequest(await srv.request(kind: 'server', name: label)));
    final DeviceKey k = await srv.register(server, ap, kind: 'server', label: label);
    server.pinnedServerDevice = srv.deviceId;
    srvId = k.deviceId;
    srvFp = k.fingerprint;
    return k;
  }

  /// Policy on at server key generation 3, Alice and Bob both in the server lane, three phone epochs.
  Future<void> productionBefore({required bool keepSupported}) async {
    server = FakeE2eeServer()..names.addAll(<String, String>{uA: 'Alice', uB: 'Bob'});
    clock = FakeClock(DateTime.utc(2026, 11, 10, 3, 0));
    server.now = () => clock.t;
    server.builtinServer = true;
    server.supportsKeepServer = keepSupported;
    server.circle(priv, members: <String>[uA, uB], admin: uA);
    channel = FakeLaneChannel(server)..strictLanes = true;
    alice1 = Phone(server, channel, uA, clock);
    bob = Phone(server, channel, uB, clock);
    await alice1.service.registerThisDevice();
    await bob.service.registerThisDevice();
    await alice1.service.enableCircle(priv);
    await bob.service.syncCircleKeys(priv);
    await registerServerKey(alice1);
    server.serverModeEnabled = true;
    for (final Phone p in <Phone>[alice1, bob]) {
      await p.runtime.setCircles(<Circle>[circleOf(priv)]);
    }
    await alice1.lanes.publishPolicy(priv, serverAssist: true);
    await alice1.lanes.rotateServerKey(priv);
    await alice1.lanes.rotateServerKey(priv);
    await bob.lanes.refresh(priv, force: true);
    await bob.lanes.setLane(priv, E2ee.lineServer, confirmServerFingerprintHex: srvFp);
    await alice1.lanes.setLane(priv, E2ee.lineServer, confirmServerFingerprintHex: srvFp);
    await alice1.lanes.maintain(priv);
    await alice1.service.bumpEpoch(priv);
    await alice1.service.bumpEpoch(priv);
    await bob.service.syncCircleKeys(priv);
    await bob.lanes.refresh(priv, force: true);
    await alice1.lanes.refresh(priv, force: true);
    final FakeCircle c = server.circles[priv]!;
    expect((c.skGen, c.assist, c.skWraps.containsKey('3/$srvId')), (3, true, true));
    expect((await bob.lanes.status(priv), await alice1.lanes.status(priv)), (LaneStatus.serverAssisted, LaneStatus.serverAssisted));
  }

  /// The owner resets her keys on a new phone. The old background isolate keeps its cached identity (alice1).
  Future<(Phone, KeyResetResult)> ownerResets() async {
    // Same phone storage as alice1's (foreground and background share it); the foreground wipes the old identity.
    final Phone a2 = Phone(server, channel, uA, clock, vault: alice1.vault);
    await a2.service.eraseLocalKeys();
    final KeyResetResult r = await a2.service.resetThisDevice(label: 'Reset', serverWait: const Duration(milliseconds: 50), step: const Duration(milliseconds: 10));
    // The owner approves her own new phone (owner approval), like the production circle.
    server.circles[priv]!.approvals.add(r.key.deviceId);
    await a2.runtime.setCircles(<Circle>[circleOf(priv)]);
    await a2.service.bumpEpoch(priv); // a new phone-line epoch, wrapped to itself and to Bob's phone
    await bob.service.syncCircleKeys(priv);
    return (a2, r);
  }

  /// The built-in server notices its key was revoked and makes a new one; the reset phone approves it (v0.26.16).
  Future<void> serverMakesNewKey(Phone approver) async {
    await registerServerKey(approver);
  }

  test('SAME server key: reset keeps it, and the circle converges with no user action', () async {
    await productionBefore(keepSupported: true);
    final String oldServer = srvId;
    // Bob's phone has positions sealed for the server lane waiting to go out when the reset happens.
    await seal(bob, 2);
    final List<WireItem> waiting = await bob.runtime.queue.peek();
    expect(waiting.map((WireItem i) => i.line).toSet(), <int>{E2ee.lineServer});

    final (Phone a2, KeyResetResult r) = await ownerResets();
    expect(r.serverKept, isTrue);
    expect(server.pinnedServerDevice, oldServer, reason: 'no new server key on a reset');
    expect(server.findActive(oldServer), isNotNull, reason: 'the server key is still active');
    expect(server.log.where((Map<String, dynamic> e) => e['action'] == E2ee.actServerAttach).length, 1);

    // ---- the broken state, as in production, before anybody heals

    // The stale isolate (old identity cached) uploads: the server refuses with 403 device_revoked; it picks up the new key.
    final String staleDevice = (await alice1.service.identity())!.deviceId;
    await seal(alice1, 1);
    expect(await alice1.runtime.queue.length(), 1);
    await alice1.runtime.flush();
    expect(server.refusals.any((String s) => s == 'device_revoked/$staleDevice'), isTrue);
    expect((await alice1.service.identity())!.deviceId, (await a2.service.identity())!.deviceId, reason: 'the stale isolate now reads the new identity');

    // Bob's queued server copies (his phone has not looked at the circle since): refused by the server as
    // lane_not_server, replaced by their phone-line twins, delivered.
    channel.items.clear();
    final int delivered = await bob.runtime.flush();
    expect(server.refusals.any((String s) => s.startsWith('lane_not_server/')), isTrue);
    expect(delivered, 2, reason: 'no position dropped');
    expect(await bob.runtime.queue.length(), 0);
    expect(channel.items.where((WireItem i) => i.deviceId == (waiting.first.deviceId)).map((WireItem i) => i.line).toSet(), <int>{E2ee.linePhone},
        reason: 'delivered on the phone line, never plaintext');
    expect(channel.items.where((WireItem i) => i.deviceId == waiting.first.deviceId).map((WireItem i) => i.seq).toSet(), waiting.map((WireItem i) => i.seq).toSet());
    final CircleLanes bobView = await bob.lanes.refresh(priv, force: true);
    expect(bobView.policy.assist, isFalse, reason: 'the policy was signed by the revoked phone: unverifiable');
    // New positions of Bob use the phone line until the circle is repaired (never nothing, never plaintext).
    await seal(bob, 1);
    expect((await bob.runtime.queue.peek()).single.line, E2ee.linePhone);
    expect(await bob.runtime.flush(), 1);

    // ---- no taps: the owner's new phone heals, then Bob's
    final List<String> didA = await a2.lanes.selfHeal(priv);
    expect(didA, containsAll(<String>['policy', 'pref']));
    final CircleLanes aView = await a2.lanes.refresh(priv, force: true);
    expect((aView.policy.assist, aView.status, aView.serverKey?.deviceId), (true, LaneStatus.serverAssisted, oldServer));
    expect(server.circles[priv]!.skWraps.containsKey('${server.circles[priv]!.skGen}/$oldServer'), isTrue, reason: 'the server key got the new generation');

    final List<String> didB = await bob.lanes.selfHeal(priv);
    final CircleLanes b2 = await bob.lanes.refresh(priv, force: true);
    expect((b2.policy.assist, b2.status), (true, LaneStatus.serverAssisted));
    expect(didB, isNot(contains('pref')), reason: 'the kept key leaves Bob\'s signed choice valid: nothing to re-sign');
    expect(server.circles[priv]!.prefs[uB]!.serverDeviceId, oldServer);

    // Positions flow on the server lane again, both ways, with no refusal after the repair.
    final int refusals = server.refusals.length;
    await seal(bob, 1);
    await seal(a2, 1);
    await bob.runtime.flush();
    await a2.runtime.flush();
    for (final Phone p in <Phone>[bob, a2]) {
      final String dev = (await p.service.identity())!.deviceId;
      expect(channel.items.where((WireItem i) => i.deviceId == dev).last.line, E2ee.lineServer, reason: 'the server lane works again for ${p.user}');
    }
    expect(server.refusals.length, refusals);
  });

  test('REPLACED server key (an older server): the app replaces it silently and converges; Bob re-signs by himself', () async {
    await productionBefore(keepSupported: false);
    final String oldServer = srvId;
    final (Phone a2, KeyResetResult r) = await ownerResets();
    expect(r.serverKept, isFalse);
    expect(server.findActive(oldServer), isNull, reason: 'an older server revokes the server key with everything else');
    await serverMakesNewKey(a2); // what the built-in server does on its own, approved by the reset phone
    expect(srvId, isNot(oldServer));

    // Bob's choice names the revoked key (production: pref seq 22 naming 13f7e151).
    expect((await bob.lanes.refresh(priv, force: true)).status, LaneStatus.phoneOnly);
    final List<String> didA = await a2.lanes.selfHeal(priv);
    expect(didA, containsAll(<String>['policy', 'pref']));
    final List<String> didB = await bob.lanes.selfHeal(priv);
    expect(didB, contains('pref'), reason: 'Bob\'s own phone signs his choice for the new server key');
    final CircleLanes b2 = await bob.lanes.refresh(priv, force: true);
    expect((b2.status, b2.serverKey?.deviceId), (LaneStatus.serverAssisted, srvId));
    expect(server.circles[priv]!.prefs[uB]!.serverDeviceId, srvId);
    expect(server.circles[priv]!.skWraps.containsKey('${server.circles[priv]!.skGen}/$srvId'), isTrue);
    await seal(bob, 1);
    expect(await bob.runtime.flush(), 1);
  });

  test('the same repair, through the app-open path (PrivateRuntime.onAppActive) on both phones', () async {
    await productionBefore(keepSupported: true);
    final (Phone a2, _) = await ownerResets();
    await a2.runtime.onAppActive(<Circle>[circleOf(priv)]);
    await bob.runtime.onAppActive(<Circle>[circleOf(priv)]);
    expect((await a2.lanes.status(priv), await bob.lanes.status(priv)), (LaneStatus.serverAssisted, LaneStatus.serverAssisted));
  });

  group('required server processing: no member action', () {
    test('every member phone signs by itself; the admin\'s rule survives the owner reset', () async {
      await productionBefore(keepSupported: true);
      // The owner turns the one switch on.
      await alice1.lanes.publishPolicy(priv, serverAssist: true, defaultForNew: E2ee.lineServer, memberOptOut: E2ee.optOutRequiredServer);
      final (Phone a2, _) = await ownerResets();
      await a2.lanes.selfHeal(priv);
      final CircleLanes a = await a2.lanes.refresh(priv, force: true);
      expect(a.policy.memberOptOut, E2ee.optOutRequiredServer, reason: 'the settings are kept when the owner\'s new phone signs again');
      await bob.lanes.selfHeal(priv);
      expect(await bob.lanes.status(priv), LaneStatus.serverAssisted);
      expect(await a2.lanes.status(priv), LaneStatus.serverAssisted);
    });

    test('a new member (no pref, no prompt): signs on its first run, and sends on the phone line until then', () async {
      await productionBefore(keepSupported: true);
      await alice1.lanes.publishPolicy(priv, serverAssist: true, defaultForNew: E2ee.lineServer, memberOptOut: E2ee.optOutRequiredServer);
      server.circles[priv]!.members.add(uC);
      server.names[uC] = 'Cleo';
      final Phone cleo = Phone(server, channel, uC, clock);
      await cleo.service.registerThisDevice();
      await cleo.runtime.setCircles(<Circle>[circleOf(priv)]);
      await alice1.service.processPending(priv); // an admin phone shares the keys with the new phone
      await alice1.lanes.maintain(priv);
      await cleo.service.syncCircleKeys(priv);
      expect((await cleo.lanes.refresh(priv, force: true)).status, LaneStatus.serverPending);
      await seal(cleo, 1);
      expect((await cleo.runtime.queue.peek()).single.line, E2ee.linePhone, reason: 'never nothing while it catches up');
      await cleo.lanes.selfHeal(priv);
      expect(await cleo.lanes.status(priv), LaneStatus.serverAssisted);
    });

    test('a queued older phone opt-out does not override the rule', () async {
      await productionBefore(keepSupported: true);
      bob.client.failPrefPut = true;
      try {
        await bob.lanes.setLane(priv, E2ee.linePhone);
      } catch (_) {}
      bob.client.failPrefPut = false;
      expect(await bob.store.pendingBody(priv), isNotNull);
      await alice1.lanes.publishPolicy(priv, serverAssist: true, defaultForNew: E2ee.lineServer, memberOptOut: E2ee.optOutRequiredServer);
      await bob.lanes.selfHeal(priv);
      expect(await bob.store.pendingBody(priv), isNull);
      expect(await bob.lanes.status(priv), LaneStatus.serverAssisted);
    });

    test('a pref that can never become effective is not re-signed in a loop', () async {
      await productionBefore(keepSupported: true);
      await alice1.lanes.publishPolicy(priv, serverAssist: true, defaultForNew: E2ee.lineServer, memberOptOut: E2ee.optOutRequiredServer);
      await bob.lanes.setLane(priv, E2ee.linePhone);
      int prefs() => server.log.where((Map<String, dynamic> e) => e['action'] == E2ee.actProcessingPref && e['user'] == uB).length;
      // Make the signed pref invisible to Bob's verification (a server that hides it): signing must not repeat.
      server.circles[priv]!.prefs.remove(uB);
      final int before = prefs();
      await bob.lanes.signRequiredLaneIfDue(priv);
      final int once = prefs();
      expect(once, before + 1);
      server.circles[priv]!.prefs.remove(uB);
      for (int i = 0; i < 3; i++) {
        await bob.lanes.signRequiredLaneIfDue(priv);
      }
      expect(prefs(), once, reason: 'debounced: the same (phone, server key, generation) is not signed again within minutes');
      clock.t = clock.t.add(const Duration(minutes: 11));
      await bob.lanes.signRequiredLaneIfDue(priv);
    });
  });

  group('negative cases: the trust model is not weakened', () {
    test('an unapproved or non-owner key can never become the server key', () async {
      await productionBefore(keepSupported: true);
      // A foreign "server" key of ANOTHER account, pinned by a lying server: the owner phone never trusts it.
      final ViewerFixture evil = await ViewerFixture.create(uB);
      final String ap = await bob.service.approveLinkRequest(await bob.service.inspectViewerRequest(await evil.request(kind: 'server', name: 'Evil')));
      final DeviceKey ek = await evil.register(server, ap, kind: 'server', label: 'Evil');
      server.pinnedServerDevice = ek.deviceId;
      final CircleLanes v = await alice1.lanes.refresh(priv, force: true);
      // Not approved in the circle (the admin never approved it): it is not the server key.
      expect(v.serverKey?.deviceId, isNot(ek.deviceId));
      // A reset never attaches it: the phone only signs for the key it knew before and the server reports as pinned built-in.
      final Phone a2 = Phone(server, channel, uA, clock, vault: alice1.vault);
      await a2.service.eraseLocalKeys();
      server.pinnedServerDevice = ek.deviceId;
      final DeviceKey? keep = await a2.service.serverKeyToKeep(await a2.client.myKeys());
      expect(keep, isNull);
    });

    test('a kept server key is NOT accepted without the new root phone\'s signed re-attachment', () async {
      await productionBefore(keepSupported: false);
      final String oldServer = srvId;
      final Phone a2 = Phone(server, channel, uA, clock, vault: alice1.vault);
      await a2.service.eraseLocalKeys();
      // An older server revokes the key; a lying server then re-lists it as active and approved.
      await a2.service.resetThisDevice(serverWait: const Duration(milliseconds: 20), step: const Duration(milliseconds: 5));
      server.circles[priv]!.approvals.add((await a2.service.identity())!.deviceId);
      // Revived by the "server": the key log has a reset after its registration and NO attach entry.
      final List<DeviceKey> mine = server.keys[uA]!;
      final int i = mine.indexWhere((DeviceKey k) => k.deviceId == oldServer);
      final DeviceKey d = mine[i];
      mine[i] = DeviceKey(
          deviceId: d.deviceId, userId: d.userId, kind: d.kind, edPub: d.edPub, xPub: d.xPub, fingerprint: d.fingerprint, digits: d.digits,
          short: d.short, registeredByDeviceId: d.registeredByDeviceId, registeredByPub: d.registeredByPub,
          registrationAction: d.registrationAction, registrationSignature: d.registrationSignature, initial: d.initial, label: d.label,
          createdAt: d.createdAt);
      server.pinnedServerDevice = oldServer;
      server.attachActor[oldServer] = (await a2.service.identity())!.deviceId; // even "approved" through the new phone
      final CircleLanes v = await a2.lanes.refresh(priv, force: true);
      expect(v.serverKey, isNull, reason: 'a reset retired it and nobody re-attached it');
    });

    test('forged policy is rejected: wrong signature, non-admin signer', () async {
      await productionBefore(keepSupported: true);
      final FakeCircle c = server.circles[priv]!;
      final PolicyStatement real = c.policy!;
      // 1) the statement's bytes changed after signing (a server that edits the settings)
      final PolicyStatement forged = PolicyStatement(
          serverAssist: true, defaultForNew: E2ee.lineServer, memberOptOut: E2ee.optOutRequiredServer, skGen: real.skGen,
          commitment: real.commitment, nonce: real.nonce, adminUserId: real.adminUserId, actorDeviceId: real.actorDeviceId, signature: real.signature);
      c.policy = forged;
      c.policyHistory.clear();
      final CircleLanes v = await bob.lanes.refresh(priv, force: true);
      expect(v.policy.memberOptOut, isNot(E2ee.optOutRequiredServer));
      expect(v.policy.assist, isFalse, reason: 'unverifiable: fail closed to the phone lane');
      expect(await bob.lanes.signRequiredLaneIfDue(priv), isNot(AutoApplyOutcome.applied));
      c.policy = real;
      // 2) Bob (a non-admin) cannot publish a policy
      await expectLater(bob.lanes.publishPolicy(priv, serverAssist: true, memberOptOut: E2ee.optOutRequiredServer), throwsA(isA<StateError>()));
    });

    test('the owner phone never copies settings from a statement it cannot tie to its own account', () async {
      await productionBefore(keepSupported: true);
      final (Phone a2, _) = await ownerResets();
      final FakeCircle c = server.circles[priv]!;
      final PolicyStatement real = c.policy!;
      final PolicyStatement forged = PolicyStatement(
          serverAssist: true, defaultForNew: E2ee.lineServer, memberOptOut: E2ee.optOutRequiredServer, skGen: real.skGen,
          commitment: real.commitment, nonce: real.nonce, adminUserId: real.adminUserId, actorDeviceId: real.actorDeviceId, signature: Uint8List(64));
      c.policy = forged;
      expect(await a2.lanes.selfHeal(priv), isNot(contains('policy')));
    });

    test('no secret material in any log, report or output of the repair', () async {
      await productionBefore(keepSupported: true);
      final (Phone a2, _) = await ownerResets();
      await a2.lanes.selfHeal(priv);
      await bob.lanes.selfHeal(priv);
      final StringBuffer out = StringBuffer()
        ..writeln(await a2.lanes.selfHeal(priv))
        ..writeln((await a2.runtime.deliveryFacts()).circles.map((c) => c.laneLabel))
        ..writeln((await bob.runtime.deliveryFacts()).lastErrorCode)
        ..writeln(server.refusals.join('\n'));
      // Every kv value either phone wrote (the places a secret could leak to) is searched for the key material.
      final List<Uint8List> secrets = <Uint8List>[
        for (final Phone p in <Phone>[a2, bob]) ...<Uint8List>[
          (await p.service.identity())!.edSeed,
          for (final int g in await p.service.heldServerGens(priv)) (await p.service.serverKey(priv, g))!,
        ],
      ];
      final String blob = '$out${a2.kv.data.values.join('\n')}${bob.kv.data.values.join('\n')}';
      for (final Uint8List s in secrets) {
        expect(blob.contains(E2ee.b64(s)), isFalse);
        expect(blob.contains(E2ee.hex(s)), isFalse);
        expect(blob.contains(base64Url.encode(s)), isFalse);
      }
    });
  });
}
