import '../services/chat_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/member.dart';
import '../services/perf/perf_monitor.dart';
import '../theme/app_theme.dart';
import 'circle_tab_screen.dart';
import 'driving_tab_screen.dart';
import 'map_screen.dart';
import 'safety_hub_screen.dart';

/// The four top-level destinations.
enum AppTab { location, driving, safety, circle }

/// The main app scaffold: a bottom [NavigationBar] over four tabs.
///
/// * Tabs are built lazily on first visit and then kept alive (the map keeps
///   its camera, WebSocket and reporter while you look at another tab).
/// * Back from any other tab returns to Location first; back on Location
///   leaves the app as before.
/// * Anything that needs to switch tabs (a push notification route, the alert
///   router) calls [AppShell.requestTab]; screens pushed on the root
///   navigator (alert received, SOS...) simply cover the bar.
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    this.initialTab = AppTab.location,
    this.tabBuilders,
  });

  final AppTab initialTab;

  /// Replaces tab bodies; used by tests to avoid the live map.
  final Map<AppTab, WidgetBuilder>? tabBuilders;

  /// Deep-link hook: set to switch the visible shell tab. The shell resets it
  /// to null once handled. Safe to set before the shell exists; it is picked
  /// up on mount.
  static final ValueNotifier<AppTab?> requestedTab = ValueNotifier<AppTab?>(
    null,
  );

  static void requestTab(AppTab tab) => requestedTab.value = tab;

  /// Wide screens (tablet, foldable, any landscape) get a [NavigationRail]
  /// on the leading edge instead of the bottom bar, which would eat scarce
  /// landscape height.
  static bool useRail(Size size) =>
      size.width >= 840 || (size.width > size.height && size.width >= 560);

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  late AppTab _tab = widget.initialTab;
  late final Set<AppTab> _visited = <AppTab>{widget.initialTab};

  /// One roster shared by every tab, fed by the Location tab's subscription.
  final ValueNotifier<List<Member>> _members = ValueNotifier<List<Member>>(
    const <Member>[],
  );
  final ValueNotifier<String?> _userId = ValueNotifier<String?>(null);

  /// The circle selected on the map pill, shared with the Driving tab.
  final ValueNotifier<String?> _circleId = ValueNotifier<String?>(null);

  @override
  void initState() {
    super.initState();
    AppShell.requestedTab.addListener(_onRequested);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onRequested());
  }

  @override
  void dispose() {
    AppShell.requestedTab.removeListener(_onRequested);
    _members.dispose();
    _userId.dispose();
    _circleId.dispose();
    super.dispose();
  }

  void _onRequested() {
    final AppTab? t = AppShell.requestedTab.value;
    if (t == null || !mounted) return;
    AppShell.requestedTab.value = null;
    _select(t);
  }

  void _select(AppTab t) {
    if (t == _tab) return;
    HapticFeedback.selectionClick();
    PerfMonitor.instance.setShellTab(t.name);
    setState(() {
      _tab = t;
      _visited.add(t);
    });
  }

  /// Tab bodies, created once on first visit. Handing the framework the SAME
  /// widget instance on every shell rebuild (each tab switch is a setState)
  /// means switching tabs no longer rebuilds all visited tabs, map included.
  final Map<AppTab, Widget> _bodies = <AppTab, Widget>{};

  @override
  void didUpdateWidget(AppShell old) {
    super.didUpdateWidget(old);
    if (!identical(old.tabBuilders, widget.tabBuilders)) _bodies.clear();
  }

  Widget _body(AppTab t) {
    if (!_visited.contains(t)) return const SizedBox.shrink();
    return _bodies[t] ??= _createBody(t);
  }

  Widget _createBody(AppTab t) {
    final WidgetBuilder? override = widget.tabBuilders?[t];
    if (override != null) return Builder(builder: override);
    switch (t) {
      case AppTab.location:
        return MapScreen(
          membersSink: _members,
          userIdSink: _userId,
          circleIdSink: _circleId,
        );
      case AppTab.driving:
        return DrivingTabScreen(
          members: _members,
          userId: _userId,
          circleId: _circleId,
        );
      case AppTab.safety:
        return const SafetyHubScreen();
      case AppTab.circle:
        return CircleTabScreen(
          members: _members,
          userId: _userId,
          circleId: _circleId,
        );
    }
  }

  static const List<(IconData, IconData, String)> _items =
      <(IconData, IconData, String)>[
    (Icons.place_outlined, Icons.place, 'Location'),
    (Icons.directions_car_outlined, Icons.directions_car, 'Driving'),
    (Icons.shield_outlined, Icons.shield, 'Safety'),
    (Icons.groups_outlined, Icons.groups, 'Circle'),
  ];

  @override
  Widget build(BuildContext context) {
    final bool rail = AppShell.useRail(MediaQuery.sizeOf(context));
    final Widget stack = IndexedStack(
      index: _tab.index,
      children: <Widget>[
        for (final AppTab t in AppTab.values)
          // Hidden tabs must not take focus or announce to screen readers.
          ExcludeSemantics(
            excluding: t != _tab,
            child: TickerMode(enabled: t == _tab, child: _body(t)),
          ),
      ],
    );
    return PopScope(
      canPop: _tab == AppTab.location,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (!didPop) _select(AppTab.location);
      },
      child: Scaffold(
        body: rail
            ? Row(
                children: <Widget>[
                  // The rail keeps clear of the cutout and system bars; the
                  // body then no longer needs the leading inset.
                  ColoredBox(
                    color: BrandTheme.of(context).sheet,
                    child: SafeArea(
                    right: false,
                    child: NavigationRail(
                      selectedIndex: _tab.index,
                      onDestinationSelected: (int i) =>
                          _select(AppTab.values[i]),
                      labelType: NavigationRailLabelType.all,
                      destinations: <NavigationRailDestination>[
                        for (final (IconData, IconData, String) it in _items)
                          NavigationRailDestination(
                            icon: _badged(it.$3, Icon(it.$1)),
                            selectedIcon: _badged(
                              it.$3,
                              Icon(
                                it.$2,
                                color: BrandTheme.of(context).accentInk,
                              ),
                            ),
                            label: Text(it.$3),
                          ),
                      ],
                    ),
                  ),
                  ),
                  Expanded(
                    child: MediaQuery.removePadding(
                      context: context,
                      removeLeft: true,
                      child: stack,
                    ),
                  ),
                ],
              )
            : stack,
        bottomNavigationBar: rail
            ? null
            : NavigationBar(
                selectedIndex: _tab.index,
                onDestinationSelected: (int i) => _select(AppTab.values[i]),
                labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
                destinations: <Widget>[
                  for (final (IconData, IconData, String) it in _items)
                    _dest(it.$1, it.$2, it.$3),
                ],
              ),
      ),
    );
  }

  NavigationDestination _dest(IconData icon, IconData selected, String label) {
    return NavigationDestination(
      icon: _badged(label, Icon(icon)),
      selectedIcon: _badged(
        label,
        Icon(selected, color: BrandTheme.of(context).accentInk),
      ),
      label: label,
    );
  }

  /// The Circle tab carries the unread family-chat count.
  Widget _badged(String label, Widget icon) {
    if (label != 'Circle') return icon;
    return ValueListenableBuilder<int>(
      valueListenable: ChatEvents.unreadTotal,
      builder: (BuildContext context, int n, Widget? child) => Badge(
        isLabelVisible: n > 0,
        label: Text(n > 99 ? '99+' : '$n'),
        child: child,
      ),
      child: icon,
    );
  }
}
