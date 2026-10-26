import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/circle.dart';
import 'package:openfamily/models/member.dart';
import 'package:openfamily/theme/app_theme.dart';
import 'package:openfamily/widgets/location_tab_view.dart';

import '../support/location_fixtures.dart';

class _Calls {
  final List<String> log = <String>[];
}

Widget _app({
  List<Member> members = const <Member>[kSelf, kDriver, kAtHome],
  List<Circle> circles = kCircles,
  String circleName = 'Frank Family',
  String? selectedCircleId,
  bool circleSharingPaused = false,
  bool selectable = false,
  bool sharingPaused = false,
  bool loading = false,
  String? error,
  bool hasFamily = true,
  bool locationOff = false,
  PlacesLoader? places,
  _Calls? calls,
  ThemeData? theme,
  double textScale = 1,
}) {
  final _Calls c = calls ?? _Calls();
  return MaterialApp(
    theme: theme ?? buildLightTheme(),
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: LocationTabView(
        map: const FakeMap(),
        circleName: circleName,
        selectedCircleId: selectedCircleId,
        circleSharingPaused: circleSharingPaused,
        onSelectCircle: selectable ? (String id) => c.log.add('select-circle:$id') : null,
        onResumeCircleSharing: () => c.log.add('resume'),
        circles: circles,
        members: members,
        selfId: 'me',
        sharingPaused: sharingPaused,
        loading: loading,
        error: error,
        hasFamily: hasFamily,
        locationOff: locationOff,
        placesLoader: places ?? fakePlaces,
        onCheckIn: () => c.log.add('checkin'),
        onSos: () => c.log.add('sos'),
        onOpenSettings: () => c.log.add('settings'),
        onInvite: () => c.log.add('invite'),
        onToggleSatellite: () => c.log.add('layers'),
        onLocate: () => c.log.add('locate'),
        onSelectMember: (Member m) => c.log.add('select:${m.id}'),
        onOpenMember: (Member m) => c.log.add('open:${m.id}'),
        onOpenCircle: (Circle x) => c.log.add('circle:${x.id}'),
        onManageCircles: () => c.log.add('manage'),
        onJoinCircle: () => c.log.add('join'),
        onRetry: () => c.log.add('retry'),
        onEnableLocation: () => c.log.add('enable'),
      ),
    ),
  );
}

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _expand(WidgetTester tester) async {
  await tester.fling(find.text('People'), const Offset(0, -500), 2000);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows floating controls, the circle pill and People rows', (
    tester,
  ) async {
    _phone(tester);
    await tester.pumpWidget(_app());
    await tester.pump();

    expect(find.text('Frank Family'), findsOneWidget);
    expect(find.byTooltip('Settings'), findsOneWidget);
    expect(find.byTooltip('Switch to satellite'), findsOneWidget);
    expect(find.byTooltip('Center on my location'), findsOneWidget);
    expect(find.text('Check in'), findsOneWidget);
    expect(find.text('SOS'), findsOneWidget);

    expect(find.text('People'), findsOneWidget);
    expect(find.text('Places'), findsOneWidget);
    await _expand(tester);
    expect(find.text('Driving 42 mph'), findsOneWidget);
    expect(find.text('At Home'), findsOneWidget);
    expect(find.text('Battery 18%'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('floating buttons call back', (tester) async {
    _phone(tester);
    final calls = _Calls();
    await tester.pumpWidget(_app(calls: calls));
    await tester.pump();

    await tester.tap(find.text('Check in'));
    await tester.tap(find.text('SOS'));
    await tester.tap(find.byTooltip('Settings'));
    await tester.tap(find.byTooltip('Invite someone'));
    await tester.tap(find.byTooltip('Switch to satellite'));
    await tester.tap(find.byTooltip('Center on my location'));
    expect(calls.log, <String>[
      'checkin',
      'sos',
      'settings',
      'invite',
      'layers',
      'locate',
    ]);
  });

  testWidgets('single circle: pill still shows the name and opens the list', (
    tester,
  ) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(circles: const <Circle>[], circleName: 'Solo Circle'),
    );
    await tester.pump();
    expect(find.text('Solo Circle'), findsOneWidget);

    await tester.tap(find.text('Solo Circle'));
    await tester.pumpAndSettle();
    expect(find.text('Your circles'), findsOneWidget);
    expect(find.text('Create or join a circle'), findsOneWidget);
  });

  testWidgets('circle sheet lists circles; other circle opens its detail', (
    tester,
  ) async {
    _phone(tester);
    final calls = _Calls();
    await tester.pumpWidget(_app(calls: calls));
    await tester.pump();
    await tester.tap(find.text('Frank Family'));
    await tester.pumpAndSettle();

    expect(find.text('Soccer team'), findsOneWidget);
    expect(find.textContaining('Shown on the map'), findsOneWidget);

    await tester.tap(find.text('Soccer team'));
    await tester.pumpAndSettle();
    expect(calls.log, contains('circle:c2'));
    expect(find.text('Your circles'), findsNothing);
  });

  testWidgets('circle sheet: create or join goes to manage', (tester) async {
    _phone(tester);
    final calls = _Calls();
    await tester.pumpWidget(_app(calls: calls));
    await tester.pump();
    await tester.tap(find.text('Frank Family'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create or join a circle'));
    await tester.pumpAndSettle();
    expect(calls.log, contains('manage'));
  });

  testWidgets('tapping a person selects them and reveals Details', (
    tester,
  ) async {
    _phone(tester);
    final calls = _Calls();
    await tester.pumpWidget(_app(calls: calls));
    await tester.pump();

    await _expand(tester);
    expect(find.text('Details and history'), findsNothing);
    await tester.tap(find.text('Driving 42 mph'));
    await tester.pump();
    expect(calls.log, contains('select:u1'));
    expect(find.text('Details and history'), findsOneWidget);

    await tester.tap(find.text('Details and history'));
    expect(calls.log, contains('open:u1'));
  });

  testWidgets('own row says Location sharing paused when sharing is off', (
    tester,
  ) async {
    _phone(tester);
    await tester.pumpWidget(_app(sharingPaused: true));
    await tester.pump();
    expect(find.text('Location sharing paused'), findsOneWidget);
  });

  testWidgets('Places tab loads and lists saved places', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app());
    await tester.pump();
    await tester.tap(find.text('Places'));
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('School'), findsOneWidget);
    expect(find.text('Manage places'), findsOneWidget);
    expect(find.text('Sam'), findsNothing);
  });

  testWidgets('Places tab empty and error states', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(places: () async => []));
    await tester.pump();
    await tester.tap(find.text('Places'));
    await tester.pumpAndSettle();
    expect(find.text('No places yet'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_app(places: () async => throw Exception('x')));
    await tester.pump();
    await tester.tap(find.text('Places'));
    await tester.pumpAndSettle();
    expect(find.text('Could not load places'), findsOneWidget);
  });

  testWidgets('sheet state: loading', (tester) async {
    _phone(tester);
    await tester.pumpWidget(_app(members: const [], loading: true));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('sheet state: error with retry is visible at the peek', (
    tester,
  ) async {
    _phone(tester);
    final calls = _Calls();
    await tester.pumpWidget(
      _app(members: const [], error: 'Server down', calls: calls),
    );
    await tester.pump();
    expect(find.text('Server down'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    expect(calls.log, contains('retry'));
  });

  testWidgets('sheet state: not in a circle offers Join', (tester) async {
    _phone(tester);
    final calls = _Calls();
    await tester.pumpWidget(
      _app(members: const [], hasFamily: false, calls: calls),
    );
    await tester.pump();
    await _expand(tester);
    await tester.tap(find.text('Join a circle'));
    expect(calls.log, contains('join'));
  });

  testWidgets('location-off banner offers Enable', (tester) async {
    _phone(tester);
    final calls = _Calls();
    await tester.pumpWidget(_app(locationOff: true, calls: calls));
    await tester.pump();
    await tester.tap(find.text('Enable'));
    expect(calls.log, contains('enable'));
  });

  testWidgets('dragging the sheet up expands it and hides floating pills', (
    tester,
  ) async {
    _phone(tester);
    await tester.pumpWidget(_app());
    await tester.pump();
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      1,
    );
    await tester.fling(find.text('People'), const Offset(0, -600), 2000);
    await tester.pumpAndSettle();
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      0,
    );
  });

  testWidgets('dark theme at 2x text does not overflow', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(theme: buildDarkTheme(), textScale: 2, locationOff: true),
    );
    await tester.pump();
    await _expand(tester);
  });

  testWidgets('selecting a circle in the pill sheet reports its id', (
    tester,
  ) async {
    _phone(tester);
    final calls = _Calls();
    await tester.pumpWidget(
      _app(calls: calls, selectable: true, selectedCircleId: 'c1'),
    );
    await tester.pump();
    await tester.tap(find.text('Frank Family'));
    await tester.pumpAndSettle();
    expect(find.text('All circles'), findsOneWidget);
    await tester.tap(find.text('Soccer team'));
    await tester.pumpAndSettle();
    expect(calls.log, contains('select-circle:c2'));
    expect(calls.log, isNot(contains('circle:c2')));
    expect(find.text('Your circles'), findsNothing);
  });

  testWidgets('"All circles" selects the all scope', (tester) async {
    _phone(tester);
    final calls = _Calls();
    await tester.pumpWidget(_app(calls: calls, selectable: true));
    await tester.pump();
    await tester.tap(find.text('Frank Family'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All circles'));
    await tester.pumpAndSettle();
    expect(calls.log, contains('select-circle:all'));
  });

  testWidgets('sharing paused in the selected circle shows a resume banner', (
    tester,
  ) async {
    _phone(tester);
    final calls = _Calls();
    await tester.pumpWidget(
      _app(
        calls: calls,
        circleName: 'Soccer team',
        selectedCircleId: 'c2',
        circleSharingPaused: true,
        selectable: true,
      ),
    );
    await tester.pump();
    expect(find.textContaining('Sharing paused.'), findsOneWidget);
    await tester.tap(find.text('Resume'));
    expect(calls.log, contains('resume'));
  });

  testWidgets('no paused banner and no All row with a single circle', (
    tester,
  ) async {
    _phone(tester);
    await tester.pumpWidget(
      _app(circles: <Circle>[kCircles.first], selectable: true),
    );
    await tester.pump();
    expect(find.textContaining('Sharing paused.'), findsNothing);
    await tester.tap(find.text('Frank Family'));
    await tester.pumpAndSettle();
    expect(find.text('All circles'), findsNothing);
  });
}
