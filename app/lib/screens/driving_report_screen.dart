import '../widgets/driving_page_widgets.dart' show driveCardDecoration;
import 'package:flutter/material.dart';

import '../models/member.dart';
import '../models/trip.dart';
import '../services/speed_units.dart';
import '../services/trips_service.dart';
import '../theme/app_theme.dart';
import '../services/e2ee/private_runtime.dart';
import '../services/processing/primary_lanes.dart';
import '../services/processing/processing_source.dart';
import '../widgets/phone_driving_widgets.dart';
import '../widgets/private_circle_widgets.dart';
import '../widgets/ds/ds.dart';
import '../widgets/trip_widgets.dart';

const List<String> kReportPeriods = <String>['day', 'week', 'month'];

/// Day / week / month driving report for a member. The speed-event threshold
/// is a local preference sent with each request; it is never stored on the
/// server and no alerts are raised.
class DrivingReportScreen extends StatefulWidget {
  const DrivingReportScreen({super.key, required this.member, this.api, this.lanes, this.clock});

  final Member member;

  /// Injected in tests; defaults to the running app's processing lanes.
  final PrimaryLanesLoader? lanes;
  final DateTime Function()? clock;
  final TripsApi? api;

  @override
  State<DrivingReportScreen> createState() => _DrivingReportScreenState();
}

class _DrivingReportScreenState extends State<DrivingReportScreen> {
  double _thresholdMps = UnitPreferenceService.defaultThresholdMps;
  // Value shown on the slider while dragging (display units).
  double? _dragValue;

  @override
  void initState() {
    super.initState();
    UnitPreferenceService.ensureLoaded();
    if (PrivateRuntime.primaryPrivate.value) _loadLanes();
    UnitPreferenceService.loadThreshold().then((double v) {
      if (mounted) setState(() => _thresholdMps = v);
    });
  }

