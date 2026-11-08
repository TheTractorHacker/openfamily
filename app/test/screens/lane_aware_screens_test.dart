import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:openfamily/models/member.dart';
import 'package:openfamily/models/trip.dart';
import 'package:openfamily/screens/driving_report_screen.dart';
import 'package:openfamily/screens/family_driving_report_screen.dart';
import 'package:openfamily/models/trip_report.dart';
import 'package:openfamily/services/trip_report_service.dart';
import 'package:openfamily/screens/trips_screen.dart';
import 'package:openfamily/screens/weekly_summary_screen.dart';
import 'package:openfamily/services/e2ee/private_runtime.dart';
import 'package:openfamily/services/processing/primary_lanes.dart';
import 'package:openfamily/services/processing/processing_source.dart';
import 'package:openfamily/services/processing/result_items.dart';
import 'package:openfamily/services/speed_units.dart';
import 'package:openfamily/services/trips_service.dart';
import 'package:openfamily/services/weekly_summary_service.dart';
import 'package:openfamily/widgets/trip_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Screens that mix sources in a Private circle: server-assisted members from the
// server, phone-only members from the results their phones shared, and an
// explicit placeholder otherwise. Nothing is silently dropped.

class _Weekly implements WeeklySummaryApi {
  _Weekly(this.result);
  Object result;
  int calls = 0;
  @override
  Future<WeeklySummary> load() async {
    calls++;
    final Object r = result;
    if (r is WeeklySummary) return r;
    throw r;
  }
}

WeeklySummary _serverSummary() => WeeklySummary.fromJson(<String, dynamic>{
      'members': <Map<String, dynamic>>[
        <String, dynamic>{
          'user_id': 'u2',
          'name': 'Sam',
          'current': <String, dynamic>{'drives': 2, 'distance_m': 160934.4, 'duration_s': 5400, 'top_speed_mps': 30, 'safety_score': 88},
          'previous': <String, dynamic>{'drives': 1, 'distance_m': 80467.2, 'duration_s': 1800, 'top_speed_mps': 25},
        },
      ],
    });

WeekFigures _fig(int n, double d) =>
    WeekFigures(drives: n, distanceM: d, durationS: 600, topSpeedMps: 20, speeding: 0, hardBrake: 1, rapidAccel: 0, phoneUse: 0, score: 90);

PrimaryLanes _lanes({bool alexShared = true}) => PrimaryLanes(
      circleId: 'c1',
      names: const <String, String>{'u1': 'Blake', 'u2': 'Sam', 'u3': 'Alex'},
      members: <MemberProcessing>[
        const MemberProcessing(userId: 'u2', origin: ProcessingOrigin.server),
        if (alexShared)
          MemberProcessing(
            userId: 'u3',
            origin: ProcessingOrigin.phone,
            weeks: <WeekResult>[WeekResult(weekStartMs: 1760000000000, current: _fig(3, 40233.6), previous: _fig(1, 16093.44))],
            updatedAt: DateTime.now().toUtc().subtract(const Duration(hours: 2)),
          )
        else
          const MemberProcessing(userId: 'u3', origin: ProcessingOrigin.phone, placeholder: PlaceholderReason.notSharedYet),
      ],
    );

Widget _wrap(Widget child) => MaterialApp(home: child);

void _big(WidgetTester t) {
  t.view.physicalSize = const Size(600, 2400);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
}

class _FakeTrips implements TripsApi {
  int listCalls = 0;
  @override
  Future<String?> currentUserId() async => 'me';
  @override
  Future<List<Trip>> listTrips({required String userId, required DateTime from, required DateTime to}) async {
    listCalls++;
    return <Trip>[
      Trip(
        id: 't1',
        userId: userId,
        startedAt: DateTime.now().subtract(const Duration(hours: 3)),
        endedAt: DateTime.now().subtract(const Duration(hours: 2)),
        durationS: 3600,
        distanceM: 16093.44,
        maxSpeedMps: 20,
        avgSpeedMps: 10,
        mode: TripMode.driving,
        speedSource: 'device_gps',
        start: const LatLng(1, 1),
        end: const LatLng(2, 2),
      ),
    ];
  }

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}

