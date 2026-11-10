import 'package:flutter/material.dart';

import '../main.dart';
import '../models/circle.dart';
import '../services/api_client.dart';
import '../services/e2ee/new_circle_setup.dart';
import '../services/e2ee/processing_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/circle_mode_picker.dart';
import '../widgets/ds/ds.dart';
import 'add_locations_screen.dart';
import 'invite_screen.dart';

/// Onboarding step: optionally name your new family, then invite people.
///
/// Naming is optional — if the field is left blank the family is auto-named
/// "My Family" (the user can rename it later in Settings), so this step adds
/// no friction.
///
/// Section 24 of docs/design/PRIVACY_PROCESSING.md: when the server can take part, the family starts as a Private
/// (end-to-end encrypted) circle with the server switched on, so everyone is on the server by default.
class CreateCircleScreen extends StatefulWidget {
  const CreateCircleScreen({super.key, this.setup, this.makePrivate, this.createFamily, this.onCreated});

  /// Tests inject these; the app uses the real E2EE runtime and API.
  final NewCircleSetup? setup;
  final Future<void> Function(String circleId)? makePrivate;
  final Future<Map<String, dynamic>> Function(String name)? createFamily;

  /// Replaces the navigation to the invite step (tests).
  final void Function(String name)? onCreated;

  @override
  State<CreateCircleScreen> createState() => _CreateCircleScreenState();
}

class _CreateCircleScreenState extends State<CreateCircleScreen> {
  final TextEditingController _name = TextEditingController();
  bool _submitting = false;
  String? _error;
  NewCircleMode _mode = NewCircleMode.normal;
  bool _modeTouched = false;
  bool _serverAvailable = false;
  bool _requireServer = true; // default ON for a new Private circle with the server; the owner can switch it off here or later

  NewCircleSetup? _setupOrNull() {
    try {
      return widget.setup ?? NewCircleSetup(LanesProcessingController.instance);
    } catch (_) {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    _probeServer();
  }

  Future<void> _probeServer() async {
    bool ok = false;
    try {
      final NewCircleSetup? s = _setupOrNull();
      if (s != null) ok = await s.serverAvailable();
    } catch (_) {}
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
    if (_submitting) return;
    final String trimmed = _name.text.trim();
    final String name = trimmed.isEmpty ? 'My Family' : trimmed;
    setState(() {
      _submitting = true;
      _error = null;
    });
    Map<String, dynamic> family;
    try {
      family = await (widget.createFamily ?? ApiClient.createFamily)(name);
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
    final String id = (family['id'] as String?) ?? '';
    final NewCircleSetup? setup = _setupOrNull();
    if (_mode != NewCircleMode.normal && id.isNotEmpty && setup != null) {
      await finishNewCircle(context,
          circle: Circle(id: id, name: name, role: 'admin', sharingEnabled: true, memberCount: 1, isPrimary: true),
          mode: _mode,
          requireServer: _requireServer,
          makePrivate: widget.makePrivate ?? makeCirclePrivate,
          setup: setup);
      if (!mounted) return;
    }
    final void Function(String)? done = widget.onCreated;
    if (done != null) {
      done(name);
      return;
    }
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
        const SizedBox(height: AppSpace.lg),
        CircleModePicker(
          mode: _mode,
          serverAvailable: _serverAvailable,
          requireServer: _requireServer,
          enabled: !_submitting,
          onMode: (NewCircleMode m) => setState(() {
            _mode = m;
            _modeTouched = true;
          }),
          onRequireServer: (bool v) => setState(() => _requireServer = v),
        ),
      ],
    );
  }
}
