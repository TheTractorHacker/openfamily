import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../models/member.dart';
import '../models/trip.dart';
import '../screens/daily_history_screen.dart';
import '../screens/member_profile_screen.dart';
import '../screens/place_alert_rules_screen.dart';
import '../screens/trip_detail_screen.dart';
import '../screens/trips_screen.dart';
import '../screens/weekly_summary_screen.dart';
import '../services/api_client.dart';
import '../services/history_service.dart';
import '../services/location_refresh_service.dart';
import '../services/delivery_status.dart';
import '../services/member_day_service.dart';
import '../services/person_launcher.dart';
import '../services/place_alert_rules_service.dart';
import '../services/speed_units.dart';
import '../services/weekly_summary_service.dart';
import '../theme/app_theme.dart';
import '../utils/member_status.dart';
import 'ds/ds.dart';
import 'live_speed.dart';

/// Life360-style "Last updated now" / "1 hr. ago" caption.
String lastUpdatedLabel(DateTime? seen, DateTime now) {
  if (seen == null) return 'No location yet';
  final Duration d = now.difference(seen);
  if (d.inMinutes < 1) return 'Last updated now';
  if (d.inMinutes < 60) return 'Last updated ${d.inMinutes} min ago';
  if (d.inHours < 24) return 'Last updated ${d.inHours} hr. ago';
  return 'Last updated ${d.inDays} d ago';
}

/// "Since Mon, Nov 2": the Monday that starts [now]'s week.
String weekSinceLabel(DateTime now) {
  final DateTime d = DateTime(now.year, now.month, now.day)
      .subtract(Duration(days: now.weekday - DateTime.monday));
  const List<String> days = <String>[
    'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun', //
  ];
  const List<String> months = <String>[
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec', //
  ];
  return 'Since ${days[d.weekday - 1]}, ${months[d.month - 1]} ${d.day}';
}

/// The full person view shown when someone is tapped on the map or in the
/// People list. It is the body of the map's draggable sheet: header, a
/// "location isn't updating" banner, the per-person place-alert switch, this
/// week's driving, today's places and trips, and a docked row of actions.
class PersonPanel extends StatefulWidget {
  const PersonPanel({
    super.key,
    required this.member,
    required this.controller,
    required this.onClose,
    this.selfId,
    this.myPosition,
    this.handle = true,
    this.topInset = 0,
    this.onMessage,
    this.alerts,
    this.weekly,
    this.dayLoader,
    this.requestUpdate,
    this.launcher,
    this.now,
  });

  final Member member;
  final ScrollController controller;
  final VoidCallback onClose;

  /// The signed-in user; their own panel hides the person-to-person actions.
  final String? selfId;

  /// Where the signed-in user is, for the distance pill.
  final LatLng? myPosition;
  final bool handle;
  final double topInset;

  /// Opens a conversation with the member; the Message pill is hidden when
  /// this is null and the member has no phone number.
  final VoidCallback? onMessage;

  final MemberPlaceAlertsApi? alerts;
  final WeeklySummaryApi? weekly;
  final MemberDayLoader? dayLoader;
  final Future<void> Function(String memberId)? requestUpdate;
  final UriLauncher? launcher;
  final DateTime? now;

  @override
  State<PersonPanel> createState() => _PersonPanelState();
}

class _PersonPanelState extends State<PersonPanel> {
  bool? _alertsOn;
  bool _alertsBusy = false;

  WeeklyMember? _week;
  bool _weekFailed = false;

  MemberDay? _day;
  Object? _dayError;
  bool _dayLoading = true;
  bool _requesting = false;

