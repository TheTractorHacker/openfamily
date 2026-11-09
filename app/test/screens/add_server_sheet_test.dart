import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/circle.dart';
import 'package:openfamily/services/e2ee/add_server_flow.dart';
import 'package:openfamily/services/e2ee/e2ee_crypto.dart';
import 'package:openfamily/services/e2ee/e2ee_models.dart';
import 'package:openfamily/widgets/add_server_sheet.dart';

import '../support/fake_processing_controller.dart';

const Circle adminCircle = Circle(id: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc', name: 'Family', role: 'admin', sharingEnabled: true, memberCount: 2, e2eeMode: 'private');

ServerProfile profile({String eff = 'home', String lane = 'server', bool device = true, String fp = fakeFp, bool known = true}) => ServerProfile(
      known: known,
      profile: eff,
      effective: eff,
      recommendedLane: lane,
      enabled: true,
      device: device
          ? ServerDeviceInfo(deviceId: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd', fingerprint: fp, short: 'ab12 cd34', digits: '11111 22222', label: 'Server', ownerUserId: pA)
          : null,
    );

Future<void> pump(WidgetTester t, FakeProcessingController c, {Circle circle = adminCircle}) async {
  t.view.physicalSize = const Size(420, 2200);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  await t.pumpWidget(MaterialApp(home: Scaffold(body: AddServerSheet(circle: circle, controller: c))));
  await t.pumpAndSettle();
}

Future<void> tap(WidgetTester t, String k) async {
  await t.ensureVisible(find.byKey(Key(k)));
  await t.tap(find.byKey(Key(k)));
  await t.pumpAndSettle();
}

FakeProcessingController ctl({bool admin = true, bool assist = false, Map<String, int>? lanes, ServerProfile? prof, bool serverKey = true, bool legacy = false, bool isPrivate = true, List<String> notReady = const <String>[]}) =>
    FakeProcessingController(
        FakeProcessingController.snapshot(me: pA, admin: admin, assist: assist, lanes: lanes ?? const <String, int>{pA: E2ee.linePhone, pB: E2ee.linePhone}, serverKey: serverKey, legacy: legacy, isPrivate: isPrivate, notReady: notReady))
      ..profile = prof ?? profile();

void main() {
  testWidgets('admin, home: three steps; OK publishes the policy (default server) and signs only their own lane', (t) async {
    final FakeProcessingController c = ctl();
    await pump(t, c);
    expect(find.textContaining('server in your home'), findsOneWidget);
    await tap(t, 'add-server-next');
    expect(find.byKey(const Key('add-server-code-words')), findsOneWidget);
    expect(find.text('ab12'), findsOneWidget);
    await tap(t, 'add-server-same');
    expect(find.byKey(const Key('add-server-confirm-text')), findsOneWidget);
    await tap(t, 'add-server-ok');
    expect(c.calls.where((String x) => x != 'load'), <String>['policy:true:server:allowed', 'lane:server:fp=$fakeFp:del=false']);
    expect(find.byKey(const Key('add-server-success')), findsOneWidget);
  });

  testWidgets('admin, cloud: the text warns about the host; members are still on the server by default (section 24)', (t) async {
    final FakeProcessingController c = ctl(prof: profile(eff: 'cloud', lane: 'phone'));
    await pump(t, c);
    expect(find.textContaining('rented from a company'), findsOneWidget);
    await tap(t, 'add-server-next');
    await tap(t, 'add-server-same');
    await tap(t, 'add-server-ok');
    expect(c.calls.where((String x) => x.startsWith('policy')), <String>['policy:true:server:allowed']);
  });

  testWidgets('unknown profile (older server) gets the careful wording', (t) async {
    final FakeProcessingController c = ctl(prof: ServerProfile.unknown);
    await pump(t, c);
    expect(find.textContaining('Nobody has said that this server runs in your own home'), findsOneWidget);
  });

  testWidgets('normal member with the policy on signs only their own lane, no policy call', (t) async {
    final FakeProcessingController c = FakeProcessingController(FakeProcessingController.snapshot(me: pB, admin: false, assist: true), me: pB)..profile = profile();
    await pump(t, c);
    await tap(t, 'add-server-next');
    await tap(t, 'add-server-same');
    await tap(t, 'add-server-ok');
    expect(c.calls.where((String x) => x != 'load'), <String>['lane:server:fp=$fakeFp:del=false']);
  });

  testWidgets('normal member while the policy is off must ask the admin; nothing is signed', (t) async {
    final FakeProcessingController c = FakeProcessingController(FakeProcessingController.snapshot(me: pB, admin: false, assist: false), me: pB)..profile = profile();
    await pump(t, c);
    expect(find.byKey(const Key('add-server-needs-admin')), findsOneWidget);
    expect(c.calls.where((String x) => x != 'load'), isEmpty);
  });

  testWidgets('different code: stops in red, nothing signed, can compare again', (t) async {
    final FakeProcessingController c = ctl();
    await pump(t, c);
    await tap(t, 'add-server-next');
    await tap(t, 'add-server-different');
    expect(find.byKey(const Key('add-server-mismatch')), findsOneWidget);
    expect(find.byKey(const Key('add-server-ok')), findsNothing);
    expect(c.calls.where((String x) => x != 'load'), isEmpty);
    await tap(t, 'add-server-compare-again');
    expect(find.byKey(const Key('add-server-code-words')), findsOneWidget);
  });

  testWidgets('two server answers that disagree about the key stop the flow', (t) async {
    final FakeProcessingController c = ctl(prof: profile(fp: 'ff' * 32));
    await pump(t, c);
    expect(find.byKey(const Key('add-server-conflict')), findsOneWidget);
    expect(find.byKey(const Key('add-server-next')), findsNothing);
  });

  testWidgets('server not enrolled: explains and points at the docs path', (t) async {
    final FakeProcessingController c = ctl(serverKey: false, prof: profile(device: false));
    await pump(t, c);
    expect(find.byKey(const Key('add-server-notenrolled')), findsOneWidget);
    expect(find.textContaining('/docs/server-setup'), findsOneWidget);
    expect(find.byKey(const Key('add-server-next')), findsNothing);
  });

  testWidgets('already added: remove asks, deletes own copies by default, member sees no remove-for-everyone', (t) async {
    final FakeProcessingController c = FakeProcessingController(
        FakeProcessingController.snapshot(me: pB, admin: false, assist: true, lanes: const <String, int>{pA: E2ee.linePhone, pB: E2ee.lineServer}), me: pB)
      ..profile = profile();
    await pump(t, c);
    expect(find.byKey(const Key('add-server-added')), findsOneWidget);
    expect(find.byKey(const Key('add-server-remove-all')), findsNothing);
    await tap(t, 'add-server-remove');
    await tap(t, 'add-server-remove-confirm');
    expect(c.calls.where((String x) => x != 'load'), <String>['lane:phone:fp=-:del=true']);
  });

  testWidgets('already added, admin: remove for everyone turns the policy off and deletes the circle copies', (t) async {
    final FakeProcessingController c = ctl(assist: true, lanes: const <String, int>{pA: E2ee.lineServer, pB: E2ee.linePhone});
    await pump(t, c);
    await tap(t, 'add-server-remove-all');
    await tap(t, 'add-server-remove-all-confirm');
    expect(c.calls.where((String x) => x != 'load'), <String>['policy:false:phone:allowed', 'delete:circle']);
  });

  testWidgets('old apps in the circle block the admin with their names', (t) async {
    final FakeProcessingController c = ctl(notReady: <String>['Bob']);
    await pump(t, c);
    expect(find.byKey(const Key('add-server-update')), findsOneWidget);
    expect(find.textContaining('Bob'), findsOneWidget);
  });

  testWidgets('an older server without lanes shows the unavailable text, not an error dump', (t) async {
    final FakeProcessingController c = ctl()..loadFails = Exception('404');
    await pump(t, c);
    expect(find.byKey(const Key('add-server-unavailable')), findsOneWidget);
  });

  testWidgets('a failure while signing keeps the sheet open with a plain message', (t) async {
    final FakeProcessingController c = ctl()..failWith = StateError('This phone does not hold the server key yet.');
    await pump(t, c);
    await tap(t, 'add-server-next');
    await tap(t, 'add-server-same');
    await tap(t, 'add-server-ok');
    expect(find.textContaining('does not hold the server key yet'), findsOneWidget);
    expect(find.byKey(const Key('add-server-success')), findsNothing);
  });

  test('explanation text is two sentences per profile', () {
    for (final ServerProfile p in <ServerProfile>[profile(), profile(eff: 'cloud', lane: 'phone'), ServerProfile.unknown]) {
      expect('.'.allMatches(addServerExplanation(p)).length, inInclusiveRange(2, 3));
    }
  });

  test('ServerProfile parses the server answer; missing fields read as unknown and careful', () {
    final ServerProfile p = ServerProfile.fromJson(<String, dynamic>{
      'enabled': true,
      'deployment_profile': 'home',
      'profile_effective': 'home',
      'recommended_lane': 'server',
      'data_at_rest_key': false,
    });
    expect((p.known, p.isHome, p.serverRecommended), (true, true, true));
    final ServerProfile old = ServerProfile.fromJson(<String, dynamic>{'enabled': true});
    expect((old.known, old.isHome, old.serverRecommended), (false, false, false));
    // A home profile without a recommended server never preselects it.
    expect(ServerProfile.fromJson(<String, dynamic>{'profile_effective': 'home', 'recommended_lane': 'phone'}).serverRecommended, isFalse);
  });
}
