import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:openfamily/models/place.dart';
import 'package:openfamily/screens/places_screen.dart';

const String _circle = 'c1';

const Place _home = Place(
  id: 'p1',
  name: 'Home',
  icon: Icons.home,
  address: '',
  position: LatLng(40.5, -75.25),
  radiusMeters: 152.4,
  type: 'home',
  circleId: _circle,
  circleName: 'Foley Family',
);

void main() {
  testWidgets(
      'places the others cannot read say so, and "Share places with the circle" fixes it',
      (WidgetTester t) async {
    Set<String> unshared = <String>{_circle};
    final List<String> shared = <String>[];
    await t.pumpWidget(MaterialApp(
      home: PlacesScreen(
        loader: () async => const PlacesSnapshot(
            places: <Place>[_home], role: 'admin', userId: 'me'),
        unsharedLoader: () async => unshared,
        sharer: (String c) async {
          shared.add(c);
          unshared = <String>{};
          return 1;
        },
      ),
    ));
    await t.pumpAndSettle();

    expect(find.textContaining('Other members of Foley Family may not see'),
        findsOneWidget);
    expect(find.textContaining('Only on this phone: not shared with Foley Family yet'),
        findsOneWidget);
    expect(find.textContaining('Shared with Foley Family'), findsNothing);

    await t.tap(find.text('Share places with the circle'));
    await t.pumpAndSettle();

    expect(shared, <String>[_circle]);
    expect(find.textContaining('1 place was shared with Foley Family'),
        findsOneWidget);
    expect(find.text('Share places with the circle'), findsNothing);
    expect(find.textContaining('Shared with Foley Family'), findsOneWidget);
  });

  testWidgets('a failed share explains what to do and keeps the button',
      (WidgetTester t) async {
    await t.pumpWidget(MaterialApp(
      home: PlacesScreen(
        loader: () async => const PlacesSnapshot(
            places: <Place>[_home], role: 'member', userId: 'me'),
        unsharedLoader: () async => <String>{_circle},
        sharer: (String c) async => throw StateError('no key'),
      ),
    ));
    await t.pumpAndSettle();
    await t.tap(find.text('Share places with the circle'));
    await t.pumpAndSettle();
    expect(find.textContaining('does not have the circle\'s current key'),
        findsOneWidget);
    expect(find.text('Share places with the circle'), findsOneWidget);
  });

  testWidgets('shared places keep the plain "Shared with" line',
      (WidgetTester t) async {
    await t.pumpWidget(MaterialApp(
      home: PlacesScreen(
        loader: () async => const PlacesSnapshot(
            places: <Place>[_home], role: 'admin', userId: 'me'),
        unsharedLoader: () async => <String>{},
      ),
    ));
    await t.pumpAndSettle();
    expect(find.textContaining('Shared with Foley Family'), findsOneWidget);
    expect(find.text('Share places with the circle'), findsNothing);
  });
}
