import 'package:flutter/material.dart';

import '../models/trip_report.dart';
import '../services/speed_units.dart';
import '../theme/app_theme.dart';

/// Icon and tint for each event kind (original pairing from Material icons).
IconData eventIcon(DrivingEventKind k) => switch (k) {
  DrivingEventKind.speeding => Icons.speed_rounded,
  DrivingEventKind.hardBrake => Icons.car_crash_outlined,
  DrivingEventKind.rapidAccel => Icons.bolt_rounded,
  DrivingEventKind.phoneUse => Icons.smartphone_rounded,
};

Color eventColor(DrivingEventKind k) => switch (k) {
  DrivingEventKind.speeding => AppColors.statusOrange,
  DrivingEventKind.hardBrake => AppColors.statusRed,
  DrivingEventKind.rapidAccel => AppColors.sky,
  DrivingEventKind.phoneUse => AppColors.statusGrey,
};

IconData trendIcon(Trend t) => switch (t) {
  Trend.fewer => Icons.trending_down_rounded,
  Trend.more => Icons.trending_up_rounded,
  Trend.same => Icons.trending_flat_rounded,
  Trend.unknown => Icons.remove_rounded,
};

/// "Peak 78 mph" / "Peak 8.1 mph per second" for a trip event, or null.
String? eventMagnitudeText(TripEvent e, UnitSystem u) {
  final double? m = e.magnitude;
  if (m == null) return null;
  if (e.kind == DrivingEventKind.speeding) return 'Peak ${u.formatSpeed(m)}';
  return '${u.speedFromMps(m).toStringAsFixed(1)} ${u.speedLabel} per second';
}

/// "1 incident" / "3 incidents".
String incidentsText(int n) => n == 1 ? '1 incident' : '$n incidents';

/// The row of four event chips. Four across at normal text, two by two when
/// text is large or the screen is narrow so labels are never clipped.
class DrivingEventChips extends StatelessWidget {
  const DrivingEventChips({
    super.key,
    required this.report,
    required this.phrase,
    required this.onTap,
  });

  final TripReport report;

  /// "this week" / "last week" for the semantics sentence.
  final String phrase;
  final ValueChanged<DrivingEventKind> onTap;

