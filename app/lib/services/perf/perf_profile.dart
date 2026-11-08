import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'device_tier.dart';

/// Every size and interval that scales with the phone's memory, in one place.
/// Read it through [PerfProfile.current]; it is [standard] until
/// [PerfProfile.init] has looked at the phone (a few milliseconds, after the
/// first frame), and tests can replace it with [PerfProfile.override].
@immutable
class PerfProfile {
  const PerfProfile({
    required this.tier,
    required this.imageCacheMaxBytes,
    required this.imageCacheMaxCount,
    required this.tileMemoryCacheBytes,
    required this.tileDiskCacheBytes,
    required this.tileConcurrency,
    required this.maxHistoryPoints,
    required this.catchUpPageSize,
    required this.chatPageSize,
    required this.reduceEffects,
    required this.animationScale,
    required this.stalenessTick,
    required this.keepBackgroundIsolateWarm,
    required this.allowOnDeviceProcessing,
  });

  final DeviceTier tier;

  /// `PaintingBinding.instance.imageCache` limits.
  final int imageCacheMaxBytes;
  final int imageCacheMaxCount;

  /// Decoded vector tiles kept in memory / tile files kept on disk.
  final int tileMemoryCacheBytes;
  final int tileDiskCacheBytes;
  final int tileConcurrency;

  /// Track points kept (stored and in memory) per member. Older history is
  /// fetched from the server on demand where the circle allows it.
  final int maxHistoryPoints;

  /// Items requested per catch-up page.
  final int catchUpPageSize;
  final int chatPageSize;

  /// Drop soft shadows and blur-like effects.
  final bool reduceEffects;

  /// Multiplier for animation durations (1 = as designed).
  final double animationScale;

  /// How often "last seen" labels are re-evaluated.
  final Duration stalenessTick;

  /// Keep the background location isolate resident between reports.
  final bool keepBackgroundIsolateWarm;

  /// May this phone run trip/drive/week processing itself (see
  /// docs/design/PRIVACY_PROCESSING.md)? Never on [DeviceTier.lite].
  final bool allowOnDeviceProcessing;

  static const PerfProfile lite = PerfProfile(
    tier: DeviceTier.lite,
    imageCacheMaxBytes: 24 * 1024 * 1024,
    imageCacheMaxCount: 60,
    tileMemoryCacheBytes: 3 * 1024 * 1024,
    tileDiskCacheBytes: 25 * 1024 * 1024,
    tileConcurrency: 1,
    maxHistoryPoints: 500,
    catchUpPageSize: 50,
    chatPageSize: 30,
    reduceEffects: true,
    animationScale: 0.6,
    stalenessTick: Duration(seconds: 60),
    keepBackgroundIsolateWarm: false,
    allowOnDeviceProcessing: false,
  );

  static const PerfProfile standard = PerfProfile(
    tier: DeviceTier.standard,
    imageCacheMaxBytes: 48 * 1024 * 1024,
    imageCacheMaxCount: 150,
    tileMemoryCacheBytes: 6 * 1024 * 1024,
    tileDiskCacheBytes: 50 * 1024 * 1024,
    tileConcurrency: 2,
    maxHistoryPoints: 2000,
    catchUpPageSize: 100,
    chatPageSize: 50,
    reduceEffects: false,
    animationScale: 1,
    stalenessTick: Duration(seconds: 30),
    keepBackgroundIsolateWarm: false,
    allowOnDeviceProcessing: true,
  );

  static const PerfProfile full = PerfProfile(
    tier: DeviceTier.full,
    imageCacheMaxBytes: 100 * 1024 * 1024, // Flutter's own default
    imageCacheMaxCount: 1000, // Flutter's own default
    tileMemoryCacheBytes: 10 * 1024 * 1024,
    tileDiskCacheBytes: 50 * 1024 * 1024,
    tileConcurrency: 2,
    maxHistoryPoints: 6000, // the limit before tiers existed
    catchUpPageSize: 200, // the page size before tiers existed
    chatPageSize: 50,
    reduceEffects: false,
    animationScale: 1,
    stalenessTick: Duration(seconds: 30),
    keepBackgroundIsolateWarm: true,
    allowOnDeviceProcessing: true,
  );

  static PerfProfile forTier(DeviceTier t) => switch (t) {
        DeviceTier.lite => lite,
        DeviceTier.standard => standard,
        DeviceTier.full => full,
      };

  static PerfProfile _current = standard;
  static PerfProfile? _override;
  static DeviceMemory memory = DeviceMemory.unknown;

  static PerfProfile get current => _override ?? _current;

  /// Tests (and a future "force lite mode" setting) can pin a profile.
  static set override(PerfProfile? p) {
    _override = p;
    if (p != null) p.applyToImageCache();
  }

  /// Looks at the phone once and applies the matching profile. Safe to call
  /// again (does nothing the second time unless [force]).
  static Future<PerfProfile> init({
    Future<DeviceMemory> Function()? probe,
    bool force = false,
  }) async {
    if (_initialised && !force) return current;
    _initialised = true;
    memory = await (probe ?? DeviceProbe.read)();
    _current = forTier(classifyDevice(memory));
    current.applyToImageCache();
    return current;
  }

  static bool _initialised = false;

  /// Resets to the pre-init state (tests).
  @visibleForTesting
  static void reset() {
    _initialised = false;
    _current = standard;
    _override = null;
    memory = DeviceMemory.unknown;
  }

  void applyToImageCache() {
    // The background isolate has no painting binding (and no images).
    try {
      final ImageCache c = PaintingBinding.instance.imageCache;
      c.maximumSizeBytes = imageCacheMaxBytes;
      c.maximumSize = imageCacheMaxCount;
    } catch (_) {}
  }

  /// [d] scaled by [animationScale].
  Duration scaled(Duration d) =>
      animationScale == 1 ? d : d * animationScale;
}
