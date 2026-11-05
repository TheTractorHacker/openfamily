import '../models/place.dart';
import 'api_client.dart';
import 'notification_prefs_service.dart';
import 'place_service.dart';

/// Which place events the viewer hears about one person at one place.
enum PlaceAlertMode {
  both('both', 'Both'),
  arrivals('arrivals', 'Arrivals only'),
  departures('departures', 'Departures only'),
  off('off', 'Off');

  const PlaceAlertMode(this.wire, this.label);
  final String wire;
  final String label;

  static PlaceAlertMode parse(String? s) => PlaceAlertMode.values.firstWhere(
        (PlaceAlertMode m) => m.wire == s,
        orElse: () => PlaceAlertMode.both,
      );
}

/// The signed-in user's quiet window for place alerts. Emergencies are never
/// held back.
class QuietHours {
  const QuietHours({this.start, this.end});
  final String? start;
  final String? end;
  bool get enabled => start != null && end != null;

  factory QuietHours.fromJson(Map<String, dynamic> j) => QuietHours(
        start: j['quiet_start'] as String?,
        end: j['quiet_end'] as String?,
      );
}

abstract class PlaceAlertRulesService {
  Future<List<Place>> places();
  Future<Map<String, PlaceAlertMode>> rules(String memberId);
  Future<void> setRule(String memberId, String placeId, PlaceAlertMode mode);
  Future<QuietHours> quietHours();
  Future<QuietHours> saveQuietHours(QuietHours q);
}

class ApiPlaceAlertRulesService implements PlaceAlertRulesService {
  const ApiPlaceAlertRulesService();

  @override
  Future<List<Place>> places() => PlaceService.fetchPlaces();

  @override
  Future<Map<String, PlaceAlertMode>> rules(String memberId) async {
    final dynamic r = await ApiClient.get('/members/$memberId/place-alert-rules');
    final List<dynamic> list = ((r as Map<String, dynamic>)['rules'] as List?) ?? <dynamic>[];
    return <String, PlaceAlertMode>{
      for (final dynamic e in list)
        (e as Map<String, dynamic>)['place_id'] as String:
            PlaceAlertMode.parse(e['mode'] as String?),
    };
  }

  @override
  Future<void> setRule(
      String memberId, String placeId, PlaceAlertMode mode) async {
    await ApiClient.put('/members/$memberId/place-alert-rules/$placeId',
        body: <String, dynamic>{'mode': mode.wire});
  }

  @override
  Future<QuietHours> quietHours() async =>
      QuietHours.fromJson(await ApiClient.get('/me/quiet-hours') as Map<String, dynamic>);

  @override
  Future<QuietHours> saveQuietHours(QuietHours q) async => QuietHours.fromJson(
      await ApiClient.put('/me/quiet-hours', body: <String, dynamic>{
        'quiet_start': q.start,
        'quiet_end': q.end,
        'timezone': currentUtcOffsetLabel(),
      }) as Map<String, dynamic>);
}

/// The signed-in user's master switch for arrive/leave alerts about one
/// person ("Get Place Alerts if Brian leaves or arrives"). Default on.
abstract class MemberPlaceAlertsApi {
  Future<bool> enabled(String memberId);
  Future<void> setEnabled(String memberId, bool value);
}

class ApiMemberPlaceAlerts implements MemberPlaceAlertsApi {
  const ApiMemberPlaceAlerts();

  static const MemberPlaceAlertsApi instance = ApiMemberPlaceAlerts();

  @override
  Future<bool> enabled(String memberId) async {
    final dynamic r = await ApiClient.get('/members/$memberId/place-alerts');
    return (r as Map<String, dynamic>)['enabled'] != false;
  }

  @override
  Future<void> setEnabled(String memberId, bool value) async {
    await ApiClient.put('/members/$memberId/place-alerts',
        body: <String, dynamic>{'enabled': value});
  }
}
