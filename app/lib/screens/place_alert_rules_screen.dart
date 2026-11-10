import 'package:flutter/material.dart';

import '../models/place.dart';
import '../services/place_alert_rules_service.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';
import 'security_widgets.dart';

/// Per-place choice of which of one member's place alerts you get.
class PlaceAlertRulesScreen extends StatefulWidget {
  const PlaceAlertRulesScreen({
    super.key,
    required this.memberId,
    required this.memberName,
    this.service = const ApiPlaceAlertRulesService(),
  });

  final String memberId;
  final String memberName;
  final PlaceAlertRulesService service;

  @override
  State<PlaceAlertRulesScreen> createState() => _PlaceAlertRulesScreenState();
}

class _PlaceAlertRulesScreenState extends State<PlaceAlertRulesScreen> {
  List<Place>? _places;
  Map<String, PlaceAlertMode> _rules = <String, PlaceAlertMode>{};
  String? _loadError;
  String? _saveError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loadError = null);
    try {
      final List<Place> places = await widget.service.places();
      final Map<String, PlaceAlertMode> rules =
          await widget.service.rules(widget.memberId);
      if (mounted) {
        setState(() {
          _places = places;
          _rules = rules;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loadError = errorText(e));
    }
  }

  Future<void> _set(Place p, PlaceAlertMode mode) async {
    final PlaceAlertMode before = _rules[p.id] ?? PlaceAlertMode.both;
    setState(() {
      _rules = <String, PlaceAlertMode>{..._rules, p.id: mode};
      _saveError = null;
    });
    try {
      await widget.service.setRule(widget.memberId, p.id, mode);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _rules = <String, PlaceAlertMode>{..._rules, p.id: before};
        _saveError = errorText(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<Place>? places = _places;
    return SecurityPage(
      title: 'Place alerts',
      heading: 'Places for ${widget.memberName}',
      subtitle: 'Choose which alerts you get for each place. Places you do '
          'not change keep sending both.',
      children: <Widget>[
        if (places == null)
          LoadStateView(error: _loadError, onRetry: _load)
        else if (places.isEmpty)
          const Callout(
              icon: Icons.place_outlined, text: 'There are no places yet.')
        else
          DsRowGroup(children: <Widget>[
            for (final Place p in places)
              DsListRow(
                leading: DsListRow.iconTile(context, p.icon),
                title: p.name,
                trailing: DropdownButton<PlaceAlertMode>(
                  key: ValueKey<String>('rule-${p.id}'),
                  value: _rules[p.id] ?? PlaceAlertMode.both,
                  underline: const SizedBox.shrink(),
                  isExpanded: true,
                  onChanged: (PlaceAlertMode? m) {
                    if (m != null) _set(p, m);
                  },
                  items: <DropdownMenuItem<PlaceAlertMode>>[
                    for (final PlaceAlertMode m in PlaceAlertMode.values)
                      DropdownMenuItem<PlaceAlertMode>(
                          value: m,
                          child: Text(m.label,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.end)),
                  ],
                ),
              ),
          ]),
        if (_saveError != null) ErrorText(_saveError!),
      ],
    );
  }
}

/// Quiet hours for place alerts: a toggle plus start and end times.
class QuietHoursSection extends StatefulWidget {
  const QuietHoursSection({
    super.key,
    this.service = const ApiPlaceAlertRulesService(),
  });

  final PlaceAlertRulesService service;

  @override
  State<QuietHoursSection> createState() => _QuietHoursSectionState();
}

class _QuietHoursSectionState extends State<QuietHoursSection> {
  QuietHours? _q;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Loads the saved quiet hours. The row is on screen from the first frame
  /// (see [build]), so its height never changes when the answer arrives.
  void _load() {
    if (_error != null) setState(() => _error = null);
    widget.service.quietHours().then((QuietHours q) {
      if (mounted) setState(() => _q = q);
    }).catchError((Object e) {
      if (mounted) setState(() => _error = errorText(e));
    });
  }

  Future<void> _save(QuietHours next) async {
    final QuietHours? before = _q;
    setState(() {
      _q = next;
      _error = null;
    });
    try {
      final QuietHours saved = await widget.service.saveQuietHours(next);
      if (mounted) setState(() => _q = saved);
    } catch (e) {
      if (mounted) {
        setState(() {
          _q = before;
          _error = errorText(e);
        });
      }
    }
  }

  Future<void> _pick(bool start) async {
    final QuietHours q = _q!;
    final String? cur = start ? q.start : q.end;
    final List<String> parts = (cur ?? (start ? '22:00' : '07:00')).split(':');
    final TimeOfDay? t = await showTimePicker(
      context: context,
      initialTime:
          TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1])),
    );
    if (t == null) return;
    final String v =
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    final String other = (start ? q.end : q.start)!;
    if (v == other) {
      setState(() => _error = 'Quiet hours need different start and end times.');
      return;
    }
    await _save(QuietHours(start: start ? v : other, end: start ? other : v));
  }

  @override
  Widget build(BuildContext context) {
    final QuietHours? q = _q;
    // One layout for "loading", "failed" and "loaded": the row is on screen
    // from the first frame and keeps its height when the answer arrives.
    return Column(children: <Widget>[
      DsToggleRow(
        key: q == null ? const Key('quiet-hours-placeholder') : null,
        icon: Icons.bedtime_outlined,
        title: 'Quiet hours',
        subtitle: q == null
            // While loading it reads like the loaded "off" row (same words, so
            // the same height in any font), with the switch disabled.
            ? (_error == null ? 'Pause place alerts at night' : 'Could not load')
            : q.enabled
                ? 'Silent ${q.start} to ${q.end}'
                : 'Pause place alerts at night',
        value: q?.enabled ?? false,
        onChanged: q == null
            ? null
            : (bool v) => _save(v ? const QuietHours(start: '22:00', end: '07:00') : const QuietHours()),
      ),
      AnimatedSize(
        duration: const Duration(milliseconds: 150),
        alignment: Alignment.topCenter,
        child: Column(children: <Widget>[
          if (q != null && q.enabled) ...<Widget>[
            DsListRow(
              leading: DsListRow.iconTile(context, Icons.nights_stay_outlined),
              title: 'From',
              subtitle: q.start,
              chevron: true,
              onTap: () => _pick(true),
            ),
            DsListRow(
              leading: DsListRow.iconTile(context, Icons.wb_sunny_outlined),
              title: 'Until',
              subtitle: q.end,
              chevron: true,
              onTap: () => _pick(false),
            ),
          ],
        ]),
      ),
      if (_error != null) ErrorText(_error!),
      if (q == null && _error != null)
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
            child: TextButton(onPressed: _load, child: const Text('Try again')),
          ),
        ),
    ]);
  }
}
