import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../widgets/openfamily_map_layers.dart';
import '../models/trip.dart';
import '../models/trip_report.dart';
import '../services/speed_units.dart';
import '../services/trips_service.dart';
import '../theme/app_theme.dart';
import '../widgets/driving_event_chips.dart';
import '../widgets/ds/ds.dart';
import '../widgets/trip_widgets.dart';
import 'trips_screen.dart' show UnitToggleButton;

/// One trip: stats from the list row immediately, the route from the API.
class TripDetailScreen extends StatefulWidget {
  const TripDetailScreen({
    super.key,
    required this.trip,
    this.api,
    this.tileProvider,
  });

  final Trip trip;
  final TripsApi? api;
  final TileProvider? tileProvider;

  @override
  State<TripDetailScreen> createState() => _TripDetailScreenState();
}

class _TripDetailScreenState extends State<TripDetailScreen> {
  late final TripsApi _api = widget.api ?? TripsService.instance;

  TripDetail? _detail;
  List<TripStop> _stops = const <TripStop>[];
  TripsException? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    UnitPreferenceService.ensureLoaded();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final TripDetail d = await _api.getTrip(widget.trip.id);
      if (!mounted) return;
      setState(() {
        _detail = d;
        _loading = false;
      });
      _loadStops(d.trip);
    } on TripsException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  /// Best effort: stops are the gaps right before and after this trip in the
  /// day's report. Failures just mean no stop markers.
  Future<void> _loadStops(Trip t) async {
    try {
      final TripSummary s = await _api.summary(
        userId: t.userId,
        period: 'day',
        date: t.startedAt,
      );
      const Duration slack = Duration(seconds: 2);
      final List<TripStop> near = s.stops.where((TripStop p) {
        return (p.departedAt.difference(t.startedAt)).abs() <= slack ||
            (p.arrivedAt.difference(t.endedAt)).abs() <= slack;
      }).toList();
      if (mounted) setState(() => _stops = near);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final Trip t = _detail?.trip ?? widget.trip;
    return Scaffold(
      appBar: AppBar(
        title: Text('${tripModeLabel(t.mode)} trip'),
        actions: const <Widget>[UnitToggleButton()],
      ),
      body: DsBody(maxWidth: 760, child: ValueListenableBuilder<UnitSystem>(
        valueListenable: UnitPreferenceService.units,
        builder: (BuildContext context, UnitSystem units, _) {
          return RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(AppSpace.lg),
              children: <Widget>[
                _routeSection(t),
                const SizedBox(height: AppSpace.lg),
                _summary(context, t, units),
                const SizedBox(height: AppSpace.md),
                const GpsSpeedNote(),
              ],
            ),
          );
        },
      )),
    );
  }

  Widget _routeSection(Trip t) {
    if (_loading) {
      return Semantics(
        label: 'Loading route',
        child: const DsSkeleton(height: 260, radius: AppRadius.lg),
      );
    }
    if (_error != null) {
      final TripsMessageView v =
          TripsMessageView.error(_error!, onRetry: _load);
      return SizedBox(height: 300, child: v);
    }
    return TripRouteMap(
      trip: t,
      route: _detail!.route,
      stops: _stops,
      events: _detail!.events,
      tileProvider: widget.tileProvider,
    );
  }

  Widget _summary(BuildContext context, Trip t, UnitSystem units) {
    final BrandTheme brand = BrandTheme.of(context);
    return Container(
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(
        color: brand.sheet,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              TripModeBadge(mode: t.mode),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Text(
                  '${tripClock(context, t.startedAt)} - '
                  '${tripClock(context, t.endedAt)}',
                  style: AppType.headline,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: AppSpace.xxl,
            runSpacing: AppSpace.md,
            children: <Widget>[
              TripStat(
                label: 'Distance',
                value: units.formatDistance(t.distanceM),
              ),
              TripStat(
                label: 'Duration',
                value: formatTripDuration(t.duration),
              ),
              TripStat(
                label: 'Max GPS speed',
                value: units.formatSpeed(t.maxSpeedMps),
              ),
              TripStat(
                label: 'Avg GPS speed',
                value: units.formatSpeed(t.avgSpeedMps),
              ),
            ],
          ),
          if (_detail != null && _detail!.events.isNotEmpty)
            ..._eventsSection(context, _detail!.events, units),
          if (_stops.isNotEmpty) ...<Widget>[
            const SizedBox(height: AppSpace.lg),
            Semantics(
              header: true,
              child: const Text(
                'Stops next to this trip',
                style: AppType.headline,
              ),
            ),
            for (final TripStop s in _stops)
              Padding(
                padding: const EdgeInsets.only(top: AppSpace.sm),
                child: Row(
                  children: <Widget>[
                    const Icon(Icons.pause_circle_outline_rounded, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${formatTripDuration(Duration(seconds: s.durationS.round()))}'
                        ' stop, ${tripClock(context, s.arrivedAt)} - '
                        '${tripClock(context, s.departedAt)}',
                        style: AppType.body.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

extension on _TripDetailScreenState {
  List<Widget> _eventsSection(
    BuildContext context,
    List<TripEvent> events,
    UnitSystem units,
  ) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return <Widget>[
      const SizedBox(height: AppSpace.lg),
      Semantics(
        header: true,
        child: const Text('Driving events', style: AppType.headline),
      ),
      for (final TripEvent e in events)
        Padding(
          padding: const EdgeInsets.only(top: AppSpace.sm),
          child: Semantics(
            container: true,
            excludeSemantics: true,
            label: '${e.kind.label} at ${tripClock(context, e.startedAt)}'
                '${eventMagnitudeText(e, units) == null ? '' : ', ${eventMagnitudeText(e, units)}'}'
                ', estimated from GPS',
            child: Row(
              children: <Widget>[
                Icon(eventIcon(e.kind), size: 20, color: eventColor(e.kind)),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: Text(
                    '${e.kind.label}, ${tripClock(context, e.startedAt)}'
                    '${eventMagnitudeText(e, units) == null ? '' : ' \u00b7 ${eventMagnitudeText(e, units)}'}',
                    style: AppType.body.copyWith(fontWeight: FontWeight.w500),
                  ),
                ),
              ],
            ),
          ),
        ),
      Padding(
        padding: const EdgeInsets.only(top: AppSpace.xs),
        child: Text(
          'Estimated from GPS',
          style: AppType.secondary.copyWith(color: cs.onSurfaceVariant),
        ),
      ),
    ];
  }
}

/// Route polyline with start / end / stop markers on the app's tile layer.
class TripRouteMap extends StatelessWidget {
  const TripRouteMap({
    super.key,
    this.tileProvider,
    required this.trip,
    required this.route,
    this.stops = const <TripStop>[],
    this.events = const <TripEvent>[],
    this.height = 280,
  });

  final Trip trip;
  final List<TripRoutePoint> route;
  final List<TripStop> stops;
  final List<TripEvent> events;
  final double height;

  /// Overridable so tests need no network.
  final TileProvider? tileProvider;

  List<LatLng> get _line => route.length >= 2
      ? route.map((TripRoutePoint p) => p.position).toList()
      : <LatLng>[trip.start, trip.end];

  @override
  Widget build(BuildContext context) {
    final List<LatLng> line = _line;
    final List<LatLng> all = <LatLng>[...line, ...stops.map((s) => s.position)];
    double minLat = all.first.latitude, maxLat = minLat;
    double minLon = all.first.longitude, maxLon = minLon;
    for (final LatLng p in all) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLon) minLon = p.longitude;
      if (p.longitude > maxLon) maxLon = p.longitude;
    }
    final bool tiny = (maxLat - minLat) < 0.0005 && (maxLon - minLon) < 0.0005;
    final LatLng start = line.first;
    final LatLng end = line.last;
    return Semantics(
      label: 'Map of the ${tripModeLabel(trip.mode).toLowerCase()} trip route '
          'from start to end',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: SizedBox(
          height: height,
          child: FlutterMap(
            options: MapOptions(
              initialCenter: LatLng(
                (minLat + maxLat) / 2,
                (minLon + maxLon) / 2,
              ),
              initialZoom: 15,
              initialCameraFit: tiny
                  ? null
                  : CameraFit.bounds(
                      bounds: LatLngBounds(
                        LatLng(minLat, minLon),
                        LatLng(maxLat, maxLon),
                      ),
                      padding: const EdgeInsets.all(40),
                    ),
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
              ),
            ),
            children: <Widget>[
              OpenFamilyTileLayer(tileProvider: tileProvider),
              PolylineLayer(
                polylines: <Polyline>[
                  Polyline(
                    points: line,
                    color: AppColors.historyTrail,
                    strokeWidth: 4.5,
                    borderColor: Colors.white,
                    borderStrokeWidth: 1.5,
                  ),
                ],
              ),
              MarkerLayer(
                markers: <Marker>[
                  for (final TripStop s in stops)
                    Marker(
                      point: s.position,
                      width: 32,
                      height: 32,
                      child: const _Pin(
                        icon: Icons.pause_rounded,
                        color: AppColors.statusOrange,
                        label: 'Stop',
                      ),
                    ),
                  for (final TripEvent e in events)
                    if (e.position != null)
                      Marker(
                        point: e.position!,
                        width: 28,
                        height: 28,
                        child: _Pin(
                          icon: eventIcon(e.kind),
                          color: eventColor(e.kind),
                          label: '${e.kind.label} (estimated)',
                        ),
                      ),
                  Marker(
                    point: start,
                    width: 36,
                    height: 36,
                    child: const _Pin(
                      icon: Icons.play_arrow_rounded,
                      color: AppColors.statusGreen,
                      label: 'Trip start',
                    ),
                  ),
                  Marker(
                    point: end,
                    width: 36,
                    height: 36,
                    child: const _Pin(
                      icon: Icons.flag_rounded,
                      color: AppColors.statusRed,
                      label: 'Trip end',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Pin extends StatelessWidget {
  const _Pin({required this.icon, required this.color, required this.label});

  final IconData icon;
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      excludeSemantics: true,
      child: Container(
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
          boxShadow: const <BoxShadow>[
            BoxShadow(color: Color(0x44000000), blurRadius: 4),
          ],
        ),
        child: Icon(icon, color: Colors.white, size: 20),
      ),
    );
  }
}
