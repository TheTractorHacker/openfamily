import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/screens/keep_alive_screen.dart';
import 'package:openfamily/services/diagnostics/diag_model.dart';
import 'package:openfamily/services/diagnostics/tracking_health.dart';

final DateTime now = DateTime.utc(2026, 11, 11, 12);

DiagFacts samsung({bool ignoring = false, String location = 'always', bool android = true, String maker = 'samsung'}) => DiagFacts(
      now: now,
      isAndroid: android,
      manufacturer: maker,
      locationService: true,
      locationPermission: location,
      notificationsGranted: true,
      ignoringBatteryOptimizations: ignoring,
      backgroundRestricted: false,
      powerSave: false,
      backgroundServiceRunning: true,
      tracking: const TrackingHealthFacts(standbyBucket: 10),
    );

void main() {
  setUp(() {});

  testWidgets('shows live rows, a fix button that runs, and the Samsung explanation', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final List<DiagFixKind> fixes = <DiagFixKind>[];
    await tester.pumpWidget(MaterialApp(
      home: KeepAliveScreen(
        collect: () async => samsung(ignoring: false, location: 'while_in_use'),
        onFix: (DiagFixKind k) async => fixes.add(k),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Keep tracking alive'), findsOneWidget);
    expect(find.text('Location permission'), findsOneWidget);
    expect(find.text('Samsung sleep settings'), findsOneWidget);
    expect(find.textContaining('cannot add itself'), findsOneWidget);
    expect(find.text('Android may stop Orbitly when the app is closed'), findsOneWidget);

    await tester.tap(find.text('Set battery to Unrestricted'));
    await tester.pump();
    expect(fixes, <DiagFixKind>[DiagFixKind.batterySettings]);
  });

  testWidgets('Samsung, everything readable right: not green, one check is the user\'s', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: KeepAliveScreen(collect: () async => samsung(ignoring: true))));
    await tester.pumpAndSettle();
    expect(find.text('Orbitly is set up to keep running'), findsNothing);
    expect(find.text('Everything Orbitly can read is right'), findsOneWidget);
    expect(find.textContaining('Sleeping apps'), findsWidgets);
  });

  testWidgets('another phone, everything right: green headline', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: KeepAliveScreen(collect: () async => samsung(ignoring: true, maker: 'Google'))));
    await tester.pumpAndSettle();
    expect(find.text('Orbitly is set up to keep running'), findsOneWidget);
  });

  testWidgets('the probe fails: no green headline, a plain "could not check" message', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: KeepAliveScreen(collect: () async => throw StateError('probe'))));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('keep-alive-unreadable')), findsOneWidget);
    expect(find.textContaining('Could not check this phone'), findsOneWidget);
    expect(find.text('Orbitly is set up to keep running'), findsNothing);
    expect(find.byKey(const Key('keep-alive-headline')), findsNothing);
  });

  testWidgets('re-checks when the app comes back from a settings page', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    int calls = 0;
    bool ignoring = false;
    await tester.pumpWidget(MaterialApp(
      home: KeepAliveScreen(collect: () async {
        calls++;
        return samsung(ignoring: ignoring);
      }),
    ));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.text('Almost: a few things to check'), findsOneWidget);

    // The user sets Unrestricted in the system page and returns.
    ignoring = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('Everything Orbitly can read is right'), findsOneWidget);
  });

  testWidgets('iPhone: says there is nothing to set', (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: KeepAliveScreen(collect: () async => samsung(android: false))));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('keep-alive-not-android')), findsOneWidget);
  });
}
