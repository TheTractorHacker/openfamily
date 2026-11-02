import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart' hide Circle;
import 'package:openfamily/models/circle.dart';
import 'package:openfamily/models/place.dart';
import 'package:openfamily/screens/place_picker_screen.dart';

Circle _circle(String id, String name, {bool primary = false}) => Circle(
      id: id,
      name: name,
      role: 'admin',
      sharingEnabled: true,
      memberCount: 2,
      isPrimary: primary,
    );

void main() {
  testWidgets('Share with selects a circle and returns it on the place', (
    WidgetTester tester,
  ) async {
    Place? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () async {
              saved = await Navigator.of(context).push<Place>(
                MaterialPageRoute<Place>(
                  builder: (_) => PlacePickerScreen(
                    placeName: 'Cabin',
                    icon: Icons.place_outlined,
                    circleLoader: () async => <Circle>[
                      _circle('fam', 'Family', primary: true),
                      _circle('ext', 'Extended Family'),
                    ],
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
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const ValueKey<String>('share-with')));
    await tester.tap(find.byKey(const ValueKey<String>('share-with')));
    await tester.pumpAndSettle();
    // The primary circle is the whole family, so it is not offered twice.
    expect(find.text('Family'), findsNothing);
    expect(find.text('Whole family'), findsWidgets);
    await tester.tap(find.text('Extended Family').last);
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Save place'));
    await tester.tap(find.text('Save place'));
    await tester.pumpAndSettle();
    expect(saved?.circleId, 'ext');
    expect(saved?.circleName, 'Extended Family');
  });

  testWidgets('selector is hidden when there are no other circles', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PlacePickerScreen(
          placeName: 'Home',
          icon: Icons.home,
          circleLoader: () async => <Circle>[_circle('fam', 'Family', primary: true)],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('share-with')), findsNothing);
  });

  test('copyWith can clear the circle', () {
    const Place p = Place(
      id: '1',
      name: 'Cabin',
      icon: Icons.place,
      address: '',
      position: LatLng(1, 2),
      radiusMeters: 100,
      circleId: 'ext',
      circleName: 'Extended Family',
    );
    expect(p.copyWith(name: 'x').circleId, 'ext');
    final Place cleared = p.copyWith(circleId: Place.clearCircle);
    expect(cleared.circleId, isNull);
    expect(cleared.circleName, isNull);
  });
}
