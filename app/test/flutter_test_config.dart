import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/e2ee/e2ee_vault.dart';
import 'package:openfamily/services/offline/offline_cache.dart';
import 'package:openfamily/services/offline/offline_queue.dart';

/// Every test file starts with an empty, in-memory snapshot cache and send queue. The real ones sit in the
/// Keystore-backed vault, a platform channel that never answers under `flutter test`; and a queue that
/// survives from one test to the next would show an old "SOS not sent yet" in an unrelated screen.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  setUp(() {
    OfflineCache.instance = OfflineCache(vault: MemoryVault());
    OfflineQueue.instance = OfflineQueue(storage: MemoryQueueStorage());
  });
  await testMain();
}
