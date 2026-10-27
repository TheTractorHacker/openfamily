import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:share_plus/share_plus.dart';

import '../models/member.dart';
import '../services/location_service.dart';
import '../services/sharing_service.dart';
import '../theme/app_theme.dart';
import 'member_avatar_bubble.dart';
import 'openfamily_map_layers.dart';

/// Opens the sharing sheet: the "share a link with anyone" flow first, then
/// check-in / pause / live share with one person.
Future<void> showSharingSheet(
  BuildContext context, {
  required List<Member> members,
  String? selfId,
  SharingService service = const SharingService(),
  Future<({double lat, double lon})?> Function()? locate,
  DateTime Function()? clock,
  Future<void> Function(String url)? shareUrl,
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
      shareUrl: shareUrl,
    ),
  );
}

/// Primary: a revocable, expiring link anyone can open in a browser to follow
/// your live location (no app needed). Secondary: an "I'm here" check-in to
/// chosen people, a temporary pause of location sharing, and time-limited live
/// sharing with one person. The server enforces every expiry; the countdowns
/// here only mirror it.
class SharingSheet extends StatefulWidget {
  const SharingSheet({
    super.key,
    required this.members,
    required this.service,
    this.selfId,
    this.locate,
    this.clock,
    this.shareUrl,
    this.showPreviewMap = true,
  });

  /// Hands the new link to the OS share sheet. Defaults to share_plus.
  final Future<void> Function(String url)? shareUrl;

