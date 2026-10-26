import 'dart:math' as math;
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../widgets/openfamily_map_layers.dart';
import '../models/place.dart';
import '../services/address_suggester.dart';
import '../services/geocoding_service.dart';
import '../services/location_service.dart';
import '../theme/app_theme.dart';
import '../widgets/address_suggestions.dart';
import '../widgets/ds/ds.dart';

/// A map-first place picker: a full-bleed map with a drop-pin fixed at the
/// center (drag the map to move the pin), an optional address label, and a
/// radius control (250 ft – 2 mi).
///
/// The map defaults to the user's CURRENT location (via [LocationService]),
/// falling back to a neutral world view when location is unavailable. Address
/// search is optional: when the server advertises a geocoder
/// ([GeocodingService.isEnabled]), typing shows autocomplete suggestions (pick
/// one to move the pin and fill the address) and dropping the pin detects the
/// address. A manually typed address is never overwritten without asking.
/// Without a geocoder the pin itself is the source of truth — save works with
/// just a name and the dropped coordinate.
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
  Timer? _reverseTimer;
  late final AddressSuggester _suggester;
  final FocusNode _addressFocus = FocusNode();

  /// True once the user typed in the address field (so pin moves must ask
  /// before replacing it).
  bool _userEdited = false;
  bool _detecting = false;
  bool _detectFailed = false;
  int _reverseGen = 0;

  /// A detected address for a moved pin, offered when the field holds a
  /// manually typed address.
  String? _offeredAddress;

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
    final String initialAddress = widget.initial?.address ?? '';
    _address = TextEditingController(
      text: initialAddress == 'Pinned location' ? '' : initialAddress,
    );
    // An address already stored on an existing place counts as manual.
    _userEdited = _address.text.trim().isNotEmpty;
    _suggester = AddressSuggester(
      nearProvider: () => _position == _fallbackPosition ? null : _position,
    );
    _radiusMeters = widget.initial?.radiusMeters ?? 152.4; // ~500 ft
    // Only auto-locate for a brand-new place; editing keeps the saved pin.
    if (widget.initial == null) {
      _locateUser();
    }
  }

  @override
  void dispose() {
    _reverseTimer?.cancel();
    _reverseGen++;
    _suggester.dispose();
    _addressFocus.dispose();
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

  /// Explicit search (keyboard "search" key or the search button).
  void _submitAddress(String query) {
    if (!GeocodingService.isEnabled) return;
    _suggester.submit(query);
  }

  /// The user picked a suggestion: move the pin, fill the address.
  void _selectSuggestion(GeocodeSuggestion s) {
    _reverseTimer?.cancel();
    _reverseGen++; // drop any in-flight pin-drop lookup
    _suggester.clear();
    _addressFocus.unfocus();
    setState(() {
      _position = s.position;
      _userEdited = false;
      _detecting = false;
      _detectFailed = false;
      _offeredAddress = null;
      _address.text = s.label;
      _address.selection = TextSelection.collapsed(offset: s.label.length);
    });
    _mapController.move(s.position, 17);
  }

  void _onAddressEdited(String text) {
    _userEdited = text.trim().isNotEmpty;
    _offeredAddress = null;
    _detectFailed = false;
    _suggester.onTextChanged(text);
    setState(() {});
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
    final int gen = ++_reverseGen;
    final bool manual = _userEdited && _address.text.trim().isNotEmpty;
    if (!manual) setState(() => _detecting = true);
    final String? address = await GeocodingService.reverse(center);
    if (!mounted || gen != _reverseGen) return; // stale: pin moved again
    setState(() {
      _detecting = false;
      if (manual) {
        // Never overwrite a typed address silently: offer it instead.
        _offeredAddress = address;
        return;
      }
      if (address == null) {
        // The old auto-filled text no longer describes this pin.
        _address.clear();
        _detectFailed = true;
        return;
      }
      _detectFailed = false;
      _address.text = address;
      _address.selection = TextSelection.collapsed(offset: address.length);
    });
  }

  void _useOfferedAddress() {
    final String? a = _offeredAddress;
    if (a == null) return;
    setState(() {
      _address.text = a;
      _address.selection = TextSelection.collapsed(offset: a.length);
      _userEdited = false;
      _offeredAddress = null;
    });
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

  /// One status line under the address field: detecting, failure, an offer to
  /// use a detected address, or the standing hint.
  Widget _addressStatus(ColorScheme cs) {
    final TextStyle style = AppType.secondary.copyWith(
      color: cs.onSurfaceVariant,
    );
    if (!GeocodingService.isEnabled) {
      return Text(
        'Drag the map to drop a pin, then save. Address search is off on this '
        'server — you can still save the pin, and type a label here if you '
        'want.',
        style: style,
      );
    }
    if (_detecting) {
      return Semantics(
        liveRegion: true,
        child: Row(
          children: <Widget>[
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: AppSpace.sm),
            Expanded(child: Text('Detecting address…', style: style)),
          ],
        ),
      );
    }
    if (_offeredAddress != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Semantics(
            liveRegion: true,
            child: Text(
              'You moved the pin. Use "$_offeredAddress" as the address?',
              style: style,
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(
              minimumSize: const Size(kMinTarget, kMinTarget),
            ),
            onPressed: _useOfferedAddress,
            child: const Text('Use detected address'),
          ),
        ],
      );
    }
    if (_detectFailed) {
      return Semantics(
        liveRegion: true,
        child: Text(
          'Couldn\'t detect an address here. It will be saved as "Pinned '
          'location" unless you type one.',
          style: style,
        ),
      );
    }
    // The suggestion box already speaks (matches / no matches); do not stack
    // the standing hint on top of it.
    if (_suggester.visible) return const SizedBox.shrink();
    return Text(
      'Start typing an address for suggestions, or drag the map — the '
      'address fills in automatically.',
      style: style,
    );
  }

  @override
  Widget build(BuildContext context) {
    final BrandTheme brand = BrandTheme.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
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
      // Keep clear of a landscape cutout / side gesture area; the status bar
      // is the app bar's and the gesture bar is the panel's.
      body: SafeArea(
        top: false,
        bottom: false,
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints box) {
            final bool wide = box.maxWidth >= 720 ||
                (box.maxWidth > box.maxHeight * 1.2 && box.maxWidth >= 560);
            final bool keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
            final Widget mapPane = _mapPane(
              brand,
              cs,
              // Full-height map in two-pane mode runs under the gesture bar.
              wide ? MediaQuery.paddingOf(context).bottom : 0,
            );
            if (wide) {
              // Map beside the form: both stay usable in landscape.
              return Row(
                children: <Widget>[
                  Expanded(child: mapPane),
                  SizedBox(
                    width: (box.maxWidth * 0.4).clamp(360.0, 440.0),
                    child: _panel(brand, cs),
                  ),
                ],
              );
            }
            // The form takes at most this share of the screen (more with the
            // keyboard up) so the map stays visible and the form scrolls.
            final double panelMax = keyboard
                ? math.max(box.maxHeight * 0.6, box.maxHeight - 130)
                : box.maxHeight * 0.6;
            return Column(
              children: <Widget>[
                Expanded(child: mapPane),
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: panelMax),
                  child: _panel(brand, cs),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _panel(BrandTheme brand, ColorScheme cs) {
    return SafeArea(
      top: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Flexible(
            child: SingleChildScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.fromLTRB(
                AppSpace.lg,
                AppSpace.lg,
                AppSpace.lg,
                AppSpace.sm,
              ),
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
                      focusNode: _addressFocus,
                      textCapitalization: TextCapitalization.words,
                      textInputAction: GeocodingService.isEnabled
                          ? TextInputAction.search
                          : TextInputAction.done,
                      onChanged: _onAddressEdited,
                      onSubmitted:
                          GeocodingService.isEnabled ? _submitAddress : null,
                      decoration: InputDecoration(
                        labelText: GeocodingService.isEnabled
                            ? 'Address'
                            : 'Address (optional)',
                        hintText: 'e.g. 123 Maple St',
                        prefixIcon: const Icon(Icons.place_outlined),
                        suffixIcon: !GeocodingService.isEnabled
                            ? null
                            : IconButton(
                                icon: const Icon(Icons.search),
                                tooltip: 'Search address',
                                onPressed: () => _submitAddress(_address.text),
                              ),
                      ),
                    ),
                    if (GeocodingService.isEnabled)
                      AddressSuggestionList(
                        suggester: _suggester,
                        onSelected: _selectSuggestion,
                      ),
                    const SizedBox(height: AppSpace.xs),
                    ListenableBuilder(
                      listenable: _suggester,
                      builder: (BuildContext context, _) => _addressStatus(cs),
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
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: <Widget>[
                          for (final double preset in _radiusPresets)
                            Padding(
                              padding: const EdgeInsets.only(
                                right: AppSpace.sm,
                              ),
                              child: ChoiceChip(
                                label: Text(_formatRadius(preset)),
                                selected: (_radiusMeters - preset).abs() < 1,
                                onSelected: (_) =>
                                    setState(() => _radiusMeters = preset),
                              ),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          // Pinned so the primary action is always reachable, above both the
          // keyboard and the gesture bar.
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.lg,
              AppSpace.sm,
              AppSpace.lg,
              AppSpace.lg,
            ),
            child: DsPillButton(label: 'Save place', onPressed: _save),
          ),
        ],
      ),
    );
  }

  Widget _mapPane(BrandTheme brand, ColorScheme cs, double bottomInset) {
    return Stack(
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
              bottom: AppSpace.md + bottomInset,
              child: DsMapButton(
                icon: Icons.my_location,
                tooltip: 'Use my location',
                onPressed: _locating ? null : _locateUser,
              ),
            ),
          ],
        );
  }
}
