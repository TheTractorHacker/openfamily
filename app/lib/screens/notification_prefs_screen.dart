import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/notification_prefs_service.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';
import 'security_widgets.dart';

/// Which alerts the signed-in user receives about one member. SOS alerts are
/// always delivered and cannot be switched off here.
class NotificationPrefsScreen extends StatefulWidget {
  const NotificationPrefsScreen({
    super.key,
    required this.memberId,
    required this.memberName,
    this.service = const ApiNotificationPrefsService(),
  });

  final String memberId;
  final String memberName;
  final NotificationPrefsService service;

  @override
  State<NotificationPrefsScreen> createState() =>
      _NotificationPrefsScreenState();
}

class _NotificationPrefsScreenState extends State<NotificationPrefsScreen> {
  NotificationPrefs? _prefs;
  String? _loadError;
  String? _saveError;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loadError = null);
    try {
      final NotificationPrefs p = await widget.service.load(widget.memberId);
      if (mounted) setState(() => _prefs = p);
    } catch (e) {
      if (mounted) setState(() => _loadError = errorText(e));
    }
  }

  /// Applies [next] optimistically, saves it, and rolls back on failure.
  Future<void> _apply(NotificationPrefs next) async {
    final NotificationPrefs? before = _prefs;
    setState(() {
      _prefs = next;
      _saving = true;
      _saveError = null;
    });
    try {
      final NotificationPrefs saved =
          await widget.service.save(widget.memberId, next);
      if (mounted) setState(() => _prefs = saved);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _prefs = before;
        _saveError = e is ApiException &&
                e.status != 0 &&
                e.status < 500 &&
                e.status != 429
            ? e.message
            : errorText(e);
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pickTime(bool start) async {
    final NotificationPrefs p = _prefs!;
    final String? cur = start ? p.quietStart : p.quietEnd;
    final TimeOfDay? t = await showTimePicker(
      context: context,
      initialTime: _parse(cur) ?? TimeOfDay(hour: start ? 22 : 7, minute: 0),
    );
    if (t == null) return;
    final String v = _fmt(t);
    final String other = (start ? p.quietEnd : p.quietStart) ?? (start ? '07:00' : '22:00');
    if (v == other) {
      setState(() => _saveError = 'Quiet hours need different start and end times.');
      return;
    }
    await _apply(p.copyWith(
      quietStart: start ? v : other,
      quietEnd: start ? other : v,
    ));
  }

  static TimeOfDay? _parse(String? s) {
    if (s == null) return null;
    final List<String> p = s.split(':');
    if (p.length != 2) return null;
    return TimeOfDay(hour: int.parse(p[0]), minute: int.parse(p[1]));
  }

  static String _fmt(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final NotificationPrefs? p = _prefs;
    final String name = widget.memberName;
    return SecurityPage(
      title: 'Notifications',
      heading: 'Alerts about $name',
      subtitle: 'Choose what you are told about $name. This only affects '
          'your own phone.',
      children: <Widget>[
        if (p == null)
          LoadStateView(error: _loadError, onRetry: _load)
        else ...<Widget>[
          DsRowGroup(children: <Widget>[
            DsToggleRow(
              title: 'Mute all except SOS',
              subtitle: 'Silence everything below for $name',
              icon: Icons.notifications_off_outlined,
              value: p.muted,
              onChanged: _saving ? null : (v) => _apply(p.copyWith(muted: v)),
            ),
          ]),
          const SizedBox(height: AppSpace.lg),
          DsRowGroup(children: <Widget>[
            DsToggleRow(
              title: 'Arrivals',
              subtitle: 'When $name arrives at a place',
              icon: Icons.login_rounded,
              value: p.arrivals,
              onChanged: _saving || p.muted
                  ? null
                  : (v) => _apply(p.copyWith(arrivals: v)),
            ),
            DsToggleRow(
              title: 'Departures',
              subtitle: 'When $name leaves a place',
              icon: Icons.logout_rounded,
              value: p.departures,
              onChanged: _saving || p.muted
                  ? null
                  : (v) => _apply(p.copyWith(departures: v)),
            ),
            DsToggleRow(
              title: 'Low battery',
              subtitle: "When $name's phone battery is low",
              icon: Icons.battery_alert_outlined,
              value: p.lowBattery,
              onChanged: _saving || p.muted
                  ? null
                  : (v) => _apply(p.copyWith(lowBattery: v)),
            ),
            DsToggleRow(
              title: 'Driving and speeding',
              subtitle: 'Fast driving or hard events while $name drives',
              icon: Icons.directions_car_outlined,
              value: p.driving,
              onChanged: _saving || p.muted
                  ? null
                  : (v) => _apply(p.copyWith(driving: v)),
            ),
          ]),
          const SizedBox(height: AppSpace.lg),
          DsRowGroup(children: <Widget>[
            DsToggleRow(
              title: 'Quiet hours',
              subtitle: p.hasQuietHours
                  ? '${p.quietStart} to ${p.quietEnd}, no alerts except SOS'
                  : 'Pause these alerts during set hours',
              icon: Icons.bedtime_outlined,
              value: p.hasQuietHours,
              onChanged: _saving || p.muted
                  ? null
                  : (v) => _apply(v
                      ? p.copyWith(quietStart: '22:00', quietEnd: '07:00')
                      : p.copyWith(clearQuiet: true)),
            ),
            if (p.hasQuietHours) ...<Widget>[
              DsListRow(
                leading: DsListRow.iconTile(context, Icons.nights_stay_outlined),
                title: 'From',
                subtitle: p.quietStart,
                chevron: true,
                semanticLabel: 'Quiet hours start, ${p.quietStart}',
                onTap: _saving ? null : () => _pickTime(true),
              ),
              DsListRow(
                leading: DsListRow.iconTile(context, Icons.wb_sunny_outlined),
                title: 'Until',
                subtitle: p.quietEnd,
                chevron: true,
                semanticLabel: 'Quiet hours end, ${p.quietEnd}',
                onTap: _saving ? null : () => _pickTime(false),
              ),
            ],
          ]),
          const SizedBox(height: AppSpace.lg),
          const Callout(
            icon: Icons.sos_rounded,
            text: 'SOS alerts are always delivered, whatever you choose here.',
          ),
          if (_saveError != null) ErrorText(_saveError!),
        ],
      ],
    );
  }
}

/// Row on a member profile that opens [NotificationPrefsScreen].
class NotificationPrefsEntryButton extends StatelessWidget {
  const NotificationPrefsEntryButton({
    super.key,
    required this.memberId,
    required this.memberName,
  });

  final String memberId;
  final String memberName;

  @override
  Widget build(BuildContext context) {
    return DsListRow(
      leading: DsListRow.iconTile(context, Icons.notifications_outlined),
      title: 'Notifications',
      subtitle: 'Choose which alerts you get about $memberName',
      chevron: true,
      semanticLabel: 'Notification settings for $memberName',
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => NotificationPrefsScreen(
            memberId: memberId,
            memberName: memberName,
          ),
        ),
      ),
    );
  }
}
