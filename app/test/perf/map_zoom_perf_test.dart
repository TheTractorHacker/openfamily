import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/screens/map_screen.dart';
import 'package:openfamily/widgets/openfamily_map_layers.dart';

void main() {
  test('vector base map loads 512 px tiles: about 4x fewer tiles per screen', () {
    expect(kVectorTileOffset.zoomOffset, -1);
    const Size phone = Size(412, 915);
    final int before = tilesForViewport(phone, offset: 0);
    final int after = tilesForViewport(phone, offset: kVectorTileOffset.zoomOffset);
    // ignore: avoid_print
    print('PERFMETRIC map-tiles-per-screen: before $before, after $after');
    expect(before, greaterThanOrEqualTo(after * 3));
  });

  test('programmatic camera moves are short, shorter on low-end phones', () {
    expect(cameraAnimDuration(1), const Duration(milliseconds: 400));
    expect(cameraAnimDuration(0.6), const Duration(milliseconds: 240));
    expect(cameraAnimDuration(0), const Duration(milliseconds: 120));
  });
}
