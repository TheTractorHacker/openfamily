import 'package:flutter/material.dart';

import '../models/place.dart';
import '../services/api_client.dart';
import '../services/family_service.dart';
import '../services/geofence_service.dart';
import '../services/place_service.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';
import 'place_picker_screen.dart';

/// What [PlacesScreen] needs to render: the places (with `alertsOn` set), and
/// who is looking.
class PlacesSnapshot {
  const PlacesSnapshot({
    required this.places,
    this.role = 'member',
    this.userId = '',
  });

  final List<Place> places;
  final String role;
  final String userId;
}

/// The Places / geofences list screen. Lists saved Places with their radius
/// and an arrive/leave alert toggle, and lets the user add a new Place.
class PlacesScreen extends StatefulWidget {
  const PlacesScreen({super.key, this.loader});

  /// Replaces the network load (tests and screenshots). Returns the places
  /// with their alert state already applied, plus the caller's role and id.
  final Future<PlacesSnapshot> Function()? loader;

  @override
  State<PlacesScreen> createState() => _PlacesScreenState();
}

class _PlacesScreenState extends State<PlacesScreen> {
  final FamilyService _familyService = FamilyService();

  List<Place>? _places;
  String? _error;
  String _role = 'member';
  String _userId = '';

  /// True while a geofence create/delete is in flight, to disable the toggle.
  bool _toggling = false;

  /// Whether the caller can manage places (add/delete). Children cannot.
  bool get _canManage => _role != 'child';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _places = null;
      _error = null;
    });
    try {
      final Future<PlacesSnapshot> Function()? custom = widget.loader;
      if (custom != null) {
        final PlacesSnapshot snap = await custom();
        if (!mounted) return;
        setState(() {
          _role = snap.role;
          _userId = snap.userId;
          _places = List<Place>.of(snap.places);
        });
        return;
      }
      final List<dynamic> results = await Future.wait<dynamic>([
        _familyService.fetchFamily(),
        PlaceService.fetchPlaces(),
        GeofenceService.fetchGeofences(),
      ]);
      final FamilyInfo family = results[0] as FamilyInfo;
      final List<Place> places = results[1] as List<Place>;
      final List<Geofence> geofences = results[2] as List<Geofence>;
      if (!mounted) return;
      setState(() {
        _role = family.role;
        _userId = family.userId;
        _places = _applyGeofences(places, geofences);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _errorMessage(e));
    }
  }

  /// Marks each place's [Place.alertsOn] from the geofences that belong to the
  /// caller (or are family-wide, i.e. `user_id == null`).
  List<Place> _applyGeofences(List<Place> places, List<Geofence> geofences) {
    return places.map((Place p) {
      Geofence? match;
      for (final Geofence g in geofences) {
        if (g.placeId == p.id && (g.userId == null || g.userId == _userId)) {
          match = g;
          break;
        }
      }
      if (match == null) {
        return p.copyWith(alertsOn: false, geofenceId: Place.clearGeofence);
      }
      return p.copyWith(alertsOn: true, geofenceId: match.id);
    }).toList();
  }

  String _errorMessage(Object e) {
    if (e is ApiException) return e.message;
    return 'Couldn\'t load places. Please try again.';
  }

  Future<void> _addPlace() async {
    final Place? picked = await Navigator.of(context).push<Place>(
      MaterialPageRoute<Place>(
        builder: (_) => const PlacePickerScreen(
          placeName: '',
          icon: Icons.place_outlined,
        ),
      ),
    );
    if (picked == null || !mounted) return;
    try {
      final Place created = await PlaceService.createPlace(
        name: picked.name,
        type: picked.type,
        lat: picked.position.latitude,
        lon: picked.position.longitude,
        radiusMeters: picked.radiusMeters,
        address: picked.address,
      );
      if (!mounted) return;
      setState(() => _places = <Place>[...?_places, created]);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_errorMessage(e))),
      );
    }
  }

  Future<void> _deletePlace(Place place) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete place?'),
        content: Text('Remove "${place.name}" from your family\'s places?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await PlaceService.deletePlace(place.id);
      if (!mounted) return;
      setState(() {
        _places = _places!.where((Place p) => p.id != place.id).toList();
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_errorMessage(e))),
      );
    }
  }

  Future<void> _toggleAlerts(int index) async {
    if (_toggling) return;
    final List<Place> places = _places!;
    final Place place = places[index];
    final bool turningOn = !place.alertsOn;

    // Optimistically flip the toggle; revert on failure.
    setState(() {
      _toggling = true;
      places[index] = place.copyWith(alertsOn: turningOn);
    });

    try {
      if (turningOn) {
        final Geofence geofence = await GeofenceService.createGeofence(
          placeId: place.id,
          userId: _userId.isEmpty ? null : _userId,
          enterNotify: true,
          exitNotify: true,
        );
        if (!mounted) return;
        setState(() {
          places[index] = places[index].copyWith(geofenceId: geofence.id);
        });
      } else {
        final String? geofenceId = place.geofenceId;
        if (geofenceId != null) {
          await GeofenceService.deleteGeofence(geofenceId);
        }
        if (!mounted) return;
        setState(() {
          places[index] = places[index].copyWith(
            geofenceId: Place.clearGeofence,
          );
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => places[index] = place); // revert
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_errorMessage(e))),
      );
    } finally {
      if (mounted) {
        setState(() => _toggling = false);
      } else {
        _toggling = false;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Places')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: _buildBody(),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return DsErrorState(
        icon: Icons.cloud_off,
        title: 'Could not load places',
        message: _error!,
        onRetry: _load,
      );
    }
    final List<Place>? places = _places;
    if (places == null) {
      return Semantics(
        label: 'Loading places',
        child: const Padding(
          padding: EdgeInsets.all(AppSpace.xl),
          child: DsSkeletonList(rows: 4),
        ),
      );
    }
    if (places.isEmpty) {
      return ListView(
        padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
        children: <Widget>[
          const DsEmptyState(
            icon: Icons.place_outlined,
            title: 'No places yet',
            message: 'Add one to start getting arrival and departure alerts.',
          ),
          if (_canManage) _AddPlaceTile(onTap: _addPlace),
        ],
      );
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
      children: <Widget>[
        const DsSectionHeader('Saved places'),
        for (int i = 0; i < places.length; i++)
          _PlaceTile(
            place: places[i],
            onToggleAlerts: _canManage ? () => _toggleAlerts(i) : null,
            toggling: _toggling,
            onDelete: _canManage ? () => _deletePlace(places[i]) : null,
          ),
        if (_canManage) _AddPlaceTile(onTap: _addPlace),
      ],
    );
  }
}

