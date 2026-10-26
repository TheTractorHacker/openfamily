import 'package:flutter/animation.dart' show Curves;
import 'package:latlong2/latlong.dart';

import 'marker_motion.dart';

/// Zoom the follow camera uses when the user is zoomed out further than
/// [kFollowMinZoom]; otherwise their zoom is kept.
const double kFollowZoom = 16.0;
const double kFollowMinZoom = 14.0;

/// Length of the glide from the current camera onto the followed member.
const int kFollowIntroMs = 450;

/// Locks a map camera onto one member's smoothed display position.
///
/// UI-free and driven by whoever owns the frame loop: [update] is called once
/// per animation frame and, at most, makes one `moveTo` call (no animation
/// controllers stacked on top of each other).
class FollowCamera {
  FollowCamera({required this.moveTo, required this.camera});

  /// Moves the real map (MapController.move).
  final void Function(LatLng center, double zoom) moveTo;

  /// Current (center, zoom) of the real map.
  final ({LatLng center, double zoom}) Function() camera;

  String? _id;
  bool _locked = false;
  LatLng? _introFrom;
  double _introZoomFrom = 0;
  double _introZoomTo = 0;
  Duration? _introStart;
  LatLng? _lastCenter;

  /// The followed member id, locked or not (null = not following anyone).
  String? get targetId => _id;

  /// True while the camera is glued to the member.
  bool get locked => _locked;

  /// Starts (or restarts) following [id]: glides onto them, then tracks them.
  void start(String id) {
    final c = camera();
    _id = id;
    _locked = true;
    _introFrom = c.center;
    _introZoomFrom = c.zoom;
    _introZoomTo = c.zoom < kFollowMinZoom ? kFollowZoom : c.zoom;
    _introStart = null;
    _lastCenter = null;
  }

  /// The user took the camera: stop moving it but remember the target.
  void breakLock() {
    _locked = false;
    _introFrom = null;
    _lastCenter = null;
  }

  /// Forget the target entirely.
  void stop() {
    _id = null;
    _locked = false;
    _introFrom = null;
    _lastCenter = null;
  }

  /// One frame. [sample] is the target's current display state. Returns true
  /// while the intro glide still needs frames.
  bool update(Duration elapsed, MotionSample? sample) {
    if (_id == null || !_locked || sample == null) return false;
    final LatLng target = sample.position;
    final LatLng? from = _introFrom;
    if (from != null) {
      _introStart ??= elapsed;
      final double u =
          ((elapsed - _introStart!).inMilliseconds / kFollowIntroMs)
              .clamp(0.0, 1.0);
      final double e = Curves.easeInOutCubic.transform(u);
      moveTo(
        LatLng(
          from.latitude + (target.latitude - from.latitude) * e,
          from.longitude + (target.longitude - from.longitude) * e,
        ),
        _introZoomFrom + (_introZoomTo - _introZoomFrom) * e,
      );
      _lastCenter = target;
      if (u >= 1) _introFrom = null;
      return u < 1;
    }
    if (_lastCenter != target) {
      _lastCenter = target;
      moveTo(target, camera().zoom);
    }
    return false;
  }
}
