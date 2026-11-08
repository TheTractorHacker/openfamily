import 'dart:convert';
import 'dart:math' as math;

import '../../models/member.dart';
import '../../utils/member_status.dart';
import '../delivery_status.dart' show DeliveryHints;

/// Pure Dart model + builder for the compact snapshot the phone pushes to a
/// paired watch (docs/design/WATCH_APPS.md). No Flutter plugins, no network:
/// everything here is unit-testable with plain data.

/// Hard cap of the encoded snapshot (the Wearable Data Layer item limit is
/// 100 KB; a normal family is 3 to 6 KB).
const int kWatchSnapshotMaxBytes = 100 * 1024;

/// People shown on the watch.
const int kWatchMemberCap = 15;

/// Alerts shown on the watch.
const int kWatchAlertCap = 5;

class WatchCircle {
  const WatchCircle({required this.id, required this.name, this.unread = 0, this.isPrivate = false});
  final String id;
  final String name;
  final int unread;
  final bool isPrivate;
}

class WatchAlert {
  const WatchAlert({
    required this.id,
    required this.kind,
    required this.from,
    required this.at,
    this.fromId = '',
    this.note = '',
    this.active = true,
  });

  /// `sos`, `help` or `check_in`.
  final String id;
  final String kind;
  final String from;

  /// User id of the sender (not sent to the watch); lets Private-circle senders be hidden.
  final String fromId;
  final DateTime at;
  final String note;
  final bool active;
}

/// The phone's answer to the last command the watch sent.
class WatchCommandResult {
  const WatchCommandResult({required this.id, required this.cmd, required this.ok, required this.at, this.message = ''});
  final String id;
  final String cmd;
  final bool ok;
  final DateTime at;
  final String message;
}

/// Everything [buildWatchSnapshot] needs, gathered by the bridge.
class WatchSnapshotInput {
  const WatchSnapshotInput({
    required this.now,
    required this.signedIn,
    this.members = const <Member>[],
    this.selfId,
    this.scopeId = 'all',
    this.scopeName = 'Everyone',
    this.scopePrivate = false,
    this.circles = const <WatchCircle>[],
    this.sharingPaused = false,
    this.pausedUntil,
    this.unread = 0,
    this.alerts = const <WatchAlert>[],
    this.privateMemberIds = const <String>{},
    this.showPrivate = true,
    this.lastCommand,
    this.statusLine,
  });

  final DateTime now;
  final bool signedIn;
  final List<Member> members;
  final String? selfId;
  final String scopeId;
  final String scopeName;
  final bool scopePrivate;
  final List<WatchCircle> circles;
  final bool sharingPaused;
  final DateTime? pausedUntil;
  final int unread;
  final List<WatchAlert> alerts;

  /// Members that belong to at least one Private circle.
  final Set<String> privateMemberIds;

  /// Setting "Show Private circles on the watch". Off removes Private
  /// members, Private circle names and Private-circle alerts from the snapshot.
  final bool showPrivate;
  final WatchCommandResult? lastCommand;

  /// Test hook: overrides the per-member status text.
  final String Function(Member m)? statusLine;
}

/// 5 mph in m/s: the speed in a watch status line is rounded to this step, so
/// "Driving 37 mph" does not change on every GPS fix.
const double _speedStepMps = 2.2352;

