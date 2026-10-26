import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/member.dart';
import 'package:openfamily/services/family_service.dart';

String _members(String? circle, List<String> names) => jsonEncode(<String, dynamic>{
  'type': 'members',
  if (circle != null) 'circle_id': circle,
  'members': <Map<String, dynamic>>[
    for (final String n in names)
      <String, dynamic>{
        'id': 'id-$n',
        'name': n,
        'role': 'member',
        'lat': 1.0,
        'lon': 2.0,
        'ts': '2026-01-01T00:00:00Z',
      },
  ],
});

String _loc(String id, String? circle, double lat) => jsonEncode(<String, dynamic>{
  'type': 'location',
  'user_id': id,
  if (circle != null) 'circle_id': circle,
  'lat': lat,
  'lon': 2.0,
  'ts': '2026-01-01T00:00:00Z',
});

void main() {
  test('frameInScope: unlabelled always applies, labelled must match', () {
    expect(FamilyService.frameInScope(null, null), isTrue);
    expect(FamilyService.frameInScope('c1', null), isTrue);
    expect(FamilyService.frameInScope('c1', 'c1'), isTrue);
    expect(FamilyService.frameInScope('c1', 'c2'), isFalse);
    expect(FamilyService.frameInScope('all', 'c2'), isTrue);
    expect(FamilyService.frameInScope(null, 'c2'), isTrue);
  });

  test('a snapshot or update for another circle is dropped', () {
    final svc = FamilyService()..scopeTo('c1');
    List<Member> last = const <Member>[];
    svc.onMembersChanged = (m) => last = m;

    svc.debugHandleFrame(_members('c2', <String>['Zed'])); // late, old circle
    expect(svc.members, isEmpty);

    svc.debugHandleFrame(_members('c1', <String>['Ann', 'Bob']));
    expect(svc.members.map((m) => m.name), <String>['Ann', 'Bob']);
    expect(last.length, 2);

    // Per-circle copies: only the c1 copy moves the pin.
    svc.debugHandleFrame(_loc('id-Ann', 'c2', 50));
    expect(svc.members.first.position!.latitude, 1.0);
    svc.debugHandleFrame(_loc('id-Ann', 'c1', 9));
    expect(svc.members.first.position!.latitude, 9.0);
  });

  test('all scope accepts every labelled frame; legacy frames still work', () {
    final svc = FamilyService()..scopeTo('all');
    svc.debugHandleFrame(_members('all', <String>['Ann']));
    expect(svc.members.length, 1);
    svc.debugHandleFrame(_loc('id-Ann', 'c9', 7));
    expect(svc.members.first.position!.latitude, 7.0);

    final legacy = FamilyService();
    legacy.debugHandleFrame(_members(null, <String>['Ann']));
    legacy.debugHandleFrame(_loc('id-Ann', null, 3));
    expect(legacy.members.first.position!.latitude, 3.0);
  });

  test('circle_removed and a circle_not_found error report the circle gone', () {
    final gone = <String>[];
    final svc = FamilyService(onCircleGone: gone.add)..scopeTo('c1');
    svc.debugHandleFrame(jsonEncode(<String, String>{
      'type': 'circle_removed',
      'circle_id': 'c3',
    }));
    svc.debugHandleFrame(jsonEncode(<String, String>{
      'type': 'error',
      'code': 'circle_not_found',
    }));
    expect(gone, <String>['c3', 'c1']);
  });

  test('sharing frame notifies the owner', () {
    var n = 0;
    final svc = FamilyService()..onSharingChanged = () => n++;
    svc.debugHandleFrame(jsonEncode(<String, dynamic>{
      'type': 'sharing',
      'circle_id': 'c1',
      'user_id': 'u',
      'enabled': false,
    }));
    expect(n, 1);
  });
}
