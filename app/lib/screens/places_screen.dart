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
  const PlacesScreen({
    super.key,
    this.loader,
    this.updater,
    this.deleter,
    this.unsharedLoader,
    this.sharer,
  });

  /// Replaces the network load (tests and screenshots). Returns the places
  /// with their alert state already applied, plus the caller's role and id.
  final Future<PlacesSnapshot> Function()? loader;

  /// Replaces the PATCH call (tests). Receives the place with its edited
  /// values and returns what the server saved.
  final Future<Place> Function(Place edited)? updater;

  /// Replaces the DELETE call (tests).
  final Future<void> Function(String placeId)? deleter;

  /// Replaces [PlaceService.circlesToShare] (tests): Private circles whose
  /// places on this phone the other members cannot read yet.
  final Future<Set<String>> Function()? unsharedLoader;

  /// Replaces [PlaceService.sharePlacesWithCircle] (tests).
  final Future<int> Function(String circleId)? sharer;

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

  /// Private circles whose places on this phone the others cannot read yet.
  Set<String> _unshared = <String>{};

  /// The circle whose places are being shared right now.
  String? _sharing;

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
        await _loadUnshared();
        return;
      }
      final List<dynamic> results = await Future.wait<dynamic>([
        _familyService.fetchFamily(),
        PlaceService.fetchPlaces(force: true),
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
      await _loadUnshared();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _errorMessage(e));
    }
  }

  Future<void> _loadUnshared() async {
    Set<String> s = <String>{};
    try {
      // A custom loader (tests, screenshots) without its own answer: nothing to share.
      s = await (widget.unsharedLoader ??
          (widget.loader != null
              ? () async => <String>{}
              : PlaceService.circlesToShare))();
    } catch (_) {}
    if (!mounted) return;
    setState(() => _unshared = s);
  }

  String _circleLabel(String circleId) {
    for (final Place p in _places ?? const <Place>[]) {
      if (p.circleId == circleId && (p.circleName ?? '').isNotEmpty) {
        return p.circleName!;
      }
    }
    return 'the circle';
  }

  /// "Share places with the circle": seals this phone's places of [circleId]
  /// again under the circle's current key, so every member's phone can read them.
  Future<void> _sharePlaces(String circleId) async {
    if (_sharing != null) return;
    setState(() => _sharing = circleId);
    String msg;
    try {
      final int n =
          await (widget.sharer ?? PlaceService.sharePlacesWithCircle)(circleId);
      msg = n == 0
          ? 'There were no places to share.'
          : '$n ${n == 1 ? 'place was' : 'places were'} shared with '
              '${_circleLabel(circleId)}. They appear on the other members\' '
              'phones the next time those phones open Orbitly.';
    } catch (_) {
      msg = 'Places could not be shared yet: this phone does not have the '
          'circle\'s current key. Open the circle\'s Encryption keys, then try '
          'again.';
    }
    if (!mounted) return;
    setState(() => _sharing = null);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    await _loadUnshared();
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

  /// A sentence for a failed edit/delete: permission, vanished place, clash
  /// with another place, offline, or the server's own text.
  String _changeError(Object e, String verb) {
    if (e is ApiException) {
      switch (e.status) {
        case 403:
          return 'You can\'t $verb this place. Only the person who added it '
              '(or a family admin) can.';
        case 404:
          return 'This place no longer exists. The list was refreshed.';
        case 409:
          return 'This place was changed by someone else. The list was '
              'refreshed: try again.';
        case 0:
          return '${e.message} Your change was not saved.';
        default:
          return e.message;
      }
    }
    return 'Couldn\'t $verb this place. Please try again.';
  }

  bool _refreshNeeded(Object e) =>
      e is ApiException && (e.status == 404 || e.status == 409);

  bool _editing = false;

  /// Opens the picker pre-filled with [place]; on save, updates optimistically
  /// and rolls back if the server refuses.
  Future<void> _editPlace(Place place) async {
    if (_editing) return;
    final Place? edited = await Navigator.of(context).push<Place>(
      MaterialPageRoute<Place>(
        builder: (_) => PlacePickerScreen(
          placeName: place.name,
          icon: place.icon,
          type: place.type,
          initial: place,
        ),
      ),
    );
    if (edited == null || !mounted) return;
    final List<Place> before = List<Place>.of(_places ?? const <Place>[]);
    final int index = before.indexWhere((Place p) => p.id == place.id);
    if (index < 0) return;
    // Alerts belong to the geofence, not the picker: keep them as they were.
    final Place optimistic = edited.copyWith(
      alertsOn: place.alertsOn,
      geofenceId: place.geofenceId ?? Place.clearGeofence,
    );
    setState(() {
      _editing = true;
      _places = <Place>[...before]..[index] = optimistic;
    });
    try {
      final Place saved = await (widget.updater ??
          (Place p) => PlaceService.updatePlace(
                p.id,
                name: p.name,
                type: p.type,
                lat: p.position.latitude,
                lon: p.position.longitude,
                radiusMeters: p.radiusMeters,
                address: p.address,
                setCircle: true,
                circleId: p.circleId,
              ))(optimistic);
      if (!mounted) return;
      setState(() {
        final List<Place> now = List<Place>.of(_places ?? before);
        final int i = now.indexWhere((Place p) => p.id == place.id);
        if (i >= 0) {
          now[i] = saved.copyWith(
            icon: Place.iconForType(saved.type),
            alertsOn: place.alertsOn,
            geofenceId: place.geofenceId ?? Place.clearGeofence,
          );
        }
        _places = now;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Place updated')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _places = before); // roll back
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_changeError(e, 'edit'))),
      );
      if (_refreshNeeded(e)) _load();
    } finally {
      if (mounted) {
        setState(() => _editing = false);
      } else {
        _editing = false;
      }
    }
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
        circleId: picked.circleId,
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
      await (widget.deleter ?? PlaceService.deletePlace)(place.id);
      if (!mounted) return;
      setState(() {
        _places = _places!.where((Place p) => p.id != place.id).toList();
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_changeError(e, 'delete'))),
      );
      if (_refreshNeeded(e)) _load();
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
        for (final String c in _unshared)
          _ShareBanner(
            circleName: _circleLabel(c),
            busy: _sharing == c,
            onShare: _sharing == null ? () => _sharePlaces(c) : null,
          ),
        const DsSectionHeader('Saved places'),
        for (int i = 0; i < places.length; i++)
          _PlaceTile(
            place: places[i],
            notShared: places[i].circleId != null &&
                _unshared.contains(places[i].circleId),
            onToggleAlerts: _canManage ? () => _toggleAlerts(i) : null,
            toggling: _toggling,
            onDelete: _canManage ? () => _deletePlace(places[i]) : null,
            onEdit: _canManage ? () => _editPlace(places[i]) : null,
          ),
        if (_canManage) _AddPlaceTile(onTap: _addPlace),
      ],
    );
  }
}

