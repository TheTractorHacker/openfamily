import 'package:flutter/material.dart';

import '../services/speed_units.dart';
import '../services/trips_service.dart';
import '../services/weekly_summary_service.dart';
import '../theme/app_theme.dart';
import '../services/e2ee/private_runtime.dart';
import '../services/processing/primary_lanes.dart';
import '../services/processing/processing_source.dart';
import '../services/processing/result_items.dart';
import '../widgets/private_circle_widgets.dart';
import '../widgets/processing_widgets.dart';
import '../widgets/ds/ds.dart';

/// "Weekly summary": this week against last week for each member, with simple
/// bars. Distances and speeds follow the mph / km preference.
class WeeklySummaryScreen extends StatefulWidget {
  const WeeklySummaryScreen({super.key, this.api, this.selfId, this.lanes});

  final WeeklySummaryApi? api;

  /// Injected in tests; defaults to the running app's processing lanes.
  final PrimaryLanesLoader? lanes;

  /// The signed-in user, shown as "You".
  final String? selfId;

  @override
  State<WeeklySummaryScreen> createState() => _WeeklySummaryScreenState();
}

class _WeeklySummaryScreenState extends State<WeeklySummaryScreen> {
  WeeklySummary? _data;
  TripsException? _error;
  bool _loading = true;

  // Private circle with processing lanes: who computes whose figures.
  PrimaryLanes? _lanes;
  bool _lanesLoading = false;

  @override
  void initState() {
    super.initState();
    UnitPreferenceService.ensureLoaded();
    if (PrivateRuntime.primaryPrivate.value) {
      _loadLanes();
    } else {
      _load();
    }
  }

