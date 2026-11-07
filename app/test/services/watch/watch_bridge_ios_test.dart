import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:openfamily/models/member.dart';
import 'package:openfamily/services/watch/watch_actions.dart';
import 'package:openfamily/services/watch/watch_bridge_ios.dart';
import 'package:openfamily/services/watch/watch_snapshot.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Actions implements WatchPhoneActions {
  final List<String> calls = <String>[];
  Object? fail;

  void _go(String c) {
    calls.add(c);
    if (fail != null) throw fail!;
  }

  @override
  Future<WatchExtras> extras() async {
    calls.add('extras');
    return const WatchExtras(circles: <WatchCircle>[WatchCircle(id: 'c1', name: 'Family', unread: 2)]);
  }

  @override
  Future<void> sos() async => _go('sos');
  @override
  Future<void> resolveSos() async => _go('resolve');
  @override
  Future<void> checkIn(List<String> ids) async => _go('checkin:${ids.join(",")}');
  @override
  Future<void> pause(int m) async => _go('pause:$m');
  @override
  Future<void> resume() async => _go('resume');
  @override
  Future<void> reply(String c, String t) async => _go('reply:$c:$t');
  @override
  Future<void> markRead(String c) async => _go('read:$c');
}

class _GatedActions extends _Actions {
  _GatedActions(this.gate);
  final Completer<void> gate;
  @override
  Future<WatchExtras> extras() async {
    await gate.future;
    return const WatchExtras();
  }
}

