import 'package:flutter/material.dart';

import '../models/member.dart';
import '../models/trip.dart';
import '../services/speed_units.dart';
import '../services/trips_service.dart';
import '../theme/app_theme.dart';
import '../widgets/trip_widgets.dart';
import 'driving_report_screen.dart';
import 'trip_detail_screen.dart';

/// A member's trips, grouped by day, newest first.
class TripsScreen extends StatefulWidget {
  const TripsScreen({super.key, required this.member, this.api});

  final Member member;

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

  @override
  void initState() {
    super.initState();
    UnitPreferenceService.ensureLoaded();
    _load();
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
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.member.name}\'s trips'),
        actions: <Widget>[
          const UnitToggleButton(),
          if (_isSelf)
            IconButton(
              tooltip: 'Recalculate my trips',
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              onPressed: _recomputing ? null : _recompute,
              icon: const Icon(Icons.refresh_rounded),
            ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: SegmentedButton<int>(
                    showSelectedIcon: false,
                    segments: const <ButtonSegment<int>>[
                      ButtonSegment<int>(value: 7, label: Text('7 days')),
                      ButtonSegment<int>(value: 30, label: Text('30 days')),
                    ],
                    selected: <int>{_days},
                    onSelectionChanged: (Set<int> s) {
                      setState(() => _days = s.first);
                      _load();
                    },
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(48, 48),
                  ),
                  onPressed: _openReport,
                  icon: const Icon(Icons.insights_rounded),
                  label: const Text('Report'),
                ),
              ],
            ),
          ),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(semanticsLabel: 'Loading trips'),
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
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          children: <Widget>[
            if (_error != null)
              _StaleBanner(message: _error!.message, onRetry: _load),
            for (final TripDay d in days) ...<Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 14, 4, 8),
                child: Semantics(
                  header: true,
                  child: Text(
                    MaterialLocalizations.of(context).formatFullDate(d.day),
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              for (final Trip t in d.trips)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: TripCard(
                    trip: t,
                    units: units,
                    onTap: () => _openTrip(t),
                  ),
                ),
            ],
            const SizedBox(height: 8),
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
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.statusOrange.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: <Widget>[
          const Icon(Icons.cloud_off_rounded, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text('$message Showing the last loaded trips.')),
          TextButton(
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: onRetry,
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

/// App-bar action that flips between mph and km/h.
class UnitToggleButton extends StatelessWidget {
  const UnitToggleButton({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<UnitSystem>(
      valueListenable: UnitPreferenceService.units,
      builder: (BuildContext context, UnitSystem u, _) {
        final UnitSystem next =
            u == UnitSystem.imperial ? UnitSystem.metric : UnitSystem.imperial;
        return TextButton(
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: () => UnitPreferenceService.setUnits(next),
          child: Semantics(
            label: 'Units: ${u.speedLabel}. Switch to ${next.speedLabel}',
            excludeSemantics: true,
            child: Text(u.speedLabel),
          ),
        );
      },
    );
  }
}