  /// Tests turn the tile-backed preview map off.
  final bool showPreviewMap;

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
  List<ShareLink> _links = const <ShareLink>[];
  int _linkMinutes = 60;
  int _customMinutes = 6 * 60;
  String? _lastUrl;
  Timer? _tick;
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
    // Keep the countdown chips honest; tests inject a clock and skip this.
    if (widget.clock == null) {
      _tick = Timer.periodic(const Duration(seconds: 30), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _note.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final SharingPause p = await widget.service.pauseStatus();
      final LiveShares s = await widget.service.liveShares();
      final List<ShareLink> links = await widget.service.shareLinks();
      if (!mounted) return;
      setState(() {
        _pause = p;
        _shares = s;
        _links = links;
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

  Future<void> _shareLink(String url) async {
    final Future<void> Function(String)? custom = widget.shareUrl;
    if (custom != null) return custom(url);
    await Share.share(url, subject: 'My live location');
  }

  Future<void> _startLink() => _run('create the link', () async {
        final ShareLink link =
            await widget.service.createShareLink(minutes: _linkMinutes);
        final List<ShareLink> links = await widget.service.shareLinks();
        if (mounted) {
          setState(() {
            _links = links;
            _lastUrl = link.url;
          });
        }
        if (link.url != null) await _shareLink(link.url!);
      }, done: 'Link created. Anyone who opens it can follow you until it ends.');

  Future<void> _stopLink(ShareLink l) => _run('stop sharing', () async {
        await widget.service.stopShareLink(l.id);
        final List<ShareLink> links = await widget.service.shareLinks();
        if (mounted) setState(() => _links = links);
      }, done: 'Stopped sharing. That link no longer works.');

  Future<void> _copyLast() async {
    final String? url = _lastUrl;
    if (url == null) return;
    await Clipboard.setData(ClipboardData(text: url));
    if (mounted) setState(() => _message = 'Link copied.');
  }

  Future<void> _pickCustomDuration() async {
    final int? hours = await showDialog<int>(
      context: context,
      builder: (BuildContext _) =>
          _CustomHoursDialog(initialHours: _customMinutes ~/ 60),
    );
    if (hours != null && mounted) {
      setState(() {
        _customMinutes = hours * 60;
        _linkMinutes = _customMinutes;
      });
    }
  }

  static const List<(int, String)> _linkDurations = <(int, String)>[
    (60, '1 hour'),
    (120, '2 hours'),
    (240, '4 hours'),
    (480, '8 hours'),
    (1440, '24 hours'),
  ];

  /// Dropdown value: a preset, or [_customValue] for the custom entry.
  static const int _customValue = -1;
  int get _durationValue =>
      _linkDurations.any(((int, String) o) => o.$1 == _linkMinutes)
          ? _linkMinutes
          : _customValue;

  String _customLabel() => 'Custom (${_customMinutes ~/ 60} h)';

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

  Member? get _self {
    for (final Member m in widget.members) {
      if (m.id == widget.selfId) return m;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final DateTime now = _now();
    final bool paused = _pause.activeAt(now);
    final List<ShareLink> links = <ShareLink>[
      for (final ShareLink l in _links)
        if (!l.expiredAt(now)) l,
    ];
    final List<LiveShare> outgoing = _shares.withoutExpired(now).outgoing;
    // Scale-friendly: everything is full width, wraps, and scrolls; nothing
    // relies on a fixed height or a single row of controls.
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(AppSpace.lg, 0, AppSpace.lg,
            AppSpace.lg + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Semantics(
              header: true,
              child: Text(
                'Share your live location with anyone, no app needed',
                style: text.titleLarge,
              ),
            ),
            const SizedBox(height: AppSpace.md),
            _SharePreview(
                member: _self, showMap: widget.showPreviewMap),
            const SizedBox(height: AppSpace.md),
            Text(
              'Anyone with the link can see your live location, name, photo, '
              'and battery status. You can stop sharing at any time.',
              style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: AppSpace.lg),
            DropdownButtonFormField<int>(
              key: const ValueKey<String>('link-duration'),
              isExpanded: true,
              initialValue: _durationValue,
              decoration: const InputDecoration(labelText: 'Duration'),
              items: <DropdownMenuItem<int>>[
                for (final (int, String) o in _linkDurations)
                  DropdownMenuItem<int>(value: o.$1, child: Text(o.$2)),
                DropdownMenuItem<int>(
                  value: _customValue,
                  child: Text(
                    _durationValue == _customValue
                        ? _customLabel()
                        : 'Custom (up to 72 h)',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
              onChanged: _busy
                  ? null
                  : (int? v) {
                      if (v == null) return;
                      if (v == _customValue) {
                        _pickCustomDuration();
                      } else {
                        setState(() => _linkMinutes = v);
                      }
                    },
            ),
            const SizedBox(height: AppSpace.md),
            FilledButton(
              key: const ValueKey<String>('start-link'),
              style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(56)),
              onPressed: _busy ? null : _startLink,
              child: const Text('Start sharing'),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: AppSpace.sm),
                child: Semantics(
                  liveRegion: true,
                  child: Text(_error!, style: TextStyle(color: scheme.error)),
                ),
              ),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.only(top: AppSpace.sm),
                child: Semantics(liveRegion: true, child: Text(_message!)),
              ),
            if (_lastUrl != null)
              Wrap(
                spacing: AppSpace.sm,
                children: <Widget>[
                  TextButton.icon(
                    key: const ValueKey<String>('link-share-again'),
                    onPressed: () => _run('share the link',
                        () => _shareLink(_lastUrl!)),
                    icon: const Icon(Icons.ios_share),
                    label: const Text('Share again'),
                  ),
                  TextButton.icon(
                    key: const ValueKey<String>('link-copy'),
                    onPressed: _copyLast,
                    icon: const Icon(Icons.copy),
                    label: const Text('Copy link'),
                  ),
                ],
              ),
            if (links.isNotEmpty) ...<Widget>[
              const SizedBox(height: AppSpace.lg),
              Text('Active links', style: text.titleMedium),
              for (int i = 0; i < links.length; i++)
                _LinkRow(
                  key: ValueKey<String>('link-${links[i].id}'),
                  index: i + 1,
                  link: links[i],
                  left: links[i].expiresAt.difference(now),
                  onStop: _busy ? null : () => _stopLink(links[i]),
                ),
            ],
            const Divider(height: AppSpace.xxxl),
            Text('Other ways to share', style: text.titleMedium),
            _section(
              key: 'more-checkin',
              icon: Icons.place_outlined,
              title: "I'm here",
              children: <Widget>[
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
                              v == true
                                  ? _recipients.add(m.id)
                                  : _recipients.remove(m.id);
                            }),
                  ),
                TextField(
                  controller: _note,
                  maxLength: 280,
                  decoration:
                      const InputDecoration(labelText: 'Note (optional)'),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed:
                        _busy || _recipients.isEmpty ? null : _sendCheckIn,
                    child: const Text('Send check-in'),
                  ),
                ),
              ],
            ),
            _section(
              key: 'more-pause',
              icon: Icons.pause_circle_outline,
              title: 'Pause sharing',
              subtitle: paused ? 'Paused' : null,
              children: <Widget>[
                if (paused) ...<Widget>[
                  Text(
                    'Paused. ${formatTimeLeft(_pause.until!.difference(now))}. '
                    'Your circles and link viewers cannot see your location. '
                    'SOS still shares it.',
                    style: text.bodySmall,
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: _busy ? null : _resume,
                      child: const Text('Resume sharing'),
                    ),
                  ),
                ] else
                  Wrap(
                    spacing: AppSpace.sm,
                    runSpacing: AppSpace.xs,
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
              ],
            ),
            _section(
              key: 'more-person',
              icon: Icons.person_pin_circle_outlined,
              title: 'Share live with one person',
              subtitle: outgoing.isEmpty ? null : '${outgoing.length} active',
              children: <Widget>[
                Text('Stops by itself when the time is up.',
                    style: text.bodySmall),
                const SizedBox(height: AppSpace.sm),
                DropdownButtonFormField<String>(
                  key: const ValueKey<String>('share-person'),
                  isExpanded: true,
                  initialValue: _shareWith,
                  decoration: const InputDecoration(labelText: 'Person'),
                  items: <DropdownMenuItem<String>>[
                    for (final Member m in _others)
                      DropdownMenuItem<String>(
                          value: m.id,
                          child: Text(m.name, overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: _busy
                      ? null
                      : (String? v) => setState(() => _shareWith = v),
                ),
                const SizedBox(height: AppSpace.sm),
                Wrap(
                  spacing: AppSpace.sm,
                  runSpacing: AppSpace.xs,
                  children: <Widget>[
                    for (final (int, String) o in const <(int, String)>[
                      (60, '1 hour'),
                      (240, '4 hours'),
                      (1440, '24 hours'),
                    ])
                      ChoiceChip(
                        label: Text(o.$2),
                        selected: _shareMinutes == o.$1,
                        onSelected: _busy
                            ? null
                            : (_) => setState(() => _shareMinutes = o.$1),
                      ),
                  ],
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    key: const ValueKey<String>('start-person-share'),
                    onPressed: _busy || _shareWith == null ? null : _startShare,
                    child: const Text('Share with this person'),
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
          ],
        ),
      ),
    );
  }

  Widget _section({
    required String key,
    required IconData icon,
    required String title,
    String? subtitle,
    required List<Widget> children,
  }) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        key: ValueKey<String>(key),
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: AppSpace.md),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        leading: Icon(icon),
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle),
        children: children,
      ),
    );
  }
}

