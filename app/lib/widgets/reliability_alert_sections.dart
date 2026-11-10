import 'package:flutter/material.dart';

import '../models/circle.dart';
import '../screens/security_widgets.dart' show errorText;
import '../services/api_client.dart';
import '../services/circle_service.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';

/// "Phone went silent" alerts. A circle admin picks how many quiet hours
/// trigger an alert (off by default); every member can snooze or switch off
/// alerts about their own phone. See backend/internal/handlers/silence.go.
class SilenceAlertsSection extends StatefulWidget {
  const SilenceAlertsSection({super.key});

  @override
  State<SilenceAlertsSection> createState() => _SilenceAlertsSectionState();
}

class _SilenceRow {
  _SilenceRow(this.circle, this.hours, this.disabled, this.snoozedUntil);
  final Circle circle;
  int hours;
  bool disabled;
  DateTime? snoozedUntil;
}

const List<int> _hourChoices = <int>[0, 4, 8, 12, 24, 48];

class _SilenceAlertsSectionState extends State<SilenceAlertsSection> {
  List<_SilenceRow>? _rows;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final List<Circle> circles = await CircleService.instance.listCircles();
      // One request per circle, all at once: the list used to wait for each in turn.
      final List<_SilenceRow> rows = await Future.wait(<Future<_SilenceRow>>[
        for (final Circle c in circles) _loadRow(c),
      ]);
      if (mounted) setState(() => _rows = rows);
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    }
  }

  static Future<_SilenceRow> _loadRow(Circle c) async {
    final dynamic j = await ApiClient.get('/circles/${c.id}/silence-alerts');
    final Map<String, dynamic> m = j as Map<String, dynamic>;
    return _SilenceRow(
      c,
      (m['hours'] as num?)?.toInt() ?? 0,
      m['disabled'] == true,
      DateTime.tryParse('${m['snoozed_until']}')?.toLocal(),
    );
  }

  Future<void> _put(String path, Map<String, Object?> body) async {
    try {
      await ApiClient.putJson(path, body: body);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Couldn't save: ${errorText(e)}")));
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Padding(padding: const EdgeInsets.all(AppSpace.lg), child: Text(_error!));
    }
    final List<_SilenceRow>? rows = _rows;
    if (rows == null || rows.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const DsSectionHeader('Silent phone alerts', trailing: InfoHint(
          title: 'Silent phone alerts',
          body: 'Tells circle admins, and the person themselves, when a phone has not '
              'reported for a long time during hours it normally does. Uses only '
              'when the phone last reported, never where it is, so it also works for Private circles. '
              'Off until an admin picks a time.',
        )),
        for (final _SilenceRow r in rows) ...<Widget>[
          if (r.circle.role == 'admin')
            ListTile(
              title: Text(r.circle.name),
              subtitle: const Text('Alert after a phone is quiet for'),
              trailing: DropdownButton<int>(
                value: _hourChoices.contains(r.hours) ? r.hours : 8,
                items: <DropdownMenuItem<int>>[
                  for (final int h in _hourChoices)
                    DropdownMenuItem<int>(value: h, child: Text(h == 0 ? 'Off' : '$h hours')),
                ],
                onChanged: (int? v) {
                  if (v == null) return;
                  setState(() => r.hours = v);
                  _put('/circles/${r.circle.id}/silence-alerts', <String, Object?>{'hours': v});
                },
              ),
            ),
          if (r.hours > 0 || r.circle.role == 'admin')
            DsToggleRow(
              icon: Icons.notifications_paused_outlined,
              title: 'Don\'t alert about my phone in ${r.circle.name}',
              subtitle: r.snoozedUntil != null && r.snoozedUntil!.isAfter(DateTime.now())
                  ? 'Snoozed until ${MaterialLocalizations.of(context).formatShortDate(r.snoozedUntil!)}'
                  : 'For a phone you often switch off',
              value: r.disabled,
              onChanged: (bool v) {
                setState(() => r.disabled = v);
                _put('/circles/${r.circle.id}/silence-alerts/me', <String, Object?>{'disabled': v, 'snooze_hours': 0});
              },
            ),
        ],
      ],
    );
  }
}

/// "Usually home by 4, not yet": opt-in per place, only for circles where the
/// server can see positions. Limits are documented in
/// backend/internal/handlers/arrival.go.
class ArrivalWatchSection extends StatefulWidget {
  const ArrivalWatchSection({super.key});

  @override
  State<ArrivalWatchSection> createState() => _ArrivalWatchSectionState();
}

class _ArrivalWatchSectionState extends State<ArrivalWatchSection> {
  List<Map<String, String>>? _places;
  Set<String> _watched = <String>{};
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  static String _tz() {
    final Duration o = DateTime.now().timeZoneOffset;
    final String sign = o.isNegative ? '-' : '+';
    final Duration a = o.abs();
    return 'UTC$sign${a.inHours.toString().padLeft(2, '0')}:${(a.inMinutes % 60).toString().padLeft(2, '0')}';
  }

  Future<void> _load() async {
    try {
      final Map<String, dynamic> j = await ApiClient.get('/me/arrival-watch') as Map<String, dynamic>;
      final List<dynamic> places = (j['places'] as List<dynamic>?) ?? <dynamic>[];
      final List<dynamic> watches = (j['watches'] as List<dynamic>?) ?? <dynamic>[];
      if (!mounted) return;
      setState(() {
        _places = <Map<String, String>>[
          for (final dynamic p in places)
            <String, String>{'id': '${(p as Map<String, dynamic>)['place_id']}', 'name': '${p['place_name']}'},
        ];
        _watched = <String>{for (final dynamic w in watches) '${(w as Map<String, dynamic>)['place_id']}'};
      });
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    }
  }

  Future<void> _set(String id, bool on) async {
    setState(() => on ? _watched.add(id) : _watched.remove(id));
    try {
      await ApiClient.putJson('/me/arrival-watch', body: <String, Object?>{'place_id': id, 'enabled': on, 'tz': _tz()});
    } catch (e) {
      if (!mounted) return;
      setState(() => on ? _watched.remove(id) : _watched.add(id));
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Couldn't save: ${errorText(e)}")));
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<Map<String, String>>? places = _places;
    if (_error != null || places == null || places.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const DsSectionHeader('Late-arrival alerts', trailing: InfoHint(
          title: 'Late-arrival alerts',
          body: 'Opt in per place to let your circle know when you are later than you usually are. '
              'It needs a few weeks of regular arrivals first, sends at most two alerts a day, '
              'and only works in circles where the server can see positions (not Private circles).',
        )),
        for (final Map<String, String> p in places)
          DsToggleRow(
            icon: Icons.schedule_outlined,
            title: p['name']!,
            subtitle: 'Alert if I am late here',
            value: _watched.contains(p['id']),
            onChanged: (bool v) => _set(p['id']!, v),
          ),
      ],
    );
  }
}
