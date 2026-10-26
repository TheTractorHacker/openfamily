/// Kinds of events the backend accepts at `POST /trips/sensor-events`.
enum DrivingEventKind {
  hardBrake('hard_brake'),
  rapidAccel('rapid_accel'),
  phoneUse('phone_use');

  const DrivingEventKind(this.wire);

  /// The value used on the wire.
  final String wire;

  static DrivingEventKind? fromWire(String? s) {
    for (final DrivingEventKind k in DrivingEventKind.values) {
      if (k.wire == s) return k;
    }
    return null;
  }
}

/// One detected event. Only this ever leaves the device, never raw samples.
class DrivingEvent {
  const DrivingEvent({
    required this.kind,
    required this.startedAtMs,
    required this.endedAtMs,
    required this.magnitude,
    this.lat,
    this.lon,
  });

  final DrivingEventKind kind;
  final int startedAtMs;
  final int endedAtMs;

  /// m/s^2 for braking/acceleration; seconds for phone use.
  final double magnitude;
  final double? lat;
  final double? lon;

  DrivingEvent copyWith({int? endedAtMs, double? magnitude}) => DrivingEvent(
        kind: kind,
        startedAtMs: startedAtMs,
        endedAtMs: endedAtMs ?? this.endedAtMs,
        magnitude: magnitude ?? this.magnitude,
        lat: lat,
        lon: lon,
      );

  /// Wire/queue representation (RFC 3339 UTC timestamps).
  Map<String, dynamic> toJson() => <String, dynamic>{
        'kind': kind.wire,
        'started_at': DateTime.fromMillisecondsSinceEpoch(startedAtMs,
                isUtc: true)
            .toIso8601String(),
        'ended_at': DateTime.fromMillisecondsSinceEpoch(endedAtMs, isUtc: true)
            .toIso8601String(),
        'magnitude': double.parse(magnitude.toStringAsFixed(2)),
        'lat': lat,
        'lon': lon,
      };

  @override
  String toString() =>
      'DrivingEvent(${kind.wire}, $startedAtMs..$endedAtMs, ${magnitude.toStringAsFixed(2)})';
}
