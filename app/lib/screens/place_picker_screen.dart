import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../widgets/openfamily_map_layers.dart';
import '../models/place.dart';
import '../services/geocoding_service.dart';
import '../services/location_service.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';

/// A map-first place picker: a full-bleed map with a drop-pin fixed at the
/// center (drag the map to move the pin), an optional address label, and a
/// radius control (250 ft – 2 mi).
///
/// The map defaults to the user's CURRENT location (via [LocationService]),
/// falling back to a neutral world view when location is unavailable. Address
/// search is optional: when a self-hosted Nominatim instance is configured
/// ([GeocodingService.isEnabled]), typing an address moves the pin and
/// dropping the pin reverse-geocodes into the address field. Without that
/// add-on, the pin itself is the source of truth — save works with just a
/// name and the dropped coordinate.
///
/// Pops with the resulting [Place] (lat/lon + radius + address), or `null`
/// when cancelled.
class PlacePickerScreen extends StatefulWidget {
  const PlacePickerScreen({
    super.key,
    required this.placeName,
    required this.icon,
    this.type = 'custom',
    this.initial,
  });

  final String placeName;
  final IconData icon;

  /// Backend place type ("home"/"work"/"school"/"custom") carried through to
  /// the returned [Place].
  final String type;

  /// When editing an existing place, its current values seed the picker.
  final Place? initial;

  @override
  State<PlacePickerScreen> createState() => _PlacePickerScreenState();
}

class _PlacePickerScreenState extends State<PlacePickerScreen> {
  final MapController _mapController = MapController();
  late LatLng _position;
  late final TextEditingController _name;
  late final TextEditingController _address;
  late double _radiusMeters;

  /// Neutral fallback (0,0) shown at world zoom when the user's location can't
  /// be obtained — never a hardcoded city.
  static const LatLng _fallbackPosition = LatLng(0, 0);

  bool _locating = false;
  bool _searching = false;
  Timer? _reverseTimer;

  /// Radius presets in meters (250 ft, 500 ft, 1000 ft, 1 mi, 2 mi).
  static const List<double> _radiusPresets = <double>[
    76.2,
    152.4,
    304.8,
    1609.344,
    3218.69,
  ];

  @override
  void initState() {
    super.initState();
    _position = widget.initial?.position ?? _fallbackPosition;
    _name = TextEditingController(text: widget.placeName);
    _address = TextEditingController(text: widget.initial?.address ?? '');
    _radiusMeters = widget.initial?.radiusMeters ?? 152.4; // ~500 ft
    // Only auto-locate for a brand-new place; editing keeps the saved pin.
    if (widget.initial == null) {
      _locateUser();
    }
  }

  @override
  void dispose() {
    _reverseTimer?.cancel();
    _name.dispose();
    _address.dispose();
    super.dispose();
  }

  /// Centers the map on the user's current location, falling back to a neutral
  /// world view when location is unavailable.
  Future<void> _locateUser() async {
    setState(() => _locating = true);
    final LatLng? position = await LocationService.currentPosition();
    if (!mounted) return;
    setState(() {
      _locating = false;
      if (position != null) {
        _position = position;
        _mapController.move(position, 15);
      } else {
        _position = _fallbackPosition;
        _mapController.move(_fallbackPosition, 2);
      }
    });
  }