/// Small non-interactive map with the sharer's avatar, so the person sees what
/// the link will show before they send it.
class _SharePreview extends StatelessWidget {
  const _SharePreview({required this.member, required this.showMap});

  final Member? member;
  final bool showMap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Member? m = member;
    final LatLng? pos = m?.position;
    return Semantics(
      label: 'Preview of what the link shows: your avatar on a map',
      excludeSemantics: true,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: SizedBox(
          height: 140,
          child: showMap && pos != null
              ? FlutterMap(
                  options: MapOptions(
                    initialCenter: pos,
                    initialZoom: 15,
                    interactionOptions:
                        const InteractionOptions(flags: InteractiveFlag.none),
                  ),
                  children: <Widget>[
                    const OpenFamilyTileLayer(reducedData: true),
                    MarkerLayer(markers: <Marker>[
                      Marker(
                        point: pos,
                        width: 56,
                        height: 56,
                        child: StatusAvatar(member: m!, size: 52),
                      ),
                    ]),
                  ],
                )
              : ColoredBox(
                  color: scheme.surfaceContainerHighest,
                  child: Center(
                    child: m == null
                        ? Icon(Icons.map_outlined,
                            size: 40, color: scheme.onSurfaceVariant)
                        : StatusAvatar(member: m, size: 56),
                  ),
                ),
        ),
      ),
    );
  }
}

class _LinkRow extends StatelessWidget {
  const _LinkRow({
    super.key,
    required this.index,
    required this.link,
    required this.left,
    required this.onStop,
  });

  final int index;
  final ShareLink link;
  final Duration left;
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    final String name = link.label.isEmpty ? 'Link $index' : link.label;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: AppSpace.sm,
        runSpacing: AppSpace.xs,
        children: <Widget>[
          const Icon(Icons.link),
          Text(name),
          Chip(
            visualDensity: VisualDensity.compact,
            avatar: const Icon(Icons.timer_outlined, size: 16),
            label: Text(formatTimeLeft(left)),
          ),
          TextButton(
            onPressed: onStop,
            child: const Text('Stop sharing'),
          ),
        ],
      ),
    );
  }
}

/// Asks for a whole number of hours (1 to 72). Owns its controller so it is
/// disposed only after the dialog's exit animation.
class _CustomHoursDialog extends StatefulWidget {
  const _CustomHoursDialog({required this.initialHours});

  final int initialHours;

  @override
  State<_CustomHoursDialog> createState() => _CustomHoursDialogState();
}

class _CustomHoursDialogState extends State<_CustomHoursDialog> {
  late final TextEditingController _c =
      TextEditingController(text: '${widget.initialHours}');

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Custom duration'),
      content: TextField(
        key: const ValueKey<String>('custom-hours'),
        controller: _c,
        autofocus: true,
        keyboardType: TextInputType.number,
        inputFormatters: <TextInputFormatter>[
          FilteringTextInputFormatter.digitsOnly,
        ],
        decoration: const InputDecoration(
          labelText: 'Hours (1 to 72)',
          helperText: 'Up to 72 hours (3 days)',
        ),
      ),
      actions: <Widget>[
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: () {
            final int? h = int.tryParse(_c.text);
            if (h != null && h >= 1 && h <= kMaxShareLinkMinutes ~/ 60) {
              Navigator.pop(context, h);
            }
          },
          child: const Text('Set'),
        ),
      ],
    );
  }
}
