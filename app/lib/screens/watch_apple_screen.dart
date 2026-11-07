import 'package:flutter/material.dart';

import '../services/watch/watch_bridge_ios.dart';
import '../widgets/ds/ds.dart';

/// Settings > Watch (iPhone): whether an Apple Watch is connected and the one
/// switch that controls what the watch may see. The Android phone shows the
/// matching Wear OS screen; both are reached from the same Settings row.
class WatchAppleScreen extends StatefulWidget {
  const WatchAppleScreen({super.key, WatchBridgeIos? bridge}) : _bridge = bridge;

  final WatchBridgeIos? _bridge;

  @override
  State<WatchAppleScreen> createState() => _WatchAppleScreenState();
}

class _WatchAppleScreenState extends State<WatchAppleScreen> {
  WatchBridgeIos get _b => widget._bridge ?? WatchBridgeIos.instance;
  WatchStatus _status = const WatchStatus();
  bool _enabled = true;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final bool enabled = await _b.isEnabled();
    final WatchStatus status = await _b.refreshStatus();
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _status = status;
      _loaded = true;
    });
  }

  String get _statusText {
    if (!_b.isSupported || !_status.supported) return 'Apple Watch is not available on this device.';
    if (!_status.paired) return 'No Apple Watch is paired with this iPhone.';
    if (!_status.appInstalled) {
      return 'Your Apple Watch is paired, but the Orbitly watch app is not on it yet. '
          'Open the Watch app on the iPhone and install Orbitly from the list.';
    }
    return _status.reachable
        ? 'Your Apple Watch is connected.'
        : 'Your Apple Watch has Orbitly. It updates when the watch is near the iPhone.';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Watch')),
      body: SafeArea(
        child: !_loaded
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                children: <Widget>[
                  ListTile(
                    leading: const Icon(Icons.watch_outlined),
                    title: const Text('Apple Watch'),
                    subtitle: Text(_statusText),
                  ),
                  DsToggleRow(
                    icon: Icons.family_restroom_outlined,
                    title: 'Show family on Apple Watch',
                    subtitle: 'Names, places and battery are sent to your watch. '
                        'Turning this off removes them from the watch.',
                    value: _enabled,
                    onChanged: (bool v) async {
                      setState(() => _enabled = v);
                      await _b.setEnabled(v);
                    },
                  ),
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'Your iPhone keeps your sign-in and your keys. The watch only '
                      'receives what it shows and asks the iPhone to send an SOS, '
                      'check in, pause sharing or send a quick reply. Nothing is '
                      'stored on the watch after you sign out.',
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
