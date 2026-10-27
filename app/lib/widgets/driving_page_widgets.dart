import 'package:flutter/material.dart';

import '../models/member.dart';
import '../models/trip_report.dart';
import '../services/speed_units.dart';
import '../theme/app_theme.dart';
import 'driving_event_chips.dart';
import 'ds/ds.dart';
import 'member_avatar_bubble.dart';

BoxDecoration _cardBox(BuildContext context) {
  final ColorScheme cs = Theme.of(context).colorScheme;
  return BoxDecoration(
    color: BrandTheme.of(context).sheet,
    borderRadius: BorderRadius.circular(AppRadius.lg),
    border: Border.all(color: cs.outlineVariant),
  );
}

// ---------------------------------------------------------------------------
// Times and numbers
// ---------------------------------------------------------------------------

const List<String> _weekdays = <String>[
  'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun',
];
const List<String> _mon = <String>[
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// "7:52 am" (or 24-hour when the device uses it).
String clockText(BuildContext context, DateTime t) {
  final String s = MaterialLocalizations.of(context).formatTimeOfDay(
    TimeOfDay.fromDateTime(t),
    alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
  );
  return s.replaceAll(' AM', ' am').replaceAll(' PM', ' pm');
}

/// "Today 7:52 am", "Yesterday 5:10 pm", "Mon Oct 19 5:10 pm".
String driveWhen(BuildContext context, DateTime t, DateTime now) {
  final DateTime day = DateTime(t.year, t.month, t.day);
  final DateTime today = DateTime(now.year, now.month, now.day);
  final int diff = today.difference(day).inDays;
  final String clock = clockText(context, t);
  if (diff == 0) return 'Today $clock';
  if (diff == 1) return 'Yesterday $clock';
  return '${_weekdays[t.weekday - 1]} ${_mon[t.month - 1]} ${t.day} $clock';
}

/// "Mon Oct 19".
String dayText(DateTime d) =>
    '${_weekdays[d.weekday - 1]} ${_mon[d.month - 1]} ${d.day}';

// ---------------------------------------------------------------------------
// Driving now
// ---------------------------------------------------------------------------

/// Members who are driving right now (live speed from the member snapshot).
/// Renders nothing when [driving] is empty.
class DrivingNowStrip extends StatelessWidget {
  const DrivingNowStrip({
    super.key,
    required this.driving,
    required this.selfId,
    required this.units,
    required this.onTap,
  });

  final List<Member> driving;
  final String? selfId;
  final UnitSystem units;
  final ValueChanged<Member> onTap;

  @override
  Widget build(BuildContext context) {
    if (driving.isEmpty) return const SizedBox.shrink();
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const DsSectionHeader('Driving now'),
        for (final Member m in driving)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpace.sm),
            child: _NowRow(
              member: m,
              name: m.id == selfId ? 'You' : m.name,
              units: units,
              cs: cs,
              onTap: () => onTap(m),
            ),
          ),
      ],
    );
  }
}

class _NowRow extends StatelessWidget {
  const _NowRow({
    required this.member,
    required this.name,
    required this.units,
    required this.cs,
    required this.onTap,
  });

