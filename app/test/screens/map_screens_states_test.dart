import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:openfamily/models/alert.dart';
import 'package:openfamily/models/member.dart';
import 'package:openfamily/models/place.dart';
import 'package:openfamily/screens/alert_received_screen.dart';
import 'package:openfamily/screens/alert_status_screen.dart';
import 'package:openfamily/screens/alerts_history_screen.dart';
import 'package:openfamily/screens/place_picker_screen.dart';
import 'package:openfamily/screens/places_screen.dart';
import 'package:openfamily/screens/sos_screen.dart';
import 'package:openfamily/screens/trips_screen.dart';
import 'package:openfamily/services/api_client.dart';
import 'package:openfamily/theme/app_theme.dart';
import 'package:openfamily/widgets/ds/ds.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'alert_screens_test.dart' show FakeAlertService, FakeDialer, detail, row;
import 'trips_screens_test.dart' show FakeTrips;

/// Wraps [home] with a theme and text scale, like the golden tests do.
Widget _app(Widget home, {bool dark = false, double scale = 1}) => MaterialApp(
      theme: dark ? buildDarkTheme() : buildLightTheme(),
      builder: (BuildContext c, Widget? child) => MediaQuery(
        data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: home,
    );

void _phone(WidgetTester t, {double w = 360, double h = 740}) {
  t.view.physicalSize = Size(w, h);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
}

const Member _member = Member(
  id: 'u1',
  name: 'Sam',
  position: null,
  batteryPercent: 80,
  status: MemberStatus.normal,
  address: '',
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{
        'sos_intro_seen': true,
      }));

  group('SOS', () {
    testWidgets('idle says plainly that emergency services are not called',
        (t) async {
      _phone(t);
      await t.pumpWidget(_app(SosScreen(
        smsConfigured: false,
        dialer: FakeDialer(),
      )));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('sos-send-button')),
          findsOneWidget);
      expect(find.textContaining('does not call emergency services'),
          findsOneWidget);
      expect(find.text('Call emergency services'), findsOneWidget);
      expect(find.text('Practice SOS'), findsOneWidget);
      // The big button is at least 160dp.
      expect(
        t.getSize(find.byKey(const ValueKey<String>('sos-send-button'))).width,
        greaterThanOrEqualTo(160),
      );
    });

    testWidgets('dial button hidden when the platform cannot dial',
        (t) async {
      _phone(t);
      await t.pumpWidget(_app(SosScreen(
        smsConfigured: false,
        dialer: FakeDialer(ok: false),
      )));
      await t.pumpAndSettle();
      expect(find.text('Call emergency services'), findsNothing);
    });

    testWidgets('the dial button opens the dialler', (t) async {
      _phone(t);
      final FakeDialer dialer = FakeDialer();
      await t.pumpWidget(_app(SosScreen(smsConfigured: false, dialer: dialer)));
      await t.pumpAndSettle();
      await t.tap(find.text('Call emergency services'));
      await t.pump();
      expect(dialer.dials, 1);
    });

    testWidgets('practice countdown can be cancelled with a plain button',
        (t) async {
      _phone(t);
      await t.pumpWidget(_app(SosScreen(
        smsConfigured: false,
        dialer: FakeDialer(),
      )));
      await t.pumpAndSettle();
      await t.tap(find.text('Practice SOS'));
      await t.pump();
      expect(find.text('10'), findsOneWidget);
      expect(find.text('Slide to Cancel'), findsOneWidget);
      await t.tap(find.widgetWithText(DsPillButton, 'Cancel'));
      await t.pump();
      expect(find.text('Practice complete'), findsNothing);
      expect(find.text('SOS'), findsWidgets);
      expect(t.takeException(), isNull);
    });

    for (final bool dark in <bool>[false, true]) {
      testWidgets('idle and intro fit at 200% text, dark=$dark', (t) async {
        _phone(t, w: 320, h: 568);
        await t.pumpWidget(_app(
          SosScreen(smsConfigured: true, dialer: FakeDialer()),
          dark: dark,
          scale: 2,
        ));
        await t.pumpAndSettle();
        expect(t.takeException(), isNull);
        await t.scrollUntilVisible(
          find.text('Practice SOS'),
          100,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('Practice SOS'), findsOneWidget);
      });
    }

    testWidgets('first run intro is explained and scrolls at 200% text',
        (t) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      _phone(t, w: 320, h: 568);
      await t.pumpWidget(_app(
        const SosScreen(smsConfigured: true),
        scale: 2,
      ));
      await t.pumpAndSettle();
      expect(find.text('How SOS works'), findsOneWidget);
      await t.scrollUntilVisible(
        find.text('Continue'),
        100,
        scrollable: find.byType(Scrollable).first,
      );
      expect(t.takeException(), isNull);
    });
  });

  group('alert status', () {
    testWidgets('shows a skeleton while loading, then delivery as icon + words',
        (t) async {
      _phone(t);
      final FakeAlertService svc = FakeAlertService(details: <AlertDetail>[
        detail(<Map<String, dynamic>>[row('Alex', 'push', 'delivered')]),
      ]);
      await t.pumpWidget(_app(AlertStatusScreen(
        alertId: 'a1',
        kind: AlertKind.sos,
        service: svc,
        dialer: FakeDialer(),
      )));
      expect(find.byType(DsSkeleton), findsWidgets);
      expect(find.text(kFamilyNotifiedLine), findsOneWidget);
      await t.pump();
      await t.pump();
      expect(find.byType(DsSkeleton), findsNothing);
      expect(find.textContaining('Notification: Delivered'), findsOneWidget);
      expect(find.byIcon(Icons.done_all), findsOneWidget);
    });

    testWidgets('honest line and call button survive 200% dark text',
        (t) async {
      _phone(t, w: 320, h: 568);
      final FakeAlertService svc = FakeAlertService(details: <AlertDetail>[
        detail(<Map<String, dynamic>>[
          row('Alex', 'push', 'failed', err: 'provider_error'),
          row('Bo', 'sms', 'sent'),
        ]),
      ]);
      await t.pumpWidget(_app(
        AlertStatusScreen(
          alertId: 'a1',
          kind: AlertKind.sos,
          service: svc,
          dialer: FakeDialer(),
        ),
        dark: true,
        scale: 2,
      ));
      await t.pump();
      await t.pump();
      expect(t.takeException(), isNull);
      expect(find.text(kFamilyNotifiedLine), findsOneWidget);
      expect(
        find.text('Call emergency services', skipOffstage: false),
        findsOneWidget,
      );
      await t.scrollUntilVisible(
        find.text('Notification: Failed'),
        100,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.byIcon(Icons.error_outline), findsWidgets);
    });

    testWidgets('failed load offers Retry as a 48dp button', (t) async {
      _phone(t);
      final FakeAlertService svc = FakeAlertService(failDetail: true);
      await t.pumpWidget(_app(AlertStatusScreen(
        alertId: 'a1',
        service: svc,
        dialer: FakeDialer(),
        pollInterval: const Duration(seconds: 100),
      )));
      await t.pump();
      await t.pump();
      final Finder retry = find.widgetWithText(DsPillButton, 'Retry');
      expect(retry, findsOneWidget);
      expect(t.getSize(retry).height, greaterThanOrEqualTo(48));
    });
  });

  group('alert received and history', () {
    testWidgets('received: acknowledge stays reachable at 200% text',
        (t) async {
      _phone(t, w: 320, h: 568);
      final AlertSummary a = AlertSummary.fromJson(<String, dynamic>{
        'id': 'a1',
        'type': 'sos',
        'status': 'active',
        'user_id': 'u',
        'sender_name': 'Sam',
        'created_at': DateTime.now().toIso8601String(),
      });
      await t.pumpWidget(_app(
        AlertReceivedScreen(
          alert: a,
          service: FakeAlertService(),
          dialer: FakeDialer(),
        ),
        dark: true,
        scale: 2,
      ));
      expect(t.takeException(), isNull);
      expect(find.text('Sam sent an SOS'), findsOneWidget);
      await t.scrollUntilVisible(
        find.text('Acknowledge'),
        100,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Acknowledge'), findsOneWidget);
    });

    testWidgets('history rows show Active / Resolved as text and icon',
        (t) async {
      _phone(t);
      final FakeAlertService svc = FakeAlertService(pages: <AlertPage>[
        AlertPage.fromJson(<String, dynamic>{
          'alerts': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'a',
              'type': 'sos',
              'status': 'active',
              'user_id': 'u2',
              'sender_name': 'Sam',
              'created_at': DateTime.now().toIso8601String(),
            },
            <String, dynamic>{
              'id': 'b',
              'type': 'help',
              'status': 'resolved',
              'user_id': 'u2',
              'sender_name': 'Maya',
              'created_at': DateTime.now().toIso8601String(),
            },
          ],
          'next_before': '',
        }),
      ]);
      await t.pumpWidget(_app(
        AlertsHistoryScreen(service: svc, selfUserId: 'me'),
        scale: 2,
      ));
      expect(find.byType(DsSkeleton), findsWidgets);
      await t.pumpAndSettle();
      expect(find.text('Active'), findsOneWidget);
      expect(find.text('Resolved'), findsOneWidget);
      expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('history empty and offline states', (t) async {
      _phone(t);
      await t.pumpWidget(_app(AlertsHistoryScreen(
        service: FakeAlertService(failList: true),
        selfUserId: 'me',
      )));
      await t.pumpAndSettle();
      expect(find.text('Could not load alerts'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });
  });

  group('trips and report', () {
    testWidgets('trips: skeleton, then the 7/30 day tabs and report button',
        (t) async {
      _phone(t);
      await t.pumpWidget(_app(
        TripsScreen(member: _member, api: FakeTrips()),
        dark: true,
        scale: 2,
      ));
      expect(find.byType(DsSkeleton), findsWidgets);
      await t.pump();
      await t.pump();
      expect(find.text('7 days'), findsOneWidget);
      expect(find.text('30 days'), findsOneWidget);
      expect(find.text('Driving report'), findsOneWidget);
      expect(find.text('No trips yet'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });

  group('places', () {
    const List<Place> places = <Place>[
      Place(
        id: 'p1',
        name: 'Home',
        icon: Icons.home,
        address: '12 Oak Ave',
        position: LatLng(37.78, -122.42),
        radiusMeters: 152.4,
        alertsOn: true,
      ),
      Place(
        id: 'p2',
        name: 'School',
        icon: Icons.school,
        address: '',
        position: LatLng(37.79, -122.43),
        radiusMeters: 304.8,
      ),
    ];

    testWidgets('lists places with alert state in words', (t) async {
      _phone(t);
      await t.pumpWidget(_app(PlacesScreen(
        loader: () async => const PlacesSnapshot(places: places),
      )));
      expect(find.byType(DsSkeleton), findsWidgets);
      await t.pump();
      await t.pump();
      expect(find.text('Home'), findsOneWidget);
      expect(find.textContaining('alerts: on'), findsOneWidget);
      expect(find.textContaining('alerts: off'), findsOneWidget);
      expect(find.byTooltip('Alerts on'), findsOneWidget);
      expect(find.byTooltip('Delete place'), findsNWidgets(2));
      expect(find.text('Add a Place'), findsOneWidget);
      final Size del = t.getSize(find.byTooltip('Delete place').first);
      expect(del.shortestSide, greaterThanOrEqualTo(48));
    });

    testWidgets('children cannot add, toggle or delete', (t) async {
      _phone(t);
      await t.pumpWidget(_app(PlacesScreen(
        loader: () async =>
            const PlacesSnapshot(places: places, role: 'child'),
      )));
      await t.pump();
      await t.pump();
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Add a Place'), findsNothing);
      expect(find.byTooltip('Delete place'), findsNothing);
    });

    testWidgets('empty state offers Add a Place', (t) async {
      _phone(t);
      await t.pumpWidget(_app(PlacesScreen(
        loader: () async => const PlacesSnapshot(places: <Place>[]),
      )));
      await t.pump();
      await t.pump();
      expect(find.text('No places yet'), findsOneWidget);
      expect(find.text('Add a Place'), findsOneWidget);
    });

    testWidgets('error shows Try again and recovers', (t) async {
      _phone(t);
      int calls = 0;
      await t.pumpWidget(_app(PlacesScreen(
        loader: () async {
          calls++;
          if (calls == 1) throw const ApiException(0, 'Offline');
          return const PlacesSnapshot(places: places);
        },
      )));
      await t.pump();
      await t.pump();
      expect(find.text('Could not load places'), findsOneWidget);
      await t.tap(find.text('Try again'));
      await t.pump();
      await t.pump();
      expect(find.text('Home'), findsOneWidget);
    });

    testWidgets('fits at 200% text in dark mode', (t) async {
      _phone(t, w: 320, h: 568);
      await t.pumpWidget(_app(
        PlacesScreen(
          loader: () async => const PlacesSnapshot(places: places),
        ),
        dark: true,
        scale: 2,
      ));
      await t.pump();
      await t.pump();
      expect(t.takeException(), isNull);
    });
  });

  testWidgets('place picker panel scrolls at 200% text', (t) async {
    _phone(t, w: 360, h: 640);
    await t.pumpWidget(_app(
      const PlacePickerScreen(placeName: 'Home', icon: Icons.home),
      scale: 2,
    ));
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));
    expect(t.takeException(), isNull);
    await t.scrollUntilVisible(
      find.text('Save place'),
      100,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Save place'), findsOneWidget);
  });
}
