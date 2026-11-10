import 'dart:async';

import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/notification_prefs_service.dart' show NotificationNames;
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';
import '../widgets/reliability_alert_sections.dart';
import 'place_alert_rules_screen.dart';
import 'security_widgets.dart';
import '../services/error_copy.dart';

/// Which notifications this person wants. SOS and help alerts from family are
/// not listed: they always come through.
class NotificationSettingsScreen extends StatefulWidget {
  const NotificationSettingsScreen({super.key});

  @override
  State<NotificationSettingsScreen> createState() =>
      _NotificationSettingsScreenState();
}

class _Pref {
  const _Pref(this.key, this.icon, this.title, this.subtitle, [this.info]);
  final String key;
  final IconData icon;
  final String title;
  final String subtitle;

  /// Longer explanation behind the (i) button.
  final String? info;
}

const List<_Pref> _places = <_Pref>[
  _Pref('place_alerts', Icons.place_outlined, 'Place alerts',
      'Arrivals and departures'),
  _Pref('check_in', Icons.check_circle_outline, 'Check-ins',
      'When someone checks in'),
];

const List<_Pref> _members = <_Pref>[
  _Pref('low_battery', Icons.battery_alert_outlined, 'Low battery',
      'A member\'s battery is low'),
  _Pref('completed_drives', Icons.directions_car_outlined, 'Completed drives',
      'A member finished a drive'),
  _Pref('safety_incidents', Icons.warning_amber_rounded, 'Safety incidents',
      'Crashes near your circle'),
  _Pref('weekly_summary', Icons.insights_outlined, 'Weekly driving summary',
      'Sunday evening',
      'Sunday evening: your circle\'s drives, distance and hard braking.'),
  _Pref('severe_weather', Icons.thunderstorm_outlined, 'Severe weather',
      'Alerts for your area'),
  _Pref('phone_silent', Icons.phonelink_erase_outlined, 'Silent phone alerts',
      'A member\'s phone went quiet'),
];

const _Pref _showNames = _Pref(
    'show_names',
    Icons.badge_outlined,
    'Show names in notifications',
    'Off: "A family member"',
    'Notifications say who arrived, left, drove, checked in or sent a chat '
        'message, for example "Henry arrived at Home". Names then pass '
        'through the push provider (Google, Apple or your ntfy server). '
        'Leave this off for maximum '
        'privacy: notifications say "A family member" instead.');

class _NotificationSettingsScreenState
    extends State<NotificationSettingsScreen> {
  Map<String, bool>? _prefs;
  String? _error;
  ErrorCopy? _loadCopy;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _loadCopy = null;
    });
    try {
      final dynamic d = await ApiClient.get('/me/notifications');
      if (!mounted) return;
      setState(() => _prefs = <String, bool>{
            for (final _Pref p in <_Pref>[..._places, ..._members])
              p.key: (d as Map<String, dynamic>)[p.key] != false,
            // Opt-in: off unless the server says it was switched on.
            _showNames.key: (d as Map<String, dynamic>)['show_names'] == true,
          });
      // The phone writes encrypted-chat notifications itself: keep its copy
      // of the choice in step with the server.
      unawaited(NotificationNames.remember(_prefs![_showNames.key] ?? false));
    } on SessionExpiredException {
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = errorText(e);
        _loadCopy = describeError(e);
      });
    }
  }

  Future<void> _set(String key, bool value) async {
    final Map<String, bool> before = Map<String, bool>.of(_prefs!);
    setState(() => _prefs![key] = value);
    try {
      await ApiClient.putJson('/me/notifications',
          body: <String, Object?>{key: value});
      if (key == _showNames.key) await NotificationNames.remember(value);
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
        info: p.info,
        value: _prefs![p.key] ?? (p.key != _showNames.key),
        onChanged: (bool v) => _set(p.key, v),
      );

  @override
  Widget build(BuildContext context) {
    final Map<String, bool>? prefs = _prefs;
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: prefs == null
          ? SafeArea(
              child: LoadStateView(
                error: _error,
                offline: _loadCopy?.connection ?? false,
                title: _loadCopy?.title,
                onRetry: _load,
              ),
            )
          // The whole page is built at once (about 15 rows). A lazy list
          // threw the sections away when they scrolled out of view, and each
          // one fetched itself again and popped in on the way back.
          : DsBody(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    const DsSectionHeader('Places & check-ins'),
                    for (final _Pref p in _places) _row(p),
                    const QuietHoursSection(),
                    const DsSectionHeader('Member notifications'),
                    for (final _Pref p in _members) _row(p),
                    const _Reveal(child: SilenceAlertsSection()),
                    const _Reveal(child: ArrivalWatchSection()),
                    const DsSectionHeader('Privacy'),
                    _row(_showNames),
                    Padding(
                      padding: const EdgeInsets.all(AppSpace.lg),
                      child: Text(
                        'SOS and help alerts always come through.',
                        style: AppType.secondary.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

/// Lets a section that only appears once its data is loaded (and only when
/// there is something to show) grow in smoothly instead of jumping in.
class _Reveal extends StatelessWidget {
  const _Reveal({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedSize(
        duration: const Duration(milliseconds: 150),
        alignment: Alignment.topCenter,
        child: child,
      );
}
