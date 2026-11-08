import 'dart:math' as math;

import '../../models/member.dart';
import '../speed_units.dart' show UnitSystem;

/// The compact, already-decrypted picture of the family that the phone pushes
/// to a paired watch (docs/design/WATCH_APPS_APPLE.md). The phone is the only
/// holder of tokens and keys; the watch only ever receives this and sends back
/// small commands.
///
/// JSON shape, version 1 (shared by the Apple Watch and Wear OS apps):
/// ```
/// { "v": 1, "ts": <epoch ms>, "units": "imperial"|"metric",
///   "me": { "id", "name", "sharing": bool, "pausedUntil": <epoch ms>|null },
///   "circles": [ { "id", "name", "unread": int, "active": bool,
///                  "members": [ { "id", "name", "initials", "color": <ARGB int>,
///                                 "me": bool, "state": "still|driving|bike|boat|plane|home|work|gym|star",
///                                 "speedMps": num|null, "place": str|null, "atPlace": bool,
///                                 "address": str|null, "fixTs": <epoch ms>|null,
///                                 "battery": 0-100|null, "stopped": bool,
///                                 "distanceM": num|null, "bearingDeg": num|null } ] } ],
///   "alerts": [ { "id", "kind": "sos|help|check_in|...", "title", "body", "ts", "active": bool } ],
///   "quickReplies": [str] }
/// ```
/// Only the active circle carries members (the app loads one roster at a time);
/// the other circles list their name and unread count so the watch can show a
/// switcher later. No tokens, keys or raw coordinates are included: the
/// distance and direction are computed here.
const int kWatchSnapshotVersion = 1;

/// Members listed per circle. A watch screen is tiny and the message size is
/// limited; more than this is never useful there.
const int kWatchMemberCap = 24;

/// Alerts listed.
const int kWatchAlertCap = 8;

/// The fixed quick replies. Free text is never typed on the watch.
const List<String> kWatchQuickReplies = <String>[
  'On my way',
  'OK',
  'Running late',
  'Call me',
  'Yes',
  'No',
];

/// Great-circle distance in meters between two points.
double watchDistanceMeters(double lat1, double lon1, double lat2, double lon2) {
  const double r = 6371000;
  final double p1 = lat1 * math.pi / 180;
  final double p2 = lat2 * math.pi / 180;
  final double dp = (lat2 - lat1) * math.pi / 180;
  final double dl = (lon2 - lon1) * math.pi / 180;
  final double a = math.pow(math.sin(dp / 2), 2).toDouble() +
      math.cos(p1) * math.cos(p2) * math.pow(math.sin(dl / 2), 2).toDouble();
  return 2 * r * math.asin(math.min(1, math.sqrt(a)));
}

/// Initial bearing in degrees clockwise from north, 0 <= result < 360.
double watchBearingDegrees(double lat1, double lon1, double lat2, double lon2) {
  final double p1 = lat1 * math.pi / 180;
  final double p2 = lat2 * math.pi / 180;
  final double dl = (lon2 - lon1) * math.pi / 180;
  final double y = math.sin(dl) * math.cos(p2);
  final double x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl);
  return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
}

String _state(Member m) => switch (m.movement) {
      MovementType.car => 'driving',
      MovementType.bike => 'bike',
      MovementType.boat => 'boat',
      MovementType.plane => 'plane',
      MovementType.home => 'home',
      MovementType.work => 'work',
      MovementType.gym => 'gym',
      MovementType.star => 'star',
      MovementType.none => 'still',
    };

