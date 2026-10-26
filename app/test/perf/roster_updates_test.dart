// Before/after for a WebSocket burst: 20 location updates, one person moving.
//  - the `members` prop path (parent rebuilds the tab with a new list, what
//    MapScreen.setState did) still works, now with memoised person rows;
//  - the roster listenable: only the People list listens.
// Numbers measured on the unchanged main branch with the same harness:
// burst-members-prop(20 updates): LocationTabView=20 PersonRow=200 DsListRow=220.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:openfamily/models/member.dart';
import 'package:openfamily/theme/app_theme.dart';
import 'package:openfamily/widgets/location_tab_view.dart';

import '../support/build_counter.dart';
import '../support/location_fixtures.dart';
import 'sheet_drag_builds_test.dart' show roster;

const int kUpdates = 20;

Future<void> _open(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Member _moved(Member m, int step) => m.copyWith(
      position: LatLng(m.position!.latitude + step * 0.0001, -122.41),
    );

void main() {
  testWidgets('members prop path: tab rebuilds but only the changed row does',
      (tester) async {
    await _open(tester);
    final ValueNotifier<List<Member>> src =
        ValueNotifier<List<Member>>(roster(10));
    await tester.pumpWidget(MaterialApp(
      theme: buildLightTheme(),
      home: ValueListenableBuilder<List<Member>>(
        valueListenable: src,
        builder: (_, List<Member> ms, __) => LocationTabView(
          map: const FakeMap(),
          circleName: 'Family',
          members: ms,
          selfId: 'm0',
          placesLoader: fakePlaces,
        ),
      ),
    ));
    await tester.pump();
    await tester.fling(find.text('People'), const Offset(0, -500), 2000);
    await tester.pumpAndSettle();

    final BuildCounter c = BuildCounter()..start();
    for (int i = 1; i <= kUpdates; i++) {
      final List<Member> next = List<Member>.of(src.value);
      next[3] = _moved(next[3], i);
      src.value = next;
      await tester.pump();
    }
    c.stop();
    // ignore: avoid_print
    print('PERFMETRIC burst-members-prop($kUpdates updates): '
        'LocationTabView=${c.of('LocationTabView')} '
        'PersonRow=${c.of('_PersonRow')} DsListRow=${c.of('DsListRow')}');
    expect(c.of('LocationTabView'), kUpdates);
    expect(c.of('_PersonRow'), kUpdates);
  });

  testWidgets('after: roster listenable rebuilds only the changed row',
      (tester) async {
    await _open(tester);
    final ValueNotifier<List<Member>> src =
        ValueNotifier<List<Member>>(roster(10));
    await tester.pumpWidget(MaterialApp(
      theme: buildLightTheme(),
      home: LocationTabView(
        map: const FakeMap(),
        circleName: 'Family',
        members: src.value,
        membersListenable: src,
        selfId: 'm0',
        placesLoader: fakePlaces,
      ),
    ));
    await tester.pump();
    await tester.fling(find.text('People'), const Offset(0, -500), 2000);
    await tester.pumpAndSettle();

    final BuildCounter c = BuildCounter()..start();
    for (int i = 1; i <= kUpdates; i++) {
      final List<Member> next = List<Member>.of(src.value);
      next[3] = _moved(next[3], i);
      src.value = next;
      await tester.pump();
    }
    c.stop();
    // ignore: avoid_print
    print('PERFMETRIC burst-listenable($kUpdates updates): '
        'LocationTabView=${c.of('LocationTabView')} '
        'PersonRow=${c.of('_PersonRow')} DsListRow=${c.of('DsListRow')}');
    expect(c.of('LocationTabView'), 0, reason: 'tab chrome must not rebuild');
    expect(c.of('_PersonRow'), kUpdates, reason: 'one row per update');
    expect(find.text('Person 3'), findsOneWidget);
  });

  testWidgets('hidden tab (muted TickerMode) skips roster rebuilds',
      (tester) async {
    await _open(tester);
    final ValueNotifier<List<Member>> src =
        ValueNotifier<List<Member>>(roster(4));
    final ValueNotifier<bool> visible = ValueNotifier<bool>(false);
    await tester.pumpWidget(MaterialApp(
      theme: buildLightTheme(),
      home: ValueListenableBuilder<bool>(
        valueListenable: visible,
        builder: (_, bool v, __) => TickerMode(
          enabled: v,
          child: LocationTabView(
            map: const FakeMap(),
            circleName: 'Family',
            members: src.value,
            membersListenable: src,
            placesLoader: fakePlaces,
          ),
        ),
      ),
    ));
    await tester.pump();

    final BuildCounter c = BuildCounter()..start();
    for (int i = 1; i <= kUpdates; i++) {
      final List<Member> next = List<Member>.of(src.value);
      next[1] = _moved(next[1], i);
      src.value = next;
      await tester.pump();
    }
    expect(c.of('_PersonRow'), 0, reason: 'hidden tab must not rebuild rows');
    visible.value = true;
    await tester.pump();
    c.stop();
    // ignore: avoid_print
    print('PERFMETRIC hidden-tab($kUpdates updates while hidden): '
        'PersonRow rebuilds while hidden=0, on show=${c.of('_PersonRow')}');
    expect(find.text('Person 1'), findsWidgets);
  });
}