  bool get _isSelf => widget.selfId != null && widget.selfId == widget.member.id;
  DateTime get _now => widget.now ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    UnitPreferenceService.ensureLoaded();
    _loadAll();
  }

  @override
  void didUpdateWidget(PersonPanel old) {
    super.didUpdateWidget(old);
    if (old.member.id != widget.member.id) {
      _alertsOn = null;
      _week = null;
      _weekFailed = false;
      _day = null;
      _loadAll();
    }
  }

  void _loadAll() {
    _loadDay();
    _loadWeek();
    _loadAlerts();
  }

  String get _id => widget.member.id;

  Future<void> _loadAlerts() async {
    if (_isSelf) return;
    final String id = _id;
    try {
      final bool v =
          await (widget.alerts ?? ApiMemberPlaceAlerts.instance).enabled(id);
      if (mounted && id == _id) setState(() => _alertsOn = v);
    } catch (_) {
      // Leave the switch unknown (disabled) rather than guessing.
    }
  }

  Future<void> _setAlerts(bool v) async {
    final bool? before = _alertsOn;
    setState(() {
      _alertsOn = v;
      _alertsBusy = true;
    });
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await (widget.alerts ?? ApiMemberPlaceAlerts.instance)
          .setEnabled(_id, v);
    } catch (_) {
      if (mounted) setState(() => _alertsOn = before);
      messenger.showSnackBar(
          const SnackBar(content: Text('Could not save that. Try again.')));
    }
    if (mounted) setState(() => _alertsBusy = false);
  }

  Future<void> _loadWeek() async {
    final String id = _id;
    try {
      final WeeklySummary s =
          await (widget.weekly ?? WeeklySummaryService.instance).load();
      WeeklyMember? mine;
      for (final WeeklyMember m in s.members) {
        if (m.userId == id) mine = m;
      }
      if (mounted && id == _id) {
        setState(() {
          _week = mine;
          _weekFailed = false;
        });
      }
    } catch (_) {
      if (mounted && id == _id) setState(() => _weekFailed = true);
    }
  }

  Future<void> _loadDay() async {
    final String id = _id;
    setState(() {
      _dayLoading = true;
      _dayError = null;
    });
    try {
      final MemberDay d = widget.dayLoader != null
          ? await widget.dayLoader!(widget.member, _now)
          : await loadMemberDay(widget.member, _now);
      if (!mounted || id != _id) return;
      setState(() {
        _day = d;
        _dayLoading = false;
      });
    } catch (e) {
      if (!mounted || id != _id) return;
      setState(() {
        _dayError = e;
        _dayLoading = false;
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
        await widget.requestUpdate!(_id);
      } else {
        final Map<String, dynamic> r = await LocationRefreshService.request(_id);
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

  Future<void> _launch(Uri uri, String failure) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool ok = await (widget.launcher ?? launchPersonUri)(uri);
    if (!ok) messenger.showSnackBar(SnackBar(content: Text(failure)));
  }

  /// Whole meters between the signed-in user and the member, or null.
  double? get _distanceM {
    final LatLng? a = widget.myPosition;
    final LatLng? b = widget.member.position;
    if (a == null || b == null || _isSelf) return null;
    return const Distance()(a, b);
  }

  @override
  Widget build(BuildContext context) {
    final Member m = widget.member;
    final BrandTheme brand = BrandTheme.of(context);
    final bool stale = m.status == MemberStatus.stopped && m.position != null;
    final List<Widget> actions = _actions(context);
    return Stack(
      children: <Widget>[
        CustomScrollView(
          controller: widget.controller,
          slivers: <Widget>[
            SliverToBoxAdapter(
              child: Column(
                children: <Widget>[
                  if (widget.handle)
                    const DsDragHandle()
                  else
                    SizedBox(height: widget.topInset),
                  _header(context),
                ],
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
              sliver: SliverList(
                delegate: SliverChildListDelegate(<Widget>[
                  if (stale)
                    _StaleBanner(
                        name: m.name,
                        busy: _requesting,
                        onAsk: _requestUpdate),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                        AppSpace.xs, AppSpace.sm, 0, AppSpace.md),
                    child: Semantics(
                      header: true,
                      child: Text(m.displayName,
                          key: const Key('person_name'),
                          style: AppType.title
                              .copyWith(fontSize: 28, fontWeight: FontWeight.w800)),
                    ),
                  ),
                  _statusLine(context),
                  if (!_isSelf) ...<Widget>[
                    const SizedBox(height: AppSpace.md),
                    _alertsCard(context),
                  ],
                  const SizedBox(height: AppSpace.md),
                  _driveCard(context),
                  const SizedBox(height: AppSpace.md),
                  _todayCard(context),
                  SizedBox(
                    height: 96 + MediaQuery.paddingOf(context).bottom,
                  ),
                ]),
              ),
            ),
          ],
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[brand.sheet.withValues(alpha: 0), brand.sheet],
              ),
            ),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                AppSpace.lg,
                AppSpace.lg,
                AppSpace.lg,
                AppSpace.md + MediaQuery.paddingOf(context).bottom,
              ),
              child: SingleChildScrollView(
                key: const Key('person_actions'),
                scrollDirection: Axis.horizontal,
                clipBehavior: Clip.none,
                child: Row(
                  children: <Widget>[
                    for (final Widget a in actions)
                      Padding(
                        padding: const EdgeInsets.only(right: AppSpace.sm),
                        child: a,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _actions(BuildContext context) {
    final Member m = widget.member;
    final double? dist = _distanceM;
    final String? phone = m.phone;
    return <Widget>[
      if (dist != null)
        ValueListenableBuilder<UnitSystem>(
          valueListenable: UnitPreferenceService.units,
          builder: (BuildContext _, UnitSystem u, __) => DsPillButton(
            label: u.formatDistance(dist),
            icon: Icons.directions_outlined,
            style: DsPillStyle.tonal,
            floating: true,
            semanticLabel: '${m.name} is ${u.formatDistance(dist)} from you. '
                'Get directions',
            onPressed: m.position == null ? null : _directions,
          ),
        )
      else if (!_isSelf && m.position != null)
        DsPillButton(
          label: 'Directions',
          icon: Icons.directions_outlined,
          style: DsPillStyle.tonal,
          floating: true,
          onPressed: _directions,
        ),
      if (!_isSelf && phone != null)
        DsPillButton(
          label: 'Call',
          icon: Icons.call_outlined,
          style: DsPillStyle.tonal,
          floating: true,
          semanticLabel: 'Call ${m.name}',
          onPressed: () =>
              _launch(Uri(scheme: 'tel', path: phone), 'Could not open the dialer.'),
        ),
      if (!_isSelf && (widget.onMessage != null || phone != null))
        DsPillButton(
          label: 'Message',
          icon: Icons.chat_bubble_outline,
          style: DsPillStyle.tonal,
          floating: true,
          semanticLabel: 'Message ${m.name}',
          onPressed: widget.onMessage ??
              () => _launch(
                  Uri(scheme: 'sms', path: phone), 'Could not open messages.'),
        ),
      if (!_isSelf)
        DsPillButton(
          label: _requesting ? 'Requesting…' : 'Check in',
          icon: Icons.my_location,
          style: DsPillStyle.tonal,
          floating: true,
          semanticLabel: 'Request a fresh location from ${m.name}',
          onPressed: _requesting ? null : _requestUpdate,
        ),
      DsPillButton(
        label: 'History',
        icon: Icons.history,
        style: DsPillStyle.tonal,
        floating: true,
        onPressed: () => openDailyHistory(context, m),
      ),
    ];
  }

  void _directions() {
    final LatLng? p = widget.member.position;
    if (p == null) return;
    _launch(
      Uri.parse('geo:${p.latitude},${p.longitude}'
          '?q=${p.latitude},${p.longitude}(${Uri.encodeComponent(widget.member.name)})'),
      'No maps app found.',
    );
  }

  Widget _header(BuildContext context) {
    final Member m = widget.member;
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpace.xs, 0, AppSpace.xs, 0),
      child: Row(
        children: <Widget>[
          IconButton(
            key: const Key('person_close'),
            tooltip: 'Back to the family list',
            onPressed: widget.onClose,
            constraints:
                const BoxConstraints(minWidth: kMinTarget, minHeight: kMinTarget),
            icon: const Icon(Icons.arrow_back),
          ),
          Expanded(
            child: Text(
              m.position == null && m.lastSeen == null
                  ? (DeliveryHints.hintFor(m.id) ?? lastUpdatedLabel(null, _now))
                  : lastUpdatedLabel(m.lastSeen?.toLocal(), _now),
              key: const Key('person_last_updated'),
              style: AppType.secondary.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
          if (!_isSelf)
            IconButton(
              tooltip: 'Ask ${m.name} to update their location',
              onPressed: _requesting ? null : _requestUpdate,
              constraints: const BoxConstraints(
                  minWidth: kMinTarget, minHeight: kMinTarget),
              icon: const Icon(Icons.sync),
            ),
          PopupMenuButton<String>(
            key: const Key('person_more'),
            tooltip: 'More about ${m.name}',
            onSelected: (String v) {
              switch (v) {
                case 'trips':
                  _push(TripsScreen(member: m));
                case 'profile':
                  _push(MemberProfileScreen(member: m, selfUserId: widget.selfId));
              }
            },
            itemBuilder: (BuildContext _) => const <PopupMenuEntry<String>>[
              PopupMenuItem<String>(value: 'trips', child: Text('Trips')),
              PopupMenuItem<String>(
                  value: 'profile', child: Text('Profile and settings')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statusLine(BuildContext context) {
    final Member m = widget.member;
    final ColorScheme cs = Theme.of(context).colorScheme;
    Widget line(double? mps, UnitSystem units) => Padding(
          padding: const EdgeInsets.only(left: AppSpace.xs),
          child: Text(
            memberStatusLine(m, speedMps: mps, units: units),
            key: const Key('person_status_line'),
            style: AppType.body.copyWith(color: cs.onSurfaceVariant),
          ),
        );
    if (m.movement != MovementType.car) {
      return line(null, UnitPreferenceService.units.value);
    }
    return LiveSpeedBuilder(
      member: m,
      builder: (BuildContext _, double? mps, UnitSystem u) => line(mps, u),
    );
  }

  // ---- place alerts switch ------------------------------------------------

  Widget _alertsCard(BuildContext context) {
    final Member m = widget.member;
    final ColorScheme cs = Theme.of(context).colorScheme;
    final BrandTheme brand = BrandTheme.of(context);
    return _Card(
      child: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(AppSpace.lg),
            child: Row(
              children: <Widget>[
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: brand.accent.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  child: Icon(Icons.notifications_none, color: brand.accentInk),
                ),
                const SizedBox(width: AppSpace.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text('Get Place Alerts',
                          style: AppType.headline
                              .copyWith(fontWeight: FontWeight.w800)),
                      Text('if ${m.name} leaves or arrives',
                          style: AppType.secondary
                              .copyWith(color: cs.onSurfaceVariant)),
                    ],
                  ),
                ),
                Switch(
                  key: const Key('person_place_alerts_switch'),
                  value: _alertsOn ?? true,
                  onChanged: (_alertsOn == null || _alertsBusy) ? null : _setAlerts,
                ),
              ],
            ),
          ),
          if (_alertsOn == true)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(
                    left: AppSpace.sm, bottom: AppSpace.xs),
                child: TextButton(
                  key: const Key('person_customize_places'),
                  onPressed: () => _push(PlaceAlertRulesScreen(
                      memberId: m.id, memberName: m.name)),
                  child: const Text('Customize by place'),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ---- weekly drives ------------------------------------------------------

  Widget _driveCard(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final WeeklyMember? w = _week;
    final bool tracked = w != null;
    Widget row(String key, String label, IconData icon, Color color,
            int? cur, int? prev) =>
        _MetricRow(
          key: Key('person_metric_$key'),
          label: label,
          icon: icon,
          color: color,
          current: cur,
          previous: prev,
        );
    return _Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.assignment_outlined, size: 40, color: cs.primary),
                const SizedBox(width: AppSpace.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text('Check out this week’s drives',
                          style: AppType.headline
                              .copyWith(fontWeight: FontWeight.w800)),
                      const SizedBox(height: AppSpace.xxs),
                      Text(weekSinceLabel(_now),
                          style: AppType.secondary
                              .copyWith(color: cs.onSurfaceVariant)),
                    ],
                  ),
                ),
              ],
            ),
            if (tracked && w.current.drives > 0)
              ValueListenableBuilder<UnitSystem>(
                valueListenable: UnitPreferenceService.units,
                builder: (BuildContext _, UnitSystem u, __) => Padding(
                  padding: const EdgeInsets.only(top: AppSpace.sm),
                  child: Text(
                    '${w.current.drives} ${w.current.drives == 1 ? 'drive' : 'drives'}'
                    ' · ${u.formatDistance(w.current.distanceM)}',
                    key: const Key('person_week_totals'),
                    style: AppType.secondary.copyWith(color: cs.onSurfaceVariant),
                  ),
                ),
              ),
            const SizedBox(height: AppSpace.md),
            row('speeding', 'Speeding', Icons.speed, const Color(0xFFF7776B),
                w?.current.speeding, w?.previous.speeding),
            row('distracted', 'Distracted', Icons.phone_android,
                const Color(0xFF6FD3F2), w?.current.phoneUse, w?.previous.phoneUse),
            row('accel', 'Rapid Accel', Icons.bolt, const Color(0xFFF08BE8),
                w?.current.rapidAccel, w?.previous.rapidAccel),
            row('braking', 'Hard Braking', Icons.front_hand_outlined,
                const Color(0xFFF5D547), w?.current.hardBrake, w?.previous.hardBrake),
            if (_weekFailed)
              Padding(
                padding: const EdgeInsets.only(top: AppSpace.sm),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text('Couldn’t load this week’s drives.',
                          style: AppType.secondary
                              .copyWith(color: cs.onSurfaceVariant)),
                    ),
                    TextButton(onPressed: _loadWeek, child: const Text('Retry')),
                  ],
                ),
              ),
            const SizedBox(height: AppSpace.sm),
            InkWell(
              key: const Key('person_open_weekly'),
              borderRadius: BorderRadius.circular(AppRadius.md),
              onTap: () => _push(WeeklySummaryScreen(
                  api: widget.weekly, selfId: widget.selfId)),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: kMinTarget),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text('Weekly drive report',
                          style: AppType.body.copyWith(
                              color: BrandTheme.of(context).accentInk,
                              fontWeight: FontWeight.w600)),
                    ),
                    const Icon(Icons.chevron_right),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---- today --------------------------------------------------------------

  Widget _todayCard(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Member m = widget.member;
    Widget body;
    if (_dayLoading) {
      body = const Padding(
        padding: EdgeInsets.all(AppSpace.lg),
        child: Center(child: CircularProgressIndicator()),
      );
    } else if (_dayError != null) {
      body = Row(
        children: <Widget>[
          Expanded(
            child: Text('Couldn’t load today.',
                style: AppType.body.copyWith(color: cs.onSurfaceVariant)),
          ),
          TextButton(onPressed: _loadDay, child: const Text('Retry')),
        ],
      );
    } else {
      final List<DayTrip> trips = _day?.trips ?? const <DayTrip>[];
      final List<HistoryVisit> places = _day?.places ?? const <HistoryVisit>[];
      if (trips.isEmpty && places.isEmpty) {
        body = Text('No places or trips yet today.',
            key: const Key('person_today_empty'),
            style: AppType.body.copyWith(color: cs.onSurfaceVariant));
      } else {
        body = ValueListenableBuilder<UnitSystem>(
          valueListenable: UnitPreferenceService.units,
          builder: (BuildContext _, UnitSystem u, __) => Column(
            children: <Widget>[
              for (final HistoryVisit v in places)
                _TodayRow(
                  icon: Icons.place_outlined,
                  title: v.placeName,
                  detail: _visitSpan(v),
                  onTap: () => openDailyHistory(context, m),
                ),
              for (final DayTrip d in trips)
                _TodayRow(
                  icon: d.trip.mode == TripMode.driving
                      ? Icons.directions_car_outlined
                      : Icons.directions_walk,
                  title: '${d.fromName ?? 'Start'} to ${d.toName ?? 'End'}',
                  detail: '${formatClock(d.trip.startedAt.toLocal())}'
                      ' · ${u.formatDistance(d.trip.distanceM)}'
                      ' · ${formatTripDuration(d.trip.duration)}',
                  onTap: () => _push(TripDetailScreen(trip: d.trip)),
                ),
            ],
          ),
        );
      }
    }
    return _Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            InkWell(
              key: const Key('person_today_header'),
              borderRadius: BorderRadius.circular(AppRadius.md),
              onTap: () => openDailyHistory(context, m),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: kMinTarget),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text('Today',
                          style: AppType.headline
                              .copyWith(fontWeight: FontWeight.w800)),
                    ),
                    Text('Daily history',
                        style: AppType.secondary.copyWith(
                            color: BrandTheme.of(context).accentInk)),
                    const Icon(Icons.chevron_right),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpace.xs),
            body,
          ],
        ),
      ),
    );
  }

  String _visitSpan(HistoryVisit v) {
    final String a = formatClock(v.arrivedAt.toLocal());
    final bool open = v.departedAt.isAfter(_now.subtract(const Duration(minutes: 5)));
    return open ? 'Since $a' : '$a - ${formatClock(v.departedAt.toLocal())}';
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        boxShadow: const <BoxShadow>[
          BoxShadow(
              color: Color(0x14000000), blurRadius: 12, offset: Offset(0, 3)),
        ],
      ),
      child: child,
    );
  }
}

