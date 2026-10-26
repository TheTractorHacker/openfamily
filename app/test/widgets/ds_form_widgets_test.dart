import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/theme/app_theme.dart';
import 'package:openfamily/widgets/ds/ds.dart';
import 'package:openfamily/widgets/onboarding_step_indicator.dart';

Widget _app(Widget home, {double scale = 1, bool reduceMotion = false}) =>
    MaterialApp(
      theme: buildLightTheme(),
      builder: (BuildContext c, Widget? child) => MediaQuery(
        data: MediaQuery.of(c).copyWith(
          textScaler: TextScaler.linear(scale),
          disableAnimations: reduceMotion,
        ),
        child: child!,
      ),
      home: home,
    );

void main() {
  testWidgets('DsPage pins actions at normal text and scrolls them at 200%',
      (WidgetTester t) async {
    t.view.physicalSize = const Size(360, 640);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    Widget page() => DsPage(
          title: 'T',
          actions: <Widget>[DsPillButton(label: 'Go', onPressed: () {})],
          children: const <Widget>[DsHeading('Hello', subtitle: 'World')],
        );
    await t.pumpWidget(_app(page()));
    expect(find.text('Go'), findsOneWidget);
    expect(find.descendant(of: find.byType(ListView), matching: find.text('Go')),
        findsNothing);
    await t.pumpWidget(_app(page(), scale: 2));
    expect(find.descendant(of: find.byType(ListView), matching: find.text('Go')),
        findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('DsPillButton is at least 48dp and centres when stretched',
      (WidgetTester t) async {
    await t.pumpWidget(_app(Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[DsPillButton(label: 'Wide', onPressed: () {})],
      ),
    )));
    expect(t.getSize(find.byType(DsPillButton)).height, greaterThanOrEqualTo(48));
    final double textCenter = t.getCenter(find.text('Wide')).dx;
    expect(textCenter, closeTo(t.getCenter(find.byType(DsPillButton)).dx, 1));
  });

  testWidgets('DsMessage announces tone in words and as a live region',
      (WidgetTester t) async {
    final SemanticsHandle h = t.ensureSemantics();
    await t.pumpWidget(_app(const Scaffold(body: DsMessage('Bad code'))));
    expect(find.bySemanticsLabel('Error: Bad code'), findsOneWidget);
    h.dispose();
  });

  testWidgets('DsSkeleton holds still when animations are disabled',
      (WidgetTester t) async {
    await t.pumpWidget(_app(
      const Scaffold(body: DsSkeletonList(rows: 2)),
      reduceMotion: true,
    ));
    // Would never settle if a repeating animation were running.
    await t.pumpAndSettle(const Duration(seconds: 1));
    expect(t.hasRunningAnimations, isFalse);
  });

  testWidgets('step indicator states progress in words', (WidgetTester t) async {
    await t.pumpWidget(_app(Scaffold(
      appBar: AppBar(
        bottom: const OnboardingStepIndicator(currentStep: 2, totalSteps: 6),
      ),
    )));
    expect(find.text('Step 2 of 6'), findsOneWidget);
  });

  testWidgets('DsOptionCard is one button with a 48dp+ target',
      (WidgetTester t) async {
    int taps = 0;
    await t.pumpWidget(_app(Scaffold(
      body: DsOptionCard(
        icon: Icons.add,
        title: 'Create',
        subtitle: 'Start fresh',
        onTap: () => taps++,
      ),
    )));
    await t.tap(find.text('Create'));
    expect(taps, 1);
    expect(t.getSize(find.byType(DsOptionCard)).height, greaterThanOrEqualTo(72));
  });
}
