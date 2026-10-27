import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/member.dart';
import '../services/api_client.dart';
import '../services/history_scrubber.dart';
import '../services/history_service.dart';
import '../services/speed_units.dart';
import '../theme/app_theme.dart';
import '../widgets/member_avatar_bubble.dart';
import '../widgets/openfamily_map_layers.dart';

/// Loads one day of history for a member (injectable for tests).
typedef DailyHistoryLoader = Future<MemberHistory> Function(
  String memberId,
  DateTime day,
);

Future<MemberHistory> _defaultLoader(String memberId, DateTime day) =>
    HistoryService.fetchDay(memberId: memberId, day: day);

/// Life360-style "Daily History": a full-screen map of a member's day with a
/// day selector pill and a bottom card whose slider scrubs the avatar along
/// the path through time, with 1x/4x/16x playback.
///
/// Drawing uses a downsampled path; the scrubber reads the full-resolution
/// trail from [HistoryTimeline].
class DailyHistoryScreen extends StatefulWidget {
  const DailyHistoryScreen({
    super.key,
    required this.member,
    this.loader = _defaultLoader,
    this.today,
    this.tileProvider,
  });

  final Member member;
  final DailyHistoryLoader loader;

  /// Overrides "today" (tests).
  final DateTime? today;

  /// Overrides the base-map tile provider (tests).
  final TileProvider? tileProvider;

  @override
  State<DailyHistoryScreen> createState() => _DailyHistoryScreenState();
}

