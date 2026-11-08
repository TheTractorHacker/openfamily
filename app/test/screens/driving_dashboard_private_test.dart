import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/member.dart';
import 'package:openfamily/models/trip_report.dart';
import 'package:openfamily/screens/family_driving_report_screen.dart';
import 'package:openfamily/services/api_client.dart' show ApiException;
import 'package:openfamily/services/e2ee/private_runtime.dart';
import 'package:openfamily/services/offline/offline_cache.dart' show Cached;
import 'package:openfamily/services/processing/phone_report_merge.dart';
import 'package:openfamily/services/processing/primary_lanes.dart';
import 'package:openfamily/services/processing/processing_source.dart';
import 'package:openfamily/services/processing/result_items.dart';
import 'package:openfamily/services/speed_units.dart';
import 'package:openfamily/services/trip_report_service.dart';
import 'package:openfamily/widgets/driving_page_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Regression: the Driving tab in a Private circle (owner report v0.25: "the
// driving features are gone"). Members whose lane is "server" and members who
// keep their data on their phone must appear in ONE dashboard with the header
// cards, event chips, day chart and drive list, never a bare list or a
// "not available" screen.

final DateTime _now = DateTime(2026, 11, 4, 12); // Wednesday; the week starts Mon 2 Nov

Map<String, dynamic> _serverReport() => <String, dynamic>{
      'period': 'week',
      'start': '2026-11-02',
      'end': '2026-11-08',
      'prev_start': '2026-10-26',
      'prev_end': '2026-11-01',
      'totals': <String, dynamic>{
        'drives': 2,
        'distance_m': 40000,
        'top_speed_mps': 30.0,
        'top_speed_user_id': 'u1',
        'events': <String, dynamic>{'speeding': 1, 'hard_brake': 2, 'rapid_accel': 0, 'phone_use': null},
      },
      'previous_totals': <String, dynamic>{
        'drives': 1, 'distance_m': 10000, 'top_speed_mps': 25.0, 'top_speed_user_id': 'u1',
        'events': <String, dynamic>{'speeding': 0, 'hard_brake': 1, 'rapid_accel': 0, 'phone_use': null},
      },
      'members': <Map<String, dynamic>>[
        <String, dynamic>{
          'user_id': 'u1', 'name': 'Blake', 'drives': 2, 'distance_m': 40000, 'top_speed_mps': 30.0,
          'events': <String, dynamic>{'speeding': 1, 'hard_brake': 2, 'rapid_accel': 0, 'phone_use': null},
          'previous_events': <String, dynamic>{'speeding': 0, 'hard_brake': 1, 'rapid_accel': 0, 'phone_use': null},
        },
        // The server also lists the viewer's phone-lane partner with nothing: it must not show twice.
        <String, dynamic>{'user_id': 'u3', 'name': 'Kinsley', 'drives': 0, 'distance_m': 0, 'events': <String, dynamic>{}},
      ],
      'days': <Map<String, dynamic>>[
        for (int i = 0; i < 7; i++)
          <String, dynamic>{'date': '2026-11-0${2 + i}',
            'drives': i == 1 ? 2 : 0, 'distance_m': i == 1 ? 40000.0 : 0.0, 'top_speed_mps': i == 1 ? 30.0 : 0.0},
      ],
      'recent_trips': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'srv-1', 'user_id': 'u1', 'name': 'Blake', 'started_at': '2026-11-03T08:00:00', 'ended_at': '2026-11-03T08:30:00',
          'distance_m': 20000, 'duration_s': 1800, 'max_speed_mps': 30.0, 'mode': 'driving',
          'event_counts': <String, dynamic>{'speeding': 1, 'hard_brake': 1, 'rapid_accel': 0, 'phone_use': null},
        },
      ],
      'thresholds': <String, dynamic>{'speeding_mps': 35.76, 'speeding_seconds': 30, 'hard_brake_mps2': 3.5, 'rapid_accel_mps2': 3.5},
      'estimated': true,
    };

