import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:openfamily/models/place.dart';
import 'package:openfamily/screens/notification_prefs_screen.dart';
import 'package:openfamily/screens/place_alert_rules_screen.dart';
import 'package:openfamily/services/api_client.dart';
import 'package:openfamily/services/notification_prefs_service.dart';
import 'package:openfamily/services/place_alert_rules_service.dart';

class FakeRules implements PlaceAlertRulesService {
  FakeRules({this.saveFail, QuietHours? q}) : quiet = q ?? const QuietHours();
  Object? saveFail;
  QuietHours quiet;
  final Map<String, PlaceAlertMode> stored = <String, PlaceAlertMode>{
    'p2': PlaceAlertMode.departures,
  };
  final List<String> calls = <String>[];

  @override
  Future<List<Place>> places() async => const <Place>[
        Place(
            id: 'p1',
            name: 'Home',
            icon: Icons.home,
            address: '',
            position: LatLng(0, 0),
            radiusMeters: 100),
        Place(
            id: 'p2',
            name: 'School',
            icon: Icons.school,
            address: '',
            position: LatLng(0, 0),
            radiusMeters: 100),
      ];

  @override
  Future<Map<String, PlaceAlertMode>> rules(String memberId) async => stored;

  @override
  Future<void> setRule(String m, String p, PlaceAlertMode mode) async {
    if (saveFail != null) throw saveFail!;
    calls.add('$p=${mode.wire}');
  }

  @override
  Future<QuietHours> quietHours() async => quiet;

  @override
  Future<QuietHours> saveQuietHours(QuietHours q) async {
    if (saveFail != null) throw saveFail!;
    return quiet = q;
  }
}

class _Prefs implements NotificationPrefsService {
  @override
  Future<NotificationPrefs> load(String id) async => const NotificationPrefs();
  @override
  Future<NotificationPrefs> save(String id, NotificationPrefs p) async => p;
}

Widget _wrap(Widget c) =>
    MaterialApp(theme: ThemeData(brightness: Brightness.dark), home: c);

void _tall(WidgetTester t) {
  t.view.physicalSize = const Size(600, 2400);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
}

void main() {
  test('mode parsing falls back to both', () {
    expect(PlaceAlertMode.parse('off'), PlaceAlertMode.off);
    expect(PlaceAlertMode.parse(null), PlaceAlertMode.both);
    expect(PlaceAlertMode.parse('???'), PlaceAlertMode.both);
  });

  testWidgets('lists places with stored rule and saves a change',
      (tester) async {
    _tall(tester);
    final FakeRules svc = FakeRules();
    await tester.pumpWidget(_wrap(
        PlaceAlertRulesScreen(memberId: 'm', memberName: 'Bob', service: svc)));
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('School'), findsOneWidget);
    expect(find.text('Departures only'), findsOneWidget);
    expect(find.text('Both'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('rule-p1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Off').last);
    await tester.pumpAndSettle();
    expect(svc.calls, <String>['p1=off']);
  });

  testWidgets('rolls back and shows error when save fails', (tester) async {
    _tall(tester);
    final FakeRules svc =
        FakeRules(saveFail: const ApiException(404, 'place not found'));
    await tester.pumpWidget(_wrap(
        PlaceAlertRulesScreen(memberId: 'm', memberName: 'Bob', service: svc)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('rule-p1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Arrivals only').last);
    await tester.pumpAndSettle();
    expect(find.text('place not found'), findsOneWidget);
    expect(find.text('Arrivals only'), findsNothing);
  });

  testWidgets('member prefs screen links to per-place rules', (tester) async {
    _tall(tester);
    await tester.pumpWidget(_wrap(NotificationPrefsScreen(
        memberId: 'm',
        memberName: 'Bob',
        service: _Prefs(),
        rulesService: FakeRules())));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose by place'));
    await tester.pumpAndSettle();
    expect(find.text('Places for Bob'), findsOneWidget);
  });

  testWidgets('quiet hours section toggles and saves default window',
      (tester) async {
    _tall(tester);
    final FakeRules svc = FakeRules();
    await tester.pumpWidget(_wrap(Scaffold(body: QuietHoursSection(service: svc))));
    await tester.pumpAndSettle();
    expect(find.text('From'), findsNothing);
    await tester.tap(find.text('Quiet hours'));
    await tester.pumpAndSettle();
    expect(svc.quiet.start, '22:00');
    expect(svc.quiet.end, '07:00');
    expect(find.text('From'), findsOneWidget);
    await tester.tap(find.text('Quiet hours'));
    await tester.pumpAndSettle();
    expect(svc.quiet.enabled, isFalse);
  });

  testWidgets('quiet hours save failure rolls back', (tester) async {
    _tall(tester);
    final FakeRules svc =
        FakeRules(saveFail: const ApiException(400, 'unknown timezone'));
    await tester.pumpWidget(_wrap(Scaffold(body: QuietHoursSection(service: svc))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Quiet hours'));
    await tester.pumpAndSettle();
    expect(find.text('unknown timezone'), findsOneWidget);
    expect(find.text('From'), findsNothing);
  });
}
