import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/map_style_service.dart';
import 'package:openfamily/services/tile_config.dart';

void main() {
  setUp(TileConfig.instance.resetToDefaults);

  test('default light and dark use OpenFreeMap vector styles', () {
    final TileConfig c = TileConfig.instance;
    expect(resolveMapLayer(config: c, dark: false),
        const MapLayerChoice.vector(kDefaultLightStyleUrl));
    expect(resolveMapLayer(config: c, dark: true),
        const MapLayerChoice.vector(kDefaultDarkStyleUrl));
  });

  test('MAP_STYLE_URL overrides the default style', () {
    final TileConfig c = TileConfig.instance
      ..mapStyleUrl = 'https://maps.example.com/style.json';
    expect(resolveMapLayer(config: c, dark: true),
        const MapLayerChoice.vector('https://maps.example.com/style.json'));
  });

  test('TILE_URL override forces raster and wins over MAP_STYLE_URL', () {
    final TileConfig c = TileConfig.instance
      ..streetUrl = 'https://t.example.com/{z}/{x}/{y}.png'
      ..mapStyleUrl = 'https://maps.example.com/style.json';
    expect(resolveMapLayer(config: c, dark: false),
        const MapLayerChoice.raster('https://t.example.com/{z}/{x}/{y}.png'));
  });

  test('satellite always uses the satellite raster URL', () {
    final TileConfig c = TileConfig.instance;
    expect(resolveMapLayer(config: c, dark: true, satellite: true),
        MapLayerChoice.raster(c.satelliteUrl));
  });

  test('offline fallback is the raster street URL', () {
    expect(rasterFallbackUrl(TileConfig.instance), kDefaultStreetTileUrl);
  });

  test('failed style load is not retried within the cooldown', () async {
    MapStyleService.instance.resetForTest();
    await expectLater(
        MapStyleService.instance.load('http://127.0.0.1:1/none'), throwsA(anything));
    await expectLater(
        MapStyleService.instance.load('http://127.0.0.1:1/none'),
        throwsA(isA<StateError>()));
    MapStyleService.instance.resetForTest();
  });
}
