import 'package:flutter/widgets.dart';

import '../models/member.dart';
import '../services/member_motion_hub.dart';
import '../services/speed_units.dart';

/// Rebuilds [builder] when a member's displayed speed (or the user's speed
/// unit) can have changed: on a new fix or when a speed goes stale. This is
/// per fix, never per animation frame, so cached map bubbles stay cached and
/// only the caption text rebuilds.
class LiveSpeedBuilder extends StatelessWidget {
  const LiveSpeedBuilder({
    super.key,
    required this.member,
    required this.builder,
    this.hub,
  });

  final Member member;
  final Widget Function(BuildContext context, double? mps, UnitSystem units)
      builder;
  final MemberMotionHub? hub;

  @override
  Widget build(BuildContext context) {
    final MemberMotionHub h = hub ?? MemberMotionHub.shared;
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        h.speeds,
        UnitPreferenceService.units,
      ]),
      builder: (BuildContext ctx, _) => builder(
        ctx,
        h.liveSpeedMps(member),
        UnitPreferenceService.units.value,
      ),
    );
  }
}

/// "42 mph" / "68 km/h" for [mps], or null when the speed is unknown.
String? speedText(double? mps, UnitSystem units) =>
    mps == null ? null : units.formatSpeed(mps);

/// Snapshot (non-listening) label for tooltips and semantics.
String? liveSpeedLabel(Member m) => speedText(
      MemberMotionHub.shared.liveSpeedMps(m),
      UnitPreferenceService.units.value,
    );
