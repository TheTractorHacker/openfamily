import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/circle.dart';
import 'package:openfamily/screens/circle_create_screen.dart';
import 'package:openfamily/screens/create_circle_screen.dart';
import 'package:openfamily/services/e2ee/e2ee_crypto.dart';
import 'package:openfamily/services/e2ee/e2ee_models.dart';
import 'package:openfamily/services/e2ee/new_circle_setup.dart';

import '../support/fake_processing_controller.dart';
import 'circles_screens_test.dart' show FakeCircleService;

// "End-to-end encryption out of the box" (docs/design/PRIVACY_PROCESSING.md section 24): a new circle is Private with
// the server switched on when the server can take part, the creator signs only their OWN lane, and every other
// outcome (server waiting for approval, no server) ends in a plain message instead of a dead end.

const ServerProfile builtinServer = ServerProfile(
  known: true,
  profile: '',
  effective: 'cloud',
  enabled: true,
  builtin: true,
  device: ServerDeviceInfo(deviceId: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd', fingerprint: fakeFp, short: 'ab12 cd34', digits: '11111 22222', label: 'Server', ownerUserId: pA),
);
const ServerJoinInfo joining =
    ServerJoinInfo(builtin: true, waiting: true, canApprove: true, short: 'ab12 cd34 ef56 7890', digits: '11111 22222', deviceId: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd');

/// A brand-new Private circle: only me, the server off, the server key approved (or not).
FakeProcessingController freshCircle({bool serverKey = true, ServerProfile profile = builtinServer, ServerJoinInfo join = ServerJoinInfo.none}) =>
    FakeProcessingController(FakeProcessingController.snapshot(assist: false, serverKey: serverKey, lanes: const <String, int>{pA: E2ee.linePhone}))
      ..profile = profile
      ..join = join;

List<String> signed(FakeProcessingController c) => c.calls.where((String x) => x != 'load').toList();

/// Opens [screen] from a base page with a Scaffold (so messages stay visible after it pops) and records the result.
Future<List<Circle?>> launch(WidgetTester t, Widget screen) async {
  final List<Circle?> popped = <Circle?>[];
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (BuildContext ctx) => TextButton(
          onPressed: () async => popped.add(await Navigator.of(ctx).push<Circle>(MaterialPageRoute<Circle>(builder: (_) => screen))),
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await t.tap(find.text('open'));
  await t.pumpAndSettle();
  return popped;
}

/// The busy button keeps spinning while the sheet is open (or after the step hands over), so pumpAndSettle would never settle.
Future<void> spin(WidgetTester t) async {
  for (int i = 0; i < 20; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

Future<void> big(WidgetTester t) async {
  t.view.physicalSize = const Size(800, 2600);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
}

void main() {
  group('NewCircleSetup', () {
    test('the server option is offered when the server has a key, runs the built-in device or asks to join', () async {
      expect(await NewCircleSetup(freshCircle()).serverAvailable(), isTrue);
      expect(await NewCircleSetup(freshCircle(profile: ServerProfile.unknown)).serverAvailable(), isFalse, reason: 'older server, nothing waiting');
      expect(await NewCircleSetup(freshCircle(profile: ServerProfile.unknown, join: joining)).serverAvailable(), isTrue);
    });

    test('approved server key: the policy says "server by default" and only the creator\'s own lane is signed', () async {
      final FakeProcessingController c = freshCircle();
      expect(await NewCircleSetup(c).turnOn('c1'), NewCircleServerOutcome.serverOn);
      expect(signed(c), <String>['policy:true:server:allowed', 'lane:server:fp=$fakeFp:del=false']);
    });

    test('"Everyone must use the server" publishes required_server', () async {
      final FakeProcessingController c = freshCircle();
      expect(await NewCircleSetup(c).turnOn('c1', requireServer: true), NewCircleServerOutcome.serverOn);
      expect(signed(c), <String>['policy:true:server:required_server', 'lane:server:fp=$fakeFp:del=false']);
    });

    test('the server waits for this phone\'s approval: nothing is signed, the sheet takes over', () async {
      final FakeProcessingController c = freshCircle(serverKey: false, join: joining);
      expect(await NewCircleSetup(c).turnOn('c1'), NewCircleServerOutcome.approveServer);
      expect(signed(c), isEmpty);
    });

    test('only a server administrator can approve: the creator is told, nothing is signed', () async {
      final FakeProcessingController c = freshCircle(serverKey: false, join: const ServerJoinInfo(builtin: true, waiting: true, canApprove: false));
      expect(await NewCircleSetup(c).turnOn('c1'), NewCircleServerOutcome.waitingForServerAdmin);
      expect(signed(c), isEmpty);
    });

    test('two answers about the server key that disagree stop it', () async {
      final FakeProcessingController c = freshCircle(
          profile: const ServerProfile(
              known: true,
              enabled: true,
              device: ServerDeviceInfo(deviceId: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd', fingerprint: 'ff', short: 'x', digits: 'y', label: 'S', ownerUserId: pA)));
      expect(await NewCircleSetup(c).turnOn('c1'), NewCircleServerOutcome.keyConflict);
      expect(signed(c), isEmpty);
    });

    test('no server device: phones only', () async {
      final FakeProcessingController c = freshCircle(serverKey: false, profile: ServerProfile.unknown);
      expect(await NewCircleSetup(c).turnOn('c1'), NewCircleServerOutcome.unavailable);
      expect(signed(c), isEmpty);
    });
  });

  group('New circle screen', () {
    testWidgets('with a server that can take part, "Private, with your server" is preselected and one tap does it all', (t) async {
      await big(t);
      final FakeProcessingController c = freshCircle();
      final List<String> madePrivate = <String>[];
      final List<Circle?> popped =
          await launch(t, CircleCreateScreen(service: FakeCircleService(), setup: NewCircleSetup(c), makePrivate: (String id) async => madePrivate.add(id)));
      final Icon icon = t.widget<Icon>(find.descendant(of: find.byKey(const Key('mode-private-server')), matching: find.byType(Icon)));
      expect(icon.icon, Icons.radio_button_checked);
      expect(find.textContaining('Everyone is on the server by default and can switch it off'), findsOneWidget);
      expect(find.text('Normal, no end-to-end encryption'), findsOneWidget);
      await t.enterText(find.byType(TextField), 'Family');
      await t.tap(find.text('Create circle'));
      await t.pumpAndSettle();
      expect(madePrivate, <String>['new']);
      expect(signed(c), <String>['policy:true:server:allowed', 'lane:server:fp=$fakeFp:del=false']);
      expect(popped.single?.isPrivate, isTrue);
      expect(popped.single?.serverAssist, isTrue);
      expect(find.textContaining('everyone who joins is on the server by default'), findsOneWidget);
    });

    testWidgets('"Everyone must use the server" is offered under the server option and publishes required_server', (t) async {
      await big(t);
      final FakeProcessingController c = freshCircle();
      await t.pumpWidget(MaterialApp(home: CircleCreateScreen(service: FakeCircleService(), setup: NewCircleSetup(c), makePrivate: (String id) async {})));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('mode-require-server')));
      await t.pump();
      await t.enterText(find.byType(TextField), 'Kids');
      await t.tap(find.text('Create circle'));
      await t.pumpAndSettle();
      expect(signed(c).first, 'policy:true:server:required_server');
    });

    testWidgets('phones only: Private, nothing about the server is signed', (t) async {
      await big(t);
      final FakeProcessingController c = freshCircle();
      final List<String> madePrivate = <String>[];
      await t.pumpWidget(MaterialApp(home: CircleCreateScreen(service: FakeCircleService(), setup: NewCircleSetup(c), makePrivate: (String id) async => madePrivate.add(id))));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('mode-private')));
      await t.pump();
      expect(find.byKey(const Key('mode-require-server')), findsNothing);
      await t.enterText(find.byType(TextField), 'Friends');
      await t.tap(find.text('Create circle'));
      await t.pumpAndSettle();
      expect(madePrivate, <String>['new']);
      expect(signed(c), isEmpty);
    });

    testWidgets('no server device: Normal stays the recommended default and no server option is shown', (t) async {
      await big(t);
      final FakeProcessingController c = freshCircle(serverKey: false, profile: ServerProfile.unknown);
      final List<String> madePrivate = <String>[];
      await t.pumpWidget(MaterialApp(home: CircleCreateScreen(service: FakeCircleService(), setup: NewCircleSetup(c), makePrivate: (String id) async => madePrivate.add(id))));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('mode-private-server')), findsNothing);
      expect(find.text('Normal (recommended)'), findsOneWidget);
      await t.enterText(find.byType(TextField), 'Family');
      await t.tap(find.text('Create circle'));
      await t.pumpAndSettle();
      expect(madePrivate, isEmpty);
      expect(signed(c), isEmpty);
    });

    testWidgets('the server waits for my approval: the "Your server wants to join" sheet opens right away', (t) async {
      await big(t);
      final FakeProcessingController c = freshCircle(serverKey: false, join: joining);
      c.onServerApproved = () => c.snap = FakeProcessingController.snapshot(assist: false, serverKey: true, lanes: const <String, int>{pA: E2ee.linePhone});
      await t.pumpWidget(MaterialApp(home: CircleCreateScreen(service: FakeCircleService(), setup: NewCircleSetup(c), makePrivate: (String id) async {})));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), 'Family');
      await t.tap(find.text('Create circle'));
      await spin(t);
      expect(find.byKey(const Key('add-server-join-intro')), findsOneWidget);
      await t.tap(find.byKey(const Key('add-server-next')));
      await spin(t);
      await t.tap(find.byKey(const Key('add-server-same')));
      await spin(t);
      await t.tap(find.byKey(const Key('add-server-ok')));
      await spin(t);
      expect(signed(c), <String>['approve-server-join', 'policy:true:server:allowed', 'lane:server:fp=$fakeFp:del=false']);
      expect(find.byKey(const Key('add-server-success')), findsOneWidget);
    });

    testWidgets('a server only an administrator can approve: a plain message, the circle is created anyway', (t) async {
      await big(t);
      final FakeProcessingController c = freshCircle(serverKey: false, profile: ServerProfile.unknown, join: const ServerJoinInfo(builtin: true, waiting: true, canApprove: false));
      await launch(t, CircleCreateScreen(service: FakeCircleService(), setup: NewCircleSetup(c), makePrivate: (String id) async {}));
      await t.enterText(find.byType(TextField), 'Family');
      await t.tap(find.text('Create circle'));
      await t.pumpAndSettle();
      expect(find.textContaining('waiting for its administrator to approve it once'), findsOneWidget);
      expect(signed(c), isEmpty);
    });
  });

  group('first-run "Create a family"', () {
    testWidgets('the family starts Private with the server on, then continues to the invite step', (t) async {
      await big(t);
      final FakeProcessingController c = freshCircle();
      final List<String> madePrivate = <String>[], created = <String>[];
      String? next;
      await t.pumpWidget(MaterialApp(
          home: CreateCircleScreen(
        setup: NewCircleSetup(c),
        makePrivate: (String id) async => madePrivate.add(id),
        createFamily: (String name) async {
          created.add(name);
          return <String, dynamic>{'id': 'fam-1', 'name': name};
        },
        onCreated: (String name) => next = name,
      )));
      await t.pumpAndSettle();
      expect(t.widget<Icon>(find.descendant(of: find.byKey(const Key('mode-private-server')), matching: find.byType(Icon))).icon,
          Icons.radio_button_checked);
      await t.tap(find.text('Create family'));
      await spin(t);
      expect(created, <String>['My Family']);
      expect(madePrivate, <String>['fam-1']);
      expect(signed(c), <String>['policy:true:server:allowed', 'lane:server:fp=$fakeFp:del=false']);
      expect(next, 'My Family');
    });

    testWidgets('Normal chosen: no encryption setup, straight on', (t) async {
      await big(t);
      final FakeProcessingController c = freshCircle();
      final List<String> madePrivate = <String>[];
      String? next;
      await t.pumpWidget(MaterialApp(
          home: CreateCircleScreen(
        setup: NewCircleSetup(c),
        makePrivate: (String id) async => madePrivate.add(id),
        createFamily: (String name) async => <String, dynamic>{'id': 'fam-1', 'name': name},
        onCreated: (String name) => next = name,
      )));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('mode-normal')));
      await t.pump();
      await t.tap(find.text('Create family'));
      await spin(t);
      expect(madePrivate, isEmpty);
      expect(signed(c), isEmpty);
      expect(next, 'My Family');
    });
  });
}
