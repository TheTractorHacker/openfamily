import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';

import '../services/map_style_preference.dart';
import '../services/map_style_service.dart';
import '../services/tile_config.dart';

/// Shared base-map layer for every FlutterMap in the app: crisp vector tiles
/// (OpenFreeMap by default, light/dark following the app theme), with
/// automatic fallback to the raster [TileConfig] URLs if the style cannot load.
class OpenFamilyTileLayer extends StatefulWidget {
  const OpenFamilyTileLayer({
    super.key,
    this.satellite = false,
    this.tileProvider,
    this.styleLoader,
    this.config,
    this.reducedData = false,
  });

  final bool satellite;

  /// When set (tests), a plain raster layer with this provider is used and no
  /// network style load happens.
  final TileProvider? tileProvider;

  /// Overridable style loader (tests).
  final MapStyleLoader? styleLoader;

  /// Defaults to [TileConfig.instance].
  final TileConfig? config;

  /// Smaller in-memory and on-disk caches.
  final bool reducedData;

  @override
  State<OpenFamilyTileLayer> createState() => _OpenFamilyTileLayerState();
}

class _OpenFamilyTileLayerState extends State<OpenFamilyTileLayer> {
  Future<Style>? _future;
  String? _futureUrl;

  Widget _raster(BuildContext context, String url) {
    return TileLayer(
      urlTemplate: url,
      userAgentPackageName: kMapUserAgentPackage,
      retinaMode: url.contains('{r}') && RetinaMode.isHighDensity(context),
      tileProvider: widget.tileProvider,
    );
  }

  @override
  Widget build(BuildContext context) {
    final TileConfig cfg = widget.config ?? TileConfig.instance;
    return ValueListenableBuilder<MapStylePreference>(
      valueListenable: MapStylePreferenceService.preference,
      builder: (BuildContext context, MapStylePreference pref, _) =>
          _buildLayer(context, cfg, pref),
    );
  }

  Widget _buildLayer(
      BuildContext context, TileConfig cfg, MapStylePreference pref) {
    final MapLayerChoice choice = resolveMapLayer(
      config: cfg,
      dark: pref.resolveDark(
          appIsDark: Theme.of(context).brightness == Brightness.dark),
      satellite: widget.satellite,
    );
    if (choice.kind == MapLayerKind.raster || widget.tileProvider != null) {
      return _raster(context, choice.rasterUrl ?? rasterFallbackUrl(cfg));
    }
    final String url = choice.styleUrl!;
    if (_futureUrl != url) {
      _futureUrl = url;
      _future = (widget.styleLoader ?? MapStyleService.instance.load)(url);
    }
    return FutureBuilder<Style>(
      future: _future,
      builder: (BuildContext context, AsyncSnapshot<Style> snap) {
        if (snap.hasError) return _raster(context, rasterFallbackUrl(cfg));
        final Style? style = snap.data;
        if (style == null) return const SizedBox.shrink();
        final bool low = widget.reducedData;
        return VectorTileLayer(
          key: ValueKey<String>(url),
          tileProviders: style.providers,
          theme: style.theme,
          sprites: style.sprites,
          layerMode: VectorTileLayerMode.vector,
          // Bounded disk cache (default 50 MB, 25 MB in reduced-data mode).
          fileCacheMaximumSizeInBytes: low ? 25 * 1024 * 1024 : 50 * 1024 * 1024,
          fileCacheTtl: const Duration(days: 14),
          memoryTileCacheMaxSize: low ? 4 * 1024 * 1024 : 10 * 1024 * 1024,
          concurrency: Platform.isAndroid || Platform.isIOS ? 2 : 1,
        );
      },
    );
  }
}
