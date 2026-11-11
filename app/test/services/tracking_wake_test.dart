// The server wake-up asks the Android side to restart tracking when it is wanted and gone. Fake native side only.
import 'dart:async';

import 'package:background_locator_2/background_locator.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/diagnostics/tracking_health.dart';
import 'package:openfamily/services/diagnostics/tracking_journal.dart';
import 'package:openfamily/services/location_refresh_service.dart';
import 'package:openfamily/services/tracking_wake.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late TrackingJournal journal;
  final DateTime now = DateTime.utc(2026, 11, 11, 12);
  final Future<String> Function() realNative = TrackingWake.native;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    TrackingJournal.setSourceForTest('app');
    journal = TrackingJournal(clock: () => now);
    TrackingWake.androidOverride = true;
  });

  tearDown(() {
    TrackingWake.native = realNative;
    TrackingWake.androidOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('app.yukams/locator_plugin'), null);
  });

  Future<List<String>> events() async => (await journal.readAll()).map((JournalLine l) => '${l.event}:${l.detail}').toList();

  test('a restart is journalled with its outcome', () async {
    TrackingWake.native = () async => 'restarted';
    expect(await TrackingWake.fromPush(journal: journal), 'restarted');
    expect(await events(), <String>['push_wake:result=restarted']);
  });

  test('a refusal is journalled and returned, never thrown', () async {
    TrackingWake.native = () async => 'refused';
    expect(await TrackingWake.fromPush(journal: journal), 'refused');
    expect(await events(), <String>['push_wake:result=refused']);
  });

  test('a service that is already running is the normal case and is not journalled', () async {
    TrackingWake.native = () async => 'running';
    expect(await TrackingWake.fromPush(journal: journal), 'running');
    expect(await events(), isEmpty);
  });

  test('a native error or a missing method becomes "unsupported"', () async {
    TrackingWake.native = () async => throw PlatformException(code: 'x');
    expect(await TrackingWake.fromPush(journal: journal), 'unsupported');
    TrackingWake.native = () async => throw MissingPluginException();
    expect(await TrackingWake.fromPush(journal: journal), 'unsupported');
  });

  test('a native call that never answers does not hold the push for more than a few seconds', () async {
    TrackingWake.native = () => Completer<String>().future;
    final Stopwatch w = Stopwatch()..start();
    expect(await TrackingWake.fromPush(journal: journal), 'unsupported');
    expect(w.elapsed, lessThan(const Duration(seconds: 8)));
  });

  test('not Android: nothing is called', () async {
    TrackingWake.androidOverride = false;
    bool called = false;
    TrackingWake.native = () async {
      called = true;
      return 'running';
    };
    expect(await TrackingWake.fromPush(journal: journal), 'unsupported');
    expect(called, isFalse);
  });

  test('the plugin channel call: LocatorPlugin.ensureRunning, answer passed through', () async {
    final List<String> calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('app.yukams/locator_plugin'),
        (MethodCall c) async {
      calls.add(c.method);
      return 'restarted';
    });
    expect(await BackgroundLocator.ensureRunning(), 'restarted');
    expect(calls, <String>['LocatorPlugin.ensureRunning']);
  });

  test('an older native build without the method answers "unsupported"', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('app.yukams/locator_plugin'),
        (MethodCall c) async => throw MissingPluginException());
    expect(await BackgroundLocator.ensureRunning(), 'unsupported');
  });

  group('the location request push also wakes tracking', () {
    String command(DateTime expires) =>
        '{"type":"location_request","request_id":"r1","expires_at":"${expires.toIso8601String()}"}';

    test('a live request asks for a restart; an expired one and other pushes do not', () async {
      int wakes = 0;
      TrackingWake.native = () async {
        wakes++;
        return 'running';
      };
      // The fix itself fails fast in tests (no sign-in); only the wake-up matters here.
      await LocationRefreshService.handlePush(command(DateTime.now().toUtc().add(const Duration(seconds: 30)))).catchError((Object _) => LocationRefreshResult.failed);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(wakes, 1);

      await LocationRefreshService.handlePush(command(DateTime.now().toUtc().subtract(const Duration(minutes: 1)))).catchError((Object _) => LocationRefreshResult.failed);
      await LocationRefreshService.handlePush('hello').catchError((Object _) => LocationRefreshResult.failed);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(wakes, 1);
    });
  });
}
