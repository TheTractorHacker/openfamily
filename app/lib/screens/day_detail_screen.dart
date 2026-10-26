import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../widgets/openfamily_map_layers.dart';
import '../models/member.dart';
import '../models/place.dart';
import '../services/api_client.dart';
import '../services/family_service.dart';
import '../services/history_service.dart';
import '../services/place_service.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';
import '../widgets/member_avatar_bubble.dart';
import '../widgets/movement_icon.dart';
import '../widgets/trips_entry_button.dart';

/// Location-history timeline for a member: a map trail plus named family
/// places and unnamed stops for a chosen day.
class DayDetailScreen extends StatefulWidget {
  const DayDetailScreen({super.key, required this.member});

  final Member member;

  @override
  State<DayDetailScreen> createState() => _DayDetailScreenState();
}

class _DayDetailScreenState extends State<DayDetailScreen> {
  final MapController _mapController = MapController();
  final FamilyService _familyService = FamilyService();

  late DateTime _day;
  MemberHistory? _history;
  String? _error;
  bool _loading = true;
  bool _canManage = false;
  bool _mapReady = false;

  static final DateTime _today = DateTime(
    DateTime.now().year,
    DateTime.now().month,
    DateTime.now().day,
  );
  static final DateTime _oldest = _today.subtract(const Duration(days: 89));

  @override
  void initState() {
    super.initState();
    _day = _today;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final List<dynamic> results = await Future.wait<dynamic>(<Future<dynamic>>[
        HistoryService.fetchDay(memberId: widget.member.id, day: _day),
        _familyService.fetchFamily(),
      ]);
      if (!mounted) return;
      final MemberHistory history = results[0] as MemberHistory;
      final FamilyInfo family = results[1] as FamilyInfo;
      setState(() {
        _history = history;
        _canManage = family.role != 'child';
        _loading = false;
      });
      _fitTrail();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is ApiException
            ? e.message
            : 'Couldn\'t load history. Please try again.';
        _loading = false;
      });
    }
  }

  void _shiftDay(int days) {
    final DateTime next = _day.add(Duration(days: days));
    final DateTime clamped = DateTime(next.year, next.month, next.day);
    if (clamped.isAfter(_today) || clamped.isBefore(_oldest)) return;
    setState(() => _day = clamped);
    _load();
  }

  void _fitTrail() {
    if (!_mapReady) return;
    final List<LatLng> coords = _trailCoordinates();
    if (coords.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        _mapController.fitCamera(
          CameraFit.coordinates(
            coordinates: coords,
            padding: const EdgeInsets.all(28),
            maxZoom: 16,
          ),
        );
      } catch (_) {
        // Map may not be attached yet on the first frame.
      }
    });
  }

  List<LatLng> _trailCoordinates() {
    final MemberHistory? history = _history;
    if (history == null) return <LatLng>[];
    if (history.trail.isNotEmpty) {
      return history.trail.map((HistoryTrailPoint p) => p.position).toList();
    }
    return history.visits.map((HistoryVisit v) => v.position).toList();
  }

  Future<void> _saveStop(HistoryVisit visit) async {
    final _SavePlaceResult? result = await showDialog<_SavePlaceResult>(
      context: context,
      builder: (BuildContext context) => _SavePlaceDialog(visit: visit),
    );
    if (result == null || !mounted) return;
    try {
      await PlaceService.createPlace(
        name: result.name,
        type: result.type,
        lat: visit.position.latitude,
        lon: visit.position.longitude,
        radiusMeters: 152.4,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${result.name} saved for the family')),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e is ApiException ? e.message : 'Couldn\'t save this place.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Day Detail'),
        actions: <Widget>[TripsAppBarAction(member: widget.member)],
      ),
      body: Column(
        children: [
          _Header(
            member: widget.member,
            day: _day,
            canGoBack: _day.isAfter(_oldest),
            canGoForward: _day.isBefore(_today),
            onBack: () => _shiftDay(-1),
            onForward: () => _shiftDay(1),
          ),
          const Divider(height: 1),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return Semantics(
        label: 'Loading history',
        child: const Padding(
          padding: EdgeInsets.all(AppSpace.xl),
          child: DsSkeletonList(rows: 4),
        ),
      );
    }
    if (_error != null) {
      return DsErrorState(
        icon: Icons.cloud_off,
        title: 'Could not load history',
        message: _error!,
        onRetry: _load,
      );
    }
    final MemberHistory history = _history!;
    if (history.isEmpty) {
      return const DsEmptyState(
        icon: Icons.timeline,
        title: 'No location history',
        message: 'No location history for this day.',
      );
    }
    // One scrolling list so large text never squeezes the map or timeline.
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: AppSpace.xxl),
      itemCount: history.visits.length + 1,
      itemBuilder: (BuildContext context, int index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.lg),
            child: _TrailMap(
              member: widget.member,
              history: history,
              mapController: _mapController,
              onMapReady: () {
                _mapReady = true;
                _fitTrail();
              },
            ),
          );
        }
        final HistoryVisit visit = history.visits[index - 1];
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpace.xl),
          child: _TimelineEntry(
            visit: visit,
            isLast: index == history.visits.length,
            canSave: _canManage && visit.isStop,
            onSave: () => _saveStop(visit),
          ),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.member,
    required this.day,
    required this.canGoBack,
    required this.canGoForward,
    required this.onBack,
    required this.onForward,
  });

  final Member member;
  final DateTime day;
  final bool canGoBack;
  final bool canGoForward;
  final VoidCallback onBack;
  final VoidCallback onForward;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool large = MediaQuery.textScalerOf(context).scale(16) > 16 * 1.4;
    final Widget nav = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        IconButton(
          tooltip: 'Previous day',
          constraints: const BoxConstraints(
            minWidth: kMinTarget,
            minHeight: kMinTarget,
          ),
          onPressed: canGoBack ? onBack : null,
          icon: const Icon(Icons.chevron_left),
        ),
        IconButton(
          tooltip: 'Next day',
          constraints: const BoxConstraints(
            minWidth: kMinTarget,
            minHeight: kMinTarget,
          ),
          onPressed: canGoForward ? onForward : null,
          icon: const Icon(Icons.chevron_right),
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.all(AppSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              StatusAvatar(member: member, size: 48),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Semantics(
                      header: true,
                      child: Text(member.name, style: AppType.headline),
                    ),
                    const SizedBox(height: AppSpace.xxs),
                    Text(
                      _formatDate(day),
                      style: AppType.secondary.copyWith(
                        fontSize: 14,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (!large) nav,
            ],
          ),
          if (large) Align(alignment: Alignment.centerRight, child: nav),
        ],
      ),
    );
  }
}

