import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/circle.dart';
import 'package:openfamily/screens/legacy_upgrade_screen.dart';
import 'package:openfamily/screens/my_processing_screen.dart';
import 'package:openfamily/screens/processing_policy_screen.dart';
import 'package:openfamily/screens/processing_screen.dart';
import 'package:openfamily/services/api_client.dart' show ApiException;
import 'package:openfamily/services/circle_service.dart';
import 'package:openfamily/services/e2ee/e2ee_service.dart' show LocalKeyException, LocalKeyProblem;
import 'package:openfamily/services/e2ee/e2ee_crypto.dart';
import 'package:openfamily/services/e2ee/lanes_store.dart';
import 'package:openfamily/services/e2ee/processing_controller.dart' show ProcessingViewer;
import 'package:openfamily/widgets/ds/ds.dart';
import 'package:openfamily/widgets/processing_widgets.dart';

import '../support/fake_processing_controller.dart';

const Circle adminCircle = Circle(id: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc', name: 'Family', role: 'admin', sharingEnabled: true, memberCount: 2, e2eeMode: 'private');
const Circle memberCircle = Circle(id: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc', name: 'Family', role: 'member', sharingEnabled: true, memberCount: 2, e2eeMode: 'private');

Future<void> pumpScreen(WidgetTester t, Widget w, {Size size = const Size(390, 2400), Brightness b = Brightness.light}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  await t.pumpWidget(MaterialApp(theme: ThemeData(brightness: b), home: w));
  await t.pumpAndSettle();
}

Finder txt(String s) => find.textContaining(s);

Future<void> tapKey(WidgetTester t, String k) async {
  await t.ensureVisible(find.byKey(Key(k)));
  await t.tap(find.byKey(Key(k)));
  await t.pumpAndSettle();
}

void main() {
  group('ProcessingScreen: members not yet on the server', () {
    testWidgets('a circle admin sees who is missing and the message to send; nobody is switched', (t) async {
      final FakeProcessingController c = FakeProcessingController(FakeProcessingController.snapshot(
          lanes: const <String, int>{pA: E2ee.lineServer, pB: E2ee.linePhone}, unverified: const <String>{pB}));
      await pumpScreen(t, ProcessingScreen(circle: adminCircle, controller: c), size: const Size(390, 6000));
      expect(txt('MEMBERS NOT YET ON THE SERVER'), findsOneWidget);
      expect(find.byKey(Key('not-on-server-$pB')), findsOneWidget);
      expect(find.byKey(Key('not-on-server-$pA')), findsNothing);
      expect(txt('Uses the phone (has not chosen)'), findsWidgets);
      expect(txt('not choosing yet'), findsNothing);
      expect(txt('Not chosen yet'), findsNothing);
      expect(txt('Please open the Orbitly app once'), findsOneWidget);
      expect(c.calls.where((String x) => x.startsWith('lane') || x.startsWith('policy')), isEmpty);
    });

    testWidgets('ordinary members do not get the list', (t) async {
      final FakeProcessingController c = FakeProcessingController(FakeProcessingController.snapshot(me: pB, admin: false), me: pB);
      await pumpScreen(t, ProcessingScreen(circle: memberCircle, controller: c));
      expect(txt('MEMBERS NOT YET ON THE SERVER'), findsNothing);
    });
  });

  group('ProcessingScreen: load errors name the cause', () {
    final Map<Object, (String, String)> cases = <Object, (String, String)>{
      const ApiException(503, 'Request failed (503).'): ('Server busy', 'restarting'),
      const ApiException(401, 'unauthorized'): ('Sign in again', 'Sign in again'),
      const LocalKeyException(LocalKeyProblem.missing): ('Encryption key problem', 'Encryption keys'),
    };
    for (final MapEntry<Object, (String, String)> e in cases.entries) {
      testWidgets('${e.value.$1}: not "Something went wrong", not "offline"', (t) async {
        final FakeProcessingController c = FakeProcessingController(FakeProcessingController.snapshot())..loadFails = e.key;
        await pumpScreen(t, ProcessingScreen(circle: adminCircle, controller: c));
        expect(find.text(e.value.$1), findsWidgets);
        expect(find.textContaining(e.value.$2), findsWidgets);
        expect(find.text('Something went wrong'), findsNothing);
        expect(find.textContaining('offline'), findsNothing);
        expect(find.text('Try again'), findsOneWidget);
      });
    }
  });

  group('ProcessingScreen: a member', () {
    testWidgets('sees the setting read-only with the reason, and decides for their own data', (t) async {
      final FakeProcessingController c = FakeProcessingController(FakeProcessingController.snapshot(me: pB, admin: false), me: pB);
      await pumpScreen(t, ProcessingScreen(circle: memberCircle, controller: c));
      expect(find.byKey(const Key('proc-admin-only')), findsOneWidget);
      expect(txt('Only a circle admin can change these settings'), findsOneWidget);
      expect(find.byKey(const Key('delete-all')), findsNothing, reason: 'whole-circle deletion is for admins');
      expect(find.byKey(const Key('delete-mine')), findsOneWidget);
      expect(find.byKey(const Key('proc-phone-note')), findsOneWidget);
      final Switch sw = t.widget<Switch>(find.descendant(of: find.byKey(const Key('my-lane-switch')), matching: find.byType(Switch)));
      expect(sw.onChanged, isNotNull);
      expect(sw.value, isFalse);
    });

    testWidgets('opt-out of the server: honest warning, no battery numbers, delete-copies preselected, then phone lane', (t) async {
      final FakeProcessingController c = FakeProcessingController(
          FakeProcessingController.snapshot(me: pB, admin: false, lanes: const <String, int>{pA: E2ee.linePhone, pB: E2ee.lineServer}), me: pB);
      await pumpScreen(t, ProcessingScreen(circle: memberCircle, controller: c));
      expect(find.byKey(const Key('delete-all')), findsNothing);
      await t.ensureVisible(find.byKey(const Key('my-lane-switch')));
      await t.tap(find.descendant(of: find.byKey(const Key('my-lane-switch')), matching: find.byType(Switch)));
      await t.pumpAndSettle();
      expect(find.text('Keep your data on your phone only?'), findsOneWidget);
      expect(txt('may use more battery'), findsOneWidget);
      expect(txt('only as good as your phone can compute'), findsOneWidget);
      expect(txt('calculated on your phone and shared with the circle'), findsOneWidget);
      expect(txt('does not hide that you are a member'), findsWidgets);
      expect(txt('also in a normal circle'), findsWidgets);
      expect(find.textContaining(RegExp(r'\d+\s?%|\d+\s?(mAh|hours?|h of battery)')), findsNothing, reason: 'no unmeasured numbers');
      final CheckboxListTile del = t.widget<CheckboxListTile>(find.byKey(const Key('optout-delete-copies')));
      expect(del.value, isTrue);
      // Cancel does nothing.
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(c.calls.where((String x) => x.startsWith('lane')), isEmpty);
      await t.tap(find.descendant(of: find.byKey(const Key('my-lane-switch')), matching: find.byType(Switch)));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('optout-delete-copies')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('optout-confirm')));
      await t.pumpAndSettle();
      expect(c.calls.where((String x) => x.startsWith('lane')), <String>['lane:phone:fp=-:del=false']);
    });

    testWidgets('opt-in shows the server key and needs an explicit confirmation; the fingerprint is passed along', (t) async {
      final FakeProcessingController c = FakeProcessingController(FakeProcessingController.snapshot(me: pB, admin: false), me: pB);
      await pumpScreen(t, ProcessingScreen(circle: memberCircle, controller: c));
      await t.ensureVisible(find.byKey(const Key('my-lane-switch')));
      await t.tap(find.descendant(of: find.byKey(const Key('my-lane-switch')), matching: find.byType(Switch)));
      await t.pumpAndSettle();
      expect(find.text('Let the server process your data?'), findsOneWidget);
      expect(txt('Anyone who runs or backs up this server can read'), findsWidgets);
      expect(txt('ab12 cd34'), findsOneWidget);
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(c.calls.where((String x) => x.startsWith('lane')), isEmpty);
      await t.tap(find.descendant(of: find.byKey(const Key('my-lane-switch')), matching: find.byType(Switch)));
      await t.pumpAndSettle();
      await t.tap(find.text('Allow'));
      await t.pumpAndSettle();
      expect(c.calls.where((String x) => x.startsWith('lane')), <String>['lane:server:fp=$fakeFp:del=false']);
    });

    testWidgets('admin default "server" preselects the server button but signs nothing without the confirmation', (t) async {
      final FakeProcessingController c = FakeProcessingController(
          FakeProcessingController.snapshot(me: pB, admin: false, defaultForNew: E2ee.lineServer, unverified: <String>{pB}), me: pB);
      await pumpScreen(t, ProcessingScreen(circle: memberCircle, controller: c));
      expect(find.byKey(const Key('proc-choose')), findsOneWidget);
      expect(txt('only a suggestion'), findsOneWidget);
      expect(t.widget<DsPillButton>(find.byKey(const Key('choose-server'))).style, DsPillStyle.outlined);
      expect(t.widget<DsPillButton>(find.byKey(const Key('choose-phone'))).style, DsPillStyle.outlined);
      await tapKey(t, 'choose-server');
      expect(find.text('Let the server process your data?'), findsOneWidget);
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(c.calls.where((String x) => x.startsWith('lane')), isEmpty, reason: 'never signs without an explicit confirmation');
    });

    testWidgets('required by the admin, not switched over yet: a calm notice, no opt-in or opt-out control, no dead end', (t) async {
      final FakeProcessingController c = FakeProcessingController(
          FakeProcessingController.snapshot(me: pB, admin: false, optOut: E2ee.optOutRequiredServer, unverified: <String>{pB}), me: pB);
      await pumpScreen(t, ProcessingScreen(circle: memberCircle, controller: c));
      expect(find.byKey(const Key('proc-required-notice')), findsOneWidget);
      expect(find.text('Your family admin requires server processing.'), findsOneWidget);
      expect(find.byKey(const Key('proc-required-catching-up')), findsOneWidget);
      expect(txt('not delivered (check-ins and emergency alerts still are)'), findsOneWidget);
      expect(find.byKey(const Key('my-lane-switch')), findsNothing);
      expect(find.byKey(const Key('proc-choose')), findsNothing);
      expect(find.byKey(const Key('proc-consent-required')), findsNothing);
      expect(find.byKey(const Key('proc-consent')), findsNothing);
      expect(txt('leave the circle'), findsNothing);
      expect(txt('sends nothing'), findsNothing);
      expect(c.calls.where((String x) => x.startsWith('lane')), isEmpty);
    });

    testWidgets('required by the admin and on the server: the notice, no switch', (t) async {
      final FakeProcessingController c = FakeProcessingController(
          FakeProcessingController.snapshot(me: pB, admin: false, optOut: E2ee.optOutRequiredServer, lanes: const <String, int>{pA: E2ee.lineServer, pB: E2ee.lineServer}),
          me: pB);
      await pumpScreen(t, ProcessingScreen(circle: memberCircle, controller: c));
      expect(find.text('Your family admin requires server processing.'), findsOneWidget);
      expect(find.byKey(const Key('proc-required-catching-up')), findsNothing);
      expect(find.byKey(const Key('my-lane-switch')), findsNothing);
    });

    testWidgets('server assistance off: the switch is disabled and the phone does the work', (t) async {
      final FakeProcessingController c = FakeProcessingController(FakeProcessingController.snapshot(me: pB, admin: false, assist: false), me: pB);
      await pumpScreen(t, ProcessingScreen(circle: memberCircle, controller: c));
      expect(txt('Server processing is off for this circle'), findsWidgets);
      final Switch sw = t.widget<Switch>(find.descendant(of: find.byKey(const Key('my-lane-switch')), matching: find.byType(Switch)));
      expect(sw.onChanged, isNull);
      expect(find.text('Phones only'), findsOneWidget);
    });

    testWidgets('members get Processed by server / Phone only badges', (t) async {
      final FakeProcessingController c = FakeProcessingController(
          FakeProcessingController.snapshot(me: pB, admin: false, lanes: const <String, int>{pA: E2ee.lineServer, pB: E2ee.linePhone}), me: pB);
      await pumpScreen(t, ProcessingScreen(circle: memberCircle, controller: c));
      expect(find.text('Processed by server'), findsOneWidget);
      expect(find.text('Phone only'), findsOneWidget);
      expect(find.text('Server-assisted (1 of 2 members)'), findsOneWidget);
    });

    testWidgets('a normal (not Private) circle explains that the server reads it', (t) async {
      final FakeProcessingController c = FakeProcessingController(FakeProcessingController.snapshot(isPrivate: false, lanes: const <String, int>{}));
      await pumpScreen(t, ProcessingScreen(circle: adminCircle, controller: c));
      expect(find.byKey(const Key('proc-not-private')), findsOneWidget);
      expect(find.byKey(const Key('my-lane-switch')), findsNothing);
    });

    testWidgets('legacy circle: a member is told an admin must upgrade and can open the old settings; no upgrade button', (t) async {
      final FakeProcessingController c = FakeProcessingController(FakeProcessingController.snapshot(me: pB, admin: false, legacy: true, assist: false), me: pB);
      await pumpScreen(t, ProcessingScreen(circle: memberCircle, controller: c));
      expect(find.byKey(const Key('proc-legacy-card')), findsOneWidget);
      expect(find.byKey(const Key('legacy-member-note')), findsOneWidget);
      expect(find.byKey(const Key('legacy-open-upgrade')), findsNothing);
      expect(find.byKey(const Key('legacy-open-old')), findsOneWidget);
    });

    testWidgets('verification failure is shown and the phone lane is explained', (t) async {
      final FakeProcessingController c = FakeProcessingController(
          FakeProcessingController.snapshot(me: pB, admin: false, assist: false, status: LaneStatus.verificationFailed), me: pB);
      await pumpScreen(t, ProcessingScreen(circle: memberCircle, controller: c));
      expect(find.byKey(const Key('proc-verification-failed')), findsOneWidget);
    });

    testWidgets('delete my copies asks first and reports', (t) async {
      final FakeProcessingController c = FakeProcessingController(FakeProcessingController.snapshot(me: pB, admin: false), me: pB);
      await pumpScreen(t, ProcessingScreen(circle: memberCircle, controller: c));
      await tapKey(t, 'delete-mine');
      expect(c.calls.where((String x) => x.startsWith('delete')), isEmpty);
      await t.tap(find.text('Delete copies'));
      await t.pumpAndSettle();
      expect(c.calls.where((String x) => x.startsWith('delete')), <String>['delete:mine']);
    });

    testWidgets('footnote states operator access, metadata and the multi-circle rule', (t) async {
      final FakeProcessingController c = FakeProcessingController(FakeProcessingController.snapshot(me: pB, admin: false), me: pB);
      await pumpScreen(t, ProcessingScreen(circle: memberCircle, controller: c));
      await t.ensureVisible(find.byKey(const Key('proc-footnote')));
      await t.tap(find.descendant(of: find.byKey(const Key('proc-footnote')), matching: find.byKey(const Key('info-hint'))));
      await t.pumpAndSettle();
      expect(txt('Anyone who runs or backs up this server can read the data of members who allow'), findsWidgets);
      expect(txt('when your phone connects'), findsOneWidget);
      expect(txt('also in a normal circle'), findsOneWidget);
    });

    testWidgets('dark theme at 390px does not overflow', (t) async {
      final FakeProcessingController c = FakeProcessingController(FakeProcessingController.snapshot(me: pB, admin: false), me: pB);
      await pumpScreen(t, ProcessingScreen(circle: memberCircle, controller: c), b: Brightness.dark, size: const Size(390, 844));
      expect(t.takeException(), isNull);
    });
  });

  group('ProcessingScreen: an admin', () {
    testWidgets('sees delete-all and the legacy upgrade button on a legacy circle', (t) async {
      final FakeProcessingController c = FakeProcessingController(FakeProcessingController.snapshot(legacy: true, assist: false));
      await pumpScreen(t, ProcessingScreen(circle: adminCircle, controller: c));
      expect(find.byKey(const Key('legacy-open-upgrade')), findsOneWidget);
      expect(find.byKey(const Key('proc-admin-only')), findsNothing);
      final Switch sw = t.widget<Switch>(find.descendant(of: find.byKey(const Key('my-lane-switch')), matching: find.byType(Switch)));
      expect(sw.onChanged, isNull, reason: 'a legacy circle uses the old settings until upgraded');
    });

    testWidgets('delete-all asks first', (t) async {
      final FakeProcessingController c = FakeProcessingController(FakeProcessingController.snapshot());
      await pumpScreen(t, ProcessingScreen(circle: adminCircle, controller: c));
      await tapKey(t, 'delete-all');
      await t.tap(find.text('Delete copies'));
      await t.pumpAndSettle();
      expect(c.calls.where((String x) => x.startsWith('delete')), <String>['delete:circle']);
    });
  });

  group('ProcessingPolicyScreen', () {
    testWidgets('member: read-only with the reason; nothing can be changed', (t) async {
      final FakeProcessingController c = FakeProcessingController(FakeProcessingController.snapshot(me: pB, admin: false), me: pB);
      await pumpScreen(t, ProcessingPolicyScreen(circle: memberCircle, controller: c));
      expect(find.byKey(const Key('policy-readonly')), findsOneWidget);
      final Switch sw = t.widget<Switch>(find.descendant(of: find.byKey(const Key('policy-assist-switch')), matching: find.byType(Switch)));
      expect(sw.onChanged, isNull);
      expect(sw.value, isTrue);
      await t.tap(find.byKey(const Key('opt-required')));
      await t.tap(find.byKey(const Key('default-server')));
      await t.pumpAndSettle();
      expect(c.calls.where((String x) => x.startsWith('policy')), isEmpty);
      expect(find.text('Require server processing?'), findsNothing);
    });

    testWidgets('admin turns it on after the full disclosure; server is the default for members (section 24)', (t) async {
      final FakeProcessingController c = FakeProcessingController(FakeProcessingController.snapshot(assist: false));
      await pumpScreen(t, ProcessingPolicyScreen(circle: adminCircle, controller: c));
      await t.tap(find.descendant(of: find.byKey(const Key('policy-assist-switch')), matching: find.byType(Switch)));
      await t.pumpAndSettle();
      expect(find.text('Turn on server processing for this circle?'), findsOneWidget);
      expect(txt('Each member decides for themselves'), findsOneWidget);
      expect(txt('You cannot change another member'), findsOneWidget);
      expect(txt('Anyone who runs or backs up this server can read'), findsWidgets);
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(c.calls.where((String x) => x.startsWith('policy')), isEmpty);
      await t.tap(find.descendant(of: find.byKey(const Key('policy-assist-switch')), matching: find.byType(Switch)));
      await t.pumpAndSettle();
      await t.tap(find.text('Turn on'));
      await t.pumpAndSettle();
      expect(c.calls.where((String x) => x.startsWith('policy')), <String>['policy:true:server:allowed']);
    });

    testWidgets('a member with an old app blocks turning on and is named', (t) async {
      final FakeProcessingController c = FakeProcessingController(FakeProcessingController.snapshot(assist: false, notReady: <String>['Sam']));
      await pumpScreen(t, ProcessingPolicyScreen(circle: adminCircle, controller: c));
      expect(find.byKey(const Key('policy-blocked')), findsOneWidget);
      expect(txt('Sam\'s app is out of date and cannot use this yet.'), findsOneWidget);
      final Switch sw = t.widget<Switch>(find.descendant(of: find.byKey(const Key('policy-assist-switch')), matching: find.byType(Switch)));
      expect(sw.onChanged, isNull);
    });

    testWidgets('no pinned server key: explains the operator has to set it up', (t) async {
      final FakeProcessingController c = FakeProcessingController(FakeProcessingController.snapshot(assist: false, serverKey: false));
      await pumpScreen(t, ProcessingPolicyScreen(circle: adminCircle, controller: c));
      expect(txt('no approved server key'), findsOneWidget);
      expect(find.byKey(const Key('policy-setup-server')), findsOneWidget);
    });

    testWidgets('admin chooses required_server with the warning and sets the default for new members', (t) async {
      final FakeProcessingController c = FakeProcessingController(FakeProcessingController.snapshot());
      await pumpScreen(t, ProcessingPolicyScreen(circle: adminCircle, controller: c));
      expect(find.byKey(const Key('opt-allowed')), findsOneWidget);
      await t.tap(find.byKey(const Key('opt-required')));
      await t.pumpAndSettle();
      expect(find.text('Require server processing?'), findsOneWidget);
      expect(txt('Members cannot turn it off'), findsWidgets);
      expect(txt('nobody is asked'), findsOneWidget);
      await t.tap(find.text('Require it'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('default-server')));
      await t.pumpAndSettle();
      expect(c.calls.where((String x) => x.startsWith('policy')), <String>['policy:true:phone:required_server', 'policy:true:server:allowed']);
      expect(txt('every member\'s phone signs it by itself'), findsOneWidget);
      expect(txt('Applies to child accounts too'), findsOneWidget);
    });

    testWidgets('turning it off warns that copies stay and is not destructive-styled as consent', (t) async {
      final FakeProcessingController c = FakeProcessingController(FakeProcessingController.snapshot());
      await pumpScreen(t, ProcessingPolicyScreen(circle: adminCircle, controller: c));
      await t.tap(find.descendant(of: find.byKey(const Key('policy-assist-switch')), matching: find.byType(Switch)));
      await t.pumpAndSettle();
      expect(find.text('Turn off server processing?'), findsOneWidget);
      expect(txt('not deleted automatically'), findsOneWidget);
      await t.tap(find.text('Turn off'));
      await t.pumpAndSettle();
      expect(c.calls.where((String x) => x.startsWith('policy')), <String>['policy:false:phone:allowed']);
    });

    testWidgets('legacy circle: editing is blocked until upgraded', (t) async {
      final FakeProcessingController c = FakeProcessingController(FakeProcessingController.snapshot(legacy: true, assist: false));
      await pumpScreen(t, ProcessingPolicyScreen(circle: adminCircle, controller: c));
      final Switch sw = t.widget<Switch>(find.descendant(of: find.byKey(const Key('policy-assist-switch')), matching: find.byType(Switch)));
      expect(sw.onChanged, isNull);
      expect(txt('Upgrade it first'), findsOneWidget);
    });
  });

  group('LegacyUpgradeScreen', () {
    testWidgets('admin: plain warnings, the button stays off until understood, then upgrades', (t) async {
      final FakeProcessingController c = FakeProcessingController(FakeProcessingController.snapshot(legacy: true, assist: false));
      await pumpScreen(t, LegacyUpgradeScreen(circle: adminCircle, controller: c));
      expect(txt('Everything up to now stays readable by the server'), findsOneWidget);
      expect(txt('cannot be undone'), findsWidgets);
      expect(txt('Anyone who runs or backs up this server can read'), findsOneWidget);
      expect(find.byKey(const Key('upgrade-run')), findsOneWidget);
      await t.tap(find.byKey(const Key('upgrade-run')), warnIfMissed: false);
      await t.pumpAndSettle();
      expect(c.calls, isNot(contains('upgrade')));
      await tapKey(t, 'upgrade-understood');
      await tapKey(t, 'upgrade-run');
      expect(c.calls, contains('upgrade'));
      expect(find.byKey(const Key('upgrade-not-legacy')), findsOneWidget);
      expect(txt('Nobody is opted in until they confirm'), findsOneWidget);
    });

    testWidgets('a member cannot upgrade', (t) async {
      final FakeProcessingController c = FakeProcessingController(FakeProcessingController.snapshot(me: pB, admin: false, legacy: true, assist: false), me: pB);
      await pumpScreen(t, LegacyUpgradeScreen(circle: memberCircle, controller: c));
      expect(find.byKey(const Key('upgrade-admin-only')), findsOneWidget);
      expect(find.byKey(const Key('upgrade-run')), findsNothing);
    });

    testWidgets('an out-of-date member app blocks the upgrade and is named', (t) async {
      final FakeProcessingController c = FakeProcessingController(FakeProcessingController.snapshot(legacy: true, assist: false, notReady: <String>['Sam']));
      await pumpScreen(t, LegacyUpgradeScreen(circle: adminCircle, controller: c));
      expect(find.byKey(const Key('upgrade-not-ready')), findsOneWidget);
      await tapKey(t, 'upgrade-understood');
      await t.tap(find.byKey(const Key('upgrade-run')), warnIfMissed: false);
      await t.pumpAndSettle();
      expect(c.calls, isNot(contains('upgrade')));
    });

    testWidgets('after the upgrade the admin can end the server\'s access to old data, with confirmation', (t) async {
      final FakeProcessingController c = FakeProcessingController(FakeProcessingController.snapshot(legacyAccessOpen: true));
      await pumpScreen(t, LegacyUpgradeScreen(circle: adminCircle, controller: c));
      await tapKey(t, 'upgrade-end-legacy');
      expect(c.calls, isNot(contains('end-legacy')));
      await t.tap(find.text('End access'));
      await t.pumpAndSettle();
      expect(c.calls, contains('end-legacy'));
    });
  });

  group('LegacyUpgradeScreen old-data button', () {
    testWidgets('not shown when the server does not report open legacy access', (t) async {
      final FakeProcessingController c = FakeProcessingController(FakeProcessingController.snapshot());
      await pumpScreen(t, LegacyUpgradeScreen(circle: adminCircle, controller: c));
      expect(find.byKey(const Key('upgrade-end-legacy')), findsNothing);
    });

    testWidgets('not shown to a member even when access is open', (t) async {
      final FakeProcessingController c = FakeProcessingController(FakeProcessingController.snapshot(me: pB, admin: false, legacyAccessOpen: true), me: pB);
      await pumpScreen(t, LegacyUpgradeScreen(circle: memberCircle, controller: c));
      expect(find.byKey(const Key('upgrade-end-legacy')), findsNothing);
    });
  });

  group('review findings', () {
    testWidgets('a legacy circle is never shown as "the server cannot read"', (t) async {
      final FakeProcessingController c = FakeProcessingController(FakeProcessingController.snapshot(me: pB, admin: false, legacy: true, assist: false), me: pB);
      await pumpScreen(t, ProcessingScreen(circle: memberCircle, controller: c));
      expect(find.text('Old trusted-server mode'), findsWidgets);
      expect(find.textContaining('holds the circle key'), findsWidgets);
      expect(find.text('Phones only'), findsNothing);
      expect(find.textContaining('cannot read this circle'), findsNothing);
      expect(find.textContaining('Phones do the processing'), findsNothing);
      expect(find.text('Phone only'), findsNothing, reason: 'no lane chips in a legacy circle');
    });

    testWidgets('the settings list says the same for a legacy circle', (t) async {
      final FakeProcessingController c = FakeProcessingController(FakeProcessingController.snapshot(me: pB, admin: false, legacy: true, assist: false), me: pB);
      await pumpScreen(t, MyProcessingScreen(controller: c, circles: _Circles()));
      expect(find.textContaining('Old mode'), findsOneWidget);
      expect(find.text('Server processing is off. Your phone does the work.'), findsNothing);
    });

    testWidgets('the upgrade copy tells the truth: nobody is carried over, everyone signs again, features pause', (t) async {
      final FakeProcessingController c = FakeProcessingController(FakeProcessingController.snapshot(legacy: true, assist: false));
      await pumpScreen(t, LegacyUpgradeScreen(circle: adminCircle, controller: c));
      expect(txt('Nobody is carried over'), findsOneWidget);
      expect(txt('sign their own choice again'), findsOneWidget);
      expect(txt('pause'), findsOneWidget);
      expect(txt('30 days'), findsNothing);
      expect(txt('carried over for'), findsNothing);
    });

    testWidgets('an unconfirmed opt-out is shown as such', (t) async {
      final FakeProcessingController c = FakeProcessingController(
          FakeProcessingController.snapshot(me: pB, admin: false, optOutPendingSince: DateTime(2026, 11, 7)), me: pB);
      await pumpScreen(t, ProcessingScreen(circle: memberCircle, controller: c));
      expect(find.byKey(const Key('proc-optout-pending')), findsOneWidget);
      expect(txt('the server still has your previous choice'), findsOneWidget);
    });

    testWidgets('items refused for good are reported, not dropped silently', (t) async {
      final FakeProcessingController c = FakeProcessingController(
          FakeProcessingController.snapshot(me: pB, admin: false, optOut: E2ee.optOutRequiredServer, unverified: <String>{pB}, undeliveredCount: 3), me: pB);
      await pumpScreen(t, ProcessingScreen(circle: memberCircle, controller: c));
      expect(find.byKey(const Key('proc-undelivered')), findsOneWidget);
      expect(txt('3 items were not delivered'), findsOneWidget);
      expect(txt('requires server processing and the server did not accept this phone\'s choice'), findsOneWidget);
    });

    testWidgets('required_server with a child account says the rule applies to the child', (t) async {
      final FakeProcessingController c = FakeProcessingController(
          FakeProcessingController.snapshot(me: pB, admin: false, optOut: E2ee.optOutRequiredServer, children: <String>{pB}), me: pB);
      await pumpScreen(t, ProcessingScreen(circle: memberCircle, controller: c));
      expect(find.byKey(const Key('proc-child-note')), findsOneWidget);
      expect(txt('applies to child accounts too'), findsWidgets);
    });

    testWidgets('the two default-for-new buttons look exactly alike', (t) async {
      for (final int def in <int>[E2ee.linePhone, E2ee.lineServer]) {
        final FakeProcessingController c = FakeProcessingController(
            FakeProcessingController.snapshot(me: pB, admin: false, defaultForNew: def, unverified: <String>{pB}), me: pB);
        await pumpScreen(t, ProcessingScreen(circle: memberCircle, controller: c));
        expect(t.widget<DsPillButton>(find.byKey(const Key('choose-server'))).style, t.widget<DsPillButton>(find.byKey(const Key('choose-phone'))).style);
        expect(txt('suggests'), findsOneWidget);
        await t.pumpWidget(const SizedBox());
      }
    });

    testWidgets('members see which viewers and bridges exist in the circle', (t) async {
      final FakeProcessingController c = FakeProcessingController(
          FakeProcessingController.snapshot(
              me: pB, admin: false, viewers: const <ProcessingViewer>[ProcessingViewer('Alice', 'web'), ProcessingViewer('Alice', 'service')]),
          me: pB);
      await pumpScreen(t, ProcessingScreen(circle: memberCircle, controller: c));
      await t.ensureVisible(find.byKey(const Key('viewer-Alice-web')));
      expect(txt('Alice has a web viewer'), findsOneWidget);
      expect(txt('including members who keep data on their phone'), findsOneWidget);
      expect(txt('reads members who allowed server processing, not phone-only members'), findsOneWidget);
    });
  });

  group('ProcessingScreen: required by the admin, admin view', () {
    testWidgets('the admin sees who is on the server and who is catching up, in plain words; no reminder needed', (t) async {
      final FakeProcessingController c = FakeProcessingController(FakeProcessingController.snapshot(
          optOut: E2ee.optOutRequiredServer, lanes: const <String, int>{pA: E2ee.lineServer, pB: E2ee.linePhone, pC: E2ee.linePhone}, unverified: const <String>{pC}));
      await pumpScreen(t, ProcessingScreen(circle: adminCircle, controller: c), size: const Size(390, 6000));
      expect(find.text('Required by the admin (1 of 3 on the server)'), findsOneWidget);
      expect(find.descendant(of: find.byKey(Key('member-$pA')), matching: find.text('On the server')), findsOneWidget);
      expect(find.descendant(of: find.byKey(Key('member-$pB')), matching: find.text('Catching up')), findsWidgets);
      expect(find.descendant(of: find.byKey(Key('member-$pC')), matching: find.text('Catching up')), findsWidgets);
      expect(find.byKey(Key('catching-up-$pB')), findsOneWidget);
      expect(find.byKey(Key('catching-up-$pC')), findsOneWidget);
      expect(find.byKey(const Key('remind-copy')), findsNothing);
      expect(find.byKey(Key('remind-$pC')), findsNothing);
      expect(txt('positions may not arrive'), findsWidgets);
      expect(txt('not choosing yet'), findsNothing);
      expect(txt('Not chosen yet'), findsNothing);
    });
  });

  group('ProcessingScreen: errors are specific, never "Something went wrong"', () {
    Future<void> pumpFailing(WidgetTester t, Object error) async {
      final FakeProcessingController c = FakeProcessingController(FakeProcessingController.snapshot())..loadFails = error;
      await pumpScreen(t, ProcessingScreen(circle: adminCircle, controller: c));
    }

    testWidgets('offline', (t) async {
      await pumpFailing(t, const ApiException(0, 'Could not reach the server. Check your connection.'));
      expect(find.text('No connection'), findsOneWidget);
      expect(txt('You appear to be offline'), findsOneWidget);
      expect(txt('Something went wrong'), findsNothing);
    });

    testWidgets('an unreadable answer is not called offline', (t) async {
      await pumpFailing(t, const ApiException(0, 'The server sent an unreadable answer. Please try again.'));
      expect(txt('offline'), findsNothing);
      expect(txt('unreadable answer'), findsOneWidget);
      expect(txt('Something went wrong'), findsNothing);
    });

    testWidgets('server trouble', (t) async {
      await pumpFailing(t, const ApiException(503, 'unavailable'));
      expect(txt('The server had a problem. Try again shortly.'), findsOneWidget);
      expect(txt('offline'), findsNothing);
    });

    testWidgets("this phone's key cannot be opened", (t) async {
      await pumpFailing(t, const LocalKeyException(LocalKeyProblem.locked));
      expect(txt("This phone's encryption key cannot be opened right now"), findsOneWidget);
      expect(txt('Unlock the phone'), findsOneWidget);
      expect(txt('Something went wrong'), findsNothing);
    });

    testWidgets('waiting for approval', (t) async {
      await pumpFailing(t, const ApiException(403, 'this device is not approved in this circle'));
      expect(find.text('Waiting for approval'), findsOneWidget);
      expect(txt('pull down to check again'), findsOneWidget);
    });

    testWidgets('anything else names the step and keeps Try again', (t) async {
      await pumpFailing(t, const FormatException('boom'));
      expect(txt("Could not check this circle's server processing settings."), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      expect(txt('Something went wrong'), findsNothing);
      expect(txt('boom'), findsNothing);
    });

    testWidgets('a snapshot with a problem shows it and the rest of the screen', (t) async {
      final FakeProcessingController c = FakeProcessingController(FakeProcessingController.snapshot(problem: 'Could not confirm X.'));
      await pumpScreen(t, ProcessingScreen(circle: adminCircle, controller: c));
      expect(find.byKey(const Key('proc-problem')), findsOneWidget);
      expect(find.byKey(const Key('proc-status-card')), findsOneWidget);
      // Honest about what it does not know: no lane claim in the status card or the member rows, no promise of a retry.
      expect(txt('Not confirmed right now'), findsWidgets);
      expect(txt('The server cannot read this circle'), findsNothing);
      expect(txt('Keeps data on their phone'), findsNothing);
      expect(txt('tries again by itself'), findsNothing);
      expect(find.byKey(const Key('proc-required-notice')), findsNothing);
    });
  });

  group('MyProcessingScreen (Settings shortcut)', () {
    testWidgets('lists only my Private circles with my lane and explains "Don\'t send my data to the server"', (t) async {
      final FakeProcessingController c = FakeProcessingController(
          FakeProcessingController.snapshot(me: pB, admin: false, lanes: const <String, int>{pA: E2ee.linePhone, pB: E2ee.lineServer}), me: pB);
      await pumpScreen(t, MyProcessingScreen(controller: c, circles: _Circles()));
      expect(find.byKey(const Key('my-proc-dddddddd-dddd-4ddd-8ddd-dddddddddddd')), findsOneWidget);
      expect(find.text('Family'), findsNothing, reason: 'the normal circle is not listed');
      await t.tap(find.byKey(const Key('info-hint')).first);
      await t.pumpAndSettle();
      expect(txt('Don\'t send my data to the server'), findsOneWidget);
      Navigator.of(t.element(find.byType(Scaffold).first)).pop();
      await t.pumpAndSettle();
      expect(find.text('Processed by server'), findsOneWidget);
    });

    testWidgets('no Private circle: says the position goes to the server in a normal circle', (t) async {
      final FakeProcessingController c = FakeProcessingController(FakeProcessingController.snapshot());
      await pumpScreen(t, MyProcessingScreen(controller: c, circles: _Circles(onlyNormal: true)));
      expect(find.byKey(const Key('my-proc-empty')), findsOneWidget);
    });
  });

  group('widgets', () {
    testWidgets('placeholder and computed-on-phone note use the owner wording', (t) async {
      await t.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Column(children: <Widget>[
        const WaitingForPhoneCard(name: 'Alex'),
        ComputedOnPhoneNote(name: 'Alex', updatedAt: DateTime.utc(2026, 11, 7, 10), now: DateTime.utc(2026, 11, 7, 12)),
      ]))));
      expect(txt('Waiting for Alex\'s phone'), findsWidgets);
      expect(txt('Alex keeps data on their phone'), findsOneWidget);
      expect(find.text('Computed on Alex\'s phone. Updated 2 h ago.'), findsOneWidget);
    });
  });
}

class _Circles implements CircleService {
  _Circles({this.onlyNormal = false});
  final bool onlyNormal;
  @override
  Future<List<Circle>> listCircles() async => <Circle>[
        const Circle(id: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc', name: 'Family', role: 'member', sharingEnabled: true, memberCount: 2, e2eeMode: 'off'),
        if (!onlyNormal) const Circle(id: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd', name: 'Private one', role: 'member', sharingEnabled: true, memberCount: 2, e2eeMode: 'private'),
      ];
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}
