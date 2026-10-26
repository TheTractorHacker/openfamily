import '../models/trip_report.dart';
import 'api_client.dart';
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

class TripReportService implements TripReportApi {
  const TripReportService();

  static const TripReportApi instance = TripReportService();

  @override
  Future<TripReport> report({
    required DateTime start,
    String period = 'week',
    String? circleId,
  }) async {
    try {
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
      return TripReport.fromJson(body);
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

