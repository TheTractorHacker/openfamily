import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:openfamily/models/member.dart';
import 'package:openfamily/models/trip.dart';
import 'package:openfamily/screens/driving_detection_screen.dart';
import 'package:openfamily/screens/family_driving_report_screen.dart';
import 'package:openfamily/screens/trip_detail_screen.dart';
import 'package:openfamily/services/driving/driving_settings.dart';
import 'package:openfamily/screens/trips_screen.dart';
import 'package:openfamily/services/api_client.dart' show ApiException;
import 'package:openfamily/services/speed_units.dart';
import 'package:openfamily/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/trip_report_fixtures.dart';
import 'trips_screens_test.dart' show FakeTrips;

const Member _blake = Member(
  id: 'u1',
  name: 'Blake',
  position: null,
  batteryPercent: 80,
  status: MemberStatus.normal,
  address: '',
);
const Member _brian = Member(
  id: 'u2',
  name: 'Brian',
  position: null,
  batteryPercent: 80,
  status: MemberStatus.normal,
  address: '',
);

final DateTime _now = DateTime(2026, 10, 26, 9);

final Trip _trip = Trip(
  id: 't3',
  userId: 'u1',
  startedAt: DateTime(2026, 10, 25, 8),
  endedAt: DateTime(2026, 10, 25, 8, 25),
  durationS: 1500,
  distanceM: 8000,
  maxSpeedMps: 29,
  avgSpeedMps: 5,
  mode: TripMode.driving,
  speedSource: 'device_gps',
  start: const LatLng(40, -75),
  end: const LatLng(40.1, -75),
);

