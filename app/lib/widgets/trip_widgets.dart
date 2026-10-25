import 'package:flutter/material.dart';

import '../models/trip.dart';
import '../services/speed_units.dart';
import '../services/trips_service.dart';
import '../theme/app_theme.dart';

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
        ? BorderRadius.circular(8)
        : mode == TripMode.walking
            ? BorderRadius.circular(20)
            : BorderRadius.circular(2);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        border: Border.all(color: c, width: 1.5),
        borderRadius: radius,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(tripModeIcon(mode), size: 18, color: c),
          const SizedBox(width: 6),
          Text(
            tripModeLabel(mode),
            style: TextStyle(color: c, fontWeight: FontWeight.w700),
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
          Text(
            value,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
          Text(
            label,
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
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

class TripCard extends StatelessWidget {
  const TripCard({
    super.key,
    required this.trip,
    required this.units,
    required this.onTap,
  });

  final Trip trip;
  final UnitSystem units;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final BrandTheme brand = BrandTheme.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: tripSemanticLabel(context, trip, units),
      excludeSemantics: true,
      child: Material(
        color: brand.sheet,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      TripModeBadge(mode: trip.mode),
                      const Spacer(),
                      Flexible(
                        child: Text(
                          '${tripClock(context, trip.startedAt)} - '
                          '${tripClock(context, trip.endedAt)}',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: cs.onSurface,
                          ),
                        ),
                      ),
                      Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 24,
                    runSpacing: 10,
                    children: <Widget>[
                      TripStat(
                        label: 'Distance',
                        value: units.formatDistance(trip.distanceM),
                      ),
                      TripStat(
                        label: 'Duration',
                        value: formatTripDuration(trip.duration),
                      ),
                      TripStat(
                        label: 'Max GPS speed',
                        value: units.formatSpeed(trip.maxSpeedMps),
                      ),
                      TripStat(
                        label: 'Avg GPS speed',
                        value: units.formatSpeed(trip.avgSpeedMps),
                      ),
                    ],
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

/// Full-area message for empty / offline / forbidden / error states. Scrolls
/// so pull-to-refresh still works on it.
class TripsMessageView extends StatelessWidget {
  const TripsMessageView({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.onRetry,
  });

  factory TripsMessageView.error(TripsException e, {VoidCallback? onRetry}) {
    switch (e.kind) {
      case TripsFailure.offline:
        return TripsMessageView(
          icon: Icons.cloud_off_rounded,
          title: 'You are offline',
          message: 'Trips need a connection to the server. Pull down or '
              'tap Retry once you are back online.',
          onRetry: onRetry,
        );
      case TripsFailure.forbidden:
        return const TripsMessageView(
          icon: Icons.lock_outline_rounded,
          title: 'Trips are not available',
          message: 'You do not have permission to see this member\'s trips.',
        );
      case TripsFailure.notFound:
        return const TripsMessageView(
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
        );
    }
  }

  final IconData icon;
  final String title;
  final String? message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(32),
      children: <Widget>[
        const SizedBox(height: 48),
        Icon(icon, size: 48, color: cs.onSurfaceVariant),
        const SizedBox(height: 16),
        Semantics(
          header: true,
          child: Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
        ),
        if (message != null) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            message!,
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
        ],
        if (onRetry != null) ...<Widget>[
          const SizedBox(height: 20),
          Center(
            child: FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: onRetry,
              child: const Text('Retry'),
            ),
          ),
        ],
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
      style: TextStyle(
        fontSize: 12,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}