TripResult _trip(String id, DateTime at, {double dist = 12000, double top = 24}) => TripResult(
    id: id, startMs: at.millisecondsSinceEpoch, endMs: at.add(const Duration(minutes: 20)).millisecondsSinceEpoch,
    distanceM: dist, maxSpeedMps: top, avgSpeedMps: 12, mode: 'driving', startLat: 1, startLon: 2, endLat: 1.1, endLon: 2.1);

MemberProcessing _kinsley({bool shared = true}) => shared
    ? MemberProcessing(
        userId: 'u3',
        origin: ProcessingOrigin.phone,
        trips: <TripResult>[_trip('pa', DateTime(2026, 11, 3, 17), dist: 12000, top: 28)],
        drives: const <DriveResult>[DriveResult(tripId: 'pa', events: <DriveEventResult>[], speeding: 0, hardBrake: 3, rapidAccel: 1, phoneUse: 0)],
        updatedAt: DateTime(2026, 11, 4, 9).toUtc(),
      )
    : const MemberProcessing(userId: 'u3', origin: ProcessingOrigin.phone, placeholder: PlaceholderReason.notSharedYet);

PrimaryLanes _lanes({bool kinsleyShared = true, bool blakeServer = true}) => PrimaryLanes(
      circleId: 'c1',
      names: const <String, String>{'u1': 'Blake', 'u3': 'Kinsley'},
      members: <MemberProcessing>[
        if (blakeServer)
          const MemberProcessing(userId: 'u1', origin: ProcessingOrigin.server)
        else
          const MemberProcessing(userId: 'u1', origin: ProcessingOrigin.phone, placeholder: PlaceholderReason.notSharedYet),
        _kinsley(shared: kinsleyShared),
      ],
    );

class _Api implements TripReportApi, CachedTripReportApi {
  _Api({this.fromCache, this.error});
  final DateTime? fromCache;
  final Object? error;
  int calls = 0;
  @override
  Future<TripReport> report({required DateTime start, String period = 'week', String? circleId}) async =>
      (await reportCached(start: start, period: period, circleId: circleId)).value;
  @override
  Future<Cached<TripReport>> reportCached({required DateTime start, String period = 'week', String? circleId}) async {
    calls++;
    if (error != null) throw error!;
    return Cached<TripReport>(TripReport.fromJson(_serverReport()), fromCache: fromCache != null, savedAt: fromCache);
  }
  @override
  Future<List<TripEvent>> tripEvents(String tripId) async => const <TripEvent>[];
}

Widget _screen(Future<PrimaryLanes?> Function() lanes, TripReportApi api) => MaterialApp(
      home: FamilyDrivingReportScreen(
        members: ValueNotifier<List<Member>>(<Member>[]),
        userId: ValueNotifier<String?>('u1'),
        api: api,
        clock: () => _now,
        detectionLoader: () async => true,
        lanes: lanes,
      ),
    );

