import 'package:flutter/material.dart';

import '../models/trip_report.dart';
import '../services/processing/driving_report.dart' show EventCountsOut, weeklySafetyScore;
import '../services/processing/processing_source.dart';
import '../services/processing/result_items.dart';
import '../services/speed_units.dart';
import '../theme/app_theme.dart';
import 'processing_widgets.dart';

// Driving figures of a PHONE-ONLY member, built from the sealed `trip` and
// `drive` results their phone shared (PRIVACY_PROCESSING 8.4). The figures use
// the same score function as the server. Not computable on a phone, and said so:
// place names, route maps, the per-day chart and the recent-trip list.

class PhoneDrivingStats {
  const PhoneDrivingStats({
    required this.drives,
    required this.distanceM,
    required this.durationS,
    required this.topSpeedMps,
    required this.speeding,
    required this.hardBrake,
    required this.rapidAccel,
    required this.phoneUse,
    required this.score,
  });
  final int drives;
  final double distanceM, durationS, topSpeedMps;
  final int speeding, hardBrake, rapidAccel;

  /// Null: phone-use detection is off for this member, so no count is claimed.
  final int? phoneUse;
  final int? score;
}

/// Figures for driving trips that started in [from, to); null when the phone shared no trip at all in that period.
PhoneDrivingStats? phoneDrivingStats(MemberProcessing m, DateTime from, DateTime to) {
  final int a = from.millisecondsSinceEpoch, b = to.millisecondsSinceEpoch;
  final List<TripResult> trips = <TripResult>[
    for (final TripResult t in m.trips)
      if (t.mode == 'driving' && t.startMs >= a && t.startMs < b) t
  ];
  if (trips.isEmpty) return null;
  final Set<String> ids = <String>{for (final TripResult t in trips) t.id};
  final EventCountsOut c = EventCountsOut();
  for (final DriveResult d in m.drives) {
    if (!ids.contains(d.tripId)) continue;
    c.speeding += d.speeding;
    c.hardBrake += d.hardBrake;
    c.rapidAccel += d.rapidAccel;
    c.phone += d.phoneUse;
  }
  final double dist = trips.fold(0.0, (double s, TripResult t) => s + t.distanceM);
  final double dur = trips.fold(0.0, (double s, TripResult t) => s + t.durationS);
  final double top = trips.fold(0.0, (double s, TripResult t) => t.maxSpeedMps > s ? t.maxSpeedMps : s);
  // A phone-use count is only claimed if there were events or the phone's weekly figures carry one (detection on).
  final bool detection = m.weeks.any((WeekResult w) => w.current.phoneUse != null);
  return PhoneDrivingStats(
    drives: trips.length,
    distanceM: dist,
    durationS: dur,
    topSpeedMps: top,
    speeding: c.speeding,
    hardBrake: c.hardBrake,
    rapidAccel: c.rapidAccel,
    phoneUse: (detection || c.phone > 0) ? c.phone : null,
    score: weeklySafetyScore(trips.length, dist, c),
  );
}

/// The end of the period of kind [period] ('day' | 'week' | 'month') that starts at [start].
DateTime periodEndOf(String period, DateTime start) =>
    period == 'day' ? DateTime(start.year, start.month, start.day + 1) : shiftPeriod(period, start, 1);

DateTime periodStartForKind(String period, DateTime now) =>
    period == 'day' ? DateTime(now.year, now.month, now.day) : periodStartOf(period, now);

class PhoneDrivingCard extends StatelessWidget {
  const PhoneDrivingCard({super.key, required this.name, required this.member, required this.from, required this.to, required this.units, this.now, this.onUseServer, this.onComputeOnPhone});
  final String name;
  final MemberProcessing member;
  final DateTime from, to;
  final UnitSystem units;
  final DateTime? now;

  /// Set only on the person's own card.
  final VoidCallback? onUseServer, onComputeOnPhone;

  @override
  Widget build(BuildContext context) {
    if (member.placeholder != null) {
      return WaitingForPhoneCard(name: name, onUseServer: onUseServer, onComputeOnPhone: onComputeOnPhone);
    }
    final ColorScheme cs = Theme.of(context).colorScheme;
    final PhoneDrivingStats? s = phoneDrivingStats(member, from, to);
    return Container(
      key: Key('phone-driving-$name'),
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: BoxDecoration(color: BrandTheme.of(context).sheet, borderRadius: BorderRadius.circular(AppRadius.lg)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Row(children: <Widget>[
          Expanded(child: Text(name, style: AppType.headline)),
          const LaneChip(server: false),
          if (s?.score != null) ...<Widget>[
            const SizedBox(width: AppSpace.sm),
            Text('Score ${s!.score}', style: AppType.headline.copyWith(color: BrandTheme.of(context).accentInk)),
          ],
        ]),
        const SizedBox(height: AppSpace.sm),
        if (s == null)
          Text('No drives shared by $name\'s phone in this period.', key: const Key('phone-driving-none'), style: AppType.secondary)
        else ...<Widget>[
          Text('${units.formatDistance(s.distanceM)}, ${s.drives} ${s.drives == 1 ? 'drive' : 'drives'}', style: AppType.body),
          Text('Time driven ${formatTripDuration(Duration(seconds: s.durationS.round()))}',
              style: AppType.secondary.copyWith(color: cs.onSurfaceVariant)),
          Text('Top speed ${units.formatSpeed(s.topSpeedMps)}', style: AppType.secondary.copyWith(color: cs.onSurfaceVariant)),
          const SizedBox(height: AppSpace.sm),
          Wrap(spacing: AppSpace.sm, runSpacing: AppSpace.xs, children: <Widget>[
            _chip(context, 'Hard braking ${s.hardBrake}'),
            _chip(context, 'Rapid acceleration ${s.rapidAccel}'),
            _chip(context, 'Speeding ${s.speeding}'),
            if (s.phoneUse != null) _chip(context, 'Phone use ${s.phoneUse}'),
          ]),
        ],
        const SizedBox(height: AppSpace.sm),
        ComputedOnPhoneNote(name: name, updatedAt: member.updatedAt, now: now),
        Text(
          'Place names, route maps and the daily chart need the server.',
          key: const Key('phone-driving-limits'),
          style: AppType.secondary.copyWith(color: cs.onSurfaceVariant),
        ),
      ]),
    );
  }

  Widget _chip(BuildContext context, String t) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
            border: Border.all(color: Theme.of(context).colorScheme.outlineVariant), borderRadius: BorderRadius.circular(AppRadius.md)),
        child: Text(t, style: AppType.secondary),
      );
}