class _DailyHistoryScreenState extends State<DailyHistoryScreen>
    with SingleTickerProviderStateMixin {
  static const int _drawCap = 600;

  final MapController _map = MapController();
  late final Ticker _ticker;
  late final DateTime _today;
  late DateTime _day;

  MemberHistory? _history;
  HistoryTimeline _timeline = HistoryTimeline(const <HistoryTrailPoint>[]);
  List<StopCluster> _stops = const <StopCluster>[];
  List<List<LatLng>> _drawSegments = const <List<LatLng>>[];
  String? _error;
  bool _loading = true;
  bool _mapReady = false;
  int _loadToken = 0;

  DateTime? _scrubTime;
  bool _playing = false;
  int _speed = 1;
  Duration _lastTick = Duration.zero;

  @override
  void initState() {
    super.initState();
    _today = dateOnly(widget.today ?? DateTime.now());
    _day = _today;
    _ticker = createTicker(_onTick);
    _load();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final int token = ++_loadToken;
    _stopPlayback();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final MemberHistory h = await widget.loader(widget.member.id, _day);
      if (!mounted || token != _loadToken) return;
      final HistoryTimeline tl = HistoryTimeline(h.trail);
      final List<StopCluster> stops =
          tl.nameStops(tl.stops(), h.visits);
      setState(() {
        _history = h;
        _timeline = tl;
        _stops = stops;
        _drawSegments = _buildDrawSegments(tl, stops);
        _scrubTime = tl.isEmpty ? null : tl.end;
        _loading = false;
      });
      _fitCamera();
    } catch (e) {
      if (!mounted || token != _loadToken) return;
      setState(() {
        _error = e is ApiException
            ? e.message
            : 'Couldn\'t load history. Please try again.';
        _loading = false;
      });
    }
  }

  List<List<LatLng>> _buildDrawSegments(
    HistoryTimeline tl,
    List<StopCluster> stops,
  ) {
    final List<List<int>> ranges = tl.moveRanges(stops);
    // Share the draw budget between segments proportionally.
    final int total = ranges.fold<int>(0, (int a, List<int> r) => a + r[1] - r[0] + 1);
    return <List<LatLng>>[
      for (final List<int> r in ranges)
        downsamplePath(
          <LatLng>[
            for (int i = r[0]; i <= r[1]; i++) tl.points[i].position,
          ],
          total == 0
              ? _drawCap
              : (_drawCap * (r[1] - r[0] + 1) / total).ceil().clamp(2, _drawCap),
        ),
    ];
  }

  void _shiftDay(int delta) {
    final DateTime next = shiftHistoryDay(_day, delta, _today);
    if (next == _day) return;
    setState(() => _day = next);
    _load();
  }

  void _fitCamera() {
    if (!_mapReady || _timeline.isEmpty) return;
    final List<LatLng> coords = <LatLng>[
      for (final HistoryTrailPoint p in _timeline.points) p.position,
    ];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        if (coords.length == 1) {
          _map.move(coords.first, 16);
        } else {
          _map.fitCamera(CameraFit.coordinates(
            coordinates: coords,
            padding: const EdgeInsets.fromLTRB(40, 120, 40, 260),
            maxZoom: 16,
          ));
        }
      } catch (_) {
        // Map not attached yet.
      }
    });
  }

  void _followAvatar(LatLng pos) {
    if (!_mapReady) return;
    try {
      _map.move(pos, _map.camera.zoom);
    } catch (_) {}
  }

  // --- scrubbing / playback -------------------------------------------------

  void _scrubTo(double fraction) {
    if (!_timeline.isScrubbable) return;
    _setTime(_timeline.timeForFraction(fraction));
  }

  void _setTime(DateTime t) {
    setState(() => _scrubTime = t);
    _followAvatar(_timeline.sampleAt(t).position);
  }

  void _togglePlay() {
    if (_playing) {
      _stopPlayback();
      setState(() {});
      return;
    }
    if (!_timeline.isScrubbable) return;
    if (_scrubTime == null || !_scrubTime!.isBefore(_timeline.end)) {
      _scrubTime = _timeline.start;
    }
    _lastTick = Duration.zero;
    _playing = true;
    _ticker.start();
    setState(() {});
  }

  void _stopPlayback() {
    _playing = false;
    if (_ticker.isActive) _ticker.stop();
  }

  void _onTick(Duration elapsed) {
    final Duration dt = elapsed - _lastTick;
    _lastTick = elapsed;
    final DateTime? cur = _scrubTime;
    if (cur == null || dt <= Duration.zero) return;
    final DateTime next = advancePlayback(cur, dt, _speed, _timeline.end);
    _setTime(next);
    if (!next.isBefore(_timeline.end)) {
      _stopPlayback();
      setState(() {});
    }
  }

  // --- build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: <Widget>[
          Positioned.fill(child: _buildMap()),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(child: _buildTopBar()),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(child: _buildBottom()),
          ),
        ],
      ),
    );
  }

  Widget _buildMap() {
    final ScrubSample? sample = _currentSample();
    final LatLng center =
        sample?.position ?? widget.member.position ?? const LatLng(0, 0);
    return Semantics(
      label: 'Map of ${widget.member.name}\'s day',
      child: FlutterMap(
        mapController: _map,
        options: MapOptions(
          initialCenter: center,
          initialZoom: 13,
          onMapReady: () {
            _mapReady = true;
            _fitCamera();
          },
          interactionOptions: const InteractionOptions(
            flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
          ),
        ),
        children: <Widget>[
          OpenFamilyTileLayer(tileProvider: widget.tileProvider),
          PolylineLayer(
            polylines: <Polyline>[
              for (final List<LatLng> seg in _drawSegments)
                if (seg.length >= 2)
                  Polyline(
                    points: seg,
                    color: AppColors.historyTrail,
                    strokeWidth: 4,
                    borderColor: Colors.white,
                    borderStrokeWidth: 3,
                  ),
            ],
          ),
          MarkerLayer(
            markers: <Marker>[
              for (final StopCluster s in _stops) _stopMarker(s),
              if (sample != null)
                Marker(
                  point: sample.position,
                  width: 56,
                  height: 56,
                  alignment: Alignment.center,
                  child: StatusAvatar(member: widget.member, size: 48),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Marker _stopMarker(StopCluster s) {
    return Marker(
      point: s.position,
      width: 96,
      height: 52,
      alignment: Alignment.center,
      child: Semantics(
        label: '${s.name ?? 'Stop'}, ${dwellLabel(s.dwell)}',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white,
                border: Border.all(color: AppColors.historyTrail, width: 2),
              ),
              child: const Padding(
                padding: EdgeInsets.all(3),
                child: Icon(Icons.circle,
                    size: 10, color: AppColors.historyTrail),
              ),
            ),
            const SizedBox(height: 2),
            DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.92),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                child: Text(
                  dwellLabel(s.dwell),
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Colors.black87,
                  ),
                  maxLines: 1,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  ScrubSample? _currentSample() {
    if (_timeline.isEmpty) return null;
    return _timeline.sampleAt(_scrubTime ?? _timeline.end);
  }

  Widget _buildTopBar() {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(AppSpace.md),
      child: Row(
        children: <Widget>[
          Material(
            color: cs.surface,
            shape: const CircleBorder(),
            elevation: 3,
            child: IconButton(
              tooltip: 'Close',
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.close),
              constraints: const BoxConstraints(
                  minWidth: kMinTarget, minHeight: kMinTarget),
            ),
          ),
          const Spacer(),
          Material(
            color: cs.surface,
            elevation: 3,
            shape: const StadiumBorder(),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                IconButton(
                  tooltip: 'Previous day',
                  onPressed:
                      canGoBackDay(_day, _today) ? () => _shiftDay(-1) : null,
                  icon: const Icon(Icons.chevron_left),
                  constraints: const BoxConstraints(
                      minWidth: kMinTarget, minHeight: kMinTarget),
                ),
                Semantics(
                  header: true,
                  child: Text(
                    historyDayLabel(_day, _today),
                    style: AppType.headline.copyWith(fontSize: 16),
                  ),
                ),
                IconButton(
                  tooltip: 'Next day',
                  onPressed: canGoForwardDay(_day, _today)
                      ? () => _shiftDay(1)
                      : null,
                  icon: const Icon(Icons.chevron_right),
                  constraints: const BoxConstraints(
                      minWidth: kMinTarget, minHeight: kMinTarget),
                ),
              ],
            ),
          ),
          const Spacer(),
          const SizedBox(width: kMinTarget),
        ],
      ),
    );
  }

  Widget _buildBottom() {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(AppSpace.md),
      child: Material(
        color: cs.surface,
        elevation: 6,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.lg),
          child: _bottomContent(),
        ),
      ),
    );
  }

  Widget _bottomContent() {
    if (_loading) {
      return Semantics(
        label: 'Loading history',
        child: const SizedBox(
          height: 72,
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    if (_error != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(_error!, textAlign: TextAlign.center),
          const SizedBox(height: AppSpace.sm),
          TextButton(onPressed: _load, child: const Text('Try again')),
        ],
      );
    }
    final ScrubSample? sample = _currentSample();
    if (sample == null) {
      final bool today = _day == _today;
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.timeline, size: 32),
          const SizedBox(height: AppSpace.xs),
          Text('No history for this day', style: AppType.headline),
          const SizedBox(height: AppSpace.xxs),
          Text(
            today
                ? '${widget.member.name} hasn\'t shared any location today yet.'
                : 'No location was recorded for ${widget.member.name} on this day.',
            textAlign: TextAlign.center,
            style: AppType.secondary,
          ),
        ],
      );
    }
    return _ScrubberCard(
      member: widget.member,
      timeline: _timeline,
      stops: _stops,
      visits: _history?.visits ?? const <HistoryVisit>[],
      sample: sample,
      playing: _playing,
      speed: _speed,
      onScrub: _scrubTo,
      onScrubStart: () {
        if (_playing) {
          _stopPlayback();
          setState(() {});
        }
      },
      onTogglePlay: _togglePlay,
      onCycleSpeed: () => setState(() => _speed = nextPlaybackSpeed(_speed)),
    );
  }
}

