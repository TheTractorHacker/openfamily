import 'package:flutter/material.dart';

import '../models/circle.dart';
import '../services/e2ee/new_circle_setup.dart';
import '../services/e2ee/processing_controller.dart';
import '../services/circle_service.dart';
import '../theme/app_theme.dart';
import '../widgets/circle_mode_picker.dart';
import '../widgets/circle_widgets.dart';
import '../widgets/ds/ds.dart';

/// Lifetimes offered for a temporary circle, in hours.
const Map<String, int> kTempCircleDurations = <String, int>{
  '24 hours': 24,
  '3 days': 72,
  '1 week': 168,
};

/// Creates an additional circle via `POST /circles` (name + icon). Pops with
/// the created [Circle].
class CircleCreateScreen extends StatefulWidget {
  const CircleCreateScreen({super.key, this.service, this.setup, this.makePrivate});

  final CircleService? service;

  /// Server checks and the server switch-on (tests inject one over a fake controller). Without it, and with an
  /// injected [service] (tests), no Private setup runs at all.
  final NewCircleSetup? setup;

  /// Makes the new circle Private (default: this phone's E2EE service).
  final Future<void> Function(String circleId)? makePrivate;

  @override
  State<CircleCreateScreen> createState() => _CircleCreateScreenState();
}

class _CircleCreateScreenState extends State<CircleCreateScreen> {
  final TextEditingController _name = TextEditingController();
  String? _icon = kCircleIcons.first;
  String? _error;
  bool _busy = false;
  bool _temporary = false;

  /// Section 24: "Private, with your server" is the default when the server can take part; otherwise Normal.
  NewCircleMode _mode = NewCircleMode.normal;
  bool _modeTouched = false;
  bool _serverAvailable = false;
  bool _requireServer = true; // default ON for a new Private circle with the server; the owner can switch it off here or later

  /// Lifetime of a temporary circle in hours (24h / 3 days / 1 week / custom).
  int _hours = 24;
  bool _custom = false;

  CircleService get _service => widget.service ?? CircleService.instance;

  /// Null in widget tests that inject only a fake circle service: no E2EE setup runs there.
  NewCircleSetup? get _setup =>
      widget.setup ?? (widget.service == null ? NewCircleSetup(LanesProcessingController.instance) : null);

  @override
  void initState() {
    super.initState();
    _probeServer();
  }

