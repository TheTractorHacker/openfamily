import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/security_models.dart';
import 'package:openfamily/screens/sessions_screen.dart';
import 'package:openfamily/screens/settings_screen.dart';
import 'package:openfamily/widgets/ds/ds.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_security_api.dart';

Widget _wrap(Widget child, {double scale = 1}) => MaterialApp(
      home: MediaQuery.withClampedTextScaling(minScaleFactor: scale, maxScaleFactor: scale, child: child),
    );

void _size(WidgetTester t, double w, double h) {
  t.view.physicalSize = Size(w, h);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
}

/// Every settings row keeps its own text to one short line; the rest lives behind the (i).
void expectShortSubtitles(WidgetTester t, {int max = 80}) {
  for (final DsListRow r in t.widgetList<DsListRow>(find.byType(DsListRow))) {
    expect(r.subtitle == null || r.subtitle!.length <= max, isTrue, reason: 'long subtitle on "${r.title}": ${r.subtitle}');
  }
  for (final DsToggleRow r in t.widgetList<DsToggleRow>(find.byType(DsToggleRow))) {
    expect(r.subtitle == null || r.subtitle!.length <= max, isTrue, reason: 'long subtitle on "${r.title}": ${r.subtitle}');
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('InfoHint', () {
    testWidgets('opens a sheet with the long text, is labelled and a 48 dp target', (t) async {
      await t.pumpWidget(_wrap(const Scaffold(body: Center(child: InfoHint(title: 'Keys', body: 'The long explanation.')))));
      final Size s = t.getSize(find.byKey(const Key('info-hint')));
      expect(s.width, greaterThanOrEqualTo(48));
      expect(s.height, greaterThanOrEqualTo(48));
      expect(find.byTooltip('More about Keys'), findsOneWidget);
      expect(find.text('The long explanation.'), findsNothing);
      await t.tap(find.byKey(const Key('info-hint')));
      await t.pumpAndSettle();
      expect(find.text('The long explanation.'), findsOneWidget);
      expect(find.text('Keys'), findsOneWidget);
    });

    testWidgets('a row with info shows only the short line until (i) is tapped', (t) async {
      await t.pumpWidget(_wrap(const Scaffold(
          body: DsListRow(title: 'Server', subtitle: 'Short line', info: 'Long long long explanation text.'))));
      expect(find.text('Short line'), findsOneWidget);
      expect(find.text('Long long long explanation text.'), findsNothing);
      await t.tap(find.byKey(const Key('info-hint')));
      await t.pumpAndSettle();
      expect(find.text('Long long long explanation text.'), findsOneWidget);
    });
  });

  group('Sessions screen', () {
    final DateTime now = DateTime.now();
    SessionInfo s(String id, String ua, int daysAgo) => SessionInfo(
        id: id,
        createdAt: now.subtract(Duration(days: daysAgo + 1)),
        lastUsedAt: now.subtract(Duration(days: daysAgo)),
        expiresAt: now.add(const Duration(days: 20)),
        userAgent: ua);

    testWidgets('marks This device, uses a desktop icon for browsers, folds old sessions', (t) async {
      _size(t, 360, 1400);
      final FakeSecurityApi api = FakeSecurityApi(sessions: <SessionInfo>[
        s('a', 'Dart/3.5 (dart:io)', 0),
        s('b', 'Mozilla/5.0 (Windows NT 10.0) Chrome/120', 1),
        s('c', 'Mozilla/5.0 (Windows NT 10.0) Chrome/119', 11),
        s('d', 'Dart/3.5 (dart:io)', 12),
      ])
        ..currentId = 'a';
      await t.pumpWidget(_wrap(SessionsScreen(api: api), scale: 1.5));
      await t.pumpAndSettle();
      expect(find.text('This device'), findsOneWidget);
      expect(find.byIcon(Icons.desktop_windows_outlined), findsOneWidget); // the recent browser
      expect(find.byKey(const Key('session-c')), findsNothing, reason: 'older sessions are collapsed');
      expect(find.text('Older sessions (2)'), findsOneWidget);
      await t.tap(find.text('Older sessions (2)'));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('session-c')), findsOneWidget);
      await t.dragUntilVisible(find.text('Log out everywhere'), find.byType(ListView).first, const Offset(0, -300));
      expect(find.text('Sign out other sessions'), findsOneWidget);
      expect(find.text('Log out everywhere'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('Sign out other sessions keeps the current one', (t) async {
      _size(t, 360, 1400);
      final FakeSecurityApi api = FakeSecurityApi(sessions: <SessionInfo>[
        s('a', 'Dart/3.5 (dart:io)', 0),
        s('b', 'Mozilla/5.0 Chrome/120', 1),
      ])
        ..currentId = 'a';
      await t.pumpWidget(_wrap(SessionsScreen(api: api)));
      await t.pumpAndSettle();
      await t.tap(find.text('Sign out other sessions'));
      await t.pumpAndSettle();
      await t.tap(find.text('Sign out others'));
      await t.pumpAndSettle();
      expect(api.calls.where((String c) => c == 'revokeSession').length, 1);
      expect(api.lastArgs['id'] ?? 'b', 'b');
    });

    testWidgets('unknown current session (older server): no badge, no bulk button', (t) async {
      _size(t, 360, 1400);
      final FakeSecurityApi api = FakeSecurityApi(sessions: <SessionInfo>[s('a', 'Dart/3.5', 0), s('b', 'Chrome', 1)]);
      await t.pumpWidget(_wrap(SessionsScreen(api: api)));
      await t.pumpAndSettle();
      expect(find.text('This device'), findsNothing);
      expect(find.text('Sign out other sessions'), findsNothing);
    });
  });

  group('Settings home', () {
    testWidgets('grouped sections, short lines, search, no overflow at 360 dp and 1.5x text', (t) async {
      _size(t, 360, 5000);
      await t.pumpWidget(_wrap(const SettingsScreen(), scale: 1.5));
      await t.pump(const Duration(milliseconds: 300));
      for (final String h in <String>['Account', 'Sharing & privacy', 'Notifications', 'Driving & safety', 'Server & data', 'Phone health', 'About']) {
        expect(find.text(h.toUpperCase()), findsOneWidget, reason: h);
      }
      expectShortSubtitles(t);
      expect(t.takeException(), isNull);

      await t.enterText(find.byKey(const Key('settings-search')), 'driving');
      await t.pump();
      expect(find.text('Driving detection'), findsOneWidget);
      expect(find.text('Profile'), findsNothing);
      expect(find.text('ACCOUNT'), findsNothing);
    });
  });
}
