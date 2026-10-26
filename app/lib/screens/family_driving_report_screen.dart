import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../models/member.dart';
import '../models/trip.dart';
import '../models/trip_report.dart';
import '../services/circle_selection.dart' show kAllCircles;
import '../services/driving/driving_settings.dart';
import '../services/speed_units.dart';
import '../services/trip_report_service.dart';
import '../services/trips_service.dart';
import '../theme/app_theme.dart';
import '../widgets/driving_event_chips.dart';
import '../widgets/driving_event_sheet.dart';
import '../widgets/driving_page_widgets.dart';
import '../widgets/driving_report_cards.dart';
import '../widgets/ds/ds.dart';
import 'driving_detection_screen.dart';
import 'trip_detail_screen.dart';
import 'trips_screen.dart';

/// The Driving tab: who is driving now, the period's totals, a per-day chart,
/// the latest drives and one card per member. Everything comes from one
/// `GET /trips/report` request plus the live member snapshot.
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
    this.sharing,
    this.detectionLoader,
    this.optInSync,
  });

  final ValueListenable<List<Member>> members;
  final ValueListenable<String?> userId;

  /// The circle selected on the map (null = unscoped, 'all' = every circle).
  final ValueListenable<String?>? circleId;
  final TripReportApi? api;

  /// Passed on to [TripsScreen] and [TripDetailScreen].
  final TripsApi? tripsApi;

  /// Overridable "now" (tests).
  final DateTime Function()? clock;

  /// Overridable picker (tests); returns any day in the chosen period.
  final Future<DateTime?> Function(BuildContext, DateTime now)? datePicker;

  /// This phone's location sharing (false = paused). Null means unknown/on.
  final ValueListenable<bool>? sharing;

  /// Whether Driving detection is on. Defaults to the stored preference
  /// (missing = on).
  final Future<bool> Function()? detectionLoader;

  /// Tells the server the effective detection opt-in (the app passes
  /// `DrivingEventsService.syncOptIn`). Null = do nothing (tests).
  final Future<bool> Function()? optInSync;

  @override
  State<FamilyDrivingReportScreen> createState() => _State();
}

class _State extends State<FamilyDrivingReportScreen> {
  late final TripReportApi _api = widget.api ?? TripReportService.instance;

  String _period = 'week';
  late DateTime _anchor = periodStartOf(_period, _now);
  DateTime? _day;
  TripReport? _report;
  TripsException? _error;
  bool _loading = true;
  bool? _detectionOn;
  bool _disclosureSeen = true;
  int _seq = 0;

