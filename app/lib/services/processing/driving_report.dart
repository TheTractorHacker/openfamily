import 'dart:math' as math;

import 'driving_events.dart';
import 'fix.dart';
import 'processing_params.dart';
import 'trip_segmenter.dart';

/// Per-kind event counts (server `eventCounts`). [phoneUse] is null unless the
/// member opted in to phone-use detection (never zero-by-default).
class EventCountsOut {
  EventCountsOut({
    this.speeding = 0,
    this.hardBrake = 0,
    this.rapidAccel = 0,
    this.phone = 0,
    this.phoneUseEnabled = false,
  });

  int speeding;
  int hardBrake;
  int rapidAccel;

  /// Accumulated phone-use events, exposed only when [phoneUseEnabled].
  int phone;
  bool phoneUseEnabled;

  int get total => hardBrake + rapidAccel + speeding + phone;

  void add(String kind, [int n = 1]) {
    switch (kind) {
      case kEventSpeeding:
        speeding += n;
      case kEventHardBrake:
        hardBrake += n;
      case kEventRapidAccel:
        rapidAccel += n;
      case kEventPhoneUse:
        phone += n;
    }
  }

  void addAll(Iterable<DrivingEvent> es) {
    for (final DrivingEvent e in es) {
      add(e.kind);
    }
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'speeding': speeding,
    'hard_brake': hardBrake,
    'rapid_accel': rapidAccel,
    'phone_use': phoneUseEnabled ? phone : null,
  };
}

/// Server `weeklySafetyScore`: null when nothing was driven. Note the phone
/// count enters the score even when it is hidden from the output (as on the
/// server).
int? weeklySafetyScore(int drives, double distanceM, EventCountsOut ev) {
  if (drives <= 0) return null;
  final int n = ev.total;
  final double km = math.max(distanceM / 1000, kScoreMinKm);
  int score = (100 - kScorePenaltyPerEventPer100Km * n / km * 100).round();
  if (score < 0) score = 0;
  if (score > 100) score = 100;
  return score;
}

/// A finished trip as the aggregation needs it (a [ProcessedTrip] or a
/// decoded `trip` result item).
class TripSummary {
  const TripSummary({
    required this.startedAtUs,
    required this.endedAtUs,
    required this.distanceM,
    required this.maxSpeedMps,
    required this.mode,
    this.id = '',
  });

  factory TripSummary.of(ProcessedTrip t, {String id = ''}) => TripSummary(
    startedAtUs: t.startedAtUs,
    endedAtUs: t.endedAtUs,
    distanceM: t.distanceM,
    maxSpeedMps: t.maxSpeedMps,
    mode: t.mode,
    id: id,
  );

  final int startedAtUs;
  final int endedAtUs;
  final double distanceM;
  final double maxSpeedMps;
  final String mode;
  final String id;

  double get durationS => (endedAtUs - startedAtUs) / 1e6;
}

/// One member's driving in one window (server `weekStat`).
class WeekStatOut {
  int drives = 0;
  double distanceM = 0;
  double durationS = 0;
  double topSpeedMps = 0;
  final EventCountsOut events = EventCountsOut();
  int? score;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'drives': drives,
    'distance_m': distanceM,
    'duration_s': durationS,
    'top_speed_mps': topSpeedMps,
    'events': events.toJson(),
    'safety_score': score,
  };
}

/// The server's `weekStats` for ONE member and the window [fromUs, toUs):
/// driving trips by `started_at`, events by their own `started_at`.
/// [events] must already be the *effective* events (see [effectiveEvents]).
WeekStatOut computeWeekStat(
  Iterable<TripSummary> trips,
  Iterable<DrivingEvent> events, {
  required int fromUs,
  required int toUs,
  bool phoneUseEnabled = false,
}) {
  final WeekStatOut st = WeekStatOut();
  for (final TripSummary t in trips) {
    if (t.mode != kModeDriving || t.startedAtUs < fromUs || t.startedAtUs >= toUs) {
      continue;
    }
    st.drives++;
    st.distanceM += t.distanceM;
    st.durationS += t.durationS;
    if (t.maxSpeedMps > st.topSpeedMps) st.topSpeedMps = t.maxSpeedMps;
  }
  for (final DrivingEvent e in events) {
    if (e.startedAtUs >= fromUs && e.startedAtUs < toUs) st.events.add(e.kind);
  }
  st.score = weeklySafetyScore(st.drives, st.distanceM, st.events);
  st.events.phoneUseEnabled = phoneUseEnabled;
  return st;
}

