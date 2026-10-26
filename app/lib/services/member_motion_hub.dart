import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import '../models/member.dart';
import 'marker_motion.dart';
import 'perf/perf_monitor.dart';

/// Per-member [MarkerMotion]s for the live map, shared by the marker layer,
/// the follow camera and the speed read-outs.
///
/// The hub never touches the widget tree. Two notifiers carry change:
///
/// * [frames] ticks once per animation frame (only while something is
///   moving). Only the marker layer and the follow camera listen.
/// * [speeds] ticks when a displayed speed can have changed (a new fix, or a
///   speed going stale). It is NOT per frame; tiles, the profile and the pin
///   captions listen to it.
class MemberMotionHub {
  MemberMotionHub({DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  /// The hub the map screen feeds and the list tiles / profile read.
  static final MemberMotionHub shared = MemberMotionHub();

  DateTime Function() _clock;
  DateTime now() => _clock();

  @visibleForTesting
  set clock(DateTime Function() c) => _clock = c;

  final Map<String, MarkerMotion> _motions = <String, MarkerMotion>{};
  final Map<String, MotionSample> _samples = <String, MotionSample>{};
  final Map<String, double?> _shownSpeed = <String, double?>{};

  final ValueNotifier<int> frames = ValueNotifier<int>(0);
  final ValueNotifier<int> speeds = ValueNotifier<int>(0);

  Timer? _speedWatch;

  /// Feeds a roster. Returns true when a frame loop is needed.
  bool update(List<Member> members) {
    final DateTime t = now();
    final Set<String> keep = <String>{};
    bool speedChanged = false;
    for (final Member m in members) {
      final LatLng? p = m.position;
      final DateTime ts = m.fixTime ?? m.lastSeen ?? t;
      if (p == null) continue;
      keep.add(m.id);
      final MarkerMotion motion =
          _motions.putIfAbsent(m.id, () => MarkerMotion());
      final double? beforeSpeed = motion.speedAt(t);
      motion.addFix(
        TrackFix(
          position: p,
          ts: ts,
          speedMps: m.speedMps,
          headingDeg: m.headingDeg,
          accuracyM: m.accuracyMeters,
        ),
        now: t,
      );
      _samples[m.id] = motion.sample(t);
      final double? afterSpeed = _samples[m.id]!.speedMps;
      if (afterSpeed != beforeSpeed || _shownSpeed[m.id] != afterSpeed) {
        speedChanged = true;
      }
      _shownSpeed[m.id] = afterSpeed;
    }
    for (final String id
        in _motions.keys.where((String k) => !keep.contains(k)).toList()) {
      _motions.remove(id);
      _samples.remove(id);
      _shownSpeed.remove(id);
      speedChanged = true;
    }
    if (speedChanged) speeds.value++;
    _syncSpeedWatch();
    return needsFrames;
  }

  /// Whether any member still needs animation frames.
  bool get needsFrames =>
      _samples.values.any((MotionSample s) => s.animating);

  /// Samples every member at the current time and notifies [frames].
  /// Returns whether another frame is needed.
  bool tick() {
    final DateTime t = now();
    for (final MapEntry<String, MarkerMotion> e in _motions.entries) {
      _samples[e.key] = e.value.sample(t);
    }
    PerfMonitor.instance.countAnimFrame();
    frames.value++;
    return needsFrames;
  }

  /// The latest drawn state for [memberId], or null if it has no fix.
  MotionSample? sampleOf(String memberId) => _samples[memberId];

  /// Live smoothed GPS speed (m/s) for [m], falling back to the speed carried
  /// by the member itself when the hub has no track for it.
  double? liveSpeedMps(Member m) {
    final MarkerMotion? motion = _motions[m.id];
    if (motion == null) return m.speedMps;
    return motion.speedAt(now()) ?? m.speedMps;
  }

  // While anyone reads a non-zero speed, re-check once a second so a speed
  // snaps to 0 when the fixes stop (no frame loop is running then).
  void _syncSpeedWatch() {
    final bool any = _shownSpeed.values.any((double? v) => v != null && v > 0);
    if (any && _speedWatch == null) {
      _speedWatch = Timer.periodic(const Duration(seconds: 1), (_) {
        bool changed = false;
        final DateTime t = now();
        for (final MapEntry<String, MarkerMotion> e in _motions.entries) {
          final double? v = e.value.speedAt(t);
          if (v != _shownSpeed[e.key]) {
            _shownSpeed[e.key] = v;
            changed = true;
          }
        }
        if (changed) speeds.value++;
        _syncSpeedWatch();
      });
    } else if (!any) {
      _speedWatch?.cancel();
      _speedWatch = null;
    }
  }

  /// Drops every track (screen disposed / circle changed).
  void reset() {
    _speedWatch?.cancel();
    _speedWatch = null;
    _motions.clear();
    _samples.clear();
    _shownSpeed.clear();
  }
}
