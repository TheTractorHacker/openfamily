import '../models/trip_report.dart';
import 'api_client.dart';
import 'offline/offline_cache.dart';
import 'trips_service.dart';

/// Seam for the family driving report so screens can be tested with a fake.
abstract class TripReportApi {
  /// The report for the week (or month) beginning [start] (a local date).
  /// [circleId] null means every circle / the legacy unscoped behaviour.
  Future<TripReport> report({
    required DateTime start,
    String period = 'week',
    String? circleId,
  });

  /// Events detected on one trip.
  Future<List<TripEvent>> tripEvents(String tripId);
}

/// A report source that can fall back to the last saved copy when the server
/// cannot be reached (the app is offline-first). Optional on top of
/// [TripReportApi] so test fakes stay small.
abstract class CachedTripReportApi {
  Future<Cached<TripReport>> reportCached({
    required DateTime start,
    String period = 'week',
    String? circleId,
  });
}

class TripReportService implements TripReportApi, CachedTripReportApi {
  const TripReportService();

  static const TripReportApi instance = TripReportService();

  @override
  Future<TripReport> report({
    required DateTime start,
    String period = 'week',
    String? circleId,
  }) async => (await reportCached(start: start, period: period, circleId: circleId)).value;

  /// The report; when the server cannot be reached, the last copy saved for the
  /// same circle, period and start (marked [Cached.fromCache] with its age).
  @override
  Future<Cached<TripReport>> reportCached({
    required DateTime start,
    String period = 'week',
    String? circleId,
  }) async {
    try {
      final Cached<Map<String, dynamic>> got =
          await OfflineCache.instance.fetch<Map<String, dynamic>>(
        'trip-report/${circleId ?? 'primary'}/$period/${apiDate(start)}',
        () async {
          final dynamic body = await ApiClient.getTripReport(
            period: period,
            start: apiDate(start),
            utcOffsetMinutes: DateTime.now().timeZoneOffset.inMinutes,
            circleId: circleId,
          );
          if (body is! Map<String, dynamic>) {
            throw const TripsException(
              TripsFailure.other,
              'Unexpected response from the server.',
            );
          }
          TripReport.fromJson(body); // refuse to save what cannot be read
          return body;
        },
        encode: (Map<String, dynamic> v) => v,
        decode: (Object? j) => Map<String, dynamic>.from(j! as Map),
        group: 'trip-report',
        maxInGroup: 12,
      );
      return Cached<TripReport>(
        TripReport.fromJson(got.value),
        fromCache: got.fromCache,
        savedAt: got.savedAt,
      );
    } on FormatException {
      throw const TripsException(
        TripsFailure.other,
        'The driving report from the server is invalid.',
      );
    } catch (e) {
      throw mapTripsError(e);
    }
  }

  @override
  Future<List<TripEvent>> tripEvents(String tripId) async {
    try {
      return parseTripEvents(await ApiClient.getTripEvents(tripId));
    } catch (e) {
      throw mapTripsError(e);
    }
  }
}

