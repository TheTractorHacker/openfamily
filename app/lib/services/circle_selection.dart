import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/circle.dart';

/// Where the last selected map circle is remembered across launches.
abstract class CircleSelectionStore {
  static CircleSelectionStore instance = PrefsCircleSelectionStore();

  Future<String?> read();
  Future<void> write(String? circleId);
}

/// [CircleSelectionStore] backed by shared preferences. Failures are swallowed:
/// the selection then just does not persist.
class PrefsCircleSelectionStore implements CircleSelectionStore {
  static const String _key = 'map.selected_circle';

  @override
  Future<String?> read() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      return prefs.getString(_key);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String? circleId) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      if (circleId == null) {
        await prefs.remove(_key);
      } else {
        await prefs.setString(_key, circleId);
      }
    } catch (_) {
      // Not persisting the choice is harmless.
    }
  }
}

/// The value meaning "every circle I am in".
const String kAllCircles = 'all';

/// Which circle the map, People list and live stream are scoped to.
///
/// With zero or one circle there is nothing to choose, so [effectiveId] is
/// null and the app keeps using the legacy unscoped endpoints (nothing changes
/// visually). With several circles the selection is a circle id or
/// [kAllCircles]; it falls back to the primary circle (then the first one)
/// when the remembered circle no longer exists, e.g. it was deleted or the user
/// left it.
class CircleSelection extends ChangeNotifier {
  CircleSelection({CircleSelectionStore? store})
      : _store = store ?? CircleSelectionStore.instance;

  final CircleSelectionStore _store;
  List<Circle> _circles = const <Circle>[];
  String? _selected;
  bool _restored = false;

  List<Circle> get circles => _circles;

  /// Raw selection (a circle id, [kAllCircles] or null = default).
  String? get selectedId => _selected;

  /// The id to scope requests to, or null for the legacy unscoped behaviour.
  String? get effectiveId => _circles.length < 2 ? null : _selected;

  bool get isAll => effectiveId == kAllCircles;

  /// The selected circle, or null for "all" / when unscoped.
  Circle? get selectedCircle {
    final String? id = effectiveId;
    if (id == null || id == kAllCircles) return null;
    for (final Circle c in _circles) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// True when the user turned location sharing off in the selected circle.
  bool get sharingPaused {
    final Circle? c = selectedCircle;
    return c != null && !c.sharingEnabled;
  }

  /// Display name for the pill.
  String nameOr(String fallback) {
    if (isAll) return 'All circles';
    return selectedCircle?.name ?? fallback;
  }

  /// Loads the remembered selection once.
  Future<void> restore() async {
    if (_restored) return;
    _restored = true;
    final String? saved = await _store.read();
    if (_selected == null && saved != null) {
      _selected = saved;
      _validate();
      notifyListeners();
    }
  }

  /// Replaces the circle list (after load, join, leave, delete). Returns true
  /// when the previous selection no longer exists and a fallback was chosen.
  bool update(List<Circle> circles) {
    _circles = List<Circle>.unmodifiable(circles);
    final String? before = _selected;
    final bool fellBack = _validate();
    if (before != _selected) _persist();
    notifyListeners();
    return fellBack;
  }

  /// Selects [id] ([kAllCircles] or a circle in the list). Unknown ids are
  /// ignored. Returns whether the effective selection changed.
  bool select(String id) {
    if (id != kAllCircles && !_circles.any((Circle c) => c.id == id)) {
      return false;
    }
    if (_selected == id) return false;
    _selected = id;
    _persist();
    notifyListeners();
    return true;
  }

  /// Drops temporary circles whose expiry has passed at [now] (the server has
  /// stopped serving them) and falls back like [removeCircle]. Returns true when
  /// the previous selection was among them.
  bool pruneExpired(DateTime now) {
    if (!_circles.any((Circle c) => c.isExpiredAt(now))) return false;
    return update(_circles.where((Circle c) => !c.isExpiredAt(now)).toList());
  }

  /// The soonest future expiry among the temporary circles, or null.
  DateTime? nextExpiry(DateTime now) {
    DateTime? best;
    for (final Circle c in _circles) {
      final DateTime? e = c.expiresAt;
      if (e == null || !e.isAfter(now)) continue;
      if (best == null || e.isBefore(best)) best = e;
    }
    return best;
  }

  /// Drops [id] from the list locally (the server said it is gone) and picks a
  /// fallback if it was selected.
  bool removeCircle(String id) {
    return update(_circles.where((Circle c) => c.id != id).toList());
  }

  // Returns true when an existing selection had to be replaced.
  bool _validate() {
    if (_circles.isEmpty) return false;
    final String? s = _selected;
    if (s == kAllCircles && _circles.length > 1) return false;
    if (s != null && _circles.any((Circle c) => c.id == s)) return false;
    final bool hadSelection = s != null;
    _selected = (_circles.firstWhere(
      (Circle c) => c.isPrimary,
      orElse: () => _circles.first,
    )).id;
    return hadSelection;
  }

  void _persist() => _store.write(_selected);
}
