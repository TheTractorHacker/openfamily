import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Display unit for speeds and distances on the trips screens.
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

  /// Loads the stored preference once; later calls reuse the result.
  static Future<UnitSystem> ensureLoaded() => _loading ??= load();

  static Future<UnitSystem> load() async {
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      units.value = p.getString(_unitKey) == 'metric'
          ? UnitSystem.metric
          : UnitSystem.imperial;
    } catch (_) {}
    return units.value;
  }

  static Future<void> setUnits(UnitSystem value) async {
    units.value = value;
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      await p.setString(_unitKey, value.name);
    } catch (_) {}
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
