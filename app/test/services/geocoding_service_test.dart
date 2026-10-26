import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:openfamily/services/address_suggester.dart';
import 'package:openfamily/services/geocoding_service.dart';
import 'package:openfamily/services/server_features.dart';

import '../support/fake_geocoding.dart';

void main() {
  late FakeGeocodingBackend fake;

  setUp(() {
    fake = FakeGeocodingBackend();
    GeocodingService.backend = fake;
    ServerFeatures.instance.reset();
    ServerFeatures.instance.apply(<String, dynamic>{
      'geocoder': <String, dynamic>{'enabled': true, 'autocomplete': true},
    });
  });

  tearDown(() {
    GeocodingService.backend = const ApiGeocodingBackend();
    ServerFeatures.instance.reset();
  });

  group('parsing', () {
    test('parses results and skips malformed entries', () {
      final List<GeocodeSuggestion> r = GeocodeSuggestion.parseList(<String, dynamic>{
        'results': <dynamic>[
          <String, dynamic>{
            'label': '123 Main St, Springfield, IL',
            'name': '123 Main St',
            'lat': 39.799,
            'lon': -89.65,
            'type': 'house',
          },
          <String, dynamic>{'label': '', 'lat': 1, 'lon': 2},
          <String, dynamic>{'label': 'No coords'},
          <String, dynamic>{'label': 'Out of range', 'lat': 91, 'lon': 0},
          'junk',
          <String, dynamic>{'label': 'Cafe', 'lat': 1, 'lon': 2, 'type': 'weird'},
        ],
      });
      expect(r.length, 2);
      expect(r.first.typeLabel, 'Address');
      expect(r.first.position, const LatLng(39.799, -89.65));
      expect(r.last.name, 'Cafe');
      expect(r.last.typeLabel, 'Place');
    });

    test('parses approximate and matched', () {
      final List<GeocodeSuggestion> r = GeocodeSuggestion.parseList(<String, dynamic>{
        'approximate': true,
        'results': <dynamic>[
          <String, dynamic>{
            'label': 'Old 88 Road, Arkansas',
            'name': 'Old 88 Road',
            'lat': 35.65,
            'lon': -94.25,
            'type': 'street',
            'approximate': true,
            'matched': 'street',
          },
          <String, dynamic>{'label': 'Cafe', 'lat': 1, 'lon': 2, 'type': 'poi'},
        ],
      });
      expect(r.first.approximate, isTrue);
      expect(r.first.matched, 'street');
      expect(r.last.approximate, isFalse);
      expect(r.last.matched, isNull);
    });

    test('non-map or missing results give an empty list', () {
      expect(GeocodeSuggestion.parseList(null), isEmpty);
      expect(GeocodeSuggestion.parseList(<String, dynamic>{'results': 3}), isEmpty);
    });
  });

  group('features flag', () {
    test('disabled by default and for older servers', () {
      ServerFeatures.instance.reset();
      expect(GeocodingService.isEnabled, isFalse);
      ServerFeatures.instance.apply(<String, dynamic>{'tile_url': 'x'});
      expect(GeocodingService.isEnabled, isFalse);
    });

    test('reads geocoder.enabled and autocomplete', () {
      ServerFeatures.instance.apply(<String, dynamic>{
        'geocoder': <String, dynamic>{'enabled': true, 'autocomplete': false},
      });
      expect(GeocodingService.isEnabled, isTrue);
      expect(GeocodingService.isAutocompleteEnabled, isFalse);
    });

    test('facade never calls the backend when disabled', () async {
      ServerFeatures.instance.reset();
      expect(await GeocodingService.reverse(const LatLng(1, 2)), isNull);
      expect(await GeocodingService.search('abc'), isNull);
      expect(fake.reverseCalls, isEmpty);
      expect(fake.suggestQueries, isEmpty);
    });

    test('facade swallows failures', () async {
      fake.failure = GeocodeFailure.offline;
      expect(await GeocodingService.reverse(const LatLng(1, 2)), isNull);
      expect(await GeocodingService.search('abc'), isNull);
    });
  });

  group('AddressSuggester', () {
    test('debounces to one request after 300 ms and enforces 3 chars', () async {
      fake.results = <GeocodeSuggestion>[kMainStreet];
      final AddressSuggester s = AddressSuggester();
      addTearDown(s.dispose);
      s.onTextChanged('12');
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(fake.suggestQueries, isEmpty);
      expect(s.status, SuggestStatus.idle);

      s.onTextChanged('123');
      s.onTextChanged('123 M');
      s.onTextChanged('123 Ma');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(fake.suggestQueries, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(fake.suggestQueries, <String>['123 Ma']);
      expect(s.status, SuggestStatus.ready);
      expect(s.suggestions.single.label, kMainStreet.label);
    });

    test('ignores out-of-order responses', () async {
      final Map<String, Completer<List<GeocodeSuggestion>>> pending =
          <String, Completer<List<GeocodeSuggestion>>>{};
      fake.onSuggest = (String q) =>
          (pending[q] = Completer<List<GeocodeSuggestion>>()).future;
      final AddressSuggester s = AddressSuggester(
        debounce: const Duration(milliseconds: 10),
      );
      addTearDown(s.dispose);

      s.onTextChanged('main');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      s.onTextChanged('main st');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(pending.keys, containsAll(<String>['main', 'main st']));

      pending['main st']!.complete(<GeocodeSuggestion>[kMainStreet]);
      await Future<void>.delayed(Duration.zero);
      pending['main']!.complete(<GeocodeSuggestion>[kLibrary]); // late, stale
      await Future<void>.delayed(Duration.zero);

      expect(s.suggestions.single.label, kMainStreet.label);
    });

    test('clear drops an in-flight response', () async {
      final Completer<List<GeocodeSuggestion>> c =
          Completer<List<GeocodeSuggestion>>();
      fake.onSuggest = (_) => c.future;
      final AddressSuggester s = AddressSuggester(
        debounce: const Duration(milliseconds: 5),
      );
      addTearDown(s.dispose);
      s.onTextChanged('main');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      s.clear();
      c.complete(<GeocodeSuggestion>[kMainStreet]);
      await Future<void>.delayed(Duration.zero);
      expect(s.status, SuggestStatus.idle);
      expect(s.suggestions, isEmpty);
    });

    test('maps failures to friendly statuses', () async {
      final AddressSuggester s = AddressSuggester(
        debounce: const Duration(milliseconds: 5),
      );
      addTearDown(s.dispose);
      for (final MapEntry<GeocodeFailure, SuggestStatus> e
          in <GeocodeFailure, SuggestStatus>{
        GeocodeFailure.offline: SuggestStatus.offline,
        GeocodeFailure.rateLimited: SuggestStatus.rateLimited,
        GeocodeFailure.unavailable: SuggestStatus.error,
      }.entries) {
        fake.failure = e.key;
        s.onTextChanged('main st');
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(s.status, e.value);
      }
      fake.failure = null;
      fake.results = const <GeocodeSuggestion>[];
      s.onTextChanged('nowhere at all');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(s.status, SuggestStatus.empty);
    });

    test('no autocomplete requests when the server disallows it, but submit works',
        () async {
      ServerFeatures.instance.apply(<String, dynamic>{
        'geocoder': <String, dynamic>{'enabled': true, 'autocomplete': false},
      });
      fake.results = <GeocodeSuggestion>[kMainStreet];
      final AddressSuggester s = AddressSuggester(
        debounce: const Duration(milliseconds: 5),
      );
      addTearDown(s.dispose);
      s.onTextChanged('main street');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(fake.suggestQueries, isEmpty);
      s.submit('main street');
      await Future<void>.delayed(Duration.zero);
      expect(fake.suggestQueries, <String>['main street']);
      expect(s.status, SuggestStatus.ready);
    });
  });
}
