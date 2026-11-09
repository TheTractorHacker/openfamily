import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:openfamily/models/circle.dart';
import 'package:openfamily/services/e2ee/e2ee_service.dart';
import 'package:openfamily/services/e2ee/e2ee_trust.dart';
import 'package:openfamily/services/e2ee/item_open_job.dart';
import 'package:openfamily/services/e2ee/e2ee_vault.dart';
import 'package:openfamily/services/e2ee/private_channel.dart';
import 'package:openfamily/services/e2ee/private_runtime.dart';

import '../services/e2ee/private_channel_test.dart' show FakeServer, FakeClock;
import 'fake_e2ee_server.dart';

const String benchA = '11111111-1111-4111-8111-111111111111';
const String benchB = '22222222-2222-4222-8222-222222222222';
const String benchCircle = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';

/// A [MemoryKv] that counts what the runtime asks of the key-value store (on a phone every one of these is a
/// platform-channel round trip, and `getFresh` is a full reload of the preferences file).
class CountingKv extends MemoryKv {
  int gets = 0, fresh = 0, sets = 0, removes = 0, bytesSet = 0;
  @override
  Future<String?> get(String key) {
    gets++;
    return super.get(key);
  }

  @override
  Future<String?> getFresh(String key) {
    fresh++;
    return super.getFresh(key);
  }

  @override
  Future<void> set(String key, String value) {
    sets++;
    bytesSet += value.length;
    return super.set(key, value);
  }

  @override
  Future<void> remove(String key) {
    removes++;
    return super.remove(key);
  }

  int get totalBytesStored => data.values.fold(0, (int a, String v) => a + v.length);
}

/// A [MemoryVault] that counts reads (Android Keystore + EncryptedSharedPreferences on a phone: milliseconds each).
class CountingVault extends MemoryVault {
  int reads = 0, namesCalls = 0;
  @override
  Future<Uint8List?> read(String name) {
    reads++;
    return super.read(name);
  }

  @override
  Future<List<String>> names() {
    namesCalls++;
    return super.names();
  }
}

Circle benchCircleOf(String id) => Circle(
    id: id, name: id, role: 'member', sharingEnabled: true, memberCount: 2, e2eeMode: 'private');

class BenchPhone {
  BenchPhone(FakeE2eeServer server, FakeServer channel, this.user, FakeClock clock, {OpenRunner opener = const InlineOpenRunner()})
      : vault = CountingVault(),
        kv = CountingKv() {
    service = E2eeService(
        api: server.client(user), vault: vault, trust: TrustStore(MemoryTrustKv()), userIdProvider: () async => user);
    runtime = PrivateRuntime(
        service: service, api: server.client(user), kv: kv, clock: clock, channel: channel,
        directory: StateSenderDirectory(server.client(user)), opener: opener);
    runtime.notify = (String t, String b) async {};
    runtime.chatNotify = (String t, String b) async {};
    runtime.onMemberFrame = frames.add;
  }
  final String user;
  final CountingVault vault;
  final CountingKv kv;
  late final E2eeService service;
  late final PrivateRuntime runtime;
  final List<Map<String, dynamic>> frames = <Map<String, dynamic>>[];
}

/// Two phones in one Private circle over a fake relay. A is the sender, B the receiver under measurement.
class BenchWorld {
  late FakeE2eeServer e2eeServer;
  late FakeServer channel;
  late FakeClock clock;
  late BenchPhone a, b;

  static Future<BenchWorld> make({OpenRunner? receiverOpener}) async {
    final BenchWorld w = BenchWorld();
    w.e2eeServer = FakeE2eeServer()..names.addAll(<String, String>{benchA: 'Alice', benchB: 'Bob'});
    w.e2eeServer.circle(benchCircle, members: <String>[benchA, benchB], admin: benchA);
    w.channel = FakeServer();
    w.clock = FakeClock(DateTime.utc(2026, 11, 6, 12));
    w.a = BenchPhone(w.e2eeServer, w.channel, benchA, w.clock);
    w.b = BenchPhone(w.e2eeServer, w.channel, benchB, w.clock, opener: receiverOpener ?? const InlineOpenRunner());
    await w.a.service.registerThisDevice();
    await w.b.service.registerThisDevice();
    await w.a.service.enableCircle(benchCircle);
    await w.b.service.syncCircleKeys(benchCircle);
    await w.a.runtime.setCircles(<Circle>[benchCircleOf(benchCircle)]);
    await w.b.runtime.setCircles(<Circle>[benchCircleOf(benchCircle)]);
    return w;
  }

  /// Alice seals [n] fixes, 10 s apart, ending now, and uploads them.
  Future<void> aliceSends(int n) async {
    for (int i = 0; i < n; i++) {
      final DateTime at = clock.t.subtract(Duration(seconds: (n - i) * 10));
      await a.runtime.queueSealed(benchCircle, ChannelPurpose.fix, <String, dynamic>{
        'lat': 52.5 + i * 0.0001, 'lon': 13.4 + i * 0.0001, 'acc': 8.0, 'spd': 1.2, 'bat': 77, 'mo': 'walking',
      }, at: at);
    }
    while (await a.runtime.flush() > 0) {}
  }
}

/// Measures the longest stretch the event loop was blocked (the UI isolate cannot draw a frame during it).
class LoopLag {
  final Stopwatch _sw = Stopwatch();
  Timer? _t;
  int _last = 0;
  int maxGapMs = 0;
  int ticks = 0;
  void start() {
    _sw.start();
    _last = _sw.elapsedMicroseconds;
    _t = Timer.periodic(const Duration(milliseconds: 1), (_) {
      final int now = _sw.elapsedMicroseconds;
      final int gap = ((now - _last) / 1000).round();
      if (gap > maxGapMs) maxGapMs = gap;
      _last = now;
      ticks++;
    });
  }

  void stop() => _t?.cancel();
}

String jsonSize(Object o) => '${utf8.encode(jsonEncode(o)).length}';
