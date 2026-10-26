import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import 'geocoding_service.dart';

enum SuggestStatus { idle, loading, ready, empty, offline, rateLimited, error }

/// Debounced address autocomplete.
///
/// Waits [debounce] after the last keystroke, ignores queries shorter than
/// [minChars], and numbers every request so a slow, stale response can never
/// overwrite a newer one (or resurface after [clear]).
class AddressSuggester extends ChangeNotifier {
  AddressSuggester({
    this.debounce = const Duration(milliseconds: 300),
    this.minChars = 3,
    GeocodingBackend? backend,
    this.nearProvider,
  }) : _backend = backend;

  final Duration debounce;
  final int minChars;
  final GeocodingBackend? _backend;

  /// Optional bias point (the current pin).
  final LatLng? Function()? nearProvider;

  Timer? _timer;
  int _generation = 0;
  bool _disposed = false;

  SuggestStatus status = SuggestStatus.idle;
  List<GeocodeSuggestion> suggestions = const <GeocodeSuggestion>[];

  /// True when the current list came from an explicit search (changes the
  /// wording of the "nothing found" message).
  bool lastExplicit = false;
  String _lastQuery = '';

  /// True when every shown hit is approximate (street/town, not the house).
  bool get approximate =>
      suggestions.isNotEmpty && suggestions.every((GeocodeSuggestion s) => s.approximate);

  /// Re-runs the last search (offline / error "Try again").
  void retry() {
    if (_lastQuery.isEmpty) return;
    unawaited(_run(_lastQuery, explicit: lastExplicit));
  }

  bool get visible => status != SuggestStatus.idle;

  /// Call on every user edit of the address field.
  void onTextChanged(String text) {
    _timer?.cancel();
    final String q = text.trim();
    if (q.length < minChars || !GeocodingService.isAutocompleteEnabled) {
      clear();
      return;
    }
    _timer = Timer(debounce, () => _run(q, explicit: false));
  }

  /// Immediate search for an explicit submit (works without autocomplete).
  void submit(String text) {
    _timer?.cancel();
    final String q = text.trim();
    if (q.length < minChars) {
      clear();
      return;
    }
    unawaited(_run(q, explicit: true));
  }

  Future<void> _run(String q, {required bool explicit}) async {
    final int gen = ++_generation;
    _lastQuery = q;
    lastExplicit = explicit;
    _set(SuggestStatus.loading, suggestions);
    try {
      final GeocodingBackend b = _backend ?? GeocodingService.backend;
      final List<GeocodeSuggestion> r = await b.suggest(
        q,
        near: nearProvider?.call(),
        explicit: explicit,
      );
      if (gen != _generation) return; // stale
      _set(r.isEmpty ? SuggestStatus.empty : SuggestStatus.ready, r);
    } on GeocodeException catch (e) {
      if (gen != _generation) return;
      _set(
        switch (e.failure) {
          GeocodeFailure.offline => SuggestStatus.offline,
          GeocodeFailure.rateLimited => SuggestStatus.rateLimited,
          GeocodeFailure.unavailable => SuggestStatus.error,
        },
        const <GeocodeSuggestion>[],
      );
    } catch (_) {
      if (gen != _generation) return;
      _set(SuggestStatus.error, const <GeocodeSuggestion>[]);
    }
  }

  /// Hides the list and invalidates any in-flight request.
  void clear() {
    _timer?.cancel();
    _generation++;
    _set(SuggestStatus.idle, const <GeocodeSuggestion>[]);
  }

  void _set(SuggestStatus s, List<GeocodeSuggestion> list) {
    if (_disposed) return;
    status = s;
    suggestions = list;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