  DateTime get _now => widget.clock?.call() ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    UnitPreferenceService.ensureLoaded();
    widget.circleId?.addListener(_load);
    widget.optInSync?.call();
    _loadPrefs();
    _load();
  }

  @override
  void dispose() {
    widget.circleId?.removeListener(_load);
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    final bool on = await (widget.detectionLoader?.call() ??
        DrivingSettings.sensorEnabled(reload: false));
    final bool seen = await DrivingSettings.disclosureSeen();
    if (!mounted) return;
    setState(() {
      _detectionOn = on;
      _disclosureSeen = seen;
    });
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
        start: _anchor,
        period: _period,
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

  void _goTo(String period, DateTime anchor) {
    final DateTime cur = periodStartOf(period, _now);
    setState(() {
      _period = period;
      _anchor = anchor.isAfter(cur) ? cur : periodStartOf(period, anchor);
      _day = null;
      _report = null;
    });
    _load();
  }

  bool get _canNext =>
      !shiftPeriod(_period, _anchor, 1).isAfter(periodStartOf(_period, _now));

  Future<void> _pickDate() async {
    final DateTime now = _now;
    final DateTime? d = await (widget.datePicker?.call(context, now) ??
        showDatePicker(
          context: context,
          initialDate: _anchor,
          firstDate: DateTime(now.year - 2),
          lastDate: now,
          helpText: _period == 'month'
              ? 'Pick any day in the month'
              : 'Pick any day in the week',
        ));
    if (d == null || !mounted) return;
    _goTo(_period, d);
  }

  Future<void> _openDetection() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const DrivingDetectionScreen()),
    );
    await _loadPrefs();
  }

  Future<void> _dismissDisclosure({bool openSettings = false}) async {
    setState(() => _disclosureSeen = true);
    await DrivingSettings.markDisclosureSeen();
    if (openSettings && mounted) await _openDetection();
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

  void _openMember(Member m) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TripsScreen(member: m, api: widget.tripsApi),
      ),
    );
  }

  void _openTrip(RecentTrip t) {
    final Trip trip = Trip(
      id: t.id,
      userId: t.userId,
      startedAt: t.startedAt,
      endedAt: t.endedAt,
      durationS: t.durationS,
      distanceM: t.distanceM,
      maxSpeedMps: t.maxSpeedMps,
      avgSpeedMps: t.durationS > 0 ? t.distanceM / t.durationS : 0,
      mode: TripMode.driving,
      speedSource: 'device_gps',
      start: const LatLng(0, 0),
      end: const LatLng(0, 0),
    );
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TripDetailScreen(trip: trip, api: widget.tripsApi),
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
                  constraints: BoxConstraints(
                    maxWidth:
                        MediaQuery.sizeOf(context).width >= 840 ? 640 : 560,
                  ),
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(
                      AppSpace.gutter,
                      AppSpace.lg,
                      AppSpace.gutter,
                      AppSpace.xxxl,
                    ),
                    children: <Widget>[
                      if (!_disclosureSeen && _detectionOn == true) ...<Widget>[
                        DrivingNoticeCard(
                          icon: Icons.shield_outlined,
                          title: 'Driving detection is on',
                          message:
                              'Your phone reads its motion sensor only while '
                              'you are driving, to notice hard braking and '
                              'sudden acceleration. Only the detected events '
                              'are uploaded, never the raw sensor data. You '
                              'can turn it off at any time.',
                          actionLabel: 'Okay',
                          onAction: _dismissDisclosure,
                          secondaryLabel: 'Change in Settings',
                          onSecondary: () =>
                              _dismissDisclosure(openSettings: true),
                        ),
                        const SizedBox(height: AppSpace.lg),
                      ],
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: Semantics(
                              header: true,
                              child: Text(
                                'Driving',
                                style: AppType.title.copyWith(fontSize: 28),
                              ),
                            ),
                          ),
                          const UnitToggleButton(),
                        ],
                      ),
                      const SizedBox(height: AppSpace.sm),
                      DrivingPeriodBar(
                        period: _period,
                        title: periodTitle(_period, _anchor, now: _now),
                        caption: _caption(),
                        canNext: _canNext,
                        onPeriod: (String p) {
                          if (p != _period) _goTo(p, _anchor);
                        },
                        onPrev: () =>
                            _goTo(_period, shiftPeriod(_period, _anchor, -1)),
                        onNext: () =>
                            _goTo(_period, shiftPeriod(_period, _anchor, 1)),
                        onPick: _pickDate,
                      ),
                      const SizedBox(height: AppSpace.md),
                      ValueListenableBuilder<List<Member>>(
                        valueListenable: widget.members,
                        builder: (BuildContext context, List<Member> all, _) =>
                            DrivingNowStrip(
                          driving: <Member>[
                            ...all.where((Member m) =>
                                m.movement == MovementType.car &&
                                m.id == widget.userId.value),
                            ...all.where((Member m) =>
                                m.movement == MovementType.car &&
                                m.id != widget.userId.value),
                          ],
                          selfId: widget.userId.value,
                          units: units,
                          onTap: _openMember,
                        ),
                      ),
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

  String? _caption() {
    final String unit = _period == 'month' ? 'month' : 'week';
    final DateTime cur = periodStartOf(_period, _now);
    if (_anchor == cur) return 'This $unit';
    if (_anchor == shiftPeriod(_period, cur, -1)) return 'Last $unit';
    return null;
  }

  List<Widget> _content(BuildContext context, UnitSystem units) {
    final TripReport? r = _report;
    if (r == null) {
      if (_loading) return const <Widget>[DrivingReportSkeleton()];
      final TripsException e = _error!;
      return <Widget>[
        const SizedBox(height: AppSpace.xl),
        if (e.kind == TripsFailure.offline)
          DsErrorState(
            icon: Icons.cloud_off_rounded,
            title: 'You are offline',
            message:
                'The driving report needs a connection to the server. '
                'Pull down or try again once you are back online.',
            onRetry: _load,
          )
        else
          DsErrorState(
            title: 'Could not load the report',
            message: e.message,
            onRetry: _load,
          ),
      ];
    }
    final String phrase = periodPhraseFor(_period, _anchor, _now);
    final String? me = widget.userId.value;
    final List<MemberReport> sorted = <MemberReport>[
      ...r.members.where((MemberReport m) => m.userId == me),
      ...r.members.where((MemberReport m) => m.userId != me),
    ];
    final List<MemberReport> active =
        sorted.where((MemberReport m) => m.drives > 0).toList();
    final List<MemberReport> idle =
        sorted.where((MemberReport m) => m.drives == 0).toList();
    final String? topId = r.totals.topSpeedUserId;
    MemberReport? topM;
    for (final MemberReport m in r.members) {
      if (m.userId == topId) topM = m;
    }
    final bool noPhone = r.totals.events.phoneUse == null;
    final bool sharingPaused = widget.sharing?.value == false;
    Widget card(MemberReport m) => MemberDrivingCard(
      report: m,
      member: _memberFor(m.userId, m.name),
      displayName: _nameOf(m),
      units: units,
      onTap: () => _openMember(_memberFor(m.userId, m.name)),
    );

    final List<RecentTrip> shown = _day == null
        ? r.recentTrips
        : r.recentTrips
              .where((RecentTrip t) =>
                  DateTime(t.startedAt.year, t.startedAt.month, t.startedAt.day) ==
                  _day)
              .toList();
    ReportDay? dayInfo;
    for (final ReportDay d in r.days) {
      if (d.date == _day) dayInfo = d;
    }

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
      if (sharingPaused)
        const Padding(
          padding: EdgeInsets.only(bottom: AppSpace.md),
          child: DrivingNoticeCard(
            icon: Icons.pause_circle_outline,
            title: 'Your location sharing is paused',
            message:
                'Drives are not recorded for you while sharing is paused. '
                'Turn sharing back on from the Location tab.',
          ),
        ),
      if (_detectionOn == false)
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpace.md),
          child: DrivingNoticeCard(
            icon: Icons.sensors_off_outlined,
            title: 'Hard braking and phone use need Driving detection',
            message:
                'Driving detection is turned off on this phone, so braking '
                'and acceleration are only estimated from GPS.',
            actionLabel: 'Open Driving detection',
            onAction: _openDetection,
          ),
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
        const Padding(
          padding: EdgeInsets.only(top: AppSpace.sm),
          child: DrivingHint(
            'Phone use is off, so it shows Off rather than a zero. Turn it on '
            'in Settings > Driving detection.',
          ),
        ),
      const SizedBox(height: AppSpace.lg),
      if (r.isEmpty) ...<Widget>[
        const SizedBox(height: AppSpace.lg),
        DsEmptyState(
          icon: Icons.directions_car_outlined,
          title: 'No drives yet $phrase'.replaceAll('yet in this', 'in this'),
          message:
              'Drives appear automatically when someone is moving faster '
              'than walking.',
        ),
        if (idle.isNotEmpty) ...<Widget>[
          const SizedBox(height: AppSpace.lg),
          NoDrivesGroup(
            names: idle.map(_nameOf).toList(),
            children: idle.map(card).toList(),
          ),
        ],
      ] else ...<Widget>[
        DrivingSummaryCards(
          report: r,
          units: units,
          topSpeedMember: topM == null ? null : _memberFor(topM.userId, topM.name),
        ),
        const SizedBox(height: AppSpace.lg),
        if (r.days.isNotEmpty) ...<Widget>[
          DrivingDaysChart(
            days: r.days,
            units: units,
            today: _now,
            selected: _day,
            onSelect: (DateTime? d) => setState(() => _day = d),
          ),
          const SizedBox(height: AppSpace.lg),
        ],
        if (r.recentTrips.isNotEmpty) ...<Widget>[
          Semantics(
            header: true,
            child: Text(
              _day == null ? 'Recent drives' : 'Drives on ${dayText(_day!)}',
              style: AppType.headline,
            ),
          ),
          if (_day != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => setState(() => _day = null),
                style: TextButton.styleFrom(
                  minimumSize: const Size(kMinTarget, kMinTarget),
                ),
                child: const Text('Show all drives'),
              ),
            ),
          const SizedBox(height: AppSpace.sm),
          if (shown.isEmpty)
            DrivingHint(
              dayInfo != null && dayInfo.drives > 0
                  ? 'This day is older than the latest ${r.recentTrips.length} '
                      'drives listed here. Open a driver below for every trip.'
                  : 'No drives on this day.',
            ),
          for (final RecentTrip t in shown)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.md),
              child: RecentDriveTile(
                trip: t,
                member: _memberFor(t.userId, t.name),
                name: t.userId == me ? 'You' : (t.name.isEmpty ? 'Member' : t.name),
                units: units,
                now: _now,
                onTap: () => _openTrip(t),
              ),
            ),
          const SizedBox(height: AppSpace.sm),
        ],
        Semantics(
          header: true,
          child: Text(
            sorted.length == 1 ? 'Driver' : 'Drivers',
            style: AppType.headline,
          ),
        ),
        const SizedBox(height: AppSpace.sm),
        for (final MemberReport m in active)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.md),
            child: card(m),
          ),
        if (idle.isNotEmpty)
          NoDrivesGroup(
            names: idle.map(_nameOf).toList(),
            children: idle.map(card).toList(),
          ),
        if (r.gpsOnly)
          const Padding(
            padding: EdgeInsets.only(top: AppSpace.md),
            child: DrivingHint(
              'Braking and acceleration here are estimated from GPS, which '
              'can miss short events. Speeds are GPS speed.',
            ),
          )
        else if (r.estimated)
          const Padding(
            padding: EdgeInsets.only(top: AppSpace.md),
            child: DrivingHint('Speeds, braking and acceleration are GPS estimates.'),
          ),
      ],
    ];
  }
}