/// The member's status line for the watch, without anything that changes by
/// itself as time passes. Relative times ("Left Work 25 min ago", "last seen
/// 5 min ago") are split off: [text] is the stable part and [at] the absolute
/// time the watch formats itself ("<text> 25 min ago"), so a minute ticking
/// over never produces a new snapshot. Same words as the phone otherwise.
({String text, DateTime? at}) watchMemberLine(Member m, {DateTime? now}) {
  final DateTime n = now ?? DateTime.now();
  if (m.position == null) return (text: memberStatusLine(m), at: null);
  if (m.status == MemberStatus.stopped) {
    final String? why = DeliveryHints.hintFor(m.id);
    final DateTime? seen = m.lastSeen;
    if (why != null) return seen == null ? (text: why, at: null) : (text: '$why · last seen', at: seen);
    if (seen == null) return (text: 'Updates stopped', at: null);
    if (n.difference(seen) >= const Duration(hours: 24)) return (text: 'Updates stopped, last seen', at: seen);
    return (text: memberStatusLine(m), at: null); // "last seen 3:12 pm": a clock time, stable
  }
  if (m.movement == MovementType.car) {
    final double? v = m.speedMps;
    final double? q = v == null ? null : (v / _speedStepMps).roundToDouble() * _speedStepMps;
    return (text: memberStatusLine(m, speedMps: q), at: null);
  }
  final PlacePresence? p = m.placePresence;
  if (m.movement == MovementType.none && p != null && !p.isAt) return (text: 'Left ${p.placeName}', at: p.since);
  return (text: memberStatusLine(m), at: null);
}

/// "driving", "moving", "at_place", "still", "stopped" or "none".
String watchMemberState(Member m) {
  if (m.position == null) return 'none';
  if (m.status == MemberStatus.stopped) return 'stopped';
  switch (m.movement) {
    case MovementType.car:
      return 'driving';
    case MovementType.bike:
    case MovementType.boat:
    case MovementType.plane:
      return 'moving';
    case MovementType.home:
    case MovementType.work:
    case MovementType.gym:
    case MovementType.star:
      return 'at_place';
    case MovementType.none:
      return m.placePresence?.isAt == true ? 'at_place' : 'still';
  }
}

double _round5(double v) => (v * 100000).roundToDouble() / 100000;

Map<String, dynamic> _member(WatchSnapshotInput i, Member m) {
  final bool priv = i.privateMemberIds.contains(m.id);
  final String state = watchMemberState(m);
  final double? mps = m.speedMps;
  final ({String text, DateTime? at}) line =
      i.statusLine != null ? (text: i.statusLine!(m), at: null) : watchMemberLine(m, now: i.now);
  return <String, dynamic>{
    'id': m.id,
    'name': m.name,
    'initials': _initials(m.name),
    'color': m.avatarColor.toARGB32() | 0xFF000000,
    if (m.position != null) 'lat': _round5(m.position!.latitude),
    if (m.position != null) 'lon': _round5(m.position!.longitude),
    if ((m.fixTime ?? m.lastSeen) != null) 'fixAt': (m.fixTime ?? m.lastSeen)!.millisecondsSinceEpoch,
    'battery': m.batteryPercent > 0 ? m.batteryPercent.clamp(0, 100) : -1,
    'state': state,
    if (state == 'driving' && mps != null) 'speedKmh': (mps * 3.6).round(),
    'place': m.placePresence?.isAt == true ? m.placePresence!.placeName : '',
    'address': m.address,
    'line': line.text,
    // Watch apps that know it append "25 min ago" to the line; older ones show the line alone.
    if (line.at != null) 'lineAt': line.at!.millisecondsSinceEpoch,
    'private': priv,
    'you': i.selfId != null && m.id == i.selfId,
  };
}

