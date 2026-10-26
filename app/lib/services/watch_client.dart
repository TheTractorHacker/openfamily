import 'api_client.dart';

/// Tells the server "I am looking at this member right now" so their phone
/// reports about once a second (see docs/live-tracking.md).
///
/// The server lapses a watch after [ttl] without a renewal, so callers renew
/// every [renewEvery] while the map follows a member (or their card is open)
/// and simply stop calling when they stop looking.
class WatchClient {
  const WatchClient({Future<dynamic> Function(String path, {Object? body})? post})
      : _post = post ?? _defaultPost;

  final Future<dynamic> Function(String path, {Object? body}) _post;

  static Future<dynamic> _defaultPost(String path, {Object? body}) =>
      ApiClient.post(path, body: body);

  /// Server-side lapse (45 s) as documented; renewal is well inside it.
  static const Duration ttl = Duration(seconds: 45);
  static const Duration renewEvery = Duration(seconds: 15);

  /// Returns true when the server accepted the watch. Never throws: a failed
  /// watch only means the target keeps its normal cadence.
  Future<bool> watch(String userId, {String? circleId}) async {
    try {
      await _post(
        '/locations/watch',
        body: <String, Object?>{
          'user_id': userId,
          if (circleId != null && circleId != 'all') 'circle_id': circleId,
        },
      );
      return true;
    } catch (_) {
      return false;
    }
  }
}
