import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/member.dart';
import 'package:openfamily/screens/app_shell.dart';
import 'package:openfamily/screens/circle_create_screen.dart';
import 'package:openfamily/screens/circles_screen.dart';
import 'package:openfamily/screens/family_driving_report_screen.dart';
import 'package:openfamily/screens/place_picker_screen.dart';
import 'package:openfamily/screens/settings_screen.dart';
import 'package:openfamily/screens/sos_screen.dart';
import 'package:openfamily/models/place.dart';
import 'package:openfamily/services/geocoding_service.dart';
import 'package:openfamily/services/server_features.dart';
import 'package:openfamily/services/speed_units.dart';
import 'package:openfamily/widgets/location_tab_view.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../screens/alert_screens_test.dart' show FakeDialer;
import '../screens/circles_screens_test.dart' show FakeCircleService;
import '../support/fake_geocoding.dart';
import '../support/golden_utils.dart';
import '../support/location_fixtures.dart';
import '../support/trip_report_fixtures.dart';

/// Large-screen / system-UI goldens ("ls_*"). Each is rendered through
/// [pumpOnDevice], which applies the device's status bar, cutout and gesture
/// bar as real MediaQuery insets and paints fake system chrome on top.
///
/// `OF_GOLDENS=1 flutter test --update-goldens test/goldens/ls_golden_test.dart`

Member _m(String id, String name, Color c, {bool driving = false}) => Member(
  id: id,
  name: name,
  position: null,
  batteryPercent: 80,
  status: MemberStatus.normal,
  address: '',
  avatarColor: c,
  movement: driving ? MovementType.car : MovementType.none,
  speedMph: driving ? 42 : null,
);

Map<String, dynamic> _busy() {
  final Map<String, dynamic> j = reportJson(
    rich: true,
    twoMembers: true,
    speeding: 3,
    hardBrake: 2,
    drives: 9,
    sensor: true,
  );
  const List<double> km = <double>[22000, 31000, 12000, 41000, 58000, 9000, 24000];
  j['days'] = <Map<String, dynamic>>[
    for (int i = 0; i < 7; i++)
      <String, dynamic>{
        'date': '2026-10-${19 + i}',
        'drives': i == 5 ? 1 : 2,
        'distance_m': km[i],
        'top_speed_mps': 24.0 + i * 2,
      },
  ];
  final List<Map<String, dynamic>> trips = <Map<String, dynamic>>[];
  for (int i = 0; i < 10; i++) {
    final int day = 25 - i ~/ 2;
    trips.add(<String, dynamic>{
      'id': 't$i',
      'user_id': i.isEven ? 'u1' : 'u2',
      'name': i.isEven ? 'Blake' : 'Brian',
      'started_at': '2026-10-${day}T${i.isEven ? '07:52' : '17:10'}:00',
      'ended_at': '2026-10-${day}T${i.isEven ? '08:20' : '17:40'}:00',
      'distance_m': 9000.0 + i * 1300,
      'duration_s': 1680,
      'max_speed_mps': 24.0 + i,
      'mode': 'driving',
      'event_counts': <String, dynamic>{
        'speeding': i % 4 == 0 ? 1 : 0,
        'hard_brake': i % 3 == 0 ? 2 : 0,
        'rapid_accel': 0,
        'phone_use': 0,
      },
    });
  }
  j['recent_trips'] = trips;
  return j;
}

Widget _shell(AppTab tab, Widget Function(BuildContext) body) => AppShell(
  initialTab: tab,
  tabBuilders: <AppTab, WidgetBuilder>{tab: body},
);

Widget _location() => _shell(
  AppTab.location,
  (_) => LocationTabView(
    map: const FakeMap(),
    circleName: 'Frank Family',
    circles: kCircles,
    members: const <Member>[kSelf, kDriver, kAtHome, kOffline],
    selfId: 'me',
    placesLoader: fakePlaces,
    onCheckIn: () {},
    onSos: () {},
    onOpenSettings: () {},
    onInvite: () {},
    onToggleSatellite: () {},
    onLocate: () {},
  ),
);

Widget _driving() => _shell(
  AppTab.driving,
  (_) => FamilyDrivingReportScreen(
    members: ValueNotifier<List<Member>>(<Member>[
      _m('u1', 'Blake', const Color(0xFF0284C7), driving: true),
      _m('u2', 'Brian', const Color(0xFF7C3AED)),
    ]),
    userId: ValueNotifier<String?>('u1'),
    api: FakeTripReportApi(result: _busy()),
    clock: () => DateTime(2026, 10, 25, 12),
    detectionLoader: () async => true,
  ),
);