/// Resolved report period (server `reportPeriod`), local calendar in a fixed
/// UTC offset. [startUs]/[endUs] are `[start,end)` instants.
class ReportPeriod {
  ReportPeriod({
    required this.startUs,
    required this.endUs,
    required this.prevStartUs,
    required this.prevEndUs,
    required this.startDay,
    required this.endDay,
    required this.prevStartDay,
    required this.prevEndDay,
  });

  final int startUs, endUs, prevStartUs, prevEndUs;
  final String startDay, endDay, prevStartDay, prevEndDay;
}

String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Server `computeReportPeriod`: the week (Monday start) or month containing
/// [startDay] (`YYYY-MM-DD`, local) or, when null, containing [nowUs], using a
/// fixed UTC offset. Throws [ArgumentError] on bad input.
ReportPeriod computeReportPeriod(
  String period,
  String? startDay,
  int nowUs,
  int offsetMin,
) {
  if (period != 'week' && period != 'month') {
    throw ArgumentError('period must be week or month');
  }
  // "Local wall clock as a UTC DateTime": shift by the offset, use UTC fields.
  DateTime local;
  if (startDay != null && startDay.isNotEmpty) {
    final RegExpMatch? m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(startDay);
    if (m == null) throw ArgumentError('start must be YYYY-MM-DD');
    local = DateTime.utc(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
  } else {
    local = DateTime.fromMicrosecondsSinceEpoch(
      nowUs + offsetMin * 60 * 1000000,
      isUtc: true,
    );
  }
  final DateTime day = DateTime.utc(local.year, local.month, local.day);
  DateTime from, to, prev;
  if (period == 'week') {
    from = day.subtract(Duration(days: day.weekday - 1)); // Monday = 1
    to = DateTime.utc(from.year, from.month, from.day + 7);
    prev = DateTime.utc(from.year, from.month, from.day - 7);
  } else {
    from = DateTime.utc(day.year, day.month, 1);
    to = DateTime.utc(day.year, day.month + 1, 1);
    prev = DateTime.utc(day.year, day.month - 1, 1);
  }
  int inst(DateTime wall) =>
      wall.microsecondsSinceEpoch - offsetMin * 60 * 1000000;
  return ReportPeriod(
    startUs: inst(from),
    endUs: inst(to),
    prevStartUs: inst(prev),
    prevEndUs: inst(from),
    startDay: _ymd(from),
    endDay: _ymd(DateTime.utc(to.year, to.month, to.day - 1)),
    prevStartDay: _ymd(prev),
    prevEndDay: _ymd(DateTime.utc(from.year, from.month, from.day - 1)),
  );
}

/// Server `weeklyDue`: Monday 00:00 UTC of the week whose Sunday-18:00 UTC due
/// time most recently passed, and that due instant (epoch microseconds).
({int weekStartUs, int dueUs}) weeklyDue(int nowUs) {
  final DateTime now = DateTime.fromMicrosecondsSinceEpoch(nowUs, isUtc: true);
  final DateTime d = DateTime.utc(now.year, now.month, now.day);
  DateTime mon = DateTime.utc(d.year, d.month, d.day - (d.weekday - 1));
  if (nowUs < mon.microsecondsSinceEpoch + kWeeklyDueOffset.inMicroseconds) {
    mon = DateTime.utc(mon.year, mon.month, mon.day - 7);
  }
  final int w = mon.microsecondsSinceEpoch;
  return (weekStartUs: w, dueUs: w + kWeeklyDueOffset.inMicroseconds);
}

/// One member's week summary as the app's weekly screen consumes it
/// (`GET /trips/weekly-summary` member element without user_id/name).
Map<String, dynamic> weeklyMemberJson(
  Iterable<TripSummary> trips,
  Iterable<DrivingEvent> events,
  ReportPeriod per, {
  bool phoneUseEnabled = false,
}) {
  final List<TripSummary> ts = trips.toList(growable: false);
  final List<DrivingEvent> es = events.toList(growable: false);
  return <String, dynamic>{
    'current': computeWeekStat(
      ts,
      es,
      fromUs: per.startUs,
      toUs: per.endUs,
      phoneUseEnabled: phoneUseEnabled,
    ).toJson(),
    'previous': computeWeekStat(
      ts,
      es,
      fromUs: per.prevStartUs,
      toUs: per.prevEndUs,
      phoneUseEnabled: phoneUseEnabled,
    ).toJson(),
  };
}

/// One member's slice of `GET /trips/report` (the `members[]` element without
/// user_id/name, plus `days` and `recent_trips`). [offsetMin] picks the local
/// calendar day for the `days` buckets.
Map<String, dynamic> reportMemberJson(
  Iterable<TripSummary> trips,
  Iterable<DrivingEvent> events,
  ReportPeriod per,
  int offsetMin, {
  bool phoneUseEnabled = false,
}) {
  final List<TripSummary> drives = trips
      .where((TripSummary t) => t.mode == kModeDriving)
      .toList(growable: false);
  EventCountsOut counts(int from, int to) {
    final EventCountsOut c = EventCountsOut(phoneUseEnabled: phoneUseEnabled);
    for (final DrivingEvent e in events) {
      if (e.startedAtUs >= from && e.startedAtUs < to) c.add(e.kind);
    }
    return c;
  }

  Map<String, dynamic> agg(int from, int to) {
    int n = 0;
    double dist = 0, top = 0;
    for (final TripSummary t in drives) {
      if (t.startedAtUs < from || t.startedAtUs >= to) continue;
      n++;
      dist += t.distanceM;
      if (t.maxSpeedMps > top) top = t.maxSpeedMps;
    }
    return <String, dynamic>{'drives': n, 'distance_m': dist, 'top_speed_mps': top};
  }

  // Per-day buckets, zero-filled, local calendar days.
  final int offUs = offsetMin * 60 * 1000000;
  final List<Map<String, dynamic>> days = <Map<String, dynamic>>[];
  final Map<String, int> idx = <String, int>{};
  for (int u = per.startUs; u < per.endUs;) {
    final DateTime wall = DateTime.fromMicrosecondsSinceEpoch(u + offUs, isUtc: true);
    final String key = _ymd(wall);
    idx[key] = days.length;
    days.add(<String, dynamic>{
      'date': key,
      'drives': 0,
      'distance_m': 0.0,
      'top_speed_mps': 0.0,
    });
    final DateTime next = DateTime.utc(wall.year, wall.month, wall.day + 1);
    u = next.microsecondsSinceEpoch - offUs;
  }
  final List<TripSummary> inPeriod = drives
      .where((TripSummary t) => t.startedAtUs >= per.startUs && t.startedAtUs < per.endUs)
      .toList()
    ..sort((TripSummary a, TripSummary b) {
      final int c = b.startedAtUs.compareTo(a.startedAtUs);
      return c != 0 ? c : b.id.compareTo(a.id);
    });
  final List<Map<String, dynamic>> recent = <Map<String, dynamic>>[];
  for (final TripSummary t in inPeriod) {
    final String key = _ymd(
      DateTime.fromMicrosecondsSinceEpoch(t.startedAtUs + offUs, isUtc: true),
    );
    final int? i = idx[key];
    if (i != null) {
      final Map<String, dynamic> d = days[i];
      d['drives'] = (d['drives'] as int) + 1;
      d['distance_m'] = (d['distance_m'] as double) + t.distanceM;
      if (t.maxSpeedMps > (d['top_speed_mps'] as double)) {
        d['top_speed_mps'] = t.maxSpeedMps;
      }
    }
    if (recent.length < kRecentTripsLimit) {
      recent.add(<String, dynamic>{
        'id': t.id,
        'started_at': formatUtcMicros(t.startedAtUs),
        'ended_at': formatUtcMicros(t.endedAtUs),
        'distance_m': t.distanceM,
        'duration_s': t.durationS,
        'max_speed_mps': t.maxSpeedMps,
        'mode': t.mode,
        'event_counts': (EventCountsOut(phoneUseEnabled: phoneUseEnabled)
              ..addAll(
                events.where(
                  (DrivingEvent e) =>
                      e.startedAtUs >= t.startedAtUs &&
                      e.startedAtUs <= t.endedAtUs,
                ),
              ))
            .toJson(),
      });
    }
  }
  return <String, dynamic>{
    ...agg(per.startUs, per.endUs),
    'events': counts(per.startUs, per.endUs).toJson(),
    'previous_events': counts(per.prevStartUs, per.prevEndUs).toJson(),
    'previous': agg(per.prevStartUs, per.prevEndUs),
    'days': days,
    'recent_trips': recent,
  };
}
