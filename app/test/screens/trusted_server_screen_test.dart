import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/circle.dart';
import 'package:openfamily/screens/trusted_server_screen.dart';
import 'package:openfamily/screens/viewer_approval_screen.dart';
import 'package:openfamily/services/e2ee/e2ee_service.dart';
import 'package:openfamily/services/e2ee/e2ee_trust.dart';
import 'package:openfamily/services/e2ee/e2ee_vault.dart';
import 'package:openfamily/widgets/private_circle_widgets.dart';

import '../support/fake_e2ee_server.dart';
import '../support/viewer_fixture.dart';

const String uA = '11111111-1111-4111-8111-111111111111';
const String uB = '22222222-2222-4222-8222-222222222222';
const String cid = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';

void tall(WidgetTester t) {
  t.view.physicalSize = const Size(800, 6000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
}

Future<void> settle(WidgetTester t) async {
  for (int i = 0; i < 3; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  late FakeE2eeServer server;
  late E2eeService alice, bob;
  late ViewerFixture srv;

  E2eeService mk(String u) => E2eeService(api: server.client(u), vault: MemoryVault(), trust: TrustStore(MemoryTrustKv()), userIdProvider: () async => u);

  Future<void> setup(WidgetTester t, {bool enabled = true, bool withKey = true, String role = 'admin'}) async {
    server = FakeE2eeServer()..names.addAll(<String, String>{uA: 'Alice', uB: 'Bob'});
    server.circle(cid, members: <String>[uA, uB], admin: uA);
    alice = mk(uA);
    bob = mk(uB);
    await t.runAsync(() async {
      await alice.registerThisDevice();
      await bob.registerThisDevice();
      await alice.enableCircle(cid);
      if (withKey) {
        srv = await ViewerFixture.create(uA);
        final String ap = await alice.approveLinkRequest(await alice.inspectViewerRequest(await srv.request(kind: 'server', name: 'OpenFamily server')));
        await srv.register(server, ap, kind: 'server', label: 'OpenFamily server');
        server.pinnedServerDevice = srv.deviceId;
      }
    });
    server.serverModeEnabled = enabled;
    tall(t);
    await t.pumpWidget(MaterialApp(
        home: TrustedServerScreen(
            circle: Circle(id: cid, name: 'Family', role: role, sharingEnabled: true, memberCount: 2), service: alice)));
    await settle(t);
  }

  testWidgets('default server without the mode: explains it is off and offers nothing to allow', (t) async {
    await setup(t, enabled: false, withKey: false);
    expect(find.byKey(const Key('server-disabled')), findsOneWidget);
    expect(find.byKey(const Key('server-allow')), findsNothing);
    expect(find.byKey(const Key('server-warning')), findsOneWidget);
  });

  testWidgets('no pinned key yet: tells how to enroll', (t) async {
    await setup(t, withKey: false);
    expect(find.byKey(const Key('server-no-key')), findsOneWidget);
    expect(find.byKey(const Key('server-allow')), findsNothing);
  });

  testWidgets('shows the server fingerprint and a strong warning; allow needs an explicit confirmation', (t) async {
    await setup(t);
    expect(find.byKey(const Key('server-name')), findsOneWidget);
    expect(find.byKey(const Key('server-short')), findsOneWidget);
    expect(find.textContaining('can READ the location of every member'), findsOneWidget);
    expect(find.textContaining('NOT end-to-end encryption against the server'), findsOneWidget);
    expect(find.text('The server cannot read this circle yet'), findsOneWidget);

    await t.tap(find.byKey(const Key('server-allow')));
    await settle(t);
    expect(find.text('I understand: allow the server'), findsOneWidget);
    // Cancelling consents to nothing.
    await t.tap(find.text('Cancel'));
    await settle(t);
    expect(server.circles[cid]!.serverConsents, isEmpty);

    await t.tap(find.byKey(const Key('server-allow')));
    await settle(t);
    await t.tap(find.text('I understand: allow the server'));
    await settle(t);
    expect(server.circles[cid]!.serverConsents.keys, <String>[uA]);
    // Bob has not allowed it yet: still not readable, key not offered.
    expect(find.text('The server cannot read this circle yet'), findsOneWidget);
    expect(find.byKey(const Key('server-withdraw')), findsOneWidget);
    expect(find.byKey(const Key('server-share')), findsNothing);
    expect(find.text('Has not allowed it'), findsOneWidget);
  });

  testWidgets('once everyone allowed it the admin can hand over the key; withdraw is one tap away', (t) async {
    await setup(t);
    await t.runAsync(() => bob.consentToServer(cid));
    await t.tap(find.byKey(const Key('server-allow')));
    await settle(t);
    await t.tap(find.text('I understand: allow the server'));
    await settle(t);
    expect(find.byKey(const Key('server-share')), findsOneWidget);
    await t.tap(find.byKey(const Key('server-share')));
    await settle(t);
    expect(server.circles[cid]!.wraps.containsKey('1/${srv.deviceId}'), isTrue);

    await t.tap(find.byKey(const Key('server-withdraw')));
    await settle(t);
    await t.tap(find.text('Withdraw'));
    await settle(t);
    expect(server.circles[cid]!.serverConsents.containsKey(uA), isFalse);
    expect(server.circles[cid]!.rekey, isTrue);
  });

  testWidgets('purge options: members delete their copies, admins the whole circle', (t) async {
    await setup(t);
    await t.tap(find.byKey(const Key('server-purge-mine')));
    await settle(t);
    await t.tap(find.text('Delete copies'));
    await settle(t);
    expect(server.circles[cid]!.serverPurges, <String>['mine']);
    await t.tap(find.byKey(const Key('server-purge-all')));
    await settle(t);
    await t.tap(find.text('Delete copies'));
    await settle(t);
    expect(server.circles[cid]!.serverPurges, <String>['mine', 'circle']);
  });

  testWidgets('a non-admin does not see the whole-circle purge', (t) async {
    await setup(t, role: 'member');
    expect(find.byKey(const Key('server-purge-mine')), findsOneWidget);
    expect(find.byKey(const Key('server-purge-all')), findsNothing);
  });

  testWidgets('the viewer approval screen words the server key distinctly and warns', (t) async {
    await setup(t, withKey: false);
    tall(t);
    await t.pumpWidget(MaterialApp(
        home: ViewerApprovalScreen(circle: const Circle(id: cid, name: 'Family', role: 'admin', sharingEnabled: true, memberCount: 2), service: alice)));
    await settle(t);
    final ViewerFixture v = (await t.runAsync(() => ViewerFixture.create(uA)))!;
    await t.enterText(find.byKey(const Key('viewer-code')), (await t.runAsync(() => v.request(kind: 'server', name: 'OpenFamily server')))!);
    await t.tap(find.text('Inspect'));
    await settle(t);
    expect(find.text('OpenFamily server (can read the circle)'), findsOneWidget);
    expect(find.byKey(const Key('viewer-server-warning')), findsOneWidget);
    expect(find.textContaining('SERVER itself'), findsOneWidget);
    expect(find.textContaining('every member of that circle'), findsOneWidget);
  });

  testWidgets('the circle badge says the server can read, not "End-to-end encrypted"', (t) async {
    await t.pumpWidget(const MaterialApp(home: Scaffold(body: Column(children: <Widget>[
      PrivateCircleBadge(),
      PrivateCircleBadge(serverMember: true),
      PrivateCircleBadge(serverMember: true, compact: true),
    ]))));
    expect(find.text('End-to-end encrypted'), findsOneWidget);
    expect(find.text('Server can read (trusted server)'), findsOneWidget);
    expect(find.text('Server can read'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('OpenFamily server can read locations')), findsNWidgets(2));
  });

  test('Circle model carries e2ee_server_member only for private circles', () {
    Circle c(Map<String, dynamic> extra) => Circle.fromJson(<String, dynamic>{
          'id': cid, 'name': 'x', 'role': 'admin', 'sharing_enabled': true, 'member_count': 1, 'created_by': uA, 'created_at': '2026-01-01T00:00:00Z', ...extra,
        });
    expect(c(<String, dynamic>{'e2ee_mode': 'private', 'e2ee_server_member': true}).e2eeServerMember, isTrue);
    expect(c(<String, dynamic>{'e2ee_mode': 'off', 'e2ee_server_member': true}).e2eeServerMember, isFalse);
    expect(c(<String, dynamic>{'e2ee_mode': 'private'}).e2eeServerMember, isFalse);
    expect(c(<String, dynamic>{}).e2eeServerMember, isFalse);
  });
}
