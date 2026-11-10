import 'driving_page_widgets.dart' show driveCardDecoration;
import 'package:flutter/material.dart';

import '../models/trip.dart';
import '../services/speed_units.dart';
import '../services/trips_service.dart';
import '../theme/app_theme.dart';
import 'ds/ds.dart';

String tripClock(BuildContext context, DateTime t) =>
    MaterialLocalizations.of(context)
        .formatTimeOfDay(TimeOfDay.fromDateTime(t.toLocal()));

String tripModeLabel(TripMode m) {
  switch (m) {
    case TripMode.driving:
      return 'Driving';
    case TripMode.walking:
      return 'Walking';
    case TripMode.other:
      return 'Other';
  }
}

IconData tripModeIcon(TripMode m) {
  switch (m) {
    case TripMode.driving:
      return Icons.directions_car_filled_rounded;
    case TripMode.walking:
      return Icons.directions_walk_rounded;
    case TripMode.other:
      return Icons.moving_rounded;
  }
}

Color _modeColor(BuildContext context, TripMode m) {
  switch (m) {
    case TripMode.driving:
      return Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF7DD3FC)
          : AppColors.sky;
    case TripMode.walking:
      return BrandTheme.of(context).accentInk;
    case TripMode.other:
      return Theme.of(context).colorScheme.onSurfaceVariant;
  }
}

/// Mode indicator that never relies on color alone: icon plus a text label,
/// and a different outline shape per mode.
class TripModeBadge extends StatelessWidget {
  const TripModeBadge({super.key, required this.mode});

  final TripMode mode;

