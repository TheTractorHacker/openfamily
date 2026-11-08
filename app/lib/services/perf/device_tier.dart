import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// How much room this phone has. Decided once at start-up from the memory the
/// operating system reports (see docs/developers/performance-low-memory.md).
///
///  * [lite]: under 4 GB of RAM (or Android says it is a "low RAM device").
///  * [standard]: 4 GB up to under 6 GB.
///  * [full]: 6 GB and up (6, 8, 12, 16 GB all get the full app).
enum DeviceTier { lite, standard, full }

/// Memory facts about this phone. All values are what the OS reports, which is
/// below the marketing figure (a "4 GB" phone usually reports about 3.7 GiB).
class DeviceMemory {
  const DeviceMemory({
    this.totalBytes,
    this.availableBytes,
    this.isLowRamDevice = false,
    this.memoryClassMb,
    this.largeMemoryClassMb,
  });

  /// Total RAM visible to apps, null when unknown.
  final int? totalBytes;
  final int? availableBytes;

  /// Android `ActivityManager.isLowRamDevice()` (Android Go style devices).
  final bool isLowRamDevice;

  /// Android `getMemoryClass()`: Java heap budget in MB.
  final int? memoryClassMb;
  final int? largeMemoryClassMb;

  static const DeviceMemory unknown = DeviceMemory();

  Map<String, Object?> toJson() => <String, Object?>{
        'totalBytes': totalBytes,
        'availableBytes': availableBytes,
        'isLowRamDevice': isLowRamDevice,
        'memoryClassMb': memoryClassMb,
        'largeMemoryClassMb': largeMemoryClassMb,
      };
}

const int _mib = 1024 * 1024;

/// Reported-RAM cut-offs. They sit below the marketing sizes on purpose:
/// phones report less than they are sold with (kernel, GPU and modem reserve),
/// so "4 GB" reports about 3.6-3.9 GiB and "6 GB" about 5.3-5.8 GiB.
const int liteBelowBytes = 3500 * _mib; // marketing < 4 GB
const int fullFromBytes = 5300 * _mib; // marketing >= 6 GB

/// Pure mapping from memory facts to a tier. Unknown memory is [standard].
DeviceTier classifyDevice(DeviceMemory m) {
  if (m.isLowRamDevice) return DeviceTier.lite;
  final int? total = m.totalBytes;
  if (total == null || total <= 0) return DeviceTier.standard;
  if (total < liteBelowBytes) return DeviceTier.lite;
  if (total >= fullFromBytes) return DeviceTier.full;
  return DeviceTier.standard;
}

/// Reads [DeviceMemory] from the platform (Android `ActivityManager`, iOS
/// `ProcessInfo.physicalMemory`). Never throws: on any failure it returns
/// [DeviceMemory.unknown].
class DeviceProbe {
  DeviceProbe._();

  static const MethodChannel channel = MethodChannel('app.openfamily/device');

  static Future<DeviceMemory> read() async {
    if (!(Platform.isAndroid || Platform.isIOS)) return DeviceMemory.unknown;
    try {
      final Map<Object?, Object?>? m =
          await channel.invokeMapMethod<Object?, Object?>('memoryInfo');
      if (m == null) return DeviceMemory.unknown;
      int? i(String k) => m[k] is num ? (m[k]! as num).toInt() : null;
      return DeviceMemory(
        totalBytes: i('totalBytes'),
        availableBytes: i('availableBytes'),
        isLowRamDevice: m['isLowRamDevice'] == true,
        memoryClassMb: i('memoryClassMb'),
        largeMemoryClassMb: i('largeMemoryClassMb'),
      );
    } catch (_) {
      return DeviceMemory.unknown;
    }
  }
}
