import 'api_client.dart';
import 'api_wire.dart';

/// Keeps a local list in step with a server list using `?since=` deltas
/// (docs/developers/api-efficiency.md). Thin on purpose: the screens and the
/// services that own state decide when to call [refresh]; this class only
/// knows how to ask for, and merge, only what changed.
///
/// Works against any server: one that does not know `since` simply answers
/// with the whole array, which is treated as a full replace. A cursor older
/// than 15 minutes, or a changed set of people, makes the server answer
/// `full: true`, so the merge can never drift.
class DeltaSync {
  DeltaSync({
    required this.path,
    Map<String, String> query = const <String, String>{},
    Future<dynamic> Function(String path, Map<String, String> query)? fetch,
  })  : _query = query,
        _fetch = fetch ??
            ((String p, Map<String, String> q) => ApiClient.get(p, query: q));

  final String path;
  final Map<String, String> _query;
  final Future<dynamic> Function(String path, Map<String, String> query) _fetch;

  String? _cursor;
  List<Map<String, dynamic>> _items = <Map<String, dynamic>>[];

  /// Latest merged list.
  List<Map<String, dynamic>> get items => _items;

  /// Opaque server cursor of the last sync, or null before the first one.
  String? get cursor => _cursor;

  /// Whether the last [refresh] was a delta (true) or a full list (false).
  bool lastWasDelta = false;

  /// Forget the cursor and local list (circle switch, sign-out).
  void reset() {
    _cursor = null;
    _items = <Map<String, dynamic>>[];
    lastWasDelta = false;
  }

  /// Fetches the changes since the last call and returns the merged list.
  Future<List<Map<String, dynamic>>> refresh() async {
    final dynamic r = await _fetch(path, <String, String>{
      ..._query,
      'since': _cursor ?? 'none',
    });
    if (r is List<dynamic>) {
      // Older server: the whole list, no cursor.
      _items = <Map<String, dynamic>>[
        for (final dynamic e in r) Map<String, dynamic>.from(e as Map<dynamic, dynamic>),
      ];
      _cursor = null;
      lastWasDelta = false;
      return _items;
    }
    final Map<String, dynamic> m = r as Map<String, dynamic>;
    lastWasDelta = m['full'] != true;
    _items = mergeDelta(_items, m);
    final Object? c = m['cursor'];
    _cursor = c is String && c.isNotEmpty ? c : null;
    return _items;
  }
}
