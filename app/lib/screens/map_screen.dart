import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Circle;

import '../models/member.dart';
import '../services/api_client.dart';
import '../services/app_config.dart';
import '../services/background_location_service.dart';
import '../services/battery_optimization_service.dart';
import '../services/device_service.dart';
import '../services/family_service.dart';
import '../services/location_reporter.dart';
import '../services/location_outbox.dart';
import '../services/location_service.dart';
import '../services/location_sharing_service.dart';
import '../services/permission_service.dart';
import '../services/push_service.dart';
import '../services/server_features.dart';
import '../services/tile_config.dart';
import '../theme/app_theme.dart';
import '../utils/member_clustering.dart';
import '../widgets/circle_switcher.dart';
import '../widgets/map_bottom_bar.dart';
import '../widgets/member_avatar_bubble.dart';
import 'check_in_screen.dart';
import 'help_alert_screen.dart';
import 'invite_screen.dart';
import 'join_circle_screen.dart';
import 'member_profile_screen.dart';
import 'people_screen.dart';
import 'places_screen.dart';
import 'safety_screen.dart';
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
  const MapScreen({super.key});

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

  /// Live roster exposed to the pushed People screen so its status chips stay
  /// live off the map's single WebSocket subscription (no second connection).
  final ValueNotifier<List<Member>> _membersListenable =
      ValueNotifier<List<Member>>(const <Member>[]);

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _familyService.onMembersChanged = _onMembersChanged;
    _familyService.onUserId = _onUserId;
    _connectivitySub =
        Connectivity().onConnectivityChanged.listen(_onConnectivityChanged);
    _load();
    _checkLocation();
    _initLocationSharing();
    PushService.sync();
    unawaited(_refreshServerFeatures());
    // One-time Android battery-optimization guidance (keeps background
    // updates alive when the app is closed). No-op elsewhere. Runs after the
    // first frame so the activity is visible.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _suggestBatteryOptimization();
    });
  }

  void _onMembersChanged(List<Member> members) {
    if (!mounted) return;
    setState(() {
      _members = members;
      _membersListenable.value = members;
      // Re-collapse expanded clusters whose members have moved apart.
      _pruneExpandedClusters();
    });
  }

  void _onUserId(String userId) {
    if (!mounted) return;
    setState(() => _userId = userId);
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

  /// Fetches the family name + members, then opens the live WebSocket.
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final String name = await _familyService.fetchFamilyName();
      final List<Member> members = await _familyService.fetchMembers();
      if (!mounted) return;
      setState(() {
        _familyName = name;
        _members = members;
        _membersListenable.value = members;
        _hasFamily = true;
        _loading = false;
      });
      if (_mapReady) _fitToMembers();
      await _familyService.start();
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.status == 404) {
        setState(() {
          _hasFamily = false;
          _familyName = 'No family';
          _members = <Member>[];
          _membersListenable.value = const <Member>[];
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
    LocationSharingService.enabled.removeListener(_onSharingChanged);
    _reporter.stop();
    _familyService.dispose();
    _cameraAnim?.dispose();
    _membersListenable.dispose();
    super.dispose();
  }

  /// Pauses foreground location reporting when the app is backgrounded and
  /// resumes it when the app returns to the foreground. This is explicit
  /// rather than relying on geolocator's implicit stream pause/resume.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _reporter.stop();
    } else if (state == AppLifecycleState.resumed) {
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

  /// Members with the caller's own member relabeled as "You".
  List<Member> _liveMembers() {
    if (_userId == null) return _members;
    return _members
        .map((Member m) => m.id == _userId ? m.copyWith(name: 'You') : m)
        .toList();
  }

  /// Whether to draw the blue accuracy/range circle around this member: when
  /// we have a live accuracy value, or the member is in the approximate
  /// GPS-accuracy state (which implies significant uncertainty).
  bool _showRange(Member m) =>
      m.position != null &&
      ((m.accuracyMeters != null && m.accuracyMeters! > 0) ||
          m.status == MemberStatus.gpsIssue);

  /// The radius (meters) of the blue range circle for this member — the real
  /// GPS accuracy when known, otherwise the broader-zone fallback.
  double _rangeFor(Member m) =>
      (m.accuracyMeters != null && m.accuracyMeters! > 0)
          ? m.accuracyMeters!
          : kApproxZoneRadiusMeters;

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
        _LatLngTween(begin: start, end: center).animate(
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

  /// Frames all members of the current family.
  void _fitToMembers() {
    final List<Member> members =
        _liveMembers().where((Member m) => m.position != null).toList();
    if (members.isEmpty) return;
    if (members.length == 1) {
      _mapController.move(members.first.position!, 15);
      return;
    }
    final LatLngBounds bounds = LatLngBounds.fromPoints(
      members.map((Member m) => m.position!).toList(),
    );
    _mapController.fitCamera(
      CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(80)),
    );
  }

  void _openMemberDetails(Member member) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MemberProfileScreen(member: member),
      ),
    );
  }

  /// Opens the dedicated full-screen family member roster (the People
  /// destination in the bottom bar). It consumes the map's single live member
  /// subscription so statuses stay fresh without a second WebSocket.
  void _openPeople() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PeopleScreen(
          circleName: _familyName,
          members: _membersListenable,
        ),
      ),
    );
  }

  void _openSos() {
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const SosScreen()));
  }

  void _openPlaces() {
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const PlacesScreen()));
  }

  Future<void> _refreshServerFeatures() async {
    await TileConfig.instance.refresh();
    if (mounted) setState(() {});
  }

  void _openSafety() {
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const SafetyScreen()));
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

  void _openHelpAlert() {
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const HelpAlertScreen()));
  }

  void _showAddActions() {
    final ColorScheme colors = Theme.of(context).colorScheme;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: colors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (BuildContext context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _AddActionTile(
                  icon: Icons.check_circle_outline,
                  title: 'Check In',
                  subtitle: 'Share your location with your family',
                  onTap: () {
                    Navigator.of(context).pop();
                    _openCheckIn();
                  },
                ),
                _AddActionTile(
                  icon: Icons.campaign_outlined,
                  title: 'Help Alert',
                  subtitle: 'Ask your family for help',
                  onTap: () {
                    Navigator.of(context).pop();
                    _openHelpAlert();
                  },
                ),
                _AddActionTile(
                  icon: Icons.person_add_alt_1,
                  title: 'Invite',
                  subtitle: 'Send a code to invite someone to your family',
                  onTap: () {
                    Navigator.of(context).pop();
                    _openAddPerson();
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _toggleSatellite() {
    setState(() => _satellite = !_satellite);
  }

  @override
  Widget build(BuildContext context) {
    final List<Member> members = _liveMembers();
    final MediaQueryData media = MediaQuery.of(context);
    final double safeBottom = media.padding.bottom;
    // Space reserved at the very bottom for the fixed control bar (its own
    // height plus the system safe-area inset it sits above), so the `+` FAB
    // docks clear of it.
    final double controlBarReserved = MapBottomBar.height + safeBottom;

    return Scaffold(
      body: Stack(
        children: [
          // Full-bleed live map — extends behind every control.
          FlutterMap(
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
              TileLayer(
                urlTemplate: _satellite ? kSatelliteTileUrl : kTileUrl,
                userAgentPackageName: 'app.openfamily',
              ),
              // Blue "range" circle for members whose location accuracy is
              // known (or who are in the approximate GPS-accuracy state).
              // The radius is the member's real GPS accuracy in meters, so the
              // circle shows how uncertain the fix is. Drawn for every member
              // that has a live accuracy value; approximate/flagged members
              // fall back to the broader-zone radius.
              CircleLayer(
                circles: [
                  for (final Member m in members)
                    if (_showRange(m))
                      CircleMarker(
                        point: m.position!,
                        radius: _rangeFor(m),
                        useRadiusInMeter: true,
                        color: AppColors.accuracyBlue.withValues(alpha: 0.12),
                        borderColor: AppColors.accuracyBlue.withValues(
                          alpha: 0.5,
                        ),
                        borderStrokeWidth: 2,
                      ),
                ],
              ),
              // Member bubbles, clustered by on-screen proximity at
              // the current zoom (rebuilds as the camera moves).
              _MemberMarkerLayer(
                members: members,
                expandedClusters: _expandedClusters,
                onMemberTap: _openMemberDetails,
                onClusterTap: _expandCluster,
              ),
            ],
          ),

          // Loading / error overlays for the initial fetch.
          if (_loading)
            const Positioned.fill(
              child: ColoredBox(
                color: Color(0x66000000),
                child: Center(
                  child: CircularProgressIndicator(color: AppColors.purple),
                ),
              ),
            ),
          if (_error != null)
            Positioned.fill(
              child: _LoadErrorCard(message: _error!, onRetry: _load),
            ),

          // Top: family name, with a location-off re-prompt banner below it
          // when the user skipped location during onboarding.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 8, left: 12, right: 76),
                    child: CircleSwitcher(
                      circles: [_familyName],
                      selectedIndex: 0,
                      onSelected: (_) {},
                      onJoinCircle: _hasFamily ? null : _openJoinCircle,
                      alignment: Alignment.centerLeft,
                    ),
                  ),
                  if (_locationOff)
                    Padding(
                      padding: const EdgeInsets.only(
                        top: 8,
                        left: 12,
                        right: 12,
                      ),
                      child: _LocationOffBanner(onEnable: _enableLocation),
                    ),
                ],
              ),
            ),
          ),

          // Top-right: satellite / standard layer toggle, with a "center on
          // me" button stacked beneath it.
          Positioned(
            top: 0,
            right: 12,
            child: SafeArea(
              bottom: false,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: _LayerToggle(
                      isSatellite: _satellite,
                      onToggle: _toggleSatellite,
                    ),
                  ),
                  const SizedBox(height: 8),
                  _LocateButton(onTap: _centerOnUser),
                ],
              ),
            ),
          ),

          // Bottom-center `+` FAB for the Check In / Help Alert / Invite quick
          // actions, docked just above the fixed control bar.
          Positioned(
            left: 0,
            right: 0,
            bottom: controlBarReserved + 12,
            child: Center(
              child: FloatingActionButton(
                onPressed: _showAddActions,
                tooltip: 'Add — Check In / Help Alert / Invite',
                child: const Icon(Icons.add),
              ),
            ),
          ),

          // Fixed bottom control bar (SOS + People / Places / Safety
          // destinations + Settings gear), pinned to the very bottom and always
          // visible. Drawn last so it sits above the map.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: MapBottomBar(
                onSos: _openSos,
                onPeople: _openPeople,
                onPlaces: _openPlaces,
                onSafety: ServerFeatures.instance.smsConfigured
                    ? _openSafety
                    : null,
                onSettings: _openSettings,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One row in the map `+` sheet. Icon and copy share a vertical center so
