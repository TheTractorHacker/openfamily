import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart' hide Circle;
import 'package:openfamily/models/circle.dart';
import 'package:openfamily/models/member.dart';
import 'package:openfamily/models/security_models.dart';
import 'package:openfamily/models/trip.dart';
import 'package:openfamily/screens/link_device_screen.dart';
import 'package:openfamily/screens/processing_policy_screen.dart';
import 'package:openfamily/screens/security_screen.dart';
import 'package:openfamily/screens/trips_screen.dart';
import 'package:openfamily/services/e2ee/e2ee_crypto.dart';
import 'package:openfamily/services/e2ee/e2ee_service.dart';
import 'package:openfamily/services/e2ee/e2ee_trust.dart';
import 'package:openfamily/services/e2ee/e2ee_vault.dart';
import 'package:openfamily/services/e2ee/key_backup.dart';
import 'package:openfamily/services/speed_units.dart';
import 'package:openfamily/theme/app_theme.dart';
import 'package:openfamily/widgets/ds/ds.dart';
import 'package:openfamily/widgets/location_tab_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../screens/trips_screens_test.dart' show FakeTrips;
import '../support/fake_e2ee_server.dart';
import '../support/fake_processing_controller.dart';
import '../support/fake_security_api.dart';
import '../support/location_fixtures.dart';

/// "UI polish 2" goldens (docs/ux/UI_POLISH_2.md): the screens the owner
/// flagged, rendered the way a Galaxy S26 Ultra (412 dp), a typical phone (390)
/// and a Galaxy Z Fold 4 cover display (344 dp, text x1.5) show them.
///
///   OF_GOLDENS=1 flutter test --update-goldens test/goldens/polish2_golden_test.dart
///
/// writes `test/goldens/p2/<screen>_<width>[_x15]_<light|dark>.png`. Skipped
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
      UnitPreferenceService.units.value = UnitSystem.imperial;
      t.view.physicalSize = Size(v.width * 2, v.height * 2);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(_app(screen(), v.dark ? buildDarkTheme() : buildLightTheme(), v.scale));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await t.pump(const Duration(milliseconds: 100));
      await t.pumpAndSettle();
      if (after != null) await after(t);
      expect(t.takeException(), isNull, reason: 'overflow in $name ${v.suffix}');
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('p2/${name}_${v.suffix}.png'));
    }, skip: !_on);
  }
}

Trip _trip(String id, DateTime start, int minutes, double km, double maxMps, double avgMps, {TripMode mode = TripMode.driving}) => Trip(
      id: id,
      userId: 'u1',
      startedAt: start,
      endedAt: start.add(Duration(minutes: minutes)),
      durationS: minutes * 60,
      distanceM: km * 1000,
      maxSpeedMps: maxMps,
      avgSpeedMps: avgMps,
      mode: mode,
      speedSource: 'device_gps',
      start: const LatLng(40.0, -74.0),
      end: const LatLng(40.1, -74.1),
    );

const Circle _foley = Circle(
  id: 'c1',
  name: 'Foley Family',
  role: 'admin',
  sharingEnabled: true,
  memberCount: 2,
  isPrimary: true,
  e2eeMode: 'private',
  serverAssist: true,
);

const Circle _soccer = Circle(
  id: 'c2',
  name: 'Soccer team',
  role: 'member',
  sharingEnabled: false,
  memberCount: 11,
);

