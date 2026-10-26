/// Tunable constants for on-device driving-event detection. Defaults match the
/// server's thresholds (hard brake and rapid acceleration: 3.5 m/s^2).
class DrivingConfig {
  const DrivingConfig({
    this.hardBrakeMps2 = 3.5,
    this.rapidAccelMps2 = 3.5,
    this.minDurationMs = 400,
    this.hysteresisFactor = 0.8,
    this.gapToleranceMs = 150,
    this.minSpeedMps = 5.0,
    this.mergeGapMs = 2000,
    this.smoothingTauMs = 150,
    this.gravityTauMs = 3000,
    this.gravityFreezeMps2 = 1.5,
    this.jerkCapMps2 = 12.0,
    this.reorientMps2 = 8.0,
    this.gyroSpikeRadPerSec = 1.5,
    this.handlingHoldMs = 1500,
    this.gravityTiltInvalidateDeg = 25.0,
    this.axisMinAccelMps2 = 0.8,
    this.axisMinIntervals = 3,
    this.axisMinCoherence = 0.7,
    this.fixMaxGapMs = 3000,
    this.bufferMs = 30000,
  });

  /// Deceleration (m/s^2, positive number) at or above which a hard brake counts.
  final double hardBrakeMps2;

  /// Acceleration (m/s^2) at or above which a rapid acceleration counts.
  final double rapidAccelMps2;

  /// The forward acceleration must stay above the threshold this long.
  final int minDurationMs;

  /// An episode ends when the value falls below threshold * this factor.
  final double hysteresisFactor;

  /// Brief dips below the exit level shorter than this do not end an episode.
  final int gapToleranceMs;

  /// Events only count when the GPS speed around them exceeds this.
  final double minSpeedMps;

  /// Same-kind events closer than this are merged into one.
  final int mergeGapMs;

  /// Time constant of the forward-acceleration smoothing filter.
  final int smoothingTauMs;

  /// Gravity low-pass time constant while the phone is quasi-static.
  final int gravityTauMs;

  /// Gravity estimation freezes (slow time constant) above this linear accel.
  final double gravityFreezeMps2;

  /// Horizontal acceleration above this is a jolt (drop, bump), never braking.
  final double jerkCapMps2;

  /// Deviation from the gravity estimate above this cannot be vehicle motion;
  /// it means the phone was moved, so gravity is re-learned quickly.
  final double reorientMps2;

  /// Gyroscope magnitude above this means the phone is being handled.
  final double gyroSpikeRadPerSec;

  /// Detection is suppressed this long after a handling spike.
  final int handlingHoldMs;

  /// If gravity moves this far from the axis calibration the axis is dropped.
  final double gravityTiltInvalidateDeg;

  /// GPS-derivative magnitude needed for an interval to teach the forward axis.
  final double axisMinAccelMps2;

  /// Number of such intervals needed before the axis is trusted.
  final int axisMinIntervals;

  /// Required |sum| / sum|.| of the axis votes (direction consistency).
  final double axisMinCoherence;

  /// Max age difference between an event and the GPS fix used to check it.
  final int fixMaxGapMs;

  /// Sensor history kept to replay once the forward axis becomes known.
  final int bufferMs;
}
