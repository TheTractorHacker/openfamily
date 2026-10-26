import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../models/member.dart';
import '../services/driving/driving_events_service.dart';
import '../services/location_sharing_service.dart';
import '../services/trip_report_service.dart';
import '../services/trips_service.dart';
import 'family_driving_report_screen.dart';

/// The Driving tab: who is driving now, the weekly/monthly driving report,
/// a per-day chart and the latest drives. Each member card opens that
/// member's [TripsScreen]. Opening the tab also makes sure the server knows
/// the Driving detection opt-in (on by default).
class DrivingTabScreen extends StatefulWidget {
  const DrivingTabScreen({
    super.key,
    required this.members,
    required this.userId,
    this.circleId,
    this.tripsApi,
    this.reportApi,
    this.optInSync,
  });

  final ValueListenable<List<Member>> members;
  final ValueListenable<String?> userId;

  /// Circle chosen on the map; null/absent means unscoped.
  final ValueListenable<String?>? circleId;
  final TripsApi? tripsApi;
  final TripReportApi? reportApi;

  /// Overrides the Driving detection opt-in sync (tests).
  final Future<bool> Function()? optInSync;

  @override
  State<DrivingTabScreen> createState() => _DrivingTabScreenState();
}

class _DrivingTabScreenState extends State<DrivingTabScreen> {
  @override
  void initState() {
    super.initState();
    LocationSharingService.load().catchError((Object _) => true);
  }

  @override
  Widget build(BuildContext context) {
    return FamilyDrivingReportScreen(
      members: widget.members,
      userId: widget.userId,
      circleId: widget.circleId,
      api: widget.reportApi,
      tripsApi: widget.tripsApi,
      sharing: LocationSharingService.enabled,
      optInSync: widget.optInSync ??
          DrivingEventsService(const SessionSensorEventsApi()).syncOptIn,
    );
  }
}
