import '../models/member.dart';
import 'fix_quality.dart';
import 'speed_units.dart';

/// The ONE rule for "is this person driving, stopped in a vehicle, or not
/// driving", and what speed (if any) may be shown next to it. Every display
/// (map pill, bottom sheet, list rows, widget, watch snapshot) and the member
/// mapper go through [resolveDriving]; nothing else decides "Driving 0 mph".
///
/// Why it exists: the phone's motion label ("driving") only changes when the
/// activity recogniser fires, so it outlives the drive; and a missing GPS
/// speed used to arrive as a real 0. Together they read "in a vehicle moving
/// at 0 mph". The label alone is therefore never enough.
///
/// Decisions, in order:
///  1. Not tagged as a vehicle: not driving.
///  2. The last stored fix is older than [kDrivingFixMaxAge]: the label is
///     stale, not driving. (The server stores no new row while a phone sits
///     still, so a parked phone's fix time stops moving; this is what clears
///     the badge.)
///  3. Slow or unmoved since [slowSince] for longer than [kStoppedGrace]:
///     parked, not driving.
///  4. Trusted speed at or above [kStoppedBelowMps]: driving, with that speed.
///  5. Trusted speed below it: Stopped (a red light keeps the car badge for up
///     to [kStoppedGrace], shown as "Stopped", never "Driving 0 mph").
///  6. Speed missing or not trustworthy: Driving with no number (we cannot say
///     it is moving, but we do not print a 0 we do not know).
enum DrivingPhase {
  /// Not in a vehicle (or the vehicle state is stale): no car badge, no speed.
  notDriving,

  /// In a vehicle. The speed may or may not be known.
  driving,

  /// In a vehicle that is standing still right now (red light, traffic).
  stopped,
}

/// A last stored fix older than this cannot back a "driving" claim. Driving
/// fixes arrive every few seconds; two minutes covers a tunnel or a weak
/// patch without keeping a parked phone's car badge.
const Duration kDrivingFixMaxAge = Duration(minutes: 2);

/// How long a car may stay at a standstill and still count as "Stopped" (red
/// light, rail crossing). Longer than this it is parked.
const Duration kStoppedGrace = Duration(minutes: 3);

/// Below this ground speed (m/s, about 1 mph) the vehicle counts as standing.
const double kStoppedBelowMps = 0.5;

/// A speed reading with an error bar larger than this (m/s) is not trusted.
const double kBadSpeedAccuracyMps = 3.0; // = FixQualityConfig.badSpeedAccuracyMps

/// The ground speed to believe, or null when it is unknown or unreliable.
///
/// Unknown: null, negative, NaN, or an impossible value. Unreliable: a stated
/// speed accuracy worse than [kBadSpeedAccuracyMps]; or a standstill reading
/// (below [kStoppedBelowMps]) without good position accuracy, because a 0 from
/// a weak or unknown fix usually just means "no speed available".
double? trustedSpeedMps({
  double? speedMps,
  double? speedAccuracyMps,
  double? accuracyMeters,
  FixQualityConfig config = const FixQualityConfig(),
}) {
  final double? v = speedMps;
  if (v == null || v.isNaN || v.isInfinite || v < 0) return null;
  if (v > config.maxPlausibleSpeedMps) return null;
  if (speedAccuracyMps != null &&
      speedAccuracyMps.isFinite &&
      speedAccuracyMps > kBadSpeedAccuracyMps) {
    return null;
  }
  if (v < kStoppedBelowMps) {
    final bool good = accuracyMeters != null &&
        accuracyMeters > 0 &&
        accuracyMeters <= config.goodAccuracyForZeroSpeedM;
    if (!good) return null;
  }
  return v;
}

/// The answer of [resolveDriving].
class DrivingView {
  const DrivingView(this.phase, [this.speedMps]);

  static const DrivingView notDriving = DrivingView(DrivingPhase.notDriving);

  final DrivingPhase phase;

  /// A trusted moving speed in m/s; null when stopped, unknown or not driving.
  final double? speedMps;

  /// Show the car badge.
  bool get isDriving => phase != DrivingPhase.notDriving;

  /// Standing still in a vehicle.
  bool get isStopped => phase == DrivingPhase.stopped;

  /// The map pill (speed caption) is shown: a real speed or "Stopped".
  bool get hasCaption => isStopped || (isDriving && speedMps != null);

