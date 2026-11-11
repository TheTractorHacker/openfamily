/// What the Diagnostics report says about the tracking service itself: why the
/// app's process last died, the power bucket Android put it in, per-hour
/// counters of the background pipeline, the last upload that worked, the last
/// identity/seal problem and a short journal of service events.
///
/// Pure (no plugins, no I/O) so the wording is unit tested. The facts are read
/// from the phone by `DiagnosticsProbe.collectTracking`.
///
/// Privacy: everything here is a time, a count or a short code (an exception
/// TYPE name, a reason name). Never a coordinate, a token, key material or the
/// text of an exception.
library;

/// The counters kept per UTC hour by both isolates. The order is the storage
/// order of `TrackingStats`: append only, never reorder.
enum TrackCounter {
  /// A GPS fix reached the Dart background callback.
  received,

  /// A fix the callback chose not to send (quality filter, spacing, the app is
  /// in the foreground and reporting itself).
  dropped,

  /// A fix kept for later (offline outbox, or parked for want of a key).
  parked,

  /// A location report the server accepted.
  posted,

  /// No credentials, or the server refused the ingest key (401/403).
  credFail,

  /// A fix could not be sealed for a Private circle.
  sealErr,

  /// A liveness heartbeat the server accepted.
  heartbeatOk,

  /// A liveness heartbeat that failed.
  heartbeatFail,
}

/// Android's `ApplicationExitInfo` reason codes, by name.
String exitReasonName(int reason) => switch (reason) {
      0 => 'UNKNOWN',
      1 => 'EXIT_SELF',
      2 => 'SIGNALED',
      3 => 'LOW_MEMORY',
      4 => 'CRASH',
      5 => 'CRASH_NATIVE',
      6 => 'ANR',
      7 => 'INITIALIZATION_FAILURE',
      8 => 'PERMISSION_CHANGE',
      9 => 'EXCESSIVE_RESOURCE_USAGE',
      10 => 'USER_REQUESTED',
      11 => 'USER_STOPPED',
      12 => 'DEPENDENCY_DIED',
      13 => 'OTHER',
      14 => 'FREEZER',
      15 => 'PACKAGE_STATE_CHANGE',
      16 => 'PACKAGE_UPDATED',
      _ => 'REASON_$reason',
    };

/// `RunningAppProcessInfo.IMPORTANCE_*` by name.
String processImportanceName(int importance) => switch (importance) {
      100 => 'FOREGROUND',
      125 => 'FOREGROUND_SERVICE',
      130 => 'TOP_SLEEPING',
      200 => 'VISIBLE',
      230 => 'PERCEPTIBLE',
      300 => 'SERVICE',
      325 => 'CANT_SAVE_STATE',
      400 => 'CACHED',
      1000 => 'GONE',
      _ => 'IMPORTANCE_$importance',
    };

/// `UsageStatsManager.STANDBY_BUCKET_*` by name.
String standbyBucketName(int bucket) => switch (bucket) {
      5 => 'EXEMPTED',
      10 => 'ACTIVE',
      20 => 'WORKING_SET',
      30 => 'FREQUENT',
      40 => 'RARE',
      45 => 'RESTRICTED',
      50 => 'NEVER',
      _ => 'BUCKET_$bucket',
    };

/// One entry of Android's record of why this app's processes ended.
class ProcessExit {
  const ProcessExit({
    required this.at,
    required this.reason,
    required this.importance,
    required this.status,
    required this.processName,
    this.description = '',
  });

  final DateTime at;
  final int reason;
  final int importance;
  final int status;
  final String processName;

  /// Android's own short note (for example "user request after error"). Clipped.
  final String description;

  /// Parses one map from the native side. Null when it has no usable time.
  /// Everything is clipped and flattened: this text goes into a report people paste.
  static ProcessExit? fromMap(Object? m) {
    if (m is! Map) return null;
    final Object? t = m['timestamp'];
    if (t is! num) return null;
    int i(Object? v) => v is num ? v.toInt() : 0;
    return ProcessExit(
      at: DateTime.fromMillisecondsSinceEpoch(t.toInt(), isUtc: true),
      reason: i(m['reason']),
      importance: i(m['importance']),
      status: i(m['status']),
      processName: clipCode('${m['processName'] ?? ''}', 60),
      description: clipCode('${m['description'] ?? ''}', 80),
    );
  }
}

