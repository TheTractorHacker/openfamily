import 'dart:convert';

import '../e2ee/e2ee_crypto.dart';
import '../e2ee/lanes_service.dart' show MemberLaneView;
import '../e2ee/private_channel.dart';
import 'result_items.dart';

// The data-access layer of screens that mix sources (PRIVACY_PROCESSING 8.4,
// risk 9): for each member it says WHERE the figures come from, derived from
// the member's VERIFIED lane, and returns them from the right place:
//
//   server-assisted member  -> the server reader (REST: trips, weekly summary)
//   phone-only member       -> result items their phone published (this store)
//   phone-only, nothing yet -> an explicit placeholder, never an empty screen
//
// Full screens are a later phase; they should only need this class.

/// Verified result items from members' phones, kept on this phone.
class ResultStore {
  ResultStore(this.kv, {this.keepPerKind = 60});
  final ChannelKv kv;
  final int keepPerKind;

  String _key(String circle, String user, String kind) => 'res/$circle/$user/$kind';
  String _upd(String circle, String user) => 'res/$circle/$user/upd';

  /// Stores [r] if it is a well formed result of its kind. The author is the
  /// verified sender of the item, never a field of the body. The newest
  /// (signed time, then seq) item per id / week wins.
  Future<bool> put(ReceivedItem r) async {
    if (!ChannelPurpose.results.contains(r.purpose)) return false;
    final String? id = switch (r.purpose) {
      ChannelPurpose.trip => TripResult.tryParse(r.body)?.id,
      ChannelPurpose.drive => DriveResult.tryParse(r.body)?.tripId,
      ChannelPurpose.week => WeekResult.tryParse(r.body)?.weekStartMs.toString(),
      _ => null,
    };
    if (id == null) return false;
    final String k = _key(r.circleId, r.userId, r.purpose);
    final List<Map<String, dynamic>> l = await _load(k);
    final int at = r.ts.millisecondsSinceEpoch;
    final int i = l.indexWhere((Map<String, dynamic> m) => m['i'] == id);
    if (i >= 0) {
      final int oldAt = (l[i]['t'] as num).toInt(), oldSeq = (l[i]['q'] as num).toInt();
      if (at < oldAt || (at == oldAt && r.seq <= oldSeq)) return true; // an older copy: ignore
      l.removeAt(i);
    }
    l.add(<String, dynamic>{'i': id, 't': at, 'q': r.seq, 'b': r.body});
    l.sort((Map<String, dynamic> a, Map<String, dynamic> b) => (a['t'] as num).compareTo(b['t'] as num));
    final List<Map<String, dynamic>> kept = l.length > keepPerKind ? l.sublist(l.length - keepPerKind) : l;
    await kv.set(k, jsonEncode(kept));
    final int prev = int.tryParse(await kv.get(_upd(r.circleId, r.userId)) ?? '') ?? 0;
    if (at > prev) await kv.set(_upd(r.circleId, r.userId), '$at');
    return true;
  }

  Future<List<Map<String, dynamic>>> _load(String key) async {
    final String? raw = await kv.get(key);
    if (raw == null || raw.isEmpty) return <Map<String, dynamic>>[];
    try {
      return (jsonDecode(raw) as List<dynamic>).cast<Map<String, dynamic>>();
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  Future<List<T>> _all<T>(String circle, String user, String kind, T? Function(Object?) parse) async => <T>[
        for (final Map<String, dynamic> m in await _load(_key(circle, user, kind)))
          if (parse(m['b']) case final T x) x
      ];

  Future<List<TripResult>> trips(String circle, String user) async =>
      (await _all<TripResult>(circle, user, ChannelPurpose.trip, TripResult.tryParse))..sort((TripResult a, TripResult b) => b.startMs.compareTo(a.startMs));

  Future<List<DriveResult>> drives(String circle, String user) => _all<DriveResult>(circle, user, ChannelPurpose.drive, DriveResult.tryParse);

  Future<List<WeekResult>> weeks(String circle, String user) async =>
      (await _all<WeekResult>(circle, user, ChannelPurpose.week, WeekResult.tryParse))..sort((WeekResult a, WeekResult b) => b.weekStartMs.compareTo(a.weekStartMs));

  /// When the newest result of [user] was signed, if any.
  Future<DateTime?> updatedAt(String circle, String user) async {
    final int? ms = int.tryParse(await kv.get(_upd(circle, user)) ?? '');
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  }
}

/// Thin read-side of the server for server-assisted members (REST in the app,
/// a fake in tests). Only asked for members whose verified lane is server.
abstract class ServerProcessingReader {
  Future<List<TripResult>> trips(String circleId, String userId, DateTime from, DateTime to);
  Future<WeekResult?> week(String circleId, String userId, int weekStartMs);
}

enum ProcessingOrigin {
  /// Computed by the server (the member opted in, verified from their signed pref).
  server,

  /// Computed on the member's own phone and shared as sealed result items.
  phone,
}

enum PlaceholderReason {
  /// A phone-only member whose phone has not shared figures yet (phone off?).
  notSharedYet,

  /// A server-assisted member but the server could not be reached.
  serverUnavailable,
}

class MemberProcessing {
  const MemberProcessing({
    required this.userId,
    required this.origin,
    this.trips = const <TripResult>[],
    this.drives = const <DriveResult>[],
    this.weeks = const <WeekResult>[],
    this.updatedAt,
    this.placeholder,
  });
  final String userId;
  final ProcessingOrigin origin;
  final List<TripResult> trips;
  final List<DriveResult> drives;
  final List<WeekResult> weeks;

  /// Phone-only: when their phone last shared something ("Updated 2 h ago").
  final DateTime? updatedAt;

  /// Non-null when there is nothing to show yet and why. Never silently empty.
  final PlaceholderReason? placeholder;
}

class ProcessingSource {
  ProcessingSource({required this.memberLanes, required this.results, this.server});

  /// Verified lane per member (e.g. `LanesService.members`).
  final Future<List<MemberLaneView>> Function(String circleId) memberLanes;
  final ResultStore results;
  final ServerProcessingReader? server;

  Future<List<MemberProcessing>> load(String circleId, {required DateTime from, required DateTime to}) async {
    final List<MemberProcessing> out = <MemberProcessing>[];
    for (final MemberLaneView m in await memberLanes(circleId)) {
      if (m.lane == E2ee.lineServer) {
        // Server-assisted: the server holds readable data and computes it.
        try {
          final ServerProcessingReader? s = server;
          if (s == null) throw StateError('no server reader');
          final List<TripResult> t = await s.trips(circleId, m.userId, from, to);
          out.add(MemberProcessing(userId: m.userId, origin: ProcessingOrigin.server, trips: t));
        } catch (_) {
          out.add(MemberProcessing(userId: m.userId, origin: ProcessingOrigin.server, placeholder: PlaceholderReason.serverUnavailable));
        }
        continue;
      }
      final List<TripResult> trips = (await results.trips(circleId, m.userId))
          .where((TripResult t) => t.startMs >= from.millisecondsSinceEpoch && t.startMs < to.millisecondsSinceEpoch)
          .toList();
      final List<WeekResult> weeks = await results.weeks(circleId, m.userId);
      final DateTime? upd = await results.updatedAt(circleId, m.userId);
      out.add(MemberProcessing(
        userId: m.userId,
        origin: ProcessingOrigin.phone,
        trips: trips,
        drives: await results.drives(circleId, m.userId),
        weeks: weeks,
        updatedAt: upd,
        placeholder: upd == null ? PlaceholderReason.notSharedYet : null,
      ));
    }
    return out;
  }
}
