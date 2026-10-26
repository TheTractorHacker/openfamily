import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:openfamily/models/member.dart';
import 'package:openfamily/screens/map_screen.dart';
import 'package:openfamily/utils/member_clustering.dart';
import 'package:openfamily/widgets/member_avatar_bubble.dart';

import '../support/build_counter.dart';

List<Member> _roster(int n) => <Member>[
      for (int i = 0; i < n; i++)
        Member(
          id: 'm$i',
          name: 'Person $i',
          position: LatLng(37.0 + i * 3.0, -122.0 + i * 3.0),
          status: MemberStatus.normal,
          batteryPercent: 80,
          address: 'x',
        ),
    ];

/// The previous implementation, kept here only to measure it: a stateless
/// layer that builds brand-new bubble widgets on every camera change.
class _LegacyMarkerLayer extends StatelessWidget {
  const _LegacyMarkerLayer({required this.members});
  final List<Member> members;

  @override
  Widget build(BuildContext context) {
    final MapCamera camera = MapCamera.of(context);
    final List<BubblePlacement> placements = placeBubbles(
      members,
      toScreenOffset: (LatLng l) {
        final p = camera.latLngToScreenPoint(l);
        return Offset(p.x, p.y);
      },
      toLatLng: camera.offsetToCrs,
    );
    return MarkerLayer(markers: <Marker>[
      for (final BubblePlacement p in placements)
        Marker(
          point: p.position,
          width: MemberAvatarBubble.markerWidth,
          height: MemberAvatarBubble.markerSizeFor(p.member!).height,
          child: MemberAvatarBubble(member: p.member!),
        ),
    ]);
  }
}

Future<int> _panAndCount(WidgetTester tester, Widget layer) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final MapController mc = MapController();
  await tester.pumpWidget(MaterialApp(
    home: FlutterMap(
      mapController: mc,
      options: const MapOptions(initialCenter: LatLng(38, -121), initialZoom: 6),
      children: <Widget>[layer],
    ),
  ));
  await tester.pump();
  final BuildCounter c = BuildCounter()..start();
  for (int i = 1; i <= 30; i++) {
    mc.move(LatLng(38 + i * 0.01, -121), 6);
    await tester.pump();
  }
  c.stop();
  return c.of('MemberAvatarBubble');
}

void main() {
  testWidgets('before: legacy layer rebuilds every bubble on every pan frame',
      (tester) async {
    final int n = await _panAndCount(
        tester, _LegacyMarkerLayer(members: _roster(6)));
    // ignore: avoid_print
    print('PERFMETRIC marker-pan-before: 30 pan frames, 6 members -> '
        '$n bubble rebuilds');
    expect(n, greaterThanOrEqualTo(30));
  });

  testWidgets('after: cached bubbles are not rebuilt while panning',
      (tester) async {
    final int n = await _panAndCount(
      tester,
      MemberMarkerLayer(
        members: _roster(6),
        expandedClusters: const <String>{},
        onMemberTap: (_) {},
        onClusterTap: (_, __) {},
      ),
    );
    // ignore: avoid_print
    print('PERFMETRIC marker-pan-after: 30 pan frames, 6 members -> '
        '$n bubble rebuilds');
    expect(n, 0);
  });

  testWidgets('a changed member rebuilds only its own bubble', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final ValueNotifier<List<Member>> roster =
        ValueNotifier<List<Member>>(_roster(6));
    await tester.pumpWidget(MaterialApp(
      home: FlutterMap(
        options:
            const MapOptions(initialCenter: LatLng(38, -121), initialZoom: 6),
        children: <Widget>[
          ValueListenableBuilder<List<Member>>(
            valueListenable: roster,
            builder: (_, List<Member> m, __) => MemberMarkerLayer(
              members: m,
              expandedClusters: const <String>{},
              onMemberTap: (_) {},
              onClusterTap: (_, __) {},
            ),
          ),
        ],
      ),
    ));
    await tester.pump();
    final BuildCounter c = BuildCounter()..start();
    final List<Member> next = List<Member>.of(roster.value);
    next[2] = next[2].copyWith(batteryPercent: 10, address: 'moved');
    roster.value = next;
    await tester.pump();
    c.stop();
    expect(c.of('MemberAvatarBubble'), 1);
  });
}
