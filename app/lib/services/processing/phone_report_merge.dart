import '../../models/trip_report.dart';
import '../../widgets/phone_driving_widgets.dart';
import 'processing_source.dart';
import 'result_items.dart';

// One Driving dashboard for a Private circle (PRIVACY_PROCESSING 8.4): the
// server's report covers the members whose lane is "server"; the members who
// keep their data on their phone are added from the sealed trip and drive
// results their phones shared, so the header cards, the event chips, the day
// chart and the drive list include everybody who has figures.

/// A phone-only member with figures to add to the report.
class PhoneReportMember {
  const PhoneReportMember({required this.userId, required this.name, required this.processing});
  final String userId;
  final String name;
  final MemberProcessing processing;
}

DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

/// A report with no drives at all for the period starting [start] (a local
/// day): the base to add phone members to when no member uses the server.
TripReport emptyReportFor(String period, DateTime start, {required DateTime now}) {
  final DateTime s = periodStartOf(period, start);
  final DateTime next = shiftPeriod(period, s, 1);
  final DateTime prev = shiftPeriod(period, s, -1);
  return TripReport(
    period: period,
    start: s,
    end: DateTime(next.year, next.month, next.day - 1),
    prevStart: prev,
    prevEnd: DateTime(s.year, s.month, s.day - 1),
    totals: const ReportTotals(),
    previousTotals: const ReportTotals(),
    members: const <MemberReport>[],
    thresholds: const ReportThresholds(),
    estimated: true,
    days: _zeroDays(s, next),
  );
}

List<ReportDay> _zeroDays(DateTime from, DateTime to) {
  final List<ReportDay> out = <ReportDay>[];
  for (DateTime d = _day(from); d.isBefore(to); d = DateTime(d.year, d.month, d.day + 1)) {
    out.add(ReportDay(date: d));
  }
  return out;
}

int? _addNullable(int? a, int? b) => (a == null && b == null) ? null : (a ?? 0) + (b ?? 0);

