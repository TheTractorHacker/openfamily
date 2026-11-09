import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/circle.dart';
import 'package:openfamily/screens/encryption_circle_screen.dart';
import 'package:openfamily/screens/processing_screen.dart';
import 'package:openfamily/screens/trusted_server_screen.dart' show kTrustedServerWarning;
import 'package:openfamily/services/e2ee/e2ee_service.dart';
import 'package:openfamily/services/e2ee/e2ee_trust.dart';
import 'package:openfamily/services/e2ee/e2ee_vault.dart';
import 'package:openfamily/services/e2ee/lanes_store.dart' show LaneStatus;
import 'package:openfamily/widgets/trusted_server_prompt.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('PrivateModeChoiceDialog', () {
    Future<PrivateModeChoice?> open(WidgetTester t, {required Future<void> Function() act}) async {
      tall(t);
      PrivateModeChoice? result;
      bool closed = false;
      await t.pumpWidget(MaterialApp(
        home: Builder(
          builder: (BuildContext c) => TextButton(
            onPressed: () async {
              result = await showDialog<PrivateModeChoice>(
                  context: c, builder: (_) => const PrivateModeChoiceDialog(message: 'msg'));
              closed = true;
            },
            child: const Text('open'),
          ),
        ),
      ));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      await act();
      await t.pumpAndSettle();
      expect(closed, isTrue);
      return result;
    }

    testWidgets('trusted is preselected, the honest warning is shown, and confirming returns trusted', (t) async {
      final PrivateModeChoice? r = await open(t, act: () async {
        expect(find.text('Recommended by your server admin'), findsOneWidget);
        expect(find.byKey(const Key('choice-warning')), findsOneWidget);
        final Text w = t.widget(find.byKey(const Key('choice-warning')));
        expect(w.data, kTrustedServerWarning);
        await t.tap(find.byKey(const Key('choice-confirm')));
      });
      expect(r, PrivateModeChoice.trusted);
    });

    testWidgets('the user can pick strict end-to-end instead', (t) async {
      final PrivateModeChoice? r = await open(t, act: () async {
        await t.tap(find.byKey(const Key('choice-strict')));
        await t.pumpAndSettle();
        expect(find.byKey(const Key('choice-warning')), findsNothing);
        await t.tap(find.byKey(const Key('choice-confirm')));
      });
      expect(r, PrivateModeChoice.strict);
    });
  });

  group('trusted-server prompt on the circle screen', () {
    late FakeE2eeServer server;
    late E2eeService alice;

    Future<void> setup(WidgetTester t, {required bool dflt, bool pinned = true, bool consented = false}) async {
      server = FakeE2eeServer()..names.addAll(<String, String>{uA: 'Alice', uB: 'Bob'});
      server.circle(cid, members: <String>[uA, uB], admin: uA);
      alice = E2eeService(
          api: server.client(uA), vault: MemoryVault(), trust: TrustStore(MemoryTrustKv()), userIdProvider: () async => uA);
      await t.runAsync(() async {
        await alice.registerThisDevice();
        await alice.enableCircle(cid);
        if (pinned) {
          final ViewerFixture srv = await ViewerFixture.create(uA);
          final String ap = await alice.approveLinkRequest(
              await alice.inspectViewerRequest(await srv.request(kind: 'server', name: 'Orbitly server')));
          await srv.register(server, ap, kind: 'server', label: 'Orbitly server');
          server.pinnedServerDevice = srv.deviceId;
        }
      });
      server.serverModeEnabled = true;
      server.trustedServerDefault = dflt;
      if (consented) {
        await t.runAsync(() => alice.consentToServer(cid));
      }
      tall(t);
      await t.pumpWidget(MaterialApp(
          home: EncryptionCircleScreen(
              circle: const Circle(id: cid, name: 'Family', role: 'admin', sharingEnabled: true, memberCount: 2), service: alice)));
      await settle(t);
    }

    testWidgets('shown when default is on, key pinned, not consented; never sends a consent', (t) async {
      await setup(t, dflt: true);
      expect(find.byKey(const Key('trusted-server-prompt')), findsOneWidget);
      expect(server.circles[cid]!.serverConsents, isEmpty);
      await t.tap(find.byKey(const Key('trusted-server-prompt-open')));
      await settle(t);
      // The prompt only leads to the Server processing screen; nothing is signed or consented on the way.
      expect(find.byType(ProcessingScreen), findsOneWidget);
      expect(server.circles[cid]!.serverConsents, isEmpty);
      expect(server.circles[cid]!.prefs, isEmpty);
      expect(server.circles[cid]!.assist, isFalse);
    });

    testWidgets('dismissing is remembered for the circle', (t) async {
      await setup(t, dflt: true);
      await t.tap(find.byKey(const Key('trusted-server-prompt-dismiss')));
      await t.pump();
      expect(find.byKey(const Key('trusted-server-prompt')), findsNothing);
      expect(await const TrustedServerPromptStore().dismissed(cid), isTrue);
      expect(await const TrustedServerPromptStore().dismissed('other'), isFalse);
      // Reopen: still gone.
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(MaterialApp(
          home: EncryptionCircleScreen(
              circle: const Circle(id: cid, name: 'Family', role: 'admin', sharingEnabled: true, memberCount: 2), service: alice)));
      await settle(t);
      expect(find.byKey(const Key('trusted-server-prompt')), findsNothing);
    });

    testWidgets('the "Server processing" row says the real state of my own data, from the verified lane facts', (t) async {
      await setup(t, dflt: false);
      expect(processingRowSubtitle(legacy: false, facts: null), 'See where your data is processed');
      for (final (({LaneStatus status, bool assist}) facts, String text) c in <(({LaneStatus status, bool assist}), String)>[
        ((status: LaneStatus.serverAssisted, assist: true), 'On for you'),
        ((status: LaneStatus.phoneOnly, assist: true), 'Phone only for you (you can switch it on)'),
        ((status: LaneStatus.phoneOnly, assist: false), 'Phone only (off for this circle)'),
        ((status: LaneStatus.consentRequired, assist: true), 'Required in this circle: needs your OK'),
      ]) {
        await t.pumpWidget(const SizedBox());
        await t.pumpWidget(MaterialApp(
            home: EncryptionCircleScreen(
                circle: const Circle(id: cid, name: 'Family', role: 'admin', sharingEnabled: true, memberCount: 2),
                service: alice,
                laneFacts: (String id) async => c.$1)));
        await settle(t);
        expect(find.descendant(of: find.byKey(const Key('processing-row')), matching: find.text(c.$2)), findsOneWidget, reason: c.$2);
      }
      expect(find.text('Server or phone only'), findsNothing);
      expect(processingRowSubtitle(legacy: true, facts: (status: LaneStatus.serverAssisted, assist: true)), 'Old mode: the server can read it');
      expect(processingRowSubtitle(legacy: false, facts: (status: LaneStatus.verificationFailed, assist: true)), 'Phone only (could not be confirmed)');
    });

    testWidgets('hidden when the default is off, the key is not pinned, or I already consented', (t) async {
      await setup(t, dflt: false);
      expect(find.byKey(const Key('trusted-server-prompt')), findsNothing);
      await setup(t, dflt: true, pinned: false);
      expect(find.byKey(const Key('trusted-server-prompt')), findsNothing);
      await setup(t, dflt: true, consented: true);
      expect(find.byKey(const Key('trusted-server-prompt')), findsNothing);
    });
  });
}
