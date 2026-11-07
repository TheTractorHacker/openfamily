import 'dart:async';
import 'dart:convert';

import '../e2ee/private_channel.dart' show ChannelKv;
import 'driving_events.dart';
import 'driving_report.dart';
import 'fix.dart';
import 'processing_params.dart';
import 'result_items.dart';
import 'trip_segmenter.dart';

/// Publishes one finished result as a sealed item in the author's OWN lane.
/// The sealer (not this class) picks the lane from the member's signed pref.
typedef ResultSink = Future<void> Function(String kind, Map<String, dynamic> body);

/// Wires the Phase 0 on-device processors into the phone's channel
/// (PRIVACY_PROCESSING 8.4): fixes in, `trip` / `drive` / `week` items out.
/// Used only for circles where the member is phone-only; the server does the
/// same work for server-assisted members.
///
/// Memory: the [TripSegmenter] keeps only the current stop and trip. Restart:
/// the buffers are rebuilt with [restore] from the local history (derived
/// speeds, so a restored trip can differ slightly from a live one); results are
/// de-duplicated by deterministic id so a replay never publishes twice.
/// Never logs coordinates.
class OnDeviceProcessor {
  OnDeviceProcessor({
    required this.kv,
    required this.userId,
    required this.publish,
    DateTime Function()? now,
    this.params = const TripParams(),
    this.eventParams = const EventParams(),
    this.keepDays = 21,
    this.maxDriveJsonBytes = 3600,
  })  : _now = now ?? (() => DateTime.now().toUtc()),
        _seg = TripSegmenter(params: params, eventParams: eventParams);

  final ChannelKv kv;
  final String userId;
  final ResultSink publish;
  final DateTime Function() _now;
  final TripParams params;
  final EventParams eventParams;
  final int keepDays;

  /// Largest JSON of a `drive` body (the sealed item must fit its 4096 byte bucket).
  final int maxDriveJsonBytes;

  final TripSegmenter _seg;
  Future<void> _lock = Future<void>.value();

  String get _key => 'proc/state/$userId';

  Future<T> _locked<T>(Future<T> Function() f) {
    final Completer<T> c = Completer<T>();
    _lock = _lock.then((_) async {
      try {
        c.complete(await f());
      } catch (e, st) {
        c.completeError(e, st);
      }
    });
    return c.future;
  }

  Future<_State> _load() async {
    final String? raw = await kv.get(_key);
    if (raw == null || raw.isEmpty) return _State();
    try {
      return _State.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return _State();
    }
  }

  Future<void> _save(_State s) => kv.set(_key, jsonEncode(s.toJson()));

  /// Feeds fixes that were already seen (from the local history) without
  /// publishing anything for trips that were published before.
  Future<int> restore(Iterable<Fix> fixes) => _locked(() async {
        _seg.addAll(fixes);
        return _drain(await _load());
      });

  /// Feeds one live fix; returns the number of result items published.
  Future<int> onFix(Fix f) => _locked(() async {
        _seg.add(f);
        return _drain(await _load());
      });

  /// Ends the input (app stops / long gap) and publishes an open trip.
  Future<int> finish() => _locked(() async {
        final SegmentResult r = _seg.finish();
        return _publishAll(await _load(), r.trips);
      });

  Future<int> _drain(_State st) async {
    final ({List<ProcessedTrip> trips, List<ProcessedStop> stops}) n = _seg.takeNew();
    return _publishAll(st, n.trips);
  }

  Future<int> _publishAll(_State st, List<ProcessedTrip> trips) async {
    int published = 0;
    final Set<int> weeks = <int>{};
    for (final ProcessedTrip t in trips) {
      final String id = TripResult.idFor(t.startedAtUs);
      if (st.published.contains(id)) continue;
      st.published.add(id);
      st.trips[id] = _StoredTrip(
        id: id,
        startedAtUs: t.startedAtUs,
        endedAtUs: t.endedAtUs,
        distanceM: t.distanceM,
        maxSpeedMps: t.maxSpeedMps,
        mode: t.mode,
        events: <(String, int)>[for (final DrivingEvent e in t.events) (e.kind, e.startedAtUs)],
      );
      await publish(kKindTrip, TripResult.of(t).toBody());
      published++;
      if (t.mode == kModeDriving) {
        await publish(kKindDrive, DriveResult.of(t).fitBody(maxDriveJsonBytes));
        published++;
      }
      weeks.add(_weekStartUs(t.startedAtUs));
    }
    for (final int w in weeks) {
      await publish(kKindWeek, _week(st, w).toBody());
      published++;
    }
    _prune(st);
    await _save(st);
    return published;
  }