  // Private circle with processing lanes: where this member's figures come from.
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
  }

  void _commit(UnitSystem u, double displayValue) {
    final double mps = u.mpsFromSpeed(displayValue);
    setState(() {
      _thresholdMps = mps;
      _dragValue = null;
    });
    UnitPreferenceService.saveThreshold(mps);
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: PrivateRuntime.primaryPrivate,
        builder: (BuildContext context, bool isPrivate, _) {
          if (!isPrivate) return _buildScreen(context);
          if (_lanesLoading) {
            return Scaffold(appBar: AppBar(title: Text('${widget.member.name}\'s driving')), body: const Center(child: CircularProgressIndicator()));
          }
          final MemberProcessing? p = _proc;
          if (p == null) {
            return Scaffold(
              appBar: AppBar(title: const Text('Driving report')),
              body: const SafeArea(child: NotAvailableInPrivate(feature: PrivateFeature.drivingReport)),
            );
          }
          if (p.origin == ProcessingOrigin.server) return _buildScreen(context);
          return _buildPhoneOnly(context, p);
        },
      );

  /// Day / week / month figures a phone-only member's phone computed and shared.
  Widget _buildPhoneOnly(BuildContext context, MemberProcessing p) {
    final String name = _procName.isEmpty ? widget.member.name : _procName;
    final DateTime now = widget.clock?.call() ?? DateTime.now();
    return DefaultTabController(
      length: kReportPeriods.length,
      child: Scaffold(
        appBar: AppBar(
          title: Text('$name\'s driving'),
          bottom: const TabBar(tabs: <Widget>[Tab(text: 'Day'), Tab(text: 'Week'), Tab(text: 'Month')]),
        ),
        body: SafeArea(
          child: ValueListenableBuilder<UnitSystem>(
            valueListenable: UnitPreferenceService.units,
            builder: (BuildContext context, UnitSystem units, _) => TabBarView(
              key: const Key('driving-phone-only'),
              children: <Widget>[
                for (final String period in kReportPeriods)
                  ListView(padding: const EdgeInsets.all(AppSpace.lg), children: <Widget>[
                    PhoneDrivingCard(
                      name: name,
                      member: p,
                      from: periodStartForKind(period, now),
                      to: periodEndOf(period, periodStartForKind(period, now)),
                      units: units,
                      now: now,
                    ),
                  ]),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildScreen(BuildContext context) {
    return DefaultTabController(
      length: kReportPeriods.length,
      child: Scaffold(
        appBar: AppBar(
          title: Text('${widget.member.name}\'s driving'),
          bottom: const TabBar(
            tabs: <Widget>[
              Tab(text: 'Day'),
              Tab(text: 'Week'),
              Tab(text: 'Month'),
            ],
          ),
        ),
        body: DsBody(child: ValueListenableBuilder<UnitSystem>(
          valueListenable: UnitPreferenceService.units,
          builder: (BuildContext context, UnitSystem units, _) {
            return Column(
              children: <Widget>[
                _ThresholdControl(
                  units: units,
                  thresholdMps: _thresholdMps,
                  dragValue: _dragValue,
                  onChanged: (double v) => setState(() => _dragValue = v),
                  onChangeEnd: (double v) => _commit(units, v),
                ),
                Expanded(
                  child: TabBarView(
                    children: <Widget>[
                      for (final String p in kReportPeriods)
                        ReportPeriodView(
                          key: ValueKey<String>(p),
                          member: widget.member,
                          period: p,
                          thresholdMps: _thresholdMps,
                          units: units,
                          api: widget.api ?? TripsService.instance,
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
        )),
      ),
    );
  }
}

class _ThresholdControl extends StatelessWidget {
  const _ThresholdControl({
    required this.units,
    required this.thresholdMps,
    required this.dragValue,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final UnitSystem units;
  final double thresholdMps;
  final double? dragValue;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final bool imperial = units == UnitSystem.imperial;
    final double min = imperial ? 30 : 50;
    final double max = imperial ? 100 : 160;
    final double current =
        (dragValue ?? units.speedFromMps(thresholdMps)).clamp(min, max);
    final String shown = '${current.round()} ${units.speedLabel}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        AppSpace.sm,
        AppSpace.lg,
        0,
      ),
      child: Container(
        padding: const EdgeInsets.fromLTRB(
          AppSpace.lg,
          AppSpace.md,
          AppSpace.lg,
          AppSpace.xs,
        ),
        decoration: BoxDecoration(
          color: BrandTheme.of(context).sheet,
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Speed event threshold: $shown', style: AppType.body),
            Semantics(
              label: 'Speed event threshold',
              value: shown,
              child: Slider(
                min: min,
                max: max,
                divisions: (max - min).round() ~/ 5,
                value: current,
                label: shown,
                onChanged: onChanged,
                onChangeEnd: onChangeEnd,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One tab of the report. Reloads when the threshold changes.
class ReportPeriodView extends StatefulWidget {
  const ReportPeriodView({
    super.key,
    required this.member,
    required this.period,
    required this.thresholdMps,
    required this.units,
    required this.api,
  });

  final Member member;
  final String period;
  final double thresholdMps;
  final UnitSystem units;
  final TripsApi api;

  @override
  State<ReportPeriodView> createState() => _ReportPeriodViewState();
}

class _ReportPeriodViewState extends State<ReportPeriodView>
    with AutomaticKeepAliveClientMixin {
  TripSummary? _summary;
  TripsException? _error;
  bool _loading = true;
  int _seq = 0;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(ReportPeriodView old) {
    super.didUpdateWidget(old);
    if (old.thresholdMps != widget.thresholdMps) _load(silent: true);
  }

  Future<void> _load({bool silent = false}) async {
    final int seq = ++_seq;
    if (!silent || _summary == null) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final TripSummary s = await widget.api.summary(
        userId: widget.member.id,
        period: widget.period,
        speedThresholdMps: widget.thresholdMps,
      );
      if (!mounted || seq != _seq) return;
      setState(() {
        _summary = s;
        _error = null;
        _loading = false;
      });
    } on TripsException catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) {
      return Semantics(
        label: 'Loading report',
        child: const Padding(
          padding: EdgeInsets.all(AppSpace.lg),
          child: DsSkeletonList(rows: 4, avatar: false),
        ),
      );
    }
    return RefreshIndicator(onRefresh: () => _load(silent: true), child: _body());
  }

  Widget _body() {
    if (_error != null && _summary == null) {
      return TripsMessageView.error(_error!, onRetry: _load);
    }
    final TripSummary s = _summary!;
    if (s.tripCount == 0) {
      return const TripsMessageView(
        icon: Icons.route_rounded,
        title: 'No trips yet',
        message: 'There are no trips in this period.',
      );
    }
    final UnitSystem u = widget.units;
    final DrivingStats d = s.driving;
    final ColorScheme cs = Theme.of(context).colorScheme;
    final MaterialLocalizations loc = MaterialLocalizations.of(context);
    final String range = widget.period == 'day'
        ? loc.formatFullDate(s.from)
        : '${loc.formatShortDate(s.from)} - '
            '${loc.formatShortDate(s.to.subtract(const Duration(seconds: 1)))}';
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        AppSpace.sm,
        AppSpace.lg,
        AppSpace.xxl,
      ),
      children: <Widget>[
        Text(
          range,
          style: AppType.body.copyWith(color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: AppSpace.md),
        if (_error != null)
          Semantics(
            liveRegion: true,
            container: true,
            child: Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.sm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Icon(Icons.cloud_off_rounded, size: 20),
                  const SizedBox(width: AppSpace.sm),
                  Expanded(
                    child: Text(
                      '${_error!.message} Showing the last loaded report.',
                      style: AppType.body.copyWith(fontWeight: FontWeight.w500),
                    ),
                  ),
                ],
              ),
            ),
          ),
        Container(
          padding: const EdgeInsets.all(AppSpace.lg),
          decoration: driveCardDecoration(context),
          child: Wrap(
            spacing: AppSpace.xxl,
            runSpacing: AppSpace.lg,
            children: <Widget>[
              TripStat(label: 'All trips', value: '${s.tripCount}'),
              TripStat(label: 'Driving trips', value: '${d.tripCount}'),
              TripStat(
                label: 'Driving distance',
                value: u.formatDistance(d.distanceM),
              ),
              TripStat(
                label: 'Drive time',
                value: formatTripDuration(
                  Duration(seconds: d.driveTimeS.round()),
                ),
              ),
              TripStat(
                label: 'Top GPS speed',
                value: d.tripCount == 0 ? 'n/a' : u.formatSpeed(d.maxSpeedMps),
              ),
              TripStat(
                label: 'Avg GPS speed',
                value: d.tripCount == 0 ? 'n/a' : u.formatSpeed(d.avgSpeedMps),
              ),
              TripStat(
                label: 'Over ${u.formatSpeed(s.speedThresholdMps)}',
                value: '${d.speedEvents}'
                    '${d.speedEventsTruncated ? '+' : ''}'
                    ' ${d.speedEvents == 1 ? 'event' : 'events'}',
              ),
              TripStat(label: 'Stops', value: '${s.stops.length}'),
            ],
          ),
        ),
        if (d.speedEventsTruncated)
          Padding(
            padding: const EdgeInsets.only(top: AppSpace.sm),
            child: Text(
              'Very busy period: speed events were counted for only part of '
              'the trips, so the real number may be higher.',
              style: AppType.secondary.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
        if (s.stops.isNotEmpty) ...<Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.xs,
              AppSpace.xl,
              AppSpace.xs,
              AppSpace.sm,
            ),
            child: Semantics(
              header: true,
              child: const Text('Stops', style: AppType.headline),
            ),
          ),
          for (final TripStop st in s.stops)
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: kMinTarget),
              child: Semantics(
                container: true,
                excludeSemantics: true,
                label: 'Stop for '
                    '${formatTripDuration(Duration(seconds: st.durationS.round()))}'
                    ', arrived ${tripClock(context, st.arrivedAt)}, left '
                    '${tripClock(context, st.departedAt)}',
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpace.sm),
                  child: Row(
                    children: <Widget>[
                      const Icon(Icons.pause_circle_outline_rounded),
                      const SizedBox(width: AppSpace.md),
                      Expanded(
                        child: Text(
                          '${tripClock(context, st.arrivedAt)} - '
                          '${tripClock(context, st.departedAt)}',
                        ),
                      ),
                      Text(
                        formatTripDuration(
                          Duration(seconds: st.durationS.round()),
                        ),
                        style: AppType.body,
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
        const SizedBox(height: AppSpace.lg),
        const GpsSpeedNote(),
        const SizedBox(height: AppSpace.xs),
        Text(
          'Periods follow server time (UTC), so a day or week may start '
          'part-way through your local day.',
          style: AppType.secondary.copyWith(color: cs.onSurfaceVariant),
        ),
      ],
    );
  }
}
