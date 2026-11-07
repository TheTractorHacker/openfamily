/// On-device equivalents of the server's trip, driving-report and weekly
/// summary computations (Phase 0 of docs/design/PRIVACY_PROCESSING.md).
/// Pure Dart: no Flutter, no platform channels, safe in a background isolate.
library;

export 'driving_events.dart';
export 'driving_report.dart';
export 'fix.dart';
export 'processing_params.dart';
export 'trip_segmenter.dart';
