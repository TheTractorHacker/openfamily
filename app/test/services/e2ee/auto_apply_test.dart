import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/circle.dart';
import 'package:openfamily/services/e2ee/e2ee_crypto.dart';
import 'package:openfamily/services/e2ee/e2ee_models.dart';
import 'package:openfamily/services/e2ee/lanes_service.dart';
import 'package:openfamily/services/e2ee/lanes_store.dart';
import 'package:openfamily/services/e2ee/private_runtime.dart';
import 'package:openfamily/widgets/server_prompts.dart';

import '../../support/fake_e2ee_server.dart';
import '../../support/viewer_fixture.dart';
import 'lanes_service_test.dart' show Dev, circleOf, priv, uA, uB, uC;
import 'private_channel_test.dart' show FakeClock;

// "Members are on the server by default" (docs/design/PRIVACY_PROCESSING.md section 23): the member's OWN phone signs
// the server lane once, never over a choice they made, and one tap undoes it.

void main() {
  late FakeE2eeServer server;
  late FakeLaneChannel channel;
  late FakeClock clock;
  late Dev alice, bob, carol;
  late ViewerFixture srv;

  Future<void> policyOn({int optOut = E2ee.optOutAllowed}) => alice.lanes.publishPolicy(priv, serverAssist: true, memberOptOut: optOut);
  int prefsOf(String user) => server.log.where((Map<String, dynamic> e) => e['action'] == E2ee.actProcessingPref && e['user'] == user).length;

  setUp(() async {
    server = FakeE2eeServer()..names.addAll(<String, String>{uA: 'Alice', uB: 'Bob', uC: 'Carol'});
    clock = FakeClock(DateTime.utc(2026, 11, 6, 12));
    server.now = () => clock.t;
    server.circle(priv, members: <String>[uA, uB, uC], admin: uA);
    channel = FakeLaneChannel(server);
    alice = Dev(server, channel, uA, clock);
    bob = Dev(server, channel, uB, clock);
    carol = Dev(server, channel, uC, clock);
    for (final Dev d in <Dev>[alice, bob, carol]) {
      await d.service.registerThisDevice();
    }
    await alice.service.enableCircle(priv);
    await bob.service.syncCircleKeys(priv);
    await carol.service.syncCircleKeys(priv);
    srv = await ViewerFixture.create(uA);
    final String ap = await alice.service.approveLinkRequest(await alice.service.inspectViewerRequest(await srv.request(kind: 'server', name: 'Orbitly server')));
    await srv.register(server, ap, kind: 'server', label: 'Orbitly server');
    server.serverModeEnabled = true;
    server.pinnedServerDevice = srv.deviceId;
    for (final Dev d in <Dev>[alice, bob, carol]) {
      await d.runtime.setCircles(<Circle>[circleOf(priv)]);
    }
  });

  test('a member with no pref is put on the server by their own phone, once', () async {
    await policyOn();
    final CircleLanes before = await bob.lanes.refresh(priv);
    expect(before.status, LaneStatus.phoneOnly);
    expect(await bob.lanes.autoApplyIfDue(priv, autoApply: true), AutoApplyOutcome.applied);
    final CircleLanes after = await bob.lanes.refresh(priv, force: true);
    expect(after.status, LaneStatus.serverAssisted);
    // The signature is Bob's own, in the log: his lane is verified, Carol's still is not.
    expect(after.members.firstWhere((MemberLaneView v) => v.userId == uB).verified, isTrue);
    expect(after.members.firstWhere((MemberLaneView v) => v.userId == uC).serverAssisted, isFalse);
    final AutoApplyRecord? rec = await bob.store.autoRecord(priv);
    expect(rec!.applied && !rec.dismissed, isTrue);
    // Again and again: nothing more is signed.
    final int logLen = server.log.length;
    expect(await bob.lanes.autoApplyIfDue(priv, autoApply: true), AutoApplyOutcome.alreadyHandled);
    expect(server.log.length, logLen);
  });

  test('nothing happens when the admin setting is off (cloud profile prompts instead)', () async {
    await policyOn();
    expect(await bob.lanes.autoApplyIfDue(priv, autoApply: false), AutoApplyOutcome.disabled);
    expect((await bob.lanes.refresh(priv)).status, LaneStatus.phoneOnly);
    // The profile object says the same: a cloud/unset server sends no auto-apply.
    expect(ServerProfile.fromJson(<String, dynamic>{'profile_effective': 'cloud', 'member_defaults': <String, dynamic>{'default_lane': 'phone', 'auto_apply': false}}).autoApply, isFalse);
    expect(ServerProfile.fromJson(<String, dynamic>{'profile_effective': 'home', 'member_defaults': <String, dynamic>{'default_lane': 'server', 'auto_apply': true}}).autoApply, isTrue);
    expect(ServerProfile.fromJson(<String, dynamic>{'profile_effective': 'home'}).autoApply, isFalse, reason: 'an older server sends nothing');
  });

  test('an explicit phone choice is sticky: never overridden, also after a restart of the record', () async {
    await policyOn();
    await bob.lanes.setLane(priv, E2ee.linePhone);
    expect(await bob.lanes.autoApplyIfDue(priv, autoApply: true), AutoApplyOutcome.hasChoice);
    expect((await bob.lanes.refresh(priv, force: true)).status, LaneStatus.phoneOnly);
    // A fresh phone state (no local record) still finds the signed pref in the key log.
    await bob.store.setAutoRecord(priv, const AutoApplyRecord(state: 'declined', atMs: 0));
    expect(await bob.lanes.autoApplyIfDue(priv, autoApply: true), AutoApplyOutcome.alreadyHandled);
  });

  test('an earlier explicit server choice that was voided by turning assistance off is not silently renewed', () async {
    await policyOn();
    await bob.lanes.setLane(priv, E2ee.lineServer, confirmServerFingerprintHex: (await bob.lanes.refresh(priv)).serverKey!.fingerprint);
    await alice.lanes.publishPolicy(priv, serverAssist: false);
    await policyOn();
    expect(await bob.lanes.autoApplyIfDue(priv, autoApply: true), AutoApplyOutcome.hasChoice);
  });

  test('after "Set this phone up again" the server choice signed by the old key no longer counts; it is found for a one-tap re-offer', () async {
    await policyOn();
    await bob.lanes.setLane(priv, E2ee.lineServer, confirmServerFingerprintHex: (await bob.lanes.refresh(priv)).serverKey!.fingerprint);
    expect((await bob.lanes.refresh(priv, force: true)).status, LaneStatus.serverAssisted);
    expect(await bob.lanes.serverChoiceLostToNewKey(priv), isNull, reason: 'the choice still counts');
    final String oldDevice = (await bob.service.identity())!.deviceId;
    // The same person, the phone set up again: a reset revokes every older key of the account.
    final Dev bob2 = Dev(server, channel, uB, clock);
    await bob2.service.registerThisDevice(reset: true);
    await bob2.runtime.setCircles(<Circle>[circleOf(priv)]);
    expect((await bob2.lanes.refresh(priv, force: true)).status, LaneStatus.phoneOnly, reason: 'the pref was signed by a revoked key');
    expect((await bob2.lanes.serverChoiceLostToNewKey(priv))?.oldDeviceId, oldDevice);
    // Auto-apply never re-signs over a choice in the log, so without the re-offer the person would stay off the server.
    expect(await bob2.lanes.autoApplyIfDue(priv, autoApply: true), AutoApplyOutcome.hasChoice);
  });

  test('a phone choice, or no choice at all, is not reported as lost', () async {
    await policyOn();
    expect(await carol.lanes.serverChoiceLostToNewKey(priv), isNull);
    await bob.lanes.setLane(priv, E2ee.linePhone);
    final Dev bob2 = Dev(server, channel, uB, clock);
    await bob2.service.registerThisDevice(reset: true);
    expect(await bob2.lanes.serverChoiceLostToNewKey(priv), isNull);
  });

  test('required_server circles and child accounts are not auto-signed', () async {
    await policyOn(optOut: E2ee.optOutRequiredServer);
    expect(await bob.lanes.autoApplyIfDue(priv, autoApply: true), AutoApplyOutcome.consentRequired);
    await alice.lanes.publishPolicy(priv, serverAssist: true, memberOptOut: E2ee.optOutAllowed);
    server.childUsers.add(uC);
    expect(await carol.lanes.autoApplyIfDue(priv, autoApply: true), AutoApplyOutcome.child);
    expect((await carol.lanes.refresh(priv, force: true)).status, LaneStatus.phoneOnly);
  });

  test('no server assistance or no approved server key: nothing is signed', () async {
    expect(await bob.lanes.autoApplyIfDue(priv, autoApply: true), AutoApplyOutcome.notAvailable);
    await policyOn();
    server.pinnedServerDevice = null;
    expect(await bob.lanes.autoApplyIfDue(priv, autoApply: true), AutoApplyOutcome.notAvailable);
    expect(prefsOf(uB), 0);
  });

  test('"Keep on my phone" signs the phone lane, deletes the server copies and is final', () async {
    await policyOn();
    expect(await bob.lanes.autoApplyIfDue(priv, autoApply: true), AutoApplyOutcome.applied);
    await bob.lanes.keepOnPhone(priv);
    expect(server.circles[priv]!.serverPurges, <String>['mine']);
    expect((await bob.lanes.refresh(priv, force: true)).status, LaneStatus.phoneOnly);
    expect((await bob.store.autoRecord(priv))!.declined, isTrue);
    expect(await bob.lanes.autoApplyIfDue(priv, autoApply: true), AutoApplyOutcome.alreadyHandled);
    expect((await bob.lanes.refresh(priv, force: true)).status, LaneStatus.phoneOnly);
  });

  test('the app-open path applies it, and only for phones that qualify', () async {
    await policyOn();
    server.serverProfileValue = const ServerProfile(known: true, effective: 'home', recommendedLane: 'server', memberDefaultLane: 'server', autoApply: true);
    await bob.runtime.onAppActive(<Circle>[circleOf(priv)]);
    expect((await bob.lanes.refresh(priv, force: true)).status, LaneStatus.serverAssisted);
    // Carol opted out before: the same open does nothing for her.
    await carol.lanes.setLane(priv, E2ee.linePhone);
    await carol.runtime.onAppActive(<Circle>[circleOf(priv)]);
    expect((await carol.lanes.refresh(priv, force: true)).status, LaneStatus.phoneOnly);
    // Without the setting nobody is changed.
    server.serverProfileValue = ServerProfile.unknown;
    final int n = PrivateRuntime.autoApplied.value;
    await alice.runtime.onAppActive(<Circle>[circleOf(priv)]);
    expect(PrivateRuntime.autoApplied.value, n);
  });

  // Section 24: with no administrator choice saved, the circle admin's signed "server by default" counts too.
  test('a circle whose admin signed "server by default" puts members on the server by their own phone', () async {
    await alice.lanes.publishPolicy(priv, serverAssist: true, defaultForNew: E2ee.lineServer);
    expect(await bob.lanes.autoApplyIfDue(priv, autoApply: false), AutoApplyOutcome.disabled, reason: 'not following circle defaults');
    expect(prefsOf(uB), 0);
    expect(await bob.lanes.autoApplyIfDue(priv, autoApply: false, followCircleDefault: true), AutoApplyOutcome.applied);
    expect((await bob.lanes.refresh(priv, force: true)).status, LaneStatus.serverAssisted);
    expect(prefsOf(uB), 1, reason: 'one entry, signed by Bob\'s own phone');
    // Opting out stays final, exactly as with the server-wide setting.
    await bob.lanes.keepOnPhone(priv);
    expect(await bob.lanes.autoApplyIfDue(priv, autoApply: false, followCircleDefault: true), AutoApplyOutcome.alreadyHandled);
    expect((await bob.lanes.refresh(priv, force: true)).status, LaneStatus.phoneOnly);
  });

  test('a circle whose default is "Phone only" is not auto-signed by the circle default', () async {
    await alice.lanes.publishPolicy(priv, serverAssist: true, defaultForNew: E2ee.linePhone);
    expect(await bob.lanes.autoApplyIfDue(priv, autoApply: false, followCircleDefault: true), AutoApplyOutcome.disabled);
    expect(prefsOf(uB), 0);
    // required_server keeps its explicit consent, also with the circle default.
    await alice.lanes.publishPolicy(priv, serverAssist: true, defaultForNew: E2ee.lineServer, memberOptOut: E2ee.optOutRequiredServer);
    expect(await carol.lanes.autoApplyIfDue(priv, autoApply: false, followCircleDefault: true), AutoApplyOutcome.consentRequired);
    expect(prefsOf(uC), 0);
  });

  test('the app-open path follows the circle default only when the server says so', () async {
    await alice.lanes.publishPolicy(priv, serverAssist: true, defaultForNew: E2ee.lineServer);
    server.serverProfileValue = ServerProfile.fromJson(<String, dynamic>{
      'profile_effective': 'cloud',
      'member_defaults': <String, dynamic>{'default_lane': 'phone', 'auto_apply': false, 'follow_circle_default': false},
    });
    expect(server.serverProfileValue.followCircleDefault, isFalse);
    await carol.runtime.onAppActive(<Circle>[circleOf(priv)]);
    expect((await carol.lanes.refresh(priv, force: true)).status, LaneStatus.phoneOnly, reason: 'an administrator saved "no auto-apply"');
    server.serverProfileValue = ServerProfile.fromJson(<String, dynamic>{
      'profile_effective': 'cloud',
      'member_defaults': <String, dynamic>{'default_lane': 'phone', 'auto_apply': false, 'follow_circle_default': true},
    });
    await bob.runtime.onAppActive(<Circle>[circleOf(priv)]);
    expect((await bob.lanes.refresh(priv, force: true)).status, LaneStatus.serverAssisted);
  });

  testWidgets('the first-time notice names the choice; "Keep on my phone" runs the undo, OK only dismisses', (t) async {
    final List<String> kept = <String>[], dismissed = <String>[];
    List<AutoNotice> shown = const <AutoNotice>[AutoNotice('c1', 'Family')];
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: AutoApplyNotice(loader: () async => shown, keep: (String id) async => kept.add(id), dismiss: (String id) async => dismissed.add(id)))));
    await t.pumpAndSettle();
    expect(find.text(autoApplyNoticeText), findsOneWidget);
    expect(autoApplyNoticeText, 'Your circle uses the server so maps, history and driving reports work. Tap to keep your data on your phone.');
    shown = const <AutoNotice>[];
    await t.tap(find.byKey(const Key('auto-apply-ok')));
    await t.pumpAndSettle();
    expect(dismissed, <String>['c1']);
    expect(kept, isEmpty);
    expect(find.byKey(const Key('auto-apply-notice')), findsNothing);

    shown = const <AutoNotice>[AutoNotice('c2', 'Trip')];
    await t.pumpWidget(MaterialApp(
        home: Scaffold(key: UniqueKey(), body: AutoApplyNotice(loader: () async => shown, keep: (String id) async => kept.add(id), dismiss: (String id) async => dismissed.add(id)))));
    await t.pumpAndSettle();
    shown = const <AutoNotice>[];
    await t.tap(find.byKey(const Key('auto-apply-keep')));
    await t.pumpAndSettle();
    expect(kept, <String>['c2']);
  });
}