/// [base] (the server's report, possibly empty) plus the phone-only members
/// that shared figures. Members still waiting for their phone are not added
/// (the screen shows a "waiting" card for them). Pure: no I/O.
TripReport mergePhoneMembers(TripReport base, List<PhoneReportMember> phones) {
  final List<PhoneReportMember> usable = phones.where((PhoneReportMember p) => p.processing.placeholder == null).toList();
  if (usable.isEmpty) return base;
  final DateTime curFrom = base.start;
  final DateTime curTo = periodEndOf(base.period, base.start);
  final DateTime prevFrom = base.prevStart;

  final List<MemberReport> members = <MemberReport>[...base.members];
  final List<String> phoneUseMembers = <String>[...base.phoneUseMembers];
  int drives = base.totals.drives;
  double dist = base.totals.distanceM;
  double top = base.totals.topSpeedMps ?? 0;
  String? topUser = base.totals.topSpeedUserId;
  EventCounts ev = base.totals.events;
  int pDrives = base.previousTotals.drives;
  double pDist = base.previousTotals.distanceM;
  double pTop = base.previousTotals.topSpeedMps ?? 0;
  String? pTopUser = base.previousTotals.topSpeedUserId;
  EventCounts pEv = base.previousTotals.events;

  final Map<DateTime, ReportDay> days = <DateTime, ReportDay>{
    for (final ReportDay d in (base.days.isEmpty ? _zeroDays(curFrom, curTo) : base.days)) d.date: d,
  };
  final List<RecentTrip> recent = <RecentTrip>[...base.recentTrips];

  for (final PhoneReportMember p in usable) {
    final PhoneDrivingStats? s = phoneDrivingStats(p.processing, curFrom, curTo);
    final PhoneDrivingStats? ps = phoneDrivingStats(p.processing, prevFrom, curFrom);
    members.removeWhere((MemberReport m) => m.userId == p.userId);
    members.add(MemberReport(
      userId: p.userId,
      name: p.name,
      drives: s?.drives ?? 0,
      distanceM: s?.distanceM ?? 0,
      topSpeedMps: s?.topSpeedMps,
      events: EventCounts(speeding: s?.speeding ?? 0, hardBrake: s?.hardBrake ?? 0, rapidAccel: s?.rapidAccel ?? 0, phoneUse: s?.phoneUse),
      previousEvents: EventCounts(speeding: ps?.speeding ?? 0, hardBrake: ps?.hardBrake ?? 0, rapidAccel: ps?.rapidAccel ?? 0, phoneUse: ps?.phoneUse),
    ));
    if (s?.phoneUse != null && !phoneUseMembers.contains(p.userId)) phoneUseMembers.add(p.userId);
    if (s != null) {
      drives += s.drives;
      dist += s.distanceM;
      if (s.topSpeedMps > top) {
        top = s.topSpeedMps;
        topUser = p.userId;
      }
      ev = EventCounts(
        speeding: ev.speeding + s.speeding,
        hardBrake: ev.hardBrake + s.hardBrake,
        rapidAccel: ev.rapidAccel + s.rapidAccel,
        phoneUse: _addNullable(ev.phoneUse, s.phoneUse),
      );
    }
    if (ps != null) {
      pDrives += ps.drives;
      pDist += ps.distanceM;
      if (ps.topSpeedMps > pTop) {
        pTop = ps.topSpeedMps;
        pTopUser = p.userId;
      }
      pEv = EventCounts(
        speeding: pEv.speeding + ps.speeding,
        hardBrake: pEv.hardBrake + ps.hardBrake,
        rapidAccel: pEv.rapidAccel + ps.rapidAccel,
        phoneUse: _addNullable(pEv.phoneUse, ps.phoneUse),
      );
    }
    // Days and the drive list from the trips themselves.
    final Map<String, DriveResult> driveById = <String, DriveResult>{for (final DriveResult d in p.processing.drives) d.tripId: d};
    for (final TripResult t in p.processing.trips) {
      if (t.mode != 'driving') continue;
      final DateTime at = DateTime.fromMillisecondsSinceEpoch(t.startMs).toLocal();
      if (at.isBefore(curFrom) || !at.isBefore(curTo)) continue;
      final DateTime key = _day(at);
      final ReportDay? old = days[key];
      if (old != null) {
        days[key] = ReportDay(
          date: key,
          drives: old.drives + 1,
          distanceM: old.distanceM + t.distanceM,
          topSpeedMps: t.maxSpeedMps > old.topSpeedMps ? t.maxSpeedMps : old.topSpeedMps,
        );
      }
      final DriveResult? d = driveById[t.id];
      recent.add(RecentTrip(
        id: t.id,
        userId: p.userId,
        name: p.name,
        startedAt: at,
        endedAt: DateTime.fromMillisecondsSinceEpoch(t.endMs).toLocal(),
        distanceM: t.distanceM,
        durationS: t.durationS,
        maxSpeedMps: t.maxSpeedMps,
        events: d == null
            ? const EventCounts()
            : EventCounts(speeding: d.speeding, hardBrake: d.hardBrake, rapidAccel: d.rapidAccel, phoneUse: s?.phoneUse == null ? null : d.phoneUse),
        onDevice: true,
      ));
    }
  }
  recent.sort((RecentTrip a, RecentTrip b) => b.startedAt.compareTo(a.startedAt));

  return TripReport(
    period: base.period,
    start: base.start,
    end: base.end,
    prevStart: base.prevStart,
    prevEnd: base.prevEnd,
    totals: ReportTotals(drives: drives, distanceM: dist, topSpeedMps: top > 0 ? top : base.totals.topSpeedMps, topSpeedUserId: top > 0 ? topUser : null, events: ev),
    previousTotals: ReportTotals(drives: pDrives, distanceM: pDist, topSpeedMps: pTop > 0 ? pTop : base.previousTotals.topSpeedMps, topSpeedUserId: pTop > 0 ? pTopUser : null, events: pEv),
    members: members,
    thresholds: base.thresholds,
    estimated: base.estimated,
    sensorMembers: base.sensorMembers,
    phoneUseMembers: phoneUseMembers,
    days: days.values.toList()..sort((ReportDay a, ReportDay b) => a.date.compareTo(b.date)),
    recentTrips: recent.take(10).toList(),
  );
}
