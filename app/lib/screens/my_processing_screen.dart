import 'package:flutter/material.dart';
import '../widgets/on_device_reports_tile.dart';

import '../models/circle.dart';
import '../services/circle_service.dart';
import '../services/e2ee/processing_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';
import '../widgets/processing_widgets.dart';
import 'processing_screen.dart';

/// Settings > Server & data > Server processing (where my data is processed).
///
/// My Private circles with my own setting for each. "Don't send my data to the
/// server" is the same switch as Circle > Encryption keys > Server processing.
class MyProcessingScreen extends StatefulWidget {
  const MyProcessingScreen({super.key, this.controller, this.circles});
  final ProcessingController? controller;
  final CircleService? circles;

  @override
  State<MyProcessingScreen> createState() => _MyProcessingScreenState();
}

class _MyProcessingScreenState extends State<MyProcessingScreen> {
  ProcessingController get _c => widget.controller ?? LanesProcessingController.instance;
  CircleService get _circles => widget.circles ?? CircleService.instance;
  List<({Circle circle, ProcessingSnapshot? snap})> _rows = <({Circle circle, ProcessingSnapshot? snap})>[];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = _rows.isEmpty;
      _error = null;
    });
    try {
      final List<({Circle circle, ProcessingSnapshot? snap})> rows = <({Circle circle, ProcessingSnapshot? snap})>[];
      for (final Circle c in await _circles.listCircles()) {
        if (!c.isPrivate) continue;
        ProcessingSnapshot? s;
        try {
          s = await _c.load(c.id);
        } catch (_) {}
        rows.add((circle: c, snap: s));
      }
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load your circles.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Server processing')),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(AppSpace.xl),
                children: <Widget>[
                  Row(children: <Widget>[
                    const Expanded(
                        child: Text('Where your data is processed, for each Private circle. Tap a circle to switch the server off or on for you.',
                            style: AppType.secondary)),
                    InfoHint(
                      title: 'Where my data is processed',
                      body: 'In each Private circle you decide whether the Orbitly server may process your data. '
                          'Choose "Phone only" ("Don\'t send my data to the server") and your phone does the work; end-to-end '
                          'encryption between phones continues. The server operator can still see that you are a member and when '
                          'your phone connects.',
                    ),
                  ]),
                  const SizedBox(height: AppSpace.md),
                  if (_error != null) Text(_error!, key: const Key('my-proc-error'), style: AppType.secondary),
                  if (_rows.isEmpty && _error == null)
                    const ProcessingNote(
                        noteKey: Key('my-proc-empty'),
                        icon: Icons.lock_open,
                        text: 'You are not in a Private circle. In a normal circle your position is sent to the server in readable form.'),
                  DsRowGroup(children: <Widget>[
                    for (final ({Circle circle, ProcessingSnapshot? snap}) r in _rows)
                      DsListRow(
                        key: Key('my-proc-${r.circle.id}'),
                        leading: DsListRow.iconTile(context, Icons.lock_outline),
                        title: r.circle.name,
                        subtitle: _subtitle(r.snap),
                        trailing: r.snap?.me == null || r.snap!.legacy ? null : LaneChip(server: r.snap!.me!.serverAssisted),
                        chevron: true,
                        onTap: () async {
                          await Navigator.of(context).push<void>(MaterialPageRoute<void>(
                              builder: (_) => ProcessingScreen(circle: r.circle, controller: widget.controller)));
                          if (mounted) _load();
                        },
                      ),
                  ]),
                  if (_rows.isNotEmpty) const OnDeviceReportsTile(),
                ],
              ),
      ),
    );
  }

  String _subtitle(ProcessingSnapshot? s) {
    if (s == null) return 'Could not check this circle';
    if (s.legacy) return 'Old mode: the server can read it';
    if (!s.assistOn) return 'Phone only';
    final ProcessingMember? me = s.me;
    if (me?.serverAssisted ?? false) return 'The server processes your data';
    return s.required ? 'Needs your OK for the server' : 'Phone only';
  }
}