/// One line of the tracking journal (either isolate or the native service).
class JournalLine {
  const JournalLine({
    required this.at,
    required this.source,
    required this.event,
    this.detail = '',
    this.count = 1,
    this.last,
  });

  /// First time this event was seen (repeats of the same event are folded into one line).
  final DateTime at;

  /// 'app' (the app's isolate), 'bg' (the background isolate) or 'native' (the Android service).
  final String source;
  final String event;
  final String detail;
  final int count;

  /// Last time it repeated (null when it did not).
  final DateTime? last;
}

/// The last problem of one kind: when, where and the exception TYPE only.
class StatsError {
  const StatsError({required this.at, required this.where, required this.type, required this.source});
  final DateTime at;
  final String where;
  final String type;
  final String source;
}

/// Counters of one UTC hour, summed over both isolates.
class HourCounts {
  const HourCounts(this.hour, this.counts);

  /// `2026-11-10T22` (UTC).
  final String hour;
  final List<int> counts;
  int operator [](TrackCounter c) => c.index < counts.length ? counts[c.index] : 0;
}

/// Merged view of what both isolates recorded.
class StatsSnapshot {
  const StatsSnapshot({
    this.hours = const <HourCounts>[],
    this.lastUploadOkAt,
    this.lastUploadOkSource = '',
    this.lastError,
    this.lastSealError,
  });

  /// Oldest first.
  final List<HourCounts> hours;
  final DateTime? lastUploadOkAt;
  final String lastUploadOkSource;
  final StatsError? lastError;
  final StatsError? lastSealError;
}

/// Everything the tracking section of the report prints.
class TrackingHealthFacts {
  const TrackingHealthFacts({
    this.exits,
    this.standbyBucket,
    this.ignoringBatteryOptimizations,
    this.stats = const StatsSnapshot(),
    this.journal = const <JournalLine>[],
    this.utcOffset = Duration.zero,
  });

  /// Null: this Android (or this build) cannot say (before Android 11, or the native method is missing).
  final List<ProcessExit>? exits;

  /// `UsageStatsManager.getAppStandbyBucket` (Android 9+), null when unavailable.
  final int? standbyBucket;
  final bool? ignoringBatteryOptimizations;
  final StatsSnapshot stats;

  /// Oldest first.
  final List<JournalLine> journal;

  /// The phone's offset from UTC, to print local times next to UTC ones.
  final Duration utcOffset;
}

/// Flattens whitespace, keeps only printable characters and cuts at [max].
String clipCode(String s, int max) {
  final String one = s.replaceAll(RegExp(r'[\r\n\t]+'), ' ').replaceAll(RegExp(r' {2,}'), ' ').trim();
  return one.length <= max ? one : '${one.substring(0, max)}...';
}

String _two(int n) => n.toString().padLeft(2, '0');

String _utc(DateTime t) {
  final DateTime u = t.toUtc();
  return '${u.year}-${_two(u.month)}-${_two(u.day)} ${_two(u.hour)}:${_two(u.minute)}:${_two(u.second)}Z';
}

String _offsetLabel(Duration o) {
  final int m = o.inMinutes.abs();
  return 'UTC${o.isNegative ? '-' : '+'}${_two(m ~/ 60)}:${_two(m % 60)}';
}

/// `22:36:04` in the phone's own time, shifted from UTC by [offset].
String _local(DateTime t, Duration offset) {
  final DateTime l = t.toUtc().add(offset);
  return '${l.year}-${_two(l.month)}-${_two(l.day)} ${_two(l.hour)}:${_two(l.minute)}:${_two(l.second)}';
}

String _ago(DateTime now, DateTime? t) {
  if (t == null) return 'never';
  final Duration d = now.difference(t);
  if (d.isNegative) return 'just now';
  if (d.inMinutes < 1) return '${d.inSeconds} s ago';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ${d.inMinutes % 60} min ago';
  return '${d.inDays} d ${d.inHours % 24} h ago';
}

