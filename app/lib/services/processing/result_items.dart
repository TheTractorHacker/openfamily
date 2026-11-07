import 'dart:convert';

import 'driving_events.dart';
import 'driving_report.dart';
import 'processing_params.dart';
import 'trip_segmenter.dart';

// Result item kinds of on-device processing (PRIVACY_PROCESSING 8.4). A
// phone-only member's phone computes trips, driving figures and the weekly
// summary and publishes them as small sealed items in its OWN lane. The kinds
// equal the channel purposes `trip`, `drive`, `week`.
//
// Bodies are compact JSON. They carry coordinates (a trip's start and end), so
// they only ever travel sealed and are never logged. Parsers validate every
// field and return null for anything out of range (a hostile member could send
// anything).

const String kKindTrip = 'trip';
const String kKindDrive = 'drive';
const String kKindWeek = 'week';
const List<String> kResultKinds = <String>[kKindTrip, kKindDrive, kKindWeek];

double _r1(double v) => (v * 10).roundToDouble() / 10;
double _r5(double v) => (v * 100000).roundToDouble() / 100000;

bool _okLat(num? v) => v != null && v >= -90 && v <= 90;
bool _okLon(num? v) => v != null && v >= -180 && v <= 180;
bool _okTime(num? v) => v != null && v > 0 && v < 4102444800000; // before year 2100

/// A finished trip leg.
class TripResult {
  const TripResult({
    required this.id,
    required this.startMs,
    required this.endMs,
    required this.distanceM,
    required this.maxSpeedMps,
    required this.avgSpeedMps,
    required this.mode,
    required this.startLat,
    required this.startLon,
    required this.endLat,
    required this.endLon,
  });

  /// Deterministic per (member, start) so a re-publish replaces instead of duplicating.
  static String idFor(int startedAtUs) => 'p${(startedAtUs ~/ 1000).toRadixString(36)}';

  factory TripResult.of(ProcessedTrip t) => TripResult(
        id: idFor(t.startedAtUs),
        startMs: t.startedAtUs ~/ 1000,
        endMs: t.endedAtUs ~/ 1000,
        distanceM: t.distanceM,
        maxSpeedMps: t.maxSpeedMps,
        avgSpeedMps: t.avgSpeedMps,
        mode: t.mode,
        startLat: t.startLat,
        startLon: t.startLon,
        endLat: t.endLat,
        endLon: t.endLon,
      );

  final String id;
  final int startMs;
  final int endMs;
  final double distanceM;
  final double maxSpeedMps;
  final double avgSpeedMps;
  final String mode;
  final double startLat, startLon, endLat, endLon;

  double get durationS => (endMs - startMs) / 1000;

  Map<String, dynamic> toBody() => <String, dynamic>{
        'id': id,
        's': startMs,
        'e': endMs,
        'dist': _r1(distanceM),
        'dur': durationS.round(),
        'max': _r1(maxSpeedMps),
        'avg': _r1(avgSpeedMps),
        'mode': mode,
        'sl': _r5(startLat),
        'sn': _r5(startLon),
        'el': _r5(endLat),
        'en': _r5(endLon),
      };

  static const List<String> _modes = <String>[kModeDriving, kModeWalking, kModeOther];

  static TripResult? tryParse(Object? j) {
    if (j is! Map<String, dynamic>) return null;
    try {
      final String id = j['id'] as String;
      final num s = j['s'] as num, e = j['e'] as num, dist = j['dist'] as num;
      final String mode = j['mode'] as String;
      if (id.isEmpty || id.length > 40 || !_okTime(s) || !_okTime(e) || e < s) return null;
      if (!_modes.contains(mode) || dist < 0 || dist > 5e7) return null;
      final num mx = (j['max'] as num?) ?? 0, av = (j['avg'] as num?) ?? 0;
      if (mx < 0 || mx > 400 || av < 0 || av > 400) return null;
      final num sl = j['sl'] as num, sn = j['sn'] as num, el = j['el'] as num, en = j['en'] as num;
      if (!_okLat(sl) || !_okLat(el) || !_okLon(sn) || !_okLon(en)) return null;
      return TripResult(
        id: id,
        startMs: s.toInt(),
        endMs: e.toInt(),
        distanceM: dist.toDouble(),
        maxSpeedMps: mx.toDouble(),
        avgSpeedMps: av.toDouble(),
        mode: mode,
        startLat: sl.toDouble(),
        startLon: sn.toDouble(),
        endLat: el.toDouble(),
        endLon: en.toDouble(),
      );
    } catch (_) {
      return null;
    }
  }
}

