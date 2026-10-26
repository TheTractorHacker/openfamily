import 'package:flutter/material.dart';

import '../models/circle.dart';
import '../services/circle_service.dart';
import '../theme/app_theme.dart';
import '../widgets/circle_widgets.dart';
import '../widgets/ds/ds.dart';

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
      final Circle c = await _service.createCircle(name, _icon);
      if (mounted) Navigator.of(context).pop(c);
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
        const DsSectionHeader('Icon'),
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
      ],
    );
  }
}
