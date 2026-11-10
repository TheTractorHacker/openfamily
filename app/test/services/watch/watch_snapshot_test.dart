import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:openfamily/models/member.dart';
import 'package:openfamily/services/watch/watch_snapshot.dart';

final DateTime _now = DateTime.utc(2026, 1, 2, 3, 4, 5);

Member _m(
  String id,
  String name, {
  LatLng? pos = const LatLng(51.5000049, -0.1200051),
  MovementType movement = MovementType.none,
  double? mps,
  DateTime? fix,
  int battery = 80,
  PlacePresence? presence,
  MemberStatus status = MemberStatus.normal,
}) =>
    Member(
      id: id,
      name: name,
      position: pos,
      status: status,
      batteryPercent: battery,
      address: '12 High St',
      movement: movement,
      speedMps: mps,
      fixTime: fix,
      lastSeen: fix,
      placePresence: presence,
      avatarColor: const Color(0xFF336699),
    );

WatchSnapshotInput _input({
  List<Member>? members,
  bool signedIn = true,
  bool showPrivate = true,
  Set<String> priv = const <String>{},
  List<WatchCircle> circles = const <WatchCircle>[],
  bool scopePrivate = false,
  WatchCommandResult? last,
}) =>
    WatchSnapshotInput(
      now: _now,
      signedIn: signedIn,
      members: members ?? <Member>[_m('me', 'Me Myself'), _m('u1', 'Sam')],
      selfId: 'me',
      scopeId: 'c1',
      scopeName: 'Family',
      scopePrivate: scopePrivate,
      circles: circles,
      sharingPaused: true,
      pausedUntil: _now.add(const Duration(hours: 1)),
      unread: 3,
      alerts: <WatchAlert>[WatchAlert(id: 'a1', kind: 'sos', from: 'Sam', fromId: 'u1', at: _now, note: 'x' * 200)],
      privateMemberIds: priv,
      showPrivate: showPrivate,
      lastCommand: last,
    );