void _big(WidgetTester t) {
  t.view.physicalSize = const Size(780, 9000);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    UnitPreferenceService.units.value = UnitSystem.imperial;
    PrivateRuntime.primaryPrivate.value = true;
  });
  tearDown(() => PrivateRuntime.primaryPrivate.value = false);

  testWidgets('server-lane member and phone member: one full dashboard, nothing "not available"', (t) async {
    _big(t);
    final _Api api = _Api();
    await t.pumpWidget(_screen(() async => _lanes(), api));
    await t.pumpAndSettle();
    expect(find.textContaining('not available in Private'), findsNothing);
    expect(find.byKey(const Key('driving-lanes-failed')), findsNothing);
    expect(api.calls, 1);
    expect(find.text('Weekly Driving Report'), findsOneWidget);
    // Header cards count both people: 2 server drives + 1 phone drive.
    expect(find.text('3'), findsWidgets, reason: 'total drives on the summary card');
    // Event chips include the phone member's braking (2 from the server + 3 on the phone).
    expect(find.textContaining('5'), findsWidgets);
    // Both cards, each badged with where it was worked out.
    expect(find.text('Processed by server'), findsOneWidget);
    expect(find.byKey(const Key('phone-driving-Kinsley')), findsOneWidget);
    // Day chart and the drive list include the phone trip and the server trip.
    expect(find.byType(DrivingDaysChart), findsOneWidget);
    expect(find.text('Recent drives'), findsOneWidget);
    expect(find.byType(RecentDriveTile), findsNWidgets(2));
    expect(find.byKey(const Key('driving-private-note')), findsOneWidget);
    // The phone member is listed once, not also as an empty server row.
    expect(find.text('Kinsley'), findsWidgets);
    expect(find.byKey(const Key('waiting-phone-Kinsley')), findsNothing);
  });

  testWidgets('opening a phone-made drive explains where its map is instead of failing', (t) async {
    _big(t);
    await t.pumpWidget(_screen(() async => _lanes(), _Api()));
    await t.pumpAndSettle();
    final Finder tiles = find.byType(RecentDriveTile);
    // Newest first: Kinsley's Tuesday 17:00 drive is after Blake's 08:00 one.
    await t.ensureVisible(tiles.first);
    await t.tap(tiles.first);
    await t.pump();
    expect(find.textContaining('worked out on their own phone'), findsOneWidget);
  });

  testWidgets('the circle turning Private after the tab opened loads the lanes (no dead end)', (t) async {
    _big(t);
    PrivateRuntime.primaryPrivate.value = false;
    final _Api api = _Api();
    int laneLoads = 0;
    await t.pumpWidget(_screen(() async {
      laneLoads++;
      return _lanes();
    }, api));
    await t.pumpAndSettle();
    expect(laneLoads, 0);
    PrivateRuntime.primaryPrivate.value = true;
    await t.pumpAndSettle();
    expect(laneLoads, 1);
    expect(find.byKey(const Key('driving-lanes-failed')), findsNothing);
    expect(find.byKey(const Key('phone-driving-Kinsley')), findsOneWidget);
  });

  testWidgets('phone-only viewer who has not turned reports on: clear state with the opt-in choices', (t) async {
    _big(t);
    const PrimaryLanes l = PrimaryLanes(circleId: 'c1', names: <String, String>{'u1': 'Blake'}, members: <MemberProcessing>[
      MemberProcessing(userId: 'u1', origin: ProcessingOrigin.phone, placeholder: PlaceholderReason.notSharedYet),
    ]);
    final _Api api = _Api();
    await t.pumpWidget(_screen(() async => l, api));
    await t.pumpAndSettle();
    expect(api.calls, 0, reason: 'nobody here uses the server');
    expect(find.text('Your driving report is not switched on'), findsOneWidget);
    expect(find.byKey(const Key('use-the-server')), findsOneWidget);
    expect(find.byKey(const Key('compute-on-phone')), findsOneWidget);
    expect(find.text('Weekly Driving Report'), findsOneWidget);
  });

  testWidgets('phone-only viewer with shared figures sees them in the dashboard header', (t) async {
    _big(t);
    final PrimaryLanes l = PrimaryLanes(circleId: 'c1', names: const <String, String>{'u1': 'Blake', 'u3': 'Kinsley'}, members: <MemberProcessing>[
      MemberProcessing(
        userId: 'u1',
        origin: ProcessingOrigin.phone,
        trips: <TripResult>[_trip('pb', DateTime(2026, 11, 2, 9))],
        drives: const <DriveResult>[DriveResult(tripId: 'pb', events: <DriveEventResult>[], speeding: 0, hardBrake: 1, rapidAccel: 0, phoneUse: 0)],
        updatedAt: DateTime(2026, 11, 4, 9).toUtc(),
      ),
    ]);
    final _Api api = _Api();
    await t.pumpWidget(_screen(() async => l, api));
    await t.pumpAndSettle();
    expect(api.calls, 0);
    expect(find.byType(DrivingDaysChart), findsOneWidget);
    expect(find.byType(RecentDriveTile), findsOneWidget);
    expect(find.byKey(const Key('phone-driving-You')), findsOneWidget);
  });

  testWidgets('offline: the saved report is shown with its age, not an empty error', (t) async {
    _big(t);
    final _Api api = _Api(fromCache: DateTime(2026, 11, 4, 9));
    await t.pumpWidget(_screen(() async => _lanes(), api));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('driving-offline-banner')), findsOneWidget);
    expect(find.textContaining('Showing the report saved 3 h ago'), findsOneWidget);
    expect(find.byType(RecentDriveTile), findsWidgets);
  });

  testWidgets('server unreachable and nothing saved: a friendly retry state, phones still shown', (t) async {
    _big(t);
    final _Api api = _Api(error: const ApiException(0, 'offline'));
    await t.pumpWidget(_screen(() async => _lanes(), api));
    await t.pumpAndSettle();
    expect(find.text('You are offline'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.byKey(const Key('phone-driving-Kinsley')), findsOneWidget);
  });

  group('mergePhoneMembers', () {
    test('adds totals, events, days and drives; waiting phones are left out; previous period counted', () {
      final TripReport base = emptyReportFor('week', DateTime(2026, 11, 2), now: _now);
      expect(base.days.length, 7);
      expect(base.isEmpty, isTrue);
      final MemberProcessing k = MemberProcessing(
        userId: 'u3',
        origin: ProcessingOrigin.phone,
        trips: <TripResult>[_trip('a', DateTime(2026, 11, 3, 8)), _trip('b', DateTime(2026, 11, 3, 18), top: 31), _trip('old', DateTime(2026, 10, 28, 8))],
        drives: const <DriveResult>[
          DriveResult(tripId: 'a', events: <DriveEventResult>[], speeding: 1, hardBrake: 0, rapidAccel: 0, phoneUse: 0),
          DriveResult(tripId: 'b', events: <DriveEventResult>[], speeding: 0, hardBrake: 2, rapidAccel: 0, phoneUse: 0),
          DriveResult(tripId: 'old', events: <DriveEventResult>[], speeding: 0, hardBrake: 4, rapidAccel: 0, phoneUse: 0),
        ],
        updatedAt: DateTime(2026, 11, 4).toUtc(),
      );
      final TripReport r = mergePhoneMembers(base, <PhoneReportMember>[
        PhoneReportMember(userId: 'u3', name: 'Kinsley', processing: k),
        const PhoneReportMember(
            userId: 'u9', name: 'Waiting', processing: MemberProcessing(userId: 'u9', origin: ProcessingOrigin.phone, placeholder: PlaceholderReason.notSharedYet)),
      ]);
      expect(r.members.map((MemberReport m) => m.userId), <String>['u3']);
      expect(r.totals.drives, 2);
      expect(r.totals.distanceM, 24000);
      expect(r.totals.topSpeedMps, 31);
      expect(r.totals.topSpeedUserId, 'u3');
      expect(r.totals.events.speeding, 1);
      expect(r.totals.events.hardBrake, 2);
      expect(r.totals.events.phoneUse, isNull, reason: 'phone use detection is off: never a made-up zero');
      expect(r.previousTotals.drives, 1);
      expect(r.previousTotals.events.hardBrake, 4);
      expect(r.days.firstWhere((ReportDay d) => d.date == DateTime(2026, 11, 3)).drives, 2);
      expect(r.recentTrips.length, 2);
      expect(r.recentTrips.first.id, 'b', reason: 'newest first');
      expect(r.recentTrips.every((RecentTrip t) => t.onDevice), isTrue);
    });
  });
}