class _PlaceTile extends StatelessWidget {
  const _PlaceTile({
    required this.place,
    required this.onToggleAlerts,
    required this.toggling,
    required this.onDelete,
  });

  final Place place;
  final VoidCallback? onToggleAlerts;
  final bool toggling;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final BrandTheme brand = BrandTheme.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final String where = place.address.isEmpty
        ? place.radiusLabel
        : '${place.address} · ${place.radiusLabel}';
    // Words, not just colour: the alert state is part of the subtitle.
    final String subtitle =
        '$where\nArrival and departure alerts: ${place.alertsOn ? 'on' : 'off'}';
    return DsListRow(
      leading: DsListRow.iconTile(context, place.icon),
      title: place.name,
      subtitle: subtitle,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.end,
        children: <Widget>[
          if (onToggleAlerts != null)
            IconButton(
              tooltip: place.alertsOn ? 'Alerts on' : 'Alerts off',
              constraints: const BoxConstraints(
                minWidth: kMinTarget,
                minHeight: kMinTarget,
              ),
              icon: Icon(
                place.alertsOn
                    ? Icons.notifications_active
                    : Icons.notifications_off_outlined,
                color: place.alertsOn ? brand.accentInk : cs.onSurfaceVariant,
              ),
              onPressed: toggling ? null : onToggleAlerts,
            ),
          if (onDelete != null)
            IconButton(
              tooltip: 'Delete place',
              constraints: const BoxConstraints(
                minWidth: kMinTarget,
                minHeight: kMinTarget,
              ),
              icon: Icon(Icons.delete_outline, color: cs.onSurfaceVariant),
              onPressed: onDelete,
            ),
        ],
      ),
    );
  }
}

class _AddPlaceTile extends StatelessWidget {
  const _AddPlaceTile({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return DsListRow(
      leading: DsListRow.iconTile(context, Icons.add),
      title: 'Add a Place',
      chevron: true,
      onTap: onTap,
    );
  }
}
