import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/sync_service.dart';

void main() {
  test('first call is full, later calls ask with the cursor and merge', () async {
    final List<Map<String, String>> asked = <Map<String, String>>[];
    final List<dynamic> replies = <dynamic>[
      <String, dynamic>{
        'cursor': 'c1',
        'full': true,
        'items': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'a', 'lat': 1}, <String, dynamic>{'id': 'b', 'lat': 2},
        ],
        'ids': <String>['a', 'b'],
      },
      <String, dynamic>{
        'cursor': 'c2',
        'full': false,
        'items': <Map<String, dynamic>>[<String, dynamic>{'id': 'b', 'lat': 5}],
        'ids': <String>['a', 'b'],
      },
      <String, dynamic>{
        'cursor': 'c3',
        'full': false,
        'items': <Map<String, dynamic>>[],
        'ids': <String>['b'], // a was removed
      },
    ];
    final DeltaSync sync = DeltaSync(
      path: '/family/members',
      query: const <String, String>{'circle_id': 'all', 'view': 'compact'},
      fetch: (String p, Map<String, String> q) async {
        asked.add(q);
        return replies.removeAt(0);
      },
    );
    expect((await sync.refresh()).length, 2);
    expect(sync.lastWasDelta, isFalse);
    expect(asked[0]['since'], 'none');

    final List<Map<String, dynamic>> second = await sync.refresh();
    expect(asked[1]['since'], 'c1');
    expect(asked[1]['view'], 'compact');
    expect(sync.lastWasDelta, isTrue);
    expect(second.firstWhere((Map<String, dynamic> m) => m['id'] == 'b')['lat'], 5);

    final List<Map<String, dynamic>> third = await sync.refresh();
    expect(third.map((Map<String, dynamic> m) => m['id']), <String>['b']);
    expect(sync.cursor, 'c3');
  });

  test('an older server that answers with a plain array still works', () async {
    final DeltaSync sync = DeltaSync(
      path: '/family/places',
      fetch: (String p, Map<String, String> q) async => <dynamic>[
        <String, dynamic>{'id': 'x'},
      ],
    );
    expect((await sync.refresh()).single['id'], 'x');
    expect(sync.cursor, isNull);
    expect(sync.lastWasDelta, isFalse);
    await sync.refresh();
    expect(sync.items.length, 1);
  });

  test('reset forgets the cursor', () async {
    final DeltaSync sync = DeltaSync(
      path: '/p',
      fetch: (String p, Map<String, String> q) async => <String, dynamic>{
        'cursor': 'k', 'full': true, 'items': <dynamic>[], 'ids': <dynamic>[],
      },
    );
    await sync.refresh();
    expect(sync.cursor, 'k');
    sync.reset();
    expect(sync.cursor, isNull);
    expect(sync.items, isEmpty);
  });
}