class _StaleBanner extends StatelessWidget {
  const _StaleBanner({required this.name, required this.onAsk, this.busy = false});

  final String name;
  final bool busy;
  final VoidCallback onAsk;

  @override
  Widget build(BuildContext context) {
    const Color ink = Color(0xFF6B1A0B);
    return Semantics(
      container: true,
      child: Container(
        key: const Key('person_stale_banner'),
        constraints: const BoxConstraints(minHeight: kMinTarget),
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.lg, vertical: AppSpace.md),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF6DD),
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: const Color(0xFFE8D5B8), width: 1.5),
        ),
        child: Row(
          children: <Widget>[
            const Icon(Icons.location_off_outlined, color: ink),
            const SizedBox(width: AppSpace.md),
            Expanded(
              child: Text(
                '$name’s location isn’t updating',
                style: AppType.body
                    .copyWith(color: ink, fontWeight: FontWeight.w700),
              ),
            ),
            TextButton(
              key: const Key('person_stale_ask'),
              onPressed: busy ? null : onAsk,
              style: TextButton.styleFrom(foregroundColor: ink),
              child: Text(busy ? 'Asking…' : 'Ask to update'),
            ),
          ],
        ),
      ),
    );
  }
}

class _MetricRow extends StatelessWidget {
  const _MetricRow({
    super.key,
    required this.label,
    required this.icon,
    required this.color,
    required this.current,
    required this.previous,
  });