  /// "Driving" or "Stopped"; empty when not driving.
  String get word => switch (phase) {
        DrivingPhase.driving => 'Driving',
        DrivingPhase.stopped => 'Stopped',
        DrivingPhase.notDriving => '',
      };

  /// "Driving 42 mph" / "Driving" / "Stopped". [separator] sits between the
  /// word and the number ("Driving 42 mph", "Driving · 42 mph").
  String line(UnitSystem units, {String separator = ' '}) {
    final double? v = speedMps;
    if (phase != DrivingPhase.driving || v == null) return word;
    return '$word$separator${units.formatSpeed(v)}';
  }
}

/// Resolves the driving presentation from the raw facts of the last fix.
///
/// [movement] is the member's movement tag; [speedMps] the speed to judge (the
/// live smoothed speed on screen, else the stored one); [fixTime] when the
/// last position was stored; [slowSince] when the vehicle was first seen
/// standing or unmoved without a break (see [isSlowFix]); [now] defaults to
/// the clock.
DrivingView resolveDriving({
  required MovementType movement,
  double? speedMps,
  double? speedAccuracyMps,
  double? accuracyMeters,
  DateTime? fixTime,
  DateTime? slowSince,
  DateTime? now,
}) {
  if (movement != MovementType.car) return DrivingView.notDriving;
  final DateTime n = (now ?? DateTime.now()).toUtc();
  if (fixTime != null && n.difference(fixTime.toUtc()) > kDrivingFixMaxAge) {
    return DrivingView.notDriving;
  }
  if (slowSince != null && n.difference(slowSince.toUtc()) > kStoppedGrace) {
    return DrivingView.notDriving;
  }
  final double? v = trustedSpeedMps(
    speedMps: speedMps,
    speedAccuracyMps: speedAccuracyMps,
    accuracyMeters: accuracyMeters,
  );
  if (v == null) return const DrivingView(DrivingPhase.driving);
  if (v < kStoppedBelowMps) return const DrivingView(DrivingPhase.stopped);
  return DrivingView(DrivingPhase.driving, v);
}

/// Whether a fix shows the vehicle standing still, for tracking [Member.slowSince].
///
/// A trusted speed decides. With no trusted speed the movement between the
/// previous and this fix decides: barely moved (within position noise) and a
/// low average speed means standing. [distanceM] and [elapsed] describe that
/// step; both null when there is no previous fix.
bool isSlowFix({
  double? speedMps,
  double? speedAccuracyMps,
  double? accuracyMeters,
  double? distanceM,
  Duration? elapsed,
  double? previousAccuracyMeters,
}) {
  final double? v = trustedSpeedMps(
    speedMps: speedMps,
    speedAccuracyMps: speedAccuracyMps,
    accuracyMeters: accuracyMeters,
  );
  if (v != null) return v < kStoppedBelowMps;
  if (distanceM == null || elapsed == null || elapsed.inMilliseconds <= 0) {
    return false;
  }
  final double noise = <double>[
    20,
    accuracyMeters ?? 0,
    previousAccuracyMeters ?? 0,
  ].reduce((double a, double b) => a > b ? a : b);
  final double avg = distanceM / (elapsed.inMilliseconds / 1000);
  return distanceM <= noise && avg < 1.0;
}

/// The driving presentation of [Member] [m]. [liveSpeedMps] is the smoothed
/// on-screen speed from the marker motion hub when there is one; it is judged
/// instead of the stored speed.
extension MemberDriving on Member {
  DrivingView drivingView({double? liveSpeedMps, DateTime? now}) =>
      resolveDriving(
        movement: movement,
        speedMps: liveSpeedMps ?? speedMps,
        accuracyMeters: accuracyMeters,
        fixTime: fixTime,
        slowSince: slowSince,
        now: now,
      );

  /// Whether the pin / row shows a movement badge: a car only while the
  /// driving rule says it is still in a vehicle; other movements as tagged.
  bool get showsMovementBadge => movement == MovementType.car
      ? drivingView().isDriving
      : movement != MovementType.none;

  /// Whether the map pin shows a caption under it (a speed or "Stopped").
  bool get hasDrivingSpeed => drivingView().hasCaption;

  /// Whether this member is driving fast enough to show as "speeding".
  bool get isSpeeding => isSpeedingMps(drivingView().speedMps);
}