/// a two-line subtitle does not leave the glyph hanging on the title.
class _AddActionTile extends StatelessWidget {
  const _AddActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(icon, color: BrandTheme.of(context).accentInk, size: 28),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: colors.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 13,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
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

/// A small floating button that toggles between standard and satellite tiles.
class _LayerToggle extends StatelessWidget {
  const _LayerToggle({required this.isSatellite, required this.onToggle});

  final bool isSatellite;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: isSatellite ? 'Switch to standard map' : 'Switch to satellite',
      child: Material(
        color: BrandTheme.of(context).sheet,
        shape: const CircleBorder(),
        elevation: 3,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Icon(
              isSatellite ? Icons.map : Icons.satellite_alt,
              size: 22,
              color: BrandTheme.of(context).accentInk,
            ),
          ),
        ),
      ),
    );
  }
}

/// A small circular "center on me" button that recenters the map on the
/// caller's current location.
class _LocateButton extends StatelessWidget {
  const _LocateButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Center on my location',
      child: Material(
        color: BrandTheme.of(context).sheet,
        shape: const CircleBorder(),
        elevation: 3,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Icon(
              Icons.my_location,
              size: 22,
              color: BrandTheme.of(context).accentInk,
            ),
          ),
        ),
      ),
    );
  }
}

