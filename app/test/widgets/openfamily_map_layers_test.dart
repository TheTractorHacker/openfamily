import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:openfamily/services/tile_config.dart';
import 'package:openfamily/widgets/openfamily_map_layers.dart';

Widget _host(Widget layer) => MaterialApp(
      home: SizedBox(
        width: 300,
        height: 300,
        child: FlutterMap(
          options: const MapOptions(
              initialCenter: LatLng(0, 0), initialZoom: 3),
          children: <Widget>[layer],
        ),
      ),
    );

void main() {
  setUp(TileConfig.instance.resetToDefaults);

  testWidgets('falls back to raster when the style fails to load',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(OpenFamilyTileLayer(
      styleLoader: (String _) => Future.error(Exception('offline')),
      tileProvider: null,
    )));
    await tester.pump();
    await tester.pump();
    expect(find.byType(TileLayer), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows nothing while the style loads, no network needed',
      (WidgetTester tester) async {
    await tester.pumpWidget(_host(OpenFamilyTileLayer(
      styleLoader: (String _) => Future<Never>.delayed(
          const Duration(days: 1), () => throw Exception('never')),
    )));
    expect(find.byType(TileLayer), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(days: 2));
  });

  testWidgets('satellite builds a raster TileLayer', (WidgetTester tester) async {
    await tester.pumpWidget(_host(OpenFamilyTileLayer(
      satellite: true,
      tileProvider: _NoTiles(),
    )));
    expect(find.byType(TileLayer), findsOneWidget);
  });
}

class _NoTiles extends TileProvider {
  _NoTiles();
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      MemoryImage(Uint8List.fromList(<int>[]));
}
