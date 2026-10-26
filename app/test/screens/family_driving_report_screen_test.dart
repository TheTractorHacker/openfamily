import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/member.dart';
import 'package:openfamily/screens/family_driving_report_screen.dart';
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
    expect(find.text('Weekly driving report'), findsOneWidget);
    expect(find.text('Blake', skipOffstage: false), findsOneWidget);
    expect(find.text('You'), findsOneWidget, reason: 'self is labelled You');
    expect(find.text('84 mph'), findsOneWidget);
    expect(find.text('GPS speed'), findsOneWidget);
    expect(find.text('1 drive · 30 mi'), findsOneWidget);
    expect(find.text('1 risky event'), findsOneWidget);
    expect(find.text('No drives yet'), findsNWidgets(2));
    expect(find.text('Not tracked yet'), findsOneWidget);
    expect(find.textContaining('Phone use is not tracked yet'), findsOneWidget);
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
      find.bySemanticsLabel('Phone use: not tracked yet. Tap to learn more.'),
      findsOneWidget,
    );
    h.dispose();
  });

  testWidgets('empty state', (WidgetTester t) async {
    await _pump(
      t,
      FakeTripReportApi(result: reportJson(drives: 0, speeding: 0)),
    );
    expect(find.text('No trips this week yet'), findsOneWidget);
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

  testWidgets('period chips reload with the right start', (WidgetTester t) async {
    final FakeTripReportApi api = FakeTripReportApi();
    await _pump(
      t,
      api,
      picker: (BuildContext c, DateTime n) async => DateTime(2026, 10, 14),
    );
    await t.tap(find.text('Last week'));
    await t.pump();
    await t.pump();
    expect(api.calls.last.$1, DateTime(2026, 10, 19));
    await t.tap(find.text('Pick a week'));
    await t.pump();
    await t.pump();
    expect(api.calls.last.$1, DateTime(2026, 10, 12));
    expect(find.text('Oct 12 – Oct 18'), findsWidgets);
    await t.tap(find.text('This week'));
    await t.pump();
    await t.pump();
    expect(api.calls.last.$1, DateTime(2026, 10, 26));
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

  testWidgets('phone use sheet explains it is not tracked', (WidgetTester t) async {
    await _pump(t, FakeTripReportApi());
    await t.tap(find.text('Phone use'));
    await t.pumpAndSettle();
    expect(find.text('Not tracked yet'), findsWidgets);
    expect(find.textContaining('does not measure this yet'), findsOneWidget);
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
    for (final String label in <String>['This week', 'Last week']) {
      final Size s = t.getSize(
        find.ancestor(of: find.text(label), matching: find.byType(InkWell)),
      );
      expect(s.height, greaterThanOrEqualTo(48));
    }
  });
}
