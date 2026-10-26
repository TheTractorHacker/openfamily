import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../models/member.dart';
import '../services/trip_report_service.dart';
import '../services/trips_service.dart';
import 'family_driving_report_screen.dart';

/// The Driving tab: the family's weekly driving report. Each member card
/// opens that member's [TripsScreen] (trips, detail and driving report).
class DrivingTabScreen extends StatelessWidget {
  const DrivingTabScreen({
    super.key,
    required this.members,
    required this.userId,
    this.circleId,
    this.tripsApi,
    this.reportApi,
  });

  final ValueListenable<List<Member>> members;
  final ValueListenable<String?> userId;

  /// Circle chosen on the map; null/absent means unscoped.
  final ValueListenable<String?>? circleId;
  final TripsApi? tripsApi;
  final TripReportApi? reportApi;

  @override
  Widget build(BuildContext context) {
    return FamilyDrivingReportScreen(
      members: members,
      userId: userId,
      circleId: circleId,
      api: reportApi,
      tripsApi: tripsApi,
    );
  }
}
