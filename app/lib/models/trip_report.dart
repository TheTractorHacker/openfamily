import 'package:latlong2/latlong.dart';

/// The four kinds of driving event the family report counts.
enum DrivingEventKind { speeding, hardBrake, rapidAccel, phoneUse }

extension DrivingEventKindX on DrivingEventKind {
  /// The key used by the API (`events` maps, `kind` of a trip event).
  String get apiKey => switch (this) {
    DrivingEventKind.speeding => 'speeding',
    DrivingEventKind.hardBrake => 'hard_brake',
    DrivingEventKind.rapidAccel => 'rapid_accel',
    DrivingEventKind.phoneUse => 'phone_use',
  };

  /// Short name used on chips and as the sheet title.
  String get label => switch (this) {
    DrivingEventKind.speeding => 'Speeding',
    DrivingEventKind.hardBrake => 'Hard braking',
    DrivingEventKind.rapidAccel => 'Rapid acceleration',
    DrivingEventKind.phoneUse => 'Phone use',
  };
}

DrivingEventKind? parseEventKind(Object? raw) {
  for (final DrivingEventKind k in DrivingEventKind.values) {
    if (k.apiKey == raw) return k;
  }
  return null;
}

double _num(Object? v) => v is num ? v.toDouble() : 0;
int? _intOrNull(Object? v) => v is num ? v.toInt() : null;

/// Event counts. A null count means "not tracked" (never zero): for phone use
/// it means the member has phone-use detection off.
class EventCounts {
  const EventCounts({
    this.speeding = 0,
    this.hardBrake = 0,
    this.rapidAccel = 0,
    this.phoneUse,
  });

  factory EventCounts.fromJson(Object? j) {
    if (j is! Map<String, dynamic>) return const EventCounts();
    return EventCounts(
      speeding: _intOrNull(j['speeding']) ?? 0,
      hardBrake: _intOrNull(j['hard_brake']) ?? 0,
      rapidAccel: _intOrNull(j['rapid_accel']) ?? 0,
      phoneUse: _intOrNull(j['phone_use']),
    );
  }

  final int speeding;
  final int hardBrake;
  final int rapidAccel;
  final int? phoneUse;

  int? of(DrivingEventKind k) => switch (k) {
    DrivingEventKind.speeding => speeding,
    DrivingEventKind.hardBrake => hardBrake,
    DrivingEventKind.rapidAccel => rapidAccel,
    DrivingEventKind.phoneUse => phoneUse,
  };

  /// Sum of the tracked kinds ("risky events").
  int get risky => speeding + hardBrake + rapidAccel + (phoneUse ?? 0);
}

/// Direction of a count versus the previous period. Fewer is better.
enum Trend { fewer, more, same, unknown }

/// Compares [current] to [previous]; null on either side is [Trend.unknown].
Trend trendOf(int? current, int? previous) {
  if (current == null || previous == null) return Trend.unknown;
  if (current < previous) return Trend.fewer;
  if (current > previous) return Trend.more;
  return Trend.same;
}

class ReportTotals {
  const ReportTotals({
    this.drives = 0,
    this.distanceM = 0,
    this.topSpeedMps,
    this.topSpeedUserId,
    this.events = const EventCounts(),
  });

  factory ReportTotals.fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return const ReportTotals();
    return ReportTotals(
      drives: _intOrNull(raw['drives']) ?? 0,
      distanceM: _num(raw['distance_m']),
      topSpeedMps: raw['top_speed_mps'] is num
          ? (raw['top_speed_mps'] as num).toDouble()
          : null,
      topSpeedUserId: raw['top_speed_user_id'] as String?,
      events: EventCounts.fromJson(raw['events']),
    );
  }

  final int drives;
  final double distanceM;
  final double? topSpeedMps;
  final String? topSpeedUserId;
  final EventCounts events;
}

class MemberReport {
  const MemberReport({
    required this.userId,
    required this.name,
    this.drives = 0,
    this.distanceM = 0,
    this.topSpeedMps,
    this.events = const EventCounts(),
    this.previousEvents = const EventCounts(),
  });

