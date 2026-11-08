import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/perf/device_tier.dart';
import 'package:openfamily/services/perf/memory_pressure.dart';
import 'package:openfamily/services/perf/perf_profile.dart';

const int mib = 1024 * 1024;

DeviceMemory mem(int mb, {bool low = false}) =>
    DeviceMemory(totalBytes: mb * mib, isLowRamDevice: low);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(PerfProfile.reset);

  group('classifyDevice (reported RAM, not marketing RAM)', () {
    test('2 GB and 3 GB phones are lite', () {
      expect(classifyDevice(mem(1800)), DeviceTier.lite);
      expect(classifyDevice(mem(2700)), DeviceTier.lite);
    });
    test('a "4 GB" phone reporting ~3.7 GiB is standard', () {
      expect(classifyDevice(mem(3700)), DeviceTier.standard);
    });
    test('4 to under 6 GB is standard', () {
      expect(classifyDevice(mem(4600)), DeviceTier.standard);
      expect(classifyDevice(mem(5200)), DeviceTier.standard);
    });
    test('6, 8, 12 and 16 GB phones are full', () {
      for (final int m in <int>[5600, 7400, 11000, 15000]) {
        expect(classifyDevice(mem(m)), DeviceTier.full, reason: '$m MiB');
      }
    });
    test('isLowRamDevice always wins', () {
      expect(classifyDevice(mem(8000, low: true)), DeviceTier.lite);
    });
    test('unknown memory falls back to standard', () {
      expect(classifyDevice(DeviceMemory.unknown), DeviceTier.standard);
    });
  });

  group('PerfProfile', () {
    test('values only grow with the tier', () {
      const PerfProfile l = PerfProfile.lite,
          s = PerfProfile.standard,
          f = PerfProfile.full;
      expect(l.imageCacheMaxBytes < s.imageCacheMaxBytes, isTrue);
      expect(s.imageCacheMaxBytes < f.imageCacheMaxBytes, isTrue);
      expect(l.maxHistoryPoints < s.maxHistoryPoints, isTrue);
      expect(s.maxHistoryPoints < f.maxHistoryPoints, isTrue);
      expect(l.catchUpPageSize < s.catchUpPageSize, isTrue);
      expect(l.tileMemoryCacheBytes < f.tileMemoryCacheBytes, isTrue);
    });
    test('full keeps the pre-tier limits', () {
      expect(PerfProfile.full.maxHistoryPoints, 6000);
      expect(PerfProfile.full.catchUpPageSize, 200);
      expect(PerfProfile.full.imageCacheMaxBytes, 100 * mib);
    });
    test('on-device processing is never allowed on lite', () {
      expect(PerfProfile.lite.allowOnDeviceProcessing, isFalse);
      expect(PerfProfile.lite.keepBackgroundIsolateWarm, isFalse);
      expect(PerfProfile.lite.reduceEffects, isTrue);
      expect(PerfProfile.full.reduceEffects, isFalse);
    });
    test('init applies the tier to the image cache', () async {
      await PerfProfile.init(probe: () async => mem(2000));
      expect(PerfProfile.current.tier, DeviceTier.lite);
      final ImageCache c = PaintingBinding.instance.imageCache;
      expect(c.maximumSizeBytes, 24 * mib);
      expect(c.maximumSize, 60);
      PaintingBinding.instance.imageCache.maximumSizeBytes = 100 * mib;
      PaintingBinding.instance.imageCache.maximumSize = 1000;
    });
    test('scaled shortens animations on lite only', () {
      expect(PerfProfile.lite.scaled(const Duration(milliseconds: 500)),
          const Duration(milliseconds: 300));
      expect(PerfProfile.full.scaled(const Duration(milliseconds: 500)),
          const Duration(milliseconds: 500));
    });
  });

  group('MemoryPressureGuard', () {
    tearDown(() {
      MemoryPressureGuard.instance.uninstall();
      PaintingBinding.instance.imageCache.maximumSizeBytes = 100 * mib;
    });

    testWidgets('didHaveMemoryPressure clears the image cache and calls trimmers', (WidgetTester t) async {
      final ImageCache cache = PaintingBinding.instance.imageCache;
      final ui.Image img = (await t.runAsync(() => createTestImage(width: 4, height: 4)))!;
      cache.putIfAbsent('k', () => OneFrameImageStreamCompleter(Future<ImageInfo>.value(ImageInfo(image: img))));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      expect(cache.currentSize, 1);
      bool severe = false;
      void trim(bool s) => severe = s;
      MemoryPressureGuard.instance.addTrimmer(trim);
      MemoryPressureGuard.instance.didHaveMemoryPressure();
      expect(cache.currentSize, 0);
      expect(severe, isTrue);
      MemoryPressureGuard.instance.removeTrimmer(trim);
    });

    test('trim levels: ignored below running-low, UI hidden is light, background is severe', () {
      final List<bool> calls = <bool>[];
      void trim(bool s) => calls.add(s);
      MemoryPressureGuard.instance.addTrimmer(trim);
      MemoryPressureGuard.instance.handleTrim(TrimLevel.runningModerate);
      expect(calls, isEmpty);
      MemoryPressureGuard.instance.handleTrim(TrimLevel.runningLow);
      MemoryPressureGuard.instance.handleTrim(TrimLevel.runningCritical);
      MemoryPressureGuard.instance.handleTrim(TrimLevel.uiHidden);
      MemoryPressureGuard.instance.handleTrim(TrimLevel.background);
      MemoryPressureGuard.instance.handleTrim(TrimLevel.complete);
      expect(calls, <bool>[false, true, false, true, true]);
      MemoryPressureGuard.instance.removeTrimmer(trim);
    });

    test('a failing trimmer does not stop the others', () {
      int n = 0;
      void bad(bool s) => throw StateError('x');
      void good(bool s) => n++;
      MemoryPressureGuard.instance
        ..addTrimmer(bad)
        ..addTrimmer(good)
        ..handle(severe: false);
      expect(n, 1);
      MemoryPressureGuard.instance
        ..removeTrimmer(bad)
        ..removeTrimmer(good);
    });
  });
}

