import 'dart:async';

import '../models/emergency_contact.dart';
import 'offline/offline_cache.dart';
import 'offline/offline_errors.dart';
import 'api_client.dart';

/// Client for `GET/POST/DELETE /me/contacts`.
class EmergencyContactService {
  /// Fetches the caller's emergency contacts.
  Future<List<EmergencyContact>> list() async {
    dynamic data;
    try {
      data = await ApiClient.get('/me/contacts');
      unawaited(OfflineCache.instance.write('emergency-contacts', data));
    } catch (e) {
      // Offline: the SOS "text my contacts" fallback needs their numbers on the phone.
      if (!isOfflineError(e)) rethrow;
      final CacheEntry? c = await OfflineCache.instance.read('emergency-contacts');
      if (c == null) rethrow;
      data = c.data;
    }
    if (data is! List) {
      throw const ApiException(0, 'Unexpected contacts response.');
    }
    return data
        .map(
            (dynamic e) => EmergencyContact.fromJson(e as Map<String, dynamic>))
        .where((EmergencyContact c) => c.id.isNotEmpty)
        .toList();
  }

  /// Creates an emergency contact and returns the server copy (with id).
  Future<EmergencyContact> add({
    required String name,
    required String phone,
    String relation = '',
  }) async {
    final Map<String, dynamic> body = <String, dynamic>{
      'name': name,
      'phone': phone,
    };
    if (relation.isNotEmpty) {
      body['relation'] = relation;
    }
    final dynamic data = await ApiClient.post('/me/contacts', body: body);
    if (data is! Map<String, dynamic>) {
      throw const ApiException(0, 'Unexpected contact response.');
    }
    return EmergencyContact.fromJson(data);
  }

  /// Removes an emergency contact by id.
  Future<void> delete(String id) async {
    await ApiClient.delete('/me/contacts/${Uri.encodeComponent(id)}');
  }
}
