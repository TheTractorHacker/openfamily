import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:openfamily/models/member.dart';
import 'package:openfamily/models/trip.dart';
import 'package:openfamily/models/trip_report.dart';
import 'package:openfamily/screens/member_detail_screen.dart';
import 'package:openfamily/services/history_service.dart';
import 'package:openfamily/services/member_day_service.dart';
import 'package:openfamily/services/speed_units.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _NoTiles extends TileProvider {
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      MemoryImage(base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
      ));
}

final DateTime _now = DateTime(2026, 10, 24, 18);

Member _member({
  MemberStatus status = MemberStatus.normal,
  MovementType movement = MovementType.none,
  PlacePresence? presence,
  DateTime? lastSeen,
  int battery = 80,
}) =>
    Member(
      id: 'u1',
      name: 'Sam',
      position: const LatLng(40, -74),
      status: status,
      batteryPercent: battery,
      address: '',
      movement: movement,
      speedMph: movement == MovementType.car ? 42 : null,
      placePresence: presence,
      lastSeen: lastSeen,
    );

Trip _trip() => Trip(
      id: 'a',
      userId: 'u1',
      startedAt: DateTime(2026, 10, 24, 8),
      endedAt: DateTime(2026, 10, 24, 8, 30),
      durationS: 1800,
      distanceM: 16093.44,
      maxSpeedMps: 26.8,
      avgSpeedMps: 13.4,
      mode: TripMode.driving,
      speedSource: 'device_gps',
      start: const LatLng(40.0, -74.0),
      end: const LatLng(40.1, -74.1),
    );

DayTrip _dayTrip() => DayTrip(
      trip: _trip(),
      detailLoaded: true,
      route: const <TripRoutePoint>[],
      events: <TripEvent>[
        TripEvent(
            id: '1', kind: DrivingEventKind.hardBrake, startedAt: _now),
        TripEvent(
            id: '2', kind: DrivingEventKind.hardBrake, startedAt: _now),
        TripEvent(id: '3', kind: DrivingEventKind.speeding, startedAt: _now),
      ],
    );

Future<void> _pump(
  WidgetTester t,
  Member m,
  MemberDayLoader loader, {
  double scale = 1,
  Brightness brightness = Brightness.light,
}) async {
  t.view.physicalSize = const Size(900, 2400);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: ThemeData(
        brightness: brightness, splashFactory: NoSplash.splashFactory),
    builder: (BuildContext c, Widget? w) => MediaQuery(
      data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
      child: w!,
    ),
    home: MemberDetailScreen(
      member: m,
      loader: loader,
      now: _now,
      tileProvider: _NoTiles(),
      requestUpdate: (_) async {},
    ),
  ));
  await t.pump();
  await t.pump(const Duration(milliseconds: 50));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    UnitPreferenceService.units.value = UnitSystem.imperial;
  });

  group('memberDetailStatus', () {
    test('driving shows speed', () {
      expect(
          memberDetailStatus(_member(movement: MovementType.car), now: _now),
          'Driving · 42 mph');
    });
    test('at place since', () {
      final String s = memberDetailStatus(
        _member(
            presence: PlacePresence(
                placeId: 'p',
                placeName: 'Home',
                isAt: true,
                since: DateTime(2026, 10, 24, 15, 10))),
        now: _now,
      );
      expect(s, 'At Home since 3:10 PM');
    });
    test('stopped shows last seen', () {
      expect(
          memberDetailStatus(
              _member(
                  status: MemberStatus.stopped,
                  lastSeen: _now.subtract(const Duration(hours: 2))),
              now: _now),
          'Last seen 2h ago');
    });
  });

  test('nameTripEndpoints picks nearby place visits', () {
    final List<DayTrip> named = nameTripEndpoints(<DayTrip>[
      DayTrip(trip: _trip())
    ], <HistoryVisit>[
      HistoryVisit(
          arrivedAt: DateTime(2026, 10, 24, 1),
          departedAt: DateTime(2026, 10, 24, 8, 2),
          position: const LatLng(40, -74),
          placeName: 'Home',
          kind: 'place'),
      HistoryVisit(
          arrivedAt: DateTime(2026, 10, 24, 8, 28),
          departedAt: DateTime(2026, 10, 24, 12),
          position: const LatLng(40.1, -74.1),
          placeName: 'Work',
          kind: 'place'),
    ]);
    expect(named.single.fromName, 'Home');
    expect(named.single.toName, 'Work');
  });

  testWidgets('renders header, trip card with chips and thumbnail',
      (WidgetTester t) async {
    await _pump(
        t,
        _member(movement: MovementType.car, battery: 15),
        (_, __) async => MemberDay(
            trips: nameTripEndpoints(<DayTrip>[_dayTrip()], <HistoryVisit>[])));
    expect(find.text('Sam'), findsWidgets);
    expect(find.text('Driving · 42 mph'), findsOneWidget);
    expect(find.text('Battery 15%'), findsOneWidget);
    expect(find.text('Today'.toUpperCase()), findsOneWidget);
    expect(find.text('Hard braking ×2'), findsOneWidget);
    expect(find.text('Speeding'), findsOneWidget);
    expect(find.text('10 mi'), findsOneWidget);
    expect(find.text('60 mph'), findsOneWidget);
    expect(find.byType(FlutterMap), findsOneWidget);
    expect(find.text('Daily history'), findsOneWidget);
    expect(find.text('History'), findsOneWidget);
  });

  testWidgets('empty state', (WidgetTester t) async {
    await _pump(t, _member(), (_, __) async => const MemberDay());
    expect(find.text('No trips today'), findsOneWidget);
  });

  testWidgets('loading state', (WidgetTester t) async {
    t.view.physicalSize = const Size(900, 2400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      home: MemberDetailScreen(
        member: _member(),
        loader: (_, __) => Future<MemberDay>.delayed(
            const Duration(seconds: 1), () => const MemberDay()),
        now: _now,
      ),
    ));
    await t.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await t.pump(const Duration(seconds: 2));
  });

  testWidgets('error state retries', (WidgetTester t) async {
    int calls = 0;
    await _pump(t, _member(), (_, __) async {
      calls++;
      if (calls == 1) throw Exception('boom');
      return const MemberDay();
    });
    expect(find.text('Couldn\'t load today'), findsOneWidget);
    await t.tap(find.text('Try again'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));
    expect(find.text('No trips today'), findsOneWidget);
  });

  for (final Brightness b in Brightness.values) {
    testWidgets('large text ${b.name} has no overflow',
        (WidgetTester t) async {
      await _pump(t, _member(movement: MovementType.car),
          (_, __) async => MemberDay(trips: <DayTrip>[_dayTrip()]),
          scale: 2, brightness: b);
      expect(t.takeException(), isNull);
    });
  }
}