void main() {
  setUpAll(_loadFonts);

  final DateTime now = DateTime.now();
  final DateTime today = DateTime(now.year, now.month, now.day, 18, 16);

  _shoot(
    'trips',
    () => TripsScreen(
      member: const Member(id: 'u1', name: 'Blake Foley', position: null, batteryPercent: 80, status: MemberStatus.normal, address: ''),
      api: FakeTrips(trips: <Trip>[
        _trip('t1', today, 37, 45, 33.5, 20.1),
        _trip('t2', today.subtract(const Duration(hours: 2)), 13, 8.7, 21.9, 11.2),
        _trip('t3', today.subtract(const Duration(hours: 5)), 8, 0.16, 4.5, 0.4),
        _trip('t4', today.subtract(const Duration(days: 1)), 22, 2.1, 1.6, 1.2, mode: TripMode.walking),
      ]),
      lanes: null,
    ),
  );

  _shoot(
    'policy',
    () => ProcessingPolicyScreen(
      circle: _foley,
      controller: FakeProcessingController(FakeProcessingController.snapshot(
        lanes: <String, int>{pA: E2ee.lineServer, pB: E2ee.linePhone},
        defaultForNew: E2ee.lineServer,
      )),
    ),
  );

  _shoot(
    'security',
    () => SecurityScreen(
      api: FakeSecurityApi(account: const AccountInfo(id: 'me', email: 'blake@example.com', role: 'admin', totpEnabled: false)),
      keyBackup: KeyBackup(store: MemoryPlatformKeyStore(), prefs: MemoryKeyBackupPrefs()),
    ),
  );

  _shoot(
    'circles_sheet',
    () => LocationTabView(
      map: const FakeMap(),
      circleName: 'Foley Family',
      circles: const <Circle>[_foley, _soccer],
      selectedCircleId: 'c1',
      members: const <Member>[kSelf, kAtHome],
      selfId: 'me',
      placesLoader: fakePlaces,
      onSelectCircle: (String id) {},
      onOpenCircle: (Circle c) {},
      onManageCircles: () {},
      onCheckIn: () {},
      onSos: () {},
      onOpenSettings: () {},
      onInvite: () {},
      onToggleSatellite: () {},
      onLocate: () {},
    ),
    after: (WidgetTester t) async {
      await t.tap(find.textContaining('Location sharing').first);
      await t.pumpAndSettle();
    },
  );

  _shoot(
    'map_header',
    () => LocationTabView(
      map: const FakeMap(),
      circleName: 'Foley Family',
      circles: const <Circle>[_foley, _soccer],
      selectedCircleId: 'c1',
      members: const <Member>[kSelf, kAtHome],
      selfId: 'me',
      placesLoader: fakePlaces,
      onSelectCircle: (String id) {},
      onOpenCircle: (Circle c) {},
      onManageCircles: () {},
      onCheckIn: () {},
      onSos: () {},
      onOpenSettings: () {},
      onInvite: () {},
      onToggleSatellite: () {},
      onLocate: () {},
    ),
  );


  // The shared kit, composed the way the polished screens use it.
  _shoot(
    'kit',
    () => Builder(builder: (BuildContext ctx) => Scaffold(
      appBar: AppBar(title: const Text('Kit')),
      body: DsSettingsList(children: <Widget>[
        const DsChipRow(children: <Widget>[
          DsStatusChip(label: 'Processed by server', icon: Icons.dns_outlined, color: AppColors.accentInk),
          DsStatusChip(label: 'Phone only', icon: Icons.smartphone, color: AppColors.sky),
        ]),
        const SizedBox(height: AppSpace.md),
        DsRowGroup(children: <Widget>[
          Padding(
            padding: EdgeInsets.symmetric(horizontal: DsListRow.compactFor(ctx) ? AppSpace.md : AppSpace.lg, vertical: AppSpace.md),
            child: const DsStatStrip(stats: <DsStat>[
              DsStat(value: '28 mi', label: 'Distance'),
              DsStat(value: '37 min', label: 'Duration'),
              DsStat(value: '75 mph', label: 'Top speed'),
              DsStat(value: '45 mph', label: 'Average'),
            ]),
          ),
        ]),
        const DsSectionHeader('Members', caption: 'Who may keep data on their phone.'),
        DsRowGroup(children: <Widget>[
          DsRadioRow(title: 'Members may opt out', subtitle: 'The default.', selected: true, onTap: () {}, info: 'Long text.'),
          DsRadioRow(title: 'Server processing is required', subtitle: 'Members cannot turn it off.', selected: false, onTap: () {}, info: 'Long text.'),
        ]),
        const DsSectionHeader('Account'),
        DsRowGroup(children: <Widget>[
          DsListRow(title: 'Two-factor authentication', subtitle: 'Off', leading: DsListRow.iconTile(ctx, Icons.shield_outlined, decorative: true), chevron: true, onTap: () {}),
          DsListRow(title: 'Active sessions', subtitle: 'Where you are signed in', leading: DsListRow.iconTile(ctx, Icons.devices_outlined, decorative: true), chevron: true, onTap: () {}),
          DsToggleRow(icon: Icons.restore, title: 'Keep the key through reinstalls', subtitle: 'On', value: true, onChanged: (bool v) {}, info: 'Long text.'),
        ]),
        const DsFootnote('Every change is a signed entry in the key log.', icon: Icons.info_outline),
      ]),
    )),
  );

  group('link another phone', () {
    const String uA = '11111111-1111-4111-8111-111111111111';
    E2eeService phone(FakeE2eeServer s) =>
        E2eeService(api: s.client(uA), vault: MemoryVault(), trust: TrustStore(MemoryTrustKv()), userIdProvider: () async => uA);
    FakeE2eeServer server() => FakeE2eeServer()..names[uA] = 'Alice';

    _shoot('link_choose', () => LinkDeviceScreen(service: phone(server())));
    _shoot('link_new_start', () => LinkDeviceScreen(service: phone(server()), role: LinkRole.newPhone));
  });
}
