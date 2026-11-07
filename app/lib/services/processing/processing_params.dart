/// Pinned thresholds shared by every on-device processor.
///
/// These mirror `backend/internal/trips` (`DefaultParams`, `DefaultEventParams`,
/// `AlgorithmVersion`) and `backend/internal/handlers/weekly_summary.go`. They
/// are deliberately constants: a phone-only member's results must agree with
/// what the server would have produced for the same fixes, so a change here is
/// a change of algorithm and must bump [kProcessingAlgorithmVersion] and
/// regenerate `testdata/processing/*.json` (see PROCESSING_ON_DEVICE.md).
library;

/// Mirrors Go `trips.AlgorithmVersion`.
const int kProcessingAlgorithmVersion = 1;

/// Earth radius used by the server's haversine (meters).
const double kEarthRadiusM = 6371000.0;

/// Trip modes (Go `ModeDriving`, ...).
const String kModeDriving = 'driving';
const String kModeWalking = 'walking';
const String kModeOther = 'other';

/// Speed sources (Go `SourceDevice`, ...).
const String kSourceDevice = 'device_gps';
const String kSourceDerived = 'derived';
const String kSourceMixed = 'mixed';

/// Event kinds (Go `EventSpeeding`, ...).
const String kEventSpeeding = 'speeding';
const String kEventHardBrake = 'hard_brake';
const String kEventRapidAccel = 'rapid_accel';
const String kEventPhoneUse = 'phone_use';

/// Mode classification on the 90th percentile of moving step speeds.
const double kDrivingP90Mps = 5.5;
const double kWalkingP90Mps = 2.5;

/// Steps shorter than this are discounted as jitter when the device reports a
/// speed below [TripParams.movingSpeedMps].
const double kStationaryJitterM = 20.0;

/// Safety score: `round(100 - 5 * events / max(km, 10) * 100)`, clamped 0..100.
const double kScorePenaltyPerEventPer100Km = 5;
const double kScoreMinKm = 10;

/// Weekly summary window: Monday 00:00 UTC to Sunday 18:00 UTC.
const Duration kWeeklyDueOffset = Duration(days: 6, hours: 18);

/// Number of recent drives in the report.
const int kRecentTripsLimit = 10;

/// Segmentation thresholds. Defaults equal Go `DefaultParams()`.
class TripParams {
  const TripParams({
    this.maxAccuracyM = 100,
    this.maxPlausibleSpeedMps = 90,
    this.movingSpeedMps = 1.0,
    this.driveSpeedMps = 4.5,
    this.stopRadiusM = 50,
    this.stopDuration = const Duration(minutes: 3),
    this.maxGap = const Duration(minutes: 10),
    this.minTripDistanceM = 250,
    this.minTripDuration = const Duration(minutes: 2),
    this.minLegDuration = const Duration(minutes: 2),
    this.minLegDistanceM = 150,
    this.noiseStepM = 5,
  });

  final double maxAccuracyM;
  final double maxPlausibleSpeedMps;
  final double movingSpeedMps;
  final double driveSpeedMps;
  final double stopRadiusM;
  final Duration stopDuration;
  final Duration maxGap;
  final double minTripDistanceM;
  final Duration minTripDuration;
  final Duration minLegDuration;
  final double minLegDistanceM;
  final double noiseStepM;
}

/// Event thresholds. Defaults equal Go `DefaultEventParams()` with the server's
/// default environment (`DRIVING_*` unset): 80 mph, 30 s, 3.5 m/s^2 both ways.
class EventParams {
  const EventParams({
    this.speedingMps = 35.76,
    this.speedingSeconds = 30,
    this.hardBrakeMps2 = 3.5,
    this.rapidAccelMps2 = 3.5,
    this.maxAccelGap = const Duration(seconds: 4),
    this.minAccelDt = const Duration(milliseconds: 500),
    this.maxAccelAccuracyM = 30,
    this.minMovingMps = 5,
    this.maxPlausibleAccel = 12,
    this.maxSpeedingGap = const Duration(seconds: 15),
  });

  final double speedingMps;
  final double speedingSeconds;
  final double hardBrakeMps2;
  final double rapidAccelMps2;
  final Duration maxAccelGap;
  final Duration minAccelDt;
  final double maxAccelAccuracyM;
  final double minMovingMps;
  final double maxPlausibleAccel;
  final Duration maxSpeedingGap;
}