Member _member(String id, String name) => Member(
      id: id,
      name: name,
      position: null,
      status: MemberStatus.normal,
      batteryPercent: 50,
      address: '',
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    UnitPreferenceService.units.value = UnitSystem.metric;
    PrivateRuntime.primaryPrivate.value = true;
  });
  tearDown(() => PrivateRuntime.primaryPrivate.value = false);

  group('weekly summary in a Private circle', () {
    testWidgets('server-assisted member from the server, phone-only member from their phone, each with its badge', (t) async {
      _big(t);
      final _Weekly api = _Weekly(_serverSummary());
      await t.pumpWidget(_wrap(WeeklySummaryScreen(api: api, selfId: 'u1', lanes: () async => _lanes())));
      await t.pumpAndSettle();
      expect(api.calls, 1);
      expect(find.text('Sam'), findsOneWidget);
      expect(find.text('100 mi, 2 drives'), findsOneWidget);
      expect(find.text('Alex'), findsOneWidget);
      expect(find.text('25 mi, 3 drives'), findsOneWidget);
      expect(find.text('Processed by server'), findsOneWidget);
      expect(find.text('Phone only'), findsOneWidget);
      expect(find.byKey(const Key('computed-on-phone')), findsOneWidget);
      expect(find.textContaining('Computed on Alex\'s phone. Updated 2 h ago.'), findsOneWidget);
    });

    testWidgets('a phone-only member who has not shared yet gets the "Waiting for" placeholder, not an empty hole', (t) async {
      _big(t);
      await t.pumpWidget(_wrap(WeeklySummaryScreen(api: _Weekly(_serverSummary()), lanes: () async => _lanes(alexShared: false))));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('waiting-phone-Alex')), findsOneWidget);
      expect(find.textContaining('Waiting for Alex\'s phone'), findsWidgets);
      expect(find.text('Sam'), findsOneWidget);
    });

    testWidgets('only phone-only members: the server is never asked', (t) async {
      _big(t);
      final _Weekly api = _Weekly(StateError('must not be called'));
      final PrimaryLanes l = PrimaryLanes(circleId: 'c1', names: const <String, String>{'u3': 'Alex'}, members: <MemberProcessing>[_lanes().members[1]]);
      await t.pumpWidget(_wrap(WeeklySummaryScreen(api: api, lanes: () async => l)));
      await t.pumpAndSettle();
      expect(api.calls, 0);
      expect(find.text('Alex'), findsOneWidget);
    });

    testWidgets('server unreachable: the server-assisted member says so, the phone-only member still shows', (t) async {
      _big(t);
      await t.pumpWidget(_wrap(WeeklySummaryScreen(api: _Weekly(const TripsException(TripsFailure.offline, 'offline')), lanes: () async => _lanes())));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('weekly-server-missing-u2')), findsOneWidget);
      expect(find.textContaining('could not be reached'), findsOneWidget);
      expect(find.text('Alex'), findsOneWidget);
    });

    testWidgets('no lanes (feature not available): the old "not available in Private circles" explanation', (t) async {
      _big(t);
      await t.pumpWidget(_wrap(WeeklySummaryScreen(api: _Weekly(_serverSummary()), lanes: () async => null)));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('not-available-title')), findsOneWidget);
    });

    testWidgets('a normal circle is unchanged (no badges)', (t) async {
      _big(t);
      PrivateRuntime.primaryPrivate.value = false;
      await t.pumpWidget(_wrap(WeeklySummaryScreen(api: _Weekly(_serverSummary()), lanes: () async => _lanes())));
      await t.pumpAndSettle();
      expect(find.text('Processed by server'), findsNothing);
      expect(find.text('Sam'), findsOneWidget);
    });
  });

  group('trips in a Private circle', () {
    TripResult tr(int hoursAgo) {
      final int s = DateTime.now().subtract(Duration(hours: hoursAgo)).millisecondsSinceEpoch;
      return TripResult(
          id: 'p$hoursAgo', startMs: s, endMs: s + 1200000, distanceM: 8000, maxSpeedMps: 20, avgSpeedMps: 10, mode: 'driving',
          startLat: 10, startLon: 20, endLat: 10.1, endLon: 20.1);
    }

    testWidgets('phone-only member: trips from their phone with the badge and note; the server is not asked', (t) async {
      _big(t);
      final _FakeTrips api = _FakeTrips();
      final PrimaryLanes l = PrimaryLanes(circleId: 'c1', names: const <String, String>{'u3': 'Alex'}, members: <MemberProcessing>[
        MemberProcessing(userId: 'u3', origin: ProcessingOrigin.phone, trips: <TripResult>[tr(2), tr(5)], updatedAt: DateTime.now().toUtc())
      ]);
      await t.pumpWidget(_wrap(TripsScreen(member: _member('u3', 'Alex'), api: api, lanes: () async => l)));
      await t.pumpAndSettle();
      expect(api.listCalls, 0);
      expect(find.byKey(const Key('trips-phone-only')), findsOneWidget);
      expect(find.text('Phone only'), findsOneWidget);
      expect(find.textContaining('Computed on Alex\'s phone'), findsOneWidget);
      expect(find.byType(TripCard), findsNWidgets(2));
    });

    testWidgets('phone-only member who has not shared: placeholder', (t) async {
      _big(t);
      const PrimaryLanes l = PrimaryLanes(circleId: 'c1', names: <String, String>{'u3': 'Alex'}, members: <MemberProcessing>[
        MemberProcessing(userId: 'u3', origin: ProcessingOrigin.phone, placeholder: PlaceholderReason.notSharedYet)
      ]);
      await t.pumpWidget(_wrap(TripsScreen(member: _member('u3', 'Alex'), api: _FakeTrips(), lanes: () async => l)));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('waiting-phone-Alex')), findsOneWidget);
      expect(find.byType(TripCard), findsNothing);
    });

    testWidgets('server-assisted member: the usual server trips, badged', (t) async {
      _big(t);
      final _FakeTrips api = _FakeTrips();
      const PrimaryLanes l = PrimaryLanes(circleId: 'c1', names: <String, String>{'u2': 'Sam'}, members: <MemberProcessing>[
        MemberProcessing(userId: 'u2', origin: ProcessingOrigin.server)
      ]);
      await t.pumpWidget(_wrap(TripsScreen(member: _member('u2', 'Sam'), api: api, lanes: () async => l)));
      await t.pumpAndSettle();
      expect(api.listCalls, 1);
      expect(find.byType(TripCard), findsOneWidget);
      expect(find.text('Processed by server'), findsOneWidget);
    });

    testWidgets('lanes unreadable: a retry state, never "not available in Private circles"', (t) async {
      _big(t);
      await t.pumpWidget(_wrap(TripsScreen(member: _member('u9', 'Zed'), api: _FakeTrips(), lanes: () async => null)));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('lanes-unavailable-title')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('not-available-title')), findsNothing);
      expect(find.text('Try again'), findsOneWidget);
    });
  });

  group('driving reports in a Private circle', () {
    final DateTime now = DateTime(2026, 11, 4, 12); // a Wednesday
    int ms(DateTime d) => d.millisecondsSinceEpoch;
    TripResult trip(String id, DateTime at) => TripResult(
        id: id, startMs: ms(at), endMs: ms(at) + 1200000, distanceM: 16093.44, maxSpeedMps: 25, avgSpeedMps: 12, mode: 'driving',
        startLat: 10, startLon: 20, endLat: 10.1, endLon: 20.1);
    DriveResult drive(String id, {int speeding = 1, int brake = 2, int phone = 0}) =>
        DriveResult(tripId: id, events: const <DriveEventResult>[], speeding: speeding, hardBrake: brake, rapidAccel: 0, phoneUse: phone);

    MemberProcessing alex({bool detection = false}) => MemberProcessing(
          userId: 'u3',
          origin: ProcessingOrigin.phone,
          trips: <TripResult>[trip('a', DateTime(2026, 11, 3, 9)), trip('b', DateTime(2026, 11, 4, 8)), trip('old', DateTime(2026, 9, 1, 8))],
          drives: <DriveResult>[drive('a'), drive('b'), drive('old', brake: 50)],
          weeks: detection ? <WeekResult>[WeekResult(weekStartMs: ms(DateTime(2026, 11, 2)), current: const WeekFigures(drives: 2, distanceM: 1, durationS: 1, topSpeedMps: 1, speeding: 0, hardBrake: 0, rapidAccel: 0, phoneUse: 0), previous: _fig(0, 0))] : const <WeekResult>[],
          updatedAt: now,
        );

    testWidgets('member screen, phone-only: week figures from the sealed results, badge, note and what is missing', (t) async {
      _big(t);
      final PrimaryLanes l = PrimaryLanes(circleId: 'c1', names: const <String, String>{'u3': 'Alex'}, members: <MemberProcessing>[alex()]);
      await t.pumpWidget(_wrap(DrivingReportScreen(member: _member('u3', 'Alex'), api: _FakeTrips(), lanes: () async => l, clock: () => now)));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('driving-phone-only')), findsOneWidget);
      await t.tap(find.text('Week'));
      await t.pumpAndSettle();
      expect(find.text('Phone only'), findsWidgets);
      expect(find.textContaining('2 drives'), findsOneWidget, reason: 'only this week; the September trip is outside');
      expect(find.text('Hard braking 4'), findsOneWidget);
      expect(find.text('Speeding 2'), findsOneWidget);
      expect(find.textContaining('Phone use'), findsNothing, reason: 'detection off: no count is claimed');
      expect(find.byKey(const Key('computed-on-phone')), findsOneWidget);
      expect(find.byKey(const Key('phone-driving-limits')), findsOneWidget);
    });

    testWidgets('a zero phone-use count is shown when the member has detection on', (t) async {
      _big(t);
      final PrimaryLanes l = PrimaryLanes(circleId: 'c1', names: const <String, String>{'u3': 'Alex'}, members: <MemberProcessing>[alex(detection: true)]);
      await t.pumpWidget(_wrap(DrivingReportScreen(member: _member('u3', 'Alex'), api: _FakeTrips(), lanes: () async => l, clock: () => now)));
      await t.pumpAndSettle();
      await t.tap(find.text('Week'));
      await t.pumpAndSettle();
      expect(find.text('Phone use 0'), findsOneWidget);
    });

    testWidgets('member screen, phone not shared yet: placeholder; unknown member: honest not available', (t) async {
      _big(t);
      const PrimaryLanes l = PrimaryLanes(circleId: 'c1', names: <String, String>{'u3': 'Alex'}, members: <MemberProcessing>[
        MemberProcessing(userId: 'u3', origin: ProcessingOrigin.phone, placeholder: PlaceholderReason.notSharedYet)
      ]);
      await t.pumpWidget(_wrap(DrivingReportScreen(member: _member('u3', 'Alex'), api: _FakeTrips(), lanes: () async => l, clock: () => now)));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('waiting-phone-Alex')), findsOneWidget);
      await t.pumpWidget(_wrap(DrivingReportScreen(key: const Key('zed'), member: _member('u9', 'Zed'), api: _FakeTrips(), lanes: () async => null)));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('lanes-unavailable-title')), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('not-available-title')), findsNothing);
    });

    testWidgets('family screen: phone-only member from their phone, server member from the server report, both badged', (t) async {
      _big(t);
      final PrimaryLanes l = PrimaryLanes(circleId: 'c1', names: const <String, String>{'u2': 'Sam', 'u3': 'Alex'}, members: <MemberProcessing>[
        const MemberProcessing(userId: 'u2', origin: ProcessingOrigin.server),
        alex(),
      ]);
      final _FakeReport api = _FakeReport();
      await t.pumpWidget(_wrap(FamilyDrivingReportScreen(
        members: ValueNotifier<List<Member>>(<Member>[]),
        userId: ValueNotifier<String?>('u1'),
        api: api,
        clock: () => now,
        detectionLoader: () async => true,
        lanes: () async => l,
      )));
      await t.pumpAndSettle();
      expect(api.calls, 1);
      expect(find.text('Weekly Driving Report'), findsOneWidget);
      expect(find.text('Processed by server'), findsOneWidget);
      expect(find.byKey(const Key('phone-driving-Alex')), findsOneWidget);
      expect(find.byKey(const Key('driving-private-note')), findsOneWidget);
    });

    testWidgets('family screen with only phone-only members never asks the server', (t) async {
      _big(t);
      final PrimaryLanes l = PrimaryLanes(circleId: 'c1', names: const <String, String>{'u3': 'Alex'}, members: <MemberProcessing>[alex()]);
      final _FakeReport api = _FakeReport();
      await t.pumpWidget(_wrap(FamilyDrivingReportScreen(
        members: ValueNotifier<List<Member>>(<Member>[]),
        userId: ValueNotifier<String?>('u1'),
        api: api,
        clock: () => now,
        detectionLoader: () async => true,
        lanes: () async => l,
      )));
      await t.pumpAndSettle();
      expect(api.calls, 0);
      expect(find.byKey(const Key('phone-driving-Alex')), findsOneWidget);
    });
  });

  group('WeekFigures phone use', () {
    test('null means detection off, zero is a real zero, both survive the wire', () {
      const WeekFigures off = WeekFigures(drives: 1, distanceM: 1, durationS: 1, topSpeedMps: 1, speeding: 0, hardBrake: 0, rapidAccel: 0);
      const WeekFigures zero = WeekFigures(drives: 1, distanceM: 1, durationS: 1, topSpeedMps: 1, speeding: 0, hardBrake: 0, rapidAccel: 0, phoneUse: 0);
      const WeekFigures three = WeekFigures(drives: 1, distanceM: 1, durationS: 1, topSpeedMps: 1, speeding: 0, hardBrake: 0, rapidAccel: 0, phoneUse: 3);
      expect(WeekFigures.tryParse(off.toJson())!.phoneUse, isNull);
      expect(WeekFigures.tryParse(zero.toJson())!.phoneUse, 0);
      expect(WeekFigures.tryParse(three.toJson())!.phoneUse, 3);
      final Map<String, dynamic> bad = off.toJson()..['ev'] = <int>[0, 0, 0, -2];
      expect(WeekFigures.tryParse(bad), isNull);
    });
  });

  group('driving tab never dead-ends in a Private circle', () {
    FamilyDrivingReportScreen screen(PrimaryLanesLoader loader, _FakeReport api) => FamilyDrivingReportScreen(
          members: ValueNotifier<List<Member>>(<Member>[]),
          userId: ValueNotifier<String?>('u1'),
          api: api,
          clock: () => DateTime(2026, 11, 4, 12),
          detectionLoader: () async => true,
          lanes: loader,
        );

    testWidgets('lanes could not be read: a retry state, not the old "not available" text', (t) async {
      _big(t);
      await t.pumpWidget(_wrap(screen(() async => null, _FakeReport())));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('driving-lanes-failed')), findsOneWidget);
      expect(find.textContaining('not available in Private'), findsNothing);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('my own phone-only card offers "Use the server" and the on-phone option', (t) async {
      _big(t);
      final PrimaryLanes l = PrimaryLanes(circleId: 'c1', names: const <String, String>{'u1': 'Blake'}, members: const <MemberProcessing>[
        MemberProcessing(userId: 'u1', origin: ProcessingOrigin.phone, placeholder: PlaceholderReason.notSharedYet),
      ]);
      await t.pumpWidget(_wrap(screen(() async => l, _FakeReport())));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('use-the-server')), findsOneWidget);
      expect(find.text('Compute reports on this phone (uses battery)'), findsOneWidget);
    });

    testWidgets('someone else\'s phone-only card has no buttons', (t) async {
      _big(t);
      final PrimaryLanes l = PrimaryLanes(circleId: 'c1', names: const <String, String>{'u3': 'Alex'}, members: const <MemberProcessing>[
        MemberProcessing(userId: 'u3', origin: ProcessingOrigin.phone, placeholder: PlaceholderReason.notSharedYet),
      ]);
      await t.pumpWidget(_wrap(screen(() async => l, _FakeReport())));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('use-the-server')), findsNothing);
    });
  });

}

class _FakeReport implements TripReportApi {
  int calls = 0;
  @override
  Future<TripReport> report({required DateTime start, String period = 'week', String? circleId}) async {
    calls++;
    return TripReport.fromJson(<String, dynamic>{
      'period': period,
      'start': '2026-11-02',
      'end': '2026-11-08',
      'prev_start': '2026-10-26',
      'prev_end': '2026-11-01',
      'totals': <String, dynamic>{'drives': 2, 'distance_m': 5000.0, 'top_speed_mps': 20.0, 'top_speed_user_id': 'u2'},
      'members': <Map<String, dynamic>>[
        <String, dynamic>{'user_id': 'u2', 'name': 'Sam', 'drives': 2, 'distance_m': 5000.0, 'duration_s': 600.0, 'top_speed_mps': 20.0},
      ],
    });
  }

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName}');
}
