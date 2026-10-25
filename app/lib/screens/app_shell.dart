import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/member.dart';
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
    setState(() {
      _tab = t;
      _visited.add(t);
    });
  }

  Widget _body(AppTab t) {
    if (!_visited.contains(t)) return const SizedBox.shrink();
    final WidgetBuilder? override = widget.tabBuilders?[t];
    if (override != null) return Builder(builder: override);
    switch (t) {
      case AppTab.location:
        return MapScreen(membersSink: _members, userIdSink: _userId);
      case AppTab.driving:
        return DrivingTabScreen(members: _members, userId: _userId);
      case AppTab.safety:
        return const SafetyHubScreen();
      case AppTab.circle:
        return CircleTabScreen(members: _members, userId: _userId);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _tab == AppTab.location,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (!didPop) _select(AppTab.location);
      },
      child: Scaffold(
        body: IndexedStack(
          index: _tab.index,
          children: <Widget>[
            for (final AppTab t in AppTab.values)
              // Hidden tabs must not take focus or announce to screen readers.
              ExcludeSemantics(
                excluding: t != _tab,
                child: TickerMode(enabled: t == _tab, child: _body(t)),
              ),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab.index,
          onDestinationSelected: (int i) => _select(AppTab.values[i]),
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          destinations: <Widget>[
            _dest(Icons.place_outlined, Icons.place, 'Location'),
            _dest(
              Icons.directions_car_outlined,
              Icons.directions_car,
              'Driving',
            ),
            _dest(Icons.shield_outlined, Icons.shield, 'Safety'),
            _dest(Icons.groups_outlined, Icons.groups, 'Circle'),
          ],
        ),
      ),
    );
  }

  NavigationDestination _dest(IconData icon, IconData selected, String label) {
    return NavigationDestination(
      icon: Icon(icon),
      selectedIcon: Icon(selected, color: BrandTheme.of(context).accentInk),
      label: label,
    );
  }
}
