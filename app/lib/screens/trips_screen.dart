import 'package:flutter/material.dart';

import 'package:latlong2/latlong.dart';

import '../models/member.dart';
import '../models/trip.dart';
import '../services/speed_units.dart';
import '../services/trips_service.dart';
import '../theme/app_theme.dart';
import '../services/e2ee/private_runtime.dart';
import '../services/processing/primary_lanes.dart';
import '../services/processing/processing_source.dart';
import '../services/processing/result_items.dart';
import '../widgets/private_circle_widgets.dart';
import '../widgets/processing_widgets.dart';
import '../widgets/ds/ds.dart';
import '../widgets/trip_widgets.dart';
import 'driving_report_screen.dart';
import 'trip_detail_screen.dart';

/// A member's trips, grouped by day, newest first.
class TripsScreen extends StatefulWidget {
  const TripsScreen({super.key, required this.member, this.api, this.lanes});

  final Member member;

  /// Injected in tests; defaults to the running app's processing lanes.
  final PrimaryLanesLoader? lanes;

  /// Injected in tests; defaults to the real service.
  final TripsApi? api;

  @override
  State<TripsScreen> createState() => _TripsScreenState();
}

class _TripsScreenState extends State<TripsScreen> {
  late final TripsApi _api = widget.api ?? TripsService.instance;

  int _days = 7;
  List<Trip>? _trips;
  TripsException? _error;
  bool _loading = true;
  bool _isSelf = false;
  bool _recomputing = false;

  // Private circle with processing lanes: where this member's trips come from.
  MemberProcessing? _proc;
  String _procName = '';
  bool _lanesLoading = false;

