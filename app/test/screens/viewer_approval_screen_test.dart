import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/circle.dart';
import 'package:openfamily/screens/viewer_approval_screen.dart';
import 'package:openfamily/services/e2ee/e2ee_crypto.dart';
import 'package:openfamily/services/e2ee/e2ee_models.dart';
import 'package:openfamily/services/e2ee/e2ee_service.dart';
import 'package:openfamily/services/e2ee/e2ee_trust.dart';
import 'package:openfamily/services/e2ee/e2ee_vault.dart';

import '../support/fake_e2ee_server.dart';
import '../support/viewer_fixture.dart';

const String uA = '11111111-1111-4111-8111-111111111111';
const String uB = '22222222-2222-4222-8222-222222222222';
const String cid = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';

/// Counts the calls the screen makes to the service.
class SpySvc extends E2eeService {
  SpySvc({required super.api, required super.vault, required super.trust, required super.userIdProvider});
  int bumps = 0;
  bool skipAuto = false;
  @override
  Future<PendingReport> processPending(String circleId) => skipAuto ? Future<PendingReport>.value(const PendingReport()) : super.processPending(circleId);
  final List<String> revoked = <String>[];
  @override
  Future<int> bumpEpoch(String circleId) {
    bumps++;
    return super.bumpEpoch(circleId);
  }

  @override
  Future<void> revokeKey(DeviceKey key) {
    revoked.add(key.deviceId);
    return super.revokeKey(key);
  }
}

