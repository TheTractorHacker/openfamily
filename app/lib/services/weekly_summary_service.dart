import 'api_client.dart';
import 'trips_service.dart';

/// One member's driving in one week.
class WeekStat {
  const WeekStat({
    this.drives = 0,
    this.distanceM = 0,
    this.durationS = 0,
    this.topSpeedMps = 0,
    this.hardBrake = 0,
    this.rapidAccel = 0,
    this.speeding = 0,
    this.phoneUse,
    this.score,
  });

  final int drives;
  final double distanceM;
  final double durationS;
  final double topSpeedMps;
  final int hardBrake;
  final int rapidAccel;
  final int speeding;

  /// Null unless this member opted in to phone-use detection.
  final int? phoneUse;

  /// 0-100 safety score; null when nothing was driven.
  final int? score;

  int get eventCount => hardBrake + rapidAccel + speeding + (phoneUse ?? 0);

  factory WeekStat.fromJson(Map<String, dynamic> j) {
    final Map<String, dynamic> ev =
        (j['events'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
    num n(Object? v) => v is num ? v : 0;
    return WeekStat(
      drives: n(j['drives']).toInt(),
      distanceM: n(j['distance_m']).toDouble(),
      durationS: n(j['duration_s']).toDouble(),
      topSpeedMps: n(j['top_speed_mps']).toDouble(),
      hardBrake: n(ev['hard_brake']).toInt(),
      rapidAccel: n(ev['rapid_accel']).toInt(),
      speeding: n(ev['speeding']).toInt(),
      phoneUse: ev['phone_use'] is num ? (ev['phone_use'] as num).toInt() : null,
      score: j['safety_score'] is num ? (j['safety_score'] as num).toInt() : null,
    );
  }
}

class WeeklyMember {
  const WeeklyMember({
    required this.userId,
    required this.name,
    required this.current,
    required this.previous,
  });

  final String userId;
  final String name;
  final WeekStat current;
  final WeekStat previous;

  factory WeeklyMember.fromJson(Map<String, dynamic> j) => WeeklyMember(
        userId: (j['user_id'] as String?) ?? '',
        name: (j['name'] as String?) ?? '',
        current:
            WeekStat.fromJson((j['current'] as Map<String, dynamic>?) ?? {}),
        previous:
            WeekStat.fromJson((j['previous'] as Map<String, dynamic>?) ?? {}),
      );
}

class WeeklySummary {
  const WeeklySummary({required this.members});
  final List<WeeklyMember> members;

  factory WeeklySummary.fromJson(Map<String, dynamic> j) => WeeklySummary(
        members: <WeeklyMember>[
          for (final dynamic m in (j['members'] as List<dynamic>? ?? <dynamic>[]))
            WeeklyMember.fromJson(m as Map<String, dynamic>),
        ],
      );
}

/// Seam so the screen can be tested with a fake.
abstract class WeeklySummaryApi {
  Future<WeeklySummary> load();
}

class WeeklySummaryService implements WeeklySummaryApi {
  const WeeklySummaryService();

  static const WeeklySummaryApi instance = WeeklySummaryService();

  @override
  Future<WeeklySummary> load() async {
    try {
      final dynamic body = await ApiClient.get(
        '/trips/weekly-summary',
        query: <String, String>{
          'utc_offset_minutes': '${DateTime.now().timeZoneOffset.inMinutes}',
        },
      );
      if (body is! Map<String, dynamic>) {
        throw const TripsException(
            TripsFailure.other, 'Unexpected response from the server.');
      }
      return WeeklySummary.fromJson(body);
    } catch (e) {
      throw mapTripsError(e);
    }
  }
}
