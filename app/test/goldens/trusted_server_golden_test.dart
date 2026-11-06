import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/circle.dart';
import 'package:openfamily/screens/trusted_server_screen.dart';
import 'package:openfamily/services/e2ee/e2ee_service.dart';
import 'package:openfamily/services/e2ee/e2ee_trust.dart';
import 'package:openfamily/services/e2ee/e2ee_vault.dart';
import 'package:openfamily/theme/app_theme.dart';

import '../support/fake_e2ee_server.dart';
import '../support/viewer_fixture.dart';

/// Golden renders of the Trusted server screen. Run with
/// `OF_GOLDENS=1 flutter test --update-goldens test/goldens/trusted_server_golden_test.dart`.
final bool _on = Platform.environment['OF_GOLDENS'] == '1';

const String uA = '11111111-1111-4111-8111-111111111111';
const String uB = '22222222-2222-4222-8222-222222222222';
const String cid = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';

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
    final FontLoader il = FontLoader('MaterialIcons')..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
    await il.load();
  }
}

void main() {
  setUpAll(_loadFonts);
  for (final String scenario in <String>['off', 'enrol', 'waiting']) {
    for (final bool dark in <bool>[false, true]) {
      testWidgets('golden drv_trusted_server_${scenario}_${dark ? 'dark' : 'light'}', (WidgetTester t) async {
        final FakeE2eeServer server = FakeE2eeServer()..names.addAll(<String, String>{uA: 'Alice', uB: 'Bob'});
        server.circle(cid, members: <String>[uA, uB], admin: uA);
        final E2eeService alice = E2eeService(
            api: server.client(uA), vault: MemoryVault(), trust: TrustStore(MemoryTrustKv()), userIdProvider: () async => uA);
        final E2eeService bob = E2eeService(
            api: server.client(uB), vault: MemoryVault(), trust: TrustStore(MemoryTrustKv()), userIdProvider: () async => uB);
        server.serverModeEnabled = scenario != 'off';
        await t.runAsync(() async {
          await alice.registerThisDevice();
          await bob.registerThisDevice();
          await alice.enableCircle(cid);
          if (scenario == 'waiting') {
            final ViewerFixture srv = await ViewerFixture.create(uA);
            final String ap = await alice.approveLinkRequest(
                await alice.inspectViewerRequest(await srv.request(kind: 'server', name: 'OpenFamily server')));
            await srv.register(server, ap, kind: 'server', label: 'OpenFamily server');
            server.pinnedServerDevice = srv.deviceId;
            await alice.consentToServer(cid);
          }
        });
        t.view.physicalSize = const Size(780, 2400);
        t.view.devicePixelRatio = 2;
        addTearDown(t.view.reset);
        await t.pumpWidget(MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: (dark ? buildDarkTheme() : buildLightTheme()).copyWith(textTheme: (dark ? buildDarkTheme() : buildLightTheme()).textTheme.apply(fontFamily: 'Roboto')),
          builder: (BuildContext c, Widget? child) => DefaultTextStyle.merge(style: const TextStyle(fontFamily: 'Roboto'), child: child!),
          home: RepaintBoundary(
              child: TrustedServerScreen(
                  circle: const Circle(id: cid, name: 'Family', role: 'admin', sharingEnabled: true, memberCount: 2), service: alice)),
        ));
        for (int i = 0; i < 3; i++) {
          await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
          await t.pump(const Duration(milliseconds: 100));
        }
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('drv_trusted_server_${scenario}_${dark ? 'dark' : 'light'}.png'));
      }, skip: !_on);
    }
  }
}
