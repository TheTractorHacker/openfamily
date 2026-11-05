import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:openfamily/models/trip.dart';
import 'package:openfamily/models/trip_report.dart';
import 'package:openfamily/screens/trip_detail_screen.dart';
import 'package:openfamily/services/speed_units.dart';
import 'package:openfamily/services/trips_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'trips_screens_test.dart' show FakeTrips;

class _NoTiles extends TileProvider {
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      MemoryImage(base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
      ));
}

class _Review extends FakeTrips {
  _Review(Trip t, {this.me = 'u1', this.fail = false})
      : super(trips: <Trip>[t]);

  final String? me;
  final bool fail;
  bool passenger = false;
  final List<String> calls = <String>[];

  @override
  Future<String?> currentUserId() async => me;

  @override
  Future<TripDetail> getTrip(String id) async => TripDetail(
        trip: trips.first,
        route: const <TripRoutePoint>[],
        passenger: passenger,
        events: passenger
            ? const <TripEvent>[]
            : <TripEvent>[
                TripEvent(
                  id: 'p1',
                  kind: DrivingEventKind.phoneUse,
                  startedAt: DateTime(2026, 10, 24, 17, 5),
                  endedAt: DateTime(2026, 10, 24, 17, 5, 20),
                  magnitude: 14,
                  maxSpeedMps: 20.1168, // 45 mph
                  confidence: 0.3,
                  activity: 'screen',
                ),
                TripEvent(
                  id: 'p2',
                  kind: DrivingEventKind.phoneUse,
                  startedAt: DateTime(2026, 10, 24, 17, 9),
                  magnitude: 30,
                  maxSpeedMps: 25,
                  confidence: 0.95,
                  activity: 'call',
                ),
              ],
      );

  @override
  Future<void> setPassenger(String tripId, bool p) async {
    if (fail) {
      throw const TripsException(TripsFailure.offline, 'You are offline.');
    }
    calls.add('passenger:$tripId:$p');
    passenger = p;
  }

  @override
  Future<void> setEventDismissed(String eventId, bool d) async {
    if (fail) {
      throw const TripsException(TripsFailure.offline, 'You are offline.');
    }
    calls.add('dismiss:$eventId:$d');
  }
}

Trip _trip() => Trip(
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

Future<void> _pump(WidgetTester t, _Review api) async {
  t.view.physicalSize = const Size(900, 2400);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    home: TripDetailScreen(trip: _trip(), api: api, tileProvider: _NoTiles()),
  ));
  await t.pump();
  await t.pump(const Duration(milliseconds: 80));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    UnitPreferenceService.units.value = UnitSystem.imperial;
  });

  testWidgets('phone use rows show duration, speed in the unit and a hint',
      (WidgetTester t) async {
    await _pump(t, _Review(_trip()));
    expect(find.textContaining('14 s of screen use at up to 45 mph'),
        findsOneWidget);
    expect(find.textContaining('30 s of phone call'), findsOneWidget);
    expect(find.text('Possible false alarm'), findsOneWidget);
    expect(find.textContaining('no apps or content are seen'), findsOneWidget);
  });

  testWidgets('speeds follow the metric preference', (WidgetTester t) async {
    UnitPreferenceService.units.value = UnitSystem.metric;
    await _pump(t, _Review(_trip()));
    expect(find.textContaining('at up to 72 km/h'), findsOneWidget);
  });

  testWidgets('the owner can dismiss a false alarm and bring it back',
      (WidgetTester t) async {
    final _Review api = _Review(_trip());
    await _pump(t, api);
    final Finder dismiss = find.text('Not me / false alarm');
    expect(dismiss, findsNWidgets(2));
    await t.tap(dismiss.first);
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));
    expect(api.calls, <String>['dismiss:p1:true']);
    expect(find.text('False alarm, not counted'), findsOneWidget);
    expect(find.text('Count it again'), findsOneWidget);
    await t.tap(find.text('Count it again'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));
    expect(api.calls.last, 'dismiss:p1:false');
    expect(find.text('False alarm, not counted'), findsNothing);
  });

  testWidgets('I was a passenger marks the drive and can be undone',
      (WidgetTester t) async {
    final _Review api = _Review(_trip());
    await _pump(t, api);
    await t.tap(find.text('I was a passenger'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    await t.pump(const Duration(milliseconds: 100));
    expect(api.calls, <String>['passenger:a:true']);
    expect(find.textContaining('Marked as passenger'), findsOneWidget);
    expect(find.text('Undo passenger'), findsOneWidget);
    expect(find.text('Driving events'), findsNothing);
    await t.tap(find.text('Undo passenger'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    await t.pump(const Duration(milliseconds: 100));
    expect(api.calls.last, 'passenger:a:false');
    expect(find.text('Driving events'), findsOneWidget);
  });

  testWidgets('someone else sees no dismiss or passenger controls',
      (WidgetTester t) async {
    await _pump(t, _Review(_trip(), me: 'someone-else'));
    expect(find.text('Not me / false alarm'), findsNothing);
    expect(find.text('I was a passenger'), findsNothing);
    expect(find.textContaining('14 s of screen use'), findsOneWidget);
  });

  testWidgets('a failed request shows the error and changes nothing',
      (WidgetTester t) async {
    final _Review api = _Review(_trip(), fail: true);
    await _pump(t, api);
    await t.tap(find.text('Not me / false alarm').first);
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));
    expect(find.text('You are offline.'), findsOneWidget);
    expect(find.text('False alarm, not counted'), findsNothing);
  });
}
