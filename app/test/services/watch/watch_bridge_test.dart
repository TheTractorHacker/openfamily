import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:openfamily/models/member.dart';
import 'package:openfamily/services/watch/watch_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeTransport implements WatchTransport {
  WatchLinkStatus st = const WatchLinkStatus(available: true, nodes: 1, names: <String>['Pixel Watch']);
  final List<String> published = <String>[];
  int cleared = 0;
  bool clearDelivers = true;
  int allowed = 0;
  bool failNext = false;
  Future<void> Function(String)? onCommand;
  void Function()? onPeer;

  @override
  Future<bool> publish(String json) async {
    if (failNext) {
      failNext = false;
      return false;
    }
    published.add(json);
    return true;
  }

  @override
  Future<bool> clear() async {
    cleared++;
    return clearDelivers;
  }

  @override
  Future<void> allowPublish() async => allowed++;

  @override
  Future<WatchLinkStatus> status() async => st;

  @override
  void listen({required Future<void> Function(String json) onCommand, required void Function() onPeerChanged}) {
    this.onCommand = onCommand;
    onPeer = onPeerChanged;
  }
}

class FakeActions implements WatchActions {
  final List<String> calls = <String>[];
  Object? failWith;

  Future<void> _do(String s) async {
    calls.add(s);
    if (failWith != null) throw failWith!;
  }

  @override
  Future<void> sos() => _do('sos');
  @override
  Future<void> checkIn() => _do('checkin');
  @override
  Future<DateTime?> pause(int minutes) async {
    await _do('pause:$minutes');
    return null;
  }

  @override
  Future<void> resume() => _do('resume');
  @override
  Future<void> ack(String alertId) => _do('ack:$alertId');
  @override
  Future<void> reply(String text, {String? circleId}) => _do('reply:$text@$circleId');
}

class FakeSource implements WatchContextSource {
  int reads = 0;
  int invalidations = 0;
  WatchContext ctx = const WatchContext(chatCircleId: 'c1', unread: 1);

  Future<void> Function()? onRead;

  @override
  Future<WatchContext> read() async {
    reads++;
    await onRead?.call();
    return ctx;
  }

  @override
  void invalidate() => invalidations++;
}

Member _m(String id, {int battery = 50, double lat = 51.5}) => Member(
      id: id,
      name: id,
      position: LatLng(lat, -0.12),
      status: MemberStatus.normal,
      batteryPercent: battery,
      address: '',
      avatarColor: Colors.blue,
    );