String _initials(String name) {
  final List<String> parts = name.trim().split(RegExp(r'\s+')).where((String p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  String first(String s) => String.fromCharCode(s.runes.first).toUpperCase();
  return parts.length == 1 ? first(parts.first) : first(parts.first) + first(parts.last);
}

/// Builds the JSON-encodable snapshot. A signed-out phone gets the empty
/// snapshot, which tells the watch to forget everything.
Map<String, dynamic> buildWatchSnapshot(WatchSnapshotInput i) {
  final Map<String, dynamic> out = <String, dynamic>{
    'v': 1,
    'ts': i.now.millisecondsSinceEpoch,
    'signedIn': i.signedIn,
  };
  if (!i.signedIn) return out;
  final bool hidePrivate = !i.showPrivate;
  final List<Member> members = <Member>[
    for (final Member m in i.members)
      if (!(hidePrivate && i.privateMemberIds.contains(m.id) && m.id != i.selfId)) m,
  ];
  // You first, then the most recently seen: the watch re-sorts by distance itself when it knows where it is.
  members.sort((Member a, Member b) {
    final bool ay = a.id == i.selfId;
    final bool by = b.id == i.selfId;
    if (ay != by) return ay ? -1 : 1;
    final int at = (a.fixTime ?? a.lastSeen)?.millisecondsSinceEpoch ?? 0;
    final int bt = (b.fixTime ?? b.lastSeen)?.millisecondsSinceEpoch ?? 0;
    return bt.compareTo(at);
  });
  final List<WatchCircle> circles = <WatchCircle>[
    for (final WatchCircle c in i.circles)
      if (!(hidePrivate && c.isPrivate)) c,
  ];
  final bool scopeHidden = hidePrivate && i.scopePrivate;
  out
    ..['scope'] = <String, dynamic>{
      'id': scopeHidden ? 'all' : i.scopeId,
      'name': scopeHidden ? 'Everyone' : i.scopeName,
      'private': !scopeHidden && i.scopePrivate,
    }
    ..['circles'] = <Map<String, dynamic>>[
      for (final WatchCircle c in circles) <String, dynamic>{'id': c.id, 'name': c.name, 'unread': c.unread, 'private': c.isPrivate},
    ]
    ..['me'] = <String, dynamic>{
      'sharing': i.sharingPaused ? 'paused' : 'on',
      'pausedUntil': i.sharingPaused ? i.pausedUntil?.millisecondsSinceEpoch : null,
    }
    ..['unread'] = i.unread
    ..['members'] = <Map<String, dynamic>>[for (final Member m in members.take(kWatchMemberCap)) _member(i, m)]
    ..['alerts'] = <Map<String, dynamic>>[
      for (final WatchAlert a in i.alerts.where((WatchAlert a) => !(hidePrivate && a.fromId.isNotEmpty && i.privateMemberIds.contains(a.fromId) && a.fromId != i.selfId)).take(kWatchAlertCap))
        <String, dynamic>{
          'id': a.id,
          'kind': a.kind,
          'from': a.from,
          'at': a.at.millisecondsSinceEpoch,
          'note': a.note.length > 80 ? a.note.substring(0, 80) : a.note,
          'active': a.active,
        },
    ];
  final WatchCommandResult? r = i.lastCommand;
  if (r != null) {
    out['lastCommand'] = <String, dynamic>{
      'id': r.id,
      'cmd': r.cmd,
      'ok': r.ok,
      'at': r.at.millisecondsSinceEpoch,
      'message': r.message,
    };
  }
  return out;
}

/// Encodes [snapshot]; when it exceeds [maxBytes] the least important members
/// (the end of the list) are dropped until it fits.
String encodeWatchSnapshot(Map<String, dynamic> snapshot, {int maxBytes = kWatchSnapshotMaxBytes}) {
  String s = jsonEncode(snapshot);
  if (utf8.encode(s).length <= maxBytes) return s;
  final Map<String, dynamic> copy = Map<String, dynamic>.of(snapshot);
  final List<dynamic> members = List<dynamic>.of((snapshot['members'] as List<dynamic>?) ?? const <dynamic>[]);
  while (members.isNotEmpty) {
    members.removeLast();
    copy['members'] = members;
    s = jsonEncode(copy);
    if (utf8.encode(s).length <= maxBytes) return s;
  }
  copy['alerts'] = <dynamic>[];
  return jsonEncode(copy);
}

/// Stable fingerprint of the snapshot content, without its timestamp: an
/// unchanged hash means there is nothing new to tell the watch. Nothing in the
/// snapshot changes by itself as time passes (relative times are formatted on
/// the watch from `fixAt`, `lineAt` and `at`), so the hash moves only when the
/// data does.
String watchContentHash(Map<String, dynamic> snapshot) {
  final Map<String, dynamic> c = Map<String, dynamic>.of(snapshot)..remove('ts');
  return jsonEncode(c);
}

/// How much a new snapshot differs from the last one the watch got, from
/// "nothing" to "the user is waiting for this". The bridge picks the cadence
/// and the Data Layer urgency from it (docs/design/WATCH_APPS.md, Cadence).
enum WatchChange {
  /// Identical apart from the timestamp.
  none,

  /// Only fine detail: a few meters of GPS jitter, a newer fix time, the
  /// driving speed. Sent with the next keep-alive, or at once while the watch
  /// app is on screen.
  minor,

  /// Something a person would notice: someone moved more than
  /// [kWatchMoveMeters], changed state, place, status text or battery bucket;
  /// the circles or the scope changed.
  meaningful,

  /// Unread messages or the sharing state changed, someone joined or left:
  /// sent within seconds whatever the watch is doing, but not urgent.
  event,

  /// An alert arrived or ended, the answer to a command from the watch, a
  /// new sign-in, or the first roster after an empty one: delivered at once
  /// (Data Layer `setUrgent`).
  urgent,
}

/// A member has "moved" for the watch when they are this far from where the
/// watch last saw them. GPS jitter of a still phone stays well below it.
const double kWatchMoveMeters = 100;

double _meters(num lat1, num lon1, num lat2, num lon2) {
  const double r = 6371000.0;
  final double p1 = lat1 * math.pi / 180;
  final double p2 = lat2 * math.pi / 180;
  final double dp = (lat2 - lat1) * math.pi / 180;
  final double dl = (lon2 - lon1) * math.pi / 180;
  final double a = math.sin(dp / 2) * math.sin(dp / 2) + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2);
  return 2 * r * math.asin(math.min(1, math.sqrt(a)));
}

/// Battery as the watch shows it: 5% steps at 20% and below (the watch marks
/// it as low), 10% steps above, -1 unknown.
String _batteryBucket(Object? b) {
  if (b is! int || b < 0) return '-';
  return b <= 20 ? 'low${b ~/ 5}' : 'b${b ~/ 10}';
}

/// What a person would notice about one member, positions excluded.
String _memberKey(Map<String, dynamic> m) => jsonEncode(<Object?>[
      m['name'], m['initials'], m['color'], m['state'], m['place'], m['private'], m['you'],
      _batteryBucket(m['battery']),
      m['lat'] != null && m['lon'] != null,
      // While driving the line carries the speed: that is detail, the position decides.
      if (m['state'] != 'driving') ...<Object?>[m['line'], m['lineAt']],
    ]);

String _key(Object? v) => jsonEncode(v);

/// Classifies [next] against [prev], the last snapshot the watch received
/// (null: the watch has nothing from this phone run yet).
WatchChange classifyWatchChange(Map<String, dynamic>? prev, Map<String, dynamic> next, {double moveMeters = kWatchMoveMeters}) {
  if (prev == null) return WatchChange.urgent;
  if (prev['signedIn'] != next['signedIn']) return WatchChange.urgent;
  if (watchContentHash(prev) == watchContentHash(next)) return WatchChange.none;
  List<Object?> alerts(Map<String, dynamic> s) => <Object?>[
        for (final Object? a in (s['alerts'] as List<dynamic>?) ?? const <dynamic>[])
          if (a is Map) <Object?>[a['id'], a['active']],
      ];
  if (_key(alerts(prev)) != _key(alerts(next))) return WatchChange.urgent;
  final Object? pc = (prev['lastCommand'] as Map?)?['id'];
  final Object? nc = (next['lastCommand'] as Map?)?['id'];
  if (pc != nc) return WatchChange.urgent;
  List<Object?> unread(Map<String, dynamic> s) => <Object?>[
        s['unread'],
        for (final Object? c in (s['circles'] as List<dynamic>?) ?? const <dynamic>[]) if (c is Map) c['unread'],
      ];
  if (_key(unread(prev)) != _key(unread(next)) || _key(prev['me']) != _key(next['me'])) return WatchChange.event;
  List<Object?> circles(Map<String, dynamic> s) => <Object?>[
        for (final Object? c in (s['circles'] as List<dynamic>?) ?? const <dynamic>[]) if (c is Map) <Object?>[c['id'], c['name'], c['private']],
      ];
  if (_key(prev['scope']) != _key(next['scope']) || _key(circles(prev)) != _key(circles(next))) return WatchChange.meaningful;
  final Map<Object?, Map<String, dynamic>> before = <Object?, Map<String, dynamic>>{
    for (final Object? m in (prev['members'] as List<dynamic>?) ?? const <dynamic>[]) if (m is Map<String, dynamic>) m['id']: m,
  };
  final List<Map<String, dynamic>> after = <Map<String, dynamic>>[
    for (final Object? m in (next['members'] as List<dynamic>?) ?? const <dynamic>[]) if (m is Map<String, dynamic>) m,
  ];
  // The first roster after an empty one (app start): the watch must not keep showing nobody.
  if (before.isEmpty && after.isNotEmpty) return WatchChange.urgent;
  // Someone joined or left, or the phone switched circles: within seconds.
  if (before.length != after.length || after.any((Map<String, dynamic> m) => !before.containsKey(m['id']))) return WatchChange.event;
  for (final Map<String, dynamic> m in after) {
    final Map<String, dynamic>? o = before[m['id']];
    if (o == null || _memberKey(o) != _memberKey(m)) return WatchChange.meaningful;
    final Object? la = o['lat'], lo = o['lon'], na = m['lat'], no = m['lon'];
    if (la is num && lo is num && na is num && no is num && _meters(la, lo, na, no) > moveMeters) return WatchChange.meaningful;
  }
  return WatchChange.minor;
}

// ---- Commands (watch to phone) ----------------------------------------------

/// `visible` and `hidden` are not actions: the watch app says whether it is on
/// screen (`visible`, with arg `ambient` in always-on mode) so the phone can
/// choose how often to send (docs/design/WATCH_APPS.md, Cadence).
enum WatchCmd { sos, checkin, pause, resume, ack, refresh, reply, visible, hidden }

/// Fixed quick replies. The watch sends only the id; the phone owns the words.
const Map<String, String> kWatchReplies = <String, String>{
  'ok': "I'm OK",
  'omw': 'On my way',
  'late': 'Running late',
  'call': 'Please call me',
  'thanks': 'Thanks',
};

/// Pause lengths the watch may ask for (minutes).
const Set<int> kWatchPauseMinutes = <int>{15, 60, 240};

/// How old (or how far in the future) a command may be before it is ignored.
const Duration kWatchCommandWindow = Duration(minutes: 2);

class WatchCommand {
  const WatchCommand({required this.id, required this.cmd, required this.at, this.arg});
  final String id;
  final WatchCmd cmd;
  final DateTime at;
  final String? arg;

  /// Parses and validates a command; null for anything that is not one of the
  /// accepted commands with a valid argument. Size-limited.
  static WatchCommand? tryParse(String raw) {
    if (raw.length > 512) return null;
    try {
      final Object? j = jsonDecode(raw);
      if (j is! Map<String, dynamic>) return null;
      final Object? id = j['id'];
      final Object? name = j['cmd'];
      final Object? at = j['at'];
      final Object? arg = j['arg'];
      if (id is! String || id.isEmpty || id.length > 40) return null;
      if (name is! String || at is! int) return null;
      final WatchCmd? cmd = WatchCmd.values.where((WatchCmd c) => c.name == name).firstOrNull;
      if (cmd == null) return null;
      if (arg != null && (arg is! String || arg.length > 64)) return null;
      final String? a = arg as String?;
      switch (cmd) {
        case WatchCmd.pause:
          final int? mins = int.tryParse(a ?? '');
          if (mins == null || !kWatchPauseMinutes.contains(mins)) return null;
        case WatchCmd.reply:
          if (a == null || !kWatchReplies.containsKey(a)) return null;
        case WatchCmd.ack:
          if (a == null || a.isEmpty) return null;
        case WatchCmd.visible:
          if (a != null && a != 'ambient') return null;
        case WatchCmd.hidden:
          if (a != null) return null;
        case WatchCmd.sos:
        case WatchCmd.checkin:
        case WatchCmd.resume:
        case WatchCmd.refresh:
          break;
      }
      return WatchCommand(id: id, cmd: cmd, at: DateTime.fromMillisecondsSinceEpoch(at, isUtc: true), arg: a);
    } catch (_) {
      return null;
    }
  }
}