  factory MemberReport.fromJson(Map<String, dynamic> j) => MemberReport(
    userId: (j['user_id'] ?? '').toString(),
    name: (j['name'] ?? '').toString(),
    drives: _intOrNull(j['drives']) ?? 0,
    distanceM: _num(j['distance_m']),
    topSpeedMps: j['top_speed_mps'] is num
        ? (j['top_speed_mps'] as num).toDouble()
        : null,
    events: EventCounts.fromJson(j['events']),
    previousEvents: EventCounts.fromJson(j['previous_events']),
  );

  final String userId;
  final String name;
  final int drives;
  final double distanceM;
  final double? topSpeedMps;
  final EventCounts events;
  final EventCounts previousEvents;
}

/// The thresholds the server used, quoted verbatim in the explanation sheets.
class ReportThresholds {
  const ReportThresholds({
    this.speedingMps = 35.76,
    this.speedingSeconds = 30,
    this.hardBrakeMps2 = 3.5,
    this.rapidAccelMps2 = 3.5,
  });

  factory ReportThresholds.fromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return const ReportThresholds();
    const ReportThresholds d = ReportThresholds();
    double pick(String k, double fallback) =>
        raw[k] is num ? (raw[k] as num).toDouble() : fallback;
    return ReportThresholds(
      speedingMps: pick('speeding_mps', d.speedingMps),
      speedingSeconds: pick('speeding_seconds', d.speedingSeconds.toDouble())
          .round(),
      hardBrakeMps2: pick('hard_brake_mps2', d.hardBrakeMps2),
      rapidAccelMps2: pick('rapid_accel_mps2', d.rapidAccelMps2),
    );
  }

  final double speedingMps;
  final int speedingSeconds;
  final double hardBrakeMps2;
  final double rapidAccelMps2;
}

DateTime _date(Object? v, String field) {
  if (v is String) {
    final DateTime? d = DateTime.tryParse(v);
    if (d != null) return DateTime(d.year, d.month, d.day);
  }
  throw FormatException('Invalid $field in report response.');
}

/// `GET /trips/report`.
class TripReport {
  const TripReport({
    required this.period,
    required this.start,
    required this.end,
    required this.prevStart,
    required this.prevEnd,
    required this.totals,
    required this.previousTotals,
    required this.members,
    required this.thresholds,
    required this.estimated,
    this.sensorMembers = const <String>[],
    this.phoneUseMembers = const <String>[],
    this.days = const <ReportDay>[],
    this.recentTrips = const <RecentTrip>[],
  });

  factory TripReport.fromJson(Map<String, dynamic> j) {
    final Object? m = j['members'];
    return TripReport(
      period: (j['period'] ?? 'week').toString(),
      start: _date(j['start'], 'start'),
      end: _date(j['end'], 'end'),
      prevStart: _date(j['prev_start'], 'prev_start'),
      prevEnd: _date(j['prev_end'], 'prev_end'),
      totals: ReportTotals.fromJson(j['totals']),
      previousTotals: ReportTotals.fromJson(j['previous_totals']),
      members: m is List
          ? m.whereType<Map<String, dynamic>>().map(MemberReport.fromJson).toList()
          : const <MemberReport>[],
      thresholds: ReportThresholds.fromJson(j['thresholds']),
      estimated: j['estimated'] != false,
      sensorMembers: j['sensor_members'] is List
          ? (j['sensor_members'] as List).map((Object? e) => '$e').toList()
          : const <String>[],
      phoneUseMembers: j['phone_use_members'] is List
          ? (j['phone_use_members'] as List).map((Object? e) => '$e').toList()
          : const <String>[],
      days: j['days'] is List
          ? (j['days'] as List)
              .whereType<Map<String, dynamic>>()
              .map(ReportDay.tryParse)
              .whereType<ReportDay>()
              .toList()
          : const <ReportDay>[],
      recentTrips: j['recent_trips'] is List
          ? (j['recent_trips'] as List)
              .whereType<Map<String, dynamic>>()
              .map(RecentTrip.tryParse)
              .whereType<RecentTrip>()
              .toList()
          : const <RecentTrip>[],
    );
  }

  final String period;
  final DateTime start;
  final DateTime end;
  final DateTime prevStart;
  final DateTime prevEnd;
  final ReportTotals totals;
  final ReportTotals previousTotals;
  final List<MemberReport> members;
  final ReportThresholds thresholds;

