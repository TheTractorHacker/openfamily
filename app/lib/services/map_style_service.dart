import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:vector_map_tiles/vector_map_tiles.dart';

import 'tile_config.dart';

/// User-Agent sent to tile/style hosts so operators (and OSM's tile policy)
/// can identify the app.
const String kMapUserAgentPackage = 'app.openfamily';
const String kMapUserAgent = 'app.openfamily (OpenFamily Flutter app)';

/// OpenFreeMap styles (free, no key, OpenMapTiles schema).
const String kDefaultLightStyleUrl =
    'https://tiles.openfreemap.org/styles/positron';
const String kDefaultDarkStyleUrl = 'https://tiles.openfreemap.org/styles/dark';

enum MapLayerKind { vector, raster }

/// What the shared map layer should draw. Pure data so it is unit-testable.
class MapLayerChoice {
  const MapLayerChoice.vector(this.styleUrl)
      : kind = MapLayerKind.vector,
        rasterUrl = null;
  const MapLayerChoice.raster(this.rasterUrl)
      : kind = MapLayerKind.raster,
        styleUrl = null;

  final MapLayerKind kind;
  final String? styleUrl;
  final String? rasterUrl;

  @override
  bool operator ==(Object other) =>
      other is MapLayerChoice &&
      other.kind == kind &&
      other.styleUrl == styleUrl &&
      other.rasterUrl == rasterUrl;

  @override
  int get hashCode => Object.hash(kind, styleUrl, rasterUrl);
}

/// Resolution order:
/// 1. satellite toggle -> raster SATELLITE_TILE_URL
/// 2. operator TILE_URL (anything but the stock OSM default) -> raster override
/// 3. operator MAP_STYLE_URL -> vector, that style
/// 4. OpenFreeMap positron (light) / dark (dark)
MapLayerChoice resolveMapLayer({
  required TileConfig config,
  required bool dark,
  bool satellite = false,
}) {
  if (satellite) return MapLayerChoice.raster(config.satelliteUrl);
  if (config.streetUrl != kDefaultStreetTileUrl) {
    return MapLayerChoice.raster(config.streetUrl);
  }
  if (config.mapStyleUrl.isNotEmpty) {
    return MapLayerChoice.vector(config.mapStyleUrl);
  }
  return MapLayerChoice.vector(dark ? kDefaultDarkStyleUrl : kDefaultLightStyleUrl);
}

/// Raster URL used when the vector style cannot load.
String rasterFallbackUrl(TileConfig config) => config.streetUrl;

typedef MapStyleLoader = Future<Style> Function(String styleUrl);

class _UaClient extends http.BaseClient {
  _UaClient(this._inner);
  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers['User-Agent'] = kMapUserAgent;
    return _inner.send(request);
  }
}

/// Delegates to [inner] with our User-Agent on its HTTP client.
class _UaTileProvider extends VectorTileProvider {
  _UaTileProvider(this.inner);
  final VectorTileProvider inner;

  @override
  Future<Uint8List> provide(TileIdentity tile) =>
      http.runWithClient(() => inner.provide(tile), () => _UaClient(http.Client()));

  @override
  int get maximumZoom => inner.maximumZoom;
  @override
  int get minimumZoom => inner.minimumZoom;
  @override
  TileProviderType get type => inner.type;
}

/// Loads and memoises vector styles. Failures are retried after a cooldown.
class MapStyleService {
  MapStyleService._();
  static final MapStyleService instance = MapStyleService._();

  static const Duration retryAfter = Duration(seconds: 30);

  final Map<String, Future<Style>> _styles = <String, Future<Style>>{};
  final Map<String, DateTime> _failedAt = <String, DateTime>{};

  Future<Style> load(String styleUrl) {
    final DateTime? failed = _failedAt[styleUrl];
    if (failed != null && DateTime.now().difference(failed) < retryAfter) {
      return Future<Style>.error(StateError('style recently failed'));
    }
    return _styles.putIfAbsent(styleUrl, () {
      final Future<Style> f = _fetch(styleUrl).then((Style s) {
        _failedAt.remove(styleUrl);
        return s;
      }, onError: (Object e) {
        _styles.remove(styleUrl);
        _failedAt[styleUrl] = DateTime.now();
        throw e;
      });
      return f;
    });
  }

  Future<Style> _fetch(String url) async {
    final Style s = await http.runWithClient(
      () => StyleReader(uri: url).read().timeout(const Duration(seconds: 15)),
      () => _UaClient(http.Client()),
    );
    return Style(
      name: s.name,
      theme: s.theme,
      sprites: s.sprites,
      center: s.center,
      zoom: s.zoom,
      providers: TileProviders(<String, VectorTileProvider>{
        for (final e in s.providers.tileProviderBySource.entries)
          e.key: _UaTileProvider(e.value),
      }),
    );
  }

  void resetForTest() {
    _styles.clear();
    _failedAt.clear();
  }
}
