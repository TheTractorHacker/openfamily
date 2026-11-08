import 'dart:async';

import '../models/trip.dart';
import 'api_client.dart';
import 'offline/offline_cache.dart';

/// Why a trips request failed, so screens can pick the right message.
enum TripsFailure { forbidden, notFound, offline, other }

class TripsException implements Exception {
  const TripsException(this.kind, this.message);

  final TripsFailure kind;
  final String message;

  @override
  String toString() => 'TripsException($kind): $message';
}

TripsException mapTripsError(Object e) {
  if (e is TripsException) return e;
  if (e is ApiException) {
    if (e.status == 403) {
      return const TripsException(
        TripsFailure.forbidden,
        'You do not have access to this member\'s trips.',
      );
    }
    if (e.status == 404) {
      return const TripsException(
        TripsFailure.notFound,
        'This member or trip could not be found.',
      );
    }
    if (e.status == 0) {
      return TripsException(TripsFailure.offline, e.message);
    }
    return TripsException(TripsFailure.other, e.message);
  }
  if (e is TimeoutException) {
    return const TripsException(
      TripsFailure.offline,
      'You appear to be offline.',
    );
  }
  return const TripsException(
    TripsFailure.other,
    'Something went wrong loading trips.',
  );
}

/// Seam for the trips API so screens can be tested with a fake.
abstract class TripsApi {
  Future<List<Trip>> listTrips({
    required String userId,
    required DateTime from,
    required DateTime to,
  });
  Future<TripDetail> getTrip(String id);
  Future<TripSummary> summary({
    required String userId,
    required String period,
    DateTime? date,
    double? speedThresholdMps,
  });
  Future<int> compute({required DateTime from, required DateTime to});

  /// The signed-in user's id, or null if unknown (hides self-only actions).
  Future<String?> currentUserId();

  /// Marks (or unmarks) one of the caller's own drives as "I was a passenger":
  /// its events leave their report and score.
  Future<void> setPassenger(String tripId, bool passenger);

  /// Marks one of the caller's own phone-use events as a false alarm (or
  /// restores it).
  Future<void> setEventDismissed(String eventId, bool dismissed);
}

class TripsService implements TripsApi {
  const TripsService();

  static const TripsApi instance = TripsService();

  Map<String, dynamic> _map(dynamic d) {
    if (d is Map<String, dynamic>) return d;
    throw const TripsException(
      TripsFailure.other,
      'Unexpected response from the server.',
    );
  }

  @override
  Future<List<Trip>> listTrips({
    required String userId,
    required DateTime from,
    required DateTime to,
  }) async {
    try {
      // Trips already seen stay readable when the server is down.
      final Map<String, dynamic> body = (await OfflineCache.instance.fetch<Map<String, dynamic>>(
        'trips/$userId/${from.toUtc().toIso8601String()}/${to.toUtc().toIso8601String()}',
        () async => _map(await ApiClient.getTrips(userId: userId, from: from, to: to)),
        encode: (Map<String, dynamic> v) => v,
        decode: (Object? j) => _map(j),
        group: 'trips',
      ))
          .value;
      final Object? rows = body['trips'];
      if (rows is! List) return const <Trip>[];
      return rows.whereType<Map<String, dynamic>>().map(Trip.fromJson).toList();
    } catch (e) {
      throw mapTripsError(e);
    }
  }

  @override
  Future<TripDetail> getTrip(String id) async {
    try {
      final Map<String, dynamic> body = (await OfflineCache.instance.fetch<Map<String, dynamic>>(
        'trip/$id',
        () async => _map(await ApiClient.getTrip(id)),
        encode: (Map<String, dynamic> v) => v,
        decode: (Object? j) => _map(j),
        group: 'trip-detail',
        maxInGroup: 15,
      ))
          .value;
      return TripDetail.fromJson(body);
    } catch (e) {
      throw mapTripsError(e);
    }
  }

  @override
  Future<TripSummary> summary({
    required String userId,
    required String period,
    DateTime? date,
    double? speedThresholdMps,
  }) async {
    try {
      final Map<String, dynamic> body = (await OfflineCache.instance.fetch<Map<String, dynamic>>(
        'trips-summary/$userId/$period/${date?.toUtc().toIso8601String() ?? 'now'}/${speedThresholdMps ?? ''}',
        () async => _map(
          await ApiClient.getTripsSummary(
            userId: userId,
            period: period,
            date: date,
            speedThresholdMps: speedThresholdMps,
          ),
        ),
        encode: (Map<String, dynamic> v) => v,
        decode: (Object? j) => _map(j),
        group: 'trips-summary',
      ))
          .value;
      return TripSummary.fromResponse(body);
    } catch (e) {
      throw mapTripsError(e);
    }
  }

  @override
  Future<void> setPassenger(String tripId, bool passenger) async {
    try {
      await ApiClient.setTripPassenger(tripId, passenger);
    } catch (e) {
      throw mapTripsError(e);
    }
  }

  @override
  Future<void> setEventDismissed(String eventId, bool dismissed) async {
    try {
      await ApiClient.setEventDismissed(eventId, dismissed);
    } catch (e) {
      throw mapTripsError(e);
    }
  }

  @override
  Future<String?> currentUserId() async {
    try {
      return (await ApiClient.getProfile()).id;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<int> compute({required DateTime from, required DateTime to}) async {
    try {
      final Map<String, dynamic> body =
          _map(await ApiClient.computeTrips(from: from, to: to));
      return (body['trips_written'] as num?)?.toInt() ?? 0;
    } catch (e) {
      throw mapTripsError(e);
    }
  }
}