void main() {
  late FakeTransport t;
  late FakeActions a;
  late FakeSource src;
  late DateTime now;
  late WatchBridge b;

  Future<void> settle() async {
    for (int i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<WatchBridge> make({Duration minInterval = const Duration(milliseconds: 80)}) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    t = FakeTransport();
    a = FakeActions();
    src = FakeSource();
    now = DateTime.utc(2026, 1, 1, 12);
    b = WatchBridge(
      transport: t,
      actions: a,
      source: src,
      clock: () => now,
      minInterval: minInterval,
      keepAlive: const Duration(hours: 1),
      sosCooldown: const Duration(seconds: 60),
      commandCooldown: const Duration(seconds: 2),
      supported: true,
    );
    await b.start();
    await settle();
    return b;
  }

  String command(String name, {String? arg, String id = 'k1', DateTime? at}) => jsonEncode(<String, dynamic>{
        'id': id,
        'cmd': name,
        'at': (at ?? now).millisecondsSinceEpoch,
        if (arg != null) 'arg': arg,
      });

  Map<String, dynamic> lastPublished() => jsonDecode(t.published.last) as Map<String, dynamic>;

  tearDown(() => b.disposeForTest());

  test('start publishes once when a watch is connected, and shows the link state', () async {
    await make();
    expect(b.link.value.connected, true);
    expect(t.published.length, 1);
    expect(lastPublished()['signedIn'], true);
  });

  test('nothing is read or published when no watch is connected', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    t = FakeTransport()..st = const WatchLinkStatus(available: true, nodes: 0);
    src = FakeSource();
    b = WatchBridge(transport: t, actions: FakeActions(), source: src, supported: true);
    await b.start();
    b.onMembers(<Member>[_m('u1')]);
    await settle();
    expect(t.published, isEmpty);
    expect(src.reads, 0);
  });

  test('without Play services / on unsupported platforms everything is a no-op', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    t = FakeTransport();
    b = WatchBridge(transport: t, actions: FakeActions(), source: FakeSource(), supported: false);
    await b.start();
    b.onMembers(<Member>[_m('u1')]);
    await b.signedOut();
    await settle();
    expect(t.published, isEmpty);
    expect(t.cleared, 0);
    expect(t.onCommand, isNull);

    t = FakeTransport()..st = const WatchLinkStatus(); // available: false
    b = WatchBridge(transport: t, actions: FakeActions(), source: FakeSource(), supported: true);
    await b.start();
    b.onMembers(<Member>[_m('u1')]);
    await settle();
    expect(t.published, isEmpty);
    expect(b.link.value.connected, false);
  });

  test('unchanged content is not published again, changed content is, within the rate limit', () async {
    await make();
    t.published.clear();
    // Same content: dropped.
    b.onMembers(<Member>[_m('u1')]);
    await settle();
    final int afterFirst = t.published.length;
    expect(afterFirst, 1);
    now = now.add(const Duration(seconds: 1));
    b.onMembers(<Member>[_m('u1')]);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(t.published.length, afterFirst);

    // A change inside the interval is held back and then goes out once (trailing edge, newest data).
    now = now.add(const Duration(milliseconds: 10));
    b.onMembers(<Member>[_m('u1', battery: 40)]);
    b.onMembers(<Member>[_m('u1', battery: 30)]);
    b.onMembers(<Member>[_m('u1', battery: 20)]);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(t.published.length, afterFirst + 1);
    final List<dynamic> ms = lastPublished()['members'] as List<dynamic>;
    expect((ms.single as Map)['battery'], 20);
  });

  test('a failed publish is retried by the next change', () async {
    await make();
    t.published.clear();
    t.failNext = true;
    b.onMembers(<Member>[_m('u1')]);
    await settle();
    expect(t.published, isEmpty);
    now = now.add(const Duration(seconds: 10));
    b.onMembers(<Member>[_m('u1')]);
    await settle();
    expect(t.published.length, 1);
  });

  test('signed out clears the watch', () async {
    await make();
    await b.signedOut();
    expect(t.cleared, 1);
  });

  test('turning the bridge off clears, on publishes again', () async {
    await make();
    await b.setEnabled(false);
    expect(t.cleared, 1);
    final int n = t.published.length;
    b.onMembers(<Member>[_m('u1')]);
    await settle();
    expect(t.published.length, n);
    await b.setEnabled(true);
    await settle();
    expect(t.published.length, n + 1);
  });

  group('sign-out clear', () {
    test('an undeliverable clear stays pending, blocks publishing and survives a restart', () async {
      await make();
      t.clearDelivers = false;
      await b.signedOut();
      final int n = t.published.length;
      b.onMembers(<Member>[_m('u1')]);
      await b.publish(force: true);
      await settle();
      expect(t.published.length, n);
      expect((await SharedPreferences.getInstance()).getBool(WatchBridge.clearPendingKey), true);

      // New bridge instance on the same prefs (app restart): still refuses until a new sign-in.
      final FakeTransport t2 = FakeTransport();
      final WatchBridge b2 = WatchBridge(transport: t2, actions: FakeActions(), source: FakeSource(), supported: true, minInterval: Duration.zero);
      await b2.start();
      await settle();
      expect(t2.cleared, greaterThan(0)); // retried at start (a watch is connected now)
      expect((await SharedPreferences.getInstance()).getBool(WatchBridge.clearPendingKey), false);
      b2.disposeForTest();
    });

    test('retried when a watch connects; refuses until the user signs in again', () async {
      await make();
      t.clearDelivers = false;
      await b.signedOut();
      expect(t.cleared, 1);
      t.st = const WatchLinkStatus(available: true, nodes: 0);
      t.onPeer!();
      await settle();
      // Still not delivered: still pending.
      t.clearDelivers = true;
      t.st = const WatchLinkStatus(available: true, nodes: 1);
      t.onPeer!();
      await settle();
      expect(t.cleared, 3);
      // Delivered, but publishing stays refused (roster events after sign-out are stale).
      final int n = t.published.length;
      b.onMembers(<Member>[_m('u1')]);
      await settle();
      expect(t.published.length, n);
      // A new login re-enables it.
      await b.signedIn();
      await settle();
      expect(t.allowed, 1);
      expect(t.published.length, n + 1);
      expect(lastPublished()['signedIn'], true);
    });

    test('an in-flight snapshot cannot override a clear', () async {
      await make();
      src.onRead = () async => b.signedOut();
      t.published.clear();
      await b.publish(force: true);
      await settle();
      expect(t.published, isEmpty);
    });

    test('turning the bridge off is a pending clear until delivered', () async {
      await make();
      t.clearDelivers = false;
      await b.setEnabled(false);
      expect((await SharedPreferences.getInstance()).getBool(WatchBridge.clearPendingKey), true);
      await b.setEnabled(true);
      expect(t.allowed, 1);
    });
  });

  group('commands', () {
    test('sos runs the action and the result goes back in the next snapshot', () async {
      await make();
      await t.onCommand!(command('sos', id: 's1'));
      await settle();
      expect(a.calls, <String>['sos']);
      final Map<String, dynamic> r = lastPublished()['lastCommand'] as Map<String, dynamic>;
      expect(r['id'], 's1');
      expect(r['ok'], true);
      expect(r['cmd'], 'sos');
      expect(src.invalidations, 1);
    });

    test('check-in, pause, resume, ack and reply call the existing services', () async {
      await make();
      Future<void> run(String name, String id, {String? arg}) async {
        now = now.add(const Duration(seconds: 3));
        await t.onCommand!(command(name, arg: arg, id: id));
      }

      await run('checkin', 'a');
      await run('pause', 'b', arg: '60');
      await run('resume', 'c');
      await run('ack', 'd', arg: 'alert-9');
      await run('reply', 'e', arg: 'omw');
      expect(a.calls, <String>['checkin', 'pause:60', 'resume', 'ack:alert-9', "reply:On my way@c1"]);
    });

    test('a failing action reports ok:false with a plain message', () async {
      await make();
      a.failWith = Exception('boom');
      await t.onCommand!(command('checkin', id: 'f1'));
      await settle();
      final Map<String, dynamic> r = lastPublished()['lastCommand'] as Map<String, dynamic>;
      expect(r['ok'], false);
      expect(r['message'], isNotEmpty);
      expect(r['message'].toString().contains('boom'), false);
    });

    test('invalid, unknown and replayed commands do nothing', () async {
      await make();
      await t.onCommand!('garbage');
      await t.onCommand!(command('reply', arg: 'free text', id: 'x1'));
      await t.onCommand!(command('wipe', id: 'x2'));
      expect(a.calls, isEmpty);
      await t.onCommand!(command('checkin', id: 'dup'));
      now = now.add(const Duration(seconds: 5));
      await t.onCommand!(command('checkin', id: 'dup', at: now));
      expect(a.calls, <String>['checkin']);
    });

    test('stale or far-future commands are refused', () async {
      await make();
      await t.onCommand!(command('sos', id: 'old', at: now.subtract(const Duration(minutes: 5))));
      await settle();
      expect(a.calls, isEmpty);
      expect((lastPublished()['lastCommand'] as Map)['ok'], false);
      await t.onCommand!(command('sos', id: 'future', at: now.add(const Duration(minutes: 5))));
      expect(a.calls, isEmpty);
    });

    test('a second SOS within 60 s is not sent again; after it, it is', () async {
      await make();
      await t.onCommand!(command('sos', id: 's1'));
      now = now.add(const Duration(seconds: 20));
      await t.onCommand!(command('sos', id: 's2', at: now));
      expect(a.calls, <String>['sos']);
      final Map<String, dynamic> r = lastPublished()['lastCommand'] as Map<String, dynamic>;
      expect(r['id'], 's2');
      expect(r['ok'], true); // the first one is out, the watch should not panic
      now = now.add(const Duration(seconds: 61));
      await t.onCommand!(command('sos', id: 's3', at: now));
      expect(a.calls, <String>['sos', 'sos']);
    });

    test('same non-SOS command twice within 2 s is throttled', () async {
      await make();
      await t.onCommand!(command('pause', arg: '15', id: 'p1'));
      now = now.add(const Duration(milliseconds: 500));
      await t.onCommand!(command('pause', arg: '15', id: 'p2', at: now));
      expect(a.calls, <String>['pause:15']);
    });

    test('commands are ignored while the bridge is off', () async {
      await make();
      await b.setEnabled(false);
      await t.onCommand!(command('sos', id: 'z'));
      expect(a.calls, isEmpty);
    });
  });
}
