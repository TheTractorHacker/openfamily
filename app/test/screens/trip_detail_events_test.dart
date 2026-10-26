import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:openfamily/models/trip.dart';
import 'package:openfamily/models/trip_report.dart';
import 'package:openfamily/screens/trip_detail_screen.dart';
import 'package:openfamily/services/speed_units.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'trips_screens_test.dart' show FakeTrips;

class _NoTiles extends TileProvider {
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      MemoryImage(base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
      ));
}

class _WithEvents extends FakeTrips {
  _WithEvents(Trip t) : super(trips: <Trip>[t]);

  @override
  Future<TripDetail> getTrip(String id) async => TripDetail(
        trip: trips.first,
        route: const <TripRoutePoint>[],
        events: <TripEvent>[
          TripEvent(
            id: 'e1',
            kind: DrivingEventKind.hardBrake,
            startedAt: DateTime(2026, 10, 24, 17, 5),
            magnitude: 4.5,
            position: const LatLng(40.05, -74.05),
          ),
          TripEvent(
            id: 'e2',
            kind: DrivingEventKind.speeding,
            startedAt: DateTime(2026, 10, 24, 17, 9),
            magnitude: 37.5,
            position: const LatLng(40.06, -74.06),
          ),
        ],
      );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    UnitPreferenceService.units.value = UnitSystem.imperial;
  });

  testWidgets('trip detail lists events and marks them on the route', (t) async {
    final Trip trip = Trip(
      id: 'a',
      userId: 'u1',
      startedAt: DateTime(2026, 10, 24, 17),
      endedAt: DateTime(2026, 10, 24, 17, 20),
      durationS: 1200,
      distanceM: 16093.44,
      maxSpeedMps: 26.8,
      avgSpeedMps: 13.4,
      mode: TripMode.driving,
      speedSource: 'device_gps',
      start: const LatLng(40.0, -74.0),
      end: const LatLng(40.1, -74.1),
    );
    await t.pumpWidget(
      MaterialApp(
        home: TripDetailScreen(
          trip: trip,
          api: _WithEvents(trip),
          tileProvider: _NoTiles(),
        ),
      ),
    );
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));
    expect(find.text('Driving events'), findsOneWidget);
    expect(find.textContaining('Hard braking'), findsOneWidget);
    expect(find.textContaining('Peak 84 mph'), findsOneWidget);
    expect(find.text('Estimated from GPS'), findsOneWidget);
    expect(find.byIcon(Icons.car_crash_outlined), findsWidgets);
    expect(find.byIcon(Icons.speed_rounded), findsWidgets);
  });
}
