import 'package:shared_preferences/shared_preferences.dart';

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

/// This phone's copy of the account's "Show names in notifications" choice
/// (`show_names` in `/me/notifications`). The server applies it to the pushes
/// it writes; notifications the PHONE writes (end-to-end encrypted chat, whose
/// text only the phone can read) need it locally, including in the background
/// isolate, so it is kept in shared preferences. Off until known (fails
/// closed like the server).
class NotificationNames {
  NotificationNames._();

  static const String _key = 'notif.show_names.v1';

  /// The last known value (sync, for widgets that already ran [load]).
  static bool cached = false;

  /// Reads the stored value (fresh from disk: the background isolate may
  /// read it long after the app changed it).
  static Future<bool> load() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      cached = prefs.getBool(_key) ?? false;
    } catch (_) {}
    return cached;
  }

  /// Stores a value the server confirmed (settings screen load / save).
  static Future<void> remember(bool show) async {
    cached = show;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_key, show);
    } catch (_) {}
  }

  /// Fetches the account's choice from the server and stores it. Never
  /// throws; keeps the stored value when offline.
  static Future<void> refresh() async {
    try {
      final dynamic d = await ApiClient.get('/me/notifications');
      if (d is Map<String, dynamic>) await remember(d['show_names'] == true);
    } catch (_) {}
  }
}

/// The text of a chat notification, the same rule on the server (Go
/// `chatPushCopy`) and on the phone (encrypted chat): with names on, the
/// title names the sender and the body carries a short preview; with names
/// off, it says only that a message is waiting in [circleName].
({String title, String body}) chatNotificationCopy({
  required bool showNames,
  required String circleName,
  required String senderName,
  required String text,
  bool photo = false,
}) {
  final String circle = circleName.trim().isEmpty ? 'your circle' : circleName.trim();
  if (!showNames) return (title: 'New message in $circle', body: '');
  final String first = _firstName(senderName);
  final String title = '$first in $circle';
  final String preview = _truncate(text.trim(), 120);
  if (photo) {
    return (title: title, body: preview.isEmpty ? 'Sent a photo' : 'Sent a photo: $preview');
  }
  return (title: title, body: preview);
}

String _firstName(String full) {
  final String t = full.trim();
  if (t.isEmpty) return 'A family member';
  return t.split(RegExp(r'\s+')).first;
}

String _truncate(String s, int n) {
  final List<int> runes = s.runes.toList();
  if (runes.length <= n) return s;
  return '${String.fromCharCodes(runes.take(n))}…';
}
