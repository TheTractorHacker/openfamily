import 'package:flutter/material.dart';
import '../widgets/on_device_reports_tile.dart';

import '../models/circle.dart';
import '../services/circle_service.dart';
import '../services/error_copy.dart';
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
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = actionFailedMessage(e, 'load your circles');
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
            : DsSettingsList(
                children: <Widget>[
                  DsSectionHeader(
                    'Private circles',
                    padding: EdgeInsets.fromLTRB(DsRowScope.insetFor(context), AppSpace.sm, AppSpace.sm, AppSpace.sm),
                    trailing: const InfoHint(
                      title: 'Where my data is processed',
                      body: 'In each Private circle you decide whether the Orbitly server may process your data. '
                          'Choose "Phone only" ("Don\'t send my data to the server") and your phone does the work; end-to-end '
                          'encryption between phones continues. The server operator can still see that you are a member and when '
                          'your phone connects.',
                    ),
                  ),
                  if (_error != null) DsFootnote(_error!, key: const Key('my-proc-error')),
                  if (_rows.isEmpty && _error == null)
                    const ProcessingNote(
                        noteKey: Key('my-proc-empty'),
                        icon: Icons.lock_open,
                        text: 'You are not in a Private circle. In a normal circle your position is sent to the server in readable form.'),
                  if (_rows.isNotEmpty)
                    DsRowGroup(children: <Widget>[
                      for (final ({Circle circle, ProcessingSnapshot? snap}) r in _rows)
                        DsListRow(
                          key: Key('my-proc-${r.circle.id}'),
                          leading: DsListRow.iconTile(context, Icons.lock_outline, decorative: true),
                          title: r.circle.name,
                          subtitle: _subtitleFor(r.snap),
                          trailing: _chipFor(r.snap),
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

  /// The lane chip on the right; none on a narrow screen or at large text (it would be cut off; the second line says it).
  Widget? _chipFor(ProcessingSnapshot? s) {
    if (DsListRow.compactFor(context) || s?.me == null || s!.legacy) return null;
    return LaneChip(server: s.me!.serverAssisted);
  }

  String? _subtitleFor(ProcessingSnapshot? s) {
    final String? lane = DsListRow.compactFor(context) && s?.me != null && !s!.legacy ? laneLabel(s.me!.serverAssisted) : null;
    final String joined = dsMeta(<String?>[lane, _subtitle(s)]);
    return joined.isEmpty ? null : joined;
  }

  /// A second line only when the chip on the right does not already say it.
  String? _subtitle(ProcessingSnapshot? s) {
    if (s == null) return 'Could not check; your position is still sent';
    if (s.legacy) return 'Old mode: the server can read it';
    if (!s.assistOn) return 'Off for this circle';
    final ProcessingMember? me = s.me;
    if (me?.serverAssisted ?? false) return s.required ? 'Required by your family admin' : null;
    return s.required ? 'Required by your admin; switching over' : null;
  }
}
