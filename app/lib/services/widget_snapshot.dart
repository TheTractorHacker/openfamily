import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/member.dart';
import '../utils/member_status.dart';

/// Max members shown on the home-screen widget.
const int kWidgetMemberCap = 6;

/// Minimum gap between snapshot writes.
const Duration kWidgetThrottle = Duration(seconds: 30);

/// "Blake Foley" -> "BF", "madonna" -> "M", "" -> "?".
String widgetInitials(String name) {
  final List<String> parts = name
      .trim()
      .split(RegExp(r'\s+'))
      .where((String p) => p.isNotEmpty)
      .toList();
  if (parts.isEmpty) return '?';
  String first(String s) => String.fromCharCode(s.runes.first).toUpperCase();
  if (parts.length == 1) return first(parts.first);
  return first(parts.first) + first(parts.last);
}

/// Display-ready status for the widget. Never includes street addresses or
/// coordinates: a member with no saved-place context reads "Stationary".
String widgetStatusLine(Member m, {DateTime? now}) {
  if (m.position == null) return 'No location yet';
  if (m.status == MemberStatus.stopped) return 'Updates stopped';
  if (m.movement == MovementType.none && m.placePresence == null) {
    return 'Stationary';
  }
  if (m.placePresence != null && m.movement == MovementType.none) {
    final PlacePresence p = m.placePresence!;
    if (p.isAt) return 'At ${p.placeName}';
    return placePresenceLabel(p, now: now);
  }
  return memberStatusLine(m);
}

/// Builds the JSON-encodable snapshot: display strings only, no tokens, no
/// coordinates, no ids. Capped at [kWidgetMemberCap] members.
Map<String, dynamic> buildWidgetSnapshot(
  List<Member> members, {
  DateTime? now,
  int cap = kWidgetMemberCap,
}) {
  final DateTime n = now ?? DateTime.now();
  return <String, dynamic>{
    'updated': n.millisecondsSinceEpoch,
    'total': members.length,
    'members': <Map<String, dynamic>>[
      for (final Member m in members.take(cap))
        <String, dynamic>{
          'initials': widgetInitials(m.name),
          'name': m.name,
          'status': widgetStatusLine(m, now: n),
          'battery': m.batteryPercent.clamp(0, 100),
          'color': m.avatarColor.toARGB32() | 0xFF000000,
        },
    ],
  };
}

/// Writes the snapshot to the native widget store (Android only).
class HomeWidgetService {
  HomeWidgetService._();

  static const MethodChannel _channel = MethodChannel('app.openfamily/widget');
  static const String _prefKey = 'widget_show_family';

  static DateTime? _lastWrite;

  /// Test hook.
  @visibleForTesting
  static void resetForTest() {
    _lastWrite = null;
  }

  static bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<bool> isEnabled() async {
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      return p.getBool(_prefKey) ?? true;
    } catch (_) {
      return true;
    }
  }

  static Future<void> setEnabled(bool v, {List<Member>? members}) async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.setBool(_prefKey, v);
    if (!v) {
      await clear();
    } else if (members != null) {
      await update(members, force: true);
    }
  }

  /// Throttled (30 s) snapshot write. Never throws. The native side only
  /// stores the data when at least one widget instance exists.
  static Future<void> update(
    List<Member> members, {
    bool force = false,
    DateTime? now,
    bool? supported,
  }) async {
    if (!(supported ?? _supported)) return;
    try {
      final DateTime n = now ?? DateTime.now();
      if (!force &&
          _lastWrite != null &&
          n.difference(_lastWrite!) < kWidgetThrottle) {
        return;
      }
      if (!await isEnabled()) return;
      final String json = jsonEncode(buildWidgetSnapshot(members, now: n));
      _lastWrite = n;
      await _channel.invokeMethod<bool>('write', json);
    } catch (_) {}
  }

  /// Removes all member data from the widget store (sign-out, toggle off).
  static Future<void> clear({bool? supported}) async {
    _lastWrite = null;
    if (!(supported ?? _supported)) return;
    try {
      await _channel.invokeMethod<void>('clear');
    } catch (_) {}
  }
}
