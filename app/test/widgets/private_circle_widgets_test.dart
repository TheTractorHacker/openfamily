import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/circle.dart';
import 'package:openfamily/screens/weekly_summary_screen.dart';
import 'package:openfamily/services/e2ee/private_runtime.dart';
import 'package:openfamily/services/weekly_summary_service.dart';
import 'package:openfamily/theme/app_theme.dart';
import 'package:openfamily/widgets/location_tab_view.dart';
import 'package:openfamily/widgets/private_circle_widgets.dart';

import '../support/location_fixtures.dart';

class _Api implements WeeklySummaryApi {
  int calls = 0;
  @override
  Future<WeeklySummary> load() async {
    calls++;
    return WeeklySummary.fromJson(<String, dynamic>{'members': <dynamic>[]});
  }
}

Widget _wrap(Widget child) => MaterialApp(theme: buildLightTheme(), home: child);

void main() {
  tearDown(() => PrivateRuntime.primaryPrivate.value = false);

  group('circle model', () {
    test('parses the E2EE mode and defaults to off', () {
      expect(Circle.fromJson(<String, dynamic>{'id': 'a', 'e2ee_mode': 'private', 'e2ee_epoch': 3}).isPrivate, isTrue);
      expect(Circle.fromJson(<String, dynamic>{'id': 'a', 'e2ee_epoch': 3}).isPrivate, isFalse);
      expect(Circle.fromJson(<String, dynamic>{'id': 'a', 'e2ee_mode': 'weird'}).e2eeMode, 'off');
      expect(Circle.fromJson(<String, dynamic>{'id': 'a', 'e2ee_mode': 'private', 'e2ee_epoch': 3}).e2eeEpoch, 3);
    });
  });

  group('indicator and placeholders', () {
    testWidgets('the badge says end-to-end encrypted', (WidgetTester t) async {
      await t.pumpWidget(_wrap(const Scaffold(body: PrivateCircleBadge())));
      expect(find.text('End-to-end encrypted'), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    });

    for (final PrivateFeature f in PrivateFeature.values) {
      testWidgets('${f.title} has an explicit not-available state', (WidgetTester t) async {
        await t.pumpWidget(_wrap(Scaffold(body: NotAvailableInPrivate(feature: f, circleName: 'Family'))));
        expect(find.text('${f.title} is not available in Private circles'), findsOneWidget);
        expect(find.textContaining(f.explanation), findsOneWidget);
        expect(find.textContaining('Family'), findsOneWidget);
      });
    }

    testWidgets('the map header shows the badge only for a private circle', (WidgetTester t) async {
      Future<void> pump(List<Circle> circles) async {
        await t.pumpWidget(MaterialApp(
          theme: buildLightTheme(),
          home: LocationTabView(
            map: const FakeMap(),
            circleName: 'Frank Family',
            circles: circles,
            members: const [],
            selfId: 'me',
            placesLoader: fakePlaces,
          ),
        ));
        await t.pump();
      }

      await pump(kCircles);
      expect(find.byKey(const ValueKey<String>('private-circle-badge')), findsNothing);
      await pump(<Circle>[kCircles.first.copyWith(e2eeMode: 'private')]);
      expect(find.byKey(const ValueKey<String>('private-circle-badge')), findsOneWidget);
    });
  });

  group('server-computed screens', () {
    testWidgets('normal circle: the weekly summary loads as before', (WidgetTester t) async {
      final _Api api = _Api();
      await t.pumpWidget(_wrap(WeeklySummaryScreen(api: api)));
      await t.pump();
      expect(api.calls, 1);
      expect(find.byKey(const ValueKey<String>('not-available-title')), findsNothing);
    });

    testWidgets('private primary circle: explicit placeholder, no request is made', (WidgetTester t) async {
      PrivateRuntime.primaryPrivate.value = true;
      final _Api api = _Api();
      await t.pumpWidget(_wrap(WeeklySummaryScreen(api: api)));
      await t.pump();
      expect(find.text('Weekly summary is not available in Private circles'), findsOneWidget);
      expect(api.calls, 0);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('the gate reacts when the circle turns private', (WidgetTester t) async {
      await t.pumpWidget(_wrap(PrivateFeatureGate(
          feature: PrivateFeature.trips, builder: (_) => const Scaffold(body: Text('trips here')))));
      expect(find.text('trips here'), findsOneWidget);
      PrivateRuntime.primaryPrivate.value = true;
      await t.pump();
      expect(find.text('trips here'), findsNothing);
      expect(find.text('Trips is not available in Private circles'), findsOneWidget);
    });
  });
}
