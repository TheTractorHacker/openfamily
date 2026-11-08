// The Private toggle and the Encryption keys screen when this phone's own key
// cannot be used: a real reason and a way out, never "can't reach the server".
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/screens/circle_detail_screen.dart';
import 'package:openfamily/screens/encryption_keys_screen.dart';
import 'package:openfamily/services/circle_service.dart';
import 'package:openfamily/services/e2ee/e2ee_app.dart';
import 'package:openfamily/services/e2ee/e2ee_service.dart';
import 'package:openfamily/services/e2ee/e2ee_trust.dart';

import '../services/e2ee/local_key_problem_test.dart' show FlakyVault;
import '../support/fake_e2ee_server.dart';

const String uA = '11111111-1111-4111-8111-111111111111';

void tall(WidgetTester t) {
  t.view.physicalSize = const Size(800, 3000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('turning Private off with an unreadable key explains it and opens Encryption keys', (WidgetTester t) async {
    tall(t);
    final FakeE2eeServer server = FakeE2eeServer();
    final FlakyVault v = FlakyVault();
    final E2eeService svc = E2eeService(api: server.client(uA), vault: v, trust: TrustStore(MemoryTrustKv()), userIdProvider: () async => uA);
    await svc.registerThisDevice();
    E2eeApp.override = E2eeService(api: server.client(uA), vault: v, trust: TrustStore(MemoryTrustKv()), userIdProvider: () async => uA);
    addTearDown(() => E2eeApp.override = null);
    v.failWith = PlatformException(code: 'keystore', message: 'AEADBadTagException');

    final CircleException err = describeCircleError(const LocalKeyException(LocalKeyProblem.unreadable, cause: 'PlatformException'));
    await t.pumpWidget(MaterialApp(
      home: Builder(
        builder: (BuildContext c) => Scaffold(
          body: TextButton(onPressed: () => showPrivateKeyProblem(c, err, turningOff: true), child: const Text('go')),
        ),
      ),
    ));
    await t.tap(find.text('go'));
    await t.pumpAndSettle();
    expect(find.textContaining("encryption key could not be read"), findsOneWidget);
    expect(find.textContaining('reach the server'), findsNothing);
    expect(find.textContaining('Another admin of this circle can also turn Private off'), findsOneWidget);
    await t.tap(find.text('Open Encryption keys'));
    await t.pumpAndSettle();
    expect(find.byType(EncryptionKeysScreen), findsOneWidget);
    // The screen does not dead-end on "Something went wrong": it offers the repair.
    expect(find.byKey(const Key('keys-repair-title')), findsOneWidget);
    expect(find.byKey(const Key('keys-repair-reset')), findsOneWidget);
  });

  testWidgets('"Set this phone up again" drops the unreadable copy and leads to restore / new keys', (WidgetTester t) async {
    tall(t);
    final FakeE2eeServer server = FakeE2eeServer();
    final FlakyVault v = FlakyVault();
    final E2eeService first = E2eeService(api: server.client(uA), vault: v, trust: TrustStore(MemoryTrustKv()), userIdProvider: () async => uA);
    await first.registerThisDevice();
    v.failWith = PlatformException(code: 'keystore', message: 'AEADBadTagException');
    final E2eeService svc = E2eeService(api: server.client(uA), vault: v, trust: TrustStore(MemoryTrustKv()), userIdProvider: () async => uA);
    await t.pumpWidget(MaterialApp(home: EncryptionKeysScreen(service: svc)));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('keys-repair-title')), findsOneWidget);
    await t.tap(find.byKey(const Key('keys-repair-reset')));
    await t.pumpAndSettle();
    expect(find.text('Set this phone up again?'), findsOneWidget);
    await t.tap(find.text('Remove and set up'));
    await t.pumpAndSettle();
    expect(v.data, isEmpty, reason: 'only this phone\'s unreadable copy is removed');
    expect(find.text('This phone has no registered key'), findsOneWidget);
    expect(find.byKey(const Key('keys-setup-restore')), findsOneWidget);
    expect(server.keys[uA]!.where((k) => k.isActive), isNotEmpty, reason: 'nothing is revoked on the server');
  });
}
