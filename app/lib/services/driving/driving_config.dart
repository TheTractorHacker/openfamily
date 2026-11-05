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

/// Tunables for phone-use detection (screen + handling + hands-free).
///
/// HONESTY NOTE: none of these were calibrated on real cars. The speed and
/// timing values are design choices; the handling thresholds (`tilt*`,
/// `accelStd*`) are educated guesses from typical phone/vehicle motion
/// magnitudes and need field tuning before anything is read into the numbers.
class PhoneUseConfig {
  const PhoneUseConfig({
    this.startSpeedMps = 7.0,
    this.movingSpeedMps = 2.0,
    this.stopGraceMs = 6000,
    this.speedMaxAgeMs = 5000,
    this.mergeGapMs = 10000,
    this.driveEdgeMs = 10000,
    this.minActiveMs = 3000,
    this.maxEpisodeMs = 180000,
    this.maxEventsPerDrive = 8,
    this.unlockGraceMs = 12000,
    this.handlingHoldMs = 8000,
    this.noSensorFallbackMs = 6000,
    this.windowMs = 2000,
    this.tiltRateRadPerSec = 0.35,
    this.tiltRateWeakRadPerSec = 0.25,
    this.accelStdMps2 = 2.0,
    this.noGyroAccelStdMps2 = 3.0,
    this.gravityTauMs = 1000,
  });

  /// Speed at/above which a drive counts as moving (start of counting).
  final double startSpeedMps;

  /// Below this the vehicle is considered stationary (red light, parked):
  /// that time is never counted.
  final double movingSpeedMps;

  /// Stationary this long ends the moving state (and the open event).
  /// Shorter stops (a red light) neither split nor extend an event.
  final int stopGraceMs;

  /// A GPS speed older than this is not trusted.
  final int speedMaxAgeMs;

  /// Interactions closer than this are one event.
  final int mergeGapMs;

  /// Activity in the first/last this-long of a drive is ignored (putting the
  /// phone into / taking it out of a mount or pocket).
  final int driveEdgeMs;

  /// Events with less counted interaction than this are dropped.
  final int minActiveMs;

  /// One event spans at most this long (the server accepts 5 minutes).
  final int maxEpisodeMs;

  /// At most this many events per drive; further ones are dropped.
  final int maxEventsPerDrive;

  /// After an unlock, tapping counts this long even without handling (a
  /// deliberate unlock is an interaction); after that a phone that is
  /// not being handled is treated as mounted/navigating.
  final int unlockGraceMs;

  /// A handling window keeps counting as handling for this long.
  final int handlingHoldMs;

  /// With no handling data at all after this long, fall back to counting the
  /// unlocked screen (older/limited hardware).
  final int noSensorFallbackMs;

  /// Handling analysis window.
  final int windowMs;

  /// Rotation rate (rad/s, about axes other than the vertical one) that on
  /// its own means the phone is in a hand.
  final double tiltRateRadPerSec;

  /// Weaker rotation that counts when combined with [accelStdMps2].
  final double tiltRateWeakRadPerSec;

  /// Accelerometer-magnitude deviation (m/s^2) typical of hand motion.
  final double accelStdMps2;

  /// Same, used when the phone has no gyroscope.
  final double noGyroAccelStdMps2;

  /// Gravity low-pass time constant used to remove vehicle yaw.
  final int gravityTauMs;
}