Member _m(String id, String name, LatLng? pos,
        {MovementType mv = MovementType.none, double? mps, PlacePresence? pp, int battery = 80}) =>
    Member(
      id: id,
      name: name,
      position: pos,
      status: MemberStatus.normal,
      batteryPercent: battery,
      address: '1 Main St',
      avatarColor: Colors.teal,
      movement: mv,
      speedMps: mps,
      placePresence: pp,
      lastSeen: DateTime.utc(2026, 1, 1),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel ch = MethodChannel('app.openfamily/watch');
  late List<MethodCall> sent;
  late Map<String, dynamic> statusReply;
  DateTime now = DateTime.utc(2026, 1, 1, 12);

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    sent = <MethodCall>[];
    statusReply = <String, dynamic>{'supported': true, 'paired': true, 'installed': true, 'reachable': true};
    now = DateTime.utc(2026, 1, 1, 12);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(ch, (MethodCall c) async {
      sent.add(c);
      return c.method == 'status' ? statusReply : null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(ch, null);
  });

  WatchBridgeIos make(_Actions a, {bool supported = true}) =>
      WatchBridgeIos(channel: ch, actions: a, supported: supported, clock: () => now, throttle: Duration.zero);

  test('snapshot has distance/bearing, no raw coordinates, capped and tolerant', () {
    final Member me = _m('me', 'Me Self', const LatLng(0, 0));
    final Member north = _m('a', 'Anna Bell', const LatLng(0.01, 0), mv: MovementType.car, mps: 18.8);
    final Member none = _m('b', 'Bo', null);
    final Map<String, dynamic> s = buildWatchSnapshot(
      members: <Member>[me, north, none],
      myId: 'me',
      myName: 'Me Self',
      activeCircleId: 'c1',
      circles: const <WatchCircle>[WatchCircle(id: 'c1', name: 'Family', unread: 3), WatchCircle(id: 'c2', name: 'Team')],
      sharing: true,
      now: now,
    );
    final String text = jsonEncode(s);
    expect(text.contains('latitude'), isFalse);
    expect(text.contains('"lat"'), isFalse);
    final List<dynamic> cs = s['circles'] as List<dynamic>;
    expect(cs.length, 2);
    expect((cs[1] as Map)['members'], isEmpty);
    final List<dynamic> ms = (cs[0] as Map)['members'] as List<dynamic>;
    final Map<String, dynamic> a = ms[1] as Map<String, dynamic>;
    expect(a['state'], 'driving');
    expect(a['initials'], 'AB');
    expect((a['distanceM'] as num), closeTo(1112, 5));
    expect((a['bearingDeg'] as num), 0);
    expect((ms[0] as Map)['me'], true);
    expect((ms[0] as Map)['distanceM'], isNull);
    expect((ms[2] as Map)['hasPosition'], false);
    expect(s['v'], 1);
    expect((s['quickReplies'] as List).length, kWatchQuickReplies.length);
  });

  test('bearing and distance sanity', () {
    expect(watchBearingDegrees(0, 0, 0, 1), closeTo(90, 0.01));
    expect(watchBearingDegrees(0, 0, -1, 0), closeTo(180, 0.01));
    expect(watchBearingDegrees(0, 0, 0, -1), closeTo(270, 0.01));
    expect(watchDistanceMeters(0, 0, 0, 0), 0);
  });

  test('unsupported platform never touches the channel', () async {
    final WatchBridgeIos b = make(_Actions(), supported: false);
    await b.start();
    b.onRoster(<Member>[_m('me', 'Me', const LatLng(1, 1))], userId: 'me', circleId: 'c1');
    await b.pushNow();
    expect(sent, isEmpty);
    expect(b.isSupported, isFalse);
  });

  test('no paired watch: status asked once, nothing pushed', () async {
    statusReply = <String, dynamic>{'supported': true, 'paired': false, 'installed': false, 'reachable': false};
    final _Actions a = _Actions();
    final WatchBridgeIos b = make(a);
    await b.start();
    b.onRoster(<Member>[_m('me', 'Me', const LatLng(1, 1))], userId: 'me', circleId: 'c1');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(sent.map((MethodCall c) => c.method), <String>['status']);
    expect(a.calls, isEmpty);
  });

  test('paired watch: roster change pushes one snapshot; switch off clears', () async {
    final _Actions a = _Actions();
    final WatchBridgeIos b = make(a);
    await b.start();
    b.onRoster(<Member>[_m('me', 'Me', const LatLng(1, 1)), _m('x', 'Xi', const LatLng(1, 1.01))],
        userId: 'me', circleId: 'c1');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final MethodCall snap = sent.firstWhere((MethodCall c) => c.method == 'snapshot');
    final Map<String, dynamic> j = jsonDecode(snap.arguments as String) as Map<String, dynamic>;
    expect(((j['circles'] as List).first as Map)['unread'], 2);
    expect(((j['circles'] as List).first as Map)['name'], 'Family');
    await b.setEnabled(false);
    expect(sent.last.method, 'clear');
    final int n = sent.length;
    b.onRoster(<Member>[_m('me', 'Me', null)], userId: 'me', circleId: 'c1');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(sent.length, n);
  });

  test('commands run through the actions and answer the watch', () async {
    final _Actions a = _Actions();
    final WatchBridgeIos b = make(a);
    await b.start();
    b.onRoster(<Member>[_m('me', 'Me', null), _m('x', 'Xi', null), _m('y', 'Yo', null)], userId: 'me', circleId: 'c1');
    expect((await b.handleCommand(<String, Object?>{'cmd': 'sos'}))['ok'], true);
    expect((await b.handleCommand(<String, Object?>{'cmd': 'checkin'}))['ok'], true);
    expect((await b.handleCommand(<String, Object?>{'cmd': 'pause', 'minutes': 5}))['ok'], true);
    expect((await b.handleCommand(<String, Object?>{'cmd': 'reply', 'circleId': 'c1', 'text': 'OK'}))['ok'], true);
    expect(a.calls, containsAllInOrder(<String>['sos', 'checkin:x,y', 'pause:15', 'reply:c1:OK']));
    expect((await b.handleCommand(<String, Object?>{'cmd': 'bogus'}))['ok'], false);
    expect((await b.handleCommand(<String, Object?>{'cmd': 'reply', 'circleId': 1}))['ok'], false);
  });

  test('a failing action reports plain words, not an exception', () async {
    final _Actions a = _Actions()..fail = const WatchCommandException('Nope.');
    final WatchBridgeIos b = make(a);
    await b.start();
    final Map<String, dynamic> r = await b.handleCommand(<String, Object?>{'cmd': 'sos'});
    expect(r['ok'], false);
    expect(r['message'], 'Nope.');
    a.fail = StateError('boom');
    final Map<String, dynamic> r2 = await b.handleCommand(<String, Object?>{'cmd': 'sos'});
    expect(r2['ok'], false);
    expect(r2['message'], isNot(contains('boom')));
  });

  test('commands are refused while the switch is off', () async {
    final _Actions a = _Actions();
    final WatchBridgeIos b = make(a);
    await b.start();
    await b.setEnabled(false);
    expect((await b.handleCommand(<String, Object?>{'cmd': 'sos'}))['ok'], false);
    expect(a.calls, isEmpty);
  });

  test('after clear no snapshot is sent until signedIn', () async {
    final _Actions a = _Actions();
    final WatchBridgeIos b = make(a);
    await b.start();
    final List<Member> roster = <Member>[_m('me', 'Me', const LatLng(1, 1))];
    await b.clear();
    expect(sent.last.method, 'clear');
    b.onRoster(roster, userId: 'me', circleId: 'c1');
    await b.pushNow();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(sent.where((MethodCall c) => c.method == 'snapshot'), isEmpty);
    await b.signedIn();
    expect(sent.last.method, 'signedIn');
    b.onRoster(roster, userId: 'me', circleId: 'c1');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(sent.where((MethodCall c) => c.method == 'snapshot'), isNotEmpty);
  });

  test('clear while disconnected is still sent to the native side (which keeps it pending)', () async {
    statusReply = <String, dynamic>{'supported': true, 'paired': false, 'installed': false, 'reachable': false};
    final WatchBridgeIos b = make(_Actions());
    await b.start();
    await b.clear();
    expect(sent.map((MethodCall c) => c.method), contains('clear'));
    // The watch comes back: a status change must not trigger a push either.
    statusReply = <String, dynamic>{'supported': true, 'paired': true, 'installed': true, 'reachable': true};
    await b.debugStatusChanged(statusReply);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(sent.where((MethodCall c) => c.method == 'snapshot'), isEmpty);
  });

  test('an in-flight push is dropped when clear happens meanwhile', () async {
    final Completer<void> gate = Completer<void>();
    final _GatedActions a = _GatedActions(gate);
    final WatchBridgeIos b = make(a);
    await b.start();
    b.onRoster(<Member>[_m('me', 'Me', const LatLng(1, 1))], userId: 'me', circleId: 'c1');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await b.clear();
    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(sent.where((MethodCall c) => c.method == 'snapshot'), isEmpty);
  });

  test('status parsing is tolerant', () {
    expect(WatchStatus.fromMap(null).listening, isFalse);
    expect(WatchStatus.fromMap(<String, dynamic>{'supported': true, 'paired': true, 'installed': true}).listening, isTrue);
  });
}
