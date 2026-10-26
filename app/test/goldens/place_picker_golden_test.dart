import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:openfamily/models/place.dart';
import 'package:openfamily/screens/place_picker_screen.dart';
import 'package:openfamily/services/geocoding_service.dart';
import 'package:openfamily/services/server_features.dart';
import 'package:openfamily/theme/app_theme.dart';

import '../support/fake_geocoding.dart';

/// Golden renders of the place picker's address search states. Run with
/// `OF_GOLDENS=1 flutter test --update-goldens test/goldens/place_picker_golden_test.dart`.
/// Map tiles need the network, so the map area renders as the empty basemap.
final bool _on = Platform.environment['OF_GOLDENS'] == '1';

Future<void> _loadRoboto() async {
  final String? root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) return;
  final File f = File(
    '$root/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf',
  );
  final File b = File(
    '$root/bin/cache/artifacts/material_fonts/Roboto-Bold.ttf',
  );
  if (!f.existsSync()) return;
  final FontLoader l = FontLoader('Roboto')
    ..addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
  if (b.existsSync()) {
    l.addFont(Future.value(ByteData.sublistView(b.readAsBytesSync())));
  }
  await l.load();
  final File icons = File(
    '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  if (icons.existsSync()) {
    final FontLoader il = FontLoader('MaterialIcons')
      ..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
    await il.load();
  }
}

const Place _place = Place(
  id: 'p1',
  name: 'Grandma',
  icon: Icons.favorite,
  address: 'Pinned location',
  position: LatLng(39.799, -89.65),
  radiusMeters: 152.4,
);

enum _State { suggestions, detected, disabled }

Future<void> _shot(
  WidgetTester t,
  _State state,
  ThemeData theme,
  String name, {
  double textScale = 1,
}) async {
  final FakeGeocodingBackend fake = FakeGeocodingBackend()
    ..results = <GeocodeSuggestion>[kMainStreet, kLibrary]
    ..reverseResult = '9 Elm St, Springfield, IL';
  GeocodingService.backend = fake;
  ServerFeatures.instance.reset();
  if (state != _State.disabled) {
    ServerFeatures.instance.apply(<String, dynamic>{
      'geocoder': <String, dynamic>{'enabled': true, 'autocomplete': true},
    });
  }
  addTearDown(() {
    GeocodingService.backend = const ApiGeocodingBackend();
    ServerFeatures.instance.reset();
  });
  t.view.physicalSize = const Size(780, 1520);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme.copyWith(
        textTheme: theme.textTheme.apply(fontFamily: 'Roboto'),
      ),
      builder: (BuildContext c, Widget? child) => MediaQuery(
        data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(textScale)),
        child: DefaultTextStyle.merge(
          style: const TextStyle(fontFamily: 'Roboto'),
          child: child!,
        ),
      ),
      home: const PlacePickerScreen(
        placeName: 'Grandma',
        icon: Icons.favorite,
        initial: _place,
      ),
    ),
  );
  await t.pump(const Duration(milliseconds: 100));
  switch (state) {
    case _State.suggestions:
      await t.enterText(find.widgetWithText(TextField, 'Address'), '123 Main');
      await t.pump(const Duration(milliseconds: 400));
    case _State.detected:
      await t.drag(find.byType(FlutterMap), const Offset(-40, 30));
      await t.pump(const Duration(milliseconds: 700));
      await t.pump();
    case _State.disabled:
      break;
  }
  await t.pump(const Duration(milliseconds: 500)); // label/scroll animations
  await expectLater(find.byType(MaterialApp), matchesGoldenFile('$name.png'));
}

void main() {
  setUpAll(_loadRoboto);
  for (final _State s in _State.values) {
    for (final bool dark in <bool>[false, true]) {
      for (final double scale in <double>[1, 2]) {
        final String name = 'place_picker_${s.name}_${dark ? 'dark' : 'light'}'
            '${scale == 2 ? '_x2' : ''}';
        testWidgets(
          name,
          (t) => _shot(
            t,
            s,
            dark ? buildDarkTheme() : buildLightTheme(),
            name,
            textScale: scale,
          ),
          skip: !_on,
        );
      }
    }
  }
}
