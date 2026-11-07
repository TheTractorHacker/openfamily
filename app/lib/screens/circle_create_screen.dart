import 'package:flutter/material.dart';

import '../models/circle.dart';
import '../services/e2ee/e2ee_app.dart';
import '../services/e2ee/e2ee_service.dart';
import '../services/e2ee/private_runtime.dart';
import '../services/circle_service.dart';
import '../theme/app_theme.dart';
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
  const CircleCreateScreen({super.key, this.service});

  final CircleService? service;

  @override
  State<CircleCreateScreen> createState() => _CircleCreateScreenState();
}

class _CircleCreateScreenState extends State<CircleCreateScreen> {
  final TextEditingController _name = TextEditingController();
  String? _icon = kCircleIcons.first;
  String? _error;
  bool _busy = false;
  bool _temporary = false;

  /// Normal (server keeps locations) is the default; Private is a deliberate choice.
  bool _private = false;

  /// Lifetime of a temporary circle in hours (24h / 3 days / 1 week / custom).
  int _hours = 24;
  bool _custom = false;

  CircleService get _service => widget.service ?? CircleService.instance;

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
      if (_private && widget.service == null) {
        try {
          final E2eeService svc = E2eeApp.service;
          if (await svc.identity() == null) await svc.registerThisDevice(label: 'This phone');
          await svc.enableCircle(c.id);
          await PrivateRuntime.instance.setCircles(await _service.listCircles());
          result = c.copyWith(e2eeMode: 'private');
        } catch (_) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('The circle was created in normal mode. You can make it private later in the circle settings.')));
          }
        }
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

  Widget _modeTile({required Key key, required bool selected, required String title, required String body, required VoidCallback onTap}) {
    return Semantics(
      inMutuallyExclusiveGroup: true,
      selected: selected,
      child: ListTile(
        key: key,
        contentPadding: EdgeInsets.zero,
        leading: Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked),
        title: Text(title),
        subtitle: Text(body),
        onTap: _busy ? null : onTap,
      ),
    );
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
        const DsSectionHeader('Who can see locations', padding: EdgeInsets.only(bottom: AppSpace.sm)),
        _modeTile(
          key: const Key('mode-normal'),
          selected: !_private,
          title: 'Normal (recommended)',
          body: 'Your server keeps locations so maps, history and driving reports just work.',
          onTap: () => setState(() => _private = false),
        ),
        _modeTile(
          key: const Key('mode-private'),
          selected: _private,
          title: 'Private',
          body: 'Only phones can read locations; the server keeps nothing readable. No driving reports unless you turn on phone reports (uses more battery) or later let the server help.',
          onTap: () => setState(() => _private = true),
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
