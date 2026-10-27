import 'package:latlong2/latlong.dart';

import 'api_client.dart';

/// One downsampled GPS sample on a member's trail.
class HistoryTrailPoint {
  const HistoryTrailPoint({
    required this.position,
    required this.ts,
    this.motionState = '',
    this.speedMps,
    this.batteryPct,
  });

  final LatLng position;
  final DateTime ts;
  final String motionState;

  /// Device-reported speed in m/s, null when the device didn't report one.
  final double? speedMps;

  /// Device battery 0-100, null when unknown.
  final double? batteryPct;
}

/// A named place stay, unnamed dwell, or in-transit segment.
class HistoryVisit {
  const HistoryVisit({
    required this.arrivedAt,
    required this.departedAt,
    required this.position,
    required this.placeName,
    required this.kind,
    this.placeId,
    this.placeType = '',
  });

  final DateTime arrivedAt;
  final DateTime departedAt;
  final LatLng position;
  final String? placeId;
  final String placeName;
  final String placeType;
  final String kind;

  bool get isStop => kind == 'stop';
  bool get isPlace => kind == 'place';
  bool get isTransit => kind == 'transit';
}

/// One day's history for a family member.
class MemberHistory {
  const MemberHistory({
    required this.userId,
    required this.from,
    required this.to,
    required this.trail,
    required this.visits,
  });

  final String userId;
  final DateTime from;
  final DateTime to;
  final List<HistoryTrailPoint> trail;
  final List<HistoryVisit> visits;

  bool get isEmpty => trail.isEmpty && visits.isEmpty;
}

/// Fetches location history for a family member.
class HistoryService {
  HistoryService._();

  static Future<MemberHistory> fetchDay({
    required String memberId,
    required DateTime day,
  }) async {
    final DateTime start = DateTime(day.year, day.month, day.day);
    final DateTime end = DateTime(day.year, day.month, day.day + 1);
    final dynamic data = await ApiClient.get(
      '/family/members/$memberId/history',
      query: <String, String>{
        'from': start.toUtc().toIso8601String(),
        'to': end.toUtc().toIso8601String(),
      },
    );
    if (data is! Map<String, dynamic>) {
      throw const ApiException(0, 'Unexpected history response.');
    }
    return _fromBackend(data);
  }

  static MemberHistory _fromBackend(Map<String, dynamic> json) {
    final List<HistoryTrailPoint> trail = <HistoryTrailPoint>[];
    final dynamic rawTrail = json['trail'];
    if (rawTrail is List) {
      for (final dynamic item in rawTrail) {
        if (item is! Map<String, dynamic>) continue;
        final num? lat = item['lat'] as num?;
        final num? lon = item['lon'] as num?;
        final DateTime? ts = _parseTime(item['ts']);
        if (lat == null || lon == null || ts == null) continue;
        trail.add(
          HistoryTrailPoint(
            position: LatLng(lat.toDouble(), lon.toDouble()),
            ts: ts,
            motionState: item['motion_state'] as String? ?? '',
            speedMps: (item['speed_mps'] as num?)?.toDouble(),
            batteryPct: (item['battery_pct'] as num?)?.toDouble(),
          ),
        );
      }
    }

    final List<HistoryVisit> visits = <HistoryVisit>[];
    final dynamic rawVisits = json['visits'];
    if (rawVisits is List) {
      for (final dynamic item in rawVisits) {
        if (item is! Map<String, dynamic>) continue;
        final DateTime? arrived = _parseTime(item['arrived_at']);
        final DateTime? departed = _parseTime(item['departed_at']);
        final num? lat = item['lat'] as num?;
        final num? lon = item['lon'] as num?;
        final String? name = item['place_name'] as String?;
        final String? kind = item['kind'] as String?;
        if (arrived == null ||
            departed == null ||
            lat == null ||
            lon == null ||
            name == null ||
            kind == null) {
          continue;
        }
        visits.add(
          HistoryVisit(
            arrivedAt: arrived,
            departedAt: departed,
            position: LatLng(lat.toDouble(), lon.toDouble()),
            placeId: item['place_id'] as String?,
            placeName: name,
            placeType: item['place_type'] as String? ?? '',
            kind: kind,
          ),
        );
      }
    }

    return MemberHistory(
      userId: json['user_id'] as String? ?? '',
      from: _parseTime(json['from']) ?? DateTime.fromMillisecondsSinceEpoch(0),
      to: _parseTime(json['to']) ?? DateTime.fromMillisecondsSinceEpoch(0),
      trail: trail,
      visits: visits,
    );
  }

  static DateTime? _parseTime(dynamic value) {
    if (value is! String || value.isEmpty) return null;
    return DateTime.tryParse(value);
  }
}
