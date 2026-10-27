import 'package:flutter/material.dart';

import '../models/member.dart';
import '../services/location_service.dart';
import '../services/sharing_service.dart';
import '../theme/app_theme.dart';

/// Opens the check-in / pause / live-share sheet.
Future<void> showSharingSheet(
  BuildContext context, {
  required List<Member> members,
  String? selfId,
  SharingService service = const SharingService(),
  Future<({double lat, double lon})?> Function()? locate,
  DateTime Function()? clock,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (BuildContext _) => SharingSheet(
      members: members,
      selfId: selfId,
      service: service,
      locate: locate,
      clock: clock,
    ),
  );
}

/// "I'm here" check-in to chosen people, a temporary pause of location
/// sharing, and time-limited live sharing with one person. The server enforces
/// every expiry; the countdowns here only mirror it.
class SharingSheet extends StatefulWidget {
  const SharingSheet({
    super.key,
    required this.members,
    required this.service,
    this.selfId,
    this.locate,
    this.clock,
  });

  final List<Member> members;
  final String? selfId;
  final SharingService service;
  final Future<({double lat, double lon})?> Function()? locate;
  final DateTime Function()? clock;

  @override
  State<SharingSheet> createState() => _SharingSheetState();
}

class _SharingSheetState extends State<SharingSheet> {
  final TextEditingController _note = TextEditingController();
  final Set<String> _recipients = <String>{};
  SharingPause _pause = const SharingPause(paused: false);
  LiveShares _shares = const LiveShares();
  String? _shareWith;
  int _shareMinutes = 60;
  bool _busy = false;
  String? _message;
  String? _error;

  DateTime _now() => (widget.clock ?? DateTime.now)();