  /// Forward geocodes the typed address and moves the pin/map to the result.
  Future<void> _searchAddress(String query) async {
    final String q = query.trim();
    if (q.isEmpty || _searching) return;
    setState(() => _searching = true);
    final LatLng? result = await GeocodingService.search(q);
    if (!mounted) return;
    setState(() => _searching = false);
    if (result == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Couldn\'t find that address. Try a nearby landmark.'),
        ),
      );
      return;
    }
    setState(() => _position = result);
    _mapController.move(result, 15);
    // Fill the field with the canonical address for the matched coordinate.
    final String? canonical = await GeocodingService.reverse(result);
    if (canonical != null && mounted) {
      _address.text = canonical;
      _address.selection = TextSelection.collapsed(offset: _address.text.length);
    }
  }

  /// Called as the map moves; debounces reverse geocoding so we only hit the
  /// service once the user has stopped dragging (i.e. "dropped" the pin).
  /// Programmatic moves (locate/search) update the pin but skip reverse
  /// geocoding. When geocoding is off, the pin is the source of truth and we
  /// skip the lookup entirely.
  void _onMapMoved(LatLng center, bool hasGesture) {
    setState(() => _position = center);
    if (!hasGesture || !GeocodingService.isEnabled) return;
    _reverseTimer?.cancel();
    _reverseTimer = Timer(const Duration(milliseconds: 600), () {
      _reverseGeocode(center);
    });
  }

  Future<void> _reverseGeocode(LatLng center) async {
    final String? address = await GeocodingService.reverse(center);
    if (!mounted || address == null) return;
    _address.text = address;
    _address.selection = TextSelection.collapsed(offset: _address.text.length);
  }

  String _formatCoordinates(LatLng position) {
    return '${position.latitude.toStringAsFixed(5)}, '
        '${position.longitude.toStringAsFixed(5)}';
  }

  String _formatRadius(double meters) {
    if (meters >= 1609.344) {
      final double miles = meters / 1609.344;
      final String text = miles == miles.roundToDouble()
          ? miles.round().toString()
          : miles.toStringAsFixed(1);
      return '$text mi';
    }
    return '${(meters * 3.28084).round()} ft';
  }

  void _save() {
    final String name = _name.text.trim();
    if (name.isEmpty) {
      // The backend rejects places without a name, so require one here
      // instead of silently saving a blank label.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add a name for this place first.')),
      );
      return;
    }
    final String address = _address.text.trim();
    final Place place = Place(
      id: widget.initial?.id ??
          '${name.toLowerCase()}-'
              '${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      icon: widget.icon,
      address: address.isEmpty ? 'Pinned location' : address,
      position: _position,
      radiusMeters: _radiusMeters,
      type: widget.initial?.type ?? widget.type,
      alertsOn: widget.initial?.alertsOn ?? false,
    );
    Navigator.of(context).pop(place);
  }

  @override
  Widget build(BuildContext context) {
    final BrandTheme brand = BrandTheme.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    // The control panel never takes more than this share of the screen, so
    // the map stays usable and the panel scrolls at large text sizes.
    final double panelMax = MediaQuery.sizeOf(context).height * 0.55;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.placeName.isEmpty ? 'Add a place' : 'Set ${widget.placeName} location',
        ),
        actions: <Widget>[
          TextButton(
            style: TextButton.styleFrom(
              minimumSize: const Size(kMinTarget, kMinTarget),
            ),
            onPressed: _save,
            child: const Text('Save'),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          // Map-first: the map dominates the top of the screen.
          Expanded(
            child: Stack(
              children: <Widget>[
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: _position,
                    initialZoom: widget.initial != null ? 15 : 2,
                    minZoom: 3,
                    maxZoom: 18,
                    interactionOptions: const InteractionOptions(
                      flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                    ),
                    onPositionChanged: (MapCamera camera, bool hasGesture) {
                      _onMapMoved(camera.center, hasGesture);
                    },
                  ),
                  children: <Widget>[
                    const OpenFamilyTileLayer(),
                    // The geofence radius, drawn live around the pin.
                    CircleLayer(
                      circles: <CircleMarker>[
                        CircleMarker(
                          point: _position,
                          radius: _radiusMeters,
                          useRadiusInMeter: true,
                          color: brand.accent.withValues(alpha: 0.2),
                          borderColor: brand.accentInk,
                          borderStrokeWidth: 2,
                        ),
                      ],
                    ),
                  ],
                ),
                // Drop-pin fixed at the map center; dragging the map moves the
                // pin. Shifted up by half the glyph so the tip sits on center.
                IgnorePointer(
                  child: Center(
                    child: Transform.translate(
                      offset: const Offset(0, -24),
                      child: Icon(
                        Icons.location_pin,
                        size: 48,
                        color: brand.accentInk,
                        shadows: const <Shadow>[
                          Shadow(color: Color(0x66000000), blurRadius: 6),
                        ],
                      ),
                    ),
                  ),
                ),
                // Live coordinates so pin-drop is usable without address search.
                Positioned(
                  left: AppSpace.md,
                  right: AppSpace.md + kMinTarget,
                  top: AppSpace.md,
                  child: IgnorePointer(
                    child: Center(
                      child: Semantics(
                        label: 'Pin position ${_formatCoordinates(_position)}',
                        excludeSemantics: true,
                        child: Material(
                          color: brand.sheet,
                          elevation: 3,
                          borderRadius: BorderRadius.circular(AppRadius.pill),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: AppSpace.md,
                              vertical: AppSpace.xs + AppSpace.xxs,
                            ),
                            child: Text(
                              _formatCoordinates(_position),
                              style: AppType.secondary.copyWith(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: cs.onSurface,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // "Use my location" affordance, shown while locating or as a
                // way to re-center after the user has dragged away.
                Positioned(
                  right: AppSpace.md,
                  bottom: AppSpace.md,
                  child: DsMapButton(
                    icon: Icons.my_location,
                    tooltip: 'Use my location',
                    onPressed: _locating ? null : _locateUser,
                  ),
                ),
              ],
            ),
          ),
          // Address + radius controls.
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: panelMax),
            child: SafeArea(
              top: false,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(AppSpace.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    TextField(
                      controller: _name,
                      textCapitalization: TextCapitalization.words,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Name',
                        hintText: 'e.g. Grandma',
                        prefixIcon: Icon(Icons.label_outline),
                      ),
                    ),
                    const SizedBox(height: AppSpace.sm),
                    TextField(
                      controller: _address,
                      textCapitalization: TextCapitalization.words,
                      textInputAction: GeocodingService.isEnabled
                          ? TextInputAction.search
                          : TextInputAction.done,
                      onSubmitted:
                          GeocodingService.isEnabled ? _searchAddress : null,
                      decoration: InputDecoration(
                        labelText: GeocodingService.isEnabled
                            ? 'Address'
                            : 'Address (optional)',
                        hintText: 'e.g. 123 Maple St',
                        prefixIcon: const Icon(Icons.place_outlined),
                        suffixIcon: !GeocodingService.isEnabled
                            ? null
                            : _searching
                                ? const Padding(
                                    padding: EdgeInsets.all(AppSpace.md),
                                    child: SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                  )
                                : IconButton(
                                    icon: const Icon(Icons.search),
                                    tooltip: 'Search address',
                                    onPressed: () =>
                                        _searchAddress(_address.text),
                                  ),
                      ),
                    ),
                    const SizedBox(height: AppSpace.xs),
                    Text(
                      GeocodingService.isEnabled
                          ? 'Type an address to move the pin, or drag the map — '
                              'the address fills in automatically.'
                          : 'Drag the map to drop a pin, then save. Address '
                              'search needs a geocoding add-on — you can still '
                              'save the pin, and type a label here if you want.',
                      style: AppType.secondary.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: AppSpace.lg),
                    Row(
                      children: <Widget>[
                        const Expanded(
                          child: Text('Radius', style: AppType.body),
                        ),
                        Text(
                          _formatRadius(_radiusMeters),
                          style: AppType.body.copyWith(
                            fontWeight: FontWeight.w800,
                            color: brand.accentInk,
                          ),
                        ),
                      ],
                    ),
                    Slider(
                      value: _radiusMeters,
                      min: kMinPlaceRadiusMeters,
                      max: kMaxPlaceRadiusMeters,
                      semanticFormatterCallback: _formatRadius,
                      onChanged: (double v) =>
                          setState(() => _radiusMeters = v),
                    ),
                    Wrap(
                      spacing: AppSpace.sm,
                      runSpacing: AppSpace.xs,
                      children: <Widget>[
                        for (final double preset in _radiusPresets)
                          ChoiceChip(
                            label: Text(_formatRadius(preset)),
                            selected: (_radiusMeters - preset).abs() < 1,
                            onSelected: (_) =>
                                setState(() => _radiusMeters = preset),
                          ),
                      ],
                    ),
                    const SizedBox(height: AppSpace.lg),
                    DsPillButton(label: 'Save place', onPressed: _save),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
