import 'dart:math';

// On-device place evaluation for Private circles. This is a port of the server's
// geofence rules (backend/internal/handlers/geofence_eval.go) so that arrival and
// departure alerts behave the same when the server can no longer see positions:
//
//  * a fix with a reported accuracy worse than [kPlaceMaxAccuracyMeters] never
//    drives a transition (GPS drift cannot raise a false arrival/departure);
//  * the first observation is a silent baseline (no "arrived" for a phone that
//    was already inside);
//  * a notifiable transition fires immediately when the debounce window has
//    elapsed since the last notification, otherwise it is left PENDING and fired
//    by [PlaceEvaluator.tick] once the window passes;
//  * a rapid reversal inside the window is dropped (the pending transition is
//    superseded and no stale alert fires);
//  * a stale point (older than the last one seen) is ignored.
//
// The SENDER's phone runs this against the sealed places of the circle and emits
// a sealed `event` item; receivers raise a local notification.

/// Same limits as the server (geofence_eval.go).
const Duration kPlaceDebounce = Duration(seconds: 60);
const double kPlaceMaxAccuracyMeters = 100.0;

/// A place of a Private circle, stored as a sealed `place` item.
class SealedPlace {
  const SealedPlace({
    required this.id,
    required this.name,
    required this.lat,
    required this.lon,
    required this.radiusMeters,
    this.type = 'custom',
    this.address = '',
    this.enterNotify = true,
    this.exitNotify = true,
    this.deleted = false,
  });

  final String id;
  final String name;
  final double lat;
  final double lon;
  final double radiusMeters;
  final String type;
  final String address;
  final bool enterNotify;
  final bool exitNotify;

  /// A tombstone: a later sealed item with deleted = true removes the place.
  final bool deleted;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id, 'name': name, 'lat': lat, 'lon': lon, 'r': radiusMeters, 'type': type, 'addr': address,
        'en': enterNotify, 'ex': exitNotify, 'del': deleted,
      };

  static SealedPlace? fromJson(Map<String, dynamic> j) {
    final Object? id = j['id'];
    final Object? name = j['name'];
    if (id is! String || id.isEmpty || name is! String) return null;
    final double? lat = (j['lat'] as num?)?.toDouble();
    final double? lon = (j['lon'] as num?)?.toDouble();
    final double? r = (j['r'] as num?)?.toDouble();
    if (lat == null || lon == null || r == null) return null;
    if (lat < -90 || lat > 90 || lon < -180 || lon > 180 || !(r > 0 && r <= 100000)) return null;
    return SealedPlace(
      id: id,
      name: name.length > 100 ? name.substring(0, 100) : name,
      lat: lat,
      lon: lon,
      radiusMeters: r,
      type: (j['type'] as String?) ?? 'custom',
      address: (j['addr'] as String?) ?? '',
      enterNotify: j['en'] != false,
      exitNotify: j['ex'] != false,
      deleted: j['del'] == true,
    );
  }
}

/// Keeps the newest version of each place. Later items win by their signed
/// timestamp (ties broken by id order), tombstones remove the place.
class PlaceBook {
  final Map<String, ({SealedPlace place, int tsMs})> _byId = <String, ({SealedPlace place, int tsMs})>{};

  /// Applies one sealed place item. Returns true if it changed the book.
  bool apply(SealedPlace p, int tsMs) {
    final ({SealedPlace place, int tsMs})? cur = _byId[p.id];
    if (cur != null && cur.tsMs >= tsMs) return false;
    _byId[p.id] = (place: p, tsMs: tsMs);
    return true;
  }

