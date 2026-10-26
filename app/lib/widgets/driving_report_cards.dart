import 'package:flutter/material.dart';

import '../models/member.dart';
import '../models/trip_report.dart';
import '../services/speed_units.dart';
import '../theme/app_theme.dart';
import 'ds/ds.dart';
import 'member_avatar_bubble.dart';

BoxDecoration _card(BuildContext context) {
  final ColorScheme cs = Theme.of(context).colorScheme;
  return BoxDecoration(
    color: BrandTheme.of(context).sheet,
    borderRadius: BorderRadius.circular(AppRadius.lg),
    border: Border.all(color: cs.outlineVariant),
  );
}

/// Top speed (with who set it), drives and total distance.
class DrivingSummaryCards extends StatelessWidget {
  const DrivingSummaryCards({
    super.key,
    required this.report,
    required this.units,
    required this.topSpeedMember,
  });

  final TripReport report;
  final UnitSystem units;

  /// The member who set the top speed, or null when unknown.
  final Member? topSpeedMember;

  @override
  Widget build(BuildContext context) {
    final bool big = MediaQuery.textScalerOf(context).scale(16) > 16 * 1.3;
    final Widget top = _TopSpeedCard(
      mps: report.totals.topSpeedMps,
      units: units,
      member: topSpeedMember,
    );
    final Widget stats = _StatsCard(
      drives: report.totals.drives,
      distance: units.formatDistance(report.totals.distanceM),
    );
    if (big) {
      return Column(
        children: <Widget>[top, const SizedBox(height: AppSpace.md), stats],
      );
    }
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Expanded(child: top),
          const SizedBox(width: AppSpace.md),
          Expanded(child: stats),
        ],
      ),
    );
  }
}

class _TopSpeedCard extends StatelessWidget {
  const _TopSpeedCard({
    required this.mps,
    required this.units,
    required this.member,
  });

  final double? mps;
  final UnitSystem units;
  final Member? member;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final String value = mps == null || mps! <= 0 ? '—' : units.formatSpeed(mps!);
    final String who = member == null ? '' : ', set by ${member!.name}';
    return Semantics(
      container: true,
      label: 'Top speed $value, GPS speed$who',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.all(AppSpace.lg),
        decoration: _card(context),
        child: Row(
          children: <Widget>[
            if (member != null) ...<Widget>[
              StatusAvatar(member: member!, size: 44),
              const SizedBox(width: AppSpace.md),
            ] else ...<Widget>[
              Icon(Icons.speed_rounded, size: 32, color: cs.onSurfaceVariant),
              const SizedBox(width: AppSpace.md),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Top speed',
                    style: AppType.secondary.copyWith(color: cs.onSurfaceVariant),
                  ),
                  Text(value, style: AppType.title),
                  Text(
                    'GPS speed',
                    style: AppType.secondary.copyWith(
                      color: cs.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatsCard extends StatelessWidget {
  const _StatsCard({required this.drives, required this.distance});

  final int drives;
  final String distance;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    Widget line(String label, String value) => Semantics(
      container: true,
      label: '$label: $value',
      excludeSemantics: true,
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              label,
              style: AppType.secondary.copyWith(color: cs.onSurfaceVariant),
            ),
          ),
          Text(value, style: AppType.headline),
        ],
      ),
    );
    return Container(
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: _card(context),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          line('Drives', '$drives'),
          const SizedBox(height: AppSpace.md),
          line('Total distance', distance),
        ],
      ),
    );
  }
}

/// One member: avatar, drives and distance, risky-events pill, chevron.
class MemberDrivingCard extends StatelessWidget {
  const MemberDrivingCard({
    super.key,
    required this.report,
    required this.member,
    required this.displayName,
    required this.units,
    required this.onTap,
  });

  final MemberReport report;
  final Member member;
  final String displayName;
  final UnitSystem units;
  final VoidCallback onTap;

  String get _summary => report.drives == 0
      ? 'No drives yet'
      : '${report.drives} ${report.drives == 1 ? 'drive' : 'drives'}'
          ' · ${units.formatDistance(report.distanceM)}';

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final int risky = report.events.risky;
    final String riskText = report.drives == 0
        ? 'No drives yet'
        : risky == 0
        ? 'No risky events'
        : '$risky risky ${risky == 1 ? 'event' : 'events'}';
    final Widget pill = DsStatusChip(
      label: riskText,
      icon: report.drives == 0
          ? Icons.hourglass_empty_rounded
          : risky == 0
          ? Icons.check_circle_outline_rounded
          : Icons.warning_amber_rounded,
      color: report.drives == 0
          ? AppColors.statusGrey
          : risky == 0
          ? AppColors.statusGreen
          : AppColors.statusOrange,
    );
    return Semantics(
      button: true,
      label: '$displayName. $_summary. $riskText. Opens trips and report.',
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: BrandTheme.of(context).sheet,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 72),
            padding: const EdgeInsets.all(AppSpace.lg),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: Border.all(color: cs.outlineVariant),
            ),
            child: Row(
              children: <Widget>[
                StatusAvatar(member: member, size: 52),
                const SizedBox(width: AppSpace.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(displayName, style: AppType.headline),
                      const SizedBox(height: AppSpace.xxs),
                      Text(
                        _summary,
                        style: AppType.secondary.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: AppSpace.sm),
                      pill,
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Placeholder layout shown while the first report loads.
class DrivingReportSkeleton extends StatelessWidget {
  const DrivingReportSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Loading driving report',
      liveRegion: true,
      child: const Column(
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(child: DsSkeleton(height: 96, radius: AppRadius.lg)),
              SizedBox(width: AppSpace.sm),
              Expanded(child: DsSkeleton(height: 96, radius: AppRadius.lg)),
              SizedBox(width: AppSpace.sm),
              Expanded(child: DsSkeleton(height: 96, radius: AppRadius.lg)),
              SizedBox(width: AppSpace.sm),
              Expanded(child: DsSkeleton(height: 96, radius: AppRadius.lg)),
            ],
          ),
          SizedBox(height: AppSpace.md),
          DsSkeleton(height: 84, radius: AppRadius.lg),
          SizedBox(height: AppSpace.lg),
          DsSkeleton(height: 112, radius: AppRadius.lg),
          SizedBox(height: AppSpace.md),
          DsSkeleton(height: 112, radius: AppRadius.lg),
        ],
      ),
    );
  }
}