  @override
  Widget build(BuildContext context) {
    final bool big = MediaQuery.textScalerOf(context).scale(16) > 16 * 1.15;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        // Labels like "Rapid acceleration" need room: 2x2 on phones.
        final int cols = (!big && c.maxWidth >= 520) ? 4 : 2;
        const double gap = AppSpace.sm;
        final double w = (c.maxWidth - gap * (cols - 1)) / cols;
        final List<DrivingEventKind> kinds = DrivingEventKind.values;
        return Column(
          children: <Widget>[
            for (int r = 0; r < kinds.length; r += cols)
              Padding(
                padding: EdgeInsets.only(top: r == 0 ? 0 : gap),
                child: IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      for (int k = r; k < r + cols; k++) ...<Widget>[
                        if (k > r) const SizedBox(width: gap),
                        SizedBox(
                          width: w,
                          child: k < kinds.length
                              ? DrivingEventChip(
                                  kind: kinds[k],
                                  count: report.totals.events.of(kinds[k]),
                                  previous:
                                      report.previousTotals.events.of(kinds[k]),
                                  phrase: phrase,
                                  compact: cols == 2,
                                  onTap: () => onTap(kinds[k]),
                                )
                              : null,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class DrivingEventChip extends StatelessWidget {
  const DrivingEventChip({
    super.key,
    required this.kind,
    required this.count,
    required this.previous,
    required this.phrase,
    required this.onTap,
    this.compact = false,
  });

  /// Icon beside the text (short, wide tiles) instead of stacked above it.
  /// Used in the two-column phone layout so all four tiles stay compact and
  /// the chart below stays on screen.
  final bool compact;

  final DrivingEventKind kind;

  /// Null = tracking is off (never shown as zero).
  final int? count;
  final int? previous;
  final String phrase;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final BrandTheme brand = BrandTheme.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color tint = eventColor(kind);
    final Color ink = dark
        ? Color.lerp(tint, Colors.white, 0.45)!
        : Color.lerp(tint, Colors.black, 0.35)!;
    final Trend trend = trendOf(count, previous);
    final String tText = trendText(trend, previous);
    final String label = count == null
        ? '${kind.label}: off. Tap to learn more.'
        : '${kind.label}: ${incidentsText(count!)} $phrase, $tText. '
            'Tap to learn more.';
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: brand.sheet,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: kMinTarget),
            padding: EdgeInsets.symmetric(
              horizontal: AppSpace.md,
              vertical: compact ? AppSpace.sm : AppSpace.md,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: Border.all(color: cs.outlineVariant),
            ),
            child: compact
                ? _compactBody(context, tint, ink, trend, tText, dark)
                : _stackedBody(context, tint, ink, trend, tText, dark),
          ),
        ),
      ),
    );
  }

  Widget _stackedBody(
    BuildContext context,
    Color tint,
    Color ink,
    Trend trend,
    String tText,
    bool dark,
  ) {
    final BrandTheme brand = BrandTheme.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: tint.withValues(alpha: dark ? 0.28 : 0.16),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(eventIcon(kind), size: 20, color: ink),
                ),
                const SizedBox(height: AppSpace.sm),
                if (count == null)
                  Text(
                    'Off',
                    textAlign: TextAlign.center,
                    style: AppType.secondary.copyWith(
                      fontWeight: FontWeight.w700,
                      color: cs.onSurfaceVariant,
                    ),
                  )
                else
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        '$count',
                        style: AppType.title.copyWith(fontSize: 24, fontFeatures: const <FontFeature>[FontFeature.tabularFigures()]),
                      ),
                      const SizedBox(width: AppSpace.xs),
                      Icon(
                        trendIcon(trend),
                        size: 20,
                        color: trend == Trend.fewer
                            ? (dark ? AppColors.accentBright : brand.accentInk)
                            : trend == Trend.more
                            ? ink
                            : cs.onSurfaceVariant,
                      ),
                    ],
                  ),
                const SizedBox(height: AppSpace.xxs),
                Text(
                  kind.label,
                  textAlign: TextAlign.center,
                  style: AppType.secondary.copyWith(
                    color: cs.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
                if (count != null)
                  Text(
                    tText,
                    textAlign: TextAlign.center,
                    style: AppType.secondary.copyWith(
                      color: cs.onSurfaceVariant,
                      fontSize: 11,
                    ),
                  ),
              ],
            );
  }

  Widget _compactBody(
    BuildContext context,
    Color tint,
    Color ink,
    Trend trend,
    String tText,
    bool dark,
  ) {
    final BrandTheme brand = BrandTheme.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Row(
      children: <Widget>[
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: tint.withValues(alpha: dark ? 0.28 : 0.16),
            shape: BoxShape.circle,
          ),
          child: Icon(eventIcon(kind), size: 20, color: ink),
        ),
        const SizedBox(width: AppSpace.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (count == null)
                Text(
                  'Off',
                  style: AppType.secondary.copyWith(
                    fontWeight: FontWeight.w700,
                    color: cs.onSurfaceVariant,
                  ),
                )
              else
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      '$count',
                      style: AppType.title.copyWith(
                        fontSize: 22,
                        fontFeatures: const <FontFeature>[
                          FontFeature.tabularFigures(),
                        ],
                      ),
                    ),
                    const SizedBox(width: AppSpace.xs),
                    Icon(
                      trendIcon(trend),
                      size: 18,
                      color: trend == Trend.fewer
                          ? (dark ? AppColors.accentBright : brand.accentInk)
                          : trend == Trend.more
                          ? ink
                          : cs.onSurfaceVariant,
                    ),
                  ],
                ),
              Text(
                kind.label,
                style: AppType.secondary.copyWith(
                  color: cs.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
              if (count != null)
                Text(
                  tText,
                  style: AppType.secondary.copyWith(
                    color: cs.onSurfaceVariant,
                    fontSize: 11,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
