import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/screens/login_screen.dart';
import 'package:openfamily/screens/sign_up_screen.dart';
import 'package:openfamily/screens/welcome_screen.dart';
import 'package:openfamily/theme/app_theme.dart';

Widget _app(ThemeData theme, {double textScale = 1}) => MaterialApp(
      theme: theme,
      builder: (BuildContext c, Widget? child) => MediaQuery(
        data: MediaQuery.of(c).copyWith(
          textScaler: TextScaler.linear(textScale),
        ),
        child: child!,
      ),
      home: const WelcomeScreen(),
    );

void main() {
  testWidgets('shows value-prop pages and swipes between them',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app(buildLightTheme()));
    expect(find.text('Know where your family is'), findsOneWidget);
    await tester.fling(find.byType(PageView), const Offset(-400, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('Gentle heads-ups'), findsOneWidget);
  });

  testWidgets('Create account and Sign in open the auth screens',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app(buildDarkTheme()));
    await tester.tap(find.text('Create account'));
    await tester.pumpAndSettle();
    expect(find.byType(SignUpScreen), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.byType(LoginScreen), findsOneWidget);
  });

  testWidgets('no overflow at 200% text on a small phone',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(buildLightTheme(), textScale: 2));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
