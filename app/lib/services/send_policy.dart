import 'dart:math' as math;

/// Pure send policy for the background location isolate: decides whether a
/// fix is sent now, held briefly in memory (walking, nobody watching) or
/// suppressed (still phone inside the server's dedupe envelope).
///
/// No plugins, no prefs: everything is injected so it can be tested with a
/// fake clock and fake senders.

enum SendAction { sendNow, hold, suppress }

enum SendTier { stillIdle, walking, fast }

/// Tunables. Mirrors the server (backend handlers/location.go L36-44):
/// `stationaryDedupMaxMeters = 25.0` and `movingSpeedMPS = 1.5`; the server
/// also rejects a `ts` older than 15 minutes, hence [maxCachedFixAge].
class SendPolicyConfig {
  const SendPolicyConfig({
    this.holdMaxAge = const Duration(seconds: 45),
    this.holdMaxPoints = 10,
    this.stillRefresh = const Duration(minutes: 4),
    this.heartbeatRefreshAfter = const Duration(minutes: 5),
    this.heartbeatFlushAge = const Duration(seconds: 90),
    this.maxCachedFixAge = const Duration(minutes: 14),
    this.stillDedupeM = 25,
    this.stillMaxSpeedMps = 1.5,
    this.breakoutM = 150,
    this.batchChunk = 100,
  });

  final Duration holdMaxAge;
  final int holdMaxPoints;
  final Duration stillRefresh;
  final Duration heartbeatRefreshAfter;
  final Duration heartbeatFlushAge;
  final Duration maxCachedFixAge;
  final double stillDedupeM;
  final double stillMaxSpeedMps;
  final double breakoutM;
  final int batchChunk;
}

class SendFix {
  const SendFix({
    required this.lat,
    required this.lon,
    required this.ts,
    this.speed = -1,
    this.accuracy = 0,
  });
  final double lat;
  final double lon;
  final DateTime ts;

  /// m/s; negative = unknown.
  final double speed;
  final double accuracy;
}

class SendInput {
  const SendInput({
    required this.tier,
    required this.now,
    required this.fix,
    this.liveBoostActive = false,
    this.fgPresenceFresh = false,
    this.source = 'background',
    this.lastSentAt,
    this.lastSentPos,
    this.lastTier,
    this.heldOldestAt,
    this.heldCount = 0,
    this.privateOnly = false,
  });
  final SendTier tier;
  final bool liveBoostActive;
  final bool fgPresenceFresh;
  final String source;
  final DateTime now;
  final DateTime? lastSentAt;
  final ({double lat, double lon})? lastSentPos;
  final SendTier? lastTier;
  final SendFix fix;
  final DateTime? heldOldestAt;
  final int heldCount;
  final bool privateOnly;
}

class SendDecision {
  const SendDecision(this.action, {this.flushHeldFirst = false});
  final SendAction action;
  final bool flushHeldFirst;
}

double distanceMeters(double lat1, double lon1, double lat2, double lon2) {
  const double r = 6371000;
  double rad(double d) => d * math.pi / 180;
  final double dLat = rad(lat2 - lat1);
  final double dLon = rad(lon2 - lon1);
  final double a = math.pow(math.sin(dLat / 2), 2) +
      math.cos(rad(lat1)) *
          math.cos(rad(lat2)) *
          math.pow(math.sin(dLon / 2), 2);
  return 2 * r * math.asin(math.min(1, math.sqrt(a)));
}

class SendPolicy {
  const SendPolicy._();

  static SendDecision decide(SendInput i,
      [SendPolicyConfig c = const SendPolicyConfig()]) {
    const SendDecision flushNow =
        SendDecision(SendAction.sendNow, flushHeldFirst: true);
    final ({double lat, double lon})? lp = i.lastSentPos;
    final double? dist = lp == null
        ? null
        : distanceMeters(lp.lat, lp.lon, i.fix.lat, i.fix.lon);

    // 1. Always send immediately.
    if (i.tier == SendTier.fast ||
        i.liveBoostActive ||
        i.source == 'requested' ||
        i.fgPresenceFresh ||
        i.lastSentAt == null ||
        lp == null ||
        (i.lastTier != null && i.lastTier != i.tier)) {
      return flushNow;
    }
    if (i.tier == SendTier.walking && dist! >= c.breakoutM) return flushNow;
    if (i.tier == SendTier.stillIdle &&
        (dist! > c.stillDedupeM || i.fix.speed >= c.stillMaxSpeedMps)) {
      return flushNow;
    }

    // 2. Still, inside the dedupe envelope: nothing is queued.
    if (i.tier == SendTier.stillIdle) {
      return i.now.difference(i.lastSentAt!) < c.stillRefresh
          ? const SendDecision(SendAction.suppress)
          : flushNow;
    }

    // 3. Never hold when the plaintext path is not the only copy.
    if (i.privateOnly) return flushNow;

    // 4. Walking: hold briefly.
    final DateTime? oldest = i.heldOldestAt;
    final bool full = i.heldCount >= c.holdMaxPoints;
    final bool aged = oldest != null && i.now.difference(oldest) >= c.holdMaxAge;
    if (!full && !aged) return const SendDecision(SendAction.hold);
    return flushNow;
  }
}

enum HeartbeatAction { none, flushHeld, refreshFreshest }

