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
    this.maxSpeedMps,
    this.confidence,
    this.activity,
  });

  final DrivingEventKind kind;
  final int startedAtMs;
  final int endedAtMs;

  /// m/s^2 for braking/acceleration; seconds for phone use.
  final double magnitude;
  final double? lat;
  final double? lon;

  /// Phone use only: highest GPS speed during the event (m/s).
  final double? maxSpeedMps;

  /// Phone use only: 0..1 how sure we are the phone was in use (handling and
  /// call evidence). Optional on the wire.
  final double? confidence;

  /// Phone use only: `screen` or `call`. Optional on the wire.
  final String? activity;

  DrivingEvent copyWith({int? endedAtMs, double? magnitude}) => DrivingEvent(
        kind: kind,
        startedAtMs: startedAtMs,
        endedAtMs: endedAtMs ?? this.endedAtMs,
        magnitude: magnitude ?? this.magnitude,
        lat: lat,
        lon: lon,
        maxSpeedMps: maxSpeedMps,
        confidence: confidence,
        activity: activity,
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
        // Optional phone-use fields: omitted when unset so old servers and
        // old queued events keep working.
        if (maxSpeedMps != null)
          'max_speed_mps': double.parse(maxSpeedMps!.toStringAsFixed(1)),
        if (confidence != null)
          'confidence': double.parse(confidence!.toStringAsFixed(2)),
        if (activity != null) 'activity': activity,
      };

  @override
  String toString() =>
      'DrivingEvent(${kind.wire}, $startedAtMs..$endedAtMs, ${magnitude.toStringAsFixed(2)})';
}
