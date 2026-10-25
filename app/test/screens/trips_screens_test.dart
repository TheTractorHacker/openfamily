import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openfamily/models/member.dart';
import 'package:openfamily/models/trip.dart';
import 'package:openfamily/screens/driving_report_screen.dart';
import 'package:openfamily/screens/trip_detail_screen.dart';
import 'package:openfamily/screens/trips_screen.dart';
import 'package:openfamily/services/api_client.dart' show ApiException;
import 'package:openfamily/services/speed_units.dart';
import 'package:openfamily/services/trips_service.dart';

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

class FakeTrips implements TripsApi {
  FakeTrips({this.trips = const <Trip>[], this.error, this.summaryResult});

  List<Trip> trips;
  TripsException? error;
  TripSummary? summaryResult;
  final List<double?> thresholds = <double?>[];

  @override
  Future<List<Trip>> listTrips({
    required String userId,
    required DateTime from,
    required DateTime to,
  }) async {
    if (error != null) throw error!;
    return trips;
  }

  @override
  Future<TripDetail> getTrip(String id) async {
    if (error != null) throw error!;
    return TripDetail(trip: trips.first, route: const <TripRoutePoint>[]);
  }

  @override
  Future<TripSummary> summary({
    required String userId,
    required String period,
    DateTime? date,
    double? speedThresholdMps,
  }) async {
    thresholds.add(speedThresholdMps);
    if (error != null) throw error!;
    return summaryResult ?? _summary(0);
  }

  @override
  Future<int> compute({required DateTime from, required DateTime to}) async => 0;

  @override
  Future<String?> currentUserId() async => null;
}

TripSummary _summary(int trips) => TripSummary(
      from: DateTime(2026, 10, 24),
      to: DateTime(2026, 10, 25),
      tripCount: trips,
      totalDistanceM: 16093.44,
      driving: const DrivingStats(
        tripCount: 1,
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

Member get _member => const Member(
      id: 'u1',
      name: 'Sam',
      position: null,
      batteryPercent: 80,
      status: MemberStatus.normal,
      address: '',
    );

Future<void> _pump(WidgetTester tester, Widget w, {double scale = 1}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: w,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

class _NoTiles extends TileProvider {
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      MemoryImage(base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
      ));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    UnitPreferenceService.units.value = UnitSystem.imperial;
  });

  testWidgets('lists trips grouped by day with GPS speed labels', (t) async {
    final FakeTrips api = FakeTrips(trips: <Trip>[
      _trip('a', DateTime(2026, 10, 24, 17)),
      _trip('b', DateTime(2026, 10, 23, 9), mode: TripMode.walking),
    ]);
    t.view.physicalSize = const Size(900, 3200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await _pump(t, TripsScreen(member: _member, api: api), scale: 2);
    expect(find.text('Sam\'s trips'), findsOneWidget);
    expect(find.textContaining('Saturday, October 24'), findsOneWidget);
    expect(find.textContaining('Friday, October 23'), findsOneWidget);
    expect(find.text('Driving'), findsOneWidget);
    expect(find.text('Walking'), findsOneWidget);
    expect(find.text('10 mi'), findsNWidgets(2));
    expect(find.text('Max GPS speed'), findsWidgets);
    expect(find.text('60 mph'), findsWidgets);
    expect(t.takeException(), isNull);
  });

  testWidgets('switching units re-renders in km/h', (t) async {
    final FakeTrips api = FakeTrips(trips: <Trip>[_trip('a', DateTime(2026, 10, 24, 17))]);
    await _pump(t, TripsScreen(member: _member, api: api));
    await t.tap(find.text('mph').first);
    await t.pump();
    expect(find.text('97 km/h'), findsWidgets);
  });

  testWidgets('empty state says no trips yet', (t) async {
    await _pump(t, TripsScreen(member: _member, api: FakeTrips()));
    expect(find.text('No trips yet'), findsOneWidget);
  });

  testWidgets('offline state offers retry', (t) async {
    final FakeTrips api = FakeTrips(
      error: const TripsException(TripsFailure.offline, 'x'),
    );
    await _pump(t, TripsScreen(member: _member, api: api));
    expect(find.text('You are offline'), findsOneWidget);
    api.error = null;
    await t.tap(find.text('Retry'));
    await t.pump();
    await t.pump();
    expect(find.text('No trips yet'), findsOneWidget);
  });

  testWidgets('403 shows a graceful message without retry', (t) async {
    final FakeTrips api = FakeTrips(
      error: mapTripsError(const ApiException(403, 'forbidden')),
    );
    await _pump(t, TripsScreen(member: _member, api: api));
    expect(find.text('Trips are not available'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('trip detail renders stats and handles 404', (t) async {
    final Trip trip = _trip('a', DateTime(2026, 10, 24, 17));
    await _pump(
      t,
      TripDetailScreen(
        trip: trip,
        api: FakeTrips(trips: <Trip>[trip]),
        tileProvider: _NoTiles(),
      ),
    );
    expect(find.text('Driving trip'), findsOneWidget);
    expect(find.text('Avg GPS speed'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    expect(find.byIcon(Icons.flag_rounded), findsOneWidget);
  });

  testWidgets('trip detail handles 404', (t) async {
    final Trip trip = _trip('a', DateTime(2026, 10, 24, 17));
    await _pump(
      t,
      TripDetailScreen(
        trip: trip,
        api: FakeTrips(error: const TripsException(TripsFailure.notFound, 'x')),
        tileProvider: _NoTiles(),
      ),
    );
    expect(find.text('Not found'), findsOneWidget);
  });

  testWidgets('driving report shows stats and sends threshold', (t) async {
    final FakeTrips api = FakeTrips(summaryResult: _summary(3));
    await _pump(t, DrivingReportScreen(member: _member, api: api));
    expect(find.text('Top GPS speed'), findsOneWidget);
    expect(find.text('60 mph'), findsWidgets);
    expect(find.textContaining('2 events'), findsOneWidget);
    expect(find.text('Stops'), findsWidgets);
    expect(find.textContaining('Speed event threshold: 70 mph'), findsOneWidget);
    expect(api.thresholds.first, closeTo(31.3, 0.01));
  });

  testWidgets('driving report empty period', (t) async {
    await _pump(t, DrivingReportScreen(member: _member, api: FakeTrips()));
    expect(find.text('No trips yet'), findsOneWidget);
  });
}
