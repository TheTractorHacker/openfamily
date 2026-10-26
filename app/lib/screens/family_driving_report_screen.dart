import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../models/member.dart';
import '../models/trip_report.dart';
import '../services/circle_selection.dart' show kAllCircles;
import '../services/speed_units.dart';
import '../services/trip_report_service.dart';
import '../services/trips_service.dart';
import '../theme/app_theme.dart';
import '../widgets/driving_event_chips.dart';
import '../widgets/driving_event_sheet.dart';
import '../widgets/driving_report_cards.dart';
import '../widgets/ds/ds.dart';
import '../widgets/trip_widgets.dart';
import 'trips_screen.dart';

/// The Driving tab: the family's weekly driving report. Event chips, summary
/// cards and one card per member that opens that member's trips.
class FamilyDrivingReportScreen extends StatefulWidget {
  const FamilyDrivingReportScreen({
    super.key,
    required this.members,
    required this.userId,
    this.circleId,
    this.api,
    this.tripsApi,
    this.clock,
    this.datePicker,
  });

  final ValueListenable<List<Member>> members;
  final ValueListenable<String?> userId;

  /// The circle selected on the map (null = unscoped, 'all' = every circle).
  final ValueListenable<String?>? circleId;
  final TripReportApi? api;

  /// Passed on to [TripsScreen].
  final TripsApi? tripsApi;

  /// Overridable "now" (tests).
  final DateTime Function()? clock;

  /// Overridable picker (tests); returns any day in the chosen week.
  final Future<DateTime?> Function(BuildContext, DateTime now)? datePicker;

  @override
  State<FamilyDrivingReportScreen> createState() => _State();
}

class _State extends State<FamilyDrivingReportScreen> {
  late final TripReportApi _api = widget.api ?? TripReportService.instance;

  ReportPreset _preset = ReportPreset.thisWeek;
  DateTime? _custom;
  TripReport? _report;
  TripsException? _error;
  bool _loading = true;
  int _seq = 0;

