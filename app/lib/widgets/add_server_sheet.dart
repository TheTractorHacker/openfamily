import 'package:flutter/material.dart';

import '../models/circle.dart';
import '../screens/security_widgets.dart' show errorText;
import '../services/e2ee/add_server_flow.dart';
import '../services/e2ee/e2ee_crypto.dart';
import '../services/e2ee/lanes_service.dart' show LanesNotReady;
import '../services/e2ee/processing_controller.dart';
import '../theme/app_theme.dart';
import '../services/server_config.dart';
import 'server_prompts.dart' show updateMessageText;

/// "Add server to this circle": one guided sheet, three steps (add, check the
/// code, OK). Logic lives in [AddServerFlow]; this file is text and layout.
/// Resolves to true when the server was added or removed.
Future<bool?> showAddServerSheet(BuildContext context, {required Circle circle, ProcessingController? controller}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (BuildContext ctx) => AddServerSheet(circle: circle, controller: controller),
  );
}

class AddServerSheet extends StatefulWidget {
  const AddServerSheet({super.key, required this.circle, this.controller});
  final Circle circle;
  final ProcessingController? controller;

  @override
  State<AddServerSheet> createState() => _AddServerSheetState();
}

class _AddServerSheetState extends State<AddServerSheet> {
  late final AddServerFlow _flow = AddServerFlow(widget.controller ?? LanesProcessingController.instance);
  AddServerPlan? _plan;
  Object? _loadError;
  bool _loading = true;
  bool _busy = false;
  int _step = 1;
  bool _mismatch = false;
  bool _fullCode = false;
  bool _done = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final AddServerPlan p = await _flow.plan(widget.circle.id);
      if (!mounted) return;
      setState(() {
        _plan = p;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e;
        _loading = false;
      });
    }
  }

  Future<void> _ok() async {
    final AddServerPlan? p = _plan;
    if (p == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _flow.confirm(widget.circle.id, p);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _done = true;
      });
    } on LanesNotReady catch (e) {
      _fail('Some people need to update the Orbitly app first: ${e.names.join(', ')}. Ask them, then try again.');
    } on StateError catch (e) {
      _fail(e.message);
    } catch (e) {
      _fail(errorText(e));
    }
  }

  void _fail(String m) {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = m;
    });
  }

  Future<void> _remove() async {
    bool del = true;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, StateSetter set) => AlertDialog(
          title: const Text('Remove the server?'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            const Text('Your location will be shared privately, encrypted from phone to phone. The server will no longer keep your history, trips or driving reports; you get no reports unless you turn on phone reports (uses more battery).'),
            CheckboxListTile(
              key: const Key('add-server-remove-delete'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: del,
              onChanged: (bool? v) => set(() => del = v ?? false),
              title: const Text('Also delete the copies the server already holds of my data'),
            ),
          ]),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
            FilledButton(key: const Key('add-server-remove-confirm'), onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Remove server')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _flow.remove(widget.circle.id, deleteCopies: del);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      _fail(e is StateError ? e.message : errorText(e));
    }
  }

  Future<void> _removeEveryone() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Remove the server for everyone?'),
        content: const Text('Server processing is switched off for the whole circle and the server deletes the data it holds for this circle. Phones keep what they already have.'),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          FilledButton(key: const Key('add-server-remove-all-confirm'), onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Remove for everyone')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final ProcessingSnapshot s = _plan!.snapshot;
    setState(() => _busy = true);
    try {
      await _flow.removeForEveryone(widget.circle.id, defaultForNew: s.policy.defaultForNew, memberOptOut: E2ee.optOutAllowed);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      _fail(e is StateError ? e.message : errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Padding(
          key: const Key('add-server-sheet'),
          padding: const EdgeInsets.fromLTRB(AppSpace.xxl, AppSpace.lg, AppSpace.xxl, AppSpace.xxl),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: _content()),
        ),
      ),
    );
  }

  Widget _title(String t) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpace.md),
        child: Text(t, style: Theme.of(context).textTheme.titleLarge, semanticsLabel: t),
      );

  Widget _p(String t, {Key? key, Color? color}) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpace.md),
        child: Text(t, key: key, style: color == null ? null : TextStyle(color: color)),
      );

  Widget _close([String label = 'Close']) =>
      TextButton(key: const Key('add-server-close'), onPressed: () => Navigator.of(context).pop(false), child: Text(label));

  List<Widget> _content() {
    if (_loading) return const <Widget>[Padding(padding: EdgeInsets.all(AppSpace.xxl), child: Center(child: CircularProgressIndicator()))];
    if (_loadError != null) {
      return <Widget>[
        _title('Add server to this circle'),
        _p('This server does not support adding a server from the app yet, or it could not be reached. Update the server and the app, or try again later.', key: const Key('add-server-unavailable')),
        _close(),
      ];
    }
    final AddServerPlan p = _plan!;
    final ColorScheme cs = Theme.of(context).colorScheme;
    switch (p.state) {
      case AddServerState.notPrivate:
        return <Widget>[
          _title('Add server to this circle'),
          _p('This is a normal circle, so the server already keeps its positions. Nothing to add.', key: const Key('add-server-normal')),
          _close(),
        ];
      case AddServerState.legacy:
        return <Widget>[
          _title('Add server to this circle'),
          _p('This circle uses the older "trusted server" mode. Open Encryption keys for this circle to upgrade it first.', key: const Key('add-server-legacy')),
          _close(),
        ];
      case AddServerState.serverMissing:
        return <Widget>[
          _title('The server is not ready yet'),
          _p(p.profile.device == null
              ? 'Whoever runs your server still has to give it its key. They can follow the steps in the admin page (Settings > Server setup) or in docs /docs/server-setup. Come back here when that is done.'
              : 'The server has a key, but this circle does not accept it yet. Ask the person who runs the server to finish the steps in docs /docs/server-setup, then try again.',
              key: const Key('add-server-notenrolled')),
          Row(children: <Widget>[TextButton(key: const Key('add-server-retry'), onPressed: _load, child: const Text('Check again')), _close()]),
        ];
      case AddServerState.keyConflict:
        return <Widget>[
          _title('Stop: the server key does not add up'),
          _p('The server gave two different answers about its own key. Do not continue. Check that this app points to your own server (Settings > Server), and ask the person who runs it.',
              key: const Key('add-server-conflict'), color: cs.error),
          _close(),
        ];
      case AddServerState.needsAdmin:
        return <Widget>[
          _title('Ask the circle admin'),
          _p('Only a circle admin can turn the server on for a circle. Ask them to tap "Add server to this circle". After that you will be asked here, and you decide for your own location.', key: const Key('add-server-needs-admin')),
          _close(),
        ];
      case AddServerState.membersNeedUpdate:
        return <Widget>[
          _title('Some people need to update the app'),
          _p('Before the server can be added, these people need the newest Orbitly app: ${p.names.join(', ')}.', key: const Key('add-server-update')),
          _p('Message to send them:'),
          SelectableText(updateMessageText(ServerConfig.instance.apiBaseUrl), key: const Key('add-server-update-message')),
          const SizedBox(height: AppSpace.md),
          _close(),
        ];
      case AddServerState.alreadyAdded:
        return <Widget>[
          _title('Server added'),
          _p('The server already works with your location in this circle.', key: const Key('add-server-added')),
          if (_error != null) _p(_error!, color: cs.error),
          OutlinedButton(key: const Key('add-server-remove'), onPressed: _busy ? null : _remove, child: const Text('Remove server')),
          if (p.snapshot.iAmAdmin) ...<Widget>[
            const SizedBox(height: AppSpace.sm),
            OutlinedButton(key: const Key('add-server-remove-all'), onPressed: _busy ? null : _removeEveryone, child: const Text('Remove server for everyone')),
          ],
          _close(),
        ];
      case AddServerState.serverWaiting:
        return <Widget>[
          _title('Your server wants to join'),
          _p('The server is asking to join and a server administrator has to approve it on their phone (Settings > Server setup, or any circle > Add server). Ask them, then check again.',
              key: const Key('add-server-waiting')),
          Row(children: <Widget>[TextButton(key: const Key('add-server-retry'), onPressed: _load, child: const Text('Check again')), _close()]),
        ];
      case AddServerState.approveServer:
      case AddServerState.ready:
        break;
    }
    if (_done) {
      return <Widget>[
        _title('Server added'),
        _p(p.adminTurnsOn
            ? 'The server is on for this circle and for you. Now ask each other member to open the app and tap "Use the server". Nobody is switched on for them, and they can say no.'
            : 'The server now works with your location in this circle.', key: const Key('add-server-success')),
        FilledButton(key: const Key('add-server-finish'), onPressed: () => Navigator.of(context).pop(true), child: const Text('Done')),
      ];
    }
    if (_mismatch) {
      return <Widget>[
        _title('Stop: the codes are different'),
        _p('Do not continue. Nothing was changed. The server you are connected to may not be your own, or its key was replaced. Check the server address in the app (Settings > Server), then compare again with the admin page of your own server. If they still differ, ask whoever runs the server to set up the key again.',
            key: const Key('add-server-mismatch'), color: cs.error),
        Row(children: <Widget>[
          TextButton(key: const Key('add-server-compare-again'), onPressed: () => setState(() => _mismatch = false), child: const Text('Compare again')),
          _close(),
        ]),
      ];
    }
    switch (_step) {
      case 1:
        return <Widget>[
          _title(p.state == AddServerState.approveServer ? 'Your server wants to join' : 'Step 1 of 3: use the server (recommended)'),
          if (p.state == AddServerState.approveServer) _p('This server is asking to join your circle as its own device, so it can keep maps, history and driving reports for people who choose it. Only you can approve it, and only after you compare its code.', key: const Key('add-server-join-intro')),
          _p(addServerExplanation(p.profile), key: const Key('add-server-explain')),
          Row(children: <Widget>[
            FilledButton(key: const Key('add-server-next'), onPressed: () => setState(() => _step = 2), child: const Text('Next')),
            const SizedBox(width: AppSpace.sm),
            _close('Not now'),
          ]),
        ];
      case 2:
        return <Widget>[
          _title('Step 2 of 3: check the code'),
          _p('Open the admin page of your server on a computer (Settings > Server setup). It shows four groups like these, and a QR code. Are they the same?'),
          Wrap(key: const Key('add-server-code-words'), spacing: 12, runSpacing: 4, children: <Widget>[
            for (final String g in p.words.split(' '))
              Text(g, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700, fontFeatures: <FontFeature>[FontFeature.tabularFigures()])),
          ]),
          TextButton(key: const Key('add-server-full'), onPressed: () => setState(() => _fullCode = !_fullCode), child: Text(_fullCode ? 'Hide the full code' : 'Show the full code')),
          if (_fullCode) _p(p.digits, key: const Key('add-server-digits')),
          const SizedBox(height: AppSpace.sm),
          FilledButton(key: const Key('add-server-same'), onPressed: () => setState(() => _step = 3), child: const Text('Yes, they are the same')),
          const SizedBox(height: AppSpace.sm),
          OutlinedButton(key: const Key('add-server-different'), onPressed: () => setState(() => _mismatch = true), child: const Text('No, they are different')),
        ];
      default:
        return <Widget>[
          _title('Step 3 of 3: OK'),
          _p(p.adminTurnsOn
              ? 'Tapping OK ${p.state == AddServerState.approveServer ? 'approves the server and ' : ''}turns the server on for this circle and for you. Other members are asked on their own phones; nobody is added for them.'
              : 'Tapping OK lets the server work with your location in this circle. You can remove it again at any time.', key: const Key('add-server-confirm-text')),
          if (_error != null) _p(_error!, key: const Key('add-server-error'), color: cs.error),
          FilledButton(key: const Key('add-server-ok'), onPressed: _busy ? null : _ok, child: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('OK')),
          _close('Cancel'),
        ];
    }
  }
}
