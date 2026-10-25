import 'dart:async';

import '../models/trip.dart';
import 'api_client.dart';

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
      final Map<String, dynamic> body =
          _map(await ApiClient.getTrips(userId: userId, from: from, to: to));
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
      return TripDetail.fromJson(_map(await ApiClient.getTrip(id)));
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
      return TripSummary.fromResponse(
        _map(
          await ApiClient.getTripsSummary(
            userId: userId,
            period: period,
            date: date,
            speedThresholdMps: speedThresholdMps,
          ),
        ),
      );
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