  /// Braking / acceleration are GPS estimates.
  final bool estimated;

  /// Users (visible to the viewer) whose phone sensor is on.
  final List<String> sensorMembers;

  /// Users (visible to the viewer) who turned phone-use detection on. Only
  /// they have a phone_use number; everyone else has null (off).
  final List<String> phoneUseMembers;

  /// One entry per local day of the period, zero-filled. Empty when the
  /// server predates the field.
  final List<ReportDay> days;

  /// The newest drives (at most 10) of the period, newest first.
  final List<RecentTrip> recentTrips;

  /// True when no member has the phone sensor on, so every braking /
  /// acceleration count is a GPS estimate.
  bool get gpsOnly => sensorMembers.isEmpty;

  bool get isEmpty => totals.drives == 0;

  Trend trend(DrivingEventKind k) =>
      trendOf(totals.events.of(k), previousTotals.events.of(k));

  /// Members with at least one incident of [k], most first.
  List<MemberReport> membersWith(DrivingEventKind k) {
    final List<MemberReport> out = members
        .where((MemberReport m) => (m.events.of(k) ?? 0) > 0)
        .toList()
      ..sort((MemberReport a, MemberReport b) =>
          (b.events.of(k) ?? 0).compareTo(a.events.of(k) ?? 0));
    return out;
  }
}

/// One local calendar day of the report period.
class ReportDay {
  const ReportDay({
    required this.date,
    this.drives = 0,
    this.distanceM = 0,
    this.topSpeedMps = 0,
  });

  static ReportDay? tryParse(Map<String, dynamic> j) {
    final DateTime? d = DateTime.tryParse('${j['date']}');
    if (d == null) return null;
    return ReportDay(
      date: DateTime(d.year, d.month, d.day),
      drives: _intOrNull(j['drives']) ?? 0,
      distanceM: _num(j['distance_m']),
      topSpeedMps: _num(j['top_speed_mps']),
    );
  }

  final DateTime date;
  final int drives;
  final double distanceM;
  final double topSpeedMps;
}

/// A drive listed on the Driving page (`recent_trips`).
class RecentTrip {
  const RecentTrip({
    required this.id,
    required this.userId,
    required this.name,
    required this.startedAt,
    required this.endedAt,
    this.distanceM = 0,
    this.durationS = 0,
    this.maxSpeedMps = 0,
    this.events = const EventCounts(),
  });

  static RecentTrip? tryParse(Map<String, dynamic> j) {
    final DateTime? s = DateTime.tryParse('${j['started_at']}');
    final DateTime? e = DateTime.tryParse('${j['ended_at']}');
    if (s == null || e == null) return null;
    return RecentTrip(
      id: (j['id'] ?? '').toString(),
      userId: (j['user_id'] ?? '').toString(),
      name: (j['name'] ?? '').toString(),
      startedAt: s.toLocal(),
      endedAt: e.toLocal(),
      distanceM: _num(j['distance_m']),
      durationS: _num(j['duration_s']),
      maxSpeedMps: _num(j['max_speed_mps']),
      events: EventCounts.fromJson(j['event_counts']),
    );
  }

  final String id;
  final String userId;
  final String name;
  final DateTime startedAt;
  final DateTime endedAt;
  final double distanceM;
  final double durationS;
  final double maxSpeedMps;
  final EventCounts events;

  Duration get duration => Duration(seconds: durationS.round());
}

/// One detected event on a trip (`GET /trips/{id}/events`).
class TripEvent {
  const TripEvent({
    required this.id,
    required this.kind,
    required this.startedAt,
    this.endedAt,
    this.magnitude,
    this.position,
  });

  /// Null when the kind is one this app version does not know.
  static TripEvent? tryParse(Map<String, dynamic> j) {
    final DrivingEventKind? kind = parseEventKind(j['kind']);
    final DateTime? started = DateTime.tryParse('${j['started_at']}');
    if (kind == null || started == null) return null;
    return TripEvent(
      id: (j['id'] ?? '').toString(),
      kind: kind,
      startedAt: started.toLocal(),
      endedAt: DateTime.tryParse('${j['ended_at']}')?.toLocal(),
      magnitude: j['magnitude'] is num ? (j['magnitude'] as num).toDouble() : null,
      position: j['lat'] is num && j['lon'] is num
          ? LatLng((j['lat'] as num).toDouble(), (j['lon'] as num).toDouble())
          : null,
    );
  }

