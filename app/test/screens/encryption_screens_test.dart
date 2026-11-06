import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/circle.dart';
import 'package:openfamily/screens/circle_detail_screen.dart';
import 'package:openfamily/screens/encryption_keys_screen.dart';
import 'package:openfamily/services/e2ee/e2ee_app.dart';
import 'package:openfamily/widgets/ds/ds.dart';
import 'package:openfamily/screens/key_log_screen.dart';
import 'package:openfamily/screens/member_safety_screen.dart';
import 'package:openfamily/screens/recovery_screens.dart';
import 'package:openfamily/services/circle_service.dart';
import 'package:openfamily/services/e2ee/e2ee_crypto.dart';
import 'package:openfamily/services/e2ee/e2ee_models.dart';
import 'package:openfamily/services/e2ee/e2ee_service.dart';
import 'package:openfamily/services/e2ee/e2ee_trust.dart';
import 'package:openfamily/services/e2ee/e2ee_vault.dart';

import '../support/fake_e2ee_server.dart';

const String uA = '11111111-1111-4111-8111-111111111111';
const String uB = '22222222-2222-4222-8222-222222222222';
const String circleId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';

class FakeCircles implements CircleService {
  FakeCircles({this.me = uA});
  final String me;
  @override
  Future<String> myUserId() async => me;
  @override
  Future<List<CircleMember>> listMembers(String id) async => const <CircleMember>[
        CircleMember(userId: uA, name: 'Alice', role: 'admin', sharingEnabled: true),
        CircleMember(userId: uB, name: 'Bob', role: 'member', sharingEnabled: true),
      ];
  @override
  Future<List<CircleInvite>> listInvites(String id) async => <CircleInvite>[];
  @override
  Future<List<Circle>> listCircles() async => const <Circle>[
        Circle(id: circleId, name: 'Family', role: 'admin', sharingEnabled: true, memberCount: 2),
      ];
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

class FakeScreenSecurity extends ScreenSecurity {
  FakeScreenSecurity();
  final List<bool> calls = <bool>[];
  @override
  Future<void> setSecure(bool on) async => calls.add(on);
}

class FakeStoreVault extends MemoryVault {
  FakeStoreVault(this.level);
  final KeystoreLevel level;
  @override
  Future<KeystoreStatus> status() async => KeystoreStatus(level: level, unlockedDeviceRequired: true);
}

E2eeService svcFor(FakeE2eeServer s, String user, E2eeVault vault, TrustStore trust) =>
    E2eeService(api: s.client(user), vault: vault, trust: trust, userIdProvider: () async => user);

Widget wrap(Widget child, {ThemeData? theme}) => MaterialApp(theme: theme, home: child);

void tall(WidgetTester t, {double scale = 1}) {
  t.view.physicalSize = const Size(800, 4000);
  t.view.devicePixelRatio = 1;
  t.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  addTearDown(t.platformDispatcher.clearAllTestValues);
}

void main() {
  late FakeE2eeServer server;
  late E2eeService alice, bob;
  late TrustStore aliceTrust;

  Future<void> setup(WidgetTester t, {bool aliceRegistered = true, KeystoreLevel level = KeystoreLevel.strongBox}) async {
    server = FakeE2eeServer()..names.addAll(<String, String>{uA: 'Alice', uB: 'Bob'});
    server.circle(circleId, members: <String>[uA, uB], admin: uA);
    aliceTrust = TrustStore(MemoryTrustKv());
    alice = svcFor(server, uA, FakeStoreVault(level), aliceTrust);
    bob = svcFor(server, uB, MemoryVault(), TrustStore(MemoryTrustKv()));
    await t.runAsync(() async {
      if (aliceRegistered) await alice.registerThisDevice();
      await bob.registerThisDevice();
    });
  }

  Future<void> open(WidgetTester t, {ThemeData? theme}) async {
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(wrap(EncryptionKeysScreen(service: alice, circles: FakeCircles()), theme: theme));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await t.pump(const Duration(milliseconds: 100));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await t.pump(const Duration(milliseconds: 100));
  }

  group('Encryption keys screen', () {
    testWidgets('shows fingerprint, key storage level and the honest consistency note after Check server record: MATCH', (t) async {
      tall(t);
      await setup(t);
      await open(t);
      expect(find.text('Encryption keys'), findsOneWidget);
      expect(find.byKey(const Key('keystore-level')), findsOneWidget);
      expect(find.textContaining('StrongBox'), findsOneWidget);
      final LocalIdentity id = (await t.runAsync<LocalIdentity?>(() => alice.identity()))!;
      expect(find.textContaining('Short form: ${id.short}'), findsOneWidget);
      expect(find.text('Copy fingerprint'), findsOneWidget);

      await t.tap(find.text('Check server record'));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await t.pump();
      expect(find.byKey(const Key('server-record-card')), findsOneWidget);
      expect(textOfKey(t, 'server-record-verdict'), 'MATCH');
      expect(find.textContaining('It does NOT prove authenticity'), findsOneWidget);
      expect(find.textContaining('consistency'), findsOneWidget);
    });

    testWidgets('MISMATCH is prominent and says what to do', (t) async {
      tall(t);
      await setup(t);
      await open(t);
      final DeviceKey real = server.keys[uA]!.single;
      final Uint8List other = E2ee.randomBytes(32);
      await t.runAsync(() async {
        server.keys[uA]![0] = DeviceKey(
            deviceId: real.deviceId, userId: uA, kind: 'device', edPub: real.edPub, xPub: other,
            fingerprint: E2ee.hex(await E2ee.fingerprint(real.edPub, other)), digits: '', short: '',
            registeredByDeviceId: real.registeredByDeviceId, registeredByPub: real.registeredByPub,
            registrationAction: 1, registrationSignature: real.registrationSignature, initial: true, label: '', createdAt: real.createdAt);
      });
      await t.tap(find.text('Check server record'));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await t.pump();
      expect(textOfKey(t, 'server-record-verdict'), 'MISMATCH');
      expect(find.textContaining('What to do'), findsOneWidget);
      expect(find.textContaining('different keys'), findsOneWidget);
    });

    testWidgets('a phone without keys offers to create them', (t) async {
      tall(t);
      await setup(t, aliceRegistered: false);
      await open(t);
      expect(find.text('Create keys on this phone'), findsOneWidget);
      expect(find.text('Check server record'), findsNothing);
    });

    testWidgets('circles show Normal by default (OFF) and Private after enabling', (t) async {
      tall(t);
      await setup(t);
      await open(t);
      expect(find.textContaining('Normal - not end-to-end encrypted'), findsOneWidget);
      await t.runAsync(() => alice.enableCircle(circleId));
      await open(t);
      expect(find.textContaining('Private - end-to-end key epoch 1'), findsOneWidget);
    });

    testWidgets('a verified member whose key changed raises a loud banner', (t) async {
      tall(t);
      await setup(t);
      await t.runAsync(() => alice.markVerified(uB));
      final Phone bob2 = Phone(server, uB);
      await t.runAsync(() => bob2.svc.registerThisDevice(reset: true));
      await open(t);
      expect(find.textContaining('Bob\'s encryption key changed'), findsOneWidget);
      expect(find.textContaining('compare the safety number in person'), findsWidgets);
    });

    testWidgets('an invite fingerprint that matches nobody raises an alarm; a match pins the inviter', (t) async {
      tall(t);
      await setup(t);
      await t.runAsync(() => aliceTrust.savePendingInviter('ab' * 32));
      await open(t);
      expect(find.textContaining('could not be matched'), findsOneWidget);
      // A link made by Alice carries HER key; Bob's phone matches it against the server.
      final String fpA = (await t.runAsync<String?>(() => alice.inviteFingerprint()))!;
      expect(await t.runAsync<String?>(() => bob.checkInviter(circleId, fpA)), uA);
      expect(await t.runAsync<String?>(() => bob.checkInviter(circleId, 'cd' * 32)), isNull);
    });

    testWidgets('large text and dark theme lay out without overflow', (t) async {
      tall(t, scale: 2);
      await setup(t);
      await t.runAsync(() => alice.enableCircle(circleId));
      await open(t, theme: ThemeData.dark());
      expect(t.takeException(), isNull);
      expect(find.textContaining('Normal').evaluate().length + find.textContaining('Private').evaluate().length, greaterThan(0));
    });
  });

  group('Private circle toggle in circle settings', () {
    Finder toggle() => find.widgetWithText(DsToggleRow, 'Private circle (end-to-end encrypted)');

    Future<void> openDetail(WidgetTester t, String role) async {
      CircleService.instance = FakeCircles(me: role == 'admin' ? uA : uB);
      E2eeApp.override = alice;
      addTearDown(() => E2eeApp.override = null);
      await t.pumpWidget(wrap(CircleDetailScreen(
          circle: Circle(id: circleId, name: 'Family', role: role, sharingEnabled: true, memberCount: 2))));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await t.pump(const Duration(milliseconds: 100));
    }

    testWidgets('is OFF by default for an admin, explains honestly, and turns on after confirmation', (t) async {
      tall(t);
      await setup(t);
      await openDetail(t, 'admin');
      expect(toggle(), findsOneWidget);
      expect(t.widget<DsToggleRow>(toggle()).value, isFalse);
      expect(find.textContaining('Turning it on encrypts locations'), findsOneWidget);
      expect(server.circles[circleId]!.mode, 'off');

      await t.tap(toggle());
      await t.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('encrypted on each phone'), findsOneWidget);
      expect(find.textContaining('trips, driving reports'), findsOneWidget);
      await t.tap(find.text('Turn on'));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 600)));
      await t.pump(const Duration(milliseconds: 300));
      expect(server.circles[circleId]!.mode, 'private');
      expect(t.widget<DsToggleRow>(toggle()).value, isTrue);
    });

    testWidgets('cancelling the explanation leaves the circle unchanged; members do not see the toggle', (t) async {
      tall(t);
      await setup(t);
      await openDetail(t, 'admin');
      await t.tap(toggle());
      await t.pump(const Duration(milliseconds: 300));
      await t.tap(find.text('Cancel'));
      await t.pump(const Duration(milliseconds: 300));
      expect(server.circles[circleId]!.mode, 'off');
      expect(t.widget<DsToggleRow>(toggle()).value, isFalse);

      await t.pumpWidget(const SizedBox());
      await openDetail(t, 'member');
      expect(toggle(), findsNothing);
    });
  });

  group('Member safety number', () {
    testWidgets('shows 12 groups, compares typed numbers, and pins Verified locally', (t) async {
      tall(t);
      await setup(t);
      await t.pumpWidget(wrap(MemberSafetyScreen(userId: uB, name: 'Bob', service: alice)));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await t.pump();
      final String number = (await t.runAsync(() => alice.safetyWith(uB)))!.number;
      expect(number.split(' ').length, 12);
      expect(find.text('Not verified'), findsOneWidget);

      await t.enterText(find.byType(TextField), '12345');
      await t.tap(find.text('Compare'));
      await t.pump();
      expect(find.textContaining('DOES NOT MATCH'), findsOneWidget);
      await t.enterText(find.byType(TextField), number);
      await t.tap(find.text('Compare'));
      await t.pump();
      expect(find.textContaining('MATCH - the numbers are identical.'), findsOneWidget);

      await t.tap(find.text('Mark as verified'));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await t.pump();
      expect(find.text('Verified'), findsOneWidget);
      expect(await t.runAsync(() => aliceTrust.isVerified(uB)), isTrue);
    });

    testWidgets('after a key change the screen shows the KEY CHANGED warning', (t) async {
      tall(t);
      await setup(t);
      await t.runAsync(() => alice.markVerified(uB));
      final Phone bob2 = Phone(server, uB);
      await t.runAsync(() => bob2.svc.registerThisDevice(reset: true));
      await t.pumpWidget(wrap(MemberSafetyScreen(userId: uB, name: 'Bob', service: alice)));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await t.pump();
      expect(find.text('KEY CHANGED'), findsOneWidget);
      expect(find.textContaining('key CHANGED'), findsOneWidget);
    });
  });

  group('Recovery phrase', () {
    testWidgets('shown once with FLAG_SECURE, 3-word quiz gates registration, nothing stored', (t) async {
      tall(t);
      await setup(t);
      final FakeScreenSecurity sec = FakeScreenSecurity();
      // Deterministic quiz positions via a seeded Random.
      await t.pumpWidget(wrap(RecoverySetupScreen(service: alice, screenSecurity: sec)));
      expect(find.textContaining('lose every phone AND'), findsOneWidget);
      await t.tap(find.text('Show my 24 words'));
      await t.pump();
      expect(sec.calls, <bool>[true]);
      final List<String> words = <String>[
        for (int i = 0; i < 24; i++) _wordText(t, i),
      ];
      expect(words.length, 24);
      expect(find.text('I wrote them down'), findsOneWidget);
      await t.tap(find.text('I wrote them down'));
      await t.pump();

      // Wrong answers are rejected and nothing is registered.
      await t.enterText(find.byKey(const Key('quiz-0')), 'wrong');
      await t.enterText(find.byKey(const Key('quiz-1')), 'wrong');
      await t.enterText(find.byKey(const Key('quiz-2')), 'wrong');
      await t.tap(find.text('Confirm and finish'));
      await t.pump();
      expect(find.textContaining('One of the words is wrong'), findsOneWidget);
      expect(server.activeOf(uA).where((DeviceKey k) => k.isRecovery), isEmpty);

      // Correct answers (read back from the words shown, by position).
      for (int i = 0; i < 3; i++) {
        final String label = (t.widget<InputDecorator>(find.descendant(of: find.byKey(Key('quiz-$i')), matching: find.byType(InputDecorator))).decoration.labelText)!;
        final int n = int.parse(label.split(' ').last);
        await t.enterText(find.byKey(Key('quiz-$i')), words[n - 1]);
      }
      await t.tap(find.text('Confirm and finish'));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
      await t.pump();
      expect(find.text('Recovery phrase set'), findsOneWidget);
      expect(server.activeOf(uA).where((DeviceKey k) => k.isRecovery).length, 1);
      expect(sec.calls.last, isFalse); // screenshots allowed again
      // The phrase is not on the phone: the vault holds only identity data.
      final MemoryVault v = (alice.vault as MemoryVault);
      for (final MapEntry<String, Uint8List> e in v.data.entries) {
        expect(String.fromCharCodes(e.value), isNot(contains(words.take(3).join(' '))));
      }
    });

    testWidgets('restore screen rejects a bad checksum with a clear message', (t) async {
      tall(t);
      await setup(t);
      await t.pumpWidget(wrap(RestoreScreen(service: alice, circles: FakeCircles(), screenSecurity: FakeScreenSecurity())));
      await t.enterText(find.byKey(const Key('restore-phrase')), List<String>.filled(24, 'abandon').join(' '));
      await t.tap(find.text('Restore'));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await t.pump();
      expect(find.textContaining('not a valid 24-word phrase'), findsOneWidget);
    });
  });

  group('Key log screen', () {
    testWidgets('verifies the log and reports a split view when heads differ', (t) async {
      tall(t);
      await setup(t);
      await t.pumpWidget(wrap(KeyLogScreen(service: alice)));
      await t.tap(find.text('Verify the server\'s log now'));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await t.pump();
      expect(find.byKey(const Key('log-verdict')), findsOneWidget);
      expect(textOfKey(t, 'log-verdict'), startsWith('OK'));
      final String token = textOfKey(t, 'head-token');
      await t.enterText(find.widgetWithText(TextField, 'Their token (number:hash)'), token);
      await t.tap(find.text('Compare'));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await t.pump();
      expect(textOfKey(t, 'compare-result'), startsWith('SAME HISTORY'));

      final String bad = '${token.split(':').first}:${'00' * 32}';
      await t.enterText(find.widgetWithText(TextField, 'Their token (number:hash)'), bad);
      await t.tap(find.text('Compare'));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await t.pump();
      expect(textOfKey(t, 'compare-result'), startsWith('DIFFERENT'));
    });
  });
}

String textOfKey(WidgetTester t, String key) {
  final Widget w = t.widget(find.byKey(Key(key)));
  if (w is Text) return w.data!;
  if (w is SelectableText) return w.data!;
  throw StateError('no text');
}

String _wordText(WidgetTester t, int i) {
  final Text w = t.widget<Text>(find.descendant(of: find.byKey(Key('word-$i')), matching: find.byType(Text)));
  return w.data!.split('. ').last;
}

class Phone {
  Phone(FakeE2eeServer server, String user)
      : svc = E2eeService(
            api: server.client(user),
            vault: MemoryVault(),
            trust: TrustStore(MemoryTrustKv()),
            userIdProvider: () async => user);
  final E2eeService svc;
}
