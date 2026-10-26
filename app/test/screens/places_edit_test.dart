import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:openfamily/models/place.dart';
import 'package:openfamily/screens/place_picker_screen.dart';
import 'package:openfamily/screens/places_screen.dart';
import 'package:openfamily/services/api_client.dart';

const Place _home = Place(
  id: 'p1',
  name: 'Home',
  icon: Icons.home,
  address: '1 Main St',
  position: LatLng(40.5, -75.25),
  radiusMeters: 152.4,
  type: 'home',
  alertsOn: true,
  geofenceId: 'g1',
);

Widget _screen({
  String role = 'admin',
  Future<Place> Function(Place)? updater,
  Future<void> Function(String)? deleter,
}) =>
    MaterialApp(
      home: PlacesScreen(
        loader: () async => PlacesSnapshot(
          places: const <Place>[_home],
          role: role,
          userId: 'me',
        ),
        updater: updater,
        deleter: deleter,
      ),
    );

Future<void> _openEdit(WidgetTester t) async {
  await t.tap(find.byTooltip('Edit place'));
  await t.pump();
  await t.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('edit opens the picker pre-filled and saves via update',
      (WidgetTester t) async {
    Place? sent;
    await t.pumpWidget(_screen(updater: (Place p) async {
      sent = p;
      return p;
    }));
    await t.pumpAndSettle();
    await _openEdit(t);

    final PlacePickerScreen picker =
        t.widget<PlacePickerScreen>(find.byType(PlacePickerScreen));
    expect(picker.initial?.id, 'p1');
    expect(picker.initial?.radiusMeters, 152.4);
    expect(picker.initial?.position, const LatLng(40.5, -75.25));
    expect(find.text('Home'), findsWidgets); // name field
    expect(find.text('1 Main St'), findsOneWidget); // address field

    await t.enterText(
        find.descendant(
            of: find.byType(TextField), matching: find.text('Home')),
        'Our House');
    await t.pumpAndSettle();
    await t.ensureVisible(find.text('Save place'));
    await t.pumpAndSettle();
    await t.tap(find.text('Save place'));
    await t.pumpAndSettle();

    expect(sent?.id, 'p1');
    expect(sent?.name, 'Our House');
    expect(sent?.position, const LatLng(40.5, -75.25));
    expect(find.text('Our House'), findsOneWidget);
    expect(find.text('Place updated'), findsOneWidget);
    // The alert toggle state is untouched by an edit.
    expect(find.textContaining('alerts: on'), findsOneWidget);
  });

  testWidgets('a refused edit rolls back and explains why',
      (WidgetTester t) async {
    await t.pumpWidget(_screen(
      updater: (Place p) async =>
          throw const ApiException(403, 'insufficient role'),
    ));
    await t.pumpAndSettle();
    await _openEdit(t);
    await t.enterText(
        find.descendant(
            of: find.byType(TextField), matching: find.text('Home')),
        'Nope');
    await t.pumpAndSettle();
    await t.ensureVisible(find.text('Save place'));
    await t.pumpAndSettle();
    await t.tap(find.text('Save place'));
    await t.pumpAndSettle();

    expect(find.text('Nope'), findsNothing);
    expect(find.text('Home'), findsOneWidget);
    expect(find.textContaining("You can't edit this place"), findsOneWidget);
  });

  testWidgets('offline edit rolls back with the network message',
      (WidgetTester t) async {
    await t.pumpWidget(_screen(
      updater: (Place p) async => throw const ApiException(
          0, 'Could not reach the server. Check your connection.'),
    ));
    await t.pumpAndSettle();
    await _openEdit(t);
    await t.ensureVisible(find.text('Save place'));
    await t.pumpAndSettle();
    await t.tap(find.text('Save place'));
    await t.pumpAndSettle();
    expect(find.textContaining('Could not reach the server'), findsOneWidget);
    expect(find.textContaining('not saved'), findsOneWidget);
  });

  testWidgets('delete asks for confirmation then calls delete',
      (WidgetTester t) async {
    final List<String> deleted = <String>[];
    await t.pumpWidget(_screen(deleter: (String id) async => deleted.add(id)));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Delete place'));
    await t.pumpAndSettle();
    expect(find.text('Delete place?'), findsOneWidget);
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(deleted, isEmpty);

    await t.tap(find.byTooltip('Delete place'));
    await t.pumpAndSettle();
    await t.tap(find.text('Delete'));
    await t.pumpAndSettle();
    expect(deleted, <String>['p1']);
    expect(find.text('Home'), findsNothing);
  });

  testWidgets('people who cannot manage places see no edit or delete',
      (WidgetTester t) async {
    await t.pumpWidget(_screen(role: 'child'));
    await t.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(find.byTooltip('Edit place'), findsNothing);
    expect(find.byTooltip('Delete place'), findsNothing);
    await t.tap(find.text('Home'));
    await t.pumpAndSettle();
    expect(find.byType(PlacePickerScreen), findsNothing);
  });
}
