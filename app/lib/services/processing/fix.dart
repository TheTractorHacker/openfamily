import 'dart:math' as math;

import 'processing_params.dart';

/// One location fix. Time is epoch microseconds (UTC) so comparisons are exact
/// integers, like Go's `time.Time` for the precisions the server stores.
///
/// [speedMps] null (or negative / NaN) means "device did not report speed".
/// [accuracyM] 0 means unknown. Mirrors Go `trips.Point`.
class Fix {
  const Fix({
    required this.tsUs,
    required this.lat,
    required this.lon,
    this.speedMps,
    this.accuracyM = 0,
    this.deviceId = '',
  });

  factory Fix.fromJson(Map<String, dynamic> j) => Fix(
    tsUs: parseUtcMicros(j['ts'] as String),
    lat: (j['lat'] as num).toDouble(),
    lon: (j['lon'] as num).toDouble(),
    speedMps: (j['speed_mps'] as num?)?.toDouble(),
    accuracyM: (j['accuracy_m'] as num?)?.toDouble() ?? 0,
    deviceId: (j['device_id'] as String?) ?? '',
  );

  final int tsUs;
  final double lat;
  final double lon;
  final double? speedMps;
  final double accuracyM;
  final String deviceId;

  DateTime get time => DateTime.fromMicrosecondsSinceEpoch(tsUs, isUtc: true);

  bool get hasDeviceSpeed {
    final double? s = speedMps;
    return s != null && s >= 0 && !s.isNaN;
  }
}

/// Parses RFC 3339 (as emitted by Go) to epoch microseconds, UTC.
int parseUtcMicros(String s) =>
    DateTime.parse(s).toUtc().microsecondsSinceEpoch;

/// RFC 3339 with the trailing zeros trimmed, like Go's `time.RFC3339Nano`.
String formatUtcMicros(int us) {
  final DateTime d = DateTime.fromMicrosecondsSinceEpoch(us, isUtc: true);
  String p(int v, int w) => v.toString().padLeft(w, '0');
  String frac = '';
  if (us % 1000000 != 0) {
    frac = '.${p(d.millisecond, 3)}${p(d.microsecond, 3)}'.replaceFirst(
      RegExp(r'0+$'),
      '',
    );
  }
  return '${p(d.year, 4)}-${p(d.month, 2)}-${p(d.day, 2)}T'
      '${p(d.hour, 2)}:${p(d.minute, 2)}:${p(d.second, 2)}$frac' 'Z';
}

/// Great-circle distance in meters (Go `trips.Haversine`, same formula).
double haversine(double lat1, double lon1, double lat2, double lon2) {
  const double rad = math.pi / 180;
  final double dLat = (lat2 - lat1) * rad;
  final double dLon = (lon2 - lon1) * rad;
  final double a =
      math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * rad) *
          math.cos(lat2 * rad) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  return 2 * kEarthRadiusM * math.asin(math.min(1.0, math.sqrt(a)));
}

/// Speed of the step ending at [b] and whether it is device-reported
/// (Go `stepSpeed`).
({double speed, bool reported}) stepSpeed(Fix a, Fix b, TripParams p) {
  if (b.hasDeviceSpeed) {
    return (
      speed: math.min(b.speedMps!, p.maxPlausibleSpeedMps),
      reported: true,
    );
  }
  final double dt = (b.tsUs - a.tsUs) / 1e6;
  if (dt <= 0) return (speed: 0, reported: false);
  return (
    speed: haversine(a.lat, a.lon, b.lat, b.lon) / dt,
    reported: false,
  );
}

/// What [FixCleaner] did with the input (Go `trips.Stats`).
class CleanStats {
  int input = 0;
  int used = 0;
  int outOfOrder = 0;
  int duplicate = 0;
  int lowAccuracy = 0;
  int teleport = 0;
  int invalidPosition = 0;
}

/// Streaming equivalent of Go `trips.Clean`: out-of-order and duplicate
/// timestamps are rejected (never re-sorted), implausible jumps are dropped
/// unless three in a row (then the anchor was the outlier).
class FixCleaner {
  FixCleaner(this.params);

  final TripParams params;
  final CleanStats stats = CleanStats();
  Fix? _last;
  int _tele = 0;

  /// Returns [f] when accepted, else null.
  Fix? accept(Fix f) {
    stats.input++;
    if (f.lat.isNaN ||
        f.lon.isNaN ||
        f.lat < -90 ||
        f.lat > 90 ||
        f.lon < -180 ||
        f.lon > 180 ||
        (f.lat == 0 && f.lon == 0)) {
      stats.invalidPosition++;
      return null;
    }
    if (params.maxAccuracyM > 0 && f.accuracyM > params.maxAccuracyM) {
      stats.lowAccuracy++;
      return null;
    }
    final Fix? last = _last;
    if (last != null) {
      if (f.tsUs == last.tsUs) {
        stats.duplicate++;
        return null;
      }
      if (f.tsUs < last.tsUs) {
        stats.outOfOrder++;
        return null;
      }
      final int dtUs = f.tsUs - last.tsUs;
      if (dtUs <= params.maxGap.inMicroseconds &&
          params.maxPlausibleSpeedMps > 0) {
        final double d = haversine(last.lat, last.lon, f.lat, f.lon);
        if (d / (dtUs / 1e6) > params.maxPlausibleSpeedMps) {
          _tele++;
          if (_tele < 3) {
            stats.teleport++;
            return null;
          }
        }
      }
    }
    _tele = 0;
    _last = f;
    stats.used++;
    return f;
  }
}

/// Batch convenience: Go `trips.Clean`.
List<Fix> cleanFixes(Iterable<Fix> input, TripParams p, [CleanStats? stats]) {
  final FixCleaner c = FixCleaner(p);
  final List<Fix> out = <Fix>[];
  for (final Fix f in input) {
    final Fix? a = c.accept(f);
    if (a != null) out.add(a);
  }
  if (stats != null) {
    stats
      ..input = c.stats.input
      ..used = c.stats.used
      ..outOfOrder = c.stats.outOfOrder
      ..duplicate = c.stats.duplicate
      ..lowAccuracy = c.stats.lowAccuracy
      ..teleport = c.stats.teleport
      ..invalidPosition = c.stats.invalidPosition;
  }
  return out;
}
