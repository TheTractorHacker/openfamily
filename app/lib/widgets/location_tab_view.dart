import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../models/circle.dart';
import '../models/member.dart';
import '../models/place.dart';
import '../screens/chat_screen.dart';
import '../services/person_launcher.dart';
import '../services/place_alert_rules_service.dart';
import '../services/weekly_summary_service.dart';
import '../services/member_day_service.dart';
import 'person_panel.dart';
import 'package:latlong2/latlong.dart' show LatLng;
import '../theme/app_theme.dart';
import 'attention_center.dart';
import 'private_circle_widgets.dart';
import '../utils/member_status.dart';
import '../services/perf/perf_monitor.dart';
import 'ds/ds.dart';
import '../services/speed_units.dart';
import 'live_speed.dart';
import 'invite_hero_card.dart';
import 'member_avatar_bubble.dart';
import 'visible_value_builder.dart';
import '../services/error_copy.dart';

/// Loads saved places for the Places tab. Injected in tests.
typedef PlacesLoader = Future<List<Place>> Function();

/// Presentational "Location" tab: a full-bleed [map] with floating controls,
/// a circle-switcher pill and a draggable People / Places sheet.
///
/// The map is a black box supplied by the caller, and every action is a
/// callback, so this widget owns no services and can be rendered in tests.
class LocationTabView extends StatefulWidget {
  /// The layout rule: wide or landscape bodies show the map beside a fixed
  /// panel, narrow ones a bottom sheet. Also used by the map screen to know
  /// whether a sheet covers the lower map.
  static bool isTwoPaneSize(Size s) =>
      s.width >= 720 || (s.width > s.height * 1.2 && s.width >= 560);

  const LocationTabView({
    super.key,
    required this.map,
    required this.circleName,
    required this.members,
    required this.placesLoader,
    this.circles = const <Circle>[],
    this.membersListenable,
    this.selfId,
    this.sharingPaused = false,
    this.selectedCircleId,
    this.circleSharingPaused = false,
    this.onSelectCircle,
    this.onResumeCircleSharing,
    this.loading = false,
    this.error,
    this.hasFamily = true,
    this.locationOff = false,
    this.satellite = false,
    this.onRetry,
    this.onEnableLocation,
    this.onToggleSatellite,
    this.onLocate,
    this.onOpenSettings,
    this.onInvite,
    this.onQuickInvite,
    this.onCheckIn,
    this.onOpenSharing,
    this.onSos,
    this.onSelectMember,
    this.onOpenMember,
    this.personId,
    this.onClosePerson,
    this.placeAlerts,
    this.weeklyApi,
    this.dayLoader,
    this.uriLauncher,
    this.requestUpdate,
    this.onManageCircles,
    this.onOpenCircle,
    this.onJoinCircle,
    this.onOpenPlaces,
    this.topOverlay,
  });

  final Widget map;
  final String circleName;
  final List<Circle> circles;
  final List<Member> members;

  /// Live roster. When given, ONLY the People list listens to it (and skips
  /// rebuilds while the tab is hidden); the rest of the tab (map, floating
  /// controls, sheet chrome) is untouched by roster updates. [members] is
  /// then just the initial value.
  final ValueListenable<List<Member>>? membersListenable;
  final String? selfId;
  final bool sharingPaused;

  /// The circle the map is scoped to: a circle id, `all`, or null when there
  /// is only one circle (nothing to choose).
  final String? selectedCircleId;

  /// The user turned sharing off in the selected circle: show a clear
  /// "sharing paused" state with a way to resume.
  final bool circleSharingPaused;

  /// A circle (or `all`) was picked in the pill sheet. When null the sheet
  /// falls back to opening the circle's detail (legacy behaviour).
  final ValueChanged<String>? onSelectCircle;
  final VoidCallback? onResumeCircleSharing;
  final bool loading;
  final String? error;
  final bool hasFamily;
  final bool locationOff;
  final bool satellite;
  final PlacesLoader placesLoader;

  final VoidCallback? onRetry;
  final VoidCallback? onEnableLocation;
  final VoidCallback? onToggleSatellite;
  final VoidCallback? onLocate;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onInvite;

  /// One-tap invite (create a link and open the share sheet). When null the
  /// solo-circle card falls back to [onInvite].
  final Future<void> Function()? onQuickInvite;
  final VoidCallback? onCheckIn;

  /// Opens the check-in / pause / live-share sheet.
  final VoidCallback? onOpenSharing;
  final VoidCallback? onSos;

  /// A person row was tapped: the map should center on them.
  final ValueChanged<Member>? onSelectMember;

  /// "Details" on the selected person: profile, history, location request.
  final ValueChanged<Member>? onOpenMember;

  /// The person whose full view is open (tapped on the map or in the list).
  /// The sheet shows their view instead of the People / Places tabs.
  final String? personId;

  /// The person view's back arrow; the host stops following them.
  final VoidCallback? onClosePerson;

