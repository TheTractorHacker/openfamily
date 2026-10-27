import 'package:flutter/foundation.dart';

import '../models/bubble.dart';
import 'api_client.dart';

/// Thin wrapper over the /bubbles endpoints (docs/bubbles.md). Screens take
/// one so tests can fake it.
abstract class BubbleService {
  Future<BubbleList> list();

  Future<Bubble> create({
    required String subjectId,
    required int radiusM,
    required int durationMinutes,
    bool notifyReenter = false,
  });

  Future<void> cancel(String id);
}

class ApiBubbleService implements BubbleService {
  const ApiBubbleService();

  @override
  Future<BubbleList> list() async {
    final dynamic r = await ApiClient.get('/bubbles');
    return BubbleList.fromJson(r is Map<String, dynamic> ? r : <String, dynamic>{});
  }

  @override
  Future<Bubble> create({
    required String subjectId,
    required int radiusM,
    required int durationMinutes,
    bool notifyReenter = false,
  }) async {
    final dynamic r = await ApiClient.post('/bubbles', body: <String, dynamic>{
      'subject_id': subjectId,
      'radius_m': radiusM,
      'duration_minutes': durationMinutes,
      'notify_reenter': notifyReenter,
    });
    return Bubble.fromJson(r as Map<String, dynamic>);
  }

  @override
  Future<void> cancel(String id) async {
    await ApiClient.delete('/bubbles/${Uri.encodeComponent(id)}');
  }
}

/// The caller's active Bubbles, shared so the map can draw them and the
/// Bubble screens can refresh them. Only the creator ever gets geometry.
class BubbleStore {
  BubbleStore._();

  static final BubbleStore instance = BubbleStore._();

  final ValueNotifier<List<Bubble>> mine = ValueNotifier<List<Bubble>>(const <Bubble>[]);

  Future<void> refresh([BubbleService service = const ApiBubbleService()]) async {
    try {
      final BubbleList l = (await service.list()).withoutExpired(DateTime.now());
      mine.value = l.mine;
    } catch (_) {
      // The map works without Bubbles; keep what we had.
    }
  }

  void set(List<Bubble> bubbles) => mine.value = bubbles;
}

/// Friendly text for a failed Bubble call.
String bubbleErrorMessage(Object e, {String action = 'do that'}) {
  if (e is ApiException) {
    if (e.status == 404) {
      return 'You can only make a Bubble around someone who is sharing '
          'their location with you right now.';
    }
    if (e.status == 409) {
      return 'There is no recent location for this person yet. Try again '
          'once their location updates.';
    }
    if (e.status == 429) return 'You have too many active Bubbles. Cancel one first.';
    if (e.status == 400) return 'You cannot make a Bubble around yourself.';
    if (e.status >= 500) return 'The server had a problem. Try again shortly.';
  }
  return 'Could not $action. Check your connection and try again.';
}
