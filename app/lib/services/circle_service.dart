import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import '../models/circle.dart';
import 'api_client.dart';
import 'app_compat.dart';
import 'e2ee/e2ee_service.dart' show LocalKeyException, LocalKeyProblem, localKeyProblemOf;
import 'offline/offline_cache.dart';
import 'offline/offline_errors.dart';
import 'session_diary.dart';

export 'api_client.dart' show SessionExpiredException;

/// A failure from the circles API, already worded for the user.
class CircleException implements Exception {
  const CircleException(this.message, {this.status = 0, this.offline = false, this.keyProblem});

  final String message;

  /// Set when the failure is this phone's own encryption key (the screen offers
  /// "Encryption keys" to repair it).
  final LocalKeyProblem? keyProblem;

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
///
/// Only a real transport failure may say "can't reach the server". A failure
/// on the phone itself (this phone's encryption key, the Keystore, a parse or
/// programming error) gets its own short reason, and its type is logged so a
/// diagnostics report shows what actually happened.
CircleException describeCircleError(Object error) {
  if (error is CircleException) return error;
  if (error is ApiException) {
    if (error.status == 0) return CircleException(error.message);
    return CircleException(error.message, status: error.status);
  }
  if (error is SessionExpiredException) {
    return CircleException(error.message, status: 401);
  }
  final LocalKeyException? key = localKeyProblemOf(error);
  if (key != null) {
    _logCircleError(error, key.problem.name);
    return CircleException(key.message, keyProblem: key.problem);
  }
  if (isOfflineError(error)) {
    return const CircleException(
      'Can\'t reach the server. Check your connection and try again.',
      offline: true,
    );
  }
  _logCircleError(error, 'unexpected');
  return CircleException(
    'Something went wrong on this phone (${error.runtimeType}). Try again, and if it keeps happening send a diagnostics report.',
  );
}

/// Type only: an exception's text can carry server data or file paths.
void _logCircleError(Object error, String kind) {
  final String type = error is LocalKeyException ? error.toString() : error.runtimeType.toString();
  debugPrint('circle action failed on the phone: $kind ($type)');
  SessionDiary.instance.record('circle_error', '$kind $type');
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
  Future<List<Circle>> listCircles() => _wrap(() async {
        // Offline: the circle list this phone last saw, so the switcher and the map scope work.
        dynamic raw;
        try {
          raw = await ApiClient.get('/circles');
          unawaited(OfflineCache.instance.write('circles', raw));
        } catch (e) {
          if (!isOfflineError(e)) rethrow;
          final CacheEntry? c = await OfflineCache.instance.read('circles');
          if (c == null) rethrow;
          raw = c.data;
        }
        final List<Circle> list = _rows(raw).map(Circle.fromJson).toList();
        AppCompat.noteCircles(list.map((Circle c) => c.needsNewerApp),
            names: <String>[for (final Circle c in list) if (c.needsNewerApp) c.name]);
        return list;
      });

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