  final String label;
  final IconData icon;
  final Color color;

  /// Null when the metric is not tracked (e.g. phone use not opted in).
  final int? current;
  final int? previous;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final int? c = current;
    final int p = previous ?? 0;
    // More risky events than last week is worse (red up); fewer is better.
    final IconData arrow;
    final Color arrowColor;
    final String trend;
    if (c == null || c == p) {
      arrow = Icons.arrow_right_alt;
      arrowColor = cs.onSurface;
      trend = 'same as last week';
    } else if (c > p) {
      arrow = Icons.trending_up;
      arrowColor = AppColors.statusRed;
      trend = 'up from last week';
    } else {
      arrow = Icons.trending_down;
      arrowColor = AppColors.statusGreen;
      trend = 'down from last week';
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpace.sm),
      child: Semantics(
        label: '$label ${c ?? 'not tracked'}, $trend',
        excludeSemantics: true,
        child: Container(
          constraints: const BoxConstraints(minHeight: 52),
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.sm, vertical: AppSpace.xs),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(color: cs.outlineVariant),
          ),
          child: Row(
            children: <Widget>[
              CircleAvatar(
                radius: 16,
                backgroundColor: color,
                child: Icon(icon, size: 18, color: Colors.black87),
              ),
              const SizedBox(width: AppSpace.md),
              Expanded(child: Text(label, style: AppType.body)),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpace.md, vertical: AppSpace.xs),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(c?.toString() ?? '–',
                        key: const Key('metric_count'),
                        style: AppType.body
                            .copyWith(fontWeight: FontWeight.w800)),
                    const SizedBox(width: AppSpace.sm),
                    Icon(arrow, color: arrowColor),
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

class _TodayRow extends StatelessWidget {
  const _TodayRow({
    required this.icon,
    required this.title,
    required this.detail,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String detail;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: kMinTarget),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
          child: Row(
            children: <Widget>[
              Icon(icon, color: cs.onSurfaceVariant),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(title, style: AppType.body),
                    Text(detail,
                        style: AppType.secondary
                            .copyWith(color: cs.onSurfaceVariant)),
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