class _TrailMap extends StatelessWidget {
  const _TrailMap({
    required this.member,
    required this.history,
    required this.mapController,
    required this.onMapReady,
  });

  final Member member;
  final MemberHistory history;
  final MapController mapController;
  final VoidCallback onMapReady;

  @override
  Widget build(BuildContext context) {
    final List<LatLng> trail =
        history.trail.map((HistoryTrailPoint p) => p.position).toList();
    final LatLng center = trail.isNotEmpty
        ? trail[trail.length ~/ 2]
        : (member.position ?? const LatLng(0, 0));

    return SizedBox(
      height: 220,
      width: double.infinity,
      child: Semantics(
        label: 'Map of ${member.name}\'s location trail for this day',
        child: FlutterMap(
        mapController: mapController,
        options: MapOptions(
          initialCenter: center,
          initialZoom: 13,
          onMapReady: onMapReady,
          interactionOptions: const InteractionOptions(
            flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
          ),
        ),
        children: [
          const OpenFamilyTileLayer(),
          if (trail.length >= 2)
            PolylineLayer(
              polylines: <Polyline>[
                Polyline(
                  points: trail,
                  color: AppColors.historyTrail,
                  strokeWidth: 3.5,
                  // White casing under the stroke keeps the trail readable on
                  // busy urban tiles (roads/place labels) regardless of the
                  // fill color — same trick Strava/Google trails use.
                  borderColor: Colors.white,
                  borderStrokeWidth: 3,
                ),
              ],
            ),
          MarkerLayer(
            markers: <Marker>[
              for (final HistoryVisit visit in history.visits)
                if (!visit.isTransit)
                  Marker(
                    point: visit.position,
                    width: 28,
                    height: 28,
                    alignment: Alignment.center,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white,
                        border: Border.all(
                          color: AppColors.historyTrail,
                          width: 2,
                        ),
                      ),
                      child: Icon(
                        _visitIcon(visit),
                        size: 14,
                        color: AppColors.historyTrail,
                      ),
                    ),
                  ),
            ],
          ),
        ],
      ),
      ),
    );
  }
}