String _errorLine(StatsError? e, DateTime now) =>
    e == null ? 'none' : '${e.type} in ${e.where} (${e.source}) at ${_utc(e.at)}, ${_ago(now, e.at)}';

/// How many hours of counters and journal lines the report prints.
const int kReportHours = 12;
const int kReportJournalLines = 100;

/// The tracking sections of the report, as plain text lines (no trailing blank line).
String renderTrackingHealth(TrackingHealthFacts t, DateTime now) {
  final StringBuffer b = StringBuffer();
  final Duration off = t.utcOffset;
  b
    ..writeln('Tracking health (local time zone ${_offsetLabel(off)})')
    ..writeln('battery_optimisation_ignored=${t.ignoringBatteryOptimizations == null ? 'unknown' : (t.ignoringBatteryOptimizations! ? 'yes' : 'no')}')
    ..writeln('standby_bucket=${t.standbyBucket == null ? 'unknown' : '${standbyBucketName(t.standbyBucket!)} (${t.standbyBucket})'}');

  b
    ..writeln()
    ..writeln('Recent process exits (newest first; Android\'s own record of why this app\'s process ended)');
  final List<ProcessExit>? exits = t.exits;
  if (exits == null) {
    b.writeln('  unavailable on this Android version');
  } else if (exits.isEmpty) {
    b.writeln('  (none recorded)');
  } else {
    for (final ProcessExit e in exits) {
      b.writeln('  ${exitReasonName(e.reason)} importance=${processImportanceName(e.importance)} status=${e.status} '
          'process=${e.processName.isEmpty ? '?' : e.processName} '
          'local ${_local(e.at, off)} / UTC ${_utc(e.at)} (${_ago(now, e.at)})'
          '${e.description.isEmpty ? '' : ' note="${e.description}"'}');
    }
  }

  final StatsSnapshot s = t.stats;
  b
    ..writeln()
    ..writeln('Background pipeline')
    ..writeln('last_upload_ok: ${s.lastUploadOkAt == null ? 'never recorded' : '${_utc(s.lastUploadOkAt!)} (${s.lastUploadOkSource}), ${_ago(now, s.lastUploadOkAt)}'}')
    ..writeln('last_seal_or_identity_error: ${_errorLine(s.lastSealError, now)}')
    ..writeln('last_callback_error: ${_errorLine(s.lastError, now)}');
  final List<HourCounts> shown =
      s.hours.length > kReportHours ? s.hours.sublist(s.hours.length - kReportHours) : s.hours;
  if (shown.isEmpty) {
    b.writeln('hourly (UTC): (nothing counted yet)');
  } else {
    b.writeln('hourly (UTC hour, oldest first):');
    for (final HourCounts h in shown) {
      b.writeln('  ${h.hour}Z received=${h[TrackCounter.received]} dropped=${h[TrackCounter.dropped]} '
          'parked=${h[TrackCounter.parked]} posted=${h[TrackCounter.posted]} '
          'credential_failures=${h[TrackCounter.credFail]} seal_errors=${h[TrackCounter.sealErr]} '
          'heartbeat_ok=${h[TrackCounter.heartbeatOk]} heartbeat_failed=${h[TrackCounter.heartbeatFail]}');
    }
  }

  b
    ..writeln()
    ..writeln('Tracking journal (last ${t.journal.length > kReportJournalLines ? kReportJournalLines : t.journal.length}, oldest first; [app] app, [bg] background isolate, [native] Android service)');
  if (t.journal.isEmpty) {
    b.writeln('  (empty)');
  } else {
    final List<JournalLine> lines =
        t.journal.length > kReportJournalLines ? t.journal.sublist(t.journal.length - kReportJournalLines) : t.journal;
    for (final JournalLine l in lines) {
      b.writeln('  ${_utc(l.at)} [${l.source}] ${l.event}${l.detail.isEmpty ? '' : ' ${l.detail}'}'
          '${l.count > 1 ? ' x${l.count} (last ${_utc(l.last ?? l.at)})' : ''}');
    }
  }
  return b.toString();
}
