import 'dart:async';

import '../models/circle.dart';
import 'api_client.dart';

export 'api_client.dart' show SessionExpiredException;

/// A failure from the circles API, already worded for the user.
class CircleException implements Exception {
  const CircleException(this.message, {this.status = 0, this.offline = false});

  final String message;

  /// HTTP status, or 0 when the request never got a response.
  final int status;

  /// True when the device could not reach the server at all.
  final bool offline;

  @override
  String toString() => 'CircleException($status): $message';
}

/// Converts any thrown object into a [CircleException]. Server messages are
/// shown verbatim (they explain refusals such as "cannot remove or leave as
/// the last admin"); transport failures become a friendly offline message.
CircleException describeCircleError(Object error) {
  if (error is CircleException) return error;
  if (error is ApiException) {
    if (error.status == 0) return CircleException(error.message);
    return CircleException(error.message, status: error.status);
  }
  if (error is SessionExpiredException) {
    return CircleException(error.message, status: 401);
  }
  return const CircleException(
    'Can\'t reach the server. Check your connection and try again.',
    offline: true,
  );
}

/// Circles operations used by the circle screens. Abstract so widget tests can
/// supply a fake.
abstract class CircleService {
  /// The service the screens use unless one is injected.
  static CircleService instance = ApiCircleService();

  Future<String> myUserId();
  Future<List<Circle>> listCircles();
  Future<Circle> createCircle(String name, String? icon, {int? durationHours});
  Future<void> updateCircle(String id, {String? name, String? icon});

  /// Deletes a circle. Without [force] the server refuses (409) when it is
  /// the only circle of some member.
  Future<void> deleteCircle(String id, {bool force = false});

  /// Temporary circles (admin): add [hours] to the expiry, or end it now.
  Future<Circle> extendCircle(String id, int hours);
  Future<void> endCircle(String id);

  Future<List<CircleMember>> listMembers(String id);

  /// Removes [userId] from the circle; pass `me` to leave.
  Future<void> removeMember(String id, String userId);
  Future<void> setRole(String id, String userId, String role);
  Future<void> setSharing(String id, bool enabled);
  Future<List<CircleInvite>> listInvites(String id);
  Future<CircleInvite> createInvite(String id);
  Future<void> revokeInvite(String id, String inviteId);
  Future<String> joinCircle(String code);
}

/// [CircleService] backed by the real backend through [ApiClient].
class ApiCircleService implements CircleService {
  Future<T> _wrap<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on SessionExpiredException {
      rethrow;
    } catch (e) {
      throw describeCircleError(e);
    }
  }

  static List<Map<String, dynamic>> _rows(dynamic raw) => raw is List
      ? raw.whereType<Map<String, dynamic>>().toList()
      : <Map<String, dynamic>>[];

  @override
  Future<String> myUserId() =>
      _wrap(() async => (await ApiClient.getProfile()).id);

  @override
  Future<List<Circle>> listCircles() => _wrap(() async =>
      _rows(await ApiClient.get('/circles')).map(Circle.fromJson).toList());

  @override
  Future<Circle> createCircle(String name, String? icon,
          {int? durationHours}) =>
      _wrap(() async => Circle.fromJson(await ApiClient.post('/circles',
          body: <String, dynamic>{
            'name': name,
            if (icon != null && icon.isNotEmpty) 'icon': icon,
            if (durationHours != null) 'duration_hours': durationHours,
          }) as Map<String, dynamic>));

  @override
  Future<Circle> extendCircle(String id, int hours) =>
      _wrap(() async => Circle.fromJson(await ApiClient.patch('/circles/$id',
          body: <String, dynamic>{'extend_hours': hours}) as Map<String, dynamic>));

  @override
  Future<void> endCircle(String id) => _wrap(() =>
      ApiClient.patch('/circles/$id', body: <String, dynamic>{'end': true}));

  @override
  Future<void> updateCircle(String id, {String? name, String? icon}) =>
      _wrap(() => ApiClient.patch('/circles/$id', body: <String, dynamic>{
            if (name != null) 'name': name,
            if (icon != null) 'icon': icon,
          }));

  @override
  Future<void> deleteCircle(String id, {bool force = false}) =>
      _wrap(() => ApiClient.delete('/circles/$id${force ? '?force=true' : ''}'));

  @override
  Future<List<CircleMember>> listMembers(String id) => _wrap(() async =>
      _rows(await ApiClient.get('/circles/$id/members'))
          .map(CircleMember.fromJson)
          .toList());

  @override
  Future<void> removeMember(String id, String userId) =>
      _wrap(() => ApiClient.delete('/circles/$id/members/$userId'));

  @override
  Future<void> setRole(String id, String userId, String role) => _wrap(() =>
      ApiClient.patch('/circles/$id/members/$userId',
          body: <String, dynamic>{'role': role}));

  @override
  Future<void> setSharing(String id, bool enabled) =>
      _wrap(() => ApiClient.putJson('/circles/$id/sharing',
          body: <String, dynamic>{'enabled': enabled}));

  @override
  Future<List<CircleInvite>> listInvites(String id) => _wrap(() async =>
      _rows(await ApiClient.get('/circles/$id/invites'))
          .map(CircleInvite.fromJson)
          .toList());

  @override
  Future<CircleInvite> createInvite(String id) => _wrap(() async =>
      CircleInvite.fromJson(await ApiClient.post('/circles/$id/invites',
          body: <String, dynamic>{'role': 'member', 'max_uses': 5}) as Map<String, dynamic>));

  @override
  Future<void> revokeInvite(String id, String inviteId) =>
      _wrap(() => ApiClient.delete('/circles/$id/invites/$inviteId'));

  @override
  Future<String> joinCircle(String code) => _wrap(() async {
        final dynamic data = await ApiClient.post('/circles/join',
            body: <String, dynamic>{'code': code});
        return (data as Map<String, dynamic>)['circle_id'] as String? ?? '';
      });
}
