import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/circle.dart';
import 'package:openfamily/services/circle_selection.dart';

class _MemStore implements CircleSelectionStore {
  _MemStore([this.value]);
  String? value;
  int writes = 0;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String? circleId) async {
    writes++;
    value = circleId;
  }
}

Circle _c(String id, {bool primary = false, bool sharing = true}) => Circle(
  id: id,
  name: 'Circle $id',
  role: 'member',
  sharingEnabled: sharing,
  memberCount: 2,
  isPrimary: primary,
);

void main() {
  test('zero or one circle: unscoped, nothing to choose', () {
    final sel = CircleSelection(store: _MemStore());
    sel.update(const <Circle>[]);
    expect(sel.effectiveId, isNull);
    sel.update(<Circle>[_c('a', primary: true)]);
    expect(sel.effectiveId, isNull);
    expect(sel.sharingPaused, isFalse);
  });

  test('one circle that is NOT the primary one (made in the app, joined by code) is scoped, not "No family"', () {
    final sel = CircleSelection(store: _MemStore());
    sel.update(<Circle>[_c('foleys')]);
    expect(sel.effectiveId, 'foleys');
    expect(sel.selectedCircle?.name, 'Circle foleys');
    expect(sel.nameOr('No family'), 'Circle foleys');
    // Leaving it empties the list: back to unscoped.
    sel.update(const <Circle>[]);
    expect(sel.effectiveId, isNull);
  });

  test('several circles default to the primary one', () {
    final sel = CircleSelection(store: _MemStore());
    sel.update(<Circle>[_c('a'), _c('b', primary: true)]);
    expect(sel.effectiveId, 'b');
  });

  test('selection persists and is restored on the next launch', () async {
    final store = _MemStore();
    final sel = CircleSelection(store: store);
    sel.update(<Circle>[_c('a', primary: true), _c('b')]);
    expect(sel.select('b'), isTrue);
    expect(store.value, 'b');

    final next = CircleSelection(store: store);
    await next.restore();
    next.update(<Circle>[_c('a', primary: true), _c('b')]);
    expect(next.effectiveId, 'b');
  });

  test('unknown ids are ignored; all is accepted', () {
    final sel = CircleSelection(store: _MemStore());
    sel.update(<Circle>[_c('a', primary: true), _c('b')]);
    expect(sel.select('zzz'), isFalse);
    expect(sel.effectiveId, 'a');
    expect(sel.select(kAllCircles), isTrue);
    expect(sel.isAll, isTrue);
    expect(sel.selectedCircle, isNull);
    expect(sel.nameOr('x'), 'All circles');
  });

  test('a deleted or left circle falls back to the primary one', () {
    final store = _MemStore();
    final sel = CircleSelection(store: store);
    sel.update(<Circle>[_c('a', primary: true), _c('b'), _c('c')]);
    sel.select('c');
    final fell = sel.update(<Circle>[_c('a', primary: true), _c('b')]);
    expect(fell, isTrue);
    expect(sel.effectiveId, 'a');
    // Shown as the primary for now, but the pick is not forgotten: a list can lack a circle for a moment (stale or
    // offline copy). Only removeCircle, where the server said it is gone, replaces what is remembered.
    expect(store.value, 'c');
  });

  test('removeCircle on the last other circle goes back to unscoped', () {
    final sel = CircleSelection(store: _MemStore());
    sel.update(<Circle>[_c('a', primary: true), _c('b')]);
    sel.select('b');
    expect(sel.removeCircle('b'), isTrue);
    expect(sel.effectiveId, isNull); // one circle left
    expect(sel.selectedId, 'a');
  });

  test('a stale remembered id that no longer exists is replaced', () async {
    final sel = CircleSelection(store: _MemStore('gone'));
    await sel.restore();
    sel.update(<Circle>[_c('a', primary: true), _c('b')]);
    expect(sel.effectiveId, 'a');
  });

  test('a list that temporarily lacks the remembered circle does not make the app forget it', () async {
    final store = _MemStore('b');
    final sel = CircleSelection(store: store);
    await sel.restore();
    sel.update(<Circle>[_c('a', primary: true)]); // stale list: no b yet
    expect(sel.effectiveId, isNull);
    sel.update(<Circle>[_c('a', primary: true), _c('c')]); // still no b: fallback shows, b stays remembered
    expect(sel.effectiveId, 'a');
    expect(store.value, 'b');
    expect(sel.update(<Circle>[_c('a', primary: true), _c('b'), _c('c')]), isTrue); // b is back: the map must reload it
    expect(sel.effectiveId, 'b');
    expect(store.value, 'b');
  });

  test('the remembered circle wins even when the list loaded before it was read', () async {
    final store = _MemStore('b');
    final sel = CircleSelection(store: store);
    sel.update(<Circle>[_c('a', primary: true), _c('b')]); // list first: primary fallback
    expect(sel.effectiveId, 'a');
    await sel.restore();
    expect(sel.effectiveId, 'b');
    expect(store.value, 'b');
  });

  test('a pick made before the saved value is read is not overwritten by it', () async {
    final store = _MemStore('b');
    final sel = CircleSelection(store: store);
    sel.update(<Circle>[_c('a', primary: true), _c('b'), _c('c')]);
    sel.select('c');
    await sel.restore();
    expect(sel.effectiveId, 'c');
    expect(store.value, 'c');
  });

  test('sharing paused reflects only the selected circle', () {
    final sel = CircleSelection(store: _MemStore());
    sel.update(<Circle>[_c('a', primary: true), _c('b', sharing: false)]);
    expect(sel.sharingPaused, isFalse);
    sel.select('b');
    expect(sel.sharingPaused, isTrue);
    sel.select(kAllCircles);
    expect(sel.sharingPaused, isFalse);
  });

  test('switching quickly settles on the last pick', () {
    final store = _MemStore();
    final sel = CircleSelection(store: store);
    sel.update(<Circle>[_c('a', primary: true), _c('b'), _c('c')]);
    sel.select('b');
    sel.select('c');
    sel.select('b');
    sel.select('b'); // no-op
    expect(sel.effectiveId, 'b');
    expect(store.value, 'b');
  });
}