/// One driving event inside a `drive` item.
class DriveEventResult {
  const DriveEventResult(this.kind, this.startMs, this.endMs, this.magnitude, this.lat, this.lon);
  final String kind;
  final int startMs, endMs;
  final double magnitude, lat, lon;

  List<dynamic> toJson() => <dynamic>[kind, startMs, endMs, _r1(magnitude), _r5(lat), _r5(lon)];

  static const List<String> _kinds = <String>[kEventSpeeding, kEventHardBrake, kEventRapidAccel, kEventPhoneUse];

  static DriveEventResult? tryParse(Object? j) {
    if (j is! List || j.length != 6) return null;
    try {
      final String k = j[0] as String;
      final num s = j[1] as num, e = j[2] as num, m = j[3] as num, la = j[4] as num, lo = j[5] as num;
      if (!_kinds.contains(k) || !_okTime(s) || !_okTime(e) || e < s || m < 0 || m > 1000 || !_okLat(la) || !_okLon(lo)) return null;
      return DriveEventResult(k, s.toInt(), e.toInt(), m.toDouble(), la.toDouble(), lo.toDouble());
    } catch (_) {
      return null;
    }
  }
}

/// The driving figures of one trip.
class DriveResult {
  const DriveResult({required this.tripId, required this.events, required this.speeding, required this.hardBrake, required this.rapidAccel, required this.phoneUse, this.score, this.truncated = false});

  final String tripId;
  final List<DriveEventResult> events;
  final int speeding, hardBrake, rapidAccel, phoneUse;
  final int? score;

  /// Some events were left out to fit the item size (the counts stay exact).
  final bool truncated;

  factory DriveResult.of(ProcessedTrip t) {
    final EventCountsOut c = EventCountsOut()..addAll(t.events);
    return DriveResult(
      tripId: TripResult.idFor(t.startedAtUs),
      events: <DriveEventResult>[
        for (final DrivingEvent e in t.events)
          DriveEventResult(e.kind, e.startedAtUs ~/ 1000, e.endedAtUs ~/ 1000, e.magnitude, e.lat, e.lon)
      ],
      speeding: c.speeding,
      hardBrake: c.hardBrake,
      rapidAccel: c.rapidAccel,
      phoneUse: c.phone,
      score: weeklySafetyScore(1, t.distanceM, c),
    );
  }

  Map<String, dynamic> toBody({int maxEvents = 200}) => <String, dynamic>{
        'trip': tripId,
        'n': <int>[speeding, hardBrake, rapidAccel, phoneUse],
        if (score != null) 'sc': score,
        'ev': <List<dynamic>>[for (final DriveEventResult e in events.take(maxEvents)) e.toJson()],
        if (truncated || events.length > maxEvents) 'tr': true,
      };

  /// A body whose JSON fits [maxJsonBytes] (events are dropped from the end first).
  Map<String, dynamic> fitBody(int maxJsonBytes) {
    int n = events.length;
    Map<String, dynamic> b = toBody(maxEvents: n);
    while (n > 0 && utf8.encode(jsonEncode(b)).length > maxJsonBytes) {
      n = n > 8 ? n - (n ~/ 4) : n - 1;
      b = toBody(maxEvents: n);
    }
    return b;
  }

  static DriveResult? tryParse(Object? j) {
    if (j is! Map<String, dynamic>) return null;
    try {
      final String trip = j['trip'] as String;
      final List<dynamic> n = j['n'] as List<dynamic>;
      if (trip.isEmpty || trip.length > 40 || n.length != 4) return null;
      final List<int> c = <int>[for (final dynamic x in n) (x as num).toInt()];
      if (c.any((int x) => x < 0 || x > 100000)) return null;
      final List<DriveEventResult> ev = <DriveEventResult>[];
      for (final dynamic x in (j['ev'] as List<dynamic>?) ?? <dynamic>[]) {
        final DriveEventResult? e = DriveEventResult.tryParse(x);
        if (e == null) return null;
        ev.add(e);
      }
      final num? sc = j['sc'] as num?;
      if (sc != null && (sc < 0 || sc > 100)) return null;
      return DriveResult(
          tripId: trip, events: ev, speeding: c[0], hardBrake: c[1], rapidAccel: c[2], phoneUse: c[3], score: sc?.toInt(), truncated: j['tr'] == true);
    } catch (_) {
      return null;
    }
  }
}

