import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/member.dart';
import '../models/trip.dart';
import '../models/trip_report.dart';
import '../services/api_client.dart';
import '../services/delivery_status.dart';
import '../services/location_refresh_service.dart';
import '../services/member_day_service.dart';
import '../services/speed_units.dart';
import '../services/trips_service.dart';
import '../theme/app_theme.dart';
import '../utils/member_status.dart';
import '../widgets/driving_event_chips.dart';
import '../widgets/ds/ds.dart';
import '../widgets/member_avatar_bubble.dart';
import '../widgets/openfamily_map_layers.dart';
import '../widgets/trip_widgets.dart';
import 'daily_history_screen.dart';
import 'member_profile_screen.dart';
import 'trip_detail_screen.dart';
import 'trips_screen.dart';

/// "5 min ago", "2h ago", "3d ago".
String agoLabel(DateTime t, DateTime now) {
  final Duration d = now.difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  return '${d.inDays}d ago';
}

/// Life360-style status line: "Driving · 42 mph", "At Home since 3:10 PM",
/// "Last seen 2h ago".
String memberDetailStatus(
  Member m, {
  DateTime? now,
  double? speedMps,
  UnitSystem units = UnitSystem.imperial,
}) {
  final DateTime n = now ?? DateTime.now();
  if (m.position == null) return DeliveryHints.hintFor(m.id, now: n) ?? 'No location yet';
  if (m.status == MemberStatus.stopped) {
    final String? why = DeliveryHints.hintFor(m.id, now: n);
    final DateTime? seen = m.lastSeen;
    if (why != null) return seen == null ? why : '$why · last seen ${agoLabel(seen.toLocal(), n)}';
    return seen == null ? 'Updates stopped' : 'Last seen ${agoLabel(seen.toLocal(), n)}';
  }
  if (m.movement == MovementType.car) {
    final double? v = speedMps ?? m.speedMps;
    return v == null ? 'Driving' : 'Driving · ${units.formatSpeed(v)}';
  }
  final PlacePresence? p = m.placePresence;
  if (p != null && p.isAt) return placePresenceLabel(p, now: n);
  if (p != null) return placePresenceLabel(p, now: n);
  if (m.address.isNotEmpty) return m.address;
  return m.movement == MovementType.none ? 'Not moving' : m.movement.label;
}

/// Member detail: header, battery, quick actions and today's trip timeline.
class MemberDetailScreen extends StatefulWidget {
  const MemberDetailScreen({
    super.key,
    required this.member,
    this.loader,
    this.api,
    this.requestUpdate,
    this.tileProvider,
    this.now,
  });

  final Member member;

  /// Overrides the default network loader (tests).
  final MemberDayLoader? loader;
  final TripsApi? api;
  final Future<void> Function(String memberId)? requestUpdate;
  final TileProvider? tileProvider;

  /// Clock override (tests).
  final DateTime? now;

  @override
  State<MemberDetailScreen> createState() => _MemberDetailScreenState();
}

