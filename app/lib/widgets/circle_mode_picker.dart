import 'package:flutter/material.dart';

import '../models/circle.dart';
import '../screens/security_widgets.dart' show errorText;
import '../services/circle_service.dart';
import '../services/e2ee/e2ee_app.dart';
import '../services/e2ee/e2ee_service.dart';
import '../services/e2ee/lanes_service.dart' show LanesNotReady;
import '../services/e2ee/new_circle_setup.dart';
import '../services/e2ee/private_runtime.dart';
import '../theme/app_theme.dart';
import 'add_server_sheet.dart';
import 'ds/ds.dart';

// "Who can see locations" when a circle is created (docs/design/PRIVACY_PROCESSING.md section 24), shared by the
// onboarding step and the "New circle" screen. Text and layout here; decisions in [NewCircleSetup].

/// The three ways to set up a circle. [serverAvailable] shows the server option (and makes it the recommended one).
class CircleModePicker extends StatelessWidget {
  const CircleModePicker({
    super.key,
    required this.mode,
    required this.serverAvailable,
    required this.requireServer,
    required this.onMode,
    required this.onRequireServer,
    this.enabled = true,
  });

  final NewCircleMode mode;
  final bool serverAvailable;
  final bool requireServer;
  final ValueChanged<NewCircleMode> onMode;
  final ValueChanged<bool> onRequireServer;
  final bool enabled;

  Widget _tile({required Key key, required NewCircleMode value, required String title, required String body}) {
    final bool selected = mode == value;
    return Semantics(
      inMutuallyExclusiveGroup: true,
      selected: selected,
      child: ListTile(
        key: key,
        contentPadding: EdgeInsets.zero,
        leading: Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked),
        title: Text(title),
        subtitle: Text(body),
        onTap: enabled ? () => onMode(value) : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      const DsSectionHeader('Who can see locations', padding: EdgeInsets.only(bottom: AppSpace.sm)),
      if (serverAvailable)
        _tile(
          key: const Key('mode-private-server'),
          value: NewCircleMode.privateServer,
          title: 'Private, with your server (recommended)',
          body: 'End-to-end encrypted. Your server joins as its own device so maps, history and driving reports just work. '
              'Everyone is on the server by default and can switch it off for themselves.',
        ),
      if (serverAvailable && mode == NewCircleMode.privateServer)
        Padding(
          padding: const EdgeInsets.only(left: AppSpace.xl),
          child: CheckboxListTile(
            key: const Key('mode-require-server'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: requireServer,
            onChanged: enabled ? (bool? v) => onRequireServer(v ?? false) : null,
            title: const Text('Everyone must use the server'),
            subtitle: const Text('For example children\'s phones. Nobody in this circle can keep their data from the server; '
                'each member confirms it once on their own phone or leaves.'),
          ),
        ),
      _tile(
        key: const Key('mode-private'),
        value: NewCircleMode.privatePhones,
        title: 'Private, phones only',
        body: 'Only phones can read locations; the server keeps nothing readable. No driving reports unless you turn on '
            'phone reports (uses more battery)${serverAvailable ? '' : ' or later let the server help'}.',
      ),
      _tile(
        key: const Key('mode-normal'),
        value: NewCircleMode.normal,
        title: serverAvailable ? 'Normal, no end-to-end encryption' : 'Normal (recommended)',
        body: 'Your server keeps locations in readable form so maps, history and driving reports just work.',
      ),
    ]);
  }
}

/// Makes [circleId] Private from this phone (registering its key first if needed). The default for the screens.
Future<void> makeCirclePrivate(String circleId) async {
  final E2eeService svc = E2eeApp.service;
  if (await svc.identity() == null) await svc.registerThisDevice(label: 'This phone');
  await svc.enableCircle(circleId);
  await PrivateRuntime.instance.setCircles(await CircleService.instance.listCircles());
}

/// What [finishNewCircle] did, for the caller's result.
class NewCircleResult {
  const NewCircleResult({required this.isPrivate, required this.serverOn});
  final bool isPrivate;
  final bool serverOn;
}

/// After a circle was created: applies [mode]. Private modes make it Private; the server mode then switches the
/// server on (or opens the one-tap "Your server wants to join" sheet when this phone has to approve the server
/// first). Every outcome ends with a plain message; nothing is a dead end: a circle that could not get the server
/// yet shows "Let the server help" in the attention center and in its settings.
Future<NewCircleResult> finishNewCircle(
  BuildContext context, {
  required Circle circle,
  required NewCircleMode mode,
  required bool requireServer,
  required Future<void> Function(String circleId) makePrivate,
  required NewCircleSetup setup,
}) async {
  if (mode == NewCircleMode.normal) return const NewCircleResult(isPrivate: false, serverOn: false);
  final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
  void say(String m) => messenger?.showSnackBar(SnackBar(content: Text(m), duration: const Duration(seconds: 6)));
  try {
    await makePrivate(circle.id);
  } catch (_) {
    say('The circle was created in normal mode. You can make it private later in the circle settings.');
    return const NewCircleResult(isPrivate: false, serverOn: false);
  }
  if (mode == NewCircleMode.privatePhones) return const NewCircleResult(isPrivate: true, serverOn: false);
  NewCircleServerOutcome outcome;
  try {
    outcome = await setup.turnOn(circle.id, requireServer: requireServer);
  } on LanesNotReady catch (e) {
    say('The circle is private, but the server could not be switched on yet: ${e.names.join(', ')} must update the app. '
        'Try again in the circle settings (Server processing).');
    return const NewCircleResult(isPrivate: true, serverOn: false);
  } catch (e) {
    say('The circle is private, but the server could not be switched on yet (${e is StateError ? e.message : errorText(e)}). '
        'Try again in the circle settings (Server processing).');
    return const NewCircleResult(isPrivate: true, serverOn: false);
  }
  switch (outcome) {
    case NewCircleServerOutcome.serverOn:
      say('Private circle ready. Your server processes it, and everyone who joins is on the server by default.');
      return const NewCircleResult(isPrivate: true, serverOn: true);
    case NewCircleServerOutcome.approveServer:
      if (!context.mounted) return const NewCircleResult(isPrivate: true, serverOn: false);
      final Circle priv = Circle(id: circle.id, name: circle.name, role: 'admin', sharingEnabled: circle.sharingEnabled, memberCount: circle.memberCount, e2eeMode: 'private');
      final bool added = await showAddServerSheet(context, circle: priv, controller: setup.controller) == true;
      if (!added) {
        say('The circle is private. Approve your server any time from the attention icon or the circle settings.');
        return const NewCircleResult(isPrivate: true, serverOn: false);
      }
      if (requireServer) {
        try {
          await setup.requireForEveryone(circle.id);
        } catch (_) {
          say('The server is on, but "Everyone must use the server" could not be saved. Set it in Server processing.');
        }
      }
      return const NewCircleResult(isPrivate: true, serverOn: true);
    case NewCircleServerOutcome.waitingForServerAdmin:
      say('The circle is private. Your server is waiting for its administrator to approve it once; after that, '
          'tap "Let the server do it" for this circle.');
      return const NewCircleResult(isPrivate: true, serverOn: false);
    case NewCircleServerOutcome.keyConflict:
      say('Stop: the server gave two different answers about its key, so it was not added. The circle is private, phones only. '
          'Check the server address in Settings > Server.');
      return const NewCircleResult(isPrivate: true, serverOn: false);
    case NewCircleServerOutcome.unavailable:
      say('The circle is private, phones only: this server cannot take part yet. See /docs/server-setup.');
      return const NewCircleResult(isPrivate: true, serverOn: false);
  }
}
