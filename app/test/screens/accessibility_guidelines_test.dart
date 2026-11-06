import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/screens/login_screen.dart';
import 'package:openfamily/screens/sign_up_screen.dart';
import 'package:openfamily/screens/welcome_screen.dart';
import 'package:openfamily/theme/app_theme.dart';
import 'package:openfamily/widgets/ds/ds.dart';

/// Flutter accessibility guideline checks (issue #14) on the entry flow and
/// the design-system controls, in light and dark themes.
Widget _app(Widget home, ThemeData theme, {double textScale = 1}) =>
    MaterialApp(
      theme: theme,
      builder: (BuildContext c, Widget? child) => MediaQuery(
        data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: home,
    );

Future<void> _guidelines(WidgetTester tester) async {
  await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
  await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
  await expectLater(tester, meetsGuideline(textContrastGuideline));
}

void main() {
  final Map<String, Widget Function()> screens = <String, Widget Function()>{
    'welcome': () => const WelcomeScreen(),
    'login': () => const LoginScreen(),
    'sign up': () => const SignUpScreen(),
  };
  final Map<String, ThemeData Function()> themes = <String, ThemeData Function()>{
    'light': buildLightTheme,
    'dark': buildDarkTheme,
  };

  for (final MapEntry<String, Widget Function()> s in screens.entries) {
    for (final MapEntry<String, ThemeData Function()> t in themes.entries) {
      testWidgets('${s.key} (${t.key}) meets tap-target, label and contrast '
          'guidelines', (WidgetTester tester) async {
        final SemanticsHandle handle = tester.ensureSemantics();
        await tester.pumpWidget(_app(s.value(), t.value()));
        await tester.pumpAndSettle();
        await _guidelines(tester);
        handle.dispose();
      });
    }
  }

  testWidgets('login and sign up survive 200% text without overflow',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final Widget home in <Widget>[const LoginScreen(), const SignUpScreen()]) {
      await tester.pumpWidget(_app(home, buildLightTheme(), textScale: 2));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
  });

  for (final MapEntry<String, ThemeData Function()> t in themes.entries) {
    testWidgets('design-system controls (${t.key}) meet the guidelines',
        (WidgetTester tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await tester.pumpWidget(_app(
        Scaffold(
          body: ListView(
            children: <Widget>[
              DsPillButton(label: 'Check in', onPressed: () {}),
              DsMapButton(icon: Icons.layers, tooltip: 'Layers', onPressed: () {}),
            ],
          ),
        ),
        t.value(),
      ));
      await tester.pumpAndSettle();
      await _guidelines(tester);
      handle.dispose();
    });
  }
}
