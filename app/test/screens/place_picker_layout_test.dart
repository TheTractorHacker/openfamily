import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/screens/place_picker_screen.dart';

Future<void> _pump(
  WidgetTester t, {
  double keyboard = 0,
  double textScale = 1,
}) async {
  t.view.physicalSize = const Size(360, 640);
  t.view.devicePixelRatio = 1;
  t.view.viewInsets = FakeViewPadding(bottom: keyboard);
  t.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(() {
    t.view.reset();
    t.platformDispatcher.clearAllTestValues();
  });
  await t.pumpWidget(
    const MaterialApp(
      home: PlacePickerScreen(placeName: '', icon: Icons.place),
    ),
  );
  await t.pump(const Duration(milliseconds: 50));
}

void _expectNoOverlapAndReachable(WidgetTester t) {
  final Rect save = t.getRect(find.text('Save place'));
  final Finder chip = find.byKey(const ValueKey<String>('radius-1609'));
  final Rect viewport = t.getRect(find.byType(SingleChildScrollView).first);
  expect(chip, findsOneWidget);
  expect(save.top, greaterThanOrEqualTo(viewport.bottom - 1));
}

Future<void> _expectChipsHittable(WidgetTester t) async {
  for (final String k in <String>['76', '152', '305', '1609', '3219']) {
    final Finder chip = find.byKey(ValueKey<String>('radius-$k'));
    await t.ensureVisible(chip);
    await t.pump();
    final Rect r = t.getRect(chip);
    final Rect save = t.getRect(find.text('Save place'));
    expect(r.overlaps(save), isFalse, reason: 'chip $k under Save button');
    expect(t.getRect(find.byType(Scaffold).first).contains(r.center), isTrue);
  }
  await t.tap(find.byKey(const ValueKey<String>('radius-1609')));
  await t.pump();
  expect(find.text('1 mi'), findsWidgets);
}

void main() {
  for (final double scale in <double>[1, 2]) {
    testWidgets('radius chips reachable, no overlap, keyboard closed x$scale', (
      WidgetTester t,
    ) async {
      await _pump(t, textScale: scale);
      _expectNoOverlapAndReachable(t);
      await _expectChipsHittable(t);
    });

    testWidgets('keyboard open x$scale: map shrinks, form usable', (
      WidgetTester t,
    ) async {
      await _pump(t, textScale: scale);
      final double closedMap = t.getSize(find.byType(FlutterMap)).height;
      await _pump(t, keyboard: 280, textScale: scale);
      final Finder name = find.widgetWithText(TextField, 'Name');
      expect(name, findsOneWidget);
      final double openMap = t.getSize(find.byType(FlutterMap)).height;
      expect(openMap, lessThan(closedMap * 0.6));
      expect(openMap / 640, lessThan(0.25)); // was ~45% of the screen
      _expectNoOverlapAndReachable(t);
      await _expectChipsHittable(t);
    });
  }
}
