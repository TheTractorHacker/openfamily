import 'package:flutter/material.dart';

import '../models/place.dart';
import '../services/api_client.dart';
import '../services/family_service.dart';
import '../services/geofence_service.dart';
import '../services/place_service.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';
import 'app_shell.dart';
import 'place_picker_screen.dart';

/// Onboarding step: add home/work/school places to the map (shared with all
/// family members), then land on the map.
///
/// Each place opens a real map picker that captures a lat/lon, address, and
/// radius — producing actual [Place] data, not a decorative toggle.
class AddLocationsScreen extends StatefulWidget {
  const AddLocationsScreen({super.key, this.circleName, this.step});

  final String? circleName;

  /// Onboarding step number (6 of 6). Null when reached outside onboarding.
  final int? step;

  @override
  State<AddLocationsScreen> createState() => _AddLocationsScreenState();
}

/// A preset place the user can add to the map.
class _PlacePreset {
  const _PlacePreset({
    required this.id,
    required this.icon,
    required this.name,
    required this.subtitle,
  });

  final String id;
  final IconData icon;
  final String name;
  final String subtitle;
}

/// Maps a preset id to the backend place type.
String _typeForPresetId(String id) {
  switch (id) {
    case 'home':
      return 'home';
    case 'work':
      return 'work';
    case 'school':
      return 'school';
    case 'gym':
      return 'gym';
    default:
      return 'custom';
  }
}

class _AddLocationsScreenState extends State<AddLocationsScreen> {
  static const List<_PlacePreset> _presets = [
    _PlacePreset(
      id: 'home',
      icon: Icons.home,
      name: 'Home',
      subtitle: 'Where you live',
    ),
    _PlacePreset(
      id: 'work',
      icon: Icons.business_center,
      name: 'Work',
      subtitle: 'Where you work',
    ),
    _PlacePreset(
      id: 'school',
      icon: Icons.school,
      name: 'School',
      subtitle: 'Where the kids go to school',
    ),
    _PlacePreset(
      id: 'gym',
      icon: Icons.fitness_center,
      name: 'Gym',
      subtitle: 'Where you work out',
    ),
  ];

  /// Preset id → the real [Place] the user captured.
  final Map<String, Place> _places = <String, Place>{};

  /// Custom (non-preset) places the user added, in insertion order.
  final List<Place> _customPlaces = <Place>[];

  /// Re-entry guard so a double-tap on "Continue" doesn't fire concurrent POSTs.
  bool _finishing = false;

  /// Local ids of places already created on the backend, so a retry skips them
  /// (the backend's overlap check would reject duplicate submissions).
  final Set<String> _createdPlaceIds = <String>{};

  Future<void> _addPlace(_PlacePreset preset) async {
    final Place? place = await Navigator.of(context).push<Place>(
      MaterialPageRoute<Place>(
        builder: (_) => PlacePickerScreen(
          placeName: preset.name,
          icon: preset.icon,
          type: _typeForPresetId(preset.id),
          initial: _places[preset.id],
        ),
      ),
    );
    if (place != null && mounted) {
      setState(() => _places[preset.id] = place);
    }
  }

  /// Toggles the arrive/leave notification (bell) for a captured place.
  void _toggleAlerts(_PlacePreset preset) {
    final Place? place = _places[preset.id];
    if (place == null) return;
    setState(() {
      _places[preset.id] = place.copyWith(alertsOn: !place.alertsOn);
    });
  }

  /// Adds a custom (non-preset) place: prompt for a name, then open the map
  /// picker with that name and a generic pin icon.
  Future<void> _addCustomPlace() async {
    final String? name = await _promptForPlaceName();
    if (name == null || name.trim().isEmpty || !mounted) return;
    final Place? place = await Navigator.of(context).push<Place>(
      MaterialPageRoute<Place>(
        builder: (_) => PlacePickerScreen(
          placeName: name.trim(),
          icon: Icons.place,
        ),
      ),
    );
    if (place != null && mounted) {
      setState(() => _customPlaces.add(place));
    }
  }

