import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';

import '../models/alert.dart';
import '../models/place.dart';
import '../services/alert_service.dart';
import '../services/api_client.dart';
import 'alert_status_screen.dart';
import '../services/location_service.dart';
import '../services/place_service.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';

/// Places farther than this are hidden unless nothing is closer.
const double kCheckInNearbyMeters = 1500;

/// How many places to show when none are within [kCheckInNearbyMeters].
const int kCheckInFallbackCount = 5;

/// A saved place plus its distance from the user (null when unknown).
class NearbyPlace {
  const NearbyPlace(this.place, this.meters);
  final Place place;
  final double? meters;
}

/// Sorts [places] nearest first and keeps those within [radius]; falls back to
/// the nearest [kCheckInFallbackCount]. Without a position, name order.
List<NearbyPlace> nearbyPlaces(List<Place> places, LatLng? from,
    {double radius = kCheckInNearbyMeters}) {
  if (from == null) {
    final List<Place> sorted = List<Place>.of(places)
      ..sort((Place a, Place b) =>
          a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return <NearbyPlace>[for (final Place p in sorted) NearbyPlace(p, null)];
  }
  const Distance d = Distance();
  final List<NearbyPlace> all = <NearbyPlace>[
    for (final Place p in places)
      NearbyPlace(p, d.as(LengthUnit.Meter, from, p.position).toDouble()),
  ]..sort((NearbyPlace a, NearbyPlace b) => a.meters!.compareTo(b.meters!));
  final List<NearbyPlace> within =
      all.where((NearbyPlace n) => n.meters! <= radius).toList();
  if (within.isNotEmpty) return within;
  return all.take(kCheckInFallbackCount).toList();
}

/// The Check In flow, reached from the map's `+` action sheet. Life360-style:
/// name your location, or tap one of the family's nearby saved places.
class CheckInScreen extends StatefulWidget {
  const CheckInScreen({
    super.key,
    this.loadPlaces,
    this.loadPosition,
    this.send,
  });

  /// Test seams; default to the real services.
  final Future<List<Place>> Function()? loadPlaces;
  final Future<LatLng?> Function()? loadPosition;

  /// Sends the check-in body and returns the alert id (or null).
  final Future<String?> Function(Map<String, dynamic> body)? send;

  @override
  State<CheckInScreen> createState() => _CheckInScreenState();
}

class _CheckInScreenState extends State<CheckInScreen> {
  final TextEditingController _note = TextEditingController();
  bool _sent = false;
  String? _alertId;
  bool _sending = false;
  String? _error;
  bool _loading = true;
  String? _loadError;
  List<NearbyPlace> _nearby = const <NearbyPlace>[];
  double? _lat;
  double? _lon;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    final Future<LatLng?> posF =
        (widget.loadPosition ?? LocationService.currentPosition)();
    List<Place>? places;
    String? err;
    try {
      places = await (widget.loadPlaces ?? PlaceService.fetchPlaces)();
    } on SessionExpiredException {
      return;
    } catch (e) {
      err = alertErrorMessage(e);
    }
    LatLng? pos;
    try {
      pos = await posF;
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _loading = false;
      _loadError = err;
      _lat = pos?.latitude;
      _lon = pos?.longitude;
      _nearby = places == null
          ? const <NearbyPlace>[]
          : nearbyPlaces(places, pos);
    });
  }

  Future<void> _checkIn(String name, {LatLng? at}) async {
    if (_sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final Map<String, dynamic> body = <String, dynamic>{
        'note': name.length > 280 ? name.substring(0, 280) : name,
      };
      final double? lat = at?.latitude ?? _lat;
      final double? lon = at?.longitude ?? _lon;
      if (lat != null && lon != null) {
        body['lat'] = lat;
        body['lon'] = lon;
      }
      if (widget.send != null) {
        _alertId = await widget.send!(body);
      } else {
        final dynamic response =
            await ApiClient.post('/alerts/check-in', body: body);
        if (response is Map && response['id'] is String) {
          _alertId = response['id'] as String;
        }
      }
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      setState(() {
        _sent = true;
        _sending = false;
      });
    } on SessionExpiredException {
      return;
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = 'Not sent. ${alertErrorMessage(e)}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = 'Not sent. ${alertErrorMessage(e)}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_sent && _alertId != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Check In')),
        body: SafeArea(
          child: AlertStatusBody(
            alertId: _alertId!,
            kind: AlertKind.checkIn,
            title: 'Checked in',
            footer: <Widget>[
              DsPillButton(
                label: 'Done',
                style: DsPillStyle.tonal,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
      );
    }
    if (_sent) return _buildSent();
    return _buildForm();
  }

  void _submitTyped() {
    final String name = _note.text.trim();
    if (name.isEmpty) return;
    _checkIn(name);
  }

  String _distanceLabel(double? m) {
    if (m == null) return '';
    if (m < 1000) return '${m.round()} m away';
    return '${(m / 1000).toStringAsFixed(1)} km away';
  }

  Widget _buildForm() {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Widget field = Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpace.lg, AppSpace.sm, AppSpace.lg, AppSpace.sm),
      child: TextField(
        controller: _note,
        enabled: !_sending,
        textInputAction: TextInputAction.done,
        textCapitalization: TextCapitalization.sentences,
        maxLength: 280,
        maxLengthEnforcement: MaxLengthEnforcement.enforced,
        onSubmitted: (_) => _submitTyped(),
        decoration: InputDecoration(
          hintText: 'Name your current location',
          counterText: '',
          prefixIcon: const Icon(Icons.place_outlined),
          border: const UnderlineInputBorder(),
          enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: cs.outlineVariant)),
          filled: false,
        ),
      ),
    );
    final List<Widget> list = <Widget>[];
    if (_loading) {
      list.add(const Padding(
        padding: EdgeInsets.all(AppSpace.xxl),
        child: Center(child: CircularProgressIndicator()),
      ));
    } else if (_loadError != null) {
      list.add(DsErrorState(
        message: 'Could not load nearby locations. $_loadError',
        onRetry: _load,
      ));
    } else if (_nearby.isEmpty) {
      list.add(Padding(
        padding: const EdgeInsets.all(AppSpace.xl),
        child: Text(
          'No saved places yet. Type a name above to check in.',
          style: AppType.secondary.copyWith(color: cs.onSurfaceVariant),
        ),
      ));
    } else {
      list.add(Container(
        width: double.infinity,
        color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.lg, vertical: AppSpace.sm),
        child: Semantics(
          header: true,
          child: Text('Nearby locations',
              style: AppType.secondary.copyWith(color: cs.onSurfaceVariant)),
        ),
      ));
      for (final NearbyPlace n in _nearby) {
        final bool home = n.place.type == 'home';
        list.add(InkWell(
          onTap: _sending
              ? null
              : () => _checkIn(n.place.name, at: n.place.position),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 72),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpace.lg, vertical: AppSpace.md),
              child: Row(
                children: <Widget>[
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: cs.outline),
                    ),
                    child: Icon(home ? Icons.home_outlined : Icons.place_outlined,
                        size: 22, color: cs.onSurface),
                  ),
                  const SizedBox(width: AppSpace.lg),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(n.place.name,
                            style: AppType.body
                                .copyWith(fontWeight: FontWeight.w700)),
                        if (n.meters != null)
                          Text(_distanceLabel(n.meters),
                              style: AppType.secondary
                                  .copyWith(color: cs.onSurfaceVariant)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ));
      }
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Check In')),
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: Column(
          children: <Widget>[
            field,
            if (_sending) const LinearProgressIndicator(),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
                child: DsMessage(_error!),
              ),
            Expanded(
              child: ListView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                children: list,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSent() {
    return DsPage(
      title: 'Check In',
      showBack: false,
      actions: <Widget>[
        DsPillButton(label: 'Done', onPressed: () => Navigator.of(context).pop()),
      ],
      children: <Widget>[
        const SizedBox(height: AppSpace.xxl),
        const Center(
          child: Icon(Icons.check_circle, size: 72, color: AppColors.statusGreen),
        ),
        const SizedBox(height: AppSpace.lg),
        const DsHeading(
          'Checked in',
          subtitle: 'Your family was notified. Emergency services were NOT contacted.',
          center: true,
        ),
      ],
    );
  }
}
