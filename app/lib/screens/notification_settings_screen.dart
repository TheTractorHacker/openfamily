import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/security_format.dart';
import '../widgets/ds/ds.dart';
import 'security_widgets.dart';

/// Which notifications this person wants. SOS and help alerts from family are
/// not listed: they always come through.
class NotificationSettingsScreen extends StatefulWidget {
  const NotificationSettingsScreen({super.key});

  @override
  State<NotificationSettingsScreen> createState() =>
      _NotificationSettingsScreenState();
}

class _Pref {
  const _Pref(this.key, this.icon, this.title, this.subtitle);
  final String key;
  final IconData icon;
  final String title;
  final String subtitle;
}

const List<_Pref> _places = <_Pref>[
  _Pref('place_alerts', Icons.place_outlined, 'Place alerts',
      'When someone arrives at or leaves a saved place'),
  _Pref('check_in', Icons.check_circle_outline, 'Check-ins',
      'When someone in your circle checks in'),
];

const List<_Pref> _members = <_Pref>[
  _Pref('low_battery', Icons.battery_alert_outlined, 'Low battery',
      "When a circle member's battery is low"),
  _Pref('completed_drives', Icons.directions_car_outlined, 'Completed drives',
      'When a circle member completes a drive'),
  _Pref('safety_incidents', Icons.warning_amber_rounded, 'Safety incidents',
      'Crashes and other incidents near your circle'),
  _Pref('severe_weather', Icons.thunderstorm_outlined, 'Severe weather alerts',
      'Severe weather in your area'),
];

class _NotificationSettingsScreenState
    extends State<NotificationSettingsScreen> {
  Map<String, bool>? _prefs;
  String? _error;
  bool _offline = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _offline = false;
    });
    try {
      final dynamic d = await ApiClient.get('/me/notifications');
      if (!mounted) return;
      setState(() => _prefs = <String, bool>{
            for (final _Pref p in <_Pref>[..._places, ..._members])
              p.key: (d as Map<String, dynamic>)[p.key] != false,
          });
    } on SessionExpiredException {
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = errorText(e);
        _offline = isOfflineError(e);
      });
    }
  }

  Future<void> _set(String key, bool value) async {
    final Map<String, bool> before = Map<String, bool>.of(_prefs!);
    setState(() => _prefs![key] = value);
    try {
      await ApiClient.putJson('/me/notifications',
          body: <String, Object?>{key: value});
    } on SessionExpiredException {
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() => _prefs = before);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Couldn't save: ${errorText(e)}")),
      );
    }
  }

  Widget _row(_Pref p) => DsToggleRow(
        icon: p.icon,
        title: p.title,
        subtitle: p.subtitle,
        value: _prefs![p.key] ?? true,
        onChanged: (bool v) => _set(p.key, v),
      );

  @override
  Widget build(BuildContext context) {
    final Map<String, bool>? prefs = _prefs;
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: SafeArea(
        child: prefs == null
            ? LoadStateView(error: _error, offline: _offline, onRetry: _load)
            : ListView(
                children: <Widget>[
                  const DsSectionHeader('Places & check-ins'),
                  for (final _Pref p in _places) _row(p),
                  const DsSectionHeader('Member notifications'),
                  for (final _Pref p in _members) _row(p),
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'SOS and help alerts from your family always come '
                      'through, whatever you choose here. Low battery, '
                      'drives, safety incidents and weather are saved now and '
                      'apply as the server starts sending them.',
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
