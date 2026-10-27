import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/trip_report.dart';
import 'package:openfamily/services/speed_units.dart';
import 'package:openfamily/theme/app_theme.dart';
import 'package:openfamily/widgets/driving_page_widgets.dart';

void main() {
  test('niceAxisMax rounds up to 1/2/5/10', () {
    expect(niceAxisMax(83), 100);
    expect(niceAxisMax(52), 100);
    expect(niceAxisMax(0), 1);
    expect(niceAxisMax(7), 10);
  });

  testWidgets('bars scale against axis, value labels shown, tap selects', (
    WidgetTester t,
  ) async {
    final DateTime mon = DateTime(2026, 10, 26);
    DateTime? picked;
    // 80467.2 m = 50 mi, 160934 m = 100 mi.
    final List<ReportDay> days = <ReportDay>[
      ReportDay(date: mon, drives: 1, distanceM: 80467.2),
      ReportDay(date: mon.add(const Duration(days: 1)), drives: 2, distanceM: 160934.4),
      for (int i = 2; i < 7; i++) ReportDay(date: mon.add(Duration(days: i))),
    ];
    await t.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: Scaffold(
          body: DrivingDaysChart(
            days: days,
            units: UnitSystem.imperial,
            today: mon.add(const Duration(days: 1)),
            selected: null,
            onSelect: (DateTime? d) => picked = d,
          ),
        ),
      ),
    );
    expect(find.text('100 mi'), findsOneWidget);
    expect(find.text('50'), findsWidgets);
    // Value labels above the drawn bars only.
    expect(find.byKey(ValueKey<String>('bar-value-${mon.toIso8601String()}')), findsOneWidget);
    expect(find.text('100'), findsOneWidget);
    // Bar heights: the 50-mi bar is half the 100-mi bar (= plotHeight).
    final Iterable<RenderBox> boxes = t
        .renderObjectList<RenderBox>(find.byType(FractionallySizedBox))
        .where((RenderBox b) => b.size.height < DrivingDaysChart.plotHeight + 0.1);
    final List<double> hs = boxes.map((RenderBox b) => b.size.height).toList()..sort();
    expect(hs.last, closeTo(DrivingDaysChart.plotHeight, 0.5));
    expect(hs.where((double h) => (h - DrivingDaysChart.plotHeight / 2).abs() < 0.5), isNotEmpty);
    // Touch target is at least 48dp tall.
    expect(t.getSize(find.byType(InkWell).first).height, greaterThanOrEqualTo(48));
    await t.tap(find.byType(InkWell).first);
    expect(picked, mon);
  });
}