  /// Prompts for a custom place name; returns `null` when cancelled.
  ///
  /// Uses a captured local (no [TextEditingController]) so we don't dispose a
  /// controller while the dialog's exit transition is still running.
  Future<String?> _promptForPlaceName() async {
    String name = '';
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Name your place'),
        content: TextField(
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          onChanged: (String value) => name = value,
          decoration: const InputDecoration(
            labelText: 'Place name',
            hintText: 'e.g. Grandma\'s house',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(name),
            child: const Text('Next'),
          ),
        ],
      ),
    );
  }

  /// Toggles the arrive/leave notification (bell) for a custom place.
  void _toggleCustomAlerts(int index) {
    final Place place = _customPlaces[index];
    setState(() {
      _customPlaces[index] = place.copyWith(alertsOn: !place.alertsOn);
    });
  }

  /// Re-opens the picker to edit a custom place.
  Future<void> _editCustomPlace(int index) async {
    final Place? updated = await Navigator.of(context).push<Place>(
      MaterialPageRoute<Place>(
        builder: (_) => PlacePickerScreen(
          placeName: _customPlaces[index].name,
          icon: _customPlaces[index].icon,
          initial: _customPlaces[index],
        ),
      ),
    );
    if (updated != null && mounted) {
      setState(() => _customPlaces[index] = updated);
    }
  }

  Future<void> _finish() async {
    if (_finishing) return;
    setState(() => _finishing = true);
    final List<Place> all = <Place>[
      ..._places.values,
      ..._customPlaces,
    ];
    var failed = false;
    String? callerUserId;
    var familyFetched = false;
    for (final Place place in all) {
      if (_createdPlaceIds.contains(place.id)) continue;
      try {
        final Place created = await PlaceService.createPlace(
          name: place.name,
          type: place.type,
          lat: place.position.latitude,
          lon: place.position.longitude,
          radiusMeters: place.radiusMeters,
          address: place.address,
        );
        _createdPlaceIds.add(place.id);
        if (place.alertsOn) {
          if (!familyFetched) {
            try {
              callerUserId = (await FamilyService().fetchFamily()).userId;
            } catch (_) {
              callerUserId = null;
            }
            familyFetched = true;
          }
          if (callerUserId != null && callerUserId.isNotEmpty) {
            try {
              await GeofenceService.createGeofence(
                placeId: created.id,
                userId: callerUserId,
                enterNotify: true,
                exitNotify: true,
              );
            } catch (e) {
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    'Saved "${place.name}" but couldn\'t enable alerts. '
                    '${_errorMessage(e)}',
                  ),
                ),
              );
            }
          } else if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Saved "${place.name}" but couldn\'t enable alerts. '
                  'You can toggle them later in Places.',
                ),
              ),
            );
          }
        }
      } catch (e) {
        failed = true;
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Couldn\'t save "${place.name}". ${_errorMessage(e)}'),
          ),
        );
      }
    }
    if (!mounted) return;
    if (failed) {
      setState(() => _finishing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Some places couldn\'t be saved. Check your connection and try again.',
          ),
        ),
      );
      return;
    }
    // Onboarding is complete; MapScreen starts background location reporting
    // once it is shown (and the app is in the foreground).
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const AppShell()),
      (route) => false,
    );
  }

  String _errorMessage(Object e) {
    if (e is ApiException) return e.message;
    return 'Please try again.';
  }

  @override
  Widget build(BuildContext context) {
    return DsPage(
      title: 'Add locations',
      showBack: false,
      step: widget.step,
      totalSteps: widget.step == null ? null : 6,
      actions: [
        DsBusyButton(label: 'Continue', busy: _finishing, onPressed: _finish),
        DsPillButton(
          label: 'Skip for now',
          style: DsPillStyle.outlined,
          onPressed: _finishing ? null : _finish,
        ),
      ],
      children: [
        const DsHeading(
          'Add places to your map',
          subtitle: 'Places are shared with all family members, so everyone '
              'gets arrival and departure alerts.',
        ),
        DsRowGroup(
          children: [
            for (final _PlacePreset preset in _presets)
              _PlaceRow(
                icon: preset.icon,
                name: preset.name,
                emptyHint: preset.subtitle,
                place: _places[preset.id],
                onOpen: () => _addPlace(preset),
                onToggleAlerts: () => _toggleAlerts(preset),
              ),
            for (int i = 0; i < _customPlaces.length; i++)
              _PlaceRow(
                icon: _customPlaces[i].icon,
                name: _customPlaces[i].name,
                emptyHint: '',
                place: _customPlaces[i],
                onOpen: () => _editCustomPlace(i),
                onToggleAlerts: () => _toggleCustomAlerts(i),
              ),
            DsListRow(
              leading: DsListRow.iconTile(
                context,
                Icons.add_location_alt_outlined,
              ),
              title: 'Add a custom place',
              subtitle: 'Any other place, e.g. Grandma\'s house',
              chevron: true,
              onTap: _addCustomPlace,
            ),
          ],
        ),
      ],
    );
  }
}

/// One place row. Before it is added it offers an "Add" button; once added it
/// shows "Added" with the captured address and radius, and a bell toggle for
/// arrive/leave alerts (state also spelled out in words). Tapping the row
/// opens the picker to add or edit.
class _PlaceRow extends StatelessWidget {
  const _PlaceRow({
    required this.icon,
    required this.name,
    required this.emptyHint,
    required this.place,
    required this.onOpen,
    required this.onToggleAlerts,
  });

  final IconData icon;
  final String name;
  final String emptyHint;
  final Place? place;
  final VoidCallback onOpen;
  final VoidCallback onToggleAlerts;

  @override
  Widget build(BuildContext context) {
    final Place? p = place;
    return DsListRow(
      leading: DsListRow.iconTile(
        context,
        p == null ? icon : Icons.check_circle,
        color: p == null ? null : AppColors.statusGreen,
      ),
      title: name,
      subtitle: p == null
          ? emptyHint
          : 'Added · ${p.address} · ${p.radiusLabel}\n'
              'Arrive and leave alerts ${p.alertsOn ? 'on' : 'off'}',
      onTap: onOpen,
      trailing: p == null
          ? DsPillButton(
              label: 'Add',
              style: DsPillStyle.outlined,
              onPressed: onOpen,
              semanticLabel: 'Add $name',
            )
          : IconButton(
              tooltip: p.alertsOn
                  ? 'Turn off alerts for $name'
                  : 'Turn on alerts for $name',
              constraints: const BoxConstraints(
                minWidth: kMinTarget,
                minHeight: kMinTarget,
              ),
              icon: Icon(
                p.alertsOn
                    ? Icons.notifications_active
                    : Icons.notifications_off_outlined,
                color: p.alertsOn
                    ? BrandTheme.of(context).accentInk
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              onPressed: onToggleAlerts,
            ),
    );
  }
}
