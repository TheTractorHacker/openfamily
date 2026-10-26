import 'package:flutter/material.dart';

import '../models/trip_report.dart';
import '../services/speed_units.dart';
import '../theme/app_theme.dart';
import 'ds/ds.dart';
import 'driving_event_chips.dart';

/// "What is <event>?" copy, quoting the thresholds the server used.
String eventExplanation(
  DrivingEventKind k,
  ReportThresholds t,
  UnitSystem u,
) {
  String accel(double mps2) =>
      '${u.speedFromMps(mps2).toStringAsFixed(1)} ${u.speedLabel} per second';
  return switch (k) {
    DrivingEventKind.speeding =>
      'A speeding event is logged when a drive stays over '
          '${u.formatSpeed(t.speedingMps)} for at least '
          '${t.speedingSeconds} seconds. Brief spikes are ignored.',
    DrivingEventKind.hardBrake =>
      'A hard braking event is logged when the car loses speed faster than '
          '${accel(t.hardBrakeMps2)}, like stopping suddenly for traffic.',
    DrivingEventKind.rapidAccel =>
      'A rapid acceleration event is logged when the car gains speed faster '
          'than ${accel(t.rapidAccelMps2)}, like pulling away from a light '
          'in a hurry.',
    DrivingEventKind.phoneUse =>
      'Phone use would flag handling the phone while the car is moving. '
          'OpenFamily does not measure this yet, so no count is shown. A '
          'blank is not the same as zero.',
  };
}

/// Opens the explanation sheet for [kind].
Future<void> showDrivingEventSheet(
  BuildContext context, {
  required TripReport report,
  required DrivingEventKind kind,
  required UnitSystem units,
  required String phrase,
  required String Function(MemberReport) nameOf,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (BuildContext ctx) => DrivingEventSheet(
      report: report,
      kind: kind,
      units: units,
      phrase: phrase,
      nameOf: nameOf,
    ),
  );
}

class DrivingEventSheet extends StatelessWidget {
  const DrivingEventSheet({
    super.key,
    required this.report,
    required this.kind,
    required this.units,
    required this.phrase,
    required this.nameOf,
  });

  final TripReport report;
  final DrivingEventKind kind;
  final UnitSystem units;
  final String phrase;
  final String Function(MemberReport) nameOf;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color tint = eventColor(kind);
    final int? count = report.totals.events.of(kind);
    final List<MemberReport> who = report.membersWith(kind);
    final bool brakeOrAccel =
        kind == DrivingEventKind.hardBrake || kind == DrivingEventKind.rapidAccel;
    return DsSheetScaffold(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          AppSpace.xl,
          AppSpace.sm,
          AppSpace.xl,
          AppSpace.xl,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Center(
              child: Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: tint.withValues(alpha: dark ? 0.28 : 0.16),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  eventIcon(kind),
                  size: 32,
                  color: dark
                      ? Color.lerp(tint, Colors.white, 0.45)
                      : Color.lerp(tint, Colors.black, 0.35),
                ),
              ),
            ),
            const SizedBox(height: AppSpace.md),
            Center(
              child: Semantics(
                header: true,
                child: Text(
                  kind.label,
                  textAlign: TextAlign.center,
                  style: AppType.title,
                ),
              ),
            ),
            const SizedBox(height: AppSpace.xs),
            Center(
              child: Text(
                count == null
                    ? 'Not tracked yet'
                    : '${incidentsText(count)} $phrase',
                textAlign: TextAlign.center,
                style: AppType.body.copyWith(color: cs.onSurfaceVariant),
              ),
            ),
            if (who.length > 1) ...<Widget>[
              const SizedBox(height: AppSpace.lg),
              for (final MemberReport m in who)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
                  child: Semantics(
                    container: true,
                    label: '${nameOf(m)}: ${incidentsText(m.events.of(kind)!)}',
                    excludeSemantics: true,
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(nameOf(m), style: AppType.body),
                        ),
                        Text(
                          incidentsText(m.events.of(kind)!),
                          style: AppType.body.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
            const SizedBox(height: AppSpace.xl),
            Semantics(
              header: true,
              child: Text('What is ${kind.label.toLowerCase()}?',
                  style: AppType.headline),
            ),
            const SizedBox(height: AppSpace.sm),
            Text(
              eventExplanation(kind, report.thresholds, units),
              style: AppType.body.copyWith(
                fontWeight: FontWeight.w500,
                height: 1.4,
              ),
            ),
            if (brakeOrAccel || kind == DrivingEventKind.speeding) ...<Widget>[
              const SizedBox(height: AppSpace.md),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(Icons.info_outline, size: 18, color: cs.onSurfaceVariant),
                  const SizedBox(width: AppSpace.sm),
                  Expanded(
                    child: Text(
                      brakeOrAccel
                          ? 'These are estimates from GPS, so a phone in a '
                              'weak signal area can read a little off.'
                          : 'Speeds come from GPS and are estimates.',
                      style: AppType.secondary.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: AppSpace.xl),
            DsPillButton(
              label: 'Got it',
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }
}
