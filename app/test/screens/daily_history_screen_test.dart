import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:openfamily/models/member.dart';
import 'package:openfamily/screens/daily_history_screen.dart';
import 'package:openfamily/services/history_service.dart';

const Member _m = Member(
  id: 'm1',
  name: 'Frank',
  position: null,
  status: MemberStatus.normal,
  batteryPercent: 80,
  address: 'Home',
);

final DateTime _today = DateTime(2026, 10, 27);

MemberHistory _hist(List<HistoryTrailPoint> pts) => MemberHistory(
      userId: 'm1',
      from: _today,
      to: _today.add(const Duration(days: 1)),
      trail: pts,
      visits: const <HistoryVisit>[],
    );

/// 1x1 transparent PNG so no tile network request happens.
class _BlankTiles extends TileProvider {
  static final Uint8List _png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==');

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      MemoryImage(_png);
}

Widget _app(DailyHistoryLoader loader) => MaterialApp(
      home: DailyHistoryScreen(
        member: _m,
        loader: loader,
        today: _today,
        tileProvider: _BlankTiles(),
      ),
    );

void main() {
  testWidgets('empty day shows friendly state and navigation limits',
      (WidgetTester tester) async {
    final List<DateTime> asked = <DateTime>[];
    await tester.pumpWidget(_app((String id, DateTime d) async {
      asked.add(d);
      return _hist(const <HistoryTrailPoint>[]);
    }));
    await tester.pumpAndSettle();
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('No history for this day'), findsOneWidget);
    expect(
        tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.chevron_right))
            .onPressed,
        isNull);

    await tester.tap(find.byTooltip('Previous day'));
    await tester.pumpAndSettle();
    expect(find.text('Yesterday'), findsOneWidget);
    expect(asked.last, DateTime(2026, 10, 26));
    expect(
        tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.chevron_right))
            .onPressed,
        isNotNull);
  });

  testWidgets('scrubbing updates the time and speed card',
      (WidgetTester tester) async {
    final DateTime t0 = DateTime(2026, 10, 27, 8);
    await tester.pumpWidget(_app((String id, DateTime d) async => _hist(
          <HistoryTrailPoint>[
            HistoryTrailPoint(
                position: const LatLng(40, -74),
                ts: t0,
                speedMps: 0,
                batteryPct: 90),
            HistoryTrailPoint(
                position: const LatLng(40.001, -74),
                ts: t0.add(const Duration(minutes: 8)),
                speedMps: 10,
                batteryPct: 88),
          ],
        )));
    await tester.pumpAndSettle();
    // Starts at the end of the day.
    expect(find.text('8:08 AM'), findsWidgets);
    expect(find.textContaining('Battery 88%'), findsOneWidget);

    final Slider slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChanged!(0.5);
    await tester.pump();
    expect(find.text('8:04 AM'), findsWidgets);
    expect(find.textContaining('Battery 90%'), findsOneWidget);
  });

  testWidgets('single point disables the scrubber', (WidgetTester tester) async {
    await tester.pumpWidget(_app((String id, DateTime d) async => _hist(
          <HistoryTrailPoint>[
            HistoryTrailPoint(
                position: const LatLng(40, -74), ts: DateTime(2026, 10, 27, 9)),
          ],
        )));
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNull);
    expect(find.text('Only one location recorded'), findsOneWidget);
  });
}
