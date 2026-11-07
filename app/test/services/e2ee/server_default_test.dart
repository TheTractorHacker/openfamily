import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/circle.dart';
import 'package:openfamily/services/e2ee/add_server_flow.dart';
import 'package:openfamily/services/e2ee/e2ee_crypto.dart';
import 'package:openfamily/services/e2ee/e2ee_models.dart';
import 'package:openfamily/widgets/server_prompts.dart';

import '../../support/fake_processing_controller.dart';

const ServerProfile homeServer = ServerProfile(known: true, profile: 'home', effective: 'home', recommendedLane: 'server', enabled: true, builtin: true);
const ServerJoinInfo joining = ServerJoinInfo(builtin: true, waiting: true, canApprove: true, short: 'ab12 cd34 ef56 7890', digits: '11111 22222', deviceId: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd');

Circle circle({bool admin = true, bool assist = false, bool myServer = false, String mode = 'private', String id = 'c1'}) =>
    Circle(id: id, name: 'Family', role: admin ? 'admin' : 'member', sharingEnabled: true, memberCount: 2, e2eeMode: mode, serverAssist: assist, myLaneServer: myServer);

void main() {
  group('server by default', () {
    test('the server recommends its own lane whenever it says so (home or admin choice)', () {
      expect(const ServerProfile(recommendedLane: 'server', effective: 'cloud').serverRecommended, isTrue);
      expect(const ServerProfile(recommendedLane: 'phone', effective: 'home').serverRecommended, isFalse);
    });

    test('a built-in server that asks to join: the admin approves with the same three steps and one OK', () async {
      final FakeProcessingController c = FakeProcessingController(FakeProcessingController.snapshot(serverKey: false, assist: false))
        ..profile = homeServer
        ..join = joining;
      c.onServerApproved = () => c.snap = FakeProcessingController.snapshot(serverKey: true, assist: false);
      final AddServerFlow flow = AddServerFlow(c, waitStep: Duration.zero);
      final AddServerPlan plan = await flow.plan('c1');
      expect(plan.state, AddServerState.approveServer);
      expect(plan.words, 'ab12 cd34 ef56 7890');
      await flow.confirm('c1', plan);
      // Approve the server key, publish the policy (server is the default for new members), sign only my own lane.
      expect(c.calls.where((String x) => x != 'load'), <String>['approve-server-join', 'policy:true:server:allowed', 'lane:server:fp=$fakeFp:del=false']);
    });

    test('a member who cannot approve is told the server is waiting for an administrator', () async {
      final FakeProcessingController c = FakeProcessingController(FakeProcessingController.snapshot(me: pB, admin: false, serverKey: false, assist: false), me: pB)
        ..profile = homeServer
        ..join = const ServerJoinInfo(builtin: true, waiting: true, canApprove: false);
      final AddServerPlan plan = await AddServerFlow(c, waitStep: Duration.zero).plan('c1');
      expect(plan.state, AddServerState.serverWaiting);
    });

    test('nothing is approved when the server stays silent: a clear error, no policy and no lane', () async {
      final FakeProcessingController c = FakeProcessingController(FakeProcessingController.snapshot(serverKey: false, assist: false))
        ..profile = homeServer
        ..join = joining;
      c.onServerApproved = () {}; // the server never pins its key
      final AddServerFlow flow = AddServerFlow(c, waitStep: Duration.zero);
      final AddServerPlan plan = await flow.plan('c1');
      await expectLater(flow.confirm('c1', plan), throwsA(isA<StateError>()));
      expect(c.calls.any((String x) => x.startsWith('policy') || x.startsWith('lane')), isFalse);
    });
  });

  group('which card to show', () {
    test('a member of a circle with the server on is asked once; answering hides it', () {
      final List<Circle> cs = <Circle>[circle(admin: false, assist: true)];
      expect(pickServerPrompt(cs, answered: (_) => false, snoozed: (_) => false).kind, ServerPromptKind.memberChoice);
      expect(pickServerPrompt(cs, answered: (_) => true, snoozed: (_) => false).kind, ServerPromptKind.none);
    });

    test('already on the server: no question', () {
      expect(pickServerPrompt(<Circle>[circle(admin: false, assist: true, myServer: true)], answered: (_) => false, snoozed: (_) => false).kind, ServerPromptKind.none);
    });

    test('the admin of a private circle without the server gets the setup card; normal circles get nothing', () {
      expect(pickServerPrompt(<Circle>[circle()], answered: (_) => false, snoozed: (_) => false).kind, ServerPromptKind.adminSetup);
      expect(pickServerPrompt(<Circle>[circle(mode: 'off')], answered: (_) => false, snoozed: (_) => false).kind, ServerPromptKind.none);
      expect(pickServerPrompt(<Circle>[circle(admin: false)], answered: (_) => false, snoozed: (_) => false).kind, ServerPromptKind.none);
    });

    test('the member question comes before the admin card', () {
      final List<Circle> cs = <Circle>[circle(id: 'a'), circle(id: 'b', admin: false, assist: true)];
      expect(pickServerPrompt(cs, answered: (_) => false, snoozed: (_) => false).circle!.id, 'b');
    });
  });

  testWidgets('"Your server wants to join": shows the code and approves with one tap', (t) async {
    int approved = 0;
    await t.pumpWidget(MaterialApp(
        home: Scaffold(body: ServerJoinCard(loader: () async => joining, approver: () async => approved++))));
    await t.pumpAndSettle();
    expect(find.text('Your server wants to join'), findsOneWidget);
    expect(find.text('ab12 cd34 ef56 7890'), findsOneWidget);
    await t.tap(find.byKey(const Key('server-join-approve')));
    await t.pumpAndSettle();
    expect(approved, 1);
    expect(find.byKey(const Key('server-join-card')), findsNothing);
  });

  testWidgets('the join card stays hidden for people who cannot approve', (t) async {
    await t.pumpWidget(MaterialApp(
        home: Scaffold(body: ServerJoinCard(loader: () async => const ServerJoinInfo(builtin: true, waiting: true, canApprove: false), approver: () async {}))));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('server-join-card')), findsNothing);
  });

  test('the message for members on an old app names the server and the APK', () {
    final String m = updateMessageText('https://family.example.org');
    expect(m, contains('https://family.example.org/app.apk'));
    expect(m, contains('Play Store'));
  });

  test('wording: the phone-only choice promises privacy, not reports', () {
    expect(E2ee.linePhone, isNot(E2ee.lineServer));
  });
}
