import 'package:flutter/material.dart';

import '../main.dart';
import '../services/api_client.dart';
import '../widgets/ds/ds.dart';
import 'add_locations_screen.dart';
import 'invite_screen.dart';

/// Onboarding step: optionally name your new family, then invite people.
///
/// Naming is optional — if the field is left blank the family is auto-named
/// "My Family" (the user can rename it later in Settings), so this step adds
/// no friction.
class CreateCircleScreen extends StatefulWidget {
  const CreateCircleScreen({super.key});

  @override
  State<CreateCircleScreen> createState() => _CreateCircleScreenState();
}

class _CreateCircleScreenState extends State<CreateCircleScreen> {
  final TextEditingController _name = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (_submitting) return;
    final String trimmed = _name.text.trim();
    final String name = trimmed.isEmpty ? 'My Family' : trimmed;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await ApiClient.createFamily(name);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = e.message;
      });
      return;
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = 'Could not create the family. Please try again.';
      });
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => InviteScreen(
          circleName: name,
          doneLabel: 'Continue',
          step: 5,
          onDone: () => navigatorKey.currentState?.pushReplacement(
            MaterialPageRoute<void>(
              builder: (_) => AddLocationsScreen(circleName: name, step: 6),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DsPage(
      title: 'Create a family',
      step: 4,
      totalSteps: 6,
      actions: <Widget>[
        DsBusyButton(
          label: 'Create family',
          busy: _submitting,
          onPressed: _create,
        ),
      ],
      children: <Widget>[
        const DsHeading(
          'Name your family',
          subtitle: 'Optional. This is the group your family will see on the '
              'map, like "Family" or "The Smiths". Leave it blank and we\'ll '
              'call it "My Family".',
        ),
        TextField(
          controller: _name,
          autofocus: true,
          enabled: !_submitting,
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _create(),
          decoration: const InputDecoration(
            labelText: 'Family name (optional)',
            hintText: 'My Family',
            prefixIcon: Icon(Icons.home_outlined),
          ),
        ),
        if (_error != null) DsMessage(_error!),
      ],
    );
  }
}