void _golden(
  String name,
  DeviceSpec spec,
  Widget Function() screen, {
  bool dark = false,
  double scale = 1,
  double keyboard = 0,
  Future<void> Function(WidgetTester)? after,
}) {
  final String file =
      'ls_${name}_${spec.name}_${dark ? 'dark' : 'light'}'
      '${scale == 1 ? '' : '_x${(scale * 100).round()}'}'
      '${keyboard > 0 ? '_kb' : ''}';
  testWidgets('golden $file', (WidgetTester t) async {
    await pumpOnDevice(
      t,
      screen(),
      spec: spec,
      dark: dark,
      textScale: scale,
      keyboard: keyboard,
    );
    if (after != null) await after(t);
    await expectGolden(t, '$file.png');
  }, skip: !goldensOn);
}

Future<void> _halfSheet(WidgetTester t) async {
  final Finder people = find.text('People');
  if (people.evaluate().isEmpty) return;
  await t.fling(people.first, const Offset(0, -120), 400);
  await t.pumpAndSettle();
}

Widget _picker() => const PlacePickerScreen(
  placeName: 'Grandma',
  icon: Icons.favorite,
  initial: Place(
    id: 'p1',
    name: 'Grandma',
    icon: Icons.favorite,
    address: 'Pinned location',
    position: LatLng(39.799, -89.65),
    radiusMeters: 152.4,
  ),
);

void main() {
  setUpAll(loadGoldenFonts);
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'driving_detection_disclosure_seen': true,
      'sos_intro_seen': true,
    });
    UnitPreferenceService.units.value = UnitSystem.imperial;
    GeocodingService.backend = FakeGeocodingBackend()
      ..results = <GeocodeSuggestion>[kMainStreet, kLibrary]
      ..reverseResult = '9 Elm St, Springfield, IL';
    ServerFeatures.instance.reset();
    ServerFeatures.instance.apply(<String, dynamic>{
      'geocoder': <String, dynamic>{'enabled': true, 'autocomplete': true},
    });
  });
  tearDown(() {
    GeocodingService.backend = const ApiGeocodingBackend();
    ServerFeatures.instance.reset();
  });

  // Location tab (map + People/Places sheet) inside the shell.
  _golden('location', kPhone360, _location, after: _halfSheet);
  _golden('location', kS26, _location, dark: true);
  _golden('location', kS26, _location, after: _halfSheet);
  _golden('location', kWide840L, _location);
  _golden('location', kWide840L, _location, dark: true, after: _halfSheet);

  // Driving tab.
  _golden('driving', kPhone360, _driving);
  _golden('driving', kS26, _driving);
  _golden('driving', kS26, _driving, dark: true);
  _golden('driving', kWide840L, _driving);
  _golden('driving', kS26, _driving, scale: 2);

  // Settings.
  _golden('settings', kPhone360, () => const SettingsScreen());
  _golden('settings', kS26, () => const SettingsScreen(), dark: true);
  _golden('settings', kWide840L, () => const SettingsScreen());
  _golden('settings', kS26, () => const SettingsScreen(), scale: 2);

  // A DsPage form, with and without the keyboard.
  _golden('form', kPhone360, () => CircleCreateScreen(service: FakeCircleService()));
  _golden(
    'form',
    kS26,
    () => CircleCreateScreen(service: FakeCircleService()),
    dark: true,
    keyboard: 300,
    after: (WidgetTester t) async {
      await t.tap(find.byType(TextField).first);
      await t.pumpAndSettle();
    },
  );
  _golden('form', kWide840L, () => CircleCreateScreen(service: FakeCircleService()));

  // SOS.
  _golden('sos', kPhone360, () => SosScreen(smsConfigured: true, dialer: FakeDialer()));
  _golden('sos', kS26, () => SosScreen(smsConfigured: true, dialer: FakeDialer()), dark: true);
  _golden('sos', kWide840L, () => SosScreen(smsConfigured: true, dialer: FakeDialer()));

  // Place picker, keyboard up.
  _golden(
    'picker',
    kS26,
    _picker,
    keyboard: 300,
    after: (WidgetTester t) async {
      await t.enterText(find.widgetWithText(TextField, 'Address'), '123 Main');
      await t.pump(const Duration(milliseconds: 400));
      await t.pump(const Duration(milliseconds: 500));
    },
  );
  _golden(
    'picker',
    kPhone360,
    _picker,
    dark: true,
    keyboard: 280,
    after: (WidgetTester t) async {
      await t.enterText(find.widgetWithText(TextField, 'Address'), '123 Main');
      await t.pump(const Duration(milliseconds: 400));
      await t.pump(const Duration(milliseconds: 500));
    },
  );
  _golden('picker', kWide840L, _picker);

  // Circles.
  _golden('circles', kPhone360, () => CirclesScreen(service: FakeCircleService()));
  _golden('circles', kS26, () => CirclesScreen(service: FakeCircleService()), dark: true);
  _golden('circles', kWide840L, () => CirclesScreen(service: FakeCircleService()));
}
