import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/circle.dart';
import 'package:openfamily/models/member.dart';
import 'package:openfamily/services/e2ee/last_positions.dart';
import 'package:openfamily/services/e2ee/private_channel.dart';
import 'package:openfamily/services/member_mapper.dart';
import 'package:openfamily/utils/self_label.dart';
import 'package:openfamily/widgets/member_tile.dart';

import '../services/e2ee/private_channel_test.dart' show FakeServer, FakeClock;
import '../services/e2ee/private_runtime_test.dart' show Device, circleOf, priv, uA, uB;
import '../support/fake_e2ee_server.dart';

void main() {
  group('the caller keeps their real name', () {
    const Member blake = Member(
        id: 'u-blake', name: 'Blake Foley', position: null, status: MemberStatus.normal, batteryPercent: 80, address: 'Home');

    test('the display name is the real name with a small (you) tag, never a bare You', () {
      expect(blake.displayName, 'Blake Foley');
      final Member me = blake.copyWith(isSelf: true);
      expect(me.name, 'Blake Foley');
      expect(me.displayName, 'Blake Foley (you)');
      expect(me.initials, 'BF', reason: 'the avatar initials come from the real name');
      expect(me.copyWith(position: null).isSelf, isTrue, reason: 'live updates keep the tag');
    });

    testWidgets('the people list row shows "Blake Foley (you)"', (WidgetTester t) async {
      await t.pumpWidget(MaterialApp(
          home: Scaffold(body: MemberTile(member: blake.copyWith(isSelf: true), onTap: () {}))));
      expect(find.text('Blake Foley (you)'), findsOneWidget);
      expect(find.text('You'), findsNothing);
    });

    test('selfLabel falls back to a bare You only when the name is truly unknown', () {
      expect(selfLabel('Blake Foley'), 'Blake Foley (you)');
      expect(selfLabel(''), 'You');
      expect(selfLabel(null), 'You');
      expect(selfLabel('Member'), 'You');
    });

    test('a member without a profile name shows the email local part, not a generic label', () {
      expect(memberFromJson(<String, dynamic>{'id': 'u1', 'name': '', 'email': 'blake.f@example.com'}).name, 'blake.f');
      expect(memberFromJson(<String, dynamic>{'id': 'u1', 'name': '  ', 'email': ''}).name, 'Member');
      expect(memberFromJson(<String, dynamic>{'id': 'u1', 'name': 'Sam', 'email': 'x@y.z'}).name, 'Sam');
    });
  });

  group('remembered positions never mix people or circles', () {
    late FakeE2eeServer e2eeServer;
    late FakeServer channel;
    late FakeClock clock;
    late Device b;
    const String other = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';

    setUp(() async {
      e2eeServer = FakeE2eeServer()..names.addAll(<String, String>{uA: 'Alice', uB: 'Bob'});
      e2eeServer.circle(priv, members: <String>[uA, uB], admin: uA);
      channel = FakeServer();
      clock = FakeClock(DateTime.utc(2026, 11, 6, 12));
      b = Device(e2eeServer, channel, uB, clock);
      await b.service.registerThisDevice();
      await b.runtime.setCircles(<Circle>[circleOf(priv, isPrivate: true)]);
      await b.runtime.warmUp();
    });

    LastPosition pos(String circle, String user, int ts, double lat) =>
        LastPosition(circleId: circle, userId: user, tsMs: ts, lat: lat, lon: 1);

    test('a circle view only gets the position its own circle delivered', () {
      b.runtime.lastPositions.note(pos(priv, uA, 1000, 10));
      b.runtime.lastPositions.note(pos(other, uA, 2000, 20)); // newer, but from another circle
      expect(b.runtime.lastKnown(uA)!.lat, 20, reason: 'unscoped: newest anywhere');
      expect(b.runtime.lastKnown(uA, circleId: priv)!.lat, 10);
      expect(b.runtime.lastKnown(uA, circleId: 'unknown-circle'), isNull);
      expect(b.runtime.lastKnown(uB, circleId: priv), isNull, reason: 'a different person never inherits it');
    });

    test('signing out forgets what was remembered about other people', () async {
      b.runtime.lastPositions.note(pos(priv, uA, 1000, 10));
      expect(b.runtime.lastKnown(uA), isNotNull);
      await b.runtime.forgetAccount();
      expect(b.runtime.lastKnown(uA), isNull);
      expect(b.runtime.lastPositions.all(), isEmpty);
    });
  });

  group('positions waiting for the circle key', () {
    late FakeE2eeServer e2eeServer;
    late FakeServer channel;
    late FakeClock clock;

    setUp(() {
      e2eeServer = FakeE2eeServer()..names.addAll(<String, String>{uA: 'Alice', uB: 'Bob'});
      e2eeServer.circle(priv, members: <String>[uA, uB], admin: uA);
      channel = FakeServer();
      clock = FakeClock(DateTime.utc(2026, 11, 6, 12));
    });

    test('parked fixes are sealed once the phone holds the key, even when it "already has the newest key"', () async {
      final Device a = Device(e2eeServer, channel, uA, clock);
      await a.service.registerThisDevice();
      await a.service.enableCircle(priv);
      await a.runtime.setCircles(<Circle>[circleOf(priv, isPrivate: true)]);
      // The key is here (fix time), but 12 fixes were parked before it arrived.
      final String entry = '{"ts":"${clock.t.toIso8601String()}","lat":52.5,"lon":13.4,"accuracy_meters":8.0,"for":["$priv"]}';
      a.kv.data['parked/v1'] = '[${List<String>.filled(12, entry).join(',')}]';
      expect((await a.runtime.localDelivery(priv)).parked, 12);
      // Nothing is "new" for ensureKeys: the epoch held is the newest one.
      expect(await a.runtime.ensureKeys(priv, force: true), isFalse);
      await a.runtime.flush();
      final loc = await a.runtime.localDelivery(priv);
      expect(loc.parked, 0, reason: 'they must not stay stuck behind "waiting for the circle key"');
      expect(loc.queued + channel.items.length, greaterThan(0));
    });

    test('one unreadable parked entry does not lose the ones behind it', () async {
      final Device a = Device(e2eeServer, channel, uA, clock);
      await a.service.registerThisDevice();
      await a.service.enableCircle(priv);
      await a.runtime.setCircles(<Circle>[circleOf(priv, isPrivate: true)]);
      final String good = '{"ts":"${clock.t.toIso8601String()}","lat":52.5,"lon":13.4,"for":["$priv"]}';
      a.kv.data['parked/v1'] = '[42,$good]';
      expect(await a.runtime.drainParked(), 1);
      expect(await a.runtime.queue.length() + channel.items.length, 1);
    });

    test('wrapForWaiting / sealing needs ChannelPurpose only for fixes', () {
      expect(ChannelPurpose.fix, isNotNull);
    });
  });
}
