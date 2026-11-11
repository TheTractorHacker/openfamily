// The bounded journal and the per-hour counters: both isolates write, neither overwrites the other, the size is
// bounded, and only codes and exception TYPE names are stored.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/diagnostics/tracking_health.dart';
import 'package:openfamily/services/diagnostics/tracking_journal.dart';
import 'package:openfamily/services/diagnostics/tracking_stats.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Clock {
  DateTime t = DateTime.utc(2026, 11, 10, 22, 0);
  DateTime call() => t;
  void tick([Duration d = const Duration(seconds: 1)]) => t = t.add(d);
}

class SecretError implements Exception {
  @override
  String toString() => 'SecretError at lat=52.5201 lon=13.4049 token=abcdef host=family.example.com';
}

void main() {
  late Clock clock;
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    TrackingJournal.setSourceForTest('app');
    clock = Clock();
  });
  tearDown(() => TrackingJournal.setSourceForTest('app'));

  group('journal', () {
    test('records events with time and short detail, oldest first', () async {
      final TrackingJournal j = TrackingJournal(clock: clock.call);
      j.record('service_start_requested');
      clock.tick();
      j.record('permission_changed', 'from=none to=always');
      final List<JournalLine> l = await j.readAll();
      expect(l.map((JournalLine x) => x.event), <String>['service_start_requested', 'permission_changed']);
      expect(l.last.detail, 'from=none to=always');
      expect(l.first.source, 'app');
    });

    test('a repeated event is folded into one line with a count and a last time', () async {
      final TrackingJournal j = TrackingJournal(clock: clock.call);
      for (int i = 0; i < 5; i++) {
        j.record('background_drain_blocked', 'reason=unreadable');
        clock.tick(const Duration(minutes: 10));
      }
      j.record('background_drain_blocked', 'reason=missing'); // another detail: a new line
      final List<JournalLine> l = await j.readAll();
      expect(l.length, 2);
      expect(l.first.count, 5);
      expect(l.first.last, DateTime.utc(2026, 11, 10, 22, 40));
    });

    test('bounded: the chatty lifecycle lines go first, the rare events stay', () async {
      final TrackingJournal j = TrackingJournal(clock: clock.call, maxLines: 10);
      j.record('service_restarted_on_resume');
      for (int i = 0; i < 40; i++) {
        clock.tick();
        j.record(i.isEven ? 'app_paused' : 'app_resumed', 'n=$i');
      }
      clock.tick();
      j.record('permission_changed', 'from=always to=while_in_use');
      final List<JournalLine> l = await j.readAll();
      expect(l.length, 10);
      expect(l.first.event, 'service_restarted_on_resume');
      expect(l.last.event, 'permission_changed');
    });

    test('each isolate writes only its own key, and the reader merges both by time', () async {
      final TrackingJournal app = TrackingJournal(clock: clock.call);
      final TrackingJournal bg = TrackingJournal(clock: clock.call);
      app.record('app_paused');
      await app.readAll();
      clock.tick();
      TrackingJournal.setSourceForTest('bg');
      bg.record('bg_isolate_started');
      await bg.readAll();
      clock.tick();
      TrackingJournal.setSourceForTest('app');
      app.record('app_resumed');
      final List<JournalLine> l = await app.readAll();
      expect(l.map((JournalLine x) => '${x.source}:${x.event}'), <String>['app:app_paused', 'bg:bg_isolate_started', 'app:app_resumed']);
      final SharedPreferences p = await SharedPreferences.getInstance();
      expect(p.getKeys().where((String k) => k.startsWith(TrackingJournal.keyPrefix)).toSet(),
          <String>{'${TrackingJournal.keyPrefix}app', '${TrackingJournal.keyPrefix}bg'});
    });

    test('a permission change is written once, not on every resume', () async {
      final TrackingJournal j = TrackingJournal(clock: clock.call);
      await j.notePermission('always');
      await j.notePermission('always');
      await j.notePermission('while_in_use');
      await j.notePermission('while_in_use');
      final List<JournalLine> l = await j.readAll();
      expect(l.map((JournalLine x) => x.detail), <String>['from=none to=always', 'from=always to=while_in_use']);
    });

    test('details are flattened and clipped', () async {
      final TrackingJournal j = TrackingJournal(clock: clock.call);
      j.record('x', 'a\nb ${'y' * 200}');
      final JournalLine l = (await j.readAll()).single;
      expect(l.detail.contains('\n'), isFalse);
      expect(l.detail.length, lessThanOrEqualTo(63));
    });

    test('a damaged stored value is ignored, not fatal', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{'${TrackingJournal.keyPrefix}app': '{not json'});
      final TrackingJournal j = TrackingJournal(clock: clock.call);
      j.record('app_paused');
      expect((await j.readAll()).single.event, 'app_paused');
    });
  });

  group('counters', () {
    test('count per UTC hour and read back summed', () async {
      final TrackingStats s = TrackingStats(clock: clock.call, flushEvery: Duration.zero);
      s.count(TrackCounter.received);
      s.count(TrackCounter.received);
      s.count(TrackCounter.dropped);
      s.count(TrackCounter.posted, 3);
      clock.tick(const Duration(hours: 1));
      s.count(TrackCounter.sealErr);
      final StatsSnapshot snap = await s.read();
      expect(snap.hours.map((HourCounts h) => h.hour), <String>['2026-11-10T22', '2026-11-10T23']);
      expect(snap.hours[0][TrackCounter.received], 2);
      expect(snap.hours[0][TrackCounter.dropped], 1);
      expect(snap.hours[0][TrackCounter.posted], 3);
      expect(snap.hours[1][TrackCounter.sealErr], 1);
    });

    test('increments held in memory are written by flush, and survive a new instance (a restarted isolate)', () async {
      final TrackingStats a = TrackingStats(clock: clock.call, flushEvery: const Duration(hours: 1));
      a.count(TrackCounter.received); // first write goes out at once, the next ones wait
      a.count(TrackCounter.received);
      a.count(TrackCounter.received);
      await a.flush();
      final TrackingStats b = TrackingStats(clock: clock.call, flushEvery: Duration.zero);
      b.count(TrackCounter.received);
      expect((await b.read()).hours.single[TrackCounter.received], 4);
    });

    test('the two isolates keep separate keys and are summed by the reader', () async {
      final TrackingStats app = TrackingStats(clock: clock.call, flushEvery: Duration.zero);
      final TrackingStats bg = TrackingStats(clock: clock.call, flushEvery: Duration.zero);
      app.count(TrackCounter.parked);
      await app.flush();
      TrackingJournal.setSourceForTest('bg');
      bg.count(TrackCounter.parked, 2);
      bg.noteUploadOk();
      await bg.flush();
      TrackingJournal.setSourceForTest('app');
      final StatsSnapshot snap = await app.read();
      expect(snap.hours.single[TrackCounter.parked], 3);
      expect(snap.lastUploadOkSource, 'bg');
      final SharedPreferences p = await SharedPreferences.getInstance();
      expect(jsonDecode(p.getString('${TrackingStats.keyPrefix}bg')!)['h'], isNotEmpty);
      expect(jsonDecode(p.getString('${TrackingStats.keyPrefix}app')!)['h'].values.first[TrackCounter.parked.index], 1);
    });

    test('only the last 24 hours are kept', () async {
      final TrackingStats s = TrackingStats(clock: clock.call, flushEvery: Duration.zero);
      for (int i = 0; i < 40; i++) {
        s.count(TrackCounter.received);
        await s.flush();
        clock.tick(const Duration(hours: 1));
      }
      final StatsSnapshot snap = await s.read();
      expect(snap.hours.length, TrackingStats.maxHours);
      expect(snap.hours.last.hour, '2026-11-12T13');
    });

    test('the last error keeps its place and the exception TYPE only, never the message', () async {
      final TrackingStats s = TrackingStats(clock: clock.call, flushEvery: Duration.zero);
      s.noteError('post_location', SecretError());
      s.noteSealError(const FormatException('lat=1 lon=2'), code: 'unreadable');
      final StatsSnapshot snap = await s.read();
      expect(snap.lastError!.type, 'SecretError');
      expect(snap.lastError!.where, 'post_location');
      expect(snap.lastSealError!.type, 'FormatException');
      expect(snap.lastSealError!.where, 'seal:unreadable');
      final SharedPreferences p = await SharedPreferences.getInstance();
      final String raw = p.getString('${TrackingStats.keyPrefix}app')!;
      for (final String bad in <String>['52.5201', '13.4049', 'abcdef', 'family.example.com', 'lat=']) {
        expect(raw.contains(bad), isFalse, reason: raw);
      }
    });

    test('a failing callback that fires every second does not write every second', () async {
      final TrackingStats s = TrackingStats(clock: clock.call);
      for (int i = 0; i < 10; i++) {
        s.noteError('location_callback', SecretError());
        clock.tick();
      }
      await s.flush();
      final StatsSnapshot snap = await s.read();
      expect(snap.lastError, isNotNull);
      expect(TrackingStats.errorFlushEvery, greaterThan(const Duration(seconds: 1)));
    });
  });
}
