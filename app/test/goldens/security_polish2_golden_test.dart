import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/security_models.dart';
import 'package:openfamily/screens/encryption_keys_screen.dart';
import 'package:openfamily/screens/link_device_screen.dart';
import 'package:openfamily/screens/security_screen.dart';
import 'package:openfamily/services/e2ee/e2ee_service.dart';
import 'package:openfamily/services/e2ee/e2ee_trust.dart';
import 'package:openfamily/services/e2ee/e2ee_vault.dart';
import 'package:openfamily/services/e2ee/key_backup.dart';
import 'package:openfamily/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../screens/encryption_screens_test.dart' show FakeCircles, FakeStoreVault, svcFor;
import '../support/fake_e2ee_server.dart';
import '../support/fake_security_api.dart';

/// "UI polish 2", security track (docs/ux/UI_POLISH_2.md): Security, Encryption keys and
/// Link another phone, rendered like the owner's screens, rendered the way a Galaxy S26 Ultra (412 dp), a typical phone (390)
/// and a Galaxy Z Fold 4 cover display (344 dp, text x1.5) show them.
///
///   OF_GOLDENS=1 flutter test --update-goldens test/goldens/security_polish2_golden_test.dart
///
/// writes `test/goldens/p2/sec_<screen>_<width>[_x15]_<light|dark>.png`. Skipped
/// without OF_GOLDENS=1.
final bool _on = Platform.environment['OF_GOLDENS'] == '1';

Future<void> _loadFonts() async {
  final String? root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) return;
  final String dir = '$root/bin/cache/artifacts/material_fonts';
  final FontLoader roboto = FontLoader('Roboto');
  for (final String n in <String>['Roboto-Regular', 'Roboto-Bold']) {
    final File f = File('$dir/$n.ttf');
    if (f.existsSync()) roboto.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
  }
  await roboto.load();
  final File icons = File('$dir/MaterialIcons-Regular.otf');
  if (icons.existsSync()) {
    final FontLoader il = FontLoader('MaterialIcons')
      ..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
    await il.load();
  }
}

Widget _app(Widget home, ThemeData theme, double scale) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme.copyWith(
        textTheme: theme.textTheme.apply(fontFamily: 'Roboto'),
        // Explicit list-tile styles carry no family; keep the golden font.
        listTileTheme: theme.listTileTheme.copyWith(
          titleTextStyle: theme.listTileTheme.titleTextStyle?.copyWith(fontFamily: 'Roboto'),
          subtitleTextStyle: theme.listTileTheme.subtitleTextStyle?.copyWith(fontFamily: 'Roboto'),
        ),
      ),
      builder: (BuildContext c, Widget? child) => MediaQuery(
        data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
        child: DefaultTextStyle.merge(style: const TextStyle(fontFamily: 'Roboto'), child: child!),
      ),
      home: home,
    );

class _Variant {
  const _Variant(this.width, this.scale, this.dark, {this.height = 844});
  final double width, scale, height;
  final bool dark;
  String get suffix => '${width.round()}${scale == 1 ? '' : '_x${(scale * 10).round()}'}_${dark ? 'dark' : 'light'}';
}

const List<_Variant> _variants = <_Variant>[
  _Variant(390, 1, true),
  _Variant(390, 1, false),
  _Variant(344, 1.5, true, height: 1000),
  _Variant(344, 1.5, false, height: 1000),
];

void _shoot(
  String name,
  Widget Function() screen, {
  Future<void> Function(WidgetTester)? after,
  List<_Variant> variants = _variants,
}) {
  for (final _Variant v in variants) {
    testWidgets('p2 $name ${v.suffix}', (WidgetTester t) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      t.view.physicalSize = Size(v.width * 2, v.height * 2);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(_app(screen(), v.dark ? buildDarkTheme() : buildLightTheme(), v.scale));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await t.pump(const Duration(milliseconds: 100));
      await t.pumpAndSettle();
      if (after != null) await after(t);
      expect(t.takeException(), isNull, reason: 'overflow in $name ${v.suffix}');
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('p2/sec_${name}_${v.suffix}.png'));
    }, skip: !_on);
  }
}


const String uA = '11111111-1111-4111-8111-111111111111';
const String uB = '22222222-2222-4222-8222-222222222222';
const String circleId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';

void main() {
  setUpAll(_loadFonts);

  _shoot(
    'security',
    () => SecurityScreen(
      api: FakeSecurityApi(account: const AccountInfo(id: 'me', email: 'blake@example.com', role: 'admin', totpEnabled: false)),
      keyBackup: KeyBackup(store: MemoryPlatformKeyStore(), prefs: MemoryKeyBackupPrefs()),
    ),
  );

  // Non-admin, key copy cannot be kept here: the row carries the short problem line in the error colour.
  _shoot(
    'security_problem',
    () => SecurityScreen(
      api: FakeSecurityApi(account: const AccountInfo(id: 'me', email: 'blake@example.com', role: 'member', totpEnabled: true)),
      keyBackup: KeyBackup(store: MemoryPlatformKeyStore()..failAll = true, prefs: MemoryKeyBackupPrefs()),
    ),
  );

  late FakeE2eeServer server;
  Future<Widget> keysScreen(WidgetTester t) async {
    server = FakeE2eeServer()..names.addAll(<String, String>{uA: 'Alice', uB: 'Bob'});
    server.circle(circleId, members: <String>[uA, uB], admin: uA);
    final E2eeService alice = svcFor(server, uA, FakeStoreVault(KeystoreLevel.strongBox), TrustStore(MemoryTrustKv()));
    final E2eeService bob = svcFor(server, uB, MemoryVault(), TrustStore(MemoryTrustKv()));
    await t.runAsync(() async {
      await alice.registerThisDevice();
      await bob.registerThisDevice();
    });
    return EncryptionKeysScreen(service: alice, circles: FakeCircles());
  }

  for (final _Variant v in _variants) {
    testWidgets('p2 sec keys ${v.suffix}', (WidgetTester t) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      t.view.physicalSize = Size(v.width * 2, v.height * 2);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      final Widget screen = await keysScreen(t);
      await t.pumpWidget(_app(screen, v.dark ? buildDarkTheme() : buildLightTheme(), v.scale));
      for (int i = 0; i < 3; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
        await t.pump(const Duration(milliseconds: 100));
      }
      await t.pumpAndSettle();
      expect(t.takeException(), isNull, reason: 'overflow in keys ${v.suffix}');
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('p2/sec_keys_${v.suffix}.png'));
    }, skip: !_on);
  }

  group('link another phone', () {
    E2eeService phone(FakeE2eeServer s) =>
        E2eeService(api: s.client(uA), vault: MemoryVault(), trust: TrustStore(MemoryTrustKv()), userIdProvider: () async => uA);
    FakeE2eeServer srv() => FakeE2eeServer()..names[uA] = 'Alice';

    _shoot('link_choose', () => LinkDeviceScreen(service: phone(srv())));
    _shoot(
      'link_choose_open',
      () => LinkDeviceScreen(service: phone(srv())),
      after: (WidgetTester t) async {
        await t.tap(find.text('No other phone?'));
        await t.pumpAndSettle();
      },
    );
    _shoot('link_new_start', () => LinkDeviceScreen(service: phone(srv()), role: LinkRole.newPhone));
  });
}
