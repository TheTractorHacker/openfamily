import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/member.dart';
import 'package:openfamily/services/family_service.dart';

String _members(List<String> ids) => jsonEncode(<String, dynamic>{
      'type': 'members',
      'members': <Map<String, dynamic>>[
        for (final String id in ids)
          <String, dynamic>{
            'id': id,
            'name': id,
            'role': 'member',
            'lat': 1.0,
            'lon': 2.0,
            'ts': DateTime.now().toUtc().toIso8601String(),
          },
      ],
    });

String _loc(String id, double lat) => jsonEncode(<String, dynamic>{
      'type': 'location',
      'user_id': id,
      'lat': lat,
      'lon': 2.0,
      'ts': DateTime.now().toUtc().toIso8601String(),
    });

void main() {
  testWidgets('a burst of 50 location frames in 1 s makes ~4-5 UI updates',
      (tester) async {
    final FamilyService svc = FamilyService();
    int ui = 0;
    List<Member> last = const <Member>[];
    svc.onMembersChanged = (List<Member> m) {
      ui++;
      last = m;
    };
    svc.debugHandleFrame(_members(<String>['a', 'b']));
    expect(ui, 1, reason: 'snapshots are delivered immediately');
    ui = 0;

    for (int i = 0; i < 50; i++) {
      svc.debugHandleFrame(_loc('a', 10.0 + i));
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pump(FamilyService.uiCoalesceWindow);
    // ignore: avoid_print
    print('PERFMETRIC ws-burst: 50 frames in 1.0 s -> $ui UI updates '
        '(before: 50)');
    expect(ui, inInclusiveRange(4, 6));
    // The newest data always lands.
    expect(last.firstWhere((Member m) => m.id == 'a').position!.latitude, 59.0);
    svc.dispose();
  });

  testWidgets('first frame after a quiet period is not delayed',
      (tester) async {
    final FamilyService svc = FamilyService();
    int ui = 0;
    svc.onMembersChanged = (_) => ui++;
    svc.debugHandleFrame(_members(<String>['a']));
    ui = 0;
    svc.debugHandleFrame(_loc('a', 5));
    expect(ui, 1);
    await tester.pump(const Duration(seconds: 1));
    svc.debugHandleFrame(_loc('a', 6));
    expect(ui, 2);
    svc.dispose();
  });

  testWidgets('a snapshot cancels a pending coalesced update', (tester) async {
    final FamilyService svc = FamilyService();
    final List<int> sizes = <int>[];
    svc.onMembersChanged = (List<Member> m) => sizes.add(m.length);
    svc.debugHandleFrame(_members(<String>['a']));
    svc.debugHandleFrame(_loc('a', 5)); // delivered
    svc.debugHandleFrame(_loc('a', 6)); // pending
    svc.debugHandleFrame(_members(<String>['a', 'b'])); // snapshot, immediate
    expect(sizes.last, 2);
    final int n = sizes.length;
    await tester.pump(const Duration(seconds: 1));
    expect(sizes.length, n, reason: 'no stale trailing delivery');
    svc.dispose();
  });

  testWidgets('dispose cancels the coalesce timer', (tester) async {
    final FamilyService svc = FamilyService();
    svc.onMembersChanged = (_) {};
    svc.debugHandleFrame(_members(<String>['a']));
    svc.debugHandleFrame(_loc('a', 5));
    svc.debugHandleFrame(_loc('a', 6));
    svc.dispose();
    // A leaked Timer would fail the test at teardown.
  });
}
