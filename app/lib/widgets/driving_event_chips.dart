import 'package:flutter/material.dart';

import '../models/trip_report.dart';
import '../services/speed_units.dart';
import '../theme/app_theme.dart';
import 'driving_page_widgets.dart' show driveCardDecoration;

/// Icon and tint for each event kind (original pairing from Material icons).
IconData eventIcon(DrivingEventKind k) => switch (k) {
  DrivingEventKind.speeding => Icons.speed_rounded,
  DrivingEventKind.hardBrake => Icons.car_crash_outlined,
  DrivingEventKind.rapidAccel => Icons.bolt_rounded,
  DrivingEventKind.phoneUse => Icons.smartphone_rounded,
};

/// One consistent colour per category across the whole Driving area:
/// speeding coral, phone use cyan, rapid acceleration magenta, hard braking
/// amber.
Color eventColor(DrivingEventKind k) => switch (k) {
  DrivingEventKind.speeding => const Color(0xFFFF6B5E),
  DrivingEventKind.hardBrake => const Color(0xFFF7B801),
  DrivingEventKind.rapidAccel => const Color(0xFFE85DE8),
  DrivingEventKind.phoneUse => const Color(0xFF3CC8EE),
};

/// Order the four categories are shown in.
const List<DrivingEventKind> kEventDisplayOrder = <DrivingEventKind>[
  DrivingEventKind.speeding,
  DrivingEventKind.phoneUse,
  DrivingEventKind.rapidAccel,
  DrivingEventKind.hardBrake,
];

/// Dark glyph colour that reads on top of [eventColor].
const Color kEventGlyphInk = Color(0xFF241A33);

/// A solid coloured disc with the category glyph, used by chips, sheets and
/// event rows so every place looks the same.
class EventIconDisc extends StatelessWidget {
  const EventIconDisc({super.key, required this.kind, this.size = 32});

  final DrivingEventKind kind;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: eventColor(kind), shape: BoxShape.circle),
      child: Icon(eventIcon(kind), size: size * 0.58, color: kEventGlyphInk),
    );
  }
}

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
  if (e.kind == DrivingEventKind.phoneUse) return phoneUseDetailText(e, u);
  return '${u.speedFromMps(m).toStringAsFixed(1)} ${u.speedLabel} per second';
}

/// "1 incident" / "3 incidents".
String incidentsText(int n) => n == 1 ? '1 incident' : '$n incidents';

/// The four event chips as one row of rounded cards (colour disc, count,
/// trend arrow, label). Two by two when text is very large so labels are
/// never clipped.
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
    final int cols = big ? 2 : 4;
    const double gap = AppSpace.sm;
    const List<DrivingEventKind> kinds = kEventDisplayOrder;
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
                    Expanded(
                      child: DrivingEventChip(
                        kind: kinds[k],
                        count: report.totals.events.of(kinds[k]),
                        previous: report.previousTotals.events.of(kinds[k]),
                        phrase: phrase,
                        compact: cols == 2,
                        onTap: () => onTap(kinds[k]),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
      ],
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

  /// Icon beside the count (wide tiles) instead of stacked above it.
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
    final Trend trend = trendOf(count, previous);
    final String tText = trendText(trend, previous);
    final String label = count == null
        ? '${kind.label}: off. Tap to learn more.'
        : '${kind.label}: ${incidentsText(count!)} $phrase, $tText. '
            'Tap to learn more.';
    final Color trendColor = trend == Trend.fewer
        ? brand.accentInk
        : trend == Trend.more
        ? (Theme.of(context).brightness == Brightness.dark
              ? Color.lerp(eventColor(kind), Colors.white, 0.35)!
              : Color.lerp(eventColor(kind), Colors.black, 0.4)!)
        : cs.onSurfaceVariant;
    final Widget count0 = count == null
        ? Text(
            'Off',
            style: AppType.secondary.copyWith(
              fontWeight: FontWeight.w700,
              color: cs.onSurfaceVariant,
            ),
          )
        : Row(
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
              const SizedBox(width: 2),
              Icon(trendIcon(trend), size: 16, color: trendColor),
            ],
          );
    final Widget name = FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(
        kind == DrivingEventKind.rapidAccel ? 'Rapid accel' : kind.label,
        maxLines: 1,
        style: AppType.secondary.copyWith(
          color: cs.onSurfaceVariant,
          fontSize: 12,
        ),
      ),
    );
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: Colors.transparent,
        child: Ink(
          decoration: driveCardDecoration(context, radius: 22),
          child: InkWell(
            borderRadius: BorderRadius.circular(22),
            onTap: onTap,
            child: Container(
              constraints: const BoxConstraints(minHeight: kMinTarget),
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpace.xs + 2,
                vertical: AppSpace.md,
              ),
              child: compact
                  ? Row(
                      children: <Widget>[
                        const SizedBox(width: AppSpace.xs),
                        EventIconDisc(kind: kind),
                        const SizedBox(width: AppSpace.sm),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              count0,
                              Align(
                                alignment: Alignment.centerLeft,
                                child: name,
                              ),
                            ],
                          ),
                        ),
                      ],
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        EventIconDisc(kind: kind),
                        const SizedBox(height: AppSpace.sm),
                        count0,
                        const SizedBox(height: AppSpace.xxs),
                        name,
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "14 s of use at up to 45 mph" for a phone-use event (no app or content is
/// ever known). Falls back to what the server sent.
String? phoneUseDetailText(TripEvent e, UnitSystem u) {
  final double? sec = e.magnitude;
  if (sec == null) return null;
  final String use = sec < 90
      ? '${sec.round()} s'
      : '${(sec / 60).toStringAsFixed(1)} min';
  final String what = e.activity == 'call' ? 'phone call' : 'screen use';
  final double? v = e.maxSpeedMps;
  return '$use of $what${v == null ? '' : ' at up to ${u.formatSpeed(v)}'}';
}