void tall(WidgetTester t) {
  t.view.physicalSize = const Size(800, 6000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
}

void main() {
  late FakeE2eeServer server;
  late SpySvc alice;
  late E2eeService bob;

  SpySvc mk(String u) => SpySvc(api: server.client(u), vault: MemoryVault(), trust: TrustStore(MemoryTrustKv()), userIdProvider: () async => u);

  Future<void> settle(WidgetTester t) async {
    for (int i = 0; i < 3; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> setup(WidgetTester t, {String role = 'admin'}) async {
    server = FakeE2eeServer()..names.addAll(<String, String>{uA: 'Alice', uB: 'Bob'});
    server.circle(cid, members: <String>[uA, uB], admin: uA);
    alice = mk(uA);
    bob = mk(uB);
    await t.runAsync(() async {
      await alice.registerThisDevice();
      await bob.registerThisDevice();
      await alice.enableCircle(cid);
    });
    tall(t);
    await t.pumpWidget(MaterialApp(
        home: ViewerApprovalScreen(
            circle: Circle(id: cid, name: 'Family', role: role, sharingEnabled: true, memberCount: 2), service: alice)));
    await settle(t);
  }

  Future<void> paste(WidgetTester t, String code) async {
    await t.enterText(find.byKey(const Key('viewer-code')), code);
    await t.tap(find.text('Inspect'));
    await settle(t);
  }

  Future<ViewerFixture> pair(WidgetTester t, String owner, E2eeService phone, {String kind = 'web', String name = 'Browser'}) async {
    return (await t.runAsync(() async {
      final ViewerFixture v = await ViewerFixture.create(owner);
      final String ap = await phone.approveLinkRequest(await phone.inspectViewerRequest(await v.request(kind: kind, name: name)));
      await v.register(server, ap, kind: kind, label: name);
      return v;
    }))!;
  }

  testWidgets('inspect shows name, kind, digits, warning and compare hint', (t) async {
    await setup(t);
    final ViewerFixture v = (await t.runAsync(() => ViewerFixture.create(uA)))!;
    await paste(t, (await t.runAsync(() => v.request(kind: 'service', name: 'My Dawarich')))!);
    expect(find.text('My Dawarich'), findsOneWidget);
    expect(find.text('Dawarich bridge (server process)'), findsOneWidget);
    final Uint8List fp = (await t.runAsync(() => v.fingerprint()))!;
    expect(find.text('Key: ${E2ee.shortFingerprint(fp)}'), findsOneWidget);
    final String digits = (await t.runAsync(() => E2ee.digitGroups(fp)))!;
    for (final String g in digits.split(' ').take(3)) {
      expect(find.textContaining(g), findsWidgets);
    }
    expect(find.textContaining('can READ the location of every member'), findsOneWidget);
    expect(find.textContaining('Compare these digits'), findsOneWidget);
    expect(find.text('It matches: approve'), findsOneWidget);
  });

  testWidgets('web kind is worded as a browser viewer', (t) async {
    await setup(t);
    final ViewerFixture v = (await t.runAsync(() => ViewerFixture.create(uA)))!;
    await paste(t, (await t.runAsync(() => v.request()))!);
    expect(find.text('Web viewer (browser)'), findsOneWidget);
  });

  testWidgets('code of another account and phone codes are rejected with a clear message', (t) async {
    await setup(t);
    final ViewerFixture other = (await t.runAsync(() => ViewerFixture.create(uB)))!;
    await paste(t, (await t.runAsync(() => other.request()))!);
    expect(find.textContaining('another account'), findsOneWidget);
    expect(find.byKey(const Key('viewer-name')), findsNothing);

    final ViewerFixture mine = (await t.runAsync(() => ViewerFixture.create(uA)))!;
    await paste(t, (await t.runAsync(() => mine.request(kind: 'device')))!);
    expect(find.textContaining('Link another phone'), findsOneWidget);
    await paste(t, (await t.runAsync(() => mine.request(kind: null, name: null)))!);
    expect(find.textContaining('Link another phone'), findsOneWidget);
    await paste(t, 'not a code!!');
    expect(find.textContaining('not a valid request code'), findsOneWidget);
  });

  testWidgets('approve shows an approval code that verifies; cancel clears', (t) async {
    await setup(t);
    final ViewerFixture v = (await t.runAsync(() => ViewerFixture.create(uA)))!;
    await paste(t, (await t.runAsync(() => v.request()))!);
    await t.tap(find.text('It matches: approve'));
    await settle(t);
    final String code = (t.widget(find.byKey(const Key('viewer-approval'))) as SelectableText).data!;
    final DeviceKey k = (await t.runAsync(() => v.register(server, code)))!;
    expect(await t.runAsync(() => verifyRegistration(k)), isTrue);
    expect(find.text('Copy approval'), findsOneWidget);
    await t.tap(find.text('Cancel'));
    await t.pump();
    expect(find.byKey(const Key('viewer-approval')), findsNothing);
    expect(find.byKey(const Key('viewer-name')), findsNothing);
  });

  testWidgets('a pending viewer that lacks a key can be shared or denied', (t) async {
    await setup(t);
    alice.skipAuto = true; // as if automatic wrapping had not run yet
    final ViewerFixture v1 = await pair(t, uA, alice, name: 'Pending one');
    final ViewerFixture v2 = await pair(t, uA, alice, kind: 'service', name: 'Pending two');
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(MaterialApp(
        home: ViewerApprovalScreen(
            circle: const Circle(id: cid, name: 'Family', role: 'admin', sharingEnabled: true, memberCount: 2), service: alice)));
    await settle(t);
    expect(find.byKey(Key('waiting-${v1.deviceId}')), findsOneWidget);
    expect(find.byKey(Key('waiting-${v2.deviceId}')), findsOneWidget);
    expect(find.text('Dawarich bridge (server process), key ${E2ee.shortFingerprint((await t.runAsync(() => v2.fingerprint()))!)}'), findsWidgets);

    // Share key: the viewer can unwrap with its own x25519 secret.
    await t.tap(find.byKey(Key('share-${v1.deviceId}')));
    await settle(t);
    expect(find.byKey(Key('waiting-${v1.deviceId}')), findsNothing);
    final E2eeService viewer = mk(uA);
    final int n = (await t.runAsync(() async {
      await viewer.identity(create: true);
      return viewer.syncCircleKeys(cid, asDeviceId: v1.deviceId, xSecret: v1.xSecret, xPub: v1.xPub);
    }))!;
    expect(n, 1);

    // Deny: revokeKey is called after confirmation and the entry disappears.
    await t.tap(find.byKey(Key('deny-${v2.deviceId}')));
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.text('Deny').last);
    await settle(t);
    expect(alice.revoked, <String>[v2.deviceId]);
    expect(find.byKey(Key('waiting-${v2.deviceId}')), findsNothing);
  });

  testWidgets('connected viewers list; revoke as admin revokes and rotates the epoch', (t) async {
    await setup(t);
    final ViewerFixture v = await pair(t, uA, alice, name: 'Kitchen tablet');
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(MaterialApp(
        home: ViewerApprovalScreen(
            circle: const Circle(id: cid, name: 'Family', role: 'admin', sharingEnabled: true, memberCount: 2), service: alice)));
    await settle(t);
    expect(find.byKey(Key('connected-${v.deviceId}')), findsOneWidget);
    expect(find.text('Kitchen tablet'), findsOneWidget);
    await t.tap(find.byKey(Key('revoke-${v.deviceId}')));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('Data it already received stays readable'), findsOneWidget);
    await t.tap(find.text('Revoke').last);
    await settle(t);
    expect(alice.revoked, <String>[v.deviceId]);
    expect(alice.bumps, 1);
    expect(server.circles[cid]!.epoch, 2);
    expect(find.byKey(Key('connected-${v.deviceId}')), findsNothing);
  });

  testWidgets('revoke as a non-admin does not rotate and says an admin must', (t) async {
    await setup(t, role: 'member');
    final ViewerFixture v = await pair(t, uA, alice, name: 'Den PC');
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(MaterialApp(
        home: ViewerApprovalScreen(
            circle: const Circle(id: cid, name: 'Family', role: 'member', sharingEnabled: true, memberCount: 2), service: alice)));
    await settle(t);
    await t.tap(find.byKey(Key('revoke-${v.deviceId}')));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('an admin has to rotate'), findsOneWidget);
    await t.tap(find.text('Revoke').last);
    await settle(t);
    expect(alice.revoked, <String>[v.deviceId]);
    expect(alice.bumps, 0);
    expect(server.circles[cid]!.rekey, isTrue);
  });

  testWidgets("other members' viewers are listed read-only", (t) async {
    await setup(t);
    final ViewerFixture v = await pair(t, uB, bob, name: 'Bob laptop');
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(MaterialApp(
        home: ViewerApprovalScreen(
            circle: const Circle(id: cid, name: 'Family', role: 'admin', sharingEnabled: true, memberCount: 2), service: alice)));
    await settle(t);
    expect(find.text("OTHER MEMBERS' VIEWERS"), findsOneWidget);
    expect(find.textContaining('Bob laptop (Bob)'), findsOneWidget);
    expect(find.byKey(Key('revoke-${v.deviceId}')), findsNothing);
    expect(find.byKey(Key('connected-${v.deviceId}')), findsNothing);
  });
}
