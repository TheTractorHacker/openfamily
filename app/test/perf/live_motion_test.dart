// Live-map animation guard: a moving member animates at the frame rate but
// only the marker layer rebuilds. The host (stand-in for MapScreen), the
// bubbles and the clustering are untouched per frame; idle costs nothing.
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:openfamily/models/member.dart';
import 'package:openfamily/screens/map_screen.dart';
import 'package:openfamily/services/member_motion_hub.dart';
import 'package:openfamily/services/perf/perf_monitor.dart';

import '../support/build_counter.dart';

const Distance _d = Distance(roundResult: false);
final DateTime _t0 = DateTime.utc(2026, 1, 1, 12);
const LatLng _start = LatLng(40.0, -100.0);

Member _driver(int sec, {double speed = 20}) => Member(
      id: 'd',
      name: 'Driver',
      position: _d.offset(_start, 20.0 * sec, 90),
      status: MemberStatus.normal,
      batteryPercent: 80,
      address: 'Driving',
      movement: MovementType.car,
      speedMps: speed,
      headingDeg: 90,
      fixTime: _t0.add(Duration(seconds: sec)),
      lastSeen: _t0.add(Duration(seconds: sec)),
      accuracyMeters: 5,
    );

Member _parked() => Member(
      id: 'p',
      name: 'Parked',
      position: const LatLng(40.0, -99.99),
      status: MemberStatus.normal,
      batteryPercent: 80,
      address: 'Stationary',
      speedMps: 0,
      fixTime: _t0,
      lastSeen: _t0,
      accuracyMeters: 5,
    );

/// Host that, like MapScreen, owns a Ticker and never calls setState.
class _Host extends StatefulWidget {
  const _Host(this.hub, this.roster, this.clock);
  final MemberMotionHub hub;
  final ValueNotifier<List<Member>> roster;
  final _Clock clock;
  @override
  State<_Host> createState() => _HostState();
}

int hostBuilds = 0;

class _HostState extends State<_Host> with SingleTickerProviderStateMixin {
  late final Ticker ticker;
  final MapController mc = MapController();

  @override
  void initState() {
    super.initState();
    ticker = createTicker((Duration e) {
      widget.clock.elapsed = e;
      if (!widget.hub.tick()) ticker.stop();
    });
    widget.roster.addListener(_publish);
    _publish();
  }

  void _publish() {
    if (widget.hub.update(widget.roster.value) && !ticker.isActive) {
      ticker.start();
    }
  }

  @override
  void dispose() {
    widget.roster.removeListener(_publish);
    ticker.dispose();
    widget.hub.reset();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    hostBuilds++;
    return FlutterMap(
      mapController: mc,
      options: const MapOptions(initialCenter: _start, initialZoom: 15),
      children: <Widget>[
        ValueListenableBuilder<List<Member>>(
          valueListenable: widget.roster,
          builder: (_, List<Member> ms, __) => MemberMarkerLayer(
            members: ms,
            expandedClusters: const <String>{},
            onMemberTap: (_) {},
            onClusterTap: (_, __) {},
            motion: widget.hub,
          ),
        ),
      ],
    );
  }
}

/// Fake wall clock: the hub's "now" is t0 + the test's elapsed frame time.
class _Clock {
  Duration elapsed = Duration.zero;
  DateTime now() => _t0.add(elapsed);
}

List<LatLng> _markerPoints(WidgetTester tester) {
  final MarkerLayer layer = tester.widget<MarkerLayer>(find.byType(MarkerLayer));
  return layer.markers.map((Marker m) => m.point).toList();
}

void main() {
  setUp(() {
    hostBuilds = 0;
    PerfMonitor.instance.reset();
  });

  testWidgets('a 1 Hz drive animates smoothly and only the marker layer rebuilds',
      (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final _Clock clock = _Clock();
    final MemberMotionHub hub = MemberMotionHub(clock: clock.now);
    final ValueNotifier<List<Member>> roster =
        ValueNotifier<List<Member>>(<Member>[_driver(0), _parked()]);
    await tester.pumpWidget(
      MaterialApp(home: _Host(hub, roster, clock)),
    );
    await tester.pump();
    final int hostAfterMount = hostBuilds;
    final int clusterStart = MemberMarkerLayer.debugClusterRuns;
    final BuildCounter counter = BuildCounter()..start();

    double? prevEast;
    double maxStep = 0;
    int frames = 0;
    for (int sec = 1; sec <= 12; sec++) {
      roster.value = <Member>[_driver(sec), _parked()];
      // ~60 fps for a second.
      for (int f = 0; f < 60; f++) {
        await tester.pump(const Duration(milliseconds: 16));
        frames++;
        final LatLng drv = _markerPoints(tester).first;
        final double east =
            _d.as(LengthUnit.Meter, _start, LatLng(_start.latitude, drv.longitude));
        if (prevEast != null && sec > 2) {
          final double step = east - prevEast;
          expect(step, greaterThanOrEqualTo(-1e-6));
          if (step > maxStep) maxStep = step;
        }
        prevEast = east;
      }
    }
    counter.stop();
    final int layerBuilds = counter.of('MemberMarkerLayer');
    final int clusterRuns = MemberMarkerLayer.debugClusterRuns - clusterStart;
    // ignore: avoid_print
    print('PERFMETRIC live-drive: $frames frames, max step '
        '${maxStep.toStringAsFixed(2)} m/frame, marker layer builds '
        '$layerBuilds, cluster runs $clusterRuns, MemberAvatarBubble rebuilds '
        '${counter.of('MemberAvatarBubble')}, host builds '
        '${hostBuilds - hostAfterMount}');
    expect(maxStep, lessThan(0.6), reason: '20 m/s at ~60 fps is ~0.33 m');
    // The screen above the layer never rebuilt; neither did cached bubbles'
    // avatars beyond the one new Member instance per fix per mover.
    expect(hostBuilds - hostAfterMount, 0);
    expect(counter.of('StatusAvatar'), lessThanOrEqualTo(12 * 2));
    expect(layerBuilds, greaterThan(0));
    // Clustering ran for the roster changes, not for the animation frames.
    expect(clusterRuns, lessThan(frames ~/ 3));
  });

  testWidgets('idle (nothing moving) costs zero frames and zero rebuilds',
      (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final _Clock clock = _Clock();
    final MemberMotionHub hub = MemberMotionHub(clock: clock.now);
    final ValueNotifier<List<Member>> roster =
        ValueNotifier<List<Member>>(<Member>[_parked()]);
    await tester.pumpWidget(MaterialApp(home: _Host(hub, roster, clock)));
    for (int i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    PerfMonitor.instance.recording = true;
    PerfMonitor.instance.reset();
    final BuildCounter counter = BuildCounter()..start();
    for (int i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    counter.stop();
    PerfMonitor.instance.recording = false;
    expect(counter.counts, isEmpty, reason: 'no widget rebuilt while idle');
    expect(PerfMonitor.instance.animFrames, 0);
    expect(hub.needsFrames, isFalse);
    hub.reset();
  });
}
