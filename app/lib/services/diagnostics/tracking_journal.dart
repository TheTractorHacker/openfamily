import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

import 'tracking_health.dart';

/// A small, bounded, low-volume journal of what happened to the tracking
/// service: app paused and resumed, the service restarted on resume, start and
/// stop requests, permission changes, the background isolate starting, parked
/// fixes being drained. It is printed at the end of the Diagnostics report so a
/// "tracking stopped at 22:36" can be explained from the report alone.
///
/// Two isolates write (the app and the background one). Each writes ONLY its
/// own preferences key (`tracking_journal_v1_app` / `_bg`), so neither can
/// overwrite the other's lines (a read-modify-write of one shared list would).
/// The reader reloads preferences and merges both by time. The Android service
/// keeps its own native journal that the diagnostics channel hands over.
///
/// SECURITY: events are fixed codes and [detail] is a short code or a count.
/// Never a coordinate, a token, key material or an exception message.
class TrackingJournal {
  TrackingJournal({DateTime Function()? clock, this.maxLines = 60}) : _clock = clock ?? DateTime.now;

  static final TrackingJournal instance = TrackingJournal();

  static const String keyPrefix = 'tracking_journal_v1_';
  static const String _permissionKey = 'tracking_journal_permission_v1';

  /// Which isolate this is. The default is the app; the background callbacks
  /// call [markBackground] before they write anything.
  static String _source = 'app';
  static String get source => _source;
  static void markBackground() => _source = 'bg';

  @visibleForTesting
  static void setSourceForTest(String s) => _source = s;

  final DateTime Function() _clock;
  final int maxLines;
  Future<void> _chain = Future<void>.value();

  /// Records one event. Never throws and never blocks the caller. The same
  /// event with the same detail as the previous line is folded into it (a
  /// counter and a "last seen" time), so a repeating tick cannot push the
  /// interesting lines out.
  void record(String event, [String detail = '']) {
    final DateTime now = _clock().toUtc();
    final String src = _source;
    final String d = clipCode(detail, 60);
    _chain = _chain.then((_) => _append(src, now, event, d)).catchError((Object _) {});
  }

  Future<void> _append(String src, DateTime now, String event, String detail) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      try {
        await prefs.reload();
      } catch (_) {}
      final List<Map<String, dynamic>> lines = _decode(prefs.getString('$keyPrefix$src'));
      final int ms = now.millisecondsSinceEpoch;
      final Map<String, dynamic>? last = lines.isEmpty ? null : lines.last;
      if (last != null && last['e'] == event && (last['d'] ?? '') == detail) {
        last['n'] = ((last['n'] as num?)?.toInt() ?? 1) + 1;
        last['l'] = ms;
      } else {
        lines.add(<String, dynamic>{'t': ms, 'e': event, if (detail.isNotEmpty) 'd': detail});
      }
      // Over the limit: the oldest lifecycle line (app_paused / app_resumed) goes first, because those are the
      // chatty ones; the rarer events (service created, restarted, permission) stay for as long as possible.
      while (lines.length > maxLines) {
        final int i = lines.indexWhere((Map<String, dynamic> l) => '${l['e']}'.startsWith('app_'));
        lines.removeAt(i < 0 ? 0 : i);
      }
      await prefs.setString('$keyPrefix$src', jsonEncode(lines));
    } catch (_) {
      // The journal must never disturb tracking.
    }
  }

  /// Notes the location permission seen now: a line only when it differs from
  /// the one recorded last (`permission_changed from=while_in_use to=always`).
  Future<void> notePermission(String permission) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      try {
        await prefs.reload();
      } catch (_) {}
      final String? before = prefs.getString(_permissionKey);
      if (before == permission) return;
      await prefs.setString(_permissionKey, permission);
      record('permission_changed', 'from=${before ?? 'none'} to=$permission');
    } catch (_) {}
  }

  static List<Map<String, dynamic>> _decode(String? raw) {
    if (raw == null || raw.isEmpty) return <Map<String, dynamic>>[];
    try {
      final Object? d = jsonDecode(raw);
      if (d is! List) return <Map<String, dynamic>>[];
      return d.whereType<Map>().map((Map m) => m.cast<String, dynamic>()).toList();
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  /// Both isolates' lines merged, oldest first, once pending writes landed.
  Future<List<JournalLine>> readAll() async {
    await _chain;
    final List<JournalLine> out = <JournalLine>[];
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      try {
        await prefs.reload();
      } catch (_) {}
      for (final String src in const <String>['app', 'bg']) {
        for (final Map<String, dynamic> l in _decode(prefs.getString('$keyPrefix$src'))) {
          final JournalLine? j = lineFromMap(l, src);
          if (j != null) out.add(j);
        }
      }
    } catch (_) {}
    out.sort((JournalLine a, JournalLine b) => a.at.compareTo(b.at));
    return out;
  }

  /// One stored (or native) map: `t` first time in ms, `e` event, `d` detail, `n` repeats, `l` last time in ms.
  static JournalLine? lineFromMap(Map<dynamic, dynamic> m, String source) {
    final Object? t = m['t'];
    final Object? e = m['e'];
    if (t is! num || e is! String || e.isEmpty) return null;
    final Object? n = m['n'];
    final Object? l = m['l'];
    return JournalLine(
      at: DateTime.fromMillisecondsSinceEpoch(t.toInt(), isUtc: true),
      source: source,
      event: clipCode(e, 40),
      detail: clipCode('${m['d'] ?? ''}', 60),
      count: n is num && n > 1 ? n.toInt() : 1,
      last: l is num ? DateTime.fromMillisecondsSinceEpoch(l.toInt(), isUtc: true) : null,
    );
  }

  /// Merges [native] lines (from the Android service) into [own], oldest first.
  static List<JournalLine> merge(List<JournalLine> own, List<JournalLine> native) {
    final List<JournalLine> all = <JournalLine>[...own, ...native];
    all.sort((JournalLine a, JournalLine b) => a.at.compareTo(b.at));
    return all;
  }
}