  /// Injected services for the person view (tests); defaults use the API.
  final MemberPlaceAlertsApi? placeAlerts;
  final WeeklySummaryApi? weeklyApi;
  final MemberDayLoader? dayLoader;
  final UriLauncher? uriLauncher;
  final Future<void> Function(String memberId)? requestUpdate;
  final VoidCallback? onManageCircles;
  final ValueChanged<Circle>? onOpenCircle;
  final VoidCallback? onJoinCircle;
  final VoidCallback? onOpenPlaces;

  /// Floating chip under the top row (the map's "Following" pill).
  final Widget? topOverlay;

  @override
  State<LocationTabView> createState() => _LocationTabViewState();
}

class _LocationTabViewState extends State<LocationTabView> {
  /// Sheet heights, as fractions of the tab body.
  static const double _peekPx = 188;
  static const double _half = 0.5;

  final DraggableScrollableController _sheet = DraggableScrollableController();

  /// The map is moved (not recreated) between the bottom-sheet layout and the
  /// two-pane layout, so unfolding the phone keeps the camera, zoom and tiles.
  final GlobalKey _mapKey = GlobalKey(debugLabel: 'location-map');
  Widget get _map => KeyedSubtree(key: _mapKey, child: widget.map);

  // A solo circle has nothing to look at but the invite card, so the sheet
  // opens to half height once (never again, so the user's own dragging wins).
  bool _soloOpened = false;

  // Tall enough for the handle, tabs, your own row and the whole invite card;
  // clamped to the sheet's maximum in build.
  double _soloTarget = 0.72;

  bool get _isSolo =>
      !widget.loading && widget.hasFamily && widget.members.length <= 1;

  @override
  void initState() {
    super.initState();
    _selectedId = widget.personId;
    _soloOpened = _isSolo;
    if (_selectedId != null) _openSheetFor();
  }

