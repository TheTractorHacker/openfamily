import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:openfamily/models/member.dart';
import 'package:openfamily/models/place.dart';
import 'package:openfamily/models/trip.dart';
import 'package:openfamily/screens/alert_status_screen.dart';
import 'package:openfamily/screens/driving_report_screen.dart';
import 'package:openfamily/screens/places_screen.dart';
import 'package:openfamily/screens/sos_screen.dart';
import 'package:openfamily/screens/trips_screen.dart';
import 'package:openfamily/models/alert.dart';
import 'package:openfamily/services/speed_units.dart';
import 'package:openfamily/services/trips_service.dart';
import 'package:openfamily/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../screens/alert_screens_test.dart'
    show FakeAlertService, FakeDialer, detail, row;
import '../screens/trips_screens_test.dart' show FakeTrips;

/// Golden renders of the safety / trips / places screens. Run with
/// `OF_GOLDENS=1 flutter test --update-goldens test/goldens`.
final bool _on = Platform.environment['OF_GOLDENS'] == '1';

Future<void> _loadFonts() async {
  final String? root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) return;
  final String dir = '$root/bin/cache/artifacts/material_fonts';
  final FontLoader roboto = FontLoader('Roboto');
  for (final String n in <String>['Roboto-Regular', 'Roboto-Bold']) {
    final File f = File('$dir/$n.ttf');
    if (f.existsSync()) {
      roboto.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
    }
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
      ),
      builder: (BuildContext c, Widget? child) => MediaQuery(
        data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
        child: DefaultTextStyle.merge(
          style: const TextStyle(fontFamily: 'Roboto'),
          child: child!,
        ),
      ),
      home: home,
    );

void _golden(
  String name,
  Widget Function() screen, {
  double scale = 1,
  bool settle = true,
  Future<void> Function(WidgetTester)? after,
}) {
  for (final bool dark in <bool>[false, true]) {
    final String file = '${name}_${dark ? 'dark' : 'light'}'
        '${scale == 1 ? '' : '_x${scale.toStringAsFixed(0)}'}';
    testWidgets('golden $file', (WidgetTester t) async {
      t.view.physicalSize = const Size(780, 1688);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        _app(screen(), dark ? buildDarkTheme() : buildLightTheme(), scale),
      );
      // Let asset images (logo) decode before the first frame is captured.
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      if (settle) {
        await t.pumpAndSettle();
      } else {
        await t.pump(const Duration(milliseconds: 100));
      }
      if (after != null) await after(t);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('$file.png'));
    }, skip: !_on);
  }
}


Trip _trip(String id, DateTime start, {TripMode mode = TripMode.driving}) {
  return Trip(
    id: id,
    userId: 'u1',
    startedAt: start,
    endedAt: start.add(const Duration(minutes: 20)),
    durationS: 1200,
    distanceM: 16093.44,
    maxSpeedMps: 26.8224,
    avgSpeedMps: 13.4,
    mode: mode,
    speedSource: 'device_gps',
    start: const LatLng(40.0, -74.0),
    end: const LatLng(40.1, -74.1),
  );
}

const Member _sam = Member(
  id: 'u1',
  name: 'Sam',
  position: null,
  batteryPercent: 80,
  status: MemberStatus.normal,
  address: '',
);

TripSummary _summary() => TripSummary(
      from: DateTime(2026, 10, 24),
      to: DateTime(2026, 10, 25),
      tripCount: 3,
      totalDistanceM: 16093.44,
      driving: const DrivingStats(
        tripCount: 2,
        distanceM: 16093.44,
        driveTimeS: 1200,
        maxSpeedMps: 26.8224,
        avgSpeedMps: 13.4,
        speedEvents: 2,
      ),
      speedThresholdMps: 31.3,
      stops: <TripStop>[
        TripStop(
          arrivedAt: DateTime(2026, 10, 24, 10),
          departedAt: DateTime(2026, 10, 24, 10, 30),
          durationS: 1800,
          position: const LatLng(40, -74),
        ),
      ],
    );

const List<Place> _places = <Place>[
  Place(
    id: 'p1',
    name: 'Home',
    icon: Icons.home,
    address: '12 Oak Ave',
    position: LatLng(37.78, -122.42),
    radiusMeters: 152.4,
    alertsOn: true,
  ),
  Place(
    id: 'p2',
    name: 'School',
    icon: Icons.school,
    address: '400 Elm St',
    position: LatLng(37.79, -122.43),
    radiusMeters: 304.8,
  ),
  Place(
    id: 'p3',
    name: 'Grandma',
    icon: Icons.favorite_border,
    address: '',
    position: LatLng(37.80, -122.44),
    radiusMeters: 76.2,
    alertsOn: true,
  ),
];

void main() {
  setUpAll(_loadFonts);
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'sos_intro_seen': true,
    });
    UnitPreferenceService.units.value = UnitSystem.imperial;
  });

  for (final double scale in <double>[1, 2]) {
    _golden(
      'm3_sos',
      () => SosScreen(smsConfigured: true, dialer: FakeDialer()),
      scale: scale,
    );
    _golden(
      'm3_alert_status',
      () => AlertStatusScreen(
        alertId: 'a1',
        kind: AlertKind.sos,
        service: FakeAlertService(details: <AlertDetail>[
          detail(<Map<String, dynamic>>[
            row('Alex', 'push', 'acknowledged'),
            row('Bo', 'push', 'failed', err: 'provider_error'),
            row('Cam', 'ws', 'delivered'),
            row('Dee', 'push', 'sent'),
          ]),
        ]),
        dialer: FakeDialer(),
        pollInterval: const Duration(seconds: 100),
      ),
      scale: scale,
    );
    _golden(
      'm3_trips',
      () => TripsScreen(
        member: _sam,
        api: FakeTrips(trips: <Trip>[
          _trip('a', DateTime(2026, 10, 24, 17)),
          _trip('b', DateTime(2026, 10, 23, 9), mode: TripMode.walking),
        ]),
      ),
      scale: scale,
    );
    _golden(
      'm3_report',
      () => DrivingReportScreen(
        member: _sam,
        api: FakeTrips(summaryResult: _summary()),
      ),
      scale: scale,
    );
    _golden(
      'm3_places',
      () => PlacesScreen(
        loader: () async => const PlacesSnapshot(places: _places),
      ),
      scale: scale,
    );
  }
}
