import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/circle.dart';
import 'package:openfamily/screens/encryption_circle_screen.dart';
import 'package:openfamily/services/e2ee/e2ee_models.dart';
import 'package:openfamily/services/e2ee/e2ee_service.dart';
import 'package:openfamily/services/e2ee/e2ee_trust.dart';
import 'package:openfamily/services/e2ee/e2ee_vault.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_e2ee_server.dart';

const String uA = '11111111-1111-4111-8111-111111111111';
const String uB = '22222222-2222-4222-8222-222222222222';
const String cid = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';

Future<void> settle(WidgetTester t) async {
  for (int i = 0; i < 3; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
    await t.pump(const Duration(milliseconds: 100));
  }
}

E2eeService phone(FakeE2eeServer s, String user) =>
    E2eeService(api: s.client(user), vault: MemoryVault(), trust: TrustStore(MemoryTrustKv()), userIdProvider: () async => user);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  late FakeE2eeServer server;
  late E2eeService a2;
  late DeviceKey newKey;

  /// Alice created the circle and is its only admin; she set her phone up again.
  Future<void> setup(WidgetTester t, {bool ownerApproval = false}) async {
    server = FakeE2eeServer()..names.addAll(<String, String>{uA: 'Alice', uB: 'Bob'});
    server.circle(cid, members: <String>[uA, uB], admin: uA);
    await t.runAsync(() async {
      final E2eeService a = phone(server, uA), b = phone(server, uB);
      await a.registerThisDevice();
      await b.registerThisDevice();
      await a.enableCircle(cid);
      a2 = phone(server, uA);
      newKey = await a2.registerThisDevice(reset: true);
      server.circles[cid]!.rekey = true;
      if (ownerApproval) await a2.setOwnerApproval(cid, true, password: FakeCircle.password);
    });
    t.view.physicalSize = const Size(800, 4000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(MaterialApp(
        home: EncryptionCircleScreen(
            circle: const Circle(id: cid, name: 'Foley Family', role: 'admin', sharingEnabled: true, memberCount: 2), service: a2)));
    await settle(t);
  }

  testWidgets('sole admin, rule off: plain words and the two ways out', (t) async {
    await setup(t);
    expect(find.text('Waiting for approval'), findsOneWidget);
    expect(
        find.text("You're the only admin. Make another member an admin so they can approve this phone, or turn on owner approval for this circle."),
        findsOneWidget);
    expect(find.byKey(const Key('enable-owner-approval')), findsOneWidget);
    expect(find.byKey(const Key('open-members')), findsOneWidget);
    expect(find.byKey(const Key('approve-as-owner')), findsNothing);
    // The new circle key can only be published once this phone is approved.
    expect(find.text('A new circle key is needed'), findsOneWidget);
    expect(find.byKey(const Key('publish-new-key')), findsOneWidget);
    expect(find.byKey(const Key('owner-approval-toggle')), findsOneWidget);
  });

  testWidgets('rule on: Approve as owner asks for the password and approves', (t) async {
    await setup(t, ownerApproval: true);
    expect(find.byKey(const Key('approve-as-owner')), findsOneWidget);
    expect(find.textContaining('approve it yourself'), findsOneWidget);
    await t.tap(find.byKey(const Key('approve-as-owner')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('owner-stepup-password')), FakeCircle.password);
    await t.tap(find.widgetWithText(FilledButton, 'Approve'));
    await settle(t);
    expect(server.circles[cid]!.selfApprovals, contains(newKey.deviceId));
    expect(find.text('Waiting for approval'), findsNothing);
  });
}