  DateTime get _now => widget.clock?.call() ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    UnitPreferenceService.ensureLoaded();
    widget.circleId?.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    widget.circleId?.removeListener(_load);
    super.dispose();
  }

  String? get _scope {
    final String? id = widget.circleId?.value;
    return id == null || id == kAllCircles ? null : id;
  }

  Future<void> _load() async {
    final int seq = ++_seq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final TripReport r = await _api.report(
        start: presetStart(_preset, _now, custom: _custom),
        circleId: _scope,
      );
      if (!mounted || seq != _seq) return;
      setState(() {
        _report = r;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _error = mapTripsError(e);
        _loading = false;
      });
    }
  }

  void _pick(ReportPreset p) {
    if (p == _preset && _custom == null) return;
    setState(() {
      _preset = p;
      _report = null;
    });
    _load();
  }

  Future<void> _pickDate() async {
    final DateTime now = _now;
    final DateTime? d = await (widget.datePicker?.call(context, now) ??
        showDatePicker(
          context: context,
          initialDate: _custom ?? now,
          firstDate: DateTime(now.year - 2),
          lastDate: now,
          helpText: 'Pick any day in the week',
        ));
    if (d == null || !mounted) return;
    setState(() {
      _preset = ReportPreset.custom;
      _custom = d;
      _report = null;
    });
    _load();
  }

  // ---- members ----

  Member _memberFor(String id, String name) {
    for (final Member m in widget.members.value) {
      if (m.id == id) return m;
    }
    return Member(
      id: id,
      name: name,
      position: null,
      status: MemberStatus.normal,
      batteryPercent: 0,
      address: '',
    );
  }

  String _nameOf(MemberReport m) =>
      m.userId == widget.userId.value ? 'You' : (m.name.isEmpty ? 'Member' : m.name);

  void _openMember(MemberReport m) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TripsScreen(
          member: _memberFor(m.userId, m.name),
          api: widget.tripsApi,
        ),
      ),
    );
  }

  // ---- build ----

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ValueListenableBuilder<UnitSystem>(
          valueListenable: UnitPreferenceService.units,
          builder: (BuildContext context, UnitSystem units, _) {
            return RefreshIndicator(
              onRefresh: _load,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(
                      AppSpace.gutter,
                      AppSpace.md,
                      AppSpace.gutter,
                      AppSpace.xxxl,
                    ),
                    children: <Widget>[
                      _periodChips(context),
                      const SizedBox(height: AppSpace.lg),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: Semantics(
                              header: true,
                              child: Text(
                                'Weekly driving report',
                                style: AppType.title.copyWith(fontSize: 28),
                              ),
                            ),
                          ),
                          const UnitToggleButton(),
                        ],
                      ),
                      if (_report != null) ...<Widget>[
                        const SizedBox(height: AppSpace.xxs),
                        Text(
                          formatDateRange(
                            _report!.start,
                            _report!.end,
                            now: _now,
                          ),
                          style: AppType.body.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                      const SizedBox(height: AppSpace.lg),
                      ..._content(context, units),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _periodChips(BuildContext context) {
    final DateTime now = _now;
    final String custom = _custom == null
        ? 'Pick a week'
        : formatDateRange(
            weekStartOf(_custom!),
            weekStartOf(_custom!).add(const Duration(days: 6)),
            now: now,
          );
    return Wrap(
      spacing: AppSpace.sm,
      runSpacing: AppSpace.sm,
      children: <Widget>[
        _PeriodChip(
          label: 'This week',
          selected: _preset == ReportPreset.thisWeek,
          onTap: () => _pick(ReportPreset.thisWeek),
        ),
        _PeriodChip(
          label: 'Last week',
          selected: _preset == ReportPreset.lastWeek,
          onTap: () => _pick(ReportPreset.lastWeek),
        ),
        _PeriodChip(
          label: custom,
          icon: Icons.calendar_month_outlined,
          selected: _preset == ReportPreset.custom,
          semanticLabel: _custom == null
              ? 'Pick a week from the calendar'
              : 'Week of $custom. Tap to change.',
          onTap: _pickDate,
        ),
      ],
    );
  }

  List<Widget> _content(BuildContext context, UnitSystem units) {
    final TripReport? r = _report;
    if (r == null) {
      if (_loading) return const <Widget>[DrivingReportSkeleton()];
      final TripsException e = _error!;
      return <Widget>[
        SizedBox(
          height: 320,
          child: TripsMessageView.error(e, onRetry: _load),
        ),
      ];
    }
    final String phrase = periodPhrase(_preset);
    final List<MemberReport> members = <MemberReport>[
      ...r.members.where((MemberReport m) => m.userId == widget.userId.value),
      ...r.members.where((MemberReport m) => m.userId != widget.userId.value),
    ];
    final String? topId = r.totals.topSpeedUserId;
    MemberReport? topM;
    for (final MemberReport m in r.members) {
      if (m.userId == topId) topM = m;
    }
    final bool noPhone = r.totals.events.phoneUse == null;
    return <Widget>[
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpace.md),
          child: DsOfflineBanner(
            message: _error!.kind == TripsFailure.offline
                ? 'You are offline. Showing the last report.'
                : 'Could not refresh. Showing the last report.',
            onRetry: _load,
          ),
        ),
      if (_loading)
        const Padding(
          padding: EdgeInsets.only(bottom: AppSpace.sm),
          child: LinearProgressIndicator(minHeight: 3),
        ),
      DrivingEventChips(
        report: r,
        phrase: phrase,
        onTap: (DrivingEventKind k) => showDrivingEventSheet(
          context,
          report: r,
          kind: k,
          units: units,
          phrase: phrase,
          nameOf: _nameOf,
        ),
      ),
      if (noPhone)
        Padding(
          padding: const EdgeInsets.only(top: AppSpace.sm),
          child: Text(
            'Phone use is not tracked yet, so it shows no number rather '
            'than a zero.',
            style: AppType.secondary.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      const SizedBox(height: AppSpace.lg),
      if (r.isEmpty) ...<Widget>[
        const SizedBox(height: AppSpace.lg),
        DsEmptyState(
          icon: Icons.directions_car_outlined,
          title: _preset == ReportPreset.thisWeek
              ? 'No trips this week yet'
              : 'No trips in this week',
          message:
              'Drives appear here once someone in your circle shares their '
              'location while driving.',
        ),
      ] else ...<Widget>[
        DrivingSummaryCards(
          report: r,
          units: units,
          topSpeedMember: topM == null ? null : _memberFor(topM.userId, topM.name),
        ),
        const SizedBox(height: AppSpace.lg),
        Semantics(
          header: true,
          child: const Text('Drivers', style: AppType.headline),
        ),
        const SizedBox(height: AppSpace.sm),
        for (final MemberReport m in members)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.md),
            child: MemberDrivingCard(
              report: m,
              member: _memberFor(m.userId, m.name),
              displayName: _nameOf(m),
              units: units,
              onTap: () => _openMember(m),
            ),
          ),
        if (r.estimated)
          Padding(
            padding: const EdgeInsets.only(top: AppSpace.xs),
            child: Text(
              'Speeds, braking and acceleration are GPS estimates.',
              style: AppType.secondary.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    ];
  }
}

class _PeriodChip extends StatelessWidget {
  const _PeriodChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.semanticLabel,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final BrandTheme brand = BrandTheme.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Color fg = selected ? brand.onAccent : cs.onSurface;
    return Semantics(
      button: true,
      selected: selected,
      label: semanticLabel ?? label,
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: selected ? brand.accent : brand.sheet,
        shape: StadiumBorder(
          side: selected ? BorderSide.none : BorderSide(color: cs.outlineVariant),
        ),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: kMinTarget),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (icon != null) ...<Widget>[
                    Icon(icon, size: 18, color: fg),
                    const SizedBox(width: AppSpace.sm),
                  ],
                  Flexible(
                    child: Text(
                      label,
                      style: AppType.body.copyWith(
                        fontWeight: FontWeight.w700,
                        color: fg,
                      ),
                    ),
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