  final Member member;
  final String name;
  final UnitSystem units;
  final ColorScheme cs;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final double? mps = member.speedMps;
    final String speed =
        mps == null ? 'Driving' : 'Driving ${units.formatSpeed(mps)}';
    return Semantics(
      button: true,
      label: '$name. $speed${mps == null ? '' : ', GPS speed'}. Opens trips.',
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: BrandTheme.of(context).sheet,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: kMinTarget),
            padding: const EdgeInsets.all(AppSpace.md),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: Border.all(color: cs.outlineVariant),
            ),
            child: Row(
              children: <Widget>[
                StatusAvatar(member: member, size: 44),
                const SizedBox(width: AppSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(name, style: AppType.headline),
                      Text(
                        speed,
                        style: AppType.body.copyWith(
                          color: BrandTheme.of(context).accentInk,
                        ),
                      ),
                      if (mps != null)
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
                Icon(Icons.directions_car_filled_rounded,
                    color: cs.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Period navigation
// ---------------------------------------------------------------------------

/// Week / Month toggle, previous / next arrows, the period label and
/// "Pick a week". [canNext] is false at the current period.
class DrivingPeriodBar extends StatelessWidget {
  const DrivingPeriodBar({
    super.key,
    required this.period,
    required this.title,
    required this.caption,
    required this.canNext,
    required this.onPeriod,
    required this.onPrev,
    required this.onNext,
    required this.onPick,
  });

  final String period;
  final String title;

  /// "This week" / "Last week" / null.
  final String? caption;
  final bool canNext;
  final ValueChanged<String> onPeriod;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final String unit = period == 'month' ? 'month' : 'week';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Wrap(
          spacing: AppSpace.sm,
          runSpacing: AppSpace.sm,
          children: <Widget>[
            DrivingChoiceChip(
              label: 'Week',
              selected: period == 'week',
              onTap: () => onPeriod('week'),
            ),
            DrivingChoiceChip(
              label: 'Month',
              selected: period == 'month',
              onTap: () => onPeriod('month'),
            ),
            DrivingChoiceChip(
              label: period == 'month' ? 'Pick a month' : 'Pick a week',
              icon: Icons.calendar_month_outlined,
              selected: false,
              semanticLabel: 'Pick a $unit from the calendar',
              onTap: onPick,
            ),
          ],
        ),
        const SizedBox(height: AppSpace.sm),
        Row(
          children: <Widget>[
            IconButton(
              tooltip: 'Previous $unit',
              constraints: const BoxConstraints(
                minWidth: kMinTarget,
                minHeight: kMinTarget,
              ),
              onPressed: onPrev,
              icon: const Icon(Icons.chevron_left_rounded),
            ),
            Expanded(
              child: Semantics(
                liveRegion: true,
                label: caption == null ? title : '$caption, $title',
                excludeSemantics: true,
                child: Column(
                  children: <Widget>[
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      style: AppType.headline,
                    ),
                    if (caption != null)
                      Text(
                        caption!,
                        textAlign: TextAlign.center,
                        style: AppType.secondary
                            .copyWith(color: cs.onSurfaceVariant),
                      ),
                  ],
                ),
              ),
            ),
            IconButton(
              tooltip: canNext ? 'Next $unit' : 'Next $unit (this is the latest)',
              constraints: const BoxConstraints(
                minWidth: kMinTarget,
                minHeight: kMinTarget,
              ),
              onPressed: canNext ? onNext : null,
              icon: const Icon(Icons.chevron_right_rounded),
            ),
          ],
        ),
      ],
    );
  }
}

/// Pill chip with a 48dp target.
class DrivingChoiceChip extends StatelessWidget {
  const DrivingChoiceChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.semanticLabel,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final BrandTheme brand = BrandTheme.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Color fg = selected ? brand.onAccent : cs.onSurface;
    return Semantics(
      button: true,
      selected: selected,
      label: semanticLabel ?? label,
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: selected ? brand.accent : brand.sheet,
        shape: StadiumBorder(
          side: selected ? BorderSide.none : BorderSide(color: cs.outlineVariant),
        ),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: kMinTarget),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (icon != null) ...<Widget>[
                    Icon(icon, size: 18, color: fg),
                    const SizedBox(width: AppSpace.sm),
                  ],
                  Flexible(
                    child: Text(
                      label,
                      style: AppType.body.copyWith(
                        fontWeight: FontWeight.w700,
                        color: fg,
                      ),
                    ),
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

// ---------------------------------------------------------------------------
// Daily chart
// ---------------------------------------------------------------------------

/// The smallest "round" axis maximum (1, 2, 5, 10, 20, 50...) at or above
/// [v]; 1 when there is nothing to draw.
double niceAxisMax(double v) {
  if (v <= 0) return 1;
  double scale = 1;
  while (scale * 10 < v) {
    scale *= 10;
  }
  while (scale > 0.1 && scale > v) {
    scale /= 10;
  }
  for (final double m in <double>[1, 2, 5, 10]) {
    if (m * scale >= v - 1e-9) return m * scale;
  }
  return 10 * scale;
}

String _axisNumber(double v) {
  if (v == v.roundToDouble()) return v.round().toString();
  return v.toStringAsFixed(1);
}

/// Distance per day for the period. Bars are drawn to scale against a round
/// axis maximum in the user's unit; today is highlighted; tapping a bar
/// selects that day ([onSelect] with null clears it).
class DrivingDaysChart extends StatelessWidget {
  const DrivingDaysChart({
    super.key,
    required this.days,
    required this.units,
    required this.today,
    required this.selected,
    required this.onSelect,
  });

  final List<ReportDay> days;
  final UnitSystem units;
  final DateTime today;
  final DateTime? selected;
  final ValueChanged<DateTime?> onSelect;

  static const double plotHeight = 120;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final BrandTheme brand = BrandTheme.of(context);
    final List<double> vals = <double>[
      for (final ReportDay d in days) units.distanceFromMeters(d.distanceM),
    ];
    double maxV = 0;
    for (final double v in vals) {
      if (v > maxV) maxV = v;
    }
    final double axis = niceAxisMax(maxV);
    final bool month = days.length > 8;
    final DateTime t0 = DateTime(today.year, today.month, today.day);
    final TextStyle small = AppType.secondary.copyWith(
      color: cs.onSurfaceVariant,
      fontSize: 11,
    );
    final int total = days.fold<int>(0, (int a, ReportDay d) => a + d.drives);

    Widget gridLine(double frac, String label) => Positioned(
      left: 0,
      right: 0,
      bottom: frac * plotHeight,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(label, style: small),
          Container(
            height: 1,
            color: cs.outlineVariant.withValues(alpha: 0.5),
          ),
        ],
      ),
    );