String _initials(String name) {
  final List<String> parts =
      name.trim().split(RegExp(r'\s+')).where((String p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  String first(String s) => String.fromCharCode(s.runes.first).toUpperCase();
  return parts.length == 1 ? first(parts.first) : first(parts.first) + first(parts.last);
}

/// One member as the watch sees it. [origin] is the signed-in user's own
/// position (for distance and direction), or null.
Map<String, dynamic> watchMemberJson(Member m, {required String? myId, Member? origin}) {
  final bool isMe = myId != null && m.id == myId;
  final bool hasPos = m.position != null;
  double? dist;
  double? bearing;
  if (!isMe && hasPos && origin?.position != null) {
    final p = origin!.position!;
    final q = m.position!;
    dist = watchDistanceMeters(p.latitude, p.longitude, q.latitude, q.longitude);
    bearing = watchBearingDegrees(p.latitude, p.longitude, q.latitude, q.longitude);
  }
  final PlacePresence? pp = m.placePresence;
  final DateTime? seen = m.fixTime ?? m.lastSeen;
  return <String, dynamic>{
    'id': m.id,
    'name': m.name,
    'initials': _initials(m.name),
    'color': m.avatarColor.toARGB32() | 0xFF000000,
    'me': isMe,
    'state': _state(m),
    'speedMps': m.movement == MovementType.car ? m.speedMps : null,
    'place': pp?.placeName,
    'atPlace': pp?.isAt ?? false,
    'address': hasPos && m.address.isNotEmpty ? m.address : null,
    'fixTs': seen?.millisecondsSinceEpoch,
    'battery': m.batteryPercent > 0 ? m.batteryPercent.clamp(0, 100) : null,
    'stopped': hasPos && m.status == MemberStatus.stopped,
    'hasPosition': hasPos,
    'distanceM': dist?.roundToDouble(),
    'bearingDeg': bearing?.roundToDouble(),
  };
}

/// One alert row for the watch.
class WatchAlert {
  const WatchAlert({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    required this.ts,
    this.active = false,
  });

  final String id;
  final String kind;
  final String title;
  final String body;
  final DateTime ts;
  final bool active;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'kind': kind,
        'title': title,
        'body': body,
        'ts': ts.millisecondsSinceEpoch,
        'active': active,
      };
}

/// A circle header for the snapshot.
class WatchCircle {
  const WatchCircle({required this.id, required this.name, this.unread = 0});
  final String id;
  final String name;
  final int unread;
}

/// Builds the snapshot map. Pure: everything it needs is passed in so tests do
/// not need a network.
Map<String, dynamic> buildWatchSnapshot({
  required List<Member> members,
  required String? myId,
  required String? myName,
  required String? activeCircleId,
  List<WatchCircle> circles = const <WatchCircle>[],
  required bool sharing,
  DateTime? pausedUntil,
  List<WatchAlert> alerts = const <WatchAlert>[],
  UnitSystem units = UnitSystem.imperial,
  String? sessionId,
  DateTime? now,
}) {
  final DateTime n = now ?? DateTime.now();
  Member? origin;
  for (final Member m in members) {
    if (myId != null && m.id == myId) origin = m;
  }
  final List<Map<String, dynamic>> roster = <Map<String, dynamic>>[
    for (final Member m in members.take(kWatchMemberCap)) watchMemberJson(m, myId: myId, origin: origin),
  ];
  final List<WatchCircle> list = <WatchCircle>[
    ...circles,
    if (activeCircleId != null && !circles.any((WatchCircle c) => c.id == activeCircleId))
      WatchCircle(id: activeCircleId, name: 'Circle'),
  ];
  return <String, dynamic>{
    'v': kWatchSnapshotVersion,
    // Identity of the sign-in this snapshot belongs to; the watch drops data of any other.
    'sid': sessionId,
    'ts': n.millisecondsSinceEpoch,
    'units': units == UnitSystem.metric ? 'metric' : 'imperial',
    'me': <String, dynamic>{
      'id': myId,
      'name': myName,
      'sharing': sharing,
      'pausedUntil': pausedUntil?.millisecondsSinceEpoch,
    },
    'circles': <Map<String, dynamic>>[
      for (final WatchCircle c in list)
        <String, dynamic>{
          'id': c.id,
          'name': c.name,
          'unread': c.unread,
          'active': c.id == activeCircleId,
          'members': c.id == activeCircleId ? roster : const <Map<String, dynamic>>[],
        },
    ],
    'alerts': <Map<String, dynamic>>[
      for (final WatchAlert a in alerts.take(kWatchAlertCap)) a.toJson(),
    ],
    'quickReplies': kWatchQuickReplies,
  };
}