HeartbeatAction heartbeatAction({
  required DateTime now,
  required DateTime? lastSentAt,
  required DateTime? heldOldestAt,
  required SendFix? cachedFix,
  DateTime? lastSentTs,
  SendPolicyConfig config = const SendPolicyConfig(),
}) {
  // The tick period is longer than any hold age: whatever is held goes now.
  if (heldOldestAt != null) return HeartbeatAction.flushHeld;
  // A cached fix the server already has (same or older ts) refreshes nothing.
  if (cachedFix != null &&
      (lastSentTs == null || cachedFix.ts.isAfter(lastSentTs)) &&
      (lastSentAt == null ||
          now.difference(lastSentAt) >= config.heartbeatRefreshAfter) &&
      now.difference(cachedFix.ts) < config.maxCachedFixAge) {
    return HeartbeatAction.refreshFreshest;
  }
  return HeartbeatAction.none;
}

enum SingleOutcome { ok, notNewer, failed }

class FlushResult {
  const FlushResult({required this.singleSent, required this.batchSent});
  final bool singleSent;
  final bool batchSent;
}

DateTime? _tsOf(Map<String, dynamic> p) => DateTime.tryParse('${p['ts']}')?.toUtc();

/// Sends held points (oldest first, chunks <= batchChunk) through the batch
/// endpoint, then the single freshest point. Held points with a ts not below
/// the freshest ts are discarded (the server would refuse them). A failed or
/// throwing batch chunk spills that chunk and the rest to [spill] and the
/// single is still attempted; a failed single spills the freshest body. A
/// "ts is not newer" answer is success and is not spilled.
///
/// Staleness: the live endpoint refuses a `ts` older than 15 minutes, so when
/// the freshest point is older than [SendPolicyConfig.maxCachedFixAge] (the
/// isolate was paused or its timers frozen, e.g. by doze) it is NOT sent as a
/// single: it joins the batch, which accepts old points as history repair
/// (no live fan-out, no geofence replay). Points older than [dropAfter] are
/// dropped (the outbox would prune them anyway), so one ancient point can never
/// fail the whole batch.
Future<FlushResult> flushHeld({
  required List<Map<String, dynamic>> held,
  required Map<String, dynamic> freshest,
  required Future<bool> Function(List<Map<String, dynamic>> chunk) sendBatch,
  required Future<SingleOutcome> Function(Map<String, dynamic> body) sendSingle,
  required Future<void> Function(List<Map<String, dynamic>> points) spill,
  int chunkSize = 100,
  DateTime? now,
  Duration dropAfter = const Duration(hours: 12),
  Duration singleMaxAge = const Duration(minutes: 14),
}) async {
  final DateTime clock = (now ?? DateTime.now()).toUtc();
  final DateTime? freshTs = _tsOf(freshest);
  final bool freshStale = freshTs != null && clock.difference(freshTs) >= singleMaxAge;
  final bool freshTooOld = freshTs != null && clock.difference(freshTs) >= dropAfter;
  final List<Map<String, dynamic>> pts = held.where((Map<String, dynamic> p) {
    final DateTime? t = _tsOf(p);
    if (t == null || clock.difference(t) >= dropAfter) return false;
    return freshTs == null || t.isBefore(freshTs);
  }).toList();
  if (freshStale && !freshTooOld) pts.add(freshest);
  pts.sort((Map<String, dynamic> a, Map<String, dynamic> b) =>
      _tsOf(a)!.compareTo(_tsOf(b)!));
  bool batchOk = true;
  for (int i = 0; i < pts.length; i += chunkSize) {
    final List<Map<String, dynamic>> chunk =
        pts.sublist(i, math.min(i + chunkSize, pts.length));
    bool ok;
    try {
      ok = await sendBatch(chunk);
    } catch (_) {
      ok = false;
    }
    if (!ok) {
      batchOk = false;
      await spill(pts.sublist(i));
      break;
    }
  }
  if (freshStale) {
    // Delivered (or spilled) with the batch; nothing goes to the live endpoint.
    return FlushResult(singleSent: batchOk && !freshTooOld, batchSent: batchOk);
  }
  SingleOutcome out;
  try {
    out = await sendSingle(freshest);
  } catch (_) {
    out = SingleOutcome.failed;
  }
  if (out == SingleOutcome.failed) {
    await spill(<Map<String, dynamic>>[freshest]);
  }
  return FlushResult(
      singleSent: out != SingleOutcome.failed, batchSent: batchOk);
}

/// Whether a heartbeat tick should ask the OS for a one-shot position because
/// the continuous location stream went quiet (Android doze / OEM power
/// management can defer fixes for many minutes while the heartbeat alarm
/// still fires). Pure: a fix received within [quietAfter] means the stream is
/// alive and no probe is needed.
bool shouldProbePosition({
  required DateTime now,
  required DateTime? lastFixAt,
  required bool isAndroid,
  Duration quietAfter = const Duration(minutes: 5),
}) {
  if (!isAndroid) return false;
  return lastFixAt == null || now.difference(lastFixAt) >= quietAfter;
}

/// The background-locator JSON for a one-shot probe fix, so it flows through
/// exactly the same quality filter and send policy as a streamed fix.
Map<String, dynamic> probeFixJson({
  required double latitude,
  required double longitude,
  required double accuracy,
  required double altitude,
  required double speed,
  required double speedAccuracy,
  required double heading,
  required DateTime time,
  bool isMocked = false,
}) =>
    <String, dynamic>{
      'latitude': latitude,
      'longitude': longitude,
      'accuracy': accuracy,
      'altitude': altitude,
      'speed': speed,
      'speed_accuracy': speedAccuracy,
      'heading': heading,
      'time': time.toUtc().millisecondsSinceEpoch.toDouble(),
      'is_mocked': isMocked,
      'provider': 'probe',
      'motion_state': '',
      'native_reset': false,
    };
