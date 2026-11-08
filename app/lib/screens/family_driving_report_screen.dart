import '../utils/self_label.dart';
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
import '../services/e2ee/private_runtime.dart';
import '../services/processing/primary_lanes.dart';
import '../services/processing/phone_report_merge.dart';
import '../services/processing/processing_source.dart';
import '../services/offline/offline_cache.dart' show Cached;
import '../widgets/phone_driving_widgets.dart';
import '../widgets/processing_widgets.dart';
import '../widgets/driving_event_chips.dart';
import '../widgets/driving_event_sheet.dart';
import '../widgets/driving_page_widgets.dart';
import '../widgets/driving_report_cards.dart';
import '../widgets/driving_member_dock.dart';
import '../widgets/ds/ds.dart';
import 'driving_detection_screen.dart';
import 'inbox_screen.dart';
import 'my_processing_screen.dart';
import 'trip_detail_screen.dart';
import 'trips_screen.dart';
import 'weekly_summary_screen.dart';

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
    this.lanes,
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

  /// Injected in tests; defaults to the running app's processing lanes.
  final PrimaryLanesLoader? lanes;

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

  /// When the shown report was saved, if the server could not be reached and
  /// the last saved copy is shown instead.
  DateTime? _cachedAt;

  DateTime get _now => widget.clock?.call() ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    UnitPreferenceService.ensureLoaded();
    widget.circleId?.addListener(_reload);
    PrivateRuntime.primaryPrivate.addListener(_onPrivateChanged);
    widget.optInSync?.call();
    _loadPrefs();
    if (PrivateRuntime.primaryPrivate.value) {
      _loadLanes();
    } else {
      _load();
    }
  }

  // The app learns that the primary circle is Private a moment after start:
  // the tab may already be open. Load the processing lanes then (never leave
  // the "could not load" card up), and go back to the plain report when the
  // circle turns Normal.
  void _onPrivateChanged() {
    if (!mounted) return;
    if (PrivateRuntime.primaryPrivate.value) {
      if (_lanes == null && !_lanesLoading) _loadLanes();
    } else {
      _load();
    }
  }

  void _reload() {
    if (PrivateRuntime.primaryPrivate.value) {
      _loadLanes();
    } else {
      _load();
    }
  }

  // Private circle with processing lanes: who computes whose figures.
  PrimaryLanes? _lanes;
  bool _lanesLoading = false;

  bool get _hasServerMembers => _lanes?.members.any((MemberProcessing m) => m.origin == ProcessingOrigin.server) ?? false;

  bool get _private => PrivateRuntime.primaryPrivate.value && _lanes != null;

  /// People whose phone worked out their figures, with a name for each.
  List<MemberProcessing> get _phoneMembers =>
      _lanes?.members.where((MemberProcessing m) => m.origin == ProcessingOrigin.phone).toList() ?? const <MemberProcessing>[];

  /// What the dashboard shows. Normal circle: the server's report. Private
  /// circle: the server's report for the members whose lane is "server" plus
  /// the figures the phone-only members shared, in one set of totals, events,
  /// day chart and drive list.
  TripReport? get _viewReport {
    if (!_private) return _report;
    final PrimaryLanes l = _lanes!;
    final Set<String> phoneIds = <String>{for (final MemberProcessing m in _phoneMembers) m.userId};
    TripReport? base = _report;
    if (base != null) {
      base = base.withMembers(<MemberReport>[for (final MemberReport m in base.members) if (!phoneIds.contains(m.userId)) m]);
    } else if (!_hasServerMembers) {
      base = emptyReportFor(_period, _anchor, now: _now);
    }
    if (base == null) return null;
    return mergePhoneMembers(base, <PhoneReportMember>[
      for (final MemberProcessing m in _phoneMembers) PhoneReportMember(userId: m.userId, name: l.nameOf(m.userId), processing: m),
    ]);
  }

  Future<void> _loadLanes() async {
    if (!mounted) return;
    setState(() => _lanesLoading = true);
    PrimaryLanes? l;
    try {
      l = await (widget.lanes ?? () => loadPrimaryLanes(circleId: _scope))();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _lanes = l ?? _lanes; // offline: keep the last verified view
      _lanesLoading = false;
    });
    await _load();
  }

  @override
  void dispose() {
    widget.circleId?.removeListener(_reload);
    PrivateRuntime.primaryPrivate.removeListener(_onPrivateChanged);
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
    if (PrivateRuntime.primaryPrivate.value) {
      if (_lanes == null) return; // the lanes decide who the server can speak for
      if (!_hasServerMembers) {
        // Nobody here uses the server: the dashboard is built from the phones' own figures.
        setState(() {
          _report = null;
          _error = null;
          _cachedAt = null;
          _loading = false;
        });
        return;
      }
    }
    final int seq = ++_seq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final Object a = _api;
      final Cached<TripReport> r = a is CachedTripReportApi
          ? await a.reportCached(start: _anchor, period: _period, circleId: _scope)
          : Cached<TripReport>(await _api.report(start: _anchor, period: _period, circleId: _scope));
      if (!mounted || seq != _seq) return;
      setState(() {
        _report = r.value;
        _cachedAt = r.fromCache ? (r.savedAt ?? _now) : null;
        _error = null;
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
      m.userId == widget.userId.value ? selfLabel(m.name) : (m.name.isEmpty ? 'Member' : m.name);

  void _openMember(Member m) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TripsScreen(member: m, api: widget.tripsApi),
      ),
    );
  }

  void _openTrip(RecentTrip t) {
    if (t.onDevice) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(
              '${t.userId == widget.userId.value ? 'This drive was' : '${t.name.isEmpty ? 'This person' : t.name}\'s drive was'} '
              'worked out on their own phone, so the route map stays there.'),
        ));
      return;
    }
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
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: PrivateRuntime.primaryPrivate,
        builder: (BuildContext context, bool isPrivate, _) {
          if (!isPrivate) return _buildScreen(context);
          if (_lanesLoading && _lanes == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
          if (_lanes == null) {
            // Never a dead end: the lanes could not be read just now (offline, keys still loading). Say so and retry.
            return Scaffold(
              appBar: AppBar(title: const Text('Driving report')),
              body: SafeArea(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpace.xl),
                    child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
                      const Icon(Icons.cloud_off_outlined, size: 40),
                      const SizedBox(height: AppSpace.md),
                      Text('Could not load the driving report', key: const Key('driving-lanes-failed'), style: AppType.headline, textAlign: TextAlign.center),
                      const SizedBox(height: AppSpace.sm),
                      Text('Check your connection and try again. Your data is not affected.', style: AppType.secondary, textAlign: TextAlign.center),
                      const SizedBox(height: AppSpace.lg),
                      DsPillButton(label: 'Try again', icon: Icons.refresh, onPressed: _loadLanes),
                    ]),
                  ),
                ),
              ),
            );
          }
          return _buildScreen(context);
        },
      );

  Widget _buildScreen(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ValueListenableBuilder<UnitSystem>(
          valueListenable: UnitPreferenceService.units,
          builder: (BuildContext context, UnitSystem units, _) {
            return Column(children: <Widget>[
              Expanded(child: RefreshIndicator(
              onRefresh: () => PrivateRuntime.primaryPrivate.value ? _loadLanes() : _load(),
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
                      AppSpace.xl,
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
                          Expanded(child: Align(
                            alignment: Alignment.centerLeft,
                            child: ActionChip(
                            key: const ValueKey<String>('weekly-summary-link'),
                            avatar: const Icon(Icons.insights_outlined, size: 18),
                            label: const Text(
                              'Weekly summary',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            side: BorderSide.none,
                            backgroundColor:
                                Theme.of(context).colorScheme.surfaceContainerHighest,
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => WeeklySummaryScreen(
                                    selfId: widget.userId.value),
                              ),
                            ),
                          ),
                          )),
                          IconButton(
                            key: const ValueKey<String>('driving-inbox'),
                            tooltip: 'Inbox',
                            icon: const Icon(Icons.mail_outline_rounded),
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => const InboxScreen(),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppSpace.lg),
                      Semantics(
                        header: true,
                        child: Text(
                          _period == 'month'
                              ? 'Monthly Driving Report'
                              : 'Weekly Driving Report',
                          style: AppType.title.copyWith(
                            fontSize: 30,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -0.6,
                            height: 1.1,
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpace.lg),
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
                        onThis: () => _goTo(_period, _now),
                        onLast: () => _goTo(
                          _period,
                          shiftPeriod(_period, periodStartOf(_period, _now), -1),
                        ),
                        onPick: _pickDate,
                      ),
                      const SizedBox(height: AppSpace.xl),
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
              )),
              if (_viewReport != null && _viewReport!.members.length > 1)
                DrivingMemberDock(
                  members: <Member>[
                    for (final MemberReport m in _viewReport!.members)
                      _memberFor(m.userId, m.name),
                  ],
                  onTap: _openMember,
                ),
            ]);
          },
        ),
      ),
    );
  }

  Widget _phoneCard(MemberProcessing mp, String name, bool mine, UnitSystem units) {
    void openMine() => Navigator.of(context).push<void>(MaterialPageRoute<void>(builder: (_) => const MyProcessingScreen()));
    return PhoneDrivingCard(
      name: name,
      member: mp,
      from: _anchor,
      to: periodEndOf(_period, _anchor),
      units: units,
      now: _now,
      onUseServer: mine ? openMine : null,
      onComputeOnPhone: mine ? openMine : null,
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
    final TripReport? r = _viewReport;
    if (r == null) {
      if (_loading) return const <Widget>[DrivingReportSkeleton()];
      final TripsException e = _error ?? const TripsException(TripsFailure.other, 'Please try again in a moment.');
      return <Widget>[
        const SizedBox(height: AppSpace.xl),
        if (e.kind == TripsFailure.offline)
          DsErrorState(
            icon: Icons.cloud_off_rounded,
            title: 'You are offline',
            message:
                'The driving report needs a connection to the server. '
                'Pull down or try again once you are back online.',
            onRetry: _reload,
          )
        else
          DsErrorState(
            title: 'Could not load the report',
            message: e.message,
            onRetry: _load,
          ),
        // People who keep their data on their phone do not need the server.
        if (_private)
          for (final MemberProcessing mp in _phoneMembers)
            Padding(
              padding: const EdgeInsets.only(top: AppSpace.md),
              child: _phoneCard(mp, mp.userId == widget.userId.value ? 'You' : _lanes!.nameOf(mp.userId), mp.userId == widget.userId.value, units),
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
    final bool priv = _private;
    final bool anyPhoneFigures = priv &&
        _phoneMembers.any((MemberProcessing m) => m.placeholder == null && r.members.any((MemberReport x) => x.userId == m.userId));
    Widget card(MemberReport m) {
      final MemberProcessing? mp = priv ? _lanes!.memberById(m.userId) : null;
      if (mp != null && mp.origin == ProcessingOrigin.phone) {
        return _phoneCard(mp, _nameOf(m), m.userId == me, units);
      }
      final Widget c = MemberDrivingCard(
        report: m,
        member: _memberFor(m.userId, m.name),
        displayName: _nameOf(m),
        units: units,
        onTap: () => _openMember(_memberFor(m.userId, m.name)),
      );
      if (!priv) return c;
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        const Padding(padding: EdgeInsets.only(bottom: AppSpace.xs), child: LaneChip(server: true)),
        c,
      ]);
    }

    // Phone-only members whose phone has not shared anything yet.
    final List<Widget> waiting = <Widget>[
      if (priv)
        for (final MemberProcessing mp in _phoneMembers)
          if (mp.placeholder != null)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.md),
              child: _phoneCard(mp, mp.userId == me ? 'You' : _lanes!.nameOf(mp.userId), mp.userId == me, units),
            ),
    ];

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
      if (_error != null || _cachedAt != null)
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpace.md),
          child: DsOfflineBanner(
            key: const Key('driving-offline-banner'),
            message: _cachedAt != null
                ? 'You are offline. Showing the report saved ${sinceText(_cachedAt!, _now)}.'
                : (_error!.kind == TripsFailure.offline
                    ? 'You are offline. Showing the last report.'
                    : 'Could not refresh. Showing the last report.'),
            onRetry: _reload,
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
        if (waiting.isNotEmpty) ...<Widget>[
          const SizedBox(height: AppSpace.lg),
          ...waiting,
        ],
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
        Semantics(
          header: true,
          child: Text(
            sorted.length == 1 ? 'Driver' : 'Drivers',
            style: AppType.headline,
          ),
        ),
        const SizedBox(height: AppSpace.md),
        for (final MemberReport m in active)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.md),
            child: card(m),
          ),
        ...waiting,
        if (idle.isNotEmpty)
          NoDrivesGroup(
            names: idle.map(_nameOf).toList(),
            children: idle.map(card).toList(),
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
                name: t.userId == me ? selfLabel(t.name) : (t.name.isEmpty ? 'Member' : t.name),
                units: units,
                now: _now,
                onTap: () => _openTrip(t),
              ),
            ),
          const SizedBox(height: AppSpace.sm),
        ],
        if (anyPhoneFigures)
          const Padding(
            padding: EdgeInsets.only(top: AppSpace.md),
            child: ProcessingNote(
              noteKey: Key('driving-private-note'),
              icon: Icons.info_outline,
              text: 'People who keep their data on their phone are counted from the figures their phone shares. '
                  'Place names and route maps for those drives stay on their phone.',
            ),
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