/// One member's driving figures for one window (server `weekStat`).
class WeekFigures {
  const WeekFigures({required this.drives, required this.distanceM, required this.durationS, required this.topSpeedMps, required this.speeding, required this.hardBrake, required this.rapidAccel, this.phoneUse, this.score});

  factory WeekFigures.of(WeekStatOut s) => WeekFigures(
        drives: s.drives,
        distanceM: s.distanceM,
        durationS: s.durationS,
        topSpeedMps: s.topSpeedMps,
        speeding: s.events.speeding,
        hardBrake: s.events.hardBrake,
        rapidAccel: s.events.rapidAccel,
        phoneUse: s.events.phoneUseEnabled ? s.events.phone : null,
        score: s.score,
      );

  final int drives;
  final double distanceM, durationS, topSpeedMps;
  final int speeding, hardBrake, rapidAccel;

  /// Null when this member did not switch phone-use detection on (then zero is NOT claimed).
  /// On the wire a null is `-1` in `ev[3]`; an older phone's plain count is read as a count.
  final int? phoneUse;
  final int? score;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'n': drives,
        'd': _r1(distanceM),
        't': durationS.round(),
        'top': _r1(topSpeedMps),
        'ev': <int>[speeding, hardBrake, rapidAccel, phoneUse ?? -1],
        if (score != null) 'sc': score,
      };

  static WeekFigures? tryParse(Object? j) {
    if (j is! Map<String, dynamic>) return null;
    try {
      final int n = (j['n'] as num).toInt();
      final num d = j['d'] as num, t = j['t'] as num, top = j['top'] as num;
      final List<dynamic> ev = j['ev'] as List<dynamic>;
      if (n < 0 || n > 100000 || d < 0 || d > 5e8 || t < 0 || t > 1e8 || top < 0 || top > 400 || ev.length != 4) return null;
      final List<int> c = <int>[for (final dynamic x in ev) (x as num).toInt()];
      if (c.sublist(0, 3).any((int x) => x < 0 || x > 1000000) || c[3] < -1 || c[3] > 1000000) return null;
      final num? sc = j['sc'] as num?;
      if (sc != null && (sc < 0 || sc > 100)) return null;
      return WeekFigures(
          drives: n, distanceM: d.toDouble(), durationS: t.toDouble(), topSpeedMps: top.toDouble(), speeding: c[0], hardBrake: c[1], rapidAccel: c[2], phoneUse: c[3] < 0 ? null : c[3], score: sc?.toInt());
    } catch (_) {
      return null;
    }
  }
}

/// The weekly summary of one member: the week starting Monday 00:00 UTC
/// ([weekStartMs]) and the one before it.
class WeekResult {
  const WeekResult({required this.weekStartMs, required this.current, required this.previous});
  final int weekStartMs;
  final WeekFigures current, previous;

  /// Computes the figures with the same functions the server's weekly summary is pinned to.
  static WeekResult compute(Iterable<TripSummary> trips, Iterable<DrivingEvent> events, int weekStartUs, {bool phoneUseEnabled = false}) {
    const int week = 7 * 24 * 3600 * 1000000;
    WeekFigures f(int from) =>
        WeekFigures.of(computeWeekStat(trips, events, fromUs: from, toUs: from + week, phoneUseEnabled: phoneUseEnabled));
    return WeekResult(weekStartMs: weekStartUs ~/ 1000, current: f(weekStartUs), previous: f(weekStartUs - week));
  }

  Map<String, dynamic> toBody() => <String, dynamic>{'wk': weekStartMs, 'c': current.toJson(), 'p': previous.toJson()};

  static WeekResult? tryParse(Object? j) {
    if (j is! Map<String, dynamic>) return null;
    try {
      final num wk = j['wk'] as num;
      final WeekFigures? c = WeekFigures.tryParse(j['c']), p = WeekFigures.tryParse(j['p']);
      if (!_okTime(wk) || c == null || p == null) return null;
      return WeekResult(weekStartMs: wk.toInt(), current: c, previous: p);
    } catch (_) {
      return null;
    }
  }
}