  Future<void> _probeServer() async {
    bool ok = false;
    try {
      final NewCircleSetup? setup = _setup;
      if (setup == null) return;
      ok = await setup.serverAvailable();
    } catch (_) {
      // no E2EE runtime here (or offline): Normal stays the default
    }
    if (!mounted) return;
    setState(() {
      _serverAvailable = ok;
      if (ok && !_modeTouched) _mode = NewCircleMode.privateServer;
      if (!ok && _mode == NewCircleMode.privateServer) _mode = NewCircleMode.normal;
    });
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final String name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Give your circle a name');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final Circle c = await _service.createCircle(name, _icon,
          durationHours: _temporary ? _hours : null);
      Circle result = c;
      final NewCircleSetup? setup = _setup;
      if (!mounted) return;
      if (_mode != NewCircleMode.normal && setup != null) {
        final NewCircleResult r = await finishNewCircle(context,
            circle: c,
            mode: _mode,
            requireServer: _requireServer,
            makePrivate: widget.makePrivate ?? makeCirclePrivate,
            setup: setup);
        if (r.isPrivate) result = c.copyWith(e2eeMode: 'private', serverAssist: r.serverOn, myLaneServer: r.serverOn);
      }
      if (mounted) Navigator.of(context).pop(result);
    } on SessionExpiredException {
      rethrow;
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = describeCircleError(e).message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return DsPage(
      title: 'New circle',
      actions: <Widget>[
        DsBusyButton(label: 'Create circle', busy: _busy, onPressed: _create),
      ],
      children: <Widget>[
        const DsHeading(
          'Name your circle',
          subtitle: 'A circle is a group you choose to share your location '
              'with. You can make as many as you like.',
        ),
        TextField(
          controller: _name,
          autofocus: true,
          maxLength: 100,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(
            labelText: 'Circle name',
            hintText: 'Friends, Soccer team, Grandparents',
            errorText: _error,
          ),
          onSubmitted: (_) => _create(),
        ),
        const SizedBox(height: AppSpace.lg),
        const DsSectionHeader(
          'Icon',
          padding: EdgeInsets.only(bottom: AppSpace.sm),
        ),
        Wrap(
          spacing: AppSpace.sm,
          runSpacing: AppSpace.sm,
          children: <Widget>[
            for (final String icon in kCircleIcons)
              Semantics(
                button: true,
                selected: icon == _icon,
                label: 'Icon $icon',
                child: ChoiceChip(
                  showCheckmark: icon == _icon,
                  materialTapTargetSize: MaterialTapTargetSize.padded,
                  label: SizedBox(
                    width: 32,
                    height: 32,
                    child: Center(
                      child: Text(icon, style: const TextStyle(fontSize: 22)),
                    ),
                  ),
                  selected: icon == _icon,
                  onSelected:
                      _busy ? null : (_) => setState(() => _icon = icon),
                ),
              ),
          ],
        ),
        const SizedBox(height: AppSpace.lg),
        CircleModePicker(
          mode: _mode,
          serverAvailable: _serverAvailable,
          requireServer: _requireServer,
          enabled: !_busy,
          onMode: (NewCircleMode m) => setState(() {
            _mode = m;
            _modeTouched = true;
          }),
          onRequireServer: (bool v) => setState(() => _requireServer = v),
        ),
        const SizedBox(height: AppSpace.lg),
        DsRowGroup(
          children: <Widget>[
            DsToggleRow(
              icon: Icons.timer_outlined,
              title: 'Temporary',
              subtitle: _temporary
                  ? 'Members see each other only until it ends.'
                  : 'For a road trip or event. Sharing stops on its own.',
              value: _temporary,
              onChanged: _busy ? null : (bool v) => setState(() => _temporary = v),
            ),
          ],
        ),
        if (_temporary) ...<Widget>[
          const SizedBox(height: AppSpace.lg),
          const DsSectionHeader(
            'Lasts for',
            padding: EdgeInsets.only(bottom: AppSpace.sm),
          ),
          Wrap(
            spacing: AppSpace.sm,
            runSpacing: AppSpace.sm,
            children: <Widget>[
              for (final MapEntry<String, int> p in kTempCircleDurations.entries)
                ChoiceChip(
                  materialTapTargetSize: MaterialTapTargetSize.padded,
                  label: Text(p.key),
                  selected: !_custom && _hours == p.value,
                  onSelected: _busy
                      ? null
                      : (_) => setState(() {
                            _custom = false;
                            _hours = p.value;
                          }),
                ),
              ChoiceChip(
                materialTapTargetSize: MaterialTapTargetSize.padded,
                label: const Text('Custom'),
                selected: _custom,
                onSelected: _busy
                    ? null
                    : (_) => setState(() {
                          _custom = true;
                          if (_hours % 24 != 0) _hours = 24;
                        }),
              ),
            ],
          ),
          if (_custom) ...<Widget>[
            const SizedBox(height: AppSpace.md),
            Semantics(
              label: 'Custom length in days',
              child: Slider(
                min: 1,
                max: 30,
                divisions: 29,
                value: (_hours / 24).clamp(1, 30).toDouble(),
                label: '${_hours ~/ 24} days',
                onChanged: _busy
                    ? null
                    : (double v) => setState(() => _hours = v.round() * 24),
              ),
            ),
            Text('${_hours ~/ 24} ${_hours ~/ 24 == 1 ? 'day' : 'days'} (up to 30)',
                style: AppType.secondary),
          ],
        ],
      ],
    );
  }
}
