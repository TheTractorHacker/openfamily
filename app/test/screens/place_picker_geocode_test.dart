import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:openfamily/models/place.dart';
import 'package:openfamily/screens/place_picker_screen.dart';
import 'package:openfamily/services/geocoding_service.dart';
import 'package:openfamily/services/server_features.dart';

import '../support/fake_geocoding.dart';

const Place _existing = Place(
  id: 'p1',
  name: 'Grandma',
  icon: Icons.favorite,
  address: 'Pinned location',
  position: LatLng(39.7, -89.6),
  radiusMeters: 152.4,
  type: 'custom',
  alertsOn: false,
);

void main() {
  late FakeGeocodingBackend fake;
  Place? saved;

  void enable({bool autocomplete = true}) {
    ServerFeatures.instance.apply(<String, dynamic>{
      'geocoder': <String, dynamic>{
        'enabled': true,
        'autocomplete': autocomplete,
      },
    });
  }

  setUp(() {
    fake = FakeGeocodingBackend();
    GeocodingService.backend = fake;
    ServerFeatures.instance.reset();
    saved = null;
  });

  tearDown(() {
    GeocodingService.backend = const ApiGeocodingBackend();
    ServerFeatures.instance.reset();
  });

  Future<void> open(WidgetTester tester, {Place initial = _existing}) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () async {
              saved = await Navigator.of(context).push<Place>(
                MaterialPageRoute<Place>(
                  builder: (_) => PlacePickerScreen(
                    placeName: initial.name,
                    icon: initial.icon,
                    initial: initial,
                  ),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  Finder addressField() => find.widgetWithText(TextField, 'Address');

  Future<void> dragMap(WidgetTester tester) async {
    await tester.drag(find.byType(FlutterMap), const Offset(-60, 40));
    await tester.pump();
  }

  testWidgets('typing shows suggestions with attribution', (tester) async {
    enable();
    fake.results = <GeocodeSuggestion>[kMainStreet, kLibrary];
    await open(tester);
    await tester.enterText(addressField(), '123 Ma');
    await tester.pump(const Duration(milliseconds: 100));
    expect(fake.suggestQueries, isEmpty); // still debouncing
    await tester.pump(const Duration(milliseconds: 250));
    expect(fake.suggestQueries, <String>['123 Ma']);
    expect(find.text(kMainStreet.label), findsOneWidget);
    expect(find.text('Address'), findsWidgets);
    expect(find.text('Place'), findsOneWidget);
    expect(find.text('Powered by OpenStreetMap data'), findsOneWidget);
    // 48dp rows.
    expect(
      tester.getSize(find.text(kMainStreet.label)).height,
      lessThanOrEqualTo(60),
    );
    final Rect row = tester.getRect(
      find.ancestor(
        of: find.text(kLibrary.label),
        matching: find.byType(InkWell),
      ),
    );
    expect(row.height, greaterThanOrEqualTo(48));
  });

  testWidgets('choosing a suggestion moves the pin and fills the address', (
    tester,
  ) async {
    enable();
    fake.results = <GeocodeSuggestion>[kMainStreet];
    await open(tester);
    await tester.enterText(addressField(), '123 Main');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text(kMainStreet.label));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('39.79900, -89.65010'), findsOneWidget);
    expect(
      tester.widget<TextField>(addressField()).controller!.text,
      kMainStreet.label,
    );
    expect(find.text('Powered by OpenStreetMap data'), findsNothing);
    expect(fake.reverseCalls, isEmpty); // programmatic move: no lookup
    await tester.ensureVisible(find.text('Save place'));
    await tester.pump();
    await tester.tap(find.text('Save place'));
    await tester.pumpAndSettle();
    expect(saved!.address, kMainStreet.label);
    expect(saved!.position, kMainStreet.position);
  });

  testWidgets('dropping the pin detects the address', (tester) async {
    enable();
    final Completer<String?> c = Completer<String?>();
    fake.onReverse = (_) => c.future;
    await open(tester);
    await dragMap(tester);
    await tester.pump(const Duration(milliseconds: 700));
    expect(fake.reverseCalls.length, 1);
    expect(find.text('Detecting address…'), findsOneWidget);
    c.complete('9 Elm St, Springfield, IL');
    await tester.pump();
    await tester.pump();
    expect(find.text('Detecting address…'), findsNothing);
    expect(
      tester.widget<TextField>(addressField()).controller!.text,
      '9 Elm St, Springfield, IL',
    );
  });

  testWidgets('a typed address is never overwritten without asking', (
    tester,
  ) async {
    enable(autocomplete: false);
    fake.reverseResult = '9 Elm St, Springfield, IL';
    await open(tester);
    await tester.enterText(addressField(), 'Grandma\'s place');
    await tester.pump();
    await dragMap(tester);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    expect(
      tester.widget<TextField>(addressField()).controller!.text,
      'Grandma\'s place',
    );
    expect(find.text('Use detected address'), findsOneWidget);
    await tester.ensureVisible(find.text('Use detected address'));
    await tester.tap(find.text('Use detected address'));
    await tester.pump();
    expect(
      tester.widget<TextField>(addressField()).controller!.text,
      '9 Elm St, Springfield, IL',
    );
  });

  testWidgets('failed detection falls back to Pinned location', (tester) async {
    enable();
    fake.failure = GeocodeFailure.offline;
    await open(tester);
    await dragMap(tester);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    expect(find.textContaining('Couldn\'t detect an address'), findsOneWidget);
    await tester.ensureVisible(find.text('Save place'));
    await tester.pump();
    await tester.tap(find.text('Save place'));
    await tester.pumpAndSettle();
    expect(saved!.address, 'Pinned location');
  });

  testWidgets('rate limited and offline searches show friendly text', (
    tester,
  ) async {
    enable();
    fake.failure = GeocodeFailure.rateLimited;
    await open(tester);
    await tester.enterText(addressField(), 'main street');
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('Too many searches'), findsOneWidget);
    fake.failure = GeocodeFailure.offline;
    await tester.enterText(addressField(), 'main street 2');
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('Can\'t reach the server'), findsOneWidget);
  });

  testWidgets('disabled: no search UI, no lookups, manual entry works', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('Address (optional)'), findsOneWidget);
    expect(find.byTooltip('Search address'), findsNothing);
    expect(find.textContaining('Address search is off'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Address (optional)'), 'Home sweet home');
    await tester.pump(const Duration(milliseconds: 500));
    await dragMap(tester);
    await tester.pump(const Duration(milliseconds: 700));
    expect(fake.suggestQueries, isEmpty);
    expect(fake.reverseCalls, isEmpty);
    await tester.ensureVisible(find.text('Save place'));
    await tester.pump();
    await tester.tap(find.text('Save place'));
    await tester.pumpAndSettle();
    expect(saved!.address, 'Home sweet home');
  });
}