    return Container(
      padding: const EdgeInsets.all(AppSpace.lg),
      decoration: _cardBox(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Semantics(
            header: true,
            child: Text(
              'Distance per day (${units.distanceLabel})',
              style: AppType.headline,
            ),
          ),
          Text(
            total == 0
                ? 'No drives in this period'
                : 'Tap a day to list only its drives',
            style: AppType.secondary.copyWith(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: AppSpace.xl),
          Stack(
            children: <Widget>[
              SizedBox(
                height: plotHeight,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: <Widget>[
                    gridLine(1, '${_axisNumber(axis)} ${units.distanceLabel}'),
                    gridLine(0.5, _axisNumber(axis / 2)),
                    gridLine(0, '0'),
                  ],
                ),
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  for (int i = 0; i < days.length; i++)
                    Expanded(
                      child: _Bar(
                        day: days[i],
                        value: vals[i],
                        frac: (vals[i] / axis).clamp(0.0, 1.0),
                        isToday: days[i].date == t0,
                        isSelected: selected == days[i].date,
                        label: month
                            ? (days[i].date.day % 7 == 1 || days[i].date == t0
                                ? '${days[i].date.day}'
                                : '')
                            : _weekdays[days[i].date.weekday - 1],
                        units: units,
                        showValue: !month || selected == days[i].date,
                        fill: _barFill(
                          brand.accentInk,
                          isToday: days[i].date == t0,
                          isSelected: selected == days[i].date,
                          anySelected: selected != null,
                        ),
                        onTap: () => onSelect(
                          selected == days[i].date ? null : days[i].date,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Bar colour: today and the selected day are solid; the rest are softened
/// (less so when nothing is selected) but stay clearly readable.
Color _barFill(
  Color base, {
  required bool isToday,
  required bool isSelected,
  required bool anySelected,
}) {
  if (isSelected || (isToday && !anySelected)) return base;
  return base.withValues(alpha: anySelected ? 0.5 : 0.7);
}

/// Compact value shown above a bar ("52", "8.4").
String barValueLabel(double v) {
  if (v >= 10) return v.round().toString();
  return v.toStringAsFixed(1);
}

class _Bar extends StatelessWidget {
  const _Bar({
    required this.day,
    required this.value,
    required this.frac,
    required this.isToday,
    required this.isSelected,
    required this.label,
    required this.units,
    required this.fill,
    required this.showValue,
    required this.onTap,
  });

  final bool showValue;
  final ReportDay day;
  final double value;
  final double frac;
  final bool isToday;
  final bool isSelected;
  final String label;
  final UnitSystem units;
  final Color fill;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final String drives = day.drives == 1 ? '1 drive' : '${day.drives} drives';
    final String sem =
        '${dayText(day.date)}${isToday ? ', today' : ''}: '
        '${day.drives == 0 ? 'no drives' : '${units.formatDistance(day.distanceM)}, $drives'}'
        '${isSelected ? ', selected' : ''}';
    final bool narrow = label.length < 3 && MediaQuery.sizeOf(context).width < 900;
    return Semantics(
      button: true,
      selected: isSelected,
      label: sem,
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: Column(
          children: <Widget>[
            SizedBox(
              height: DrivingDaysChart.plotHeight,
              child: Stack(
                alignment: Alignment.bottomCenter,
                clipBehavior: Clip.none,
                children: <Widget>[
                  // Faint full-height rail so empty days still read as a slot.
                  FractionallySizedBox(
                    widthFactor: narrow ? 0.62 : 0.5,
                    heightFactor: 1,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: cs.onSurface.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                      ),
                    ),
                  ),
                  if (day.drives > 0)
                    FractionallySizedBox(
                      widthFactor: narrow ? 0.62 : 0.5,
                      heightFactor: frac.clamp(0.05, 1.0),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: fill,
                          borderRadius: BorderRadius.circular(AppRadius.sm),
                          border: isSelected
                              ? Border.all(color: cs.onSurface, width: 2)
                              : null,
                        ),
                      ),
                    ),
                  if (day.drives > 0 && showValue)
                    Positioned(
                      left: -8,
                      right: -8,
                      bottom: frac.clamp(0.05, 1.0) * DrivingDaysChart.plotHeight + 2,
                      child: Text(
                        barValueLabel(value),
                        key: ValueKey<String>('bar-value-${day.date.toIso8601String()}'),
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        style: AppType.secondary.copyWith(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: cs.onSurface,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: AppSpace.xs),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.clip,
              style: AppType.secondary.copyWith(
                fontSize: 11,
                fontWeight: isToday || isSelected
                    ? FontWeight.w800
                    : FontWeight.w500,
                color: isToday || isSelected
                    ? cs.onSurface
                    : cs.onSurfaceVariant,
                decoration:
                    isToday ? TextDecoration.underline : TextDecoration.none,
              ),
            ),
            const SizedBox(height: AppSpace.sm),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Recent drives
// ---------------------------------------------------------------------------

/// One drive: who, when, distance, duration, top speed and event badges.
class RecentDriveTile extends StatelessWidget {
  const RecentDriveTile({
    super.key,
    required this.trip,
    required this.member,
    required this.name,
    required this.units,
    required this.now,
    required this.onTap,
  });

  final RecentTrip trip;
  final Member member;
  final String name;
  final UnitSystem units;
  final DateTime now;
  final VoidCallback onTap;

  List<Widget> _badges() {
    final List<Widget> out = <Widget>[];
    for (final DrivingEventKind k in DrivingEventKind.values) {
      final int n = trip.events.of(k) ?? 0;
      if (n == 0) continue;
      out.add(
        DsStatusChip(
          label: '$n ${k.label.toLowerCase()}',
          icon: eventIcon(k),
          color: eventColor(k),
        ),
      );
    }
    return out;
  }

  String _eventSemantics() {
    final List<String> parts = <String>[
      for (final DrivingEventKind k in DrivingEventKind.values)
        if ((trip.events.of(k) ?? 0) > 0)
          '${trip.events.of(k)} ${k.label.toLowerCase()}',
    ];
    return parts.isEmpty ? 'no risky events' : parts.join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final String when = driveWhen(context, trip.startedAt, now);
    final String facts =
        '${units.formatDistance(trip.distanceM)} · '
        '${formatTripDuration(trip.duration)} · '
        'top ${units.formatSpeed(trip.maxSpeedMps)}';
    final List<Widget> badges = _badges();
    return Semantics(
      button: true,
      label: '$name, $when. $facts, GPS speed. ${_eventSemantics()}. '
          'Opens the trip.',
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
            padding: const EdgeInsets.all(AppSpace.md),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: Border.all(color: cs.outlineVariant),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                StatusAvatar(member: member, size: 40),
                const SizedBox(width: AppSpace.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text('$name · $when', style: AppType.headline),
                      const SizedBox(height: AppSpace.xxs),
                      Text(
                        facts,
                        style: AppType.secondary
                            .copyWith(color: cs.onSurfaceVariant),
                      ),
                      if (badges.isNotEmpty) ...<Widget>[
                        const SizedBox(height: AppSpace.sm),
                        Wrap(
                          spacing: AppSpace.sm,
                          runSpacing: AppSpace.xs,
                          children: badges,
                        ),
                      ],
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

// ---------------------------------------------------------------------------
// Notices
// ---------------------------------------------------------------------------

/// A calm inline card: icon, title, message and an optional action. Meaning
/// is in the words, not the tint.
class DrivingNoticeCard extends StatelessWidget {
  const DrivingNoticeCard({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
    this.secondaryLabel,
    this.onSecondary,
  });

  final IconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      child: Container(
        padding: const EdgeInsets.all(AppSpace.lg),
        decoration: _cardBox(context),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(icon, color: BrandTheme.of(context).accentInk),
                const SizedBox(width: AppSpace.md),
                Expanded(child: Text(title, style: AppType.headline)),
              ],
            ),
            if (message != null) ...<Widget>[
              const SizedBox(height: AppSpace.sm),
              Text(
                message!,
                style: AppType.secondary.copyWith(color: cs.onSurfaceVariant),
              ),
            ],
            if (actionLabel != null || secondaryLabel != null) ...<Widget>[
              const SizedBox(height: AppSpace.md),
              Wrap(
                spacing: AppSpace.sm,
                runSpacing: AppSpace.sm,
                children: <Widget>[
                  if (actionLabel != null)
                    DsPillButton(
                      label: actionLabel!,
                      onPressed: onAction,
                    ),
                  if (secondaryLabel != null)
                    DsPillButton(
                      label: secondaryLabel!,
                      onPressed: onSecondary,
                      style: DsPillStyle.outlined,
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A plain one-line hint under a section.
class DrivingHint extends StatelessWidget {
  const DrivingHint(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: AppType.secondary.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
  );
}
