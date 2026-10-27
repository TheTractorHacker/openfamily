import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/screens/notification_prefs_screen.dart';
import 'package:openfamily/services/api_client.dart';
import 'package:openfamily/services/notification_prefs_service.dart';

class FakePrefsService implements NotificationPrefsService {
  FakePrefsService({this.initial = const NotificationPrefs(), this.loadFail, this.saveFail});

  NotificationPrefs initial;
  Object? loadFail;
  Object? saveFail;
  final List<NotificationPrefs> saved = <NotificationPrefs>[];

  @override
  Future<NotificationPrefs> load(String memberId) async {
    if (loadFail != null) throw loadFail!;
    return initial;
  }

  @override
  Future<NotificationPrefs> save(String memberId, NotificationPrefs p) async {
    if (saveFail != null) throw saveFail!;
    saved.add(p);
    return p;
  }
}

Widget _wrap(Widget child) => MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: child,
    );

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(600, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _screen(FakePrefsService svc) => _wrap(NotificationPrefsScreen(
    memberId: 'm1', memberName: 'Bob', service: svc));

void main() {
  group('NotificationPrefs model', () {
    test('parses defaults and quiet hours', () {
      final NotificationPrefs p = NotificationPrefs.fromJson(<String, dynamic>{
        'muted': false,
        'arrivals': false,
        'quiet_start': '22:00',
        'quiet_end': '07:00',
        'timezone': 'UTC',
      });
      expect(p.arrivals, isFalse);
      expect(p.departures, isTrue);
      expect(p.hasQuietHours, isTrue);
      expect(NotificationPrefs.fromJson(<String, dynamic>{}).lowBattery, isTrue);
    });

    test('toJson sends the phone offset, never a user id', () {
      final Map<String, dynamic> j =
          const NotificationPrefs(muted: true).toJson(timezone: 'UTC+01:00');
      expect(j['muted'], isTrue);
      expect(j['timezone'], 'UTC+01:00');
      expect(j.containsKey('user_id'), isFalse);
    });

    test('offset label', () {
      expect(currentUtcOffsetLabel(const Duration(hours: 5, minutes: 30)),
          'UTC+05:30');
      expect(currentUtcOffsetLabel(const Duration(hours: -8)), 'UTC-08:00');
      expect(currentUtcOffsetLabel(Duration.zero), 'UTC+00:00');
    });
  });

  group('NotificationPrefsScreen', () {
    testWidgets('shows defaults and the SOS guarantee', (tester) async {
      _tall(tester);
      await tester.pumpWidget(_screen(FakePrefsService()));
      await tester.pumpAndSettle();
      expect(find.text('Alerts about Bob'), findsOneWidget);
      expect(find.text('Arrivals'), findsOneWidget);
      expect(find.text('Departures'), findsOneWidget);
      expect(find.text('Low battery'), findsOneWidget);
      expect(find.text('Driving and speeding'), findsOneWidget);
      expect(find.textContaining('SOS alerts are always delivered'),
          findsOneWidget);
    });

    testWidgets('toggling arrivals saves', (tester) async {
      final FakePrefsService svc = FakePrefsService();
      await tester.pumpWidget(_screen(svc));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Arrivals'));
      await tester.pumpAndSettle();
      expect(svc.saved.single.arrivals, isFalse);
      expect(svc.saved.single.departures, isTrue);
    });

    testWidgets('mute-all saves and disables the other toggles',
        (tester) async {
      _tall(tester);
      final FakePrefsService svc = FakePrefsService();
      await tester.pumpWidget(_screen(svc));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mute all except SOS'));
      await tester.pumpAndSettle();
      expect(svc.saved.single.muted, isTrue);
      final int before = svc.saved.length;
      await tester.tap(find.text('Arrivals'));
      await tester.pumpAndSettle();
      expect(svc.saved.length, before, reason: 'disabled while muted');
      // SOS note is still shown.
      expect(find.textContaining('SOS alerts are always delivered'),
          findsOneWidget);
    });

    testWidgets('quiet hours toggle sets a default window', (tester) async {
      final FakePrefsService svc = FakePrefsService();
      await tester.pumpWidget(_screen(svc));
      await tester.pumpAndSettle();
      expect(find.text('From'), findsNothing);
      await tester.tap(find.text('Quiet hours'));
      await tester.pumpAndSettle();
      expect(svc.saved.single.quietStart, '22:00');
      expect(svc.saved.single.quietEnd, '07:00');
      expect(find.text('From'), findsOneWidget);
      expect(find.text('Until'), findsOneWidget);
      await tester.tap(find.text('Quiet hours'));
      await tester.pumpAndSettle();
      expect(svc.saved.last.hasQuietHours, isFalse);
      expect(find.text('From'), findsNothing);
    });

    testWidgets('rolls back and shows the server error on failure',
        (tester) async {
      _tall(tester);
      final FakePrefsService svc = FakePrefsService(
          saveFail: const ApiException(400, 'unknown timezone'));
      await tester.pumpWidget(_screen(svc));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Low battery'));
      await tester.pumpAndSettle();
      expect(find.text('unknown timezone'), findsOneWidget);
      expect(svc.saved, isEmpty);
    });

    testWidgets('load failure shows an error with retry', (tester) async {
      _tall(tester);
      final FakePrefsService svc =
          FakePrefsService(loadFail: const ApiException(404, 'member not found'));
      await tester.pumpWidget(_screen(svc));
      await tester.pumpAndSettle();
      expect(find.text('Arrivals'), findsNothing);
      expect(find.text('Something went wrong'), findsOneWidget);
      svc.loadFail = null;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('Arrivals'), findsOneWidget);
    });

    testWidgets('entry row opens the screen', (tester) async {
      await tester.pumpWidget(_wrap(const Scaffold(
        body: NotificationPrefsEntryButton(memberId: 'm1', memberName: 'Bob'),
      )));
      expect(find.text('Notifications'), findsOneWidget);
      expect(find.text('Choose which alerts you get about Bob'),
          findsOneWidget);
      await tester.tap(find.text('Notifications'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(NotificationPrefsScreen), findsOneWidget);
    });

    testWidgets('survives large text scale', (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
        child: _screen(FakePrefsService()),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
