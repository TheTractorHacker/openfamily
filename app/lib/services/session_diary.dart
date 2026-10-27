import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

/// A small persisted ring buffer of session events (refresh attempts and
/// results, store reads, clear reasons, silent re-logins, gate results) so
/// "why was I signed out?" can be answered from the Performance report.
///
/// SECURITY: callers must only pass short non-secret strings. Tokens are
/// referenced by [shortHash] and passwords never appear here.
class SessionDiary {
  SessionDiary._();

  static final SessionDiary instance = SessionDiary._();

  static const String _key = 'session_diary_v1';
  static const int maxEvents = 50;

  List<String>? _events;
  Future<void> _chain = Future<void>.value();

  /// A short, non-reversible tag for a token (FNV-1a, 32 bit). Enough to tell
  /// two tokens apart in a log; useless for reconstructing one.
  static String shortHash(String? value) {
    if (value == null || value.isEmpty) return '-';
    int h = 0x811c9dc5;
    for (final int c in value.codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0xffffffff;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }

  /// Records one event. Never throws and never blocks the caller.
  void record(String event, [String detail = '']) {
    final String line = '${DateTime.now().toUtc().toIso8601String()} '
        '$event${detail.isEmpty ? '' : ' $detail'}';
    _chain = _chain.then((_) => _append(line)).catchError((Object _) {});
  }

  Future<void> _append(String line) async {
    final List<String> events = await _load();
    events.add(line);
    while (events.length > maxEvents) {
      events.removeAt(0);
    }
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_key, events);
    } catch (_) {}
  }

  Future<List<String>> _load() async {
    final List<String>? cached = _events;
    if (cached != null) return cached;
    List<String> stored = <String>[];
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      stored = List<String>.of(prefs.getStringList(_key) ?? <String>[]);
    } catch (_) {}
    return _events = stored;
  }

  /// The recorded events, oldest first, once pending writes have landed.
  Future<List<String>> events() async {
    await _chain;
    return List<String>.of(await _load());
  }

  /// Plain-text section for the diagnostics report.
  Future<String> render() async {
    final List<String> list = await events();
    final StringBuffer b = StringBuffer()
      ..writeln('session diary (last ${list.length}, oldest first):');
    if (list.isEmpty) b.writeln('  (empty)');
    for (final String e in list) {
      b.writeln('  $e');
    }
    return b.toString();
  }

  /// Test hook: forget the in-memory cache.
  void resetForTest() {
    _events = null;
    _chain = Future<void>.value();
  }
}
