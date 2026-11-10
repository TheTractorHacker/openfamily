// "I scroll down then back up and Quiet hours pops in": the sections of the
// Notifications page are built once and stay, they never fetch again on the
// way back, and Quiet hours has its row (same height) from the first frame.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openfamily/screens/notification_settings_screen.dart';
import 'package:openfamily/services/api_client.dart';
import 'package:openfamily/services/server_config.dart';
import 'package:openfamily/services/token_storage.dart';
import 'package:openfamily/widgets/ds/ds.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/size_matrix.dart';

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: <String, String>{'content-type': 'application/json'});

void main() {
  setUp(() async {
    TokenStorage.resetForTest();
    FlutterSecureStorage.setMockInitialValues(<String, String>{'access_token_v2': 'a', 'refresh_token_v2': 'r'});
    SharedPreferences.setMockInitialValues(<String, Object>{'wb_api_base_url': 'https://example.test'});
    await ServerConfig.instance.load();
    ApiClient.invalidateConfig();
  });

  /// Runs [body] against a server that answers the Notifications requests;
  /// [calls] counts them per path. [delay] makes every answer slow.
  Future<void> withServer(Map<String, int> calls, Duration delay, Future<void> Function() body,
      {int quietStatus = 200, bool quietOn = true}) {
    return http.runWithClient(body, () => MockClient((http.Request r) async {
          calls[r.url.path] = (calls[r.url.path] ?? 0) + 1;
          if (delay > Duration.zero) await Future<void>.delayed(delay);
          switch (r.url.path) {
            case '/me/notifications':
              return _json(<String, Object?>{});
            case '/me/quiet-hours':
              if (quietStatus != 200) return _json(<String, String>{'error': 'boom'}, quietStatus);
              return _json(<String, Object?>{'quiet_start': quietOn ? '22:00' : null, 'quiet_end': quietOn ? '07:00' : null});
            case '/circles':
              return _json(<Object>[]);
            case '/me/arrival-watch':
              return _json(<String, Object>{'places': <Object>[], 'watches': <Object>[]});
          }
          return _json(<String, String>{'error': 'not found'}, 404);
        }));
  }

  testWidgets('scrolling down and back up keeps Quiet hours and does not fetch it again', (WidgetTester t) async {
    setWindow(t, const Size(344, 640));
    final Map<String, int> calls = <String, int>{};
    await withServer(calls, Duration.zero, () async {
      await t.pumpWidget(scaled(const NotificationSettingsScreen(), 1));
      await t.pumpAndSettle();
      expect(find.text('Quiet hours'), findsOneWidget);
      expect(calls['/me/quiet-hours'], 1);

      final Finder scroller = find.byType(SingleChildScrollView);
      await t.drag(scroller, const Offset(0, -3000));
      await t.pumpAndSettle();
      expect(find.text('Show names in notifications'), findsOneWidget);
      await t.drag(scroller, const Offset(0, 3000));
      // No pump of any length between the scroll and the check.
      expect(find.text('Quiet hours'), findsOneWidget);
      await t.pumpAndSettle();
      expect(find.text('Quiet hours'), findsOneWidget);
      expect(calls['/me/quiet-hours'], 1, reason: 'the section is kept, not rebuilt and refetched');
      expect(calls['/me/arrival-watch'], 1);
      expect(t.takeException(), isNull);
    });
  });

  testWidgets('Quiet hours is on screen before its answer arrives, at the same height', (WidgetTester t) async {
    setWindow(t, const Size(344, 882));
    final Map<String, int> calls = <String, int>{};
    await withServer(calls, const Duration(milliseconds: 400), quietOn: false, () async {
      await t.pumpWidget(scaled(const NotificationSettingsScreen(), 1));
      // The preferences answer first; the page appears after that.
      await t.pump(const Duration(milliseconds: 450));
      await t.pump(const Duration(milliseconds: 10));
      expect(find.text('Quiet hours'), findsOneWidget);
      expect(find.byKey(const Key('quiet-hours-placeholder')), findsOneWidget, reason: 'waiting for the answer');
      List<double> tops() => <double>[for (final e in find.byType(DsToggleRow).evaluate()) t.getRect(find.byWidget(e.widget)).top];
      final List<double> topsBefore = tops();
      final double before = t.getRect(find.text('Show names in notifications').first).top;
      final double heightBefore = t.getSize(find.byType(DsToggleRow).at(2)).height;
      await t.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const Key('quiet-hours-placeholder')), findsNothing);
      expect(find.text('Pause place alerts at night'), findsOneWidget);
      final double after = t.getRect(find.text('Show names in notifications').first).top;
      // Everything below Quiet hours stays put (the row has the same height before and after).
      expect(tops(), topsBefore, reason: 'every row stays where it was');
      expect(after, before);
      expect(t.getSize(find.byType(DsToggleRow).at(2)).height, heightBefore);
      await t.pumpAndSettle();
    });
  });

  testWidgets('with Quiet hours ON the row is there from the start; From and Until slide in when the answer arrives', (WidgetTester t) async {
    // Honest limit: the placeholder cannot know the answer, so the sub-rows
    // appear (and the sections below move down) once, on the first visit.
    setWindow(t, const Size(344, 882));
    final Map<String, int> calls = <String, int>{};
    await withServer(calls, const Duration(milliseconds: 400), quietOn: true, () async {
      await t.pumpWidget(scaled(const NotificationSettingsScreen(), 1));
      await t.pump(const Duration(milliseconds: 450));
      await t.pump(const Duration(milliseconds: 10));
      expect(find.text('Quiet hours'), findsOneWidget);
      expect(find.byKey(const Key('quiet-hours-placeholder')), findsOneWidget);
      expect(find.text('From'), findsNothing);
      await t.pump(const Duration(milliseconds: 500));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('quiet-hours-placeholder')), findsNothing);
      expect(find.text('From'), findsOneWidget);
      expect(find.text('Until'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });

  testWidgets('a failed Quiet hours load shows the row, a reason and Try again', (WidgetTester t) async {
    setWindow(t, const Size(344, 882));
    final Map<String, int> calls = <String, int>{};
    await withServer(calls, Duration.zero, quietStatus: 500, () async {
      await t.pumpWidget(scaled(const NotificationSettingsScreen(), 1));
      await t.pumpAndSettle();
      expect(find.text('Quiet hours'), findsOneWidget);
      expect(find.text('Could not load'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      await t.tap(find.text('Try again'));
      await t.pumpAndSettle();
      expect(calls['/me/quiet-hours'], greaterThanOrEqualTo(2));
    });
  });
}