  List<Member> get _others => <Member>[
        for (final Member m in widget.members)
          if (m.id != widget.selfId) m,
      ];

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final SharingPause p = await widget.service.pauseStatus();
      final LiveShares s = await widget.service.liveShares();
      if (!mounted) return;
      setState(() {
        _pause = p;
        _shares = s;
      });
    } catch (_) {
      // Leave the defaults; the actions below report their own errors.
    }
  }

  Future<void> _run(String action, Future<void> Function() body,
      {String? done}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      await body();
      if (!mounted) return;
      setState(() => _message = done);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = sharingErrorMessage(e, action: action));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendCheckIn() => _run('send your check-in', () async {
        final ({double lat, double lon})? pos =
            widget.locate != null ? await widget.locate!() : await _locate();
        await widget.service.checkIn(
          recipientIds: _recipients.toList(),
          note: _note.text.trim(),
          lat: pos?.lat,
          lon: pos?.lon,
        );
        if (mounted) {
          _note.clear();
          _recipients.clear();
        }
      }, done: 'Check-in sent.');

  Future<({double lat, double lon})?> _locate() async {
    final p = await LocationService.currentPosition();
    return p == null ? null : (lat: p.latitude, lon: p.longitude);
  }

  Future<void> _setPause({int? minutes, DateTime? until}) =>
      _run('pause sharing', () async {
        final SharingPause p =
            await widget.service.pause(minutes: minutes, until: until);
        if (mounted) setState(() => _pause = p);
      }, done: 'Location sharing paused. SOS still shares your location.');

  Future<void> _customPause() async {
    final DateTime now = _now();
    final DateTime? date = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: now,
      lastDate: now.add(const Duration(days: 30)),
    );
    if (date == null || !mounted) return;
    final TimeOfDay? time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now.add(const Duration(hours: 2))),
    );
    if (time == null) return;
    final DateTime until =
        DateTime(date.year, date.month, date.day, time.hour, time.minute);
    if (!until.isAfter(now.add(const Duration(minutes: 1)))) {
      setState(() => _error = 'Pick a time at least a minute from now.');
      return;
    }
    await _setPause(until: until);
  }

  Future<void> _resume() => _run('resume sharing', () async {
        await widget.service.resume();
        if (mounted) setState(() => _pause = const SharingPause(paused: false));
      }, done: 'Location sharing resumed.');

  Future<void> _startShare() => _run('share your location', () async {
        await widget.service
            .shareLive(viewerId: _shareWith!, minutes: _shareMinutes);
        final LiveShares s = await widget.service.liveShares();
        if (mounted) setState(() => _shares = s);
      }, done: 'Live location shared.');

  Future<void> _endShare(LiveShare s) => _run('stop sharing', () async {
        await widget.service.endLiveShare(s.id);
        final LiveShares next = await widget.service.liveShares();
        if (mounted) setState(() => _shares = next);
      }, done: 'Stopped sharing with ${s.name}.');

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final DateTime now = _now();
    final bool paused = _pause.activeAt(now);
    final List<LiveShare> outgoing =
        _shares.withoutExpired(now).outgoing;
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(AppSpace.md, 0, AppSpace.md,
            AppSpace.md + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Check in & sharing', style: text.titleLarge),
            const SizedBox(height: AppSpace.sm),
            if (_error != null)
              Semantics(
                liveRegion: true,
                child: Text(_error!,
                    style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            if (_message != null)
              Semantics(liveRegion: true, child: Text(_message!)),
            const SizedBox(height: AppSpace.md),
            Text("I'm here", style: text.titleMedium),
            Text(
              'Send your current location once to the people you choose.',
              style: text.bodySmall,
            ),
            if (_others.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpace.sm),
                child: Text('No one else is in this circle yet.'),
              ),
            for (final Member m in _others)
              CheckboxListTile(
                key: ValueKey<String>('checkin-${m.id}'),
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(m.name),
                value: _recipients.contains(m.id),
                onChanged: _busy
                    ? null
                    : (bool? v) => setState(() {
                          v == true ? _recipients.add(m.id) : _recipients.remove(m.id);
                        }),
              ),
            TextField(
              controller: _note,
              maxLength: 280,
              decoration: const InputDecoration(labelText: 'Note (optional)'),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: _busy || _recipients.isEmpty ? null : _sendCheckIn,
                child: const Text('Send check-in'),
              ),
            ),
            const Divider(height: AppSpace.lg),
            Text('Pause sharing', style: text.titleMedium),
            if (paused) ...<Widget>[
              Text(
                'Paused. ${formatTimeLeft(_pause.until!.difference(now))}. '
                'Your circles cannot see your location. SOS still shares it.',
                style: text.bodySmall,
              ),
              TextButton(
                onPressed: _busy ? null : _resume,
                child: const Text('Resume sharing'),
              ),
            ] else
              Wrap(
                spacing: AppSpace.sm,
                children: <Widget>[
                  ActionChip(
                    label: const Text('1 hour'),
                    onPressed: _busy ? null : () => _setPause(minutes: 60),
                  ),
                  ActionChip(
                    label: const Text('Until tomorrow'),
                    onPressed: _busy
                        ? null
                        : () => _setPause(until: pauseUntilTomorrow(now)),
                  ),
                  ActionChip(
                    label: const Text('Custom…'),
                    onPressed: _busy ? null : _customPause,
                  ),
                ],
              ),
            const Divider(height: AppSpace.lg),
            Text('Share live with one person', style: text.titleMedium),
            Text('Stops by itself when the time is up.', style: text.bodySmall),
            DropdownButtonFormField<String>(
              key: const ValueKey<String>('share-person'),
              initialValue: _shareWith,
              decoration: const InputDecoration(labelText: 'Person'),
              items: <DropdownMenuItem<String>>[
                for (final Member m in _others)
                  DropdownMenuItem<String>(value: m.id, child: Text(m.name)),
              ],
              onChanged: _busy ? null : (String? v) => setState(() => _shareWith = v),
            ),
            const SizedBox(height: AppSpace.sm),
            Wrap(
              spacing: AppSpace.sm,
              children: <Widget>[
                for (final (int, String) o in const <(int, String)>[
                  (60, '1 hour'),
                  (240, '4 hours'),
                  (1440, '24 hours'),
                ])
                  ChoiceChip(
                    label: Text(o.$2),
                    selected: _shareMinutes == o.$1,
                    onSelected: _busy ? null : (_) => setState(() => _shareMinutes = o.$1),
                  ),
              ],
            ),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: _busy || _shareWith == null ? null : _startShare,
                child: const Text('Start sharing'),
              ),
            ),
            for (final LiveShare s in outgoing)
              ListTile(
                key: ValueKey<String>('share-${s.id}'),
                contentPadding: EdgeInsets.zero,
                title: Text('Sharing with ${s.name}'),
                subtitle: Text(formatTimeLeft(s.expiresAt.difference(now))),
                trailing: TextButton(
                  onPressed: _busy ? null : () => _endShare(s),
                  child: const Text('Stop'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
