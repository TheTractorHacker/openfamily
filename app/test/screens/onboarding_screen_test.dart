import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/screens/onboarding_screen.dart';
import 'package:openfamily/services/onboarding_service.dart';
import 'package:openfamily/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _host({
  Widget Function(BuildContext)? builder,
  double scale = 1,
  TextDirection dir = TextDirection.ltr,
  ThemeData? theme,
}) {
  return MaterialApp(
    theme: theme ?? buildLightTheme(),
    builder: (c, child) => MediaQuery(
      data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
      child: Directionality(textDirection: dir, child: child!),
    ),
    home: Builder(
      builder: builder ??
          (c) => Scaffold(
                body: TextButton(
                  onPressed: () => OnboardingScreen.maybeShow(c, 'u1'),
                  child: const Text('go'),
                ),
              ),
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    OnboardingService.resetCheckedForTest();
  });

  testWidgets('shows on first run', (t) async {
    await t.pumpWidget(_host());
    await t.tap(find.text('go'));
    await t.pumpAndSettle();
    expect(find.text('Welcome to Orbitly'), findsOneWidget);
    expect(find.text('Skip'), findsOneWidget);
  });

  testWidgets('does not show again once seen', (t) async {
    SharedPreferences.setMockInitialValues(
        <String, Object>{'onboarding_seen_v1_u1': true});
    await t.pumpWidget(_host());
    await t.tap(find.text('go'));
    await t.pumpAndSettle();
    expect(find.text('Welcome to Orbitly'), findsNothing);
  });

  testWidgets('seen is per user', (t) async {
    SharedPreferences.setMockInitialValues(
        <String, Object>{'onboarding_seen_v1_other': true});
    await t.pumpWidget(_host());
    await t.tap(find.text('go'));
    await t.pumpAndSettle();
    expect(find.text('Welcome to Orbitly'), findsOneWidget);
  });

  testWidgets('skip persists', (t) async {
    await t.pumpWidget(_host());
    await t.tap(find.text('go'));
    await t.pumpAndSettle();
    await t.tap(find.text('Skip'));
    await t.pumpAndSettle();
    expect(find.text('Welcome to Orbitly'), findsNothing);
    expect(await OnboardingService.hasSeen('u1'), isTrue);
  });

  testWidgets('done persists after paging through', (t) async {
    await t.pumpWidget(_host());
    await t.tap(find.text('go'));
    await t.pumpAndSettle();
    for (int i = 0; i < 4; i++) {
      await t.tap(find.text('Next'));
      await t.pumpAndSettle();
    }
    expect(find.text('Check in and get help'), findsOneWidget);
    await t.tap(find.text('Done'));
    await t.pumpAndSettle();
    expect(find.text('Check in and get help'), findsNothing);
    expect(await OnboardingService.hasSeen('u1'), isTrue);
  });

  testWidgets('replay works even when already seen', (t) async {
    SharedPreferences.setMockInitialValues(
        <String, Object>{'onboarding_seen_v1_u1': true});
    await t.pumpWidget(_host(
      builder: (c) => Scaffold(
        body: TextButton(
          onPressed: () => OnboardingScreen.show(c, 'u1'),
          child: const Text('replay'),
        ),
      ),
    ));
    await t.tap(find.text('replay'));
    await t.pumpAndSettle();
    expect(find.text('Welcome to Orbitly'), findsOneWidget);
  });

  testWidgets('permission and circle buttons call injected callbacks',
      (t) async {
    final calls = <String>[];
    await t.pumpWidget(_host(
      builder: (c) => OnboardingScreen(
        userId: 'u1',
        requestLocation: () async => calls.add('loc'),
        requestNotifications: () async => calls.add('notif'),
        openBatterySettings: () async => calls.add('batt'),
        openInvite: () => calls.add('invite'),
        openJoin: () => calls.add('join'),
        openCreate: () => calls.add('create'),
      ),
    ));
    Future<void> next() async {
      await t.tap(find.text('Next'));
      await t.pumpAndSettle();
    }

    await next();
    await t.tap(find.text('Allow location'));
    await next();
    await t.tap(find.text('Allow notifications'));
    await t.tap(find.text('Background updates'));
    await next();
    await t.tap(find.text('Create a circle'));
    await t.tap(find.text('Join with a code'));
    await t.tap(find.text('Invite someone'));
    expect(calls, <String>['loc', 'notif', 'batt', 'create', 'join', 'invite']);
  });

  for (final dark in <bool>[false, true]) {
    for (final dir in TextDirection.values) {
      testWidgets('2x text no overflow dark=$dark $dir', (t) async {
        t.view.physicalSize = const Size(360, 640);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        await t.pumpWidget(_host(
          scale: 2,
          dir: dir,
          theme: dark ? buildDarkTheme() : buildLightTheme(),
          builder: (c) => const OnboardingScreen(userId: 'u1'),
        ));
        for (int i = 0; i < 5; i++) {
          await t.pumpAndSettle();
          expect(t.takeException(), isNull);
          if (i < 4) await t.tap(find.text('Next'));
        }
      });
    }
  }
}
