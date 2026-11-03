import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:openfamily/models/place.dart';
import 'package:openfamily/screens/check_in_screen.dart';
import 'package:openfamily/theme/app_theme.dart';

Place _p(String id, String name, double lat, {String type = 'custom'}) => Place(
      id: id,
      name: name,
      icon: Place.iconForType(type),
      address: '',
      position: LatLng(lat, 0),
      radiusMeters: 100,
      type: type,
    );

// 0.001 deg lat ~ 111 m.
final List<Place> _places = <Place>[
  _p('far', 'Far Gym', 0.05, type: 'gym'),
  _p('b', 'School', 0.004, type: 'school'),
  _p('a', 'Home', 0.001, type: 'home'),
];

Widget _app({
  Future<List<Place>> Function()? places,
  List<Map<String, dynamic>>? sent,
  ThemeData? theme,
  double scale = 1,
  Future<String?> Function(Map<String, dynamic>)? send,
}) {
  return MaterialApp(
    theme: theme,
    builder: (BuildContext c, Widget? child) => MediaQuery(
      data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: CheckInScreen(
      loadPlaces: places ?? () async => _places,
      loadPosition: () async => const LatLng(0, 0),
      send: send ??
          (Map<String, dynamic> b) async {
            sent?.add(b);
            return null;
          },
    ),
  );
}

void main() {
  testWidgets('rows sorted nearest first, far places hidden',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    expect(find.text('Name your current location'), findsOneWidget);
    expect(find.text('Nearby locations'), findsOneWidget);
    expect(find.text('Far Gym'), findsNothing);
    expect(tester.getTopLeft(find.text('Home')).dy,
        lessThan(tester.getTopLeft(find.text('School')).dy));
    expect(find.byIcon(Icons.home_outlined), findsOneWidget);
    expect(find.byIcon(Icons.place_outlined), findsWidgets);
  });

  testWidgets('tapping a row sends the place name and coordinates',
      (WidgetTester tester) async {
    final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
    await tester.pumpWidget(_app(sent: sent));
    await tester.pumpAndSettle();
    await tester.tap(find.text('School'));
    await tester.pumpAndSettle();
    expect(sent.single['note'], 'School');
    expect(sent.single['lat'], 0.004);
    expect(find.text('Checked in'), findsOneWidget);
  });

  testWidgets('typed custom name sends on submit', (WidgetTester tester) async {
    final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
    await tester.pumpWidget(_app(sent: sent));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '  Grandma  ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(sent.single['note'], 'Grandma');
  });

  testWidgets('empty state shows only the field and a hint',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app(places: () async => <Place>[]));
    await tester.pumpAndSettle();
    expect(find.text('Nearby locations'), findsNothing);
    expect(find.textContaining('No saved places'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('load error shows retry', (WidgetTester tester) async {
    int calls = 0;
    await tester.pumpWidget(_app(places: () async {
      calls++;
      if (calls == 1) throw Exception('boom');
      return _places;
    }));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not load'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
  });

  testWidgets('send failure keeps the form and shows an error',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app(send: (_) async => throw Exception('x')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();
    expect(find.text('Checked in'), findsNothing);
    expect(find.textContaining('Not sent'), findsOneWidget);
  });

  testWidgets('renders at 200% text in dark theme without overflow',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(theme: buildDarkTheme(), scale: 2));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Home'), findsOneWidget);
  });
}
