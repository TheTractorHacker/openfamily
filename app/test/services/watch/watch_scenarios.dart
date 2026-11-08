import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:openfamily/models/member.dart';
import 'package:openfamily/services/watch/watch_bridge.dart';
import 'package:openfamily/services/watch/watch_snapshot.dart';

/// One-hour family scenarios for the watch cadence tests (OPT-07/08).
///
/// Every second of the hour may carry a roster frame (what FamilyService hands
/// to WatchBridge.onMembers) and a context (alerts, unread, sharing). The data
/// is deterministic (seeded jitter) so the snapshot counts are reproducible.

final DateTime kScenarioStart = DateTime.utc(2026, 3, 2, 9);

class ScenarioSecond {
  const ScenarioSecond(this.members, this.context);

  /// Null: no roster frame this second.
  final List<Member>? members;
  final WatchContext context;
}

const double _lat0 = 51.5;
const double _lon0 = -0.12;

LatLng _offset(double northM, double eastM) => LatLng(
      _lat0 + northM / 111320.0,
      _lon0 + eastM / (111320.0 * math.cos(_lat0 * math.pi / 180)),
    );

Member scenarioMember(
  String id, {
  required LatLng pos,
  required DateTime fix,
  MovementType movement = MovementType.none,
  double? mps,
  int battery = 80,
  PlacePresence? presence,
  String address = '',
}) =>
    Member(
      id: id,
      name: id.toUpperCase(),
      position: pos,
      status: MemberStatus.normal,
      batteryPercent: battery,
      address: address,
      movement: movement,
      speedMps: mps,
      fixTime: fix,
      lastSeen: fix,
      placePresence: presence,
      avatarColor: Colors.teal,
    );

/// Stationary member reporting every [every] seconds with GPS jitter up to
/// [jitterM] meters around the same spot.
class _Still {
  _Still(this.id, this.northM, this.eastM, this.every, this.jitterM, this.rnd, {this.presence, this.address = ''});
  final String id;
  final double northM;
  final double eastM;
  final int every;
  final double jitterM;
  final math.Random rnd;
  final PlacePresence? presence;
  final String address;
  Member? current;

  /// True when this second produced a new fix.
  bool tick(int t) {
    if (current != null && t % every != 0) return false;
    final double a = rnd.nextDouble() * 2 * math.pi;
    final double r = rnd.nextDouble() * jitterM;
    current = scenarioMember(
      id,
      pos: _offset(northM + r * math.cos(a), eastM + r * math.sin(a)),
      fix: kScenarioStart.add(Duration(seconds: t)),
      presence: presence,
      address: address,
    );
    return true;
  }
}

const WatchContext _quiet = WatchContext(chatCircleId: 'c1');

/// "me" and "ana" at home or still, "sam" drives for the whole hour at 1 Hz
/// with a varying speed (so the old status line "Driving 37 mph" changed nearly
/// every frame) and a slowly falling battery.
List<ScenarioSecond> drivingHour() {
  final math.Random rnd = math.Random(7);
  final PlacePresence home = PlacePresence(placeId: 'p1', placeName: 'Home', isAt: true, since: kScenarioStart.subtract(const Duration(hours: 3)));
  final _Still me = _Still('me', 0, 0, 60, 15, rnd, presence: home);
  final _Still ana = _Still('ana', 800, 300, 120, 20, rnd, address: '12 High St');
  final List<ScenarioSecond> out = <ScenarioSecond>[];
  double north = 0;
  for (int t = 0; t < 3600; t++) {
    me.tick(t);
    ana.tick(t);
    final double v = 14 + 4 * math.sin(t / 40) + rnd.nextDouble(); // 10..19 m/s
    north += v;
    final Member sam = scenarioMember(
      'sam',
      pos: _offset(north, 50 * math.sin(t / 300)),
      fix: kScenarioStart.add(Duration(seconds: t)),
      movement: MovementType.car,
      mps: v,
      battery: 90 - t ~/ 360,
    );
    out.add(ScenarioSecond(<Member>[me.current!, sam, ana.current!], _quiet));
  }
  return out;
}

/// Nobody moves: four people reporting every 30 to 120 s with GPS jitter of up
/// to 25 m (so the same spot never produced the same coordinates twice), one of
/// them "Left Work" 3 minutes before the hour started.
List<ScenarioSecond> stationaryHour() {
  final math.Random rnd = math.Random(11);
  final PlacePresence home = PlacePresence(placeId: 'p1', placeName: 'Home', isAt: true, since: kScenarioStart.subtract(const Duration(hours: 2)));
  final PlacePresence leftWork = PlacePresence(placeId: 'p2', placeName: 'Work', isAt: false, since: kScenarioStart.subtract(const Duration(minutes: 3)));
  final List<_Still> people = <_Still>[
    _Still('me', 0, 0, 30, 25, rnd, presence: home),
    _Still('ana', 1200, -400, 60, 25, rnd, address: '12 High St'),
    _Still('sam', -3000, 2500, 90, 25, rnd, presence: leftWork),
    _Still('leo', 400, 400, 120, 25, rnd, presence: home),
  ];
  final List<ScenarioSecond> out = <ScenarioSecond>[];
  for (int t = 0; t < 3600; t++) {
    bool any = false;
    for (final _Still p in people) {
      if (p.tick(t)) any = true;
    }
    out.add(ScenarioSecond(any ? <Member>[for (final _Still p in people) p.current!] : null, _quiet));
  }
  return out;
}

/// The stationary hour plus a burst of events: four alerts within two minutes
/// (from minute 10), all ended at minute 15, twenty chat messages between minute
/// 20 and 30 (one every 30 s), read at minute 40, and sharing paused for 15 min
/// at minute 45.
List<ScenarioSecond> alertBurstHour() {
  final List<ScenarioSecond> base = stationaryHour();
  final List<ScenarioSecond> out = <ScenarioSecond>[];
  for (int t = 0; t < 3600; t++) {
    final List<WatchAlert> alerts = <WatchAlert>[
      if (t < 900)
        for (int k = 0; k < 4; k++)
          if (t >= 600 + 30 * k)
            WatchAlert(id: 'a$k', kind: k == 0 ? 'sos' : 'check_in', from: 'ANA', fromId: 'ana', at: kScenarioStart.add(Duration(seconds: 600 + 30 * k))),
    ];
    int unread = 0;
    if (t >= 1200 && t < 2400) unread = math.min(20, 1 + (t - 1200) ~/ 30);
    final bool paused = t >= 2700 && t < 3600;
    out.add(ScenarioSecond(
      base[t].members,
      WatchContext(
        chatCircleId: 'c1',
        alerts: alerts,
        unread: unread,
        sharingPaused: paused,
        pausedUntil: paused ? kScenarioStart.add(const Duration(seconds: 2700 + 900)) : null,
      ),
    ));
  }
  return out;
}

/// Meters between two points (haversine), for assertions.
double metersBetween(double lat1, double lon1, double lat2, double lon2) {
  const double r = 6371000.0;
  final double p1 = lat1 * math.pi / 180;
  final double p2 = lat2 * math.pi / 180;
  final double dp = (lat2 - lat1) * math.pi / 180;
  final double dl = (lon2 - lon1) * math.pi / 180;
  final double a = math.sin(dp / 2) * math.sin(dp / 2) + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2);
  return 2 * r * math.asin(math.min(1, math.sqrt(a)));
}
