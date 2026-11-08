import 'package:flutter/material.dart';

import '../services/watch/watch_bridge.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';

/// Settings > Watch: connection state of a paired Wear OS watch and the two
/// switches that matter. Plain wording; the (i) explains what the watch sees.
class WatchSettingsScreen extends StatefulWidget {
  const WatchSettingsScreen({super.key, WatchBridge? bridge}) : _bridge = bridge;

  final WatchBridge? _bridge;

  @override
  State<WatchSettingsScreen> createState() => _WatchSettingsScreenState();
}

class _WatchSettingsScreenState extends State<WatchSettingsScreen> {
  WatchBridge get _b => widget._bridge ?? WatchBridge.instance;

  @override
  void initState() {
    super.initState();
    _b.refreshLink();
  }

  void _info() {
    showDialog<void>(
      context: context,
      builder: (BuildContext c) => AlertDialog(
        title: const Text('How the watch works'),
        content: const SingleChildScrollView(
          child: Text(
            'Your phone keeps your sign-in and your Private circle keys. It sends '
            'your watch a short summary: names, last places, battery, alerts. '
            'Nothing else is stored on the watch, and the watch never goes to the '
            'internet by itself.\n\n'
            'For a Private circle this summary is readable on the watch. It travels '
            'only between your phone and your watch, never to the server. If you do '
            'not want that, switch "Show Private circles" off.\n\n'
            'Buttons on the watch (SOS, I\'m OK, pause sharing) are carried out by '
            'this phone, so Orbitly must be running on it.',
          ),
        ),
        actions: <Widget>[TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close'))],
      ),
    );
  }

  String _state(WatchLinkStatus s) {
    if (!_b.enabled) return 'Off';
    if (!s.available) return 'Not available: this phone has no Google Play services';
    if (s.nodes == 0) return 'No watch connected';
    return s.names.isEmpty ? 'Connected' : 'Connected: ${s.names.join(', ')}';
  }

  @override
  Widget build(BuildContext context) {
    return DsPage(
      title: 'Watch',
      maxWidth: 640,
      appBarActions: <Widget>[IconButton(tooltip: 'About the watch', icon: const Icon(Icons.info_outline), onPressed: _info)],
      children: <Widget>[
        ValueListenableBuilder<WatchLinkStatus>(
          valueListenable: _b.link,
          builder: (BuildContext c, WatchLinkStatus s, Widget? _) => Column(
            children: <Widget>[
              DsListRow(
                leading: DsListRow.iconTile(c, Icons.watch_outlined),
                title: 'Wear OS watch',
                subtitle: _state(s),
              ),
              DsToggleRow(
                icon: Icons.sync_outlined,
                title: 'Send to my watch',
                subtitle: 'Shows your people and lets the watch send SOS and I\'m OK.',
                value: _b.enabled,
                onChanged: (bool v) async {
                  await _b.setEnabled(v);
                  if (mounted) setState(() {});
                },
              ),
              DsToggleRow(
                icon: Icons.lock_outline,
                title: 'Show Private circles',
                subtitle: 'When off, people from Private circles are left out on the watch.',
                value: _b.showPrivate,
                onChanged: _b.enabled
                    ? (bool v) async {
                        await _b.setShowPrivate(v);
                        if (mounted) setState(() {});
                      }
                    : null,
              ),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(AppSpace.xl, AppSpace.md, AppSpace.xl, AppSpace.md),
          child: Text(
            'Install Orbitly on your Wear OS watch (Galaxy Watch 4 or newer, Pixel Watch and others). '
            'Older Samsung watches with Tizen are not supported. Steps: Settings, Help in the docs, "Orbitly on your watch".',
            style: AppType.secondary,
          ),
        ),
      ],
    );
  }
}