/// Opens [DailyHistoryScreen] for [member].
void openDailyHistory(BuildContext context, Member member) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => DailyHistoryScreen(member: member),
    ),
  );
}

String _clock(DateTime t) {
  final DateTime l = t.toLocal();
  final int h = l.hour % 12 == 0 ? 12 : l.hour % 12;
  final String m = l.minute.toString().padLeft(2, '0');
  return '$h:$m ${l.hour < 12 ? 'AM' : 'PM'}';
}

class _ScrubberCard extends StatelessWidget {
  const _ScrubberCard({
    required this.member,
    required this.timeline,
    required this.stops,
    required this.visits,
    required this.sample,
    required this.playing,
    required this.speed,
    required this.onScrub,
    required this.onScrubStart,
    required this.onTogglePlay,
    required this.onCycleSpeed,
  });

  final Member member;
  final HistoryTimeline timeline;
  final List<StopCluster> stops;
  final List<HistoryVisit> visits;
  final ScrubSample sample;
  final bool playing;
  final int speed;
  final ValueChanged<double> onScrub;
  final VoidCallback onScrubStart;
  final VoidCallback onTogglePlay;
  final VoidCallback onCycleSpeed;

  String _where() {
    final StopCluster? stop = HistoryTimeline.stopAt(stops, sample.time);
    if (stop != null) {
      return '${stop.name ?? 'Stopped'} · ${dwellLabel(stop.dwell)}';
    }
    for (final HistoryVisit v in visits) {
      if (v.isTransit &&
          !sample.time.isBefore(v.arrivedAt) &&
          !sample.time.isAfter(v.departedAt)) {
        return v.placeName;
      }
    }
    return 'Moving';
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final UnitSystem units = UnitPreferenceService.units.value;
    final double? mps = sample.speedMps;
    final List<String> details = <String>[
      if (mps != null) units.formatSpeed(mps) else 'Speed unknown',
      if (sample.batteryPct != null)
        'Battery ${sample.batteryPct!.round()}%',
    ];
    final bool scrubbable = timeline.isScrubbable;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Semantics(
                    liveRegion: true,
                    child: Text(_clock(sample.time), style: AppType.headline),
                  ),
                  Text(_where(), style: AppType.secondary),
                  Text(
                    details.join(' · '),
                    style: AppType.secondary
                        .copyWith(color: cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: scrubbable ? onCycleSpeed : null,
              child: Semantics(
                label: 'Playback speed ${speed}x',
                child: Text('${speed}x'),
              ),
            ),
            IconButton.filled(
              tooltip: playing ? 'Pause' : 'Play',
              onPressed: scrubbable ? onTogglePlay : null,
              icon: Icon(playing ? Icons.pause : Icons.play_arrow),
              constraints: const BoxConstraints(
                  minWidth: kMinTarget, minHeight: kMinTarget),
            ),
          ],
        ),
        Semantics(
          label: 'Time scrubber',
          value: _clock(sample.time),
          child: Slider(
            value: timeline.fractionForTime(sample.time),
            onChangeStart: scrubbable ? (_) => onScrubStart() : null,
            onChanged: scrubbable ? onScrub : null,
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Text(_clock(timeline.start), style: AppType.secondary),
            if (!scrubbable)
              Text('Only one location recorded', style: AppType.secondary)
            else
              Text(_clock(timeline.end), style: AppType.secondary),
          ],
        ),
      ],
    );
  }
}
