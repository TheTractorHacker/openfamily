import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/screens/performance_screen.dart';
import 'package:openfamily/screens/settings_screen.dart' show VersionTapCounter;
import 'package:openfamily/services/perf/perf_monitor.dart';

void main() {
  group('frame summary', () {
    test('percentiles come from build and raster separately', () {
      final PerfMonitor m = PerfMonitor.forTest();
      for (int i = 1; i <= 100; i++) {
        m.addFrame(buildMicros: i * 100, rasterMicros: 2000); // 0.1..10 ms
      }
      expect(m.frames, 100);
      expect(m.buildPercentileMs(50), closeTo(5.0, 0.3));
      expect(m.buildPercentileMs(90), closeTo(9.0, 0.3));
      expect(m.buildPercentileMs(99), closeTo(9.9, 0.3));
      expect(m.rasterPercentileMs(99), closeTo(2.0, 0.3));
    });

    test('janky threshold follows the refresh rate', () {
      final PerfMonitor m = PerfMonitor.forTest();
      // 12 ms: fine at 60 Hz (16.7 ms), janky at 120 Hz (8.3 ms).
      m.addFrame(buildMicros: 12000, rasterMicros: 1000, refreshHz: 60);
      expect(m.jankyFrames, 0);
      m.addFrame(buildMicros: 12000, rasterMicros: 1000, refreshHz: 120);
      expect(m.jankyFrames, 1);
      m.addFrame(buildMicros: 1000, rasterMicros: 18000, refreshHz: 60);
      expect(m.jankyFrames, 2);
      expect(m.jankPercent, closeTo(66.7, 0.1));
      expect(m.budgetMs, closeTo(16.67, 0.01));
    });

    test('keeps the 10 slowest frames with the route that was visible', () {
      final PerfMonitor m = PerfMonitor.forTest();
      for (int i = 0; i < 30; i++) {
        m.currentRoute = 'screen-$i';
        m.addFrame(buildMicros: (i + 1) * 1000, rasterMicros: 500);
      }
      expect(m.slowest.length, 10);
      expect(m.slowest.first.route, 'screen-29');
      expect(m.slowest.first.buildMs, 30);
      expect(m.slowest.last.route, 'screen-20');
    });

    test('reset clears everything', () {
      final PerfMonitor m = PerfMonitor.forTest()..recording = true;
      m.addFrame(buildMicros: 30000, rasterMicros: 1);
      m.countBuild('X');
      m.recordHttp('GET', '/config', 5, 200);
      m.recordWsFrame(applied: true);
      m.reset();
      expect(m.frames, 0);
      expect(m.slowest, isEmpty);
      expect(m.rebuilds, isEmpty);
      expect(m.httpSamples, isEmpty);
      expect(m.wsReceived, 0);
    });
  });

  group('detail recorders are off by default', () {
    test('rebuilds, http and websocket do nothing until recording', () {
      final PerfMonitor m = PerfMonitor.forTest();
      m.countBuild('MapScreen');
      m.recordHttp('GET', '/family/members', 10, 200);
      m.recordWsFrame(applied: true);
      m.recordWsUiUpdate();
      expect(m.rebuilds, isEmpty);
      expect(m.httpSamples, isEmpty);
      expect(m.wsReceived, 0);
      expect(m.wsUiUpdates, 0);
      m.recording = true;
      m.countBuild('MapScreen');
      m.countBuild('MapScreen');
      expect(m.rebuilds['MapScreen'], 2);
    });

    test('websocket per-minute averages', () {
      final PerfMonitor m = PerfMonitor.forTest()..recording = true;
      DateTime now = DateTime.utc(2026, 1, 1, 12, 0, 5);
      m.clock = () => now;
      for (int i = 0; i < 30; i++) {
        m.recordWsFrame(applied: i.isEven);
      }
      now = now.add(const Duration(minutes: 1));
      for (int i = 0; i < 10; i++) {
        m.recordWsFrame(applied: true);
        m.recordWsUiUpdate();
      }
      final pm = m.wsPerMinute;
      expect(pm.received, 20);
      expect(pm.applied, 12.5);
      expect(pm.ui, 5);
    });
  });

  group('http ring buffer is anonymous', () {
    test('ids, tokens and queries never appear in endpoint labels', () {
      expect(
          PerfMonitor.endpointLabel(
              'GET', '/trips/3f2a9c1e-7b1d-4c55-9a2e-0123456789ab/events'),
          'GET /trips/:id/events');
      expect(PerfMonitor.endpointLabel('GET', '/trips/report?lat=51.5&lon=-0.1'),
          'GET /trips/report');
      expect(PerfMonitor.endpointLabel('POST', '/alerts/42/ack'),
          'POST /alerts/:id/ack');
      expect(
          PerfMonitor.endpointLabel(
              'GET', '/family/members/eyJhbGciOi.abc123/avatar'),
          'GET /family/members/:id/avatar');
      expect(PerfMonitor.endpointLabel('GET', '/family/places'),
          'GET /family/places');
    });

    test('ring buffer is bounded and aggregates per endpoint', () {
      final PerfMonitor m = PerfMonitor.forTest()..recording = true;
      for (int i = 0; i < PerfMonitor.httpRingSize + 50; i++) {
        m.recordHttp('GET', '/family/members', 100 + i % 10, i % 50 == 0 ? 500 : 200);
      }
      expect(m.httpSamples.length, PerfMonitor.httpRingSize);
      final EndpointStats s = m.endpointStats().single;
      expect(s.endpoint, 'GET /family/members');
      expect(s.count, PerfMonitor.httpRingSize);
      expect(s.errors, greaterThan(0));
      expect(s.p50, inInclusiveRange(100, 109));
    });
  });

  group('startup', () {
    test('process age is parsed from /proc/self/stat', () {
      // Field 22 (starttime) = 1000 ticks = 10 s after boot; uptime 12.5 s.
      final String stat = '1234 (app.openfamily) S 1 1 1 0 -1 4194560 100 0 0 0 '
          '5 5 0 0 20 0 30 0 1000 99999 100 18446744073709551615';
      expect(PerfMonitor.processAgeFromProc(stat, '12.50 40.0'), 2500);
    });

    test('a process name containing spaces and parentheses still parses', () {
      final String stat = '9 (a b) c) S 1 1 1 0 -1 4194560 100 0 0 0 '
          '5 5 0 0 20 0 30 0 500 99999 100 18446744073709551615';
      expect(PerfMonitor.processAgeFromProc(stat, '6.00 1.0'), 1000);
    });

    test('garbage returns null', () {
      expect(PerfMonitor.processAgeFromProc('nope', '1.0 1.0'), isNull);
    });

    test('timeStep records its duration and the step list', () async {
      final PerfMonitor m = PerfMonitor.forTest()..markMainStart();
      final int v = await m.timeStep('prefs', () async => 7);
      expect(v, 7);
      expect(m.startupSteps.single.name, 'prefs');
    });
  });

  group('report', () {
    test('contains the headline numbers and no URLs or ids', () {
      final PerfMonitor m = PerfMonitor.forTest()..recording = true;
      m.currentRoute = 'AppShell:location';
      m.addFrame(buildMicros: 20000, rasterMicros: 3000);
      m.recordHttp('GET', '/trips/3f2a9c1e-7b1d-4c55-9a2e-0123456789ab', 120, 200);
      m.countBuild('MapScreen');
      final String r = m.buildReport(device: 'test');
      expect(r, contains('build ms p50/p90/p99'));
      expect(r, contains('raster ms p50/p90/p99'));
      expect(r, contains('janky frames: 1'));
      expect(r, contains('AppShell:location'));
      expect(r, contains('GET /trips/:id'));
      expect(r, contains('MapScreen: 1'));
      expect(r, isNot(contains('3f2a9c1e')));
      expect(r, isNot(contains('https://')));
    });
  });

  group('route observer', () {
    testWidgets('names the pushed page widget', (tester) async {
      final PerfMonitor m = PerfMonitor.forTest();
      final GlobalKey<NavigatorState> nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: nav,
        navigatorObservers: <NavigatorObserver>[PerfRouteObserver(m)],
        home: const Scaffold(body: Text('home')),
      ));
      nav.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const PerformanceScreen()),
      );
      await tester.pumpAndSettle();
      expect(m.currentRoute, 'PerformanceScreen');
      nav.currentState!.pop();
      await tester.pumpAndSettle();
      expect(m.currentRoute, isNot('PerformanceScreen'));
    });
  });

  group('hidden screen entry', () {
    test('seven taps within the window unlock it', () {
      final VersionTapCounter c = VersionTapCounter();
      DateTime t = DateTime(2026);
      for (int i = 0; i < 6; i++) {
        expect(c.tap(t), isFalse);
        t = t.add(const Duration(milliseconds: 300));
      }
      expect(c.tap(t), isTrue);
      expect(c.tap(t), isFalse, reason: 'counter restarts');
    });

    test('a pause longer than the window restarts the count', () {
      final VersionTapCounter c = VersionTapCounter();
      DateTime t = DateTime(2026);
      for (int i = 0; i < 6; i++) {
        c.tap(t);
        t = t.add(const Duration(milliseconds: 200));
      }
      t = t.add(VersionTapCounter.window + const Duration(seconds: 1));
      expect(c.tap(t), isFalse);
    });

    testWidgets('screen renders, copies the report and resets', (tester) async {
      final PerfMonitor m = PerfMonitor.forTest();
      m.addFrame(buildMicros: 9000, rasterMicros: 2000);
      String? clip;
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          clip = (call.arguments as Map)['text'] as String;
        }
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      await tester.pumpWidget(MaterialApp(home: PerformanceScreen(monitor: m)));
      expect(find.text('Performance'), findsOneWidget);
      expect(find.textContaining('Janky'), findsOneWidget);
      await tester.tap(find.text('Copy report'));
      // The report also awaits the persisted session diary (real async IO).
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
      expect(clip, contains('OpenFamily performance report'));
      expect(clip, contains('session diary'));
      expect(find.text('Performance report copied'), findsOneWidget);
      await tester.tap(find.text('Reset'));
      await tester.pump();
      expect(m.frames, 0);
      // Switch recording on.
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(m.recording, isTrue);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
