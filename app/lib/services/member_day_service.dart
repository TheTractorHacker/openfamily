import '../models/member.dart';
import '../models/trip.dart';
import '../models/trip_report.dart';
import 'history_service.dart';
import 'trips_service.dart';

/// One of a member's trips today, with the extras the detail timeline shows.
class DayTrip {
  const DayTrip({
    required this.trip,
    this.route = const <TripRoutePoint>[],
    this.events = const <TripEvent>[],
    this.detailLoaded = false,
    this.fromName,
    this.toName,
  });

  final Trip trip;
  final List<TripRoutePoint> route;
  final List<TripEvent> events;

  /// False when the per-trip detail call failed (events then unknown).
  final bool detailLoaded;
  final String? fromName;
  final String? toName;

  int countOf(DrivingEventKind k) =>
      events.where((TripEvent e) => e.kind == k).length;

  DayTrip copyWith({String? fromName, String? toName}) => DayTrip(
        trip: trip,
        route: route,
        events: events,
        detailLoaded: detailLoaded,
        fromName: fromName ?? this.fromName,
        toName: toName ?? this.toName,
      );
}

/// Everything the member detail "Today" timeline needs, newest trip first.
class MemberDay {
  const MemberDay({this.trips = const <DayTrip>[]});

  final List<DayTrip> trips;
}

typedef MemberDayLoader = Future<MemberDay> Function(Member member, DateTime now);

const Duration _nameWindow = Duration(minutes: 20);

/// Names each trip's start / end from the member's place visits: the place
/// they left around the trip start and the one they reached around its end.
List<DayTrip> nameTripEndpoints(List<DayTrip> trips, List<HistoryVisit> visits) {
  final List<HistoryVisit> places =
      visits.where((HistoryVisit v) => v.isPlace).toList();
  String? nearest(DateTime at, DateTime Function(HistoryVisit) key) {
    HistoryVisit? best;
    Duration? bestGap;
    for (final HistoryVisit v in places) {
      final Duration gap = key(v).difference(at).abs();
      if (gap <= _nameWindow && (bestGap == null || gap < bestGap)) {
        best = v;
        bestGap = gap;
      }
    }
    return best?.placeName;
  }

  return <DayTrip>[
    for (final DayTrip d in trips)
      d.copyWith(
        fromName: nearest(d.trip.startedAt, (HistoryVisit v) => v.departedAt),
        toName: nearest(d.trip.endedAt, (HistoryVisit v) => v.arrivedAt),
      ),
  ];
}

/// Default loader: today's trips (+ route and events per trip) and place visits
/// for naming. Only a failed trip list is an error; the extras degrade.
Future<MemberDay> loadMemberDay(
  Member member,
  DateTime now, {
  TripsApi? api,
  Future<MemberHistory> Function({
    required String memberId,
    required DateTime day,
  })? history,
}) async {
  final TripsApi trips = api ?? TripsService.instance;
  final DateTime start = DateTime(now.year, now.month, now.day);
  final Future<MemberHistory?> visitsF =
      (history ?? HistoryService.fetchDay)(memberId: member.id, day: now)
          .then<MemberHistory?>((MemberHistory h) => h)
          .catchError((Object _) => null);
  final List<Trip> list =
      await trips.listTrips(userId: member.id, from: start, to: now);
  final List<Trip> sorted = List<Trip>.of(list)
    ..sort((Trip a, Trip b) => b.startedAt.compareTo(a.startedAt));
  final List<DayTrip> detailed = await Future.wait(
    sorted.map((Trip t) async {
      try {
        final TripDetail d = await trips.getTrip(t.id);
        return DayTrip(
            trip: t, route: d.route, events: d.events, detailLoaded: true);
      } catch (_) {
        return DayTrip(trip: t);
      }
    }),
  );
  final MemberHistory? h = await visitsF;
  return MemberDay(
    trips: h == null ? detailed : nameTripEndpoints(detailed, h.visits),
  );
}
