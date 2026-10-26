import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../models/circle.dart';
import '../models/member.dart';
import '../models/place.dart';
import '../theme/app_theme.dart';
import '../utils/member_status.dart';
import '../services/perf/perf_monitor.dart';
import 'ds/ds.dart';
import 'member_avatar_bubble.dart';
import 'visible_value_builder.dart';

/// Loads saved places for the Places tab. Injected in tests.
typedef PlacesLoader = Future<List<Place>> Function();

/// Presentational "Location" tab: a full-bleed [map] with floating controls,
/// a circle-switcher pill and a draggable People / Places sheet.
///
/// The map is a black box supplied by the caller, and every action is a
/// callback, so this widget owns no services and can be rendered in tests.
class LocationTabView extends StatefulWidget {
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
    this.onCheckIn,
    this.onSos,
    this.onSelectMember,
    this.onOpenMember,
    this.onManageCircles,
    this.onOpenCircle,
    this.onJoinCircle,
    this.onOpenPlaces,
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
  final VoidCallback? onCheckIn;
  final VoidCallback? onSos;

  /// A person row was tapped: the map should center on them.
  final ValueChanged<Member>? onSelectMember;

  /// "Details" on the selected person: profile, history, location request.
  final ValueChanged<Member>? onOpenMember;
  final VoidCallback? onManageCircles;
  final ValueChanged<Circle>? onOpenCircle;
  final VoidCallback? onJoinCircle;
  final VoidCallback? onOpenPlaces;

  @override
  State<LocationTabView> createState() => _LocationTabViewState();
}

class _LocationTabViewState extends State<LocationTabView> {
  /// Sheet heights, as fractions of the tab body.
  static const double _peekPx = 236;
  static const double _half = 0.5;

  final DraggableScrollableController _sheet = DraggableScrollableController();
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

  void _select(Member m) {
    setState(() => _selectedId = _selectedId == m.id ? null : m.id);
    if (_selectedId != null) widget.onSelectMember?.call(m);
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
          final double textScale = MediaQuery.textScalerOf(
            context,
          ).scale(1).clamp(1.0, 2.0);
          final double peek = (minSize * textScale).clamp(minSize, 0.5);
          return Stack(
            children: <Widget>[
              Positioned.fill(child: widget.map),
              _buildTop(context),
              _buildFloating(context, h, peek),
              NotificationListener<DraggableScrollableNotification>(
                onNotification: (DraggableScrollableNotification n) {
                  _extent.value = n.extent;
                  return false;
                },
                child: DraggableScrollableSheet(
                  controller: _sheet,
                  initialChildSize: peek,
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
      box.maxWidth >= 720 ||
      (box.maxWidth > box.maxHeight * 1.2 && box.maxWidth >= 560);

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
              Positioned.fill(child: widget.map),
              _buildTop(context),
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
                  // A chat button would live here once the backend has chat.
                  DsMapButton(
                    icon: Icons.person_add_alt_1_outlined,
                    tooltip: 'Invite someone',
                    onPressed: widget.onInvite,
                  ),
                ],
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
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFloating(BuildContext context, double h, double peek) {
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
          bottom: extent * h + AppSpace.md,
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
    return Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Expanded(
                    child: Wrap(
                      spacing: AppSpace.sm,
                      runSpacing: AppSpace.sm,
                      children: <Widget>[
                        DsPillButton(
                          label: 'Check in',
                          icon: Icons.check_circle_outline,
                          floating: true,
                          onPressed: widget.onCheckIn,
                        ),
                        DsPillButton(
                          label: 'SOS',
                          icon: Icons.warning_amber_rounded,
                          style: DsPillStyle.danger,
                          floating: true,
                          onPressed: widget.onSos,
                          semanticLabel: 'Send an SOS to your family',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpace.sm),
                  Column(
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
    return CustomScrollView(
      controller: sc,
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: Column(
            children: <Widget>[
              if (handle) const DsDragHandle() else SizedBox(height: topInset),
              DsSegmentedTabs(
                labels: const <String>['People', 'Places'],
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
      onDetails: () => widget.onOpenMember?.call(m),
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
        child: DsListRow(
          title: 'Add a person',
          leading: DsListRow.iconTile(context, Icons.person_add_alt_1_outlined),
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
                message: 'Check your connection and try again.',
                onRetry: _reloadPlaces,
              );
            }
            final List<Place> places = snap.data ?? const <Place>[];
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
                        ? '${p.radiusMeters.round()} m radius'
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

class _PersonRow extends StatelessWidget {
  const _PersonRow({
    super.key,
    required this.member,
    required this.paused,
    required this.selected,
    required this.onTap,
    required this.onDetails,
  });

  final Member member;
  final bool paused;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDetails;

  @override
  Widget build(BuildContext context) {
    PerfMonitor.instance.countBuild('PersonRow');
    final String status = memberStatusLine(member, sharingPaused: paused);
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
              '${member.name}. $status.${battery == null ? '' : ' $battery.'}',
          leading: StatusAvatar(member: member, size: 44),
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
        if (selected)
          Padding(
            // Aligned under the name (xl gutter + 44 avatar + md gap), with
            // air above and below so it never touches the row.
            padding: const EdgeInsets.fromLTRB(
              AppSpace.xl + 44 + AppSpace.md,
              AppSpace.xs,
              AppSpace.xl,
              AppSpace.lg,
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: DsPillButton(
                label: 'Details and history',
                icon: Icons.history,
                style: DsPillStyle.outlined,
                onPressed: onDetails,
                semanticLabel: 'Open ${member.name}\'s details and history',
              ),
            ),
          ),
      ],
    ),
    );
  }
}