Future<void> _pump(
  WidgetTester t,
  FakeTripReportApi api, {
  ValueNotifier<String?>? circle,
  double scale = 1,
  Future<DateTime?> Function(BuildContext, DateTime)? picker,
  FakeTrips? trips,
  bool dark = false,
}) async {
  t.view.physicalSize = const Size(780, 3200);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: dark ? buildDarkTheme() : buildLightTheme(),
      builder: (BuildContext c, Widget? child) => MediaQuery(
        data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: FamilyDrivingReportScreen(
        members: ValueNotifier<List<Member>>(<Member>[_blake, _brian]),
        userId: ValueNotifier<String?>('u2'),
        circleId: circle,
        api: api,
        tripsApi: trips ?? FakeTrips(),
        clock: () => _now,
        datePicker: picker,
      ),
    ),
  );
  await t.pump();
  await t.pump();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    UnitPreferenceService.units.value = UnitSystem.imperial;
  });

  testWidgets('shows loading skeleton, then the report', (WidgetTester t) async {
    final FakeTripReportApi api = FakeTripReportApi();
    await _pump(t, api);
    expect(find.text('Driving'), findsOneWidget);
    expect(find.text('Blake', skipOffstage: false), findsOneWidget);
    expect(find.text('You'), findsOneWidget, reason: 'self is labelled You');
    expect(find.text('84 mph'), findsOneWidget);
    expect(find.text('GPS speed'), findsOneWidget);
    expect(find.text('1 drive · 30 mi'), findsOneWidget);
    expect(find.text('1 risky event'), findsOneWidget);
    expect(find.text('No drives'), findsOneWidget, reason: 'idle member is collapsed');
    expect(find.text('Off'), findsOneWidget);
    expect(find.textContaining('Phone use is off'), findsOneWidget);
    expect(api.calls.single.$1, DateTime(2026, 10, 26));
  });

  testWidgets('loading skeleton before data arrives', (WidgetTester t) async {
    t.view.physicalSize = const Size(780, 3200);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: FamilyDrivingReportScreen(
          members: ValueNotifier<List<Member>>(<Member>[_blake]),
          userId: ValueNotifier<String?>(null),
          api: FakeTripReportApi(),
          clock: () => _now,
        ),
      ),
    );
    expect(find.bySemanticsLabel('Loading driving report'), findsOneWidget);
    await t.pumpAndSettle();
    expect(find.bySemanticsLabel('Loading driving report'), findsNothing);
  });

  testWidgets('chip semantics carry count and trend as text', (WidgetTester t) async {
    final SemanticsHandle h = t.ensureSemantics();
    await _pump(t, FakeTripReportApi());
    expect(
      find.bySemanticsLabel(
        'Speeding: 1 incident this week, down from 2. Tap to learn more.',
      ),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('Phone use: off. Tap to learn more.'),
      findsOneWidget,
    );
    h.dispose();
  });

  testWidgets('empty state', (WidgetTester t) async {
    await _pump(
      t,
      FakeTripReportApi(result: reportJson(drives: 0, speeding: 0)),
    );
    expect(find.text('No drives yet this week'), findsOneWidget);
    expect(find.textContaining('moving faster than walking'), findsOneWidget);
    expect(find.text('Drivers'), findsNothing);
  });

  testWidgets('offline with retry', (WidgetTester t) async {
    final FakeTripReportApi api = FakeTripReportApi(
      error: const ApiException(0, 'Server is not reachable.'),
    );
    await _pump(t, api);
    expect(find.text('You are offline'), findsOneWidget);
    api.error = null;
    await t.tap(find.text('Try again'));
    await t.pump();
    await t.pump();
    expect(find.text('Blake', skipOffstage: false), findsOneWidget);
  });

  testWidgets('generic error with retry', (WidgetTester t) async {
    final FakeTripReportApi api = FakeTripReportApi(
      error: const ApiException(500, 'Boom'),
    );
    await _pump(t, api);
    expect(find.text('Could not load the report'), findsOneWidget);
    expect(find.text('Boom'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('keeps the last report with an offline banner', (WidgetTester t) async {
    final FakeTripReportApi api = FakeTripReportApi();
    final ValueNotifier<String?> circle = ValueNotifier<String?>('c1');
    await _pump(t, api, circle: circle);
    api.error = const ApiException(0, 'Server is not reachable.');
    circle.value = 'c2';
    await t.pump();
    await t.pump();
    expect(find.text('Blake'), findsOneWidget);
    expect(find.textContaining('Showing the last report'), findsOneWidget);
  });

  testWidgets('arrows, week/month toggle and picker reload the right period',
      (WidgetTester t) async {
    final FakeTripReportApi api = FakeTripReportApi();
    await _pump(
      t,
      api,
      picker: (BuildContext c, DateTime n) async => DateTime(2026, 10, 14),
    );
    expect(find.text('This week'), findsOneWidget);
    expect(find.text('Oct 26 – Nov 1'), findsOneWidget);
    // Next is disabled at the current week.
    final IconButton next = t.widget(find.widgetWithIcon(IconButton, Icons.chevron_right_rounded));
    expect(next.onPressed, isNull);
    await t.tap(find.byTooltip('Previous week'));
    await t.pump();
    await t.pump();
    expect(api.calls.last.$1, DateTime(2026, 10, 19));
    expect(find.text('Last week'), findsOneWidget);
    await t.tap(find.text('Pick a week'));
    await t.pump();
    await t.pump();
    expect(api.calls.last.$1, DateTime(2026, 10, 12));
    expect(find.text('Oct 12 – Oct 18'), findsWidgets);
    await t.tap(find.byTooltip('Next week'));
    await t.pump();
    await t.pump();
    expect(api.calls.last.$1, DateTime(2026, 10, 19));
    await t.tap(find.text('Month'));
    await t.pump();
    await t.pump();
    expect(api.periods.last, 'month');
    expect(api.calls.last.$1, DateTime(2026, 10));
    expect(find.text('October 2026'), findsOneWidget);
    expect(find.text('This month'), findsOneWidget);
    await t.tap(find.byTooltip('Previous month'));
    await t.pump();
    await t.pump();
    expect(api.calls.last.$1, DateTime(2026, 9));
    expect(find.text('Last month'), findsOneWidget);
    await t.tap(find.text('Week'));
    await t.pump();
    await t.pump();
    expect(api.periods.last, 'week');
    expect(api.calls.last.$1, DateTime(2026, 8, 31));
  });

  testWidgets('uses the selected circle and reloads when it changes', (WidgetTester t) async {
    final FakeTripReportApi api = FakeTripReportApi();
    final ValueNotifier<String?> circle = ValueNotifier<String?>('c1');
    await _pump(t, api, circle: circle);
    expect(api.calls.last.$2, 'c1');
    circle.value = 'all';
    await t.pump();
    await t.pump();
    expect(api.calls.last.$2, isNull, reason: 'all circles = no circle_id');
    circle.value = null;
    await t.pump();
    await t.pump();
    expect(api.calls.length, 3);
  });

  testWidgets('metric units', (WidgetTester t) async {
    UnitPreferenceService.units.value = UnitSystem.metric;
    await _pump(t, FakeTripReportApi());
    expect(find.text('135 km/h'), findsOneWidget);
    expect(find.text('1 drive · 48 km'), findsOneWidget);
  });

  testWidgets('chip opens the sheet with thresholds and per-member list', (WidgetTester t) async {
    await _pump(
      t,
      FakeTripReportApi(result: reportJson(speeding: 3, twoMembers: true)),
    );
    await t.tap(find.text('Speeding'));
    await t.pumpAndSettle();
    expect(find.text('3 incidents this week'), findsOneWidget);
    expect(find.text('What is speeding?'), findsOneWidget);
    expect(
      find.textContaining('over 80 mph for at least 30 seconds'),
      findsOneWidget,
    );
    expect(find.text('Blake'), findsWidgets);
    expect(find.text('2 incidents'), findsOneWidget);
    expect(find.text('1 incident'), findsOneWidget);
    await t.tap(find.text('Got it'));
    await t.pumpAndSettle();
    expect(find.text('What is speeding?'), findsNothing);
  });

  testWidgets('braking sheet says estimates are GPS based', (WidgetTester t) async {
    await _pump(t, FakeTripReportApi());
    await t.tap(find.text('Hard braking'));
    await t.pumpAndSettle();
    expect(find.text('What is hard braking?'), findsOneWidget);
    expect(find.textContaining('estimates from GPS'), findsOneWidget);
    expect(find.text('0 incidents this week'), findsOneWidget);
  });

  testWidgets('phone use sheet explains it is off and opens the settings',
      (WidgetTester t) async {
    await _pump(t, FakeTripReportApi());
    await t.tap(find.text('Phone use'));
    await t.pumpAndSettle();
    expect(find.text('Off'), findsWidgets);
    expect(find.textContaining('Phone use tracking is off. Turn it on in '
        'Settings > Driving detection (experimental: it records screen '
        'activity while the car is moving and cannot tell a driver from a '
        'passenger)'), findsOneWidget);
    await t.ensureVisible(find.text('Open Driving detection'));
    await t.tap(find.text('Open Driving detection'));
    await t.pumpAndSettle();
    expect(find.byType(DrivingDetectionScreen), findsOneWidget);
  });

  testWidgets('phone use tile: zero is a real count, never shown for off',
      (WidgetTester t) async {
    final Map<String, dynamic> j = reportJson(rich: true, sensor: true);
    await _pump(t, FakeTripReportApi(result: j));
    // sensor fixture: totals phone_use 0 for an enabled member
    (j['totals'] as Map<String, dynamic>)['events']['phone_use'] = 0;
    await _pump(t, FakeTripReportApi(result: j));
    expect(find.text('Off'), findsNothing);
    await t.tap(find.text('Phone use'));
    await t.pumpAndSettle();
    expect(find.text('0 incidents this week'), findsOneWidget);
    expect(find.text('Open Driving detection'), findsNothing);
  });

  testWidgets('member card opens that member\'s trips', (WidgetTester t) async {
    await _pump(t, FakeTripReportApi());
    await t.tap(find.text('Blake'));
    await t.pumpAndSettle();
    expect(find.byType(TripsScreen), findsOneWidget);
    final TripsScreen s = t.widget(find.byType(TripsScreen));
    expect(s.member.id, 'u1');
  });

  testWidgets('works at 200% text without overflow', (WidgetTester t) async {
    await _pump(t, FakeTripReportApi(), scale: 2);
    expect(t.takeException(), isNull);
    await t.scrollUntilVisible(find.text('Blake'), 300);
    expect(t.takeException(), isNull);
    expect(find.text('Blake'), findsOneWidget);
  });

  testWidgets('tap targets are at least 48dp', (WidgetTester t) async {
    await _pump(t, FakeTripReportApi());
    for (final String label in <String>['Week', 'Month']) {
      final Size s = t.getSize(
        find.ancestor(of: find.text(label), matching: find.byType(InkWell)),
      );
      expect(s.height, greaterThanOrEqualTo(48));
    }
  });

  group('Driving page content', () {
    Future<void> pumpRich(
      WidgetTester t, {
      bool sensor = false,
      bool detectionOn = true,
      bool sharing = true,
      List<Member>? members,
      double scale = 1,
      FakeTrips? trips,
    }) async {
      t.view.physicalSize = const Size(780, 9000);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          theme: buildLightTheme(),
          builder: (BuildContext c, Widget? child) => MediaQuery(
            data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: FamilyDrivingReportScreen(
            members: ValueNotifier<List<Member>>(members ?? <Member>[_blake, _brian]),
            userId: ValueNotifier<String?>('u2'),
            api: FakeTripReportApi(
              result: reportJson(twoMembers: true, rich: true, sensor: sensor),
            ),
            tripsApi: trips ?? FakeTrips(),
            clock: () => DateTime(2026, 10, 25, 12),
            sharing: ValueNotifier<bool>(sharing),
            detectionLoader: () async => detectionOn,
          ),
        ),
      );
      await t.pump();
      await t.pump();
      await t.pump();
    }

    testWidgets('recent drives are on the page with all the facts',
        (WidgetTester t) async {
      await pumpRich(t);
      expect(find.text('Recent drives'), findsOneWidget);
      expect(find.text('Blake · Today 8:00 am'), findsOneWidget);
      expect(find.text('Blake · Fri Oct 23 5:00 pm'), findsOneWidget);
      expect(find.text('You · Fri Oct 23 9:00 am'), findsOneWidget);
      expect(find.text('7.5 mi · 25 min · top 65 mph'), findsWidgets);
      expect(find.text('1 speeding'), findsWidgets);
      expect(find.text('2 hard braking'), findsOneWidget);
    });

    testWidgets('daily chart has real axis labels and tapping a day filters',
        (WidgetTester t) async {
      await pumpRich(t);
      expect(find.text('Distance per day (mi)'), findsOneWidget);
      // 20 km = 12.4 mi -> axis 20 mi, half 10, zero.
      expect(find.text('20 mi'), findsOneWidget);
      expect(find.text('10'), findsOneWidget);
      expect(find.text('Mon'), findsOneWidget);
      await t.tap(find.bySemanticsLabel(RegExp('^Fri Oct 23')));
      await t.pump();
      expect(find.text('Drives on Fri Oct 23'), findsOneWidget);
      expect(find.text('Blake · Fri Oct 23 5:00 pm'), findsOneWidget);
      expect(find.text('Blake · Today 8:00 am'), findsNothing);
      await t.tap(find.text('Show all drives'));
      await t.pump();
      expect(find.text('Recent drives'), findsOneWidget);
      expect(find.text('Blake · Today 8:00 am'), findsOneWidget);
    });

    testWidgets('a day with no drives says so', (WidgetTester t) async {
      await pumpRich(t);
      await t.tap(find.bySemanticsLabel(RegExp('^Sat Oct 24')));
      await t.pump();
      expect(find.text('No drives on this day.'), findsOneWidget);
    });

    testWidgets('tapping a drive opens its detail', (WidgetTester t) async {
      await pumpRich(t, trips: FakeTrips(trips: <Trip>[_trip]));
      await t.tap(find.text('Blake · Today 8:00 am'));
      await t.pumpAndSettle();
      expect(find.byType(TripDetailScreen), findsOneWidget);
    });

    testWidgets('Driving now strip shows speed in the unit; hidden when nobody drives',
        (WidgetTester t) async {
      final Member driving = _blake.copyWith(
        movement: MovementType.car,
        speedMph: 42,
      );
      await pumpRich(t, members: <Member>[driving, _brian]);
      expect(find.text('DRIVING NOW'), findsOneWidget);
      expect(find.text('Driving 42 mph'), findsOneWidget);
      UnitPreferenceService.units.value = UnitSystem.metric;
      await t.pump();
      expect(find.text('Driving 68 km/h'), findsOneWidget);
      UnitPreferenceService.units.value = UnitSystem.imperial;
    });

    testWidgets('no Driving now strip when nobody is driving',
        (WidgetTester t) async {
      await pumpRich(t);
      expect(find.text('DRIVING NOW'), findsNothing);
    });

    testWidgets('detection off shows the prompt with a button; on does not',
        (WidgetTester t) async {
      await pumpRich(t, detectionOn: false);
      expect(
        find.text('Hard braking and phone use need Driving detection'),
        findsOneWidget,
      );
      await t.tap(find.text('Open Driving detection'));
      await t.pumpAndSettle();
      expect(find.byType(DrivingDetectionScreen), findsOneWidget);
    });

    testWidgets('detection on: no prompt', (WidgetTester t) async {
      await pumpRich(t);
      expect(find.textContaining('need Driving detection'), findsNothing);
    });

    testWidgets('sharing paused is explained', (WidgetTester t) async {
      await pumpRich(t, sharing: false);
      expect(find.text('Your location sharing is paused'), findsOneWidget);
    });

    testWidgets('GPS-only estimate note; absent when a sensor member exists',
        (WidgetTester t) async {
      await pumpRich(t);
      expect(find.textContaining('estimated from GPS'), findsOneWidget);
    });

    testWidgets('sensor members: no GPS-only note, phone use is a number',
        (WidgetTester t) async {
      await pumpRich(t, sensor: true);
      expect(find.textContaining('estimated from GPS'), findsNothing);
      expect(find.text('Speeds, braking and acceleration are GPS estimates.'),
          findsOneWidget);
    });

    testWidgets('one member with one drive looks complete',
        (WidgetTester t) async {
      t.view.physicalSize = const Size(780, 9000);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      final Map<String, dynamic> j = reportJson(rich: true);
      (j['members'] as List).removeLast();
      await t.pumpWidget(MaterialApp(
        theme: buildLightTheme(),
        home: FamilyDrivingReportScreen(
          members: ValueNotifier<List<Member>>(<Member>[_blake]),
          userId: ValueNotifier<String?>('u1'),
          api: FakeTripReportApi(result: j),
          clock: () => DateTime(2026, 10, 25, 12),
          detectionLoader: () async => true,
        ),
      ));
      await t.pump();
      await t.pump();
      expect(find.text('Driver'), findsOneWidget);
      expect(find.text('Recent drives'), findsOneWidget);
      expect(find.textContaining('Top speed 84 mph'), findsOneWidget);
      expect(find.text('No drives'), findsNothing);
    });

    testWidgets('200% text does not overflow with the full page',
        (WidgetTester t) async {
      await pumpRich(t, scale: 2, detectionOn: false, sharing: false);
      expect(t.takeException(), isNull);
      await t.scrollUntilVisible(find.text('Drivers'), 400,
          scrollable: find.byType(Scrollable).first);
      expect(t.takeException(), isNull);
    });

    testWidgets('chart bars and drives are labelled for screen readers',
        (WidgetTester t) async {
      final SemanticsHandle h = t.ensureSemantics();
      await pumpRich(t);
      expect(find.bySemanticsLabel(RegExp(r'^Fri Oct 23: 12 mi, 2 drives')),
          findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Sun Oct 25, today')),
          findsOneWidget);
      h.dispose();
    });
  });

  group('disclosure card', () {
    Future<void> pumpCard(WidgetTester t, {bool detectionOn = true}) async {
      t.view.physicalSize = const Size(780, 3200);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: buildLightTheme(),
        home: FamilyDrivingReportScreen(
          members: ValueNotifier<List<Member>>(<Member>[_blake]),
          userId: ValueNotifier<String?>('u1'),
          api: FakeTripReportApi(),
          clock: () => _now,
          detectionLoader: () async => detectionOn,
        ),
      ));
      await t.pump();
      await t.pump();
      await t.pump();
    }

    testWidgets('shows once, says what is collected, and Okay dismisses it for good',
        (WidgetTester t) async {
      await pumpCard(t);
      expect(find.text('Driving detection is on'), findsOneWidget);
      expect(find.textContaining('only while you are driving'), findsOneWidget);
      expect(find.textContaining('never the raw sensor data'), findsOneWidget);
      await t.tap(find.text('Okay'));
      await t.pump();
      expect(find.text('Driving detection is on'), findsNothing);
      expect(await DrivingSettings.disclosureSeen(), isTrue);
      await t.pumpWidget(const SizedBox());
      await pumpCard(t);
      expect(find.text('Driving detection is on'), findsNothing,
          reason: 'seen state survives a new screen');
    });

    testWidgets('Change in Settings marks it seen and opens Driving detection',
        (WidgetTester t) async {
      await pumpCard(t);
      await t.tap(find.text('Change in Settings'));
      await t.pumpAndSettle();
      expect(find.byType(DrivingDetectionScreen), findsOneWidget);
      expect(await DrivingSettings.disclosureSeen(), isTrue);
    });

    testWidgets('not shown when the user has turned detection off',
        (WidgetTester t) async {
      await pumpCard(t, detectionOn: false);
      expect(find.text('Driving detection is on'), findsNothing);
    });
  });
}
