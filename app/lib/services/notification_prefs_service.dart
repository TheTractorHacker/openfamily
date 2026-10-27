import 'api_client.dart';

/// What the signed-in user wants to hear about one family member. SOS alerts
/// are always delivered and are not part of this model.
class NotificationPrefs {
  const NotificationPrefs({
    this.muted = false,
    this.arrivals = true,
    this.departures = true,
    this.lowBattery = true,
    this.driving = true,
    this.quietStart,
    this.quietEnd,
    this.timezone = 'UTC',
  });

  final bool muted;
  final bool arrivals;
  final bool departures;
  final bool lowBattery;
  final bool driving;

  /// "HH:MM" local to [timezone]; both null or both set.
  final String? quietStart;
  final String? quietEnd;
  final String timezone;

  bool get hasQuietHours => quietStart != null && quietEnd != null;

  NotificationPrefs copyWith({
    bool? muted,
    bool? arrivals,
    bool? departures,
    bool? lowBattery,
    bool? driving,
    String? quietStart,
    String? quietEnd,
    bool clearQuiet = false,
  }) {
    return NotificationPrefs(
      muted: muted ?? this.muted,
      arrivals: arrivals ?? this.arrivals,
      departures: departures ?? this.departures,
      lowBattery: lowBattery ?? this.lowBattery,
      driving: driving ?? this.driving,
      quietStart: clearQuiet ? null : (quietStart ?? this.quietStart),
      quietEnd: clearQuiet ? null : (quietEnd ?? this.quietEnd),
      timezone: timezone,
    );
  }

  factory NotificationPrefs.fromJson(Map<String, dynamic> j) {
    return NotificationPrefs(
      muted: j['muted'] == true,
      arrivals: j['arrivals'] != false,
      departures: j['departures'] != false,
      lowBattery: j['low_battery'] != false,
      driving: j['driving'] != false,
      quietStart: j['quiet_start'] as String?,
      quietEnd: j['quiet_end'] as String?,
      timezone: (j['timezone'] as String?) ?? 'UTC',
    );
  }

  /// [timezone] is replaced by the phone's current UTC offset on save, since
  /// quiet hours are read on the phone's clock.
  Map<String, dynamic> toJson({required String timezone}) => <String, dynamic>{
        'muted': muted,
        'arrivals': arrivals,
        'departures': departures,
        'low_battery': lowBattery,
        'driving': driving,
        'quiet_start': quietStart,
        'quiet_end': quietEnd,
        'timezone': timezone,
      };
}

/// "UTC+05:30" for the phone's current offset, accepted by the server.
String currentUtcOffsetLabel([Duration? offset]) {
  final Duration o = offset ?? DateTime.now().timeZoneOffset;
  final int m = o.inMinutes.abs();
  final String sign = o.isNegative ? '-' : '+';
  return 'UTC$sign${(m ~/ 60).toString().padLeft(2, '0')}:'
      '${(m % 60).toString().padLeft(2, '0')}';
}

abstract class NotificationPrefsService {
  Future<NotificationPrefs> load(String memberId);

  /// Throws [ApiException] with the server's message on failure.
  Future<NotificationPrefs> save(String memberId, NotificationPrefs prefs);
}

class ApiNotificationPrefsService implements NotificationPrefsService {
  const ApiNotificationPrefsService();

  @override
  Future<NotificationPrefs> load(String memberId) async {
    final dynamic r =
        await ApiClient.get('/members/$memberId/notification-prefs');
    return NotificationPrefs.fromJson(r as Map<String, dynamic>);
  }

  @override
  Future<NotificationPrefs> save(
      String memberId, NotificationPrefs prefs) async {
    final dynamic r = await ApiClient.put(
      '/members/$memberId/notification-prefs',
      body: prefs.toJson(timezone: currentUtcOffsetLabel()),
    );
    return NotificationPrefs.fromJson(r as Map<String, dynamic>);
  }
}
