import 'package:flutter/material.dart';

import '../models/bubble.dart';
import '../services/bubble_service.dart';
import '../services/sharing_service.dart' show formatTimeLeft;
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';

/// The caller's active Bubbles, each with a cancel action, plus the Bubbles
/// other people drew around the caller (who and until when, no location).
class BubblesScreen extends StatefulWidget {
  const BubblesScreen({
    super.key,
    this.service = const ApiBubbleService(),
    this.now,
  });

  final BubbleService service;
  final DateTime Function()? now;

  @override
  State<BubblesScreen> createState() => _BubblesScreenState();
}

class _BubblesScreenState extends State<BubblesScreen> {
  BubbleList? _list;
  String? _error;
  String? _cancelling;

  DateTime get _now => (widget.now ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final BubbleList l = (await widget.service.list()).withoutExpired(_now);
      BubbleStore.instance.set(l.mine);
      if (!mounted) return;
      setState(() {
        _list = l;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = bubbleErrorMessage(e, action: 'load your Bubbles'));
    }
  }

  Future<void> _cancel(Bubble b) async {
    setState(() => _cancelling = b.id);
    try {
      await widget.service.cancel(b.id);
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = bubbleErrorMessage(e, action: 'cancel the Bubble'));
    } finally {
      if (mounted) setState(() => _cancelling = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final BubbleList? l = _list;
    return Scaffold(
      appBar: AppBar(title: const Text('Bubbles')),
      body: SafeArea(
        child: l == null
            ? Center(
                child: _error != null
                    ? Padding(
                        padding: const EdgeInsets.all(AppSpace.xl),
                        child: DsMessage(_error!),
                      )
                    : const CircularProgressIndicator(),
              )
            : ListView(
                padding: const EdgeInsets.all(AppSpace.xl),
                children: <Widget>[
                  if (_error != null) DsMessage(_error!),
                  if (l.mine.isEmpty && l.aboutMe.isEmpty)
                    const DsEmptyState(
                      icon: Icons.bubble_chart_outlined,
                      title: 'No active Bubbles',
                      message: 'Open a person in People and tap Create Bubble '
                          'to be alerted when they leave a place.',
                    ),
                  if (l.mine.isNotEmpty)
                    DsRowGroup(children: <Widget>[
                      for (final Bubble b in l.mine) _mineRow(b),
                    ]),
                  if (l.aboutMe.isNotEmpty) ...<Widget>[
                    const SizedBox(height: AppSpace.xl),
                    const Text('Around you', style: AppType.title),
                    const SizedBox(height: AppSpace.sm),
                    DsRowGroup(children: <Widget>[
                      for (final BubbleAboutMe a in l.aboutMe)
                        DsListRow(
                          leading: DsListRow.iconTile(context, Icons.visibility_outlined),
                          title: '${a.creatorName} has a Bubble around you',
                          subtitle: formatTimeLeft(a.expiresAt.difference(_now)),
                        ),
                    ]),
                  ],
                ],
              ),
      ),
    );
  }

  Widget _mineRow(Bubble b) {
    return DsListRow(
      leading: DsListRow.iconTile(context, Icons.bubble_chart_outlined, color: AppColors.purple),
      title: b.subjectName,
      subtitle: '${formatBubbleRadius(b.radiusM)} · '
          '${formatTimeLeft(b.expiresAt.difference(_now))}',
      semanticLabel: 'Bubble around ${b.subjectName}',
      trailing: _cancelling == b.id
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : TextButton(
              onPressed: () => _cancel(b),
              child: const Text('Cancel'),
            ),
    );
  }
}