class _MemberDetailScreenState extends State<MemberDetailScreen> {
  MemberDay? _day;
  Object? _error;
  bool _loading = true;
  bool _requesting = false;

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
    final DateTime now = widget.now ?? DateTime.now();
    try {
      final MemberDay d = widget.loader != null
          ? await widget.loader!(widget.member, now)
          : await loadMemberDay(widget.member, now, api: widget.api);
      if (!mounted) return;
      setState(() {
        _day = d;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _requestUpdate() async {
    if (_requesting) return;
    setState(() => _requesting = true);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    String msg = 'Request sent. The map will update when the phone responds.';
    try {
      if (widget.requestUpdate != null) {
        await widget.requestUpdate!(widget.member.id);
      } else {
        final Map<String, dynamic> r =
            await LocationRefreshService.request(widget.member.id);
        msg = switch (r['status']) {
          'cooldown' => 'A recent location request is still cooling down.',
          'coalesced' => 'A location request is already in progress.',
          _ => msg,
        };
      }
    } on ApiException catch (e) {
      msg = e.message;
    } catch (_) {
      msg = 'Could not request a location right now.';
    }
    if (!mounted) return;
    setState(() => _requesting = false);
    messenger.showSnackBar(SnackBar(content: Text(msg)));
  }

  void _push(Widget screen) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));

  @override
  Widget build(BuildContext context) {
    final Member m = widget.member;
    return Scaffold(
      appBar: AppBar(title: Text(m.name)),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(
                    AppSpace.xxl, AppSpace.lg, AppSpace.xxl, AppSpace.xxl),
                children: <Widget>[
                  _Header(member: m, now: widget.now),
                  const SizedBox(height: AppSpace.xl),
                  _QuickActions(
                    member: m,
                    requesting: _requesting,
                    onUpdate: _requestUpdate,
                    onHistory: () => openDailyHistory(context, m),
                    onTrips: () => _push(TripsScreen(member: m, api: widget.api)),
                    onProfile: () => _push(MemberProfileScreen(member: m)),
                  ),
                  DsSectionHeader(
                    'Today',
                    padding: const EdgeInsets.only(
                        top: AppSpace.xxl, bottom: AppSpace.sm),
                    trailing: TextButton(
                      onPressed: () => openDailyHistory(context, m),
                      child: const Text('Daily history'),
                    ),
                  ),
                  _Timeline(
                    loading: _loading,
                    error: _error,
                    day: _day,
                    onRetry: _load,
                    tileProvider: widget.tileProvider,
                    onOpenTrip: (Trip t) => _push(TripDetailScreen(
                      trip: t,
                      api: widget.api,
                      tileProvider: widget.tileProvider,
                    )),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.member, this.now});

  final Member member;
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final int b = member.batteryPercent;
    final bool charging = member.showsCharging;
    final Color bc = b <= 0
        ? AppColors.statusGrey
        : charging
            ? AppColors.statusGreen
            : b <= 20
            ? AppColors.statusRed
            : b <= 50
                ? AppColors.statusOrange
                : AppColors.statusGreen;
    return ValueListenableBuilder<UnitSystem>(
      valueListenable: UnitPreferenceService.units,
      builder: (BuildContext context, UnitSystem units, _) {
        final String status =
            memberDetailStatus(member, now: now, units: units);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            StatusAvatar(member: member, size: 64),
            const SizedBox(width: AppSpace.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Semantics(
                    header: true,
                    child: Text(member.name, style: AppType.title),
                  ),
                  const SizedBox(height: AppSpace.xs),
                  Text(
                    status,
                    key: const Key('member_status_line'),
                    style: AppType.body.copyWith(color: cs.onSurface),
                  ),
                  if (member.address.isNotEmpty &&
                      member.address != status) ...<Widget>[
                    const SizedBox(height: AppSpace.xxs),
                    Text(
                      member.address,
                      style: AppType.secondary
                          .copyWith(color: cs.onSurfaceVariant),
                    ),
                  ],
                  const SizedBox(height: AppSpace.sm),
                  DsStatusChip(
                    key: const Key('member_detail_battery'),
                    label: b <= 0
                        ? 'Battery unknown'
                        : charging
                            ? 'Battery $b% · Charging'
                            : 'Battery $b%',
                    icon: b <= 0
                        ? Icons.battery_unknown
                        : charging
                            ? Icons.battery_charging_full
                            : b <= 20
                            ? Icons.battery_1_bar
                            : b <= 50
                                ? Icons.battery_3_bar
                                : Icons.battery_full,
                    color: bc,
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _QuickActions extends StatelessWidget {
  const _QuickActions({
    required this.member,
    required this.requesting,
    required this.onUpdate,
    required this.onHistory,
    required this.onTrips,
    required this.onProfile,
  });

  final Member member;
  final bool requesting;
  final VoidCallback onUpdate;
  final VoidCallback onHistory;
  final VoidCallback onTrips;
  final VoidCallback onProfile;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppSpace.sm,
      runSpacing: AppSpace.sm,
      children: <Widget>[
        DsPillButton(
          label: requesting ? 'Requesting…' : 'Check in',
          icon: Icons.my_location,
          onPressed: requesting ? null : onUpdate,
          semanticLabel: 'Request a fresh location from ${member.name}',
        ),
        DsPillButton(
          label: 'History',
          icon: Icons.history,
          style: DsPillStyle.tonal,
          onPressed: onHistory,
        ),
        DsPillButton(
          label: 'Trips',
          icon: Icons.route_rounded,
          style: DsPillStyle.tonal,
          onPressed: onTrips,
        ),
        DsPillButton(
          label: 'Profile',
          icon: Icons.person_outline,
          style: DsPillStyle.tonal,
          onPressed: onProfile,
        ),
      ],
    );
  }
}

class _Timeline extends StatelessWidget {
  const _Timeline({
    required this.loading,
    required this.error,
    required this.day,
    required this.onRetry,
    required this.onOpenTrip,
    this.tileProvider,
  });

  final bool loading;
  final Object? error;
  final MemberDay? day;
  final VoidCallback onRetry;
  final ValueChanged<Trip> onOpenTrip;
  final TileProvider? tileProvider;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Padding(
        padding: EdgeInsets.all(AppSpace.xxl),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (error != null) {
      final String message = error is TripsException
          ? (error as TripsException).message
          : error is ApiException
              ? (error as ApiException).message
              : 'Could not load today\'s trips.';
      return SizedBox(
        height: 260,
        child: DsErrorState(
          title: 'Couldn\'t load today',
          message: message,
          onRetry: onRetry,
        ),
      );
    }
    final List<DayTrip> trips = day?.trips ?? const <DayTrip>[];
    if (trips.isEmpty) {
      return const SizedBox(
        height: 220,
        child: DsEmptyState(
          icon: Icons.route_rounded,
          title: 'No trips today',
          message: 'Drives and walks will show up here as they happen.',
        ),
      );
    }
    return ValueListenableBuilder<UnitSystem>(
      valueListenable: UnitPreferenceService.units,
      builder: (BuildContext context, UnitSystem units, _) => Column(
        children: <Widget>[
          for (final DayTrip d in trips)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.md),
              child: DayTripCard(
                dayTrip: d,
                units: units,
                tileProvider: tileProvider,
                onTap: () => onOpenTrip(d.trip),
              ),
            ),
        ],
      ),
    );
  }
}

/// A Life360-style trip card: route thumbnail, from -> to, stats, event chips.
class DayTripCard extends StatelessWidget {
  const DayTripCard({
    super.key,
    required this.dayTrip,
    required this.units,
    required this.onTap,
    this.tileProvider,
  });

  final DayTrip dayTrip;
  final UnitSystem units;
  final VoidCallback onTap;
  final TileProvider? tileProvider;

  @override
  Widget build(BuildContext context) {
    final BrandTheme brand = BrandTheme.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Trip t = dayTrip.trip;
    final String from = dayTrip.fromName ?? 'Start';
    final String to = dayTrip.toName ?? 'End';
    return Semantics(
      button: true,
      label: '${tripSemanticLabel(context, t, units)}, from $from to $to',
      excludeSemantics: true,
      child: Material(
        color: brand.sheet,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _RouteThumb(dayTrip: dayTrip, tileProvider: tileProvider),
              Padding(
                padding: const EdgeInsets.all(AppSpace.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        TripModeBadge(mode: t.mode),
                        const Spacer(),
                        Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
                      ],
                    ),
                    const SizedBox(height: AppSpace.md),
                    _Endpoint(
                      icon: Icons.trip_origin,
                      name: from,
                      time: tripClock(context, t.startedAt),
                    ),
                    const SizedBox(height: AppSpace.sm),
                    _Endpoint(
                      icon: Icons.place,
                      name: to,
                      time: tripClock(context, t.endedAt),
                    ),
                    const SizedBox(height: AppSpace.md),
                    Wrap(
                      spacing: AppSpace.xxl,
                      runSpacing: AppSpace.md,
                      children: <Widget>[
                        TripStat(
                            label: 'Distance',
                            value: units.formatDistance(t.distanceM)),
                        TripStat(
                            label: 'Duration',
                            value: formatTripDuration(t.duration)),
                        TripStat(
                            label: 'Top speed',
                            value: units.formatSpeed(t.maxSpeedMps)),
                      ],
                    ),
                    _EventChipRow(dayTrip: dayTrip),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Endpoint extends StatelessWidget {
  const _Endpoint({required this.icon, required this.name, required this.time});

  final IconData icon;
  final String name;
  final String time;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(icon, size: 18, color: cs.onSurfaceVariant),
        const SizedBox(width: AppSpace.sm),
        Expanded(child: Text(name, style: AppType.body)),
        const SizedBox(width: AppSpace.sm),
        Text(time,
            style: AppType.secondary.copyWith(color: cs.onSurfaceVariant)),
      ],
    );
  }
}

class _EventChipRow extends StatelessWidget {
  const _EventChipRow({required this.dayTrip});

  final DayTrip dayTrip;

  @override
  Widget build(BuildContext context) {
    if (dayTrip.trip.mode != TripMode.driving || !dayTrip.detailLoaded) {
      return const SizedBox.shrink();
    }
    final List<Widget> chips = <Widget>[
      for (final DrivingEventKind k in DrivingEventKind.values)
        if (dayTrip.countOf(k) > 0)
          DsStatusChip(
            label: dayTrip.countOf(k) == 1
                ? k.label
                : '${k.label} ×${dayTrip.countOf(k)}',
            icon: eventIcon(k),
            color: eventColor(k),
          ),
    ];
    return Padding(
      padding: const EdgeInsets.only(top: AppSpace.md),
      child: Wrap(
        spacing: AppSpace.sm,
        runSpacing: AppSpace.sm,
        children: chips.isEmpty
            ? const <Widget>[
                DsStatusChip(
                  label: 'No risky events',
                  icon: Icons.check_circle_outline,
                  color: AppColors.statusGreen,
                ),
              ]
            : chips,
      ),
    );
  }
}

/// Non-interactive route thumbnail using the app's normal tile layer.
class _RouteThumb extends StatelessWidget {
  const _RouteThumb({required this.dayTrip, this.tileProvider});

  final DayTrip dayTrip;
  final TileProvider? tileProvider;

  @override
  Widget build(BuildContext context) {
    final Trip t = dayTrip.trip;
    final List<LatLng> pts = dayTrip.route.length >= 2
        ? dayTrip.route.map((TripRoutePoint p) => p.position).toList()
        : <LatLng>[t.start, t.end];
    final Color line = BrandTheme.of(context).accentInk;
    final bool single = pts.every((LatLng p) => p == pts.first);
    return ExcludeSemantics(
      child: SizedBox(
        height: 120,
        child: IgnorePointer(
          child: FlutterMap(
            options: MapOptions(
              initialCenter: pts.first,
              initialZoom: 15,
              initialCameraFit: single
                  ? null
                  : CameraFit.bounds(
                      bounds: LatLngBounds.fromPoints(pts),
                      padding: const EdgeInsets.all(24),
                      maxZoom: 16,
                    ),
              interactionOptions:
                  const InteractionOptions(flags: InteractiveFlag.none),
            ),
            children: <Widget>[
              OpenFamilyTileLayer(tileProvider: tileProvider),
              PolylineLayer(
                polylines: <Polyline>[
                  Polyline(points: pts, strokeWidth: 4, color: line),
                ],
              ),
              MarkerLayer(
                markers: <Marker>[
                  Marker(
                    point: pts.first,
                    width: 14,
                    height: 14,
                    child: const _Dot(color: AppColors.statusGreen),
                  ),
                  Marker(
                    point: pts.last,
                    width: 14,
                    height: 14,
                    child: const _Dot(color: AppColors.statusRed),
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

class _Dot extends StatelessWidget {
  const _Dot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
        ),
      );
}
