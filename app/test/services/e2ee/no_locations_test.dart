
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/circle.dart';
import 'package:openfamily/services/e2ee/private_channel.dart';
import 'package:openfamily/services/e2ee/private_runtime.dart';

import '../../support/fake_e2ee_server.dart';
import 'private_channel_test.dart' show FakeServer, FakeClock;
import 'private_runtime_test.dart' show Device, circleOf, priv, uA, uB;

/// Regression tests for "the family app shows nobody's location" (docs/troubleshooting/no-locations.md).
void main() {
  late FakeE2eeServer e2eeServer;
  late FakeServer channel;
  late FakeClock clock;

  Map<String, dynamic> loc(double lat, double lon, {DateTime? at}) => <String, dynamic>{
        'device_id': 'x', 'ts': (at ?? clock.t).toIso8601String(), 'lat': lat, 'lon': lon,
        'accuracy_meters': 8.0, 'speed_mps': 1.0, 'battery_pct': 77, 'motion_state': '', 'source': 'foreground',
      };

  setUp(() {
    e2eeServer = FakeE2eeServer()..names.addAll(<String, String>{uA: 'Alice', uB: 'Bob'});
    e2eeServer.circle(priv, members: <String>[uA, uB], admin: uA);
    channel = FakeServer();
    clock = FakeClock(DateTime.utc(2026, 11, 6, 12));
  });

  // Alice enables the circle AFTER Bob registered his phone, so a key wrap for Bob exists on the server,
  // but Bob's phone never fetched it (the production state of the Foley circle).
  Future<(Device, Device)> wrappedButNotFetched() async {
    final Device a = Device(e2eeServer, channel, uA, clock);
    final Device b = Device(e2eeServer, channel, uB, clock);
    await a.service.registerThisDevice();
    await b.service.registerThisDevice();
    await a.service.enableCircle(priv);
    expect(await b.service.heldEpochs(priv), isEmpty);
    return (a, b);
  }

  test('a phone with a key wrap it never fetched fetches it when the app opens, then sends', () async {
    final (Device a, Device b) = await wrappedButNotFetched();
    await a.runtime.setCircles(<Circle>[circleOf(priv, isPrivate: true)]);
    await a.runtime.routeFix(loc(52.5, 13.4));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await a.runtime.flush();

    await b.runtime.onAppActive(<Circle>[circleOf(priv, isPrivate: true)]);
    expect(await b.service.heldEpochs(priv), <int>[1], reason: 'the wrap addressed to this phone must be opened on app open');
    // Reading: Alice's earlier fix, delivered before Bob had a key, now shows.
    expect(b.frames.where((Map<String, dynamic> f) => f['user_id'] == uA), isNotEmpty);
    // Sending
    await b.runtime.routeFix(loc(40, -75));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await b.runtime.flush();
    expect(channel.items.where((WireItem i) => i.deviceId != channel.items.first.deviceId), isNotEmpty);
  });

  test('a fix taken while the key is missing is parked, the key is fetched, and the fix is sent (no deadlock)', () async {
    final (Device _, Device b) = await wrappedButNotFetched();
    await b.runtime.setCircles(<Circle>[circleOf(priv, isPrivate: true)]);
    expect(await b.runtime.routeFix(loc(1, 2)), isFalse);
    for (int i = 0; i < 60 && await b.runtime.queue.length() == 0 && channel.items.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(await b.service.heldEpochs(priv), <int>[1]);
    // Sealed once the key arrived (it may already have been uploaded by the jittered flush).
    expect(await b.runtime.queue.length() + channel.items.length, 1);
  });

  test('a long-lived background runtime notices that a circle turned private', () async {
    final Device a = Device(e2eeServer, channel, uA, clock);
    await a.service.registerThisDevice();
    await a.service.enableCircle(priv);
    await a.runtime.setCircles(<Circle>[circleOf(priv)]); // standard at first
    final PrivateRuntime bg = PrivateRuntime(
        service: a.service, api: e2eeServer.client(uA), kv: a.kv, clock: clock, channel: channel);
    expect(await bg.routeFix(loc(1, 2)), isTrue); // plaintext, as before
    await a.runtime.setCircles(<Circle>[circleOf(priv, isPrivate: true)]); // the foreground learns it
    expect(await bg.routeFix(loc(1, 2, at: clock.t.add(const Duration(minutes: 1)))), isFalse,
        reason: 'the background isolate must not keep sending plaintext (the server refuses it) after the circle turned private');
  });

  test('a circle that turns private gets the last known position at once', () async {
    final Device a = Device(e2eeServer, channel, uA, clock);
    await a.service.registerThisDevice();
    await a.service.enableCircle(priv);
    await a.runtime.setCircles(<Circle>[circleOf(priv)]);
    expect(await a.runtime.routeFix(loc(52.5, 13.4)), isTrue);
    await a.runtime.onAppActive(<Circle>[circleOf(priv, isPrivate: true)]);
    expect(channel.items.where((WireItem i) => i.purpose == ChannelPurpose.fix), hasLength(1));
  });

  test('opening the app sends the last fix when nothing was sent for a while', () async {
    final Device a = Device(e2eeServer, channel, uA, clock);
    await a.service.registerThisDevice();
    await a.service.enableCircle(priv);
    await a.runtime.setCircles(<Circle>[circleOf(priv, isPrivate: true)]);
    await a.runtime.routeFix(loc(52.5, 13.4));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await a.runtime.flush();
    final int first = channel.items.length;
    clock.t = clock.t.add(const Duration(minutes: 10));
    await a.runtime.onAppActive(<Circle>[circleOf(priv, isPrivate: true)]);
    expect(channel.items.length, first + 1);
  });

  group('upload failures', () {
    test('being offline or having a session in renewal never uses up an item', () async {
      final Device a = Device(e2eeServer, channel, uA, clock);
      await a.service.registerThisDevice();
      await a.service.enableCircle(priv);
      await a.runtime.setCircles(<Circle>[circleOf(priv, isPrivate: true)]);
      await a.runtime.routeFix(loc(1, 2));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final _Flaky api = _Flaky(const UploadUnavailable('401'));
      for (int i = 0; i < 40; i++) {
        await a.runtime.queue.flush(api, deviceFor: (_) => 'd');
      }
      expect(await a.runtime.queue.length(), 1);
    });

    test('a refusal that can never succeed is remembered, not silent', () async {
      final Device a = Device(e2eeServer, channel, uA, clock);
      await a.service.registerThisDevice();
      await a.service.enableCircle(priv);
      await a.runtime.setCircles(<Circle>[circleOf(priv, isPrivate: true)]);
      await a.runtime.routeFix(loc(1, 2));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await a.runtime.queue.flush(_Flaky(const PermanentUploadError('403')), deviceFor: (_) => 'd');
      final und = await a.runtime.queue.undelivered(priv);
      expect(und, isNotNull);
      expect(und!.code, 'http_403');
    });
  });
}

class _Flaky implements ChannelApi {
  _Flaky(this.error);
  final Object error;
  @override
  Future<List<BatchResult>> postBatch(String circleId, String deviceId, List<WireItem> items) async => throw error;
  @override
  Future<Page> pull(String circleId, int after, {List<String>? purposes, int limit = 200}) async => throw error;
}