void main() {
  group('buildWatchSnapshot', () {
    test('signed out is the empty snapshot, nothing else', () {
      final Map<String, dynamic> s = buildWatchSnapshot(_input(signedIn: false));
      expect(s.keys.toSet(), <String>{'v', 'ts', 'signedIn'});
      expect(s['signedIn'], false);
    });

    test('shape, rounding, you-first order and flags', () {
      final DateTime fix = _now.subtract(const Duration(minutes: 2));
      final Map<String, dynamic> s = buildWatchSnapshot(_input(members: <Member>[
        _m('u1', 'Sam', fix: fix, movement: MovementType.car, mps: 10),
        _m('me', 'Me Myself', fix: _now.subtract(const Duration(hours: 1))),
        _m('u2', 'Ana', pos: null),
      ]));
      expect(s['v'], 1);
      expect(s['unread'], 3);
      expect((s['me'] as Map)['sharing'], 'paused');
      final List<dynamic> members = s['members'] as List<dynamic>;
      expect(members.map((dynamic m) => (m as Map)['id']).toList(), <String>['me', 'u1', 'u2']);
      final Map<String, dynamic> me = members[0] as Map<String, dynamic>;
      expect(me['you'], true);
      expect(me['initials'], 'MM');
      expect(me['lat'], 51.5);
      expect(me['lon'], -0.12001); // rounded to 5 decimals
      final Map<String, dynamic> sam = members[1] as Map<String, dynamic>;
      expect(sam['state'], 'driving');
      expect(sam['speedKmh'], 36);
      expect(sam['fixAt'], fix.millisecondsSinceEpoch);
      final Map<String, dynamic> ana = members[2] as Map<String, dynamic>;
      expect(ana['state'], 'none');
      expect(ana.containsKey('lat'), false);
      // Long notes are cut.
      expect(((s['alerts'] as List<dynamic>).single as Map)['note'].toString().length, 80);
    });

    test('place presence maps to at_place and carries the place name', () {
      final Member m = _m('u1', 'Sam',
          presence: PlacePresence(placeId: 'p', placeName: 'Home', isAt: true, since: _now));
      expect(watchMemberState(m), 'at_place');
      final Map<String, dynamic> s = buildWatchSnapshot(_input(members: <Member>[m]));
      expect(((s['members'] as List<dynamic>).single as Map)['place'], 'Home');
      expect(watchMemberState(_m('x', 'X', status: MemberStatus.stopped)), 'stopped');
      expect(watchMemberState(_m('x', 'X', movement: MovementType.bike)), 'moving');
    });

    test('hiding Private circles removes their people, circles and scope but never you', () {
      final Map<String, dynamic> s = buildWatchSnapshot(_input(
        showPrivate: false,
        priv: <String>{'u1', 'me'},
        scopePrivate: true,
        circles: const <WatchCircle>[
          WatchCircle(id: 'c1', name: 'Secret', isPrivate: true),
          WatchCircle(id: 'c2', name: 'Open'),
        ],
      ));
      expect((s['members'] as List<dynamic>).map((dynamic m) => (m as Map)['id']), <String>['me']);
      expect((s['circles'] as List<dynamic>).map((dynamic c) => (c as Map)['name']), <String>['Open']);
      final Map<String, dynamic> scope = s['scope'] as Map<String, dynamic>;
      expect(scope['private'], false);
      expect(scope['name'], 'Everyone');
      expect(jsonEncode(s).contains('Secret'), false);
      expect(jsonEncode(s).contains('Sam'), false);
    });

    test('private members are flagged when shown', () {
      final Map<String, dynamic> s = buildWatchSnapshot(_input(priv: <String>{'u1'}));
      final List<dynamic> members = s['members'] as List<dynamic>;
      expect((members.firstWhere((dynamic m) => (m as Map)['id'] == 'u1') as Map)['private'], true);
    });

    test('members are capped and the encoded size stays small', () {
      final List<Member> many = <Member>[for (int i = 0; i < 40; i++) _m('u$i', 'Person $i')];
      final Map<String, dynamic> s = buildWatchSnapshot(_input(members: many));
      expect((s['members'] as List<dynamic>).length, kWatchMemberCap);
      expect(utf8.encode(encodeWatchSnapshot(s)).length, lessThan(12 * 1024));
    });

    test('an oversized snapshot drops members from the end until it fits', () {
      final Map<String, dynamic> s = buildWatchSnapshot(_input(members: <Member>[for (int i = 0; i < 10; i++) _m('u$i', 'P$i')]));
      final String enc = encodeWatchSnapshot(s, maxBytes: 1200);
      expect(utf8.encode(enc).length, lessThanOrEqualTo(1200));
      final List<dynamic> kept = (jsonDecode(enc) as Map<String, dynamic>)['members'] as List<dynamic>;
      expect(kept.length, lessThan(10));
      expect(kept.first['id'], 'u0');
    });

    test('content hash ignores the timestamp only', () {
      final Map<String, dynamic> a = buildWatchSnapshot(_input());
      final Map<String, dynamic> b = Map<String, dynamic>.of(a)..['ts'] = 1;
      expect(watchContentHash(a), watchContentHash(b));
      final Map<String, dynamic> c = buildWatchSnapshot(_input(members: <Member>[_m('me', 'Me Myself', battery: 5)]));
      expect(watchContentHash(a), isNot(watchContentHash(c)));
      final Map<String, dynamic> d = buildWatchSnapshot(_input(
          last: WatchCommandResult(id: 'k', cmd: 'sos', ok: true, at: _now)));
      expect(watchContentHash(a), isNot(watchContentHash(d)));
      expect((d['lastCommand'] as Map)['id'], 'k');
    });
  });

  group('WatchCommand.tryParse', () {
    String cmd(String name, {String? arg, Object? id = 'abc', Object? at = 1000}) =>
        jsonEncode(<String, dynamic>{'id': id, 'cmd': name, 'at': at, if (arg != null) 'arg': arg});

    test('accepts the fixed vocabulary', () {
      for (final String n in <String>['sos', 'checkin', 'resume', 'refresh']) {
        expect(WatchCommand.tryParse(cmd(n))?.cmd.name, n);
      }
      expect(WatchCommand.tryParse(cmd('pause', arg: '60'))?.arg, '60');
      expect(WatchCommand.tryParse(cmd('reply', arg: 'omw'))?.arg, 'omw');
      expect(WatchCommand.tryParse(cmd('ack', arg: 'alert-1'))?.arg, 'alert-1');
    });

    test('visible and hidden: the cadence vocabulary, additive', () {
      expect(WatchCommand.tryParse(cmd('visible'))?.cmd, WatchCmd.visible);
      expect(WatchCommand.tryParse(cmd('visible', arg: 'ambient'))?.arg, 'ambient');
      expect(WatchCommand.tryParse(cmd('visible', arg: 'finding'))?.arg, 'finding');
      expect(WatchCommand.tryParse(cmd('hidden'))?.cmd, WatchCmd.hidden);
      expect(WatchCommand.tryParse(cmd('visible', arg: 'always')), isNull);
      expect(WatchCommand.tryParse(cmd('hidden', arg: 'x')), isNull);
    });

    test('rejects unknown commands, bad arguments and malformed input', () {
      expect(WatchCommand.tryParse(cmd('format_disk')), isNull);
      expect(WatchCommand.tryParse(cmd('pause', arg: '5')), isNull);
      expect(WatchCommand.tryParse(cmd('pause')), isNull);
      expect(WatchCommand.tryParse(cmd('reply', arg: 'free text')), isNull);
      expect(WatchCommand.tryParse(cmd('ack')), isNull);
      expect(WatchCommand.tryParse(cmd('sos', id: '')), isNull);
      expect(WatchCommand.tryParse(cmd('sos', id: 5)), isNull);
      expect(WatchCommand.tryParse(cmd('sos', at: 'now')), isNull);
      expect(WatchCommand.tryParse('not json'), isNull);
      expect(WatchCommand.tryParse('[1]'), isNull);
      expect(WatchCommand.tryParse(cmd('reply', arg: 'x' * 600)), isNull);
    });

    test('quick replies are plain fixed text', () {
      expect(kWatchReplies.keys, <String>['ok', 'omw', 'late', 'call', 'thanks']);
    });
  });
}
