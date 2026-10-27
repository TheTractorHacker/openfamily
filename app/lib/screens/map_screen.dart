import 'dart:async';
import 'dart:math' as math;


import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart' show ValueListenable, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Circle;

import '../models/bubble.dart';
import '../models/circle.dart';
import '../widgets/openfamily_map_layers.dart';
import '../models/member.dart';
import '../services/api_client.dart';
import '../services/background_location_service.dart';
import '../services/bubble_service.dart';
import '../services/battery_optimization_service.dart';
import '../services/circle_selection.dart';
import '../services/circle_service.dart';
import '../services/device_service.dart';
import '../services/family_service.dart';
import '../services/location_reporter.dart';
import '../services/follow_camera.dart';
import '../services/marker_motion.dart';
import '../services/member_motion_hub.dart';
import '../services/speed_units.dart';
import '../services/watch_client.dart';
import '../services/location_outbox.dart';
import '../services/location_service.dart';
import '../services/location_sharing_service.dart';
import '../services/perf/perf_monitor.dart';
import '../services/permission_service.dart';
import '../services/place_service.dart';
import '../services/push_service.dart';
import '../services/tile_config.dart';
import '../theme/app_theme.dart';
import '../utils/member_clustering.dart';
import '../widgets/location_tab_view.dart';
import '../widgets/sharing_sheet.dart';
import '../widgets/member_avatar_bubble.dart';
import '../widgets/visible_value_builder.dart';
import 'check_in_screen.dart';
import 'invite_screen.dart';
import 'join_circle_screen.dart';
import 'member_profile_screen.dart';
import 'circle_detail_screen.dart';
import 'circles_screen.dart';
import 'places_screen.dart';
import 'settings_screen.dart';
import 'sos_screen.dart';

/// Radius (meters) of the "broader zone" circle drawn around a member whose
/// location is only approximate (GPS accuracy issue).
const double kApproxZoneRadiusMeters = 300.0;

/// The map-first home screen.
///
/// A full-bleed live map is the background — it extends behind *everything*.
/// A family name chip floats at the top, and member avatar bubbles are pinned to
/// their locations (clustered and fanned out when near each other).
///
/// The bottom control bar — a large, dominant SOS button plus the Places /
/// People destinations, optional Safety (when SMS is configured), and a
/// Settings gear pinned bottom-right — is FIXED and pinned to the very
/// bottom of the screen, always visible.
/// The family member roster lives on a dedicated full-screen People destination
/// (no drawer overlapping these controls). A `+` FAB floats above the bar and
/// offers the Check In / Help Alert / Invite quick actions.
class MapScreen extends StatefulWidget {
  const MapScreen({
    super.key,
    this.membersSink,
    this.userIdSink,
    this.circleIdSink,
    this.circleService,
    this.placesLoader,
    this.selectionStore,
    this.motionHub,
    this.watchClient,
  });

  /// When hosted in the app shell, the live roster is published here so the
  /// other tabs (Driving, Circle) share the map's single subscription.
  final ValueNotifier<List<Member>>? membersSink;
  final ValueNotifier<String?>? userIdSink;

  /// Receives the effective circle id (null = unscoped) for the Driving tab.
  final ValueNotifier<String?>? circleIdSink;

  /// Injected in tests; defaults to [CircleService.instance].
  final CircleService? circleService;
  final PlacesLoader? placesLoader;

  /// Injected in tests; defaults to the shared-preferences store.
  final CircleSelectionStore? selectionStore;

  /// Injected in tests; defaults to [MemberMotionHub.shared].
  final MemberMotionHub? motionHub;

  /// Injected in tests; defaults to a client that POSTs /locations/watch.
  final WatchClient? watchClient;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  // Zoom the camera animates to when a cluster is expanded.
  static const double _expandZoom = 16.0;

  final MapController _mapController = MapController();

  bool _satellite = false;

  /// Whether location sharing is off (the user skipped it during onboarding).
  /// When true we show a gentle re-prompt banner so they can enable it.
  bool _locationOff = false;

  // Live family data from the backend.
  final FamilyService _familyService = FamilyService();
  List<Member> _members = <Member>[];

  /// What the map layers and the People list render: the roster with the
  /// caller relabeled "You", republished (a fresh list) whenever the service
  /// emits. Live WebSocket frames update ONLY this notifier, so they never
  /// rebuild [MapScreen], the tab view, the tile layer or the sheet chrome.
  final ValueNotifier<List<Member>> _roster =
      ValueNotifier<List<Member>>(const <Member>[]);

  /// Live roster exposed to the pushed People screen so its status chips stay
  /// live off the map's single WebSocket subscription (no second connection).
  late final ValueNotifier<List<Member>> _membersListenable =
      widget.membersSink ?? ValueNotifier<List<Member>>(const <Member>[]);

  /// Circles for the switcher pill plus which one the map is scoped to.
  late final CircleSelection _selection =
      CircleSelection(store: widget.selectionStore);
  List<Circle> get _circles => _selection.circles;

  /// OS connectivity watcher for this screen: coming back online must recover
  /// the map on its own (see [_onConnectivityChanged]).
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  // Foreground location reporter: POSTs the device's GPS position to the
  // backend while this screen (the base of the nav stack) is alive.
  final LocationReporter _reporter = LocationReporter();
  String _familyName = 'Family';
  String? _userId;
  bool _hasFamily = true;

  /// True while the first family/members fetch is in flight.
  bool _loading = true;

  /// Non-null when the initial fetch failed; shown with a retry action.
  String? _error;

  // Clusters the user has expanded (tapped) so their members fan out.
  final Set<String> _expandedClusters = <String>{};

  // The current camera, tracked so expanded clusters can be re-collapsed when
  // members move apart (pruned on each movement tick) or the user zooms out.
  MapCamera? _camera;
  double? _lastZoom;

  /// Whether the map has finished its first layout (so camera moves are safe).
  bool _mapReady = false;