  Future<void> _loadLanes() async {
    setState(() => _lanesLoading = true);
    PrimaryLanes? l;
    try {
      l = await (widget.lanes ?? loadPrimaryLanes)();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _proc = l?.memberById(widget.member.id);
      _procName = l?.nameOf(widget.member.id) ?? widget.member.name;
      _lanesLoading = false;
    });
    if (_proc?.origin == ProcessingOrigin.server) await _load();
  }

  @override
  void initState() {
    super.initState();
    UnitPreferenceService.ensureLoaded();
    if (PrivateRuntime.primaryPrivate.value) {
      _loadLanes();
    } else {
      _load();
    }
    _api.currentUserId().then((String? id) {
      if (mounted && id != null && id == widget.member.id) {
        setState(() => _isSelf = true);
      }
    });
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    final DateTime now = DateTime.now();
    try {
      final List<Trip> trips = await _api.listTrips(
        userId: widget.member.id,
        from: now.subtract(Duration(days: _days)),
        to: now,
      );
      if (!mounted) return;
      setState(() {
        _trips = trips;
        _error = null;
        _loading = false;
      });
    } on TripsException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _recompute() async {
    setState(() => _recomputing = true);
    final DateTime now = DateTime.now();
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await _api.compute(
        from: now.subtract(const Duration(days: 7)),
        to: now,
      );
      await _load(silent: true);
      messenger.showSnackBar(
        const SnackBar(content: Text('Trips recalculated for the last 7 days.')),
      );
    } on TripsException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _recomputing = false);
    }
  }

  void _openTrip(Trip t) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TripDetailScreen(trip: t, api: widget.api),
      ),
    );
  }

  void _openReport() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DrivingReportScreen(member: widget.member, api: widget.api),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: PrivateRuntime.primaryPrivate,
        builder: (BuildContext context, bool isPrivate, _) {
          if (!isPrivate) return _buildScreen(context);
          if (_lanesLoading) {
            return Scaffold(appBar: AppBar(title: Text('${widget.member.name}\'s trips')), body: const Center(child: CircularProgressIndicator()));
          }
          final MemberProcessing? p = _proc;
          if (p == null) {
            return Scaffold(
              appBar: AppBar(title: const Text('Trips')),
              body: const SafeArea(child: NotAvailableInPrivate(feature: PrivateFeature.trips)),
            );
          }
          if (p.origin == ProcessingOrigin.server) return _buildScreen(context);
          return _buildPhoneOnly(context, p);
        },
      );

  /// A phone-only member's trips: computed on their phone and shared sealed.
  Widget _buildPhoneOnly(BuildContext context, MemberProcessing p) {
    final String name = _procName.isEmpty ? widget.member.name : _procName;
    final DateTime from = DateTime.now().subtract(Duration(days: _days));
    final List<Trip> trips = <Trip>[
      for (final TripResult t in p.trips)
        if (t.startMs >= from.millisecondsSinceEpoch) _tripOf(t, widget.member.id)
    ];
    return Scaffold(
      appBar: AppBar(title: Text('$name\'s trips')),
      body: SafeArea(
        child: ValueListenableBuilder<UnitSystem>(
          valueListenable: UnitPreferenceService.units,
          builder: (BuildContext context, UnitSystem units, _) => ListView(
            key: const Key('trips-phone-only'),
            padding: const EdgeInsets.all(AppSpace.lg),
            children: <Widget>[
              Row(children: <Widget>[const LaneChip(server: false), const SizedBox(width: AppSpace.sm), Expanded(child: ComputedOnPhoneNote(name: name, updatedAt: p.updatedAt))]),
              const SizedBox(height: AppSpace.md),
              DsSegmentedTabs(
                labels: const <String>['7 days', '30 days'],
                selected: _days == 7 ? 0 : 1,
                onChanged: (int i) => setState(() => _days = i == 0 ? 7 : 30),
              ),
              const SizedBox(height: AppSpace.md),
              if (p.placeholder != null)
                WaitingForPhoneCard(name: name)
              else if (trips.isEmpty)
                const TripsMessageView(
                    icon: Icons.route_rounded, title: 'No trips in this period', message: 'Trips shared by their phone for this period appear here.')
              else
                for (final Trip t in trips)
                  Padding(padding: const EdgeInsets.only(bottom: AppSpace.md), child: TripCard(trip: t, units: units, onTap: null)),
              const SizedBox(height: AppSpace.sm),
              const GpsSpeedNote(),
            ],
          ),
        ),
      ),
    );
  }

  static Trip _tripOf(TripResult t, String userId) => Trip(
        id: t.id,
        userId: userId,
        startedAt: DateTime.fromMillisecondsSinceEpoch(t.startMs).toLocal(),
        endedAt: DateTime.fromMillisecondsSinceEpoch(t.endMs).toLocal(),
        durationS: t.durationS,
        distanceM: t.distanceM,
        maxSpeedMps: t.maxSpeedMps,
        avgSpeedMps: t.avgSpeedMps,
        mode: parseTripMode(t.mode),
        speedSource: 'phone',
        start: LatLng(t.startLat, t.startLon),
        end: LatLng(t.endLat, t.endLon),
      );

  Widget _buildScreen(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.member.name}\'s trips'),
        actions: <Widget>[
          if (_isSelf)
            IconButton(
              tooltip: 'Recalculate my trips',
              constraints: const BoxConstraints(minWidth: kMinTarget, minHeight: kMinTarget),
              onPressed: _recomputing ? null : _recompute,
              icon: const Icon(Icons.refresh_rounded),
            ),
        ],
      ),
      body: DsBody(child: Column(
        children: <Widget>[
          const SizedBox(height: AppSpace.sm),
          if (_proc != null)
            const Padding(
              padding: EdgeInsets.only(bottom: AppSpace.sm),
              child: Align(alignment: Alignment.centerLeft, child: LaneChip(server: true)),
            ),
          DsSegmentedTabs(
            labels: const <String>['7 days', '30 days'],
            selected: _days == 7 ? 0 : 1,
            onChanged: (int i) {
              setState(() => _days = i == 0 ? 7 : 30);
              _load();
            },
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.lg,
              AppSpace.sm,
              AppSpace.lg,
              0,
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: DsPillButton(
                label: 'Driving report',
                icon: Icons.insights_rounded,
                style: DsPillStyle.tonal,
                semanticLabel: 'Report',
                onPressed: _openReport,
              ),
            ),
          ),
          Expanded(child: _body()),
        ],
      )),
    );
  }

  Widget _body() {
    if (_loading) {
      return Semantics(
        label: 'Loading trips',
        child: const Padding(
          padding: EdgeInsets.all(AppSpace.lg),
          child: DsSkeletonList(rows: 4, avatar: false),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _load(silent: true),
      child: _content(),
    );
  }

  Widget _content() {
    if (_error != null && _trips == null) {
      return TripsMessageView.error(_error!, onRetry: _load);
    }
    final List<Trip> trips = _trips ?? const <Trip>[];
    if (trips.isEmpty) {
      return TripsMessageView(
        icon: Icons.route_rounded,
        title: 'No trips yet',
        message: 'Trips appear here after ${widget.member.name} has been '
            'moving for a few minutes with location sharing on.',
      );
    }
    final List<TripDay> days = groupTripsByDay(trips);
    return ValueListenableBuilder<UnitSystem>(
      valueListenable: UnitPreferenceService.units,
      builder: (BuildContext context, UnitSystem units, _) {
        return ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(
            AppSpace.lg,
            AppSpace.xs,
            AppSpace.lg,
            AppSpace.xxl,
          ),
          children: <Widget>[
            if (_error != null)
              _StaleBanner(message: _error!.message, onRetry: _load),
            for (final TripDay d in days) ...<Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.xs,
                  AppSpace.lg,
                  AppSpace.xs,
                  AppSpace.sm,
                ),
                child: Semantics(
                  header: true,
                  child: Text(
                    MaterialLocalizations.of(context).formatFullDate(d.day),
                    style: AppType.headline,
                  ),
                ),
              ),
              for (final Trip t in d.trips)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpace.md),
                  child: TripCard(
                    trip: t,
                    units: units,
                    onTap: () => _openTrip(t),
                  ),
                ),
            ],
            const SizedBox(height: AppSpace.sm),
            const GpsSpeedNote(),
          ],
        );
      },
    );
  }
}

class _StaleBanner extends StatelessWidget {
  const _StaleBanner({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        margin: const EdgeInsets.only(top: AppSpace.sm),
        padding: const EdgeInsets.all(AppSpace.md),
        decoration: BoxDecoration(
          color: AppColors.statusOrange.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Icon(Icons.cloud_off_rounded, size: 22),
            const SizedBox(width: AppSpace.sm),
            Expanded(
              child: Text(
                '$message Showing the last loaded trips.',
                style: AppType.body.copyWith(fontWeight: FontWeight.w500),
              ),
            ),
            TextButton(
              style: TextButton.styleFrom(
                minimumSize: const Size(kMinTarget, kMinTarget),
              ),
              onPressed: onRetry,
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