  /// Publishes the finished week once its due time (Sunday 18:00 UTC) passed.
  /// Idempotent. Returns whether an item was published.
  Future<bool> tickWeekly() => _locked(() async {
        final _State st = await _load();
        final ({int weekStartUs, int dueUs}) due = weeklyDue(_now().microsecondsSinceEpoch);
        if (st.weekDone >= due.weekStartUs) return false;
        st.weekDone = due.weekStartUs;
        final WeekResult w = _week(st, due.weekStartUs);
        // A week without any trip (this one or the one before) is not worth an upload; a
        // phone that never drove sends nothing at all.
        final bool any = w.current.drives > 0 || w.previous.drives > 0 || st.trips.isNotEmpty;
        if (any) await publish(kKindWeek, w.toBody());
        await _save(st);
        return any;
      });

  WeekResult _week(_State st, int weekStartUs) {
    final List<TripSummary> ts = <TripSummary>[
      for (final _StoredTrip t in st.trips.values)
        TripSummary(startedAtUs: t.startedAtUs, endedAtUs: t.endedAtUs, distanceM: t.distanceM, maxSpeedMps: t.maxSpeedMps, mode: t.mode, id: t.id)
    ];
    final List<DrivingEvent> es = <DrivingEvent>[
      for (final _StoredTrip t in st.trips.values)
        for (final (String, int) e in t.events) DrivingEvent(kind: e.$1, startedAtUs: e.$2, endedAtUs: e.$2, magnitude: 0, lat: 0, lon: 0)
    ];
    return WeekResult.compute(ts, es, weekStartUs);
  }

  static int _weekStartUs(int us) {
    final DateTime d = DateTime.fromMicrosecondsSinceEpoch(us, isUtc: true);
    final DateTime day = DateTime.utc(d.year, d.month, d.day);
    return DateTime.utc(day.year, day.month, day.day - (day.weekday - 1)).microsecondsSinceEpoch;
  }

  void _prune(_State st) {
    final int cut = _now().subtract(Duration(days: keepDays)).microsecondsSinceEpoch;
    st.trips.removeWhere((String _, _StoredTrip t) => t.startedAtUs < cut);
    if (st.published.length > 600) st.published = st.published.sublist(st.published.length - 600);
  }
}

class _StoredTrip {
  _StoredTrip({required this.id, required this.startedAtUs, required this.endedAtUs, required this.distanceM, required this.maxSpeedMps, required this.mode, required this.events});
  final String id;
  final int startedAtUs, endedAtUs;
  final double distanceM, maxSpeedMps;
  final String mode;
  final List<(String, int)> events;

  List<dynamic> toJson() => <dynamic>[
        id, startedAtUs, endedAtUs, distanceM, maxSpeedMps, mode,
        <List<dynamic>>[for (final (String, int) e in events) <dynamic>[e.$1, e.$2]],
      ];

  static _StoredTrip? fromJson(Object? j) {
    if (j is! List || j.length != 7) return null;
    try {
      return _StoredTrip(
        id: j[0] as String,
        startedAtUs: (j[1] as num).toInt(),
        endedAtUs: (j[2] as num).toInt(),
        distanceM: (j[3] as num).toDouble(),
        maxSpeedMps: (j[4] as num).toDouble(),
        mode: j[5] as String,
        events: <(String, int)>[for (final dynamic e in j[6] as List<dynamic>) ((e as List<dynamic>)[0] as String, (e[1] as num).toInt())],
      );
    } catch (_) {
      return null;
    }
  }
}

class _State {
  _State();
  List<String> published = <String>[];
  final Map<String, _StoredTrip> trips = <String, _StoredTrip>{};
  int weekDone = 0;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'pub': published,
        'wk': weekDone,
        'trips': <dynamic>[for (final _StoredTrip t in trips.values) t.toJson()],
      };

  factory _State.fromJson(Map<String, dynamic> j) {
    final _State s = _State();
    s.published = ((j['pub'] as List<dynamic>?) ?? <dynamic>[]).whereType<String>().toList();
    s.weekDone = (j['wk'] as num?)?.toInt() ?? 0;
    for (final dynamic t in (j['trips'] as List<dynamic>?) ?? <dynamic>[]) {
      final _StoredTrip? x = _StoredTrip.fromJson(t);
      if (x != null) s.trips[x.id] = x;
    }
    return s;
  }
}
