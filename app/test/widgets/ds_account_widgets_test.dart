import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/screens/circles_screen.dart';
import 'package:openfamily/screens/issue_reset_code_screen.dart';
import 'package:openfamily/screens/privacy_policy_screen.dart';
import 'package:openfamily/screens/sessions_screen.dart';
import 'package:openfamily/screens/two_factor_screen.dart';
import 'package:openfamily/theme/app_theme.dart';
import 'package:openfamily/widgets/ds/ds.dart';

import '../screens/circles_screens_test.dart' show FakeCircleService;
import '../support/fake_security_api.dart';

Widget _wrap(Widget child, {double scale = 1, ThemeData? theme}) => MaterialApp(
      theme: theme ?? buildLightTheme(),
      builder: (BuildContext c, Widget? w) => MediaQuery(
        data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
        child: w!,
      ),
      home: child,
    );

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  group('showDsConfirm', () {
    Future<bool?> open(WidgetTester tester, {required bool destructive}) async {
      bool? result;
      await tester.pumpWidget(_wrap(Builder(
        builder: (BuildContext c) => TextButton(
          onPressed: () async => result = await showDsConfirm(
            c,
            title: 'Delete it?',
            message: 'This cannot be undone.',
            confirmLabel: 'Delete',
            destructive: destructive,
          ),
          child: const Text('go'),
        ),
      )));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('destructive uses the danger pill and a warning icon',
        (tester) async {
      await open(tester, destructive: true);
      final DsPillButton confirm =
          tester.widget(find.widgetWithText(DsPillButton, 'Delete'));
      expect(confirm.style, DsPillStyle.danger);
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
      expect(find.text('This cannot be undone.'), findsOneWidget);
    });

    testWidgets('cancel resolves false, confirm resolves true', (tester) async {
      bool? result;
      await tester.pumpWidget(_wrap(Builder(
        builder: (BuildContext c) => TextButton(
          onPressed: () async => result =
              await showDsConfirm(c, title: 't', message: 'm', confirmLabel: 'Yes'),
          child: const Text('go'),
        ),
      )));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(result, isFalse);
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Yes'));
      await tester.pumpAndSettle();
      expect(result, isTrue);
    });

    testWidgets('holds up at 200% text on a small screen', (tester) async {
      tester.view.physicalSize = const Size(400, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(_wrap(
        Builder(
          builder: (BuildContext c) => TextButton(
            onPressed: () => showDsConfirm(
              c,
              title: 'Log out everywhere?',
              message: 'Every device, including this one, will be signed out '
                  'and will need to sign in again.',
              confirmLabel: 'Log out everywhere',
              destructive: true,
            ),
            child: const Text('go'),
          ),
        ),
        scale: 2,
      ));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Log out everywhere'), findsWidgets);
    });
  });

  group('DsChoiceSetting', () {
    Widget build(double scale, ValueChanged<int> on) => _wrap(
          Scaffold(
            body: SingleChildScrollView(
              child: DsChoiceSetting<int>(
                title: 'Theme',
                description: 'Following this device.',
                options: const <DsChoice<int>>[
                  DsChoice<int>(0, 'System', icon: Icons.brightness_auto),
                  DsChoice<int>(1, 'Light'),
                  DsChoice<int>(2, 'Dark'),
                ],
                selected: 1,
                onChanged: on,
              ),
            ),
          ),
          scale: scale,
        );

    testWidgets('segmented at normal text', (tester) async {
      int? picked;
      await tester.pumpWidget(build(1, (int v) => picked = v));
      expect(find.byType(SegmentedButton<int>), findsOneWidget);
      await tester.tap(find.text('Dark'));
      expect(picked, 2);
    });

    testWidgets('rows with a check and words at large text', (tester) async {
      int? picked;
      await tester.pumpWidget(build(2, (int v) => picked = v));
      expect(find.byType(SegmentedButton<int>), findsNothing);
      expect(find.byIcon(Icons.check), findsOneWidget);
      await tester.tap(find.text('Dark'));
      expect(picked, 2);
      expect(tester.takeException(), isNull);
    });
  });

  group('account screens states', () {
    testWidgets('sessions with none shows the empty state', (tester) async {
      _tall(tester);
      await tester.pumpWidget(_wrap(SessionsScreen(api: FakeSecurityApi())));
      await tester.pumpAndSettle();
      expect(find.text('No active sessions'), findsOneWidget);
      expect(find.text('Log out everywhere'), findsOneWidget);
    });

    testWidgets('sessions log out cancel does not call the server',
        (tester) async {
      _tall(tester);
      final FakeSecurityApi api = FakeSecurityApi();
      await tester.pumpWidget(_wrap(SessionsScreen(api: api)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Log out everywhere'));
      await tester.pumpAndSettle();
      expect(find.text('Log out everywhere?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(api.calls, isNot(contains('logoutAll')));
    });

    testWidgets('issue reset code shows loading skeleton then members',
        (tester) async {
      _tall(tester);
      await tester.pumpWidget(
          _wrap(IssueResetCodeScreen(selfId: 'me', api: FakeSecurityApi())));
      expect(find.byType(DsSkeletonList), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('Kid'), findsOneWidget);
    });

    testWidgets('two-factor verify step shows step indicator', (tester) async {
      _tall(tester);
      await tester.pumpWidget(
          _wrap(TwoFactorScreen(enabled: false, api: FakeSecurityApi())));
      expect(find.text('Step 1 of 3'), findsOneWidget);
    });

    testWidgets('privacy policy scrolls at 200% text', (tester) async {
      await tester.pumpWidget(_wrap(const PrivacyPolicyScreen(), scale: 2));
      expect(find.text('OpenFamily privacy policy'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('circles FAB (dark theme ring)', () {
    test('theme draws no elevation shadow under the FAB', () {
      for (final ThemeData t in <ThemeData>[buildLightTheme(), buildDarkTheme()]) {
        final FloatingActionButtonThemeData f = t.floatingActionButtonTheme;
        expect(f.elevation, 0);
        expect(f.highlightElevation, 0);
        expect(f.focusElevation, 0);
        expect(f.hoverElevation, 0);
      }
    });

    testWidgets('New circle button renders with zero elevation in dark',
        (tester) async {
      await tester.pumpWidget(_wrap(
        CirclesScreen(service: FakeCircleService()),
        theme: buildDarkTheme(),
      ));
      await tester.pumpAndSettle();
      final Material m = tester.widget(find.descendant(
        of: find.byType(FloatingActionButton),
        matching: find.byType(Material),
      ).first);
      expect(m.elevation, 0);
    });
  });
}