  @override
  void didUpdateWidget(LocationTabView old) {
    super.didUpdateWidget(old);
    if (widget.personId != old.personId) {
      _selectedId = widget.personId;
      if (_selectedId != null) _openSheetFor();
    }
    if (_soloOpened || !_isSolo) return;
    _soloOpened = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_sheet.isAttached) return;
      _sheet.animateTo(
        _soloTarget,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    });
  }
  final ValueNotifier<double> _extent = ValueNotifier<double>(0);

  int _tab = 0;
  String? _selectedId;

  /// Loaded the first time the Places tab opens, not before.
  Future<List<Place>>? _places;

  @override
  void dispose() {
    _sheet.dispose();
    _panelScroll.dispose();
    _extent.dispose();
    super.dispose();
  }

  void _reloadPlaces() => setState(() => _places = widget.placesLoader());

  /// Tapping a person opens their full view straight away (no extra
  /// "details" tap) and asks the map to follow them.
  void _select(Member m) {
    setState(() => _selectedId = m.id);
    widget.onSelectMember?.call(m);
    _openSheetFor();
  }

  void _closePerson() {
    setState(() => _selectedId = null);
    widget.onClosePerson?.call();
  }

  /// Lifts the sheet so the person's card is readable with the map above it.
  void _openSheetFor() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_sheet.isAttached) return;
      if (_sheet.size >= 0.55) return;
      _sheet.animateTo(
        0.6,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    });
  }

  Member? _personMember() {
    final String? id = _selectedId;
    if (id == null) return null;
    final List<Member> ms = widget.membersListenable?.value ?? widget.members;
    for (final Member m in ms) {
      if (m.id == id) return m;
    }
    return null;
  }

  LatLng? _myPosition() {
    final String? me = widget.selfId;
    if (me == null) return null;
    final List<Member> ms = widget.membersListenable?.value ?? widget.members;
    for (final Member m in ms) {
      if (m.id == me) return m.position;
    }
    return null;
  }

  /// Message: the circle's chat when one is known, else the phone's SMS app.
  VoidCallback? _messageFor(Member m) {
    final Circle? c = _activeCircle ??
        (widget.circles.isEmpty
            ? null
            : widget.circles.firstWhere((Circle x) => x.isPrimary,
                orElse: () => widget.circles.first));
    if (c == null) return null;
    return () => Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => ChatScreen(
              circleId: c.id, circleName: c.name, isAdmin: c.isAdmin),
        ));
  }

  void _showCircles() {
    final BrandTheme brand = BrandTheme.of(context);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext ctx) {
        final List<Circle> circles = widget.circles;
        return SafeArea(
          child: DsSheetScaffold(
            title: 'Your circles',
            header: _circleSheetHeader(ctx),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (circles.isEmpty)
                    DsListRow(
                      title: widget.circleName,
                      subtitle: 'Shown on the map',
                      leading: DsListRow.iconTile(ctx, Icons.groups_outlined),
                      trailing: Icon(Icons.check, color: brand.accentInk),
                      onTap: () => Navigator.of(ctx).pop(),
                    ),
                  if (circles.length > 1 && widget.onSelectCircle != null)
                    DsListRow(
                      title: 'All circles',
                      subtitle: 'Everyone from every circle',
                      leading: DsListRow.iconTile(ctx, Icons.public),
                      trailing: widget.selectedCircleId == 'all'
                          ? Icon(Icons.check, color: brand.accentInk)
                          : null,
                      onTap: () {
                        Navigator.of(ctx).pop();
                        widget.onSelectCircle?.call('all');
                      },
                    ),
                  for (final Circle c in circles)
                    DsListRow(
                      title: c.name,
                      subtitle:
                          '${c.memberCount} '
                          '${c.memberCount == 1 ? 'person' : 'people'}'
                          '${c.isAdmin ? ' - Admin' : ''}'
                          '${c.isPrivate ? (c.e2eeServerMember ? ' - Server can read' : c.serverAssist ? ' - Private + server' : ' - End-to-end encrypted') : ''}'
                          '${c.sharingEnabled ? '' : ' - Sharing paused'}'
                          '${_isActive(c) ? ' - Shown on the map' : ''}',
                      leading: _circleLeading(ctx, c),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          if (_isActive(c))
                            Icon(Icons.check, color: brand.accentInk),
                          if (widget.onOpenCircle != null)
                            IconButton(
                              key: ValueKey<String>('circle-info-${c.id}'),
                              tooltip: 'Open details for ${c.name}',
                              constraints: const BoxConstraints(
                                minWidth: kMinTarget,
                                minHeight: kMinTarget,
                              ),
                              icon: const Icon(Icons.info_outline),
                              onPressed: () {
                                Navigator.of(ctx).pop();
                                widget.onOpenCircle!.call(c);
                              },
                            ),
                        ],
                      ),
                      chevron: !_isActive(c) &&
                          widget.onSelectCircle == null &&
                          widget.onOpenCircle == null,
                      onTap: () {
                        Navigator.of(ctx).pop();
                        if (widget.onSelectCircle != null) {
                          widget.onSelectCircle!.call(c.id);
                        } else if (!_isActive(c)) {
                          widget.onOpenCircle?.call(c);
                        }
                      },
                    ),
                  DsListRow(
                    title: 'Create or join a circle',
                    leading: DsListRow.iconTile(ctx, Icons.add),
                    chevron: true,
                    onTap: () {
                      Navigator.of(ctx).pop();
                      widget.onManageCircles?.call();
                    },
                  ),
                  const SizedBox(height: AppSpace.sm),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// The single circle the map is scoped to, or null for "All circles" or
  /// when the circle list is not known.
  Circle? get _activeCircle {
    if (widget.selectedCircleId == 'all') return null;
    for (final Circle c in widget.circles) {
      if (_isActive(c)) return c;
    }
    return null;
  }

  bool _isActive(Circle c) {
    if (widget.selectedCircleId != null) {
      return widget.selectedCircleId == c.id;
    }
    return widget.circles.any((Circle x) => x.isPrimary)
        ? c.isPrimary
        : c.name == widget.circleName;
  }

  /// Pinned header of the circle sheet: for the selected circle, whether
  /// location sharing is on or paused (icon plus words) and a clear way to
  /// open its details (members, roles, sharing, invites).
  Widget? _circleSheetHeader(BuildContext ctx) {
    final Circle? c = _activeCircle;
    if (c == null || widget.onOpenCircle == null) return null;
    final bool paused = !c.sharingEnabled;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.xl,
        0,
        AppSpace.xl,
        AppSpace.sm,
      ),
      child: Wrap(
        spacing: AppSpace.sm,
        runSpacing: AppSpace.sm,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          _SharingChip(paused: paused),
          DsPillButton(
            label: 'Open circle details',
            icon: Icons.info_outline,
            style: DsPillStyle.tonal,
            onPressed: () {
              Navigator.of(ctx).pop();
              widget.onOpenCircle!.call(c);
            },
          ),
        ],
      ),
    );
  }

  Widget _circleLeading(BuildContext ctx, Circle c) {
    final String? icon = c.icon;
    if (icon == null) return DsListRow.iconTile(ctx, Icons.groups_outlined);
    return SizedBox(
      width: 40,
      height: 40,
      child: Center(child: Text(icon, style: const TextStyle(fontSize: 24))),
    );
  }

  @override
  Widget build(BuildContext context) {
    PerfMonitor.instance.countBuild('LocationTabView');
    final BrandTheme brand = BrandTheme.of(context);
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints box) {
          if (isTwoPane(box)) return _buildTwoPane(context, box);
          final double h = box.maxHeight;
          final double minSize = (_peekPx / h).clamp(0.12, 0.4);
          // Leave the top row (settings / circle pill) visible when fully open.
          final double full = (1 - (MediaQuery.paddingOf(context).top + 72) / h)
              .clamp(0.5, 0.92);
          _soloTarget = math.min(0.72, full);
          final double textScale = MediaQuery.textScalerOf(
            context,
          ).scale(1).clamp(1.0, 2.0);
          // Capped so the docked buttons stay below the map centre at huge text.
          final double peek = (minSize * textScale).clamp(minSize, math.max(minSize, 0.38));
          return Stack(
            children: <Widget>[
              Positioned.fill(child: _map),
              _buildTop(context),
              _buildFloating(context, h, peek),
              _buildSpeedChip(context, h, peek),
              NotificationListener<DraggableScrollableNotification>(
                onNotification: (DraggableScrollableNotification n) {
                  _extent.value = n.extent;
                  return false;
                },
                child: DraggableScrollableSheet(
                  controller: _sheet,
                  initialChildSize: _isSolo ? math.max(peek, _soloTarget) : peek,
                  minChildSize: peek,
                  maxChildSize: full,
                  snap: true,
                  snapSizes: <double>[if (peek < _half - 0.05) _half],
                  builder: (BuildContext ctx, ScrollController sc) {
                    return DecoratedBox(
                      decoration: BoxDecoration(
                        color: brand.sheet,
                        borderRadius: AppRadius.sheet,
                        boxShadow: const <BoxShadow>[
                          BoxShadow(
                            color: Color(0x40000000),
                            blurRadius: 16,
                            offset: Offset(0, -2),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: AppRadius.sheet,
                        child: _buildSheetBody(ctx, sc),
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Wide or landscape bodies show the map beside a fixed People / Places
  /// panel instead of a bottom sheet that would cover most of the map.
  static bool isTwoPane(BoxConstraints box) =>
      LocationTabView.isTwoPaneSize(Size(box.maxWidth, box.maxHeight));

  final ScrollController _panelScroll = ScrollController();

  Widget _buildTwoPane(BuildContext context, BoxConstraints box) {
    final BrandTheme brand = BrandTheme.of(context);
    final double panelW = (box.maxWidth * 0.38).clamp(340.0, 440.0);
    final EdgeInsets pad = MediaQuery.paddingOf(context);
    return Row(
      children: <Widget>[
        Expanded(
          child: Stack(
            children: <Widget>[
              Positioned.fill(child: _map),
              _buildTop(context),
              if (_selectedId == null)
                Positioned(
                  left: AppSpace.md,
                  right: AppSpace.md,
                  bottom: AppSpace.md + pad.bottom,
                  child: _floatingRow(context),
                ),
            ],
          ),
        ),
        SizedBox(
          width: panelW,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: brand.sheet,
              border: Border(
                left: BorderSide(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
            ),
            // The panel is full height, so it clears the status bar itself.
            child: _buildSheetBody(
              context,
              _panelScroll,
              handle: false,
              topInset: pad.top + AppSpace.sm,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTop(BuildContext context) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpace.md,
            AppSpace.sm,
            AppSpace.md,
            0,
          ),
          child: Column(
            children: <Widget>[
              Row(
                children: <Widget>[
                  DsMapButton(
                    icon: Icons.settings_outlined,
                    tooltip: 'Settings',
                    onPressed: widget.onOpenSettings,
                  ),
                  const SizedBox(width: AppSpace.sm),
                  Expanded(
                    child: Center(
                      child: _CirclePill(
                        name: widget.circleName,
                        sharingPaused: widget.circleSharingPaused,
                        onTap: _showCircles,
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpace.sm),
                  // Hidden unless something needs attention (then it adds its own gap).
                  const AttentionButton(onMap: true),
                  DsMapButton(
                    icon: Icons.person_add_alt_1_outlined,
                    tooltip: 'Invite someone',
                    onPressed: widget.onInvite,
                  ),
                ],
              ),
              if (_activeCircle?.isPrivate == true)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpace.sm),
                  child: PrivateCircleBadge(serverMember: _activeCircle?.e2eeServerMember == true, serverAssist: _activeCircle?.serverAssist == true),
                ),
              if (widget.circleSharingPaused)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpace.sm),
                  child: _CircleSharingPausedBanner(
                    circleName: widget.circleName,
                    onResume: widget.onResumeCircleSharing,
                  ),
                ),
              if (widget.locationOff)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpace.sm),
                  child: _LocationOffBanner(onEnable: widget.onEnableLocation),
                ),
              if (widget.topOverlay != null)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpace.sm),
                  child: widget.topOverlay,
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Life360-style speed chip over the map while the open person is driving.
  Widget _buildSpeedChip(BuildContext context, double h, double peek) {
    final Member? m = _personMember();
    if (m == null || m.movement != MovementType.car) {
      return const SizedBox.shrink();
    }
    return ValueListenableBuilder<double>(
      valueListenable: _extent,
      builder: (BuildContext context, double raw, _) => Positioned(
        right: AppSpace.lg,
        bottom: (raw < peek ? peek : raw) * h + AppSpace.md,
        child: LiveSpeedBuilder(
          member: m,
          builder: (BuildContext _, double? mps, UnitSystem u) {
            if (mps == null) return const SizedBox.shrink();
            return DecoratedBox(
              key: const Key('person_speed_chip'),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.92),
                borderRadius: BorderRadius.circular(AppRadius.lg),
                boxShadow: const <BoxShadow>[
                  BoxShadow(color: Color(0x33000000), blurRadius: 8),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpace.md, vertical: AppSpace.sm),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const Icon(Icons.directions_car,
                        size: 20, color: Colors.black87),
                    const SizedBox(width: AppSpace.sm),
                    Text(u.formatSpeed(mps),
                        style: AppType.body.copyWith(
                            color: Colors.black87, fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildFloating(BuildContext context, double h, double peek) {
    if (_selectedId != null) return const SizedBox.shrink();
    // The row itself is built once per tab rebuild and passed as the
    // builder's `child`, so a drag frame only repositions it.
    final Widget row = _floatingRow(context);
    return ValueListenableBuilder<double>(
      valueListenable: _extent,
      child: row,
      builder: (BuildContext context, double raw, Widget? child) {
        final double extent = raw < peek ? peek : raw;
        final bool visible = extent < 0.62;
        return Positioned(
          left: AppSpace.md,
          right: AppSpace.md,
          bottom: extent * h + AppSpace.sm,
          child: IgnorePointer(
            ignoring: !visible,
            child: AnimatedOpacity(
              opacity: visible ? 1 : 0,
              duration: AppMotion.of(context, AppMotion.fast),
              child: child,
            ),
          ),
        );
      },
    );
  }

  Widget _floatingRow(BuildContext context) {
    // Life360-style docking: the quick actions sit at the left edge and the
    // layers / recenter buttons at the right edge, both just above the
    // sheet. The middle stays empty so the map's centre and markers are
    // never covered.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        Expanded(
          child: Align(
            alignment: Alignment.bottomLeft,
            // Scales down rather than wrapping or overflowing at large text.
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.bottomLeft,
              child: Row(
                key: const ValueKey<String>('map-quick-actions'),
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  _QuickAction(
                    label: 'Check in',
                    icon: Icons.check_circle_outline,
                    onPressed: widget.onCheckIn,
                  ),
                  if (widget.onOpenSharing != null) ...<Widget>[
                    const SizedBox(width: AppSpace.sm),
                    _QuickAction(
                      label: 'Share',
                      icon: Icons.share_location,
                      onPressed: widget.onOpenSharing,
                      semanticLabel:
                          'Check in, pause sharing or share live location',
                    ),
                  ],
                  const SizedBox(width: AppSpace.sm),
                  _QuickAction(
                    label: 'SOS',
                    icon: Icons.warning_amber_rounded,
                    danger: true,
                    onPressed: widget.onSos,
                    semanticLabel: 'Send an SOS to your circle',
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: AppSpace.sm),
        Column(
          key: const ValueKey<String>('map-side-buttons'),
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            DsMapButton(
              icon: widget.satellite ? Icons.map : Icons.layers,
              tooltip: widget.satellite
                  ? 'Switch to standard map'
                  : 'Switch to satellite',
              onPressed: widget.onToggleSatellite,
            ),
            const SizedBox(height: AppSpace.sm),
            DsMapButton(
              icon: Icons.my_location,
              tooltip: 'Center on my location',
              onPressed: widget.onLocate,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSheetBody(
    BuildContext context,
    ScrollController sc, {
    bool handle = true,
    double topInset = 0,
  }) {
    if (_selectedId != null) {
      Widget panel(Member m) => PersonPanel(
            key: ValueKey<String>('person-panel-${m.id}'),
            member: m,
            controller: sc,
            onClose: _closePerson,
            selfId: widget.selfId,
            myPosition: _myPosition(),
            handle: handle,
            topInset: topInset,
            onMessage: _messageFor(m),
            alerts: widget.placeAlerts,
            weekly: widget.weeklyApi,
            dayLoader: widget.dayLoader,
            launcher: widget.uriLauncher,
            requestUpdate: widget.requestUpdate,
          );
      final ValueListenable<List<Member>>? live = widget.membersListenable;
      if (live != null) {
        return ValueListenableBuilder<List<Member>>(
          valueListenable: live,
          builder: (BuildContext _, List<Member> __, Widget? ___) {
            final Member? m = _personMember();
            return m == null ? _peopleBody(context, sc, handle, topInset) : panel(m);
          },
        );
      }
      final Member? m = _personMember();
      if (m != null) return panel(m);
    }
    return _peopleBody(context, sc, handle, topInset);
  }

  Widget _peopleBody(
      BuildContext context, ScrollController sc, bool handle, double topInset) {
    return CustomScrollView(
      controller: sc,
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: Column(
            children: <Widget>[
              if (handle) const DsDragHandle() else SizedBox(height: topInset),
              _SheetTabChips(
                labels: const <String>['People', 'Places'],
                icons: const <IconData>[
                  Icons.groups_rounded,
                  Icons.place_rounded,
                ],
                selected: _tab,
                onChanged: (int i) => setState(() => _tab = i),
              ),
              const SizedBox(height: AppSpace.sm),
            ],
          ),
        ),
        if (_tab == 0)
          ..._peopleSection(context)
        else
          ..._placesSlivers(context),
        SliverToBoxAdapter(
          child: SizedBox(
            height: MediaQuery.paddingOf(context).bottom + AppSpace.xxxl,
          ),
        ),
      ],
    );
  }

  /// The People slivers. With a live [LocationTabView.membersListenable] they
  /// sit behind a listener of their own, so roster updates rebuild nothing
  /// else in the tab.
  List<Widget> _peopleSection(BuildContext context) {
    final ValueListenable<List<Member>>? live = widget.membersListenable;
    if (live == null) return _peopleSlivers(context, widget.members);
    return <Widget>[
      VisibleValueBuilder<List<Member>>(
        valueListenable: live,
        builder: (BuildContext ctx, List<Member> ms, _) {
          PerfMonitor.instance.countBuild('PeopleList');
          return SliverMainAxisGroup(slivers: _peopleSlivers(ctx, ms));
        },
      ),
    ];
  }

  /// Person rows by member id. A row's widget is reused (and therefore NOT
  /// rebuilt) while its member instance and flags are unchanged, so a
  /// location frame for one person rebuilds one row, not the whole list.
  final Map<String, _RowMemo> _rows = <String, _RowMemo>{};

  Widget _personRow(Member m) {
    final bool self = m.id == widget.selfId;
    final bool paused = self && widget.sharingPaused;
    final bool selected = m.id == _selectedId;
    final _RowMemo? memo = _rows[m.id];
    if (memo != null &&
        identical(memo.member, m) &&
        memo.paused == paused &&
        memo.selected == selected) {
      return memo.widget;
    }
    final Widget w = _PersonRow(
      key: ValueKey<String>('person-${m.id}'),
      member: m,
      paused: paused,
      selected: selected,
      onTap: () => _select(m),
    );
    _rows[m.id] = _RowMemo(m, paused, selected, w);
    return w;
  }

  List<Widget> _peopleSlivers(BuildContext context, List<Member> members) {
    if (widget.error != null && members.isEmpty) {
      // Compact on purpose: the retry must be visible at the sheet's peek.
      return <Widget>[
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.md,
              0,
              AppSpace.md,
              AppSpace.sm,
            ),
            child: DsOfflineBanner(
              message: widget.error!,
              onRetry: widget.onRetry,
            ),
          ),
        ),
      ];
    }
    if (widget.loading && members.isEmpty) {
      return const <Widget>[
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(AppSpace.xxl),
            child: Center(child: CircularProgressIndicator()),
          ),
        ),
      ];
    }
    if (!widget.hasFamily) {
      return <Widget>[
        SliverToBoxAdapter(
          child: DsEmptyState(
            icon: Icons.groups_outlined,
            title: 'You are not in a circle yet',
            message: 'Join with an invite code to see your people here.',
            actionLabel: 'Join a circle',
            onAction: widget.onJoinCircle,
          ),
        ),
      ];
    }
    final List<Member> ms = members;
    if (_rows.length > ms.length) {
      final Set<String> ids = <String>{for (final Member m in ms) m.id};
      _rows.removeWhere((String id, _) => !ids.contains(id));
    }
    return <Widget>[
      if (widget.error != null)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpace.md,
              0,
              AppSpace.md,
              AppSpace.sm,
            ),
            child: DsOfflineBanner(
              message: widget.error!,
              onRetry: widget.onRetry,
            ),
          ),
        ),
      SliverList.builder(
        itemCount: ms.length,
        itemBuilder: (BuildContext ctx, int i) => _personRow(ms[i]),
      ),
      SliverToBoxAdapter(
        child: ms.length <= 1 && widget.hasFamily
            ? InviteHeroCard(
                onSend: widget.onQuickInvite ??
                    () async => widget.onInvite?.call(),
                onShowCode: () => widget.onInvite?.call(),
              )
            : DsListRow(
                title: 'Add a person',
                leading: DsListRow.iconTile(
                  context,
                  Icons.person_add_alt_1_outlined,
                ),
                onTap: widget.onInvite,
              ),
      ),
    ];
  }

  List<Widget> _placesSlivers(BuildContext context) {
    return <Widget>[
      SliverToBoxAdapter(
        child: FutureBuilder<List<Place>>(
          future: _places ??= widget.placesLoader(),
          builder: (BuildContext ctx, AsyncSnapshot<List<Place>> snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.all(AppSpace.xxl),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snap.hasError) {
              return DsErrorState(
                title: 'Could not load places',
                message: describeError(snap.error!).message,
                onRetry: _reloadPlaces,
              );
            }
            // Only this circle's places (and whole-family ones), as every
            // other member of the circle sees them.
            final List<Place> places = placesForScope(
              snap.data ?? const <Place>[],
              widget.selectedCircleId,
            );
            if (places.isEmpty) {
              return DsEmptyState(
                icon: Icons.place_outlined,
                title: 'No places yet',
                message:
                    'Add Home, School or Work to see who arrives and '
                    'leaves.',
                actionLabel: 'Add a place',
                onAction: widget.onOpenPlaces,
              );
            }
            return Column(
              children: <Widget>[
                for (final Place p in places)
                  DsListRow(
                    title: p.name,
                    subtitle: p.address.isEmpty
                        ? '${p.radiusLabel} radius'
                        : p.address,
                    leading: DsListRow.iconTile(ctx, p.icon),
                    chevron: true,
                    onTap: widget.onOpenPlaces,
                  ),
                DsListRow(
                  title: 'Manage places',
                  leading: DsListRow.iconTile(
                    ctx,
                    Icons.add_location_alt_outlined,
                  ),
                  chevron: true,
                  onTap: widget.onOpenPlaces,
                ),
              ],
            );
          },
        ),
      ),
    ];
  }
}

/// Life360-style row of rounded chips under the sheet handle: the active one
/// is filled dark, the others float as light cards.
class _SheetTabChips extends StatelessWidget {
  const _SheetTabChips({
    required this.labels,
    required this.icons,
    required this.selected,
    required this.onChanged,
  });

  final List<String> labels;
  final List<IconData> icons;
  final int selected;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final BrandTheme brand = BrandTheme.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
      child: Row(
        children: <Widget>[
          for (int i = 0; i < labels.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(width: AppSpace.sm),
            Expanded(
              child: Semantics(
                button: true,
                selected: i == selected,
                label: labels[i],
                excludeSemantics: true,
                onTap: () => onChanged(i),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onChanged(i),
                  child: AnimatedContainer(
                    duration: AppMotion.of(context, AppMotion.fast),
                    constraints: const BoxConstraints(minHeight: kMinTarget),
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpace.md,
                      vertical: AppSpace.sm,
                    ),
                    decoration: BoxDecoration(
                      color: i == selected ? cs.onSurface : brand.paper,
                      borderRadius: BorderRadius.circular(18),
                      boxShadow: i == selected ? null : kFloatShadow,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        Icon(
                          icons[i],
                          size: 20,
                          color: i == selected ? cs.surface : cs.onSurface,
                        ),
                        const SizedBox(width: AppSpace.sm),
                        Flexible(
                          child: Text(
                            labels[i],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppType.body.copyWith(
                              fontWeight: FontWeight.w700,
                              color:
                                  i == selected ? cs.surface : cs.onSurface,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Circle-switcher pill: circle name plus a chevron. With a single circle it
/// still shows the name (and still opens the list so Create/Join is
/// reachable).
class _CirclePill extends StatelessWidget {
  const _CirclePill({
    required this.name,
    required this.onTap,
    this.sharingPaused = false,
  });

  final String name;
  final bool sharingPaused;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final BrandTheme brand = BrandTheme.of(context);
    return Semantics(
      button: true,
      label: 'Circle: $name. Location sharing: '
          '${sharingPaused ? 'paused' : 'on'}. Switch circle or open details',
      excludeSemantics: true,
      onTap: onTap,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.pill),
          boxShadow: kFloatShadow,
        ),
        child: Material(
          color: brand.sheet,
          shape: const StadiumBorder(),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: kMinTarget),
              child: Padding(
                padding: const EdgeInsets.only(
                  left: AppSpace.lg,
                  right: AppSpace.sm,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Flexible(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: AppSpace.xs,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppType.headline,
                            ),
                            Text(
                              sharingPaused
                                  ? 'Location sharing: paused'
                                  : 'Location sharing: on',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppType.secondary.copyWith(
                                fontSize: 12,
                                color: sharingPaused
                                    ? AppColors.statusOrange
                                    : Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpace.xs),
                    Icon(Icons.keyboard_arrow_down, color: brand.accentInk),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "Location sharing: on / paused" with an icon, so colour is never the only
/// signal.
class _SharingChip extends StatelessWidget {
  const _SharingChip({required this.paused});

  final bool paused;

  @override
  Widget build(BuildContext context) => Semantics(
        container: true,
        child: DsStatusChip(
          label: paused ? 'Location sharing: paused' : 'Location sharing: on',
          icon: paused ? Icons.pause_circle_outline : Icons.location_on,
          color: paused ? AppColors.statusOrange : AppColors.statusGreen,
        ),
      );
}

/// Shown when the user turned sharing off in the selected circle: the circle's
/// people are still listed, but they cannot see you there.
class _CircleSharingPausedBanner extends StatelessWidget {
  const _CircleSharingPausedBanner({
    required this.circleName,
    required this.onResume,
  });

  final String circleName;
  final VoidCallback? onResume;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: 'Sharing paused for $circleName',
      child: Material(
        color: BrandTheme.of(context).sheet,
        elevation: 3,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpace.lg,
            vertical: AppSpace.sm,
          ),
          child: Row(
            children: <Widget>[
              const Icon(Icons.pause_circle_outline,
                  color: AppColors.statusOrange),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Text(
                  'Sharing paused. People in $circleName can\'t see where '
                  'you are.',
                  style: AppType.secondary.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              TextButton(onPressed: onResume, child: const Text('Resume')),
            ],
          ),
        ),
      ),
    );
  }
}

class _LocationOffBanner extends StatelessWidget {
  const _LocationOffBanner({required this.onEnable});

  final VoidCallback? onEnable;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: BrandTheme.of(context).sheet,
      elevation: 3,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpace.lg,
          vertical: AppSpace.sm,
        ),
        child: Row(
          children: <Widget>[
            const Icon(Icons.location_off, color: AppColors.statusOrange),
            const SizedBox(width: AppSpace.md),
            Expanded(
              child: Text(
                'Location sharing is off, so your family can\'t see where '
                'you are.',
                style: AppType.secondary.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            TextButton(onPressed: onEnable, child: const Text('Enable')),
          ],
        ),
      ),
    );
  }
}

class _RowMemo {
  const _RowMemo(this.member, this.paused, this.selected, this.widget);
  final Member member;
  final bool paused;
  final bool selected;
  final Widget widget;
}

/// Avatar with a small battery-level badge on its corner, as in Life360.
class _AvatarWithBattery extends StatelessWidget {
  const _AvatarWithBattery({required this.member});

  final Member member;

  @override
  Widget build(BuildContext context) {
    final int pct = member.batteryPercent;
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool charging = member.showsCharging;
    final bool low = pct > 0 && pct <= 20 && !charging;
    return SizedBox(
      width: 52,
      height: 52,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: <Widget>[
          StatusAvatar(member: member, size: 44),
          if (pct > 0)
            Positioned(
              bottom: -2,
              left: 0,
              child: ExcludeSemantics(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: cs.surface,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    border: Border.all(color: cs.outlineVariant),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(
                          charging
                              ? Icons.bolt
                              : low
                                  ? Icons.battery_alert_rounded
                                  : Icons.battery_full_rounded,
                          key: charging
                              ? const Key('person_row_charging')
                              : null,
                          size: 11,
                          color: charging
                              ? AppColors.statusGreen
                              : low
                                  ? AppColors.statusRed
                                  : cs.onSurface,
                        ),
                        const SizedBox(width: 2),
                        Text(
                          '$pct%',
                          style: AppType.secondary.copyWith(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: low ? AppColors.statusRed : cs.onSurface,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _PersonRow extends StatelessWidget {
  const _PersonRow({
    super.key,
    required this.member,
    required this.paused,
    required this.selected,
    required this.onTap,
  });

  final Member member;
  final bool paused;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    PerfMonitor.instance.countBuild('PersonRow');
    // A driving member's speed text follows the live fix; everyone else's
    // row has nothing live in it.
    if (member.movement != MovementType.car) return _row(context, null, null);
    return LiveSpeedBuilder(
      member: member,
      builder: (BuildContext ctx, double? mps, UnitSystem units) =>
          _row(ctx, mps, units),
    );
  }

  Widget _row(BuildContext context, double? mps, UnitSystem? units) {
    final String status = memberStatusLine(
      member,
      sharingPaused: paused,
      speedMps: mps,
      units: units ?? UnitSystem.imperial,
    );
    final String? battery = memberBatteryAlert(member);
    final String? updated = memberUpdatedLabel(member);
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Color wash = selected
        ? BrandTheme.of(context).accent.withValues(alpha: 0.09)
        : Colors.transparent;
    return ColoredBox(
      color: wash,
      child: Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        DsListRow(
          title: member.name,
          subtitle: status,
          selected: selected,
          wash: false,
          semanticLabel:
              '${member.name}. $status.${battery == null ? '' : ' $battery.'}${member.showsCharging ? ' Charging.' : ''}',
          leading: _AvatarWithBattery(member: member),
          onTap: onTap,
          trailing: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (battery != null)
                DsStatusChip(
                  label: battery,
                  icon: Icons.battery_alert,
                  color: AppColors.statusRed,
                ),
              if (updated != null)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpace.xs),
                  child: Text(
                    updated,
                    style: AppType.secondary.copyWith(
                      fontSize: 12,
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
    );
  }
}

/// Compact floating action: a small pill (icon + short label) used for the
/// map's Check in / Share / SOS shortcuts.
class _QuickAction extends StatelessWidget {
  const _QuickAction({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.danger = false,
    this.semanticLabel,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool danger;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final BrandTheme brand = BrandTheme.of(context);
    final Color bg = danger ? AppColors.sosRed : brand.sheet;
    final Color fg = danger ? Colors.white : brand.accentInk;
    return Semantics(
      button: true,
      label: semanticLabel ?? label,
      excludeSemantics: true,
      onTap: onPressed,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.pill),
          boxShadow: kFloatShadow,
        ),
        child: Material(
          color: bg,
          shape: const StadiumBorder(),
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: onPressed,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: kMinTarget),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(icon, size: 18, color: fg),
                    const SizedBox(width: 6),
                    Text(
                      label,
                      maxLines: 1,
                      style: AppType.body.copyWith(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: fg,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