  final String id;
  final DrivingEventKind kind;
  final DateTime startedAt;
  final DateTime? endedAt;

  /// m/s for speeding (peak speed), m/s^2 for braking / acceleration.
  final double? magnitude;
  final LatLng? position;
}

List<TripEvent> parseTripEvents(Object? raw) => raw is List
    ? raw
        .whereType<Map<String, dynamic>>()
        .map(TripEvent.tryParse)
        .whereType<TripEvent>()
        .toList()
    : const <TripEvent>[];

// ---- Period handling ----

enum ReportPreset { thisWeek, lastWeek, custom }

/// Monday (local) of the week containing [d], at local midnight.
DateTime weekStartOf(DateTime d) {
  final DateTime day = DateTime(d.year, d.month, d.day);
  return DateTime(day.year, day.month, day.day - (day.weekday - DateTime.monday));
}

const List<String> _months = <String>[
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _md(DateTime d) => '${_months[d.month - 1]} ${d.day}';

/// "Oct 12 - Oct 18" (with years when the range crosses years or is not in
/// [now]'s year).
String formatDateRange(DateTime start, DateTime end, {DateTime? now}) {
  final int year = (now ?? DateTime.now()).year;
  final bool years = start.year != end.year || start.year != year;
  return years
      ? '${_md(start)}, ${start.year} – ${_md(end)}, ${end.year}'
      : '${_md(start)} – ${_md(end)}';
}

/// `YYYY-MM-DD` for the `start` query parameter.
String apiDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// Start of the week for [preset]; [custom] is any day in the chosen week.
DateTime presetStart(ReportPreset preset, DateTime now, {DateTime? custom}) {
  final DateTime thisWeek = weekStartOf(now);
  return switch (preset) {
    ReportPreset.thisWeek => thisWeek,
    ReportPreset.lastWeek =>
      DateTime(thisWeek.year, thisWeek.month, thisWeek.day - 7),
    ReportPreset.custom => weekStartOf(custom ?? now),
  };
}

/// How the period reads in sentences: "this week", "last week", "that week".
String periodPhrase(ReportPreset p) => switch (p) {
  ReportPreset.thisWeek => 'this week',
  ReportPreset.lastWeek => 'last week',
  ReportPreset.custom => 'in this week',
};

/// Start of the month containing [d].
DateTime monthStartOf(DateTime d) => DateTime(d.year, d.month);

/// The start of the period of kind [period] ('week' or 'month') containing [d].
DateTime periodStartOf(String period, DateTime d) =>
    period == 'month' ? monthStartOf(d) : weekStartOf(d);

/// The period before/after [start] ([steps] negative = earlier).
DateTime shiftPeriod(String period, DateTime start, int steps) =>
    period == 'month'
        ? DateTime(start.year, start.month + steps)
        : DateTime(start.year, start.month, start.day + 7 * steps);

/// How the period reads in sentences: "this week", "last month", "that week".
String periodPhraseFor(String period, DateTime start, DateTime now) {
  final DateTime cur = periodStartOf(period, now);
  final String unit = period == 'month' ? 'month' : 'week';
  if (start == cur) return 'this $unit';
  if (start == shiftPeriod(period, cur, -1)) return 'last $unit';
  return 'in this $unit';
}

const List<String> _monthNames = <String>[
  'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August',
  'September', 'October', 'November', 'December',
];

/// "October 2026" or "Oct 19 – Oct 25" for the period starting at [start].
String periodTitle(String period, DateTime start, {DateTime? now}) {
  if (period == 'month') return '${_monthNames[start.month - 1]} ${start.year}';
  return formatDateRange(
    start,
    DateTime(start.year, start.month, start.day + 6),
    now: now,
  );
}

/// "down from 3", "up from 1", "no change", "no earlier data" as words, so
/// the trend never relies on colour or an arrow alone.
String trendText(Trend t, int? previous) => switch (t) {
  Trend.fewer => 'down from $previous',
  Trend.more => 'up from $previous',
  Trend.same => 'no change',
  Trend.unknown => 'no earlier data',
};