  List<SealedPlace> get places =>
      _byId.values.where((v) => !v.place.deleted).map((v) => v.place).toList()
        ..sort((SealedPlace a, SealedPlace b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  SealedPlace? byId(String id) {
    final SealedPlace? p = _byId[id]?.place;
    return p == null || p.deleted ? null : p;
  }
}

/// A fired arrival or departure.
class PlaceEvent {
  const PlaceEvent({required this.placeId, required this.placeName, required this.entered, required this.at});
  final String placeId;
  final String placeName;
  final bool entered;

  /// When the transition was observed (for a pending one: when it happened).
  final DateTime at;

  @override
  String toString() => 'PlaceEvent(${entered ? 'enter' : 'exit'} $placeName @ $at)';
}

class _PlaceState {
  _PlaceState({required this.inside, required this.notifiedInside, this.lastNotifiedAt, required this.lastSeen});
  bool inside;
  bool? notifiedInside;
  DateTime? lastNotifiedAt;
  DateTime lastSeen;
  DateTime? pendingAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'in': inside, 'ni': notifiedInside, 'ln': lastNotifiedAt?.millisecondsSinceEpoch,
        'ls': lastSeen.millisecondsSinceEpoch, 'pa': pendingAt?.millisecondsSinceEpoch,
      };

  static _PlaceState fromJson(Map<String, dynamic> j) => _PlaceState(
        inside: j['in'] == true,
        notifiedInside: j['ni'] as bool?,
        lastNotifiedAt: j['ln'] is int ? DateTime.fromMillisecondsSinceEpoch(j['ln'] as int, isUtc: true) : null,
        lastSeen: DateTime.fromMillisecondsSinceEpoch((j['ls'] as int?) ?? 0, isUtc: true),
      )..pendingAt = j['pa'] is int ? DateTime.fromMillisecondsSinceEpoch(j['pa'] as int, isUtc: true) : null;
}

double _haversineMeters(double lat1, double lon1, double lat2, double lon2) {
  const double r = 6371008.8;
  final double p1 = lat1 * pi / 180, p2 = lat2 * pi / 180;
  final double dp = (lat2 - lat1) * pi / 180, dl = (lon2 - lon1) * pi / 180;
  final double a = pow(sin(dp / 2), 2) + cos(p1) * cos(p2) * pow(sin(dl / 2), 2);
  return 2 * r * asin(min(1.0, sqrt(a)));
}

/// Evaluates this phone's own fixes against the circle's places.
///
/// [now] is injectable (the debounce uses the evaluator's clock, like the server
/// uses the database clock) so the same cases as the server tests can run with a
/// fake clock.
class PlaceEvaluator {
  PlaceEvaluator({
    DateTime Function()? now,
    this.debounce = kPlaceDebounce,
    this.maxAccuracyMeters = kPlaceMaxAccuracyMeters,
  }) : _now = now ?? (() => DateTime.now().toUtc());

  final DateTime Function() _now;
  final Duration debounce;
  final double maxAccuracyMeters;
  final Map<String, _PlaceState> _states = <String, _PlaceState>{};

  /// True when a fix may drive a transition (accuracy gate; unknown is trusted).
  bool fixUsable(double? accuracyMeters) => accuracyMeters == null || accuracyMeters <= maxAccuracyMeters;

  bool _debounceElapsed(_PlaceState s) =>
      s.lastNotifiedAt == null || !_now().isBefore(s.lastNotifiedAt!.add(debounce));

  /// Feeds one fix; returns the events that fire now.
  List<PlaceEvent> onFix(double lat, double lon, DateTime ts, double? accuracyMeters, Iterable<SealedPlace> places) {
    final DateTime t = ts.toUtc();
    if (!fixUsable(accuracyMeters)) return const <PlaceEvent>[];
    final List<PlaceEvent> out = <PlaceEvent>[];
    final Set<String> live = <String>{};
    for (final SealedPlace p in places) {
      if (p.deleted) continue;
      live.add(p.id);
      final bool inside = _haversineMeters(lat, lon, p.lat, p.lon) <= p.radiusMeters;
      final _PlaceState? st = _states[p.id];
      if (st == null) {
        // Baseline: silent. Outside => the circle believes "outside"; inside => unknown.
        _states[p.id] = _PlaceState(inside: inside, notifiedInside: inside ? null : false, lastSeen: t);
        continue;
      }
      final PlaceEvent? e = _transition(st, p, inside, t);
      if (e != null) out.add(e);
    }
    _states.removeWhere((String id, _PlaceState _) => !live.contains(id));
    return out;
  }

