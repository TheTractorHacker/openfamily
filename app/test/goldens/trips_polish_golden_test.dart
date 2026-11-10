import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:openfamily/models/member.dart';
import 'package:openfamily/models/trip.dart';
import 'package:openfamily/screens/trip_detail_screen.dart';
import 'package:openfamily/screens/trips_screen.dart';
import 'package:openfamily/services/e2ee/private_runtime.dart';
import 'package:openfamily/services/processing/primary_lanes.dart';
import 'package:openfamily/services/processing/processing_source.dart';
import 'package:openfamily/services/processing/result_items.dart';
import 'package:openfamily/services/speed_units.dart';
import 'package:openfamily/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../screens/trips_screens_test.dart' show FakeTrips;

/// "UI polish 2" goldens for the trips list and the trip detail header.
///
///   OF_GOLDENS=1 flutter test --update-goldens test/goldens/trips_polish_golden_test.dart
///
/// writes `test/goldens/p2/trips_<scene>_<width>[_x15]_<light|dark>.png`. Skipped without OF_GOLDENS=1.
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
    final FontLoader il = FontLoader('MaterialIcons')..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
    await il.load();
  }
}

Widget _app(Widget home, ThemeData theme, double scale) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme.copyWith(textTheme: theme.textTheme.apply(fontFamily: 'Roboto')),
      builder: (BuildContext c, Widget? child) => MediaQuery(
        data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
        child: DefaultTextStyle.merge(style: const TextStyle(fontFamily: 'Roboto'), child: child!),
      ),
      home: home,
    );

class _V {
  const _V(this.width, this.scale, this.dark, {this.height = 844});
  final double width, scale, height;
  final bool dark;
  String get suffix => '${width.round()}${scale == 1 ? '' : '_x${(scale * 10).round()}'}_${dark ? 'dark' : 'light'}';
}

const List<_V> _variants = <_V>[
  _V(412, 1, true),
  _V(390, 1, true),
  _V(390, 1, false),
  _V(344, 1.5, true, height: 1100),
  _V(344, 1.5, false, height: 1100),
];

class _NoTiles extends TileProvider {
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      MemoryImage(Uint8List.fromList(<int>[0]));
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

const Member _blake = Member(id: 'u1', name: 'Blake Foley', position: null, batteryPercent: 80, status: MemberStatus.normal, address: '');

void _shoot(String name, Widget Function() screen, {bool private = false}) {
  for (final _V v in _variants) {
    testWidgets('trips $name ${v.suffix}', (WidgetTester t) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      UnitPreferenceService.units.value = UnitSystem.imperial;
      PrivateRuntime.primaryPrivate.value = private;
      t.view.physicalSize = Size(v.width * 2, v.height * 2);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      addTearDown(() => PrivateRuntime.primaryPrivate.value = false);
      await t.pumpWidget(_app(screen(), v.dark ? buildDarkTheme() : buildLightTheme(), v.scale));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await t.pump(const Duration(milliseconds: 100));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull, reason: 'overflow in $name ${v.suffix}');
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('p2/trips_${name}_${v.suffix}.png'));
    }, skip: !_on);
  }
}

void main() {
  setUpAll(_loadFonts);

  final DateTime now = DateTime.now();
  final DateTime today = DateTime(now.year, now.month, now.day, 18, 16);
  final List<Trip> trips = <Trip>[
    _trip('t1', today, 37, 45, 33.5, 20.1),
    _trip('t2', today.subtract(const Duration(hours: 2)), 13, 8.7, 21.9, 11.2),
    _trip('t3', today.subtract(const Duration(hours: 5)), 8, 0.16, 4.5, 0.4),
    _trip('t4', today.subtract(const Duration(days: 1)), 82, 2.1, 1.6, 1.2, mode: TripMode.walking),
  ];

  _shoot('lane', () => TripsScreen(member: _blake, api: FakeTrips(trips: trips), lanes: () async => const PrimaryLanes(
      circleId: 'c1',
      names: <String, String>{'u1': 'Blake Foley'},
      members: <MemberProcessing>[MemberProcessing(userId: 'u1', origin: ProcessingOrigin.server)])), private: true);

  _shoot('empty', () => TripsScreen(member: _blake, api: FakeTrips()));

  _shoot(
      'phone',
      () => TripsScreen(
          member: _blake,
          api: FakeTrips(),
          lanes: () async => PrimaryLanes(circleId: 'c1', names: const <String, String>{'u1': 'Blake Foley'}, members: <MemberProcessing>[
                MemberProcessing(userId: 'u1', origin: ProcessingOrigin.phone, updatedAt: DateTime.now().toUtc(), trips: <TripResult>[
                  for (final Trip t in trips.take(3))
                    TripResult(
                        id: t.id,
                        startMs: t.startedAt.millisecondsSinceEpoch,
                        endMs: t.endedAt.millisecondsSinceEpoch,
                        distanceM: t.distanceM,
                        maxSpeedMps: t.maxSpeedMps,
                        avgSpeedMps: t.avgSpeedMps,
                        mode: 'driving',
                        startLat: 10,
                        startLon: 20,
                        endLat: 10.1,
                        endLon: 20.1)
                ])
              ])),
      private: true);

  _shoot('detail', () => TripDetailScreen(trip: trips.first, api: FakeTrips(trips: trips), tileProvider: _NoTiles()));
}