/// Says plainly that the places of a Private circle are only on this phone
/// for now, and offers the one action that fixes it.
class _ShareBanner extends StatelessWidget {
  const _ShareBanner({
    required this.circleName,
    required this.busy,
    required this.onShare,
  });

  final String circleName;
  final bool busy;
  final VoidCallback? onShare;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          DsMessage(
            'Other members of $circleName may not see these places. The circle '
            'is end-to-end encrypted and its key changed after the places were '
            'shared (for example when a phone joined or was replaced), so phones '
            'that joined since cannot open them. Share them again to fix it.',
            tone: DsTone.info,
          ),
          const SizedBox(height: AppSpace.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: DsBusyButton(
              label: 'Share places with the circle',
              icon: Icons.group_outlined,
              busy: busy,
              onPressed: onShare,
            ),
          ),
          const SizedBox(height: AppSpace.sm),
        ],
      ),
    );
  }
}

class _PlaceTile extends StatelessWidget {
  const _PlaceTile({
    required this.place,
    required this.onToggleAlerts,
    required this.toggling,
    required this.onDelete,
    this.onEdit,
    this.notShared = false,
  });

  /// The place is on this phone only: the circle's members cannot read it yet.
  final bool notShared;

  final VoidCallback? onEdit;

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
    final String? sharedWith = place.circleId == null
        ? null
        : notShared
            ? 'Only on this phone: not shared with '
                '${place.circleName ?? 'the circle'} yet'
            : 'Shared with ${place.circleName ?? 'a circle'}';
    final String subtitle =
        '$where\nArrival and departure alerts: ${place.alertsOn ? 'on' : 'off'}'
        '${sharedWith == null ? '' : '\n$sharedWith'}';
    final bool large = MediaQuery.textScalerOf(context).scale(16) > 16 * 1.4;
    final String alertsLabel = place.alertsOn ? 'Alerts on' : 'Alerts off';
    final IconData alertsIcon = place.alertsOn
        ? Icons.notifications_active
        : Icons.notifications_off_outlined;
    final Color alertsColor =
        place.alertsOn ? brand.accentInk : cs.onSurfaceVariant;
    if (!large) {
      return DsListRow(
        leading: DsListRow.iconTile(context, place.icon),
        title: place.name,
        subtitle: subtitle,
        onTap: onEdit,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.end,
          children: <Widget>[
            if (onToggleAlerts != null)
              IconButton(
                tooltip: alertsLabel,
                constraints: const BoxConstraints(
                  minWidth: kMinTarget,
                  minHeight: kMinTarget,
                ),
                icon: Icon(alertsIcon, color: alertsColor),
                onPressed: toggling ? null : onToggleAlerts,
              ),
            if (onEdit != null)
              IconButton(
                tooltip: 'Edit place',
                constraints: const BoxConstraints(
                  minWidth: kMinTarget,
                  minHeight: kMinTarget,
                ),
                icon: Icon(Icons.edit_outlined, color: cs.onSurfaceVariant),
                onPressed: onEdit,
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
    // Large text: the actions get their own labelled row so the place name
    // and address keep the full width.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        DsListRow(
          leading: DsListRow.iconTile(context, place.icon),
          title: place.name,
          subtitle: subtitle,
          onTap: onEdit,
        ),
        if (onToggleAlerts != null || onDelete != null || onEdit != null)
          Padding(
            padding: const EdgeInsets.only(
              left: AppSpace.xl,
              right: AppSpace.xl,
              bottom: AppSpace.sm,
            ),
            child: Wrap(
              spacing: AppSpace.sm,
              children: <Widget>[
                if (onToggleAlerts != null)
                  Tooltip(
                    message: alertsLabel,
                    child: TextButton.icon(
                      style: TextButton.styleFrom(
                        minimumSize: const Size(kMinTarget, kMinTarget),
                        foregroundColor: alertsColor,
                      ),
                      onPressed: toggling ? null : onToggleAlerts,
                      icon: Icon(alertsIcon),
                      label: Text(alertsLabel),
                    ),
                  ),
                if (onEdit != null)
                  Tooltip(
                    message: 'Edit place',
                    child: TextButton.icon(
                      style: TextButton.styleFrom(
                        minimumSize: const Size(kMinTarget, kMinTarget),
                        foregroundColor: cs.onSurfaceVariant,
                      ),
                      onPressed: onEdit,
                      icon: const Icon(Icons.edit_outlined),
                      label: const Text('Edit'),
                    ),
                  ),
                if (onDelete != null)
                  Tooltip(
                    message: 'Delete place',
                    child: TextButton.icon(
                      style: TextButton.styleFrom(
                        minimumSize: const Size(kMinTarget, kMinTarget),
                        foregroundColor: cs.onSurfaceVariant,
                      ),
                      onPressed: onDelete,
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Delete'),
                    ),
                  ),
              ],
            ),
          ),
      ],
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