  PlaceEvent? _transition(_PlaceState st, SealedPlace p, bool inside, DateTime ts) {
    if (ts.isBefore(st.lastSeen)) return null; // stale point
    final bool prevInside = st.inside;
    if (prevInside == inside) {
      st.lastSeen = ts;
      return null;
    }
    final bool notifiable = (inside && p.enterNotify) || (!inside && p.exitNotify);
    final bool hasPending = st.notifiedInside != null && st.notifiedInside != prevInside;
    final bool elapsed = _debounceElapsed(st);
    bool fire = false, pending = false, firePending = false;
    if (notifiable) {
      final bool already = st.notifiedInside != null && st.notifiedInside == inside;
      if (already && hasPending) {
        if (elapsed) firePending = true;
      } else if (!already) {
        if (elapsed) {
          fire = true;
        } else {
          pending = true;
        }
      }
    }
    PlaceEvent? ev;
    if (firePending) {
      // Tell the circle about the OLD pending transition (the opposite direction); the current one becomes pending.
      ev = PlaceEvent(placeId: p.id, placeName: p.name, entered: !inside, at: st.pendingAt ?? ts);
      st
        ..inside = inside
        ..notifiedInside = prevInside
        ..lastNotifiedAt = _now()
        ..pendingAt = ts
        ..lastSeen = ts;
    } else if (fire) {
      ev = PlaceEvent(placeId: p.id, placeName: p.name, entered: inside, at: ts);
      st
        ..inside = inside
        ..notifiedInside = inside
        ..lastNotifiedAt = _now()
        ..pendingAt = null
        ..lastSeen = ts;
    } else if (pending) {
      st
        ..inside = inside
        ..pendingAt = ts
        ..lastSeen = ts;
    } else {
      st
        ..inside = inside
        ..notifiedInside = inside
        ..pendingAt = null
        ..lastSeen = ts;
    }
    return ev;
  }

  /// Fires pending transitions whose debounce window has elapsed (the server's
  /// reconcile worker). Call on a timer and whenever the app wakes.
  List<PlaceEvent> tick(Iterable<SealedPlace> places) {
    final List<PlaceEvent> out = <PlaceEvent>[];
    for (final SealedPlace p in places) {
      final _PlaceState? st = _states[p.id];
      if (st == null || p.deleted) continue;
      if (st.notifiedInside == null || st.notifiedInside == st.inside) continue;
      final bool notifiable = (st.inside && p.enterNotify) || (!st.inside && p.exitNotify);
      if (!notifiable || !_debounceElapsed(st)) continue;
      out.add(PlaceEvent(placeId: p.id, placeName: p.name, entered: st.inside, at: st.pendingAt ?? _now()));
      st
        ..notifiedInside = st.inside
        ..lastNotifiedAt = _now()
        ..pendingAt = null;
    }
    return out;
  }

  /// A place whose geometry changed starts over (silent baseline), like the
  /// server's reset on a geometry edit.
  void resetPlace(String placeId) => _states.remove(placeId);

  /// Whether the phone currently believes it is inside [placeId] (null: unknown).
  bool? isInside(String placeId) => _states[placeId]?.inside;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'states': _states.map((String k, _PlaceState v) => MapEntry<String, dynamic>(k, v.toJson())),
      };

  void restore(Map<String, dynamic> j) {
    _states.clear();
    final Object? s = j['states'];
    if (s is Map<String, dynamic>) {
      s.forEach((String k, dynamic v) {
        if (v is Map<String, dynamic>) _states[k] = _PlaceState.fromJson(v);
      });
    }
  }
}