  @override
  Widget build(BuildContext context) {
    final Color c = _modeColor(context, mode);
    final BorderRadius radius = mode == TripMode.driving
        ? BorderRadius.circular(AppRadius.sm)
        : mode == TripMode.walking
            ? BorderRadius.circular(AppRadius.pill)
            : BorderRadius.circular(AppSpace.xxs);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.sm + AppSpace.xxs,
        vertical: AppSpace.xs,
      ),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        border: Border.all(color: c, width: 1.5),
        borderRadius: radius,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(tripModeIcon(mode), size: 16, color: c),
          const SizedBox(width: AppSpace.xs + AppSpace.xxs),
          Text(
            tripModeLabel(mode),
            style: AppType.secondary.copyWith(
              fontSize: 13,
              color: c,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// A short "label / value" pair used in cards and reports.
class TripStat extends StatelessWidget {
  const TripStat({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      label: '$label: $value',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(value, style: AppType.headline),
          Text(
            label,
            style: AppType.secondary.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

String tripSemanticLabel(BuildContext context, Trip t, UnitSystem u) {
  return '${tripModeLabel(t.mode)} trip, ${tripClock(context, t.startedAt)} to '
      '${tripClock(context, t.endedAt)}, ${u.formatDistance(t.distanceM)}, '
      '${formatTripDuration(t.duration)}, GPS top speed '
      '${u.formatSpeed(t.maxSpeedMps)}, average ${u.formatSpeed(t.avgSpeedMps)}';
}

/// The four figures of a trip, the same on the list card and the detail header. The
/// visible labels are short; a screen reader still hears "Max GPS speed" / "Avg GPS speed".
List<DsStat> tripStats(Trip t, UnitSystem u) {
  final String top = u.formatSpeed(t.maxSpeedMps);
  final String avg = u.formatSpeed(t.avgSpeedMps);
  return <DsStat>[
    DsStat(label: 'Distance', value: u.formatDistance(t.distanceM)),
    DsStat(label: 'Duration', value: formatTripDuration(t.duration)),
    DsStat(label: 'Top speed', value: top, semanticLabel: 'Max GPS speed: $top'),
    DsStat(label: 'Average', value: avg, semanticLabel: 'Avg GPS speed: $avg'),
  ];
}

/// "6:16 PM - 6:53 PM".
String tripTimeRange(BuildContext context, Trip t) =>
    '${tripClock(context, t.startedAt)} - ${tripClock(context, t.endedAt)}';

class TripCard extends StatelessWidget {
  const TripCard({
    super.key,
    required this.trip,
    required this.units,
    required this.onTap,
  });

  final Trip trip;
  final UnitSystem units;

  /// Null for a trip a member's phone shared (no server detail to open).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    // At large text the badge and the time range no longer fit side by side:
    // the time goes on its own line instead of wrapping inside its column.
    final bool stacked = MediaQuery.textScalerOf(context).scale(1) > 1.3;
    final Widget time = Text(
      tripTimeRange(context, trip),
      style: AppType.body.copyWith(color: cs.onSurface),
    );
    final Widget chevron = onTap == null
        ? const SizedBox.shrink()
        : Icon(Icons.chevron_right, color: cs.onSurfaceVariant);
    return Semantics(
      button: onTap != null,
      label: tripSemanticLabel(context, trip, units),
      excludeSemantics: true,
      child: Material(
        color: Colors.transparent,
        child: Ink(
          decoration: driveCardDecoration(context, radius: AppRadius.lg),
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.lg),
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: kMinTarget),
              child: Padding(
                padding: const EdgeInsets.all(AppSpace.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    if (stacked) ...<Widget>[
                      Row(
                        children: <Widget>[
                          TripModeBadge(mode: trip.mode),
                          const Spacer(),
                          chevron,
                        ],
                      ),
                      const SizedBox(height: AppSpace.sm),
                      time,
                    ] else
                      Row(
                        children: <Widget>[
                          TripModeBadge(mode: trip.mode),
                          const SizedBox(width: AppSpace.sm),
                          Expanded(child: time),
                          chevron,
                        ],
                      ),
                    const SizedBox(height: AppSpace.md),
                    DsStatStrip(stats: tripStats(trip, units)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Full-area message for empty / offline / forbidden / error states. Scrolls
/// so pull-to-refresh still works on it.
class TripsMessageView extends StatelessWidget {
  const TripsMessageView({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.onRetry,
    this.header,
  });

  factory TripsMessageView.error(TripsException e, {VoidCallback? onRetry, Widget? header}) {
    switch (e.kind) {
      case TripsFailure.offline:
        return TripsMessageView(
          icon: Icons.cloud_off_rounded,
          title: 'You are offline',
          message: 'Trips need a connection to the server. Pull down or '
              'tap Retry once you are back online.',
          onRetry: onRetry,
          header: header,
        );
      case TripsFailure.forbidden:
        return TripsMessageView(
          header: header,
          icon: Icons.lock_outline_rounded,
          title: 'Trips are not available',
          message: 'You do not have permission to see this member\'s trips.',
        );
      case TripsFailure.notFound:
        return TripsMessageView(
          header: header,
          icon: Icons.search_off_rounded,
          title: 'Not found',
          message: 'This member or trip is no longer available.',
        );
      case TripsFailure.other:
        return TripsMessageView(
          icon: Icons.error_outline_rounded,
          title: 'Could not load trips',
          message: e.message,
          onRetry: onRetry,
          header: header,
        );
    }
  }

  final IconData icon;
  final String title;
  final String? message;
  final VoidCallback? onRetry;

  /// Scrolls above the message, on the page gutter (the chips and the report row of the trips list).
  final Widget? header;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    // The message keeps its wide side margin; the header sits on the 16 dp gutter.
    const double extra = AppSpace.xxxl - AppSpace.lg;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(AppSpace.lg, header == null ? AppSpace.xxxl : AppSpace.sm, AppSpace.lg, AppSpace.xxxl),
      children: <Widget>[
        if (header != null) header!,
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: extra),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const SizedBox(height: AppSpace.xxxl),
              Icon(icon, size: 48, color: cs.onSurfaceVariant),
              const SizedBox(height: AppSpace.lg),
              Semantics(
                header: true,
                child: Text(
                  title,
                  textAlign: TextAlign.center,
                  style: AppType.headline.copyWith(fontSize: 19),
                ),
              ),
              if (message != null) ...<Widget>[
                const SizedBox(height: AppSpace.sm),
                Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: AppType.body.copyWith(
                    fontWeight: FontWeight.w500,
                    height: 1.4,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
              if (onRetry != null) ...<Widget>[
                const SizedBox(height: AppSpace.xl),
                Center(
                  child: DsPillButton(
                    label: 'Retry',
                    icon: Icons.refresh,
                    onPressed: onRetry,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Reminder shown wherever speeds appear.
class GpsSpeedNote extends StatelessWidget {
  const GpsSpeedNote({super.key});

  @override
  Widget build(BuildContext context) {
    return Text(
      'GPS speed is an estimate from phone location fixes, not a measured '
      'vehicle speed.',
      style: AppType.secondary.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}
