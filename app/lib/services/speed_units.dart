import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Display unit for every speed and distance in the app (one setting).
///
/// The API always speaks m/s and metres; conversion happens only here.
enum UnitSystem { imperial, metric }

const double kMpsToMph = 2.23694;
const double kMpsToKmh = 3.6;
const double kMetersPerMile = 1609.344;

extension UnitSystemX on UnitSystem {
  String get speedLabel => this == UnitSystem.imperial ? 'mph' : 'km/h';
  String get distanceLabel => this == UnitSystem.imperial ? 'mi' : 'km';

  double speedFromMps(double mps) =>
      mps * (this == UnitSystem.imperial ? kMpsToMph : kMpsToKmh);

  double mpsFromSpeed(double v) =>
      v / (this == UnitSystem.imperial ? kMpsToMph : kMpsToKmh);

  /// "42 mph". Speeds are whole numbers; they are only GPS estimates.
  String formatSpeed(double mps) =>
      '${speedFromMps(mps).round()} $speedLabel';

  double distanceFromMeters(double m) =>
      this == UnitSystem.imperial ? m / kMetersPerMile : m / 1000;

  /// "3.2 mi", with feet/metres below a tenth of the larger unit.
  String formatDistance(double meters) {
    final double v = distanceFromMeters(meters);
    if (v < 0.1) {
      return this == UnitSystem.imperial
          ? '${(meters * 3.28084).round()} ft'
          : '${meters.round()} m';
    }
    return '${v.toStringAsFixed(v < 10 ? 1 : 0)} $distanceLabel';
  }

  /// A geofence/bubble radius: "500 ft", "1.5 mi" or "150 m", "2 km". Whole
  /// numbers where exact, one decimal otherwise.
  String formatRadius(double meters) {
    final bool imperial = this == UnitSystem.imperial;
    final double big = imperial ? kMetersPerMile : 1000;
    if (meters >= big) {
      final double v = meters / big;
      final String text = (v - v.roundToDouble()).abs() < 0.05
          ? v.round().toString()
          : v.toStringAsFixed(1);
      return '$text ${imperial ? 'mi' : 'km'}';
    }
    return imperial
        ? '${(meters * 3.28084).round()} ft'
        : '${meters.round()} m';
  }
}

/// Parses the wire value ("imperial" / "metric"); null for anything else.
UnitSystem? parseUnitSystem(Object? v) {
  switch (v) {
    case 'imperial':
      return UnitSystem.imperial;
    case 'metric':
      return UnitSystem.metric;
  }
  return null;
}

/// Compact duration such as "1 h 05 min" or "7 min".
String formatTripDuration(Duration d) {
  if (d.inSeconds < 60) return '${d.inSeconds} s';
  final int mins = (d.inSeconds / 60).round();
  if (mins < 60) return '$mins min';
  final int h = mins ~/ 60;
  final int m = mins % 60;
  return '$h h ${m.toString().padLeft(2, '0')} min';
}

/// Persisted units preference plus the user's local speed-event threshold.
class UnitPreferenceService {
  UnitPreferenceService._();

  static const String _unitKey = 'trip_unit_system';
  static const String _thresholdKey = 'trip_speed_threshold_mps';

  /// Server default (70 mph).
  static const double defaultThresholdMps = 31.3;

  static final ValueNotifier<UnitSystem> units =
      ValueNotifier<UnitSystem>(UnitSystem.imperial);

  static Future<UnitSystem>? _loading;

  /// Whether the person picked a unit on this phone (the stored key exists).
  /// Until they do, the server value / instance default applies.
  static bool _chosen = false;

  /// Called after a local change so it can be mirrored to the server (set at
  /// startup; kept out of this file so it has no network dependency).
  static Future<void> Function(UnitSystem value)? onUserChange;

  /// Loads the stored preference once; later calls reuse the result.
  static Future<UnitSystem> ensureLoaded() => _loading ??= load();

  static Future<UnitSystem> load() async {
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      final String? stored = p.getString(_unitKey);
      _chosen = stored != null;
      units.value =
          stored == 'metric' ? UnitSystem.metric : UnitSystem.imperial;
    } catch (_) {}
    return units.value;
  }

  static Future<void> setUnits(UnitSystem value) async {
    units.value = value;
    _chosen = true;
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      await p.setString(_unitKey, value.name);
    } catch (_) {}
    try {
      await onUserChange?.call(value);
    } catch (_) {}
  }

  static UnitSystem? _serverMine;
  static UnitSystem? _instanceDefault;

  static void _recompute() {
    if (_chosen) return;
    units.value = _serverMine ?? _instanceDefault ?? UnitSystem.imperial;
  }

  /// This person's saved choice on the server (null: never chose). A choice
  /// made on this phone always wins; otherwise the server choice, then the
  /// operator default, then miles. Nothing is stored locally, so a later
  /// operator change still reaches people who never chose.
  static void applyServerChoice(UnitSystem? mine) {
    _serverMine = mine;
    _recompute();
  }

  /// The operator default from `/config` (`default_units`).
  static void applyInstanceDefault(UnitSystem? value) {
    _instanceDefault = value;
    _recompute();
  }

  /// Test hook: pretend [value] is already loaded, so no later storage read
  /// can overwrite it.
  @visibleForTesting
  static void setForTest(UnitSystem value) {
    _loading = Future<UnitSystem>.value(value);
    _chosen = true;
    units.value = value;
  }

  /// Test hook: forget that a choice was made.
  @visibleForTesting
  static void resetForTest() {
    _chosen = false;
    _serverMine = null;
    _instanceDefault = null;
    _loading = null;
    onUserChange = null;
    units.value = UnitSystem.imperial;
  }

  static Future<double> loadThreshold() async {
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      final double? v = p.getDouble(_thresholdKey);
      if (v != null && v > 0 && v <= 90) return v;
    } catch (_) {}
    return defaultThresholdMps;
  }

  static Future<void> saveThreshold(double mps) async {
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      await p.setDouble(_thresholdKey, mps);
    } catch (_) {}
  }
}
