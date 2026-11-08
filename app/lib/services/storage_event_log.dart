import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

/// A small persisted ring buffer of what happened to the phone's local
/// sign-in and key storage: every read or decrypt failure, retry, fallback to
/// the mirror copy, migration, archive (instead of delete), wipe and the cause
/// of every sign-out. So the next "I was signed out and my key broke after the
/// update" can be answered from Diagnostics instead of guessed.
///
/// SECURITY: only reason codes and short non-secret details (store names,
/// exception type names, counts). Never a token, key, blob or account detail.
///
/// Kept in plain app-private SharedPreferences on purpose: it must survive the
/// very failures it records (a Keystore or EncryptedSharedPreferences fault).
class StorageEventLog {
  StorageEventLog._();

  static final StorageEventLog instance = StorageEventLog._();

  static const String _key = 'storage_event_log_v1';
  static const int maxEvents = 50;

  Future<void> _chain = Future<void>.value();

  /// Records one event. Never throws and never blocks the caller.
  ///
  /// [code] is a short reason code (`read_error`, `mirror_hit`, `archive`,
  /// `signout`...), [store] names the store (`vault`, `tokens.A`...), [detail]
  /// is an optional short non-secret note (an exception type, a count).
  void record(String code, {String store = '', String detail = ''}) {
    final String line = <String>[
      DateTime.now().toUtc().toIso8601String(),
      code,
      if (store.isNotEmpty) store,
      if (detail.isNotEmpty) _clip(detail),
    ].join(' ');
    _chain = _chain.then((_) => _append(line)).catchError((Object _) {});
  }

  static String _clip(String s) {
    final String one = s.replaceAll(RegExp(r'\s+'), ' ');
    return one.length <= 120 ? one : '${one.substring(0, 120)}...';
  }

  Future<void> _append(String line) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      // Another isolate (the background engine) may have appended meanwhile.
      try {
        await prefs.reload();
      } catch (_) {}
      final List<String> events = List<String>.of(prefs.getStringList(_key) ?? <String>[]);
      events.add(line);
      while (events.length > maxEvents) {
        events.removeAt(0);
      }
      await prefs.setStringList(_key, events);
    } catch (_) {}
  }

  /// The recorded events, oldest first, once pending writes have landed.
  Future<List<String>> events() async {
    await _chain;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      try {
        await prefs.reload();
      } catch (_) {}
      return List<String>.of(prefs.getStringList(_key) ?? <String>[]);
    } catch (_) {
      return <String>[];
    }
  }

  /// Plain-text section for the diagnostics report.
  Future<String> render() async {
    final List<String> list = await events();
    final StringBuffer b = StringBuffer()..writeln('Storage events (last ${list.length}, oldest first):');
    if (list.isEmpty) b.writeln('  (none)');
    for (final String e in list) {
      b.writeln('  $e');
    }
    return b.toString();
  }

  /// Test hook.
  void resetForTest() {
    _chain = Future<void>.value();
  }
}
