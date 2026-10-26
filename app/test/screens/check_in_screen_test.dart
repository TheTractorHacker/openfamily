import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/screens/check_in_screen.dart';
import 'package:openfamily/theme/app_theme.dart';
import 'package:openfamily/widgets/ds/ds.dart';

void main() {
  testWidgets('check-in does not use a fake street address or coordinates',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: CheckInScreen()));
    expect(find.textContaining('123 Maple'), findsNothing);
    expect(find.textContaining(RegExp(r'-?\d+\.\d{3,}')), findsNothing);
  });

  testWidgets('check-in success is not shown when the API fails',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: CheckInScreen()));
    await tester.tap(find.widgetWithText(DsPillButton, 'Check In'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Checked in'), findsNothing);
    expect(find.widgetWithText(DsPillButton, 'Check In'), findsOneWidget);
  });

  testWidgets('check-in form scrolls at 200% text in dark theme',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildDarkTheme(),
        builder: (BuildContext c, Widget? child) => MediaQuery(
          data: MediaQuery.of(c).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: const CheckInScreen(),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Share your location with your family'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.widgetWithText(DsPillButton, 'Check In'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.widgetWithText(DsPillButton, 'Check In'), findsOneWidget);
  });
}