  // Camera animation controller for smooth recentering.
  AnimationController? _cameraAnim;

  // --- live motion + follow ------------------------------------------------
  // None of this uses setState on the screen: the ticker drives the motion
  // hub, the hub notifies the marker layer, and the follow camera moves the
  // map through the controller.
  late final MemberMotionHub _hub = widget.motionHub ?? MemberMotionHub.shared;
  late final WatchClient _watch = widget.watchClient ?? const WatchClient();
  Ticker? _motionTicker;

  /// The member the camera is locked to (null = free camera) plus what the
  /// "Following" pill shows. [FollowUi.locked] is false after the user pans
  /// away until they hit recenter.
  late final FollowCamera _follow = FollowCamera(
    moveTo: (LatLng c, double z) => _mapController.move(_aboveSheet(c, z), z),
    camera: () {
      final MapCamera cam = _mapController.camera;
      return (center: _aboveSheet(cam.center, cam.zoom, undo: true), zoom: cam.zoom);
    },
  );

  /// The bottom sheet covers the lower part of the full-screen map, so the
  /// middle of the *visible* map sits above the screen's middle. This returns
  /// the camera center that puts [target] there ([undo] reverses it, giving
  /// the point currently shown in the visible middle).
  LatLng _aboveSheet(LatLng target, double zoom, {bool undo = false}) {
    if (!mounted) return target;
    final Size size = MediaQuery.sizeOf(context);
    // Two-pane (tablet) layouts have no sheet over the map.
    if (size.width >= 720 ||
        (size.width > size.height * 1.2 && size.width >= 560)) {
      return target;
    }
    final double textScale =
        MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0);
    final double inset = (236 * textScale).clamp(0.0, size.height * 0.5);
    try {
      final MapCamera cam = _mapController.camera;
      final math.Point<double> p = cam.project(target, zoom);
      return cam.unproject(
        math.Point<double>(p.x, p.y + (undo ? -inset : inset) / 2),
        zoom,
      );
    } catch (_) {
      return target;
    }
  }
  final ValueNotifier<FollowUi?> _followUi = ValueNotifier<FollowUi?>(null);

  Timer? _watchTimer;
  Timer? _circleExpiryTimer;
  bool _appResumed = true;
  bool _screenVisible = true;
  ValueListenable<TickerModeData>? _tickerMode;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _motionTicker = createTicker(_onMotionTick);
    unawaited(UnitPreferenceService.ensureLoaded());
    _familyService.onMembersChanged = _onMembersChanged;
    _familyService.onUserId = _onUserId;
    _familyService.onCircleGone = _onCircleGone;
    _familyService.onSharingChanged = _onCircleSharingChanged;
    _selection.addListener(_onSelectionChanged);
    _connectivitySub =
        Connectivity().onConnectivityChanged.listen(_onConnectivityChanged);
    _load();
    unawaited(BubbleStore.instance.refresh());
    _checkLocation();
    _initLocationSharing();
    // Push registration and the operator-config refresh are not needed to
    // paint the map; they start after the first frame so their platform
    // channel work and requests do not compete with it. (The config request
    // is shared with the session gate's through ApiClient's cache.)
    // One-time Android battery-optimization guidance (keeps background
    // updates alive when the app is closed). No-op elsewhere. Runs after the
    // first frame so the activity is visible.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      PushService.sync();
      unawaited(_refreshServerFeatures());
      _suggestBatteryOptimization();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // TickerMode tells us when this screen is hidden (another tab, a pushed
    // route). getValuesNotifier does not subscribe the element, so tab switches
    // still rebuild nothing here.
    final ValueListenable<TickerModeData> mode =
        TickerMode.getValuesNotifier(context);
    if (!identical(mode, _tickerMode)) {
      _tickerMode?.removeListener(_onTickerMode);
      _tickerMode = mode..addListener(_onTickerMode);
      _onTickerMode();
    }
  }

  void _onTickerMode() {
    final bool visible = _tickerMode?.value.enabled ?? true;
    if (visible == _screenVisible) return;
    _screenVisible = visible;
    _syncWatch();
    // Coming back: catch the pins and the camera up to where the member is.
    if (visible) _ensureTicker();
  }

  void _onMembersChanged(List<Member> members) {
    if (!mounted) return;
    _members = members;
    // Identity semantics unchanged: the shared notifier fires on snapshots.
    _membersListenable.value = members;
    // Re-collapse expanded clusters whose members have moved apart.
    _pruneExpandedClusters();
    _publishRoster();
  }

  void _onUserId(String userId) {
    if (!mounted) return;
    setState(() => _userId = userId);
    _publishRoster();
    widget.userIdSink?.value = userId;
  }

  /// Pushes the current roster to the map layers and the People list.
  void _publishRoster() {
    final List<Member> live = _liveMembers();
    // The motion tracks see the new fix BEFORE the widgets do, so a pin and
    // its caption never render the new roster against the old track.
    if (_hub.update(live)) _ensureTicker();
    _roster.value = live;
    _checkFollowed(live);
  }

  void _ensureTicker() {
    final Ticker? t = _motionTicker;
    if (t != null && !t.isActive) t.start();
  }

  void _onMotionTick(Duration elapsed) {
    final bool more = _hub.tick();
    final String? fid = _follow.targetId;
    final bool intro =
        _follow.update(elapsed, fid == null ? null : _hub.sampleOf(fid));
    if (!more && !intro) _motionTicker?.stop();
  }

  // --- follow mode ---------------------------------------------------------

  /// Centers on [m] and locks the camera to their smoothed position.
  void _followMember(Member m) {
    if (!_mapReady) return;
    if ((_hub.sampleOf(m.id)?.position ?? m.position) == null) return;
    _cameraAnim?.dispose();
    _cameraAnim = null;
    _follow.start(m.id);
    _followUi.value = FollowUi(id: m.id, name: m.name, locked: true);
    _ensureTicker();
    _syncWatch();
  }

  /// Re-locks onto the member already being followed (the recenter button).
  void _refollow() {
    final String? id = _follow.targetId;
    if (id == null) return;
    for (final Member m in _roster.value) {
      if (m.id == id) {
        _followMember(m);
        return;
      }
    }
    _stopFollow();
  }

  /// Ends following entirely (X on the pill, member offline, screen gone).
  void _stopFollow() {
    _follow.stop();
    if (_followUi.value != null) _followUi.value = null;
    _syncWatch();
  }

  /// The user took the camera: stop locking but keep the pill so they can
  /// recenter.
  void _breakFollowLock() {
    final FollowUi? ui = _followUi.value;
    if (ui == null || !ui.locked) return;
    _follow.breakLock();
    _followUi.value = FollowUi(id: ui.id, name: ui.name, locked: false);
  }

  /// Stops following when the member goes away or offline.
  void _checkFollowed(List<Member> live) {
    final String? id = _follow.targetId;
    if (id == null) return;
    Member? m;
    for (final Member x in live) {
      if (x.id == id) {
        m = x;
        break;
      }
    }
    if (m == null || m.position == null || m.status == MemberStatus.stopped) {
      _stopFollow();
      return;
    }
    final FollowUi? ui = _followUi.value;
    if (ui != null && ui.name != m.name) {
      _followUi.value = FollowUi(id: ui.id, name: m.name, locked: ui.locked);
    }
  }

  // --- watch pings -----------------------------------------------------------

  void _syncWatch() {
    final String? id = _follow.targetId;
    final bool should =
        id != null && id != _userId && _appResumed && _screenVisible;
    if (should && _watchTimer == null) {
      _pingWatch();
      _watchTimer = Timer.periodic(WatchClient.renewEvery, (_) => _pingWatch());
    } else if (!should) {
      _watchTimer?.cancel();
    _circleExpiryTimer?.cancel();
      _watchTimer = null;
    }
  }

  void _pingWatch() {
    final String? id = _follow.targetId;
    if (id == null) return;
    unawaited(_watch.watch(id, circleId: _selection.effectiveId));
  }

  /// Retries the initial family load automatically when the network returns
  /// after the app was opened (or left) offline. Without this, a failed
  /// `_load` leaves the full-screen error card up until the user taps Retry
  /// or kills the app — there is no other automatic retry in the screen.
  /// When the map data is fine, the FamilyService's own connectivity watcher
  /// manages the socket; nothing to do here.
  void _onConnectivityChanged(List<ConnectivityResult> results) {
    final bool connected = results
        .any((ConnectivityResult result) => result != ConnectivityResult.none);
    if (!connected || !mounted) return;
    // Delivery may work again: flush whatever location reports the device
    // queued while it was offline. Independent of the initial-load retry
    // below — both matter after offline use.
    if (_error != null) _load();
    unawaited(LocationOutbox.drain(send: sendOutboxBatchViaApi));
  }

  /// Loads circles, resolves the selected circle, fetches the name + members
  /// for it, then opens the live WebSocket (scoped to that circle).
  Future<void> _load({bool retriedAfterGone = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    await _selection.restore();
    await _loadCircles();
    if (!mounted) return;
    final String? scope = _selection.effectiveId;
    try {
      // Scope first: fetchMembers and the socket URL both read it.
      _familyService.scopeTo(scope);
      // The family name and the roster do not depend on each other: request
      // them together (one round trip instead of two in front of the map).
      final Future<String> nameLoad = scope == null
          ? _familyService.fetchFamilyName()
          : Future<String>.value(_selection.nameOr(_familyName));
      final Future<List<Member>> membersLoad = _familyService.fetchMembers();
      final List<Object> loaded =
          await Future.wait<Object>(<Future<Object>>[nameLoad, membersLoad]);
      final String name = loaded[0] as String;
      final List<Member> members = loaded[1] as List<Member>;
      if (!mounted) return;
      _members = members;
      _membersListenable.value = members;
      _publishRoster();
      setState(() {
        _familyName = name;
        _hasFamily = true;
        _loading = false;
      });
      if (_mapReady) _fitToMembers();
      await _familyService.start();
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.status == 404 && scope != null && !retriedAfterGone) {
        // The remembered circle is gone (deleted / left): reload circles, fall
        // back to another one and retry once.
        _selection.removeCircle(scope);
        await _load(retriedAfterGone: true);
        return;
      }
      if (e.status == 404) {
        _members = <Member>[];
        _membersListenable.value = const <Member>[];
        _publishRoster();
        setState(() {
          _hasFamily = false;
          _familyName = 'No family';
          _loading = false;
          _error = null;
        });
        return;
      }
      setState(() {
        _loading = false;
        _error = _friendlyError(e);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _friendlyError(e);
      });
    }
  }

  String _friendlyError(Object e) {
    if (e is ApiException) return e.message;
    return 'Could not load your family. Check your connection and try again.';
  }

  /// Detects whether location sharing is off (e.g. the user skipped it during
  /// onboarding) so we can show a re-prompt instead of silently degrading.
  Future<void> _checkLocation() async {
    final PermissionState state = await PermissionService.current(
      OnboardingPermission.location,
    );
    if (!mounted) return;
    if (state != PermissionState.granted) {
      setState(() => _locationOff = true);
    }
  }

  /// One-time Android guidance: when background location is on, ask the user
  /// to exempt OpenFamily from battery optimization so Doze/OEM managers
  /// don't pause or kill the background service. Fires at most once and only
  /// when "Always" permission is granted; a no-op on iOS/web/desktop.
  Future<void> _suggestBatteryOptimization() async {
    if (!mounted) return;
    if (!BatteryOptimizationService.isSupported) return;
    final PermissionState location = await PermissionService.current(
      OnboardingPermission.location,
    );
    if (location != PermissionState.granted) return;
    if (!await BatteryOptimizationService.shouldSuggest()) return;
    if (!mounted) return;

    // Mark it shown up front so a prompt that is dismissed or errors out never
    // nags again.
    await BatteryOptimizationService.markSuggested();
    if (!mounted) return;

    final bool? open = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Keep background updates reliable'),
        content: const Text(
          'To keep your location fresh when OpenFamily is closed, Android '
          'may need OpenFamily exempted from battery optimization. Otherwise '
          'the system can pause background location to save battery.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Open settings'),
          ),
        ],
      ),
    );

    if (open == true && mounted) {
      await BatteryOptimizationService.openSettings();
    }
  }

  /// Re-requests location; if the OS still won't grant it, open Settings.
  Future<void> _enableLocation() async {
    final PermissionState state = await PermissionService.request(
      OnboardingPermission.location,
    );
    if (!mounted) return;
    if (state == PermissionState.granted) {
      setState(() => _locationOff = false);
    } else {
      await PermissionService.openSettings();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connectivitySub?.cancel();
    _selection
      ..removeListener(_onSelectionChanged)
      ..dispose();
    LocationSharingService.enabled.removeListener(_onSharingChanged);
    _reporter.stop();
    _familyService.dispose();
    _cameraAnim?.dispose();
    _watchTimer?.cancel();
    _tickerMode?.removeListener(_onTickerMode);
    _motionTicker?.dispose();
    _hub.reset();
    _followUi.dispose();
    _roster.dispose();
    if (widget.membersSink == null) _membersListenable.dispose();
    super.dispose();
  }

  /// Pauses foreground location reporting when the app is backgrounded and
  /// resumes it when the app returns to the foreground. This is explicit
  /// rather than relying on geolocator's implicit stream pause/resume.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _reporter.stop();
      _appResumed = false;
      _syncWatch();
    } else if (state == AppLifecycleState.resumed) {
      _appResumed = true;
      _syncWatch();
      _onResumed();
    }
  }

  /// Restarts the foreground reporter and refreshes family
  /// data.
  Future<void> _onResumed() async {
    if (LocationSharingService.enabled.value) {
      _reporter.start();
    }
    // Refresh member positions right away: the app may have sat in the
    // background for hours, and the WebSocket (or its repair cycle) may not
    // have pushed a fresh snapshot yet. One REST round-trip bounds the
    // staleness; it also rotates an expired access token before the reporter
    // needs it.
    await _familyService.refreshMembers();
    await _refreshServerFeatures();
  }

  Future<void> _initLocationSharing() async {
    await LocationSharingService.load();
    if (!mounted) return;
    // Hand the background reporter its long-lived ingest key if it doesn't
    // have one yet (devices registered before ingest keys existed, or a
    // rotated key). Fire-and-forget: failures keep the JWT fallback working.
    unawaited(DeviceService.ensureIngestKey());
    LocationSharingService.enabled.addListener(_onSharingChanged);
    _applyLocationSharing(startBackgroundAfterFrame: true);
  }

  void _onSharingChanged() {
    if (mounted) setState(() {});
    _applyLocationSharing(startBackgroundAfterFrame: false);
  }

  void _applyLocationSharing({required bool startBackgroundAfterFrame}) {
    if (LocationSharingService.enabled.value) {
      _reporter.start();
      if (startBackgroundAfterFrame) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (LocationSharingService.enabled.value) {
            BackgroundLocationService.start();
          }
        });
      } else {
        BackgroundLocationService.start();
      }
    } else {
      _reporter.stop();
      BackgroundLocationService.stop();
    }
  }

  // The relabeled copy of the caller is memoised on the source instance so an
  // unchanged caller keeps an identical Member across roster emissions (lets
  // the person row and marker caches below skip rebuilding it).
  Member? _youSource;
  Member? _youLive;

  Member _asYou(Member m) {
    if (identical(m, _youSource)) return _youLive!;
    final Member live = m.copyWith(name: 'You');
    _youSource = m;
    _youLive = live;
    return live;
  }

  /// Members with the caller's own member relabeled as "You" (always a fresh
  /// list, so it can be published to a [ValueNotifier]).
  List<Member> _liveMembers() {
    final String? uid = _userId;
    return <Member>[
      for (final Member m in _members)
        if (uid != null && m.id == uid) _asYou(m) else m,
    ];
  }

  /// Smoothly animates the camera to [center] at [zoom].
  void _animateTo(LatLng center, double zoom) {
    _cameraAnim?.dispose();
    final LatLng start = _mapController.camera.center;
    final double startZoom = _mapController.camera.zoom;

    final AnimationController controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _cameraAnim = controller;

    final Animation<LatLng> latLng =
        _LatLngTween(begin: start, end: _aboveSheet(center, zoom)).animate(
      CurvedAnimation(parent: controller, curve: Curves.easeInOutCubic),
    );
    final Animation<double> zoomAnim =
        Tween<double>(begin: startZoom, end: zoom).animate(
      CurvedAnimation(parent: controller, curve: Curves.easeInOutCubic),
    );

    controller.addListener(() {
      _mapController.move(latLng.value, zoomAnim.value);
    });
    controller.forward();
  }

  /// Recenters the map on the caller ("You"). Prefers the caller's own member
  /// (which always carries the freshest GPS fix); falls back to the live device
  /// position when the caller has no backend location yet.
  Future<void> _centerOnUser() async {
    _stopFollow();
    final String? uid = _userId;
    if (uid != null) {
      for (final Member m in _members) {
        if (m.id == uid && m.position != null) {
          _animateTo(m.position!, 15);
          return;
        }
      }
    }
    final LatLng? pos = await LocationService.currentPosition();
    if (pos == null || !mounted) return;
    _animateTo(pos, 15);
  }

  /// Expands a tapped cluster so its members fan out and become tappable.
  void _expandCluster(String clusterId, LatLng centroid) {
    _stopFollow();
    setState(() => _expandedClusters.add(clusterId));
    _animateTo(centroid, _expandZoom);
  }

  /// Called on every camera change. Re-collapses expanded clusters when the
  /// user zooms out (a decrease in zoom, not the expand animation's zoom-in).
  ///
  /// Only re-collapses on a user-initiated gesture ([hasGesture]); the
  /// programmatic expand animation (which zooms via the controller) must not
  /// immediately re-collapse the cluster the user just opened.
  void _onCameraChanged(MapCamera camera, bool hasGesture) {
    final double? prev = _lastZoom;
    _lastZoom = camera.zoom;
    _camera = camera;
    // Any user pan / pinch / fling takes the camera back. Programmatic moves
    // (the follow lock itself) report hasGesture == false.
    if (hasGesture && _follow.targetId != null) _breakFollowLock();
    if (hasGesture &&
        _expandedClusters.isNotEmpty &&
        prev != null &&
        camera.zoom < prev - 0.5) {
      setState(() => _expandedClusters.clear());
    }
  }

  /// Drops expanded-cluster ids that no longer correspond to a multi-member
  /// cluster at the current camera (i.e. the members have moved apart).
  void _pruneExpandedClusters() {
    if (_expandedClusters.isEmpty || _camera == null) return;
    final List<MemberCluster> clusters = clusterMembers(
      _liveMembers(),
      toScreenOffset: (latLng) {
        final p = _camera!.latLngToScreenPoint(latLng);
        return Offset(p.x, p.y);
      },
    );
    final Set<String> validIds =
        clusters.where((c) => c.members.length > 1).map((c) => c.id).toSet();
    _expandedClusters.retainAll(validIds);
  }

  /// Height of the bottom sheet's resting peek over the map (0 on tablets).
  double _bottomInset() {
    if (!mounted) return 0;
    final Size size = MediaQuery.sizeOf(context);
    if (size.width >= 720 ||
        (size.width > size.height * 1.2 && size.width >= 560)) {
      return 0;
    }
    final double textScale =
        MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0);
    return (236 * textScale).clamp(0.0, size.height * 0.5);
  }

  /// Frames all members of the current family.
  void _fitToMembers() {
    final List<Member> members =
        _liveMembers().where((Member m) => m.position != null).toList();
    if (members.isEmpty) return;
    if (members.length == 1) {
      _mapController.move(_aboveSheet(members.first.position!, 15), 15);
      return;
    }
    final LatLngBounds bounds = LatLngBounds.fromPoints(
      members.map((Member m) => m.position!).toList(),
    );
    _mapController.fitCamera(
      CameraFit.bounds(
        bounds: bounds,
        padding: EdgeInsets.fromLTRB(80, 80, 80, 80 + _bottomInset()),
      ),
    );
  }

  void _openMemberDetails(Member member) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MemberProfileScreen(member: member),
      ),
    );
  }

  void _openFollowedDetails() {
    final String? id = _follow.targetId;
    if (id == null) return;
    for (final Member m in _roster.value) {
      if (m.id == id) {
        _openMemberDetails(m);
        return;
      }
    }
  }

  void _openSos() {
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const SosScreen()));
  }

  /// Loads the user's circles for the switcher pill and validates the
  /// selection against them. Failures (offline) keep the previous list and
  /// selection.
  Future<void> _loadCircles() async {
    try {
      final List<Circle> circles =
          await (widget.circleService ?? CircleService.instance).listCircles();
      if (!mounted) return;
      final bool fellBack = _selection.update(circles);
      if (fellBack) _applySelection();
      _scheduleCircleExpiry();
    } catch (_) {
      // Keep the previous list.
    }
  }

  /// A temporary circle disappears server-side the moment it expires. Drop it
  /// locally at that instant too, so the selection falls back to the primary
  /// circle instead of showing an empty one until the next refresh.
  void _scheduleCircleExpiry() {
    _circleExpiryTimer?.cancel();
    _circleExpiryTimer = null;
    final DateTime now = DateTime.now().toUtc();
    final DateTime? next = _selection.nextExpiry(now);
    if (next == null) return;
    // Timer durations are capped so a 30-day wait cannot overflow; the timer
    // simply re-arms when it fires early.
    Duration wait = next.difference(now) + const Duration(seconds: 1);
    if (wait > const Duration(hours: 12)) wait = const Duration(hours: 12);
    _circleExpiryTimer = Timer(wait, () {
      if (!mounted) return;
      final bool wasSelected = _selection.pruneExpired(DateTime.now().toUtc());
      if (wasSelected) _applySelection();
      _scheduleCircleExpiry();
      unawaited(_loadCircles());
    });
  }

  /// The user picked a circle in the pill. Only the latest pick's data lands
  /// (see [FamilyService.setCircle]).
  void _selectCircle(String id) {
    if (!_selection.select(id)) return;
    _applySelection();
  }

  /// Pushes the current selection to the family service and the header.
  void _applySelection() {
    if (!mounted) return;
    setState(() {
      _familyName = _selection.nameOr(_familyName);
      _hasFamily = true;
      _error = null;
    });
    final String? scope = _selection.effectiveId;
    unawaited(_familyService.setCircle(scope).then((_) {
      if (mounted && _mapReady) _fitToMembers();
    }));
  }

  void _onSelectionChanged() {
    widget.circleIdSink?.value = _selection.effectiveId;
    if (mounted) setState(() {});
  }

  /// The server dropped a circle we were viewing (removed, left, deleted).
  void _onCircleGone(String circleId) {
    if (!mounted) return;
    final bool wasSelected = _selection.selectedId == circleId;
    _selection.removeCircle(circleId);
    if (wasSelected) _applySelection();
    unawaited(_loadCircles());
  }

  /// A member of the viewed circle changed their sharing: refresh roster and
  /// our own circle flags.
  void _onCircleSharingChanged() {
    unawaited(_loadCircles());
    unawaited(_familyService.refreshMembers());
  }

  /// "Resume sharing" on the paused banner for the selected circle.
  Future<void> _resumeSharing() async {
    final Circle? c = _selection.selectedCircle;
    if (c == null) return;
    try {
      await (widget.circleService ?? CircleService.instance)
          .setSharing(c.id, true);
    } catch (_) {
      // The banner stays; the user can retry.
    }
    await _loadCircles();
  }

  void _openCircles() {
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const CirclesScreen()))
        .then((_) {
      // _load() reloads the circle list itself; calling _loadCircles() as
      // well sent the same request twice.
      if (mounted) _load();
    });
  }

  void _openCircle(Circle c) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CircleDetailScreen(
          circle: c,
          service: widget.circleService,
        ),
      ),
    );
  }

  /// A member picked from the People list or tapped on the map: center on
  /// them and follow.
  void _focusMember(Member m) => _followMember(m);

  void _openPlaces() {
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const PlacesScreen()));
  }

  Future<void> _refreshServerFeatures() async {
    await TileConfig.instance.refresh();
    if (mounted) setState(() {});
  }

  void _openSettings() {
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));
  }

  void _openAddPerson() {
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const InviteScreen()));
  }

  void _openJoinCircle() {
    Navigator.of(context)
        .push(
      MaterialPageRoute<bool>(builder: (_) => const JoinCircleScreen()),
    )
        .then((bool? joined) {
      if (joined == true && mounted) _load();
    });
  }

  void _openCheckIn() {
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const CheckInScreen()));
  }

  void _openSharing() {
    showSharingSheet(
      context,
      members: _roster.value,
      selfId: _userId,
    );
  }

  void _toggleSatellite() {
    setState(() => _satellite = !_satellite);
  }

  @override
  Widget build(BuildContext context) {
    PerfMonitor.instance.countBuild('MapScreen');
    return LocationTabView(
      circleName: _selection.effectiveId == null
          ? _familyName
          : _selection.nameOr(_familyName),
      circles: _circles,
      members: _roster.value,
      membersListenable: _roster,
      selfId: _userId,
      sharingPaused:
          !LocationSharingService.enabled.value || _selection.sharingPaused,
      selectedCircleId: _selection.effectiveId,
      circleSharingPaused: _selection.sharingPaused,
      onResumeCircleSharing: _resumeSharing,
      onSelectCircle: _selectCircle,
      loading: _loading,
      error: _error,
      hasFamily: _hasFamily,
      locationOff: _locationOff,
      satellite: _satellite,
      placesLoader: widget.placesLoader ?? PlaceService.fetchPlaces,
      onRetry: _load,
      onEnableLocation: _enableLocation,
      onToggleSatellite: _toggleSatellite,
      onLocate: _centerOnUser,
      onOpenSettings: _openSettings,
      onInvite: _openAddPerson,
      onCheckIn: _openCheckIn,
      onOpenSharing: _openSharing,
      onSos: _openSos,
      onSelectMember: _focusMember,
      onOpenMember: _openMemberDetails,
      onManageCircles: _openCircles,
      onOpenCircle: _openCircle,
      onJoinCircle: _openJoinCircle,
      onOpenPlaces: _openPlaces,
      topOverlay: ValueListenableBuilder<FollowUi?>(
        valueListenable: _followUi,
        builder: (BuildContext _, FollowUi? ui, __) => ui == null
            ? const SizedBox.shrink()
            : FollowPill(
                ui: ui,
                onStop: _stopFollow,
                onRecenter: _refollow,
                onOpen: _openFollowedDetails,
              ),
      ),
      map: FlutterMap(
        mapController: _mapController,
        options: MapOptions(
          initialCenter: const LatLng(37.7749, -122.4194),
          initialZoom: 13,
          minZoom: 3,
          maxZoom: 18,
          interactionOptions: const InteractionOptions(
            flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
          ),
          onMapReady: () {
            _camera = _mapController.camera;
            _lastZoom = _mapController.camera.zoom;
            _mapReady = true;
            _fitToMembers();
          },
          onPositionChanged: (camera, hasGesture) =>
              _onCameraChanged(camera, hasGesture),
        ),
        children: [
          // Own repaint boundary + const widgets: the (expensive) base map is
          // not repainted or rebuilt when markers change.
          RepaintBoundary(
            child: _satellite
                ? const OpenFamilyTileLayer(satellite: true)
                : const OpenFamilyTileLayer(),
          ),
          // Blue "range" circle for members whose location accuracy is known
          // (or who are in the approximate GPS-accuracy state). The radius is
          // the member's real GPS accuracy in meters. Range circles and
          // member bubbles live behind the roster notifier, so a WebSocket
          // frame rebuilds only these two layers.
          VisibleValueBuilder<List<Member>>(
            valueListenable: _roster,
            builder: (BuildContext context, List<Member> members, _) {
              return CircleLayer(
                circles: [
                  for (final Member m in members)
                    if (_showRange(m))
                      CircleMarker(
                        point: _hub.sampleOf(m.id)?.position ?? m.position!,
                        radius: _rangeFor(m),
                        useRadiusInMeter: true,
                        color: AppColors.accuracyBlue.withValues(alpha: 0.12),
                        borderColor:
                            AppColors.accuracyBlue.withValues(alpha: 0.5),
                        borderStrokeWidth: 2,
                      ),
                ],
              );
            },
          ),
          // The caller's own active Bubbles (temporary geofences). The server
          // only ever sends these to their creator.
          ValueListenableBuilder<List<Bubble>>(
            valueListenable: BubbleStore.instance.mine,
            builder: (BuildContext _, List<Bubble> bubbles, __) {
              final DateTime now = DateTime.now();
              return CircleLayer(
                circles: <CircleMarker>[
                  for (final Bubble b in bubbles)
                    if (!b.expiredAt(now))
                      CircleMarker(
                        point: b.center,
                        radius: b.radiusM.toDouble(),
                        useRadiusInMeter: true,
                        color: AppColors.purple.withValues(alpha: 0.18),
                        borderColor: AppColors.purple,
                        borderStrokeWidth: 2,
                      ),
                ],
              );
            },
          ),
          // Member bubbles, clustered by on-screen proximity at the current
          // zoom (rebuilds as the camera moves, reusing cached bubbles).
          VisibleValueBuilder<List<Member>>(
            valueListenable: _roster,
            builder: (BuildContext context, List<Member> members, _) {
              PerfMonitor.instance.countBuild('MapMarkers');
              return ValueListenableBuilder<FollowUi?>(
                valueListenable: _followUi,
                builder: (BuildContext _, FollowUi? follow, __) =>
                    MemberMarkerLayer(
                  members: members,
                  expandedClusters: _expandedClusters,
                  onMemberTap: _focusMember,
                  onClusterTap: _expandCluster,
                  motion: _hub,
                  followId: follow?.id,
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// Whether to draw the blue accuracy/range circle around this member: when
/// we have a live accuracy value, or the member is in the approximate
/// GPS-accuracy state (which implies significant uncertainty).
bool _showRange(Member m) =>
    m.position != null &&
    // No accuracy ring around a pin that is driving (it would trail behind).
    !(m.speedMps != null && m.speedMps! > 3) &&
    ((m.accuracyMeters != null && m.accuracyMeters! > 0) ||
        m.status == MemberStatus.gpsIssue);

/// The radius (meters) of the blue range circle for this member — the real
/// GPS accuracy when known, otherwise the broader-zone fallback.
double _rangeFor(Member m) =>
    (m.accuracyMeters != null && m.accuracyMeters! > 0)
        ? m.accuracyMeters!
        : kApproxZoneRadiusMeters;

/// What the "Following" pill shows.
@immutable
class FollowUi {
  const FollowUi({required this.id, required this.name, required this.locked});
  final String id;
  final String name;

  /// False once the user has panned away; the pill then offers recenter.
  final bool locked;

  @override
  bool operator ==(Object other) =>
      other is FollowUi &&
      other.id == id &&
      other.name == name &&
      other.locked == locked;

  @override
  int get hashCode => Object.hash(id, name, locked);
}

/// "Following Ava" pill with a recenter button (when the lock was broken) and
/// an X that ends following.
class FollowPill extends StatelessWidget {
  const FollowPill({
    super.key,
    required this.ui,
    required this.onStop,
    required this.onRecenter,
    this.onOpen,
  });

  final FollowUi ui;
  final VoidCallback onStop;
  final VoidCallback onRecenter;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surface,
      elevation: 3,
      shape: const StadiumBorder(),
      child: Padding(
        padding: const EdgeInsets.only(left: 14),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              ui.locked ? Icons.my_location : Icons.location_searching,
              size: 18,
              color: cs.primary,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: InkWell(
                onTap: onOpen,
                child: Text(
                  'Following ${ui.name}',
                  key: const ValueKey<String>('follow-pill-label'),
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ),
            if (!ui.locked)
              IconButton(
                key: const ValueKey<String>('follow-recenter'),
                tooltip: 'Recenter on ${ui.name}',
                icon: const Icon(Icons.my_location),
                onPressed: onRecenter,
              ),
            IconButton(
              key: const ValueKey<String>('follow-stop'),
              tooltip: 'Stop following ${ui.name}',
              icon: const Icon(Icons.close),
              onPressed: onStop,
            ),
          ],
        ),
      ),
    );
  }
}

/// Interpolates between two [LatLng]s for smooth camera animation.
class _LatLngTween extends Tween<LatLng> {
  _LatLngTween({required LatLng begin, required LatLng end})
      : super(begin: begin, end: end);

  @override
  LatLng lerp(double t) => LatLng(
        begin!.latitude + (end!.latitude - begin!.latitude) * t,
        begin!.longitude + (end!.longitude - begin!.longitude) * t,
      );
}

/// Builds the member [MarkerLayer] from the current camera, clustering by
/// on-screen (pixel) proximity so bubbles merge and separate as the user
/// pans and zooms.
///
/// Lives inside [FlutterMap]'s children so it can read the camera via
/// [MapCamera.of], which also subscribes it to camera changes. The bubble
/// widgets themselves are cached per member instance: while panning or
/// animating only marker POSITIONS are recomputed.
///
/// Live motion: with a [motion] hub the layer also listens to its per-frame
/// notifier and re-places only the markers (setState on this State alone, the
/// screen above is untouched). Clustering is recomputed only when the roster,
/// the camera, the expanded set or the followed member change, or when a
/// moving member has drifted far enough on screen to matter, never on every
/// animation frame. The followed member is never clustered.
@visibleForTesting
class MemberMarkerLayer extends StatefulWidget {
  const MemberMarkerLayer({
    required this.members,
    required this.expandedClusters,
    required this.onMemberTap,
    required this.onClusterTap,
    this.motion,
    this.followId,
  });

  final List<Member> members;
  final Set<String> expandedClusters;
  final ValueChanged<Member> onMemberTap;
  final void Function(String clusterId, LatLng centroid) onClusterTap;
  final MemberMotionHub? motion;
  final String? followId;

  /// How many times clustering ran (tests assert it is not per frame).
  static int debugClusterRuns = 0;

  @override
  State<MemberMarkerLayer> createState() => _MemberMarkerLayerState();
}

class _MemberMarkerLayerState extends State<MemberMarkerLayer> {
  /// A moving member that drifts this far (logical px) from where it was
  /// clustered forces a re-cluster.
  static const double _reclusterDriftPx = 24;

  /// Bubble widgets by cache key, valid for the roster they were built from.
  Map<Object, Widget> _bubbles = <Object, Widget>{};

  // Cached clustering result and the inputs it was computed from.
  List<BubblePlacement> _placements = const <BubblePlacement>[];
  List<Member>? _placedMembers;
  MapCamera? _placedCamera;
  String _placedExpanded = '';
  String? _placedFollow;
  final Map<String, Offset> _placedScreen = <String, Offset>{};
  final Map<String, LatLng> _placedPos = <String, LatLng>{};

  @override
  void initState() {
    super.initState();
    widget.motion?.frames.addListener(_onFrame);
  }

  @override
  void didUpdateWidget(MemberMarkerLayer old) {
    super.didUpdateWidget(old);
    if (old.motion != widget.motion) {
      old.motion?.frames.removeListener(_onFrame);
      widget.motion?.frames.addListener(_onFrame);
    }
  }

  @override
  void dispose() {
    widget.motion?.frames.removeListener(_onFrame);
    super.dispose();
  }

  void _onFrame() {
    if (!mounted) return;
    PerfMonitor.instance.countBuild('MarkerFrame');
    setState(() {});
  }

  LatLng _posOf(Member m) =>
      widget.motion?.sampleOf(m.id)?.position ?? m.position!;

  Widget _memberBubble(Member m, Map<Object, Widget> next) {
    // Keyed by the Member instance: a new instance (any field changed) gets
    // a freshly built bubble, an unchanged one reuses the old widget.
    final Object key = m;
    final Widget bubble = _bubbles[key] ??
        MemberAvatarBubble(
          member: m,
          onTap: () => widget.onMemberTap(m),
        );
    next[key] = bubble;
    return bubble;
  }

  Widget _clusterBubble(BubblePlacement p, Map<Object, Widget> next) {
    final Object key = Object.hashAll(<Object?>[
      p.clusterId,
      p.position,
      ...p.clusterMembers.map(identityHashCode),
    ]);
    final Widget bubble = _bubbles[key] ??
        ClusterBubble(
          members: p.clusterMembers,
          onTap: () => widget.onClusterTap(p.clusterId!, p.position),
        );
    next[key] = bubble;
    return bubble;
  }

  bool _needsCluster(MapCamera camera, String expanded) {
    if (!identical(_placedMembers, widget.members) ||
        !identical(_placedCamera, camera) ||
        _placedExpanded != expanded ||
        _placedFollow != widget.followId) {
      return true;
    }
    final MemberMotionHub? hub = widget.motion;
    if (hub == null) return false;
    for (final MapEntry<String, Offset> e in _placedScreen.entries) {
      final MotionSample? s = hub.sampleOf(e.key);
      if (s == null || !s.animating) continue;
      final p = camera.latLngToScreenPoint(s.position);
      if ((Offset(p.x, p.y) - e.value).distance > _reclusterDriftPx) {
        return true;
      }
    }
    return false;
  }

  void _cluster(MapCamera camera, String expanded) {
    MemberMarkerLayer.debugClusterRuns++;
    Offset toScreen(LatLng latLng) {
      final p = camera.latLngToScreenPoint(latLng);
      return Offset(p.x, p.y);
    }

    final String? follow = widget.followId;
    final List<Member> clusterable = <Member>[];
    Member? followed;
    for (final Member m in widget.members) {
      if (m.position == null) continue;
      if (m.id == follow) {
        followed = m;
      } else {
        clusterable.add(m);
      }
    }
    final List<BubblePlacement> placed = placeBubbles(
      clusterable,
      toScreenOffset: toScreen,
      toLatLng: camera.offsetToCrs,
      expandedClusterIds: widget.expandedClusters,
      positionOf: _posOf,
    );
    _placedScreen.clear();
    _placedPos.clear();
    for (final Member m in widget.members) {
      if (m.position == null) continue;
      final LatLng p = _posOf(m);
      _placedPos[m.id] = p;
      _placedScreen[m.id] = toScreen(p);
    }
    _placements = <BubblePlacement>[
      ...placed,
      if (followed != null)
        BubblePlacement(position: _posOf(followed), member: followed),
    ];
    _placedMembers = widget.members;
    _placedCamera = camera;
    _placedExpanded = expanded;
    _placedFollow = follow;
  }

  @override
  Widget build(BuildContext context) {
    PerfMonitor.instance.countBuild('MapMarkerLayer');
    final MapCamera camera = MapCamera.of(context);
    final String expanded = widget.expandedClusters.isEmpty
        ? ''
        : (widget.expandedClusters.toList()..sort()).join('|');
    if (_needsCluster(camera, expanded)) _cluster(camera, expanded);

    final Map<Object, Widget> next = <Object, Widget>{};
    final MemberMotionHub? hub = widget.motion;
    final MarkerLayer layer = MarkerLayer(
      markers: [
        for (final BubblePlacement p in _placements)
          if (p.isCluster)
            Marker(
              point: p.position,
              width: 140,
              height: 90,
              alignment: Alignment.center,
              child: _clusterBubble(p, next),
            )
          else
            Marker(
              point: _livePoint(hub, p),
              width: MemberAvatarBubble.markerWidth,
              height: MemberAvatarBubble.markerSizeFor(p.member!).height,
              alignment: MemberAvatarBubble.markerAlignmentFor(p.member!),
              child: _memberBubble(p.member!, next),
            ),
      ],
    );
    // Entries not used this pass belong to members that moved on.
    _bubbles = next;
    return layer;
  }

  /// A lone member follows its smoothed position; a fanned-out member keeps
  /// its fan-out spot.
  LatLng _livePoint(MemberMotionHub? hub, BubblePlacement p) {
    final MotionSample? s = hub?.sampleOf(p.member!.id);
    if (s == null) return p.position;
    final LatLng? atCluster = _placedPos[p.member!.id];
    if (atCluster != null && atCluster != p.position) return p.position;
    return s.position;
  }
}
