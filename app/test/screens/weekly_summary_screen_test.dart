import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/screens/weekly_summary_screen.dart';
import 'package:openfamily/services/api_client.dart';
import 'package:openfamily/services/direct_push_service.dart';
import 'package:openfamily/services/speed_units.dart';
import 'package:openfamily/services/weekly_summary_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Fake implements WeeklySummaryApi {
  _Fake(this.result);
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

WeeklySummary _summary() => WeeklySummary.fromJson(<String, dynamic>{
      'members': <Map<String, dynamic>>[
        <String, dynamic>{
          'user_id': 'u2',
          'name': 'Sam',
          'current': <String, dynamic>{
            'drives': 2,
            'distance_m': 160934.4,
            'duration_s': 5400,
            'top_speed_mps': 30,
            'safety_score': 88,
            'events': <String, dynamic>{
              'hard_brake': 3,
              'rapid_accel': 1,
              'speeding': 0,
              'phone_use': null,
            },
          },
          'previous': <String, dynamic>{
            'drives': 1,
            'distance_m': 80467.2,
            'duration_s': 1800,
            'top_speed_mps': 25,
            'events': <String, dynamic>{'hard_brake': 0},
          },
        },
        <String, dynamic>{
          'user_id': 'u1',
          'name': 'Blake',
          'current': <String, dynamic>{'drives': 0},
          'previous': <String, dynamic>{'drives': 0},
        },
      ],
    });

Widget _wrap(Widget child, {Brightness b = Brightness.light}) => MaterialApp(
      theme: ThemeData(brightness: b),
      home: child,
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    UnitPreferenceService.units.value = UnitSystem.imperial;
  });

  test('WeekStat parses nulls and phone use', () {
    final WeekStat s = WeekStat.fromJson(<String, dynamic>{});
    expect(s.drives, 0);
    expect(s.score, isNull);
    expect(s.phoneUse, isNull);
    expect(WeekStat.fromJson(<String, dynamic>{
      'events': <String, dynamic>{'phone_use': 2, 'hard_brake': 1}
    }).eventCount, 3);
  });

  testWidgets('shows this week vs last week in miles, self first',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(600, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(_wrap(
        WeeklySummaryScreen(api: _Fake(_summary()), selfId: 'u1'),
        b: Brightness.dark));
    await tester.pumpAndSettle();
    expect(find.text('Weekly summary'), findsOneWidget);
    expect(find.text('Blake (you)'), findsOneWidget);
    expect(find.text('Sam'), findsOneWidget);
    expect(find.text('100 mi, 2 drives'), findsOneWidget);
    expect(find.text('50 mi, 1 drive'), findsOneWidget);
    expect(find.text('Score 88'), findsOneWidget);
    expect(find.text('Hard braking 3 (was 0)'), findsOneWidget);
    expect(find.textContaining('Phone use'), findsNothing);
    expect(find.textContaining('Top speed 67 mph'), findsOneWidget);
    // Self (Blake (you)) is listed before Sam.
    expect(tester.getTopLeft(find.text('Blake (you)')).dy,
        lessThan(tester.getTopLeft(find.text('Sam')).dy));
    // Bars: this week is the longest, last week half as wide.
    final double cur =
        tester.getSize(find.byKey(const ValueKey<String>('bar-This week')).first).width;
    final double prev =
        tester.getSize(find.byKey(const ValueKey<String>('bar-Last week')).first).width;
    expect(prev, closeTo(cur / 2, 1));
  });

  testWidgets('honours the km preference', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(600, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    UnitPreferenceService.units.value = UnitSystem.metric;
    await tester.pumpWidget(
        _wrap(WeeklySummaryScreen(api: _Fake(_summary()), selfId: 'u1')));
    await tester.pumpAndSettle();
    expect(find.text('161 km, 2 drives'), findsOneWidget);
    expect(find.textContaining('km/h'), findsWidgets);
  });

  testWidgets('large text does not overflow', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      builder: (BuildContext c, Widget? w) => MediaQuery(
        data: MediaQuery.of(c).copyWith(textScaler: const TextScaler.linear(2)),
        child: w!,
      ),
      home: WeeklySummaryScreen(api: _Fake(_summary()), selfId: 'u1'),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty and error states', (WidgetTester tester) async {
    await tester.pumpWidget(_wrap(WeeklySummaryScreen(
        api: _Fake(const WeeklySummary(members: <WeeklyMember>[])))));
    await tester.pumpAndSettle();
    expect(find.text('No drives yet'), findsOneWidget);

    final _Fake f = _Fake(const ApiException(500, 'boom'));
    await tester.pumpWidget(_wrap(WeeklySummaryScreen(key: UniqueKey(), api: f)));
    await tester.pumpAndSettle();
    expect(find.text('Could not load the summary'), findsOneWidget);
    f.result = _summary();
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(f.calls, 2);
    expect(find.text('Sam'), findsOneWidget);
  });

  test('push route payload and tap routing', () async {
    final DirectPushEvent? e = DirectPushEvent.tryParse(
        '{"id":"x","kind":"notice","title":"t","route":"weekly_summary"}');
    expect(e!.route, 'weekly_summary');
    expect(DirectPushDispatcher.payloadFor(e), 'route:weekly_summary');
    String? opened;
    await routeNotificationTap(
      'route:weekly_summary',
      openAlert: (String _) async {},
      checkActive: () async {},
      openRoute: (String r) async => opened = r,
    );
    expect(opened, 'weekly_summary');
  });
}