  /// Private circle: phone-only members' figures come from their phones (sealed
  /// result items); only server-assisted members are asked from the server.
  Future<void> _loadLanes() async {
    setState(() => _lanesLoading = true);
    PrimaryLanes? l;
    try {
      l = await (widget.lanes ?? loadPrimaryLanes)();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _lanes = l;
      _lanesLoading = false;
    });
    if (l != null && l.members.any((MemberProcessing m) => m.origin == ProcessingOrigin.server)) await _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final WeeklySummary d =
          await (widget.api ?? WeeklySummaryService.instance).load();
      if (!mounted) return;
      setState(() {
        _data = d;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = mapTripsError(e);
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: PrivateRuntime.primaryPrivate,
        builder: (BuildContext context, bool isPrivate, _) {
          if (!isPrivate) return _buildScreen(context);
          if (_lanesLoading) {
            return Scaffold(
                appBar: AppBar(title: const Text('Weekly summary')), body: const Center(child: CircularProgressIndicator()));
          }
          if (_lanes == null) {
            return Scaffold(
              appBar: AppBar(title: const Text('Weekly summary')),
              body: const SafeArea(child: NotAvailableInPrivate(feature: PrivateFeature.weeklySummary)),
            );
          }
          return _buildPrivate(context, _lanes!);
        },
      );

  /// One card per member, from the right source, never silently dropped.
  Widget _buildPrivate(BuildContext context, PrimaryLanes l) {
    return Scaffold(
      appBar: AppBar(title: const Text('Weekly summary')),
      body: SafeArea(
        child: ValueListenableBuilder<UnitSystem>(
          valueListenable: UnitPreferenceService.units,
          builder: (BuildContext context, UnitSystem units, _) {
            final List<MemberProcessing> ms = <MemberProcessing>[
              ...l.members.where((MemberProcessing m) => m.userId == widget.selfId),
              ...l.members.where((MemberProcessing m) => m.userId != widget.selfId),
            ];
            double maxM = 0;
            final Map<String, WeeklyMember?> figures = <String, WeeklyMember?>{};
            for (final MemberProcessing m in ms) {
              final WeeklyMember? w = _figuresFor(m, l);
              figures[m.userId] = w;
              if (w != null) {
                maxM = [maxM, w.current.distanceM, w.previous.distanceM].reduce((double x, double y) => x > y ? x : y);
              }
            }
            return RefreshIndicator(
              onRefresh: () async {
                await _loadLanes();
              },
              child: ListView(
                key: const Key('weekly-private-list'),
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(AppSpace.gutter),
                children: <Widget>[
                  Text('This week vs last week',
                      style: AppType.secondary.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  const SizedBox(height: AppSpace.md),
                  if (ms.isEmpty)
                    const DsEmptyState(
                        icon: Icons.directions_car_outlined,
                        title: 'No members to show yet',
                        message: 'The circle\'s members appear here once this phone has checked the circle\'s settings.'),
                  for (final MemberProcessing m in ms)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpace.md),
                      child: _privateMember(context, m, l, figures[m.userId], units, maxM),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _privateMember(BuildContext context, MemberProcessing m, PrimaryLanes l, WeeklyMember? w, UnitSystem units, double maxM) {
    final String name = m.userId == widget.selfId ? 'You' : l.nameOf(m.userId);
    if (w == null) {
      if (m.origin == ProcessingOrigin.server) {
        return Container(
          key: Key('weekly-server-missing-${m.userId}'),
          padding: const EdgeInsets.all(AppSpace.lg),
          decoration: BoxDecoration(color: BrandTheme.of(context).sheet, borderRadius: BorderRadius.circular(AppRadius.lg)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Row(children: <Widget>[Expanded(child: Text(name, style: AppType.headline)), const LaneChip(server: true)]),
            const SizedBox(height: AppSpace.sm),
            Text(_error != null ? 'The server could not be reached.' : 'The server has no figures for $name yet.', style: AppType.secondary),
          ]),
        );
      }
      return WaitingForPhoneCard(name: name);
    }
    final bool phone = m.origin == ProcessingOrigin.phone;
    return _MemberCard(
      member: w,
      name: name,
      units: units,
      maxMeters: maxM,
      badge: LaneChip(server: !phone),
      footer: phone ? ComputedOnPhoneNote(name: name, updatedAt: m.updatedAt) : null,
    );
  }

  WeeklyMember? _figuresFor(MemberProcessing m, PrimaryLanes l) {
    if (m.origin == ProcessingOrigin.server) {
      for (final WeeklyMember w in _data?.members ?? const <WeeklyMember>[]) {
        if (w.userId == m.userId) return w;
      }
      return null;
    }
    if (m.weeks.isEmpty) return null;
    final WeekResult w = m.weeks.first;
    return WeeklyMember(userId: m.userId, name: l.nameOf(m.userId), current: _stat(w.current), previous: _stat(w.previous));
  }

  static WeekStat _stat(WeekFigures f) => WeekStat(
        drives: f.drives,
        distanceM: f.distanceM,
        durationS: f.durationS,
        topSpeedMps: f.topSpeedMps,
        hardBrake: f.hardBrake,
        rapidAccel: f.rapidAccel,
        speeding: f.speeding,
        phoneUse: f.phoneUse > 0 ? f.phoneUse : null,
        score: f.score,
      );

  Widget _buildScreen(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Weekly summary'),
      ),
      body: SafeArea(
        child: ValueListenableBuilder<UnitSystem>(
          valueListenable: UnitPreferenceService.units,
          builder: (BuildContext context, UnitSystem units, _) =>
              _body(context, units),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, UnitSystem units) {
    final WeeklySummary? d = _data;
    if (d == null) {
      if (_loading) {
        return const Center(child: CircularProgressIndicator());
      }
      return DsErrorState(
        title: 'Could not load the summary',
        message: _error?.message ?? 'Try again.',
        onRetry: _load,
      );
    }
    final List<WeeklyMember> members = <WeeklyMember>[
      ...d.members.where((WeeklyMember m) => m.userId == widget.selfId),
      ...d.members.where((WeeklyMember m) => m.userId != widget.selfId),
    ];
    final bool any = members.any(
        (WeeklyMember m) => m.current.drives > 0 || m.previous.drives > 0);
    final double maxM = members.fold<double>(
        0,
        (double a, WeeklyMember m) => [a, m.current.distanceM, m.previous.distanceM]
            .reduce((double x, double y) => x > y ? x : y));
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(AppSpace.gutter),
        children: <Widget>[
          Text('This week vs last week',
              style: AppType.secondary.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: AppSpace.md),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.md),
              child: DsOfflineBanner(
                  message: 'Could not refresh. Showing the last summary.',
                  onRetry: _load),
            ),
          if (!any)
            const DsEmptyState(
              icon: Icons.directions_car_outlined,
              title: 'No drives yet',
              message: 'Drives from the last two weeks will show up here.',
            )
          else
            for (final WeeklyMember m in members)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpace.md),
                child: _MemberCard(
                  member: m,
                  name: m.userId == widget.selfId
                      ? 'You'
                      : (m.name.isEmpty ? 'Member' : m.name),
                  units: units,
                  maxMeters: maxM,
                ),
              ),
        ],
      ),
    );
  }
}

class _MemberCard extends StatelessWidget {
  const _MemberCard({
    required this.member,
    required this.name,
    required this.units,
    required this.maxMeters,
    this.badge,
    this.footer,
  });

  final WeeklyMember member;
  final String name;
  final UnitSystem units;
  final double maxMeters;

  /// Private circles: where these figures were computed.
  final Widget? badge;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final BrandTheme brand = BrandTheme.of(context);
    final WeekStat c = member.current;
    final WeekStat p = member.previous;
    return Semantics(
      container: true,
      label: '$name: ${c.drives} drives, ${units.formatDistance(c.distanceM)} '
          'this week, ${p.drives} drives, ${units.formatDistance(p.distanceM)} '
          'last week',
      child: Container(
        padding: const EdgeInsets.all(AppSpace.lg),
        decoration: BoxDecoration(
          color: brand.sheet,
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(child: Text(name, style: AppType.headline)),
                if (badge != null) ...<Widget>[badge!, const SizedBox(width: AppSpace.sm)],
                if (c.score != null)
                  Text('Score ${c.score}',
                      style: AppType.headline.copyWith(color: brand.accentInk)),
              ],
            ),
            const SizedBox(height: AppSpace.md),
            _BarRow(
              label: 'This week',
              value: units.formatDistance(c.distanceM),
              detail: '${c.drives} ${c.drives == 1 ? 'drive' : 'drives'}',
              fraction: maxMeters <= 0 ? 0 : c.distanceM / maxMeters,
              color: brand.accent,
            ),
            const SizedBox(height: AppSpace.sm),
            _BarRow(
              label: 'Last week',
              value: units.formatDistance(p.distanceM),
              detail: '${p.drives} ${p.drives == 1 ? 'drive' : 'drives'}',
              fraction: maxMeters <= 0 ? 0 : p.distanceM / maxMeters,
              color: cs.onSurfaceVariant.withValues(alpha: 0.45),
            ),
            const SizedBox(height: AppSpace.md),
            Text(
              'Time driven ${formatTripDuration(Duration(seconds: c.durationS.round()))}'
              ' (last week ${formatTripDuration(Duration(seconds: p.durationS.round()))})',
              style: AppType.secondary.copyWith(color: cs.onSurfaceVariant),
            ),
            Text(
              'Top speed ${units.formatSpeed(c.topSpeedMps)}'
              ' (last week ${units.formatSpeed(p.topSpeedMps)})',
              style: AppType.secondary.copyWith(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: AppSpace.sm),
            Wrap(
              spacing: AppSpace.sm,
              runSpacing: AppSpace.xs,
              children: <Widget>[
                _EventChip('Hard braking', c.hardBrake, p.hardBrake),
                _EventChip('Rapid acceleration', c.rapidAccel, p.rapidAccel),
                _EventChip('Speeding', c.speeding, p.speeding),
                if (c.phoneUse != null)
                  _EventChip('Phone use', c.phoneUse!, p.phoneUse ?? 0),
              ],
            ),
            if (footer != null) ...<Widget>[const SizedBox(height: AppSpace.sm), footer!],
          ],
        ),
      ),
    );
  }
}

class _BarRow extends StatelessWidget {
  const _BarRow({
    required this.label,
    required this.value,
    required this.detail,
    required this.fraction,
    required this.color,
  });

  final String label;
  final String value;
  final String detail;
  final double fraction;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(child: Text(label, style: AppType.secondary)),
            Flexible(
              child: Text('$value, $detail',
                  textAlign: TextAlign.end, style: AppType.body),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Stack(
            children: <Widget>[
              Container(height: 10, color: cs.onSurface.withValues(alpha: 0.08)),
              FractionallySizedBox(
                widthFactor: fraction.clamp(0.0, 1.0),
                child: Container(
                  key: ValueKey<String>('bar-$label'),
                  height: 10,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _EventChip extends StatelessWidget {
  const _EventChip(this.label, this.now, this.before);

  final String label;
  final int now;
  final int before;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        border: Border.all(color: cs.outlineVariant),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Text('$label $now (was $before)', style: AppType.secondary),
    );
  }
}
