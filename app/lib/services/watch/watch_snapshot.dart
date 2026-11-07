import 'dart:convert';

import '../../models/member.dart';
import '../../utils/member_status.dart';

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
    this.note = '',
    this.active = true,
  });

  /// `sos`, `help` or `check_in`.
  final String id;
  final String kind;
  final String from;
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
    'line': i.statusLine != null ? i.statusLine!(m) : memberStatusLine(m),
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
      for (final WatchAlert a in i.alerts.take(kWatchAlertCap))
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
/// unchanged hash means there is nothing new to tell the watch.
String watchContentHash(Map<String, dynamic> snapshot) {
  final Map<String, dynamic> c = Map<String, dynamic>.of(snapshot)..remove('ts');
  return jsonEncode(c);
}

// ---- Commands (watch to phone) ----------------------------------------------

enum WatchCmd { sos, checkin, pause, resume, ack, refresh, reply }

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