/// Builds the member [MarkerLayer] from the current camera, clustering by
/// on-screen (pixel) proximity so bubbles merge and separate as the user
/// pans and zooms.
///
/// Lives inside [FlutterMap]'s children so it can read the camera via
/// [MapCamera.of], which also subscribes it to camera changes (it rebuilds on
/// every pan/zoom).
class _MemberMarkerLayer extends StatelessWidget {
  const _MemberMarkerLayer({
    required this.members,
    required this.expandedClusters,
    required this.onMemberTap,
    required this.onClusterTap,
  });

  final List<Member> members;
  final Set<String> expandedClusters;
  final ValueChanged<Member> onMemberTap;
  final void Function(String clusterId, LatLng centroid) onClusterTap;

  @override
  Widget build(BuildContext context) {
    final MapCamera camera = MapCamera.of(context);
    final List<BubblePlacement> placements = placeBubbles(
      members,
      toScreenOffset: (latLng) {
        final p = camera.latLngToScreenPoint(latLng);
        return Offset(p.x, p.y);
      },
      toLatLng: camera.offsetToCrs,
      expandedClusterIds: expandedClusters,
    );

    return MarkerLayer(
      markers: [
        for (final BubblePlacement p in placements)
          if (p.isCluster)
            Marker(
              point: p.position,
              width: 140,
              height: 90,
              alignment: Alignment.center,
              child: ClusterBubble(
                members: p.clusterMembers,
                onTap: () => onClusterTap(p.clusterId!, p.position),
              ),
            )
          else
            Marker(
              point: p.position,
              width: MemberAvatarBubble.markerWidth,
              height: MemberAvatarBubble.markerSizeFor(p.member!).height,
              alignment: MemberAvatarBubble.markerAlignmentFor(p.member!),
              child: MemberAvatarBubble(
                member: p.member!,
                onTap: () => onMemberTap(p.member!),
              ),
            ),
      ],
    );
  }
}

/// A gentle banner shown on the map when location sharing is off (the user
/// skipped it during onboarding). Explains the degraded state and offers a
/// one-tap re-prompt so they can enable it without digging through Settings.
class _LocationOffBanner extends StatelessWidget {
  const _LocationOffBanner({required this.onEnable});

  final VoidCallback onEnable;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: BrandTheme.of(context).sheet,
      elevation: 3,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            const Icon(Icons.location_off, color: AppColors.statusOrange),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Location sharing is off, so your family can\'t see where you '
                'are.',
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(onPressed: onEnable, child: const Text('Enable')),
          ],
        ),
      ),
    );
  }
}

/// A centered error card shown when the initial family fetch fails, with a
/// retry button that re-runs [_MapScreenState._load].
class _LoadErrorCard extends StatelessWidget {
  const _LoadErrorCard({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Material(
        color: BrandTheme.of(context).sheet,
        elevation: 4,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.cloud_off,
                size: 40,
                color: AppColors.statusOrange,
              ),
              const SizedBox(height: 12),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: onRetry,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.purple,
                ),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