class _TimelineEntry extends StatelessWidget {
  const _TimelineEntry({
    required this.visit,
    required this.isLast,
    required this.canSave,
    required this.onSave,
  });

  final HistoryVisit visit;
  final bool isLast;
  final bool canSave;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final MovementType movement = _movementFor(visit);
    final BrandTheme brand = BrandTheme.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Color dotColor = visit.isTransit ? cs.onSurfaceVariant : brand.accentInk;
    final Duration stay = visit.departedAt.difference(visit.arrivedAt);

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                _formatTime(visit.arrivedAt.toLocal()),
                textAlign: TextAlign.right,
                style: AppType.secondary.copyWith(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 20,
            child: Column(
              children: [
                Container(
                  width: 12,
                  height: 12,
                  margin: const EdgeInsets.only(top: 4),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: dotColor,
                    border: Border.all(color: brand.sheet, width: 2),
                  ),
                ),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 2,
                      color: cs.outlineVariant,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : AppSpace.xl),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          visit.placeName,
                          style: AppType.body,
                        ),
                        if (stay.inMinutes >= 1)
                          Text(
                            _formatDuration(stay),
                            style: AppType.secondary.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (movement != MovementType.none) ...[
                    const SizedBox(width: 8),
                    MovementIcon(movement: movement, size: 18),
                  ] else ...[
                    const SizedBox(width: 8),
                    Icon(
                      _visitIcon(visit),
                      size: 18,
                      color: brand.accentInk,
                    ),
                  ],
                  if (canSave)
                    IconButton(
                      tooltip: 'Save as place',
                      constraints: const BoxConstraints(
                        minWidth: kMinTarget,
                        minHeight: kMinTarget,
                      ),
                      icon: const Icon(Icons.add_location_alt_outlined),
                      color: brand.accentInk,
                      onPressed: onSave,
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SavePlaceResult {
  const _SavePlaceResult({required this.name, required this.type});
  final String name;
  final String type;
}

class _SavePlaceDialog extends StatefulWidget {
  const _SavePlaceDialog({required this.visit});

  final HistoryVisit visit;

  @override
  State<_SavePlaceDialog> createState() => _SavePlaceDialogState();
}

class _SavePlaceDialogState extends State<_SavePlaceDialog> {
  late final TextEditingController _name;
  String _type = 'custom';

  static const List<String> _types = <String>[
    'home',
    'work',
    'school',
    'gym',
    'custom',
  ];

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.visit.placeName == 'Stopped'
        ? ''
        : widget.visit.placeName);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Save as family place'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Name',
              hintText: 'Coffee shop',
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _type,
            decoration: const InputDecoration(labelText: 'Type'),
            items: _types
                .map(
                  (String t) => DropdownMenuItem<String>(
                    value: t,
                    child: Text(
                      '${t[0].toUpperCase()}${t.substring(1)}',
                    ),
                  ),
                )
                .toList(),
            onChanged: (String? v) {
              if (v != null) _type = v;
            },
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final String name = _name.text.trim();
            if (name.isEmpty) return;
            Navigator.of(context).pop(
              _SavePlaceResult(name: name, type: _type),
            );
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

IconData _visitIcon(HistoryVisit visit) {
  if (visit.isStop) return Icons.place;
  if (visit.isPlace) return Place.iconForType(visit.placeType);
  return Icons.route;
}

MovementType _movementFor(HistoryVisit visit) {
  if (visit.isPlace) {
    switch (visit.placeType) {
      case 'home':
        return MovementType.home;
      case 'work':
        return MovementType.work;
      case 'gym':
        return MovementType.gym;
    }
  }
  if (visit.isTransit) {
    switch (visit.placeType) {
      case 'driving':
        return MovementType.car;
      case 'cycling':
        return MovementType.bike;
    }
  }
  return MovementType.none;
}

String _formatTime(DateTime t) {
  final int hour12 = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final String minute = t.minute.toString().padLeft(2, '0');
  final String ampm = t.hour < 12 ? 'AM' : 'PM';
  return '$hour12:$minute $ampm';
}

String _formatDate(DateTime d) {
  const List<String> months = <String>[
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${months[d.month - 1]} ${d.day}, ${d.year}';
}

String _formatDuration(Duration d) {
  if (d.inHours >= 1) {
    final int hours = d.inHours;
    final int mins = d.inMinutes.remainder(60);
    if (mins == 0) return hours == 1 ? '1 hr' : '$hours hrs';
    return '${hours}h ${mins}m';
  }
  return '${d.inMinutes} min';
}
