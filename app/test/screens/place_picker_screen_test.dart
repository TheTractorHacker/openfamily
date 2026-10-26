import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/place.dart';
import 'package:openfamily/screens/place_picker_screen.dart';
import 'package:openfamily/services/geocoding_service.dart';

void main() {
  test('geocoding is off unless a Nominatim URL is configured', () {
    expect(GeocodingService.isEnabled, isFalse);
  });

  testWidgets('pin-drop save works without address search', (
    WidgetTester tester,
  ) async {
    Place? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) {
            return TextButton(
              onPressed: () async {
                saved = await Navigator.of(context).push<Place>(
                  MaterialPageRoute<Place>(
                    builder: (_) => const PlacePickerScreen(
                      placeName: 'Home',
                      icon: Icons.home,
                      type: 'home',
                    ),
                  ),
                );
              },
              child: const Text('open'),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('Drag the map to drop a pin'), findsOneWidget);
    expect(find.text('Address (optional)'), findsOneWidget);
    expect(find.byTooltip('Search address'), findsNothing);
    expect(find.text('0.00000, 0.00000'), findsOneWidget);

    await tester.ensureVisible(find.text('Save place'));
    await tester.pump();
    await tester.tap(find.text('Save place'));
    await tester.pumpAndSettle();

    expect(saved, isNotNull);
    expect(saved!.name, 'Home');
    expect(saved!.address, 'Pinned location');
    expect(saved!.position.latitude, 0);
    expect(saved!.position.longitude, 0);
    expect(saved!.type, 'home');
  });
}
