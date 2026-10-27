import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// Bounds the backend enforces (docs/bubbles.md).
const int kMinBubbleRadiusM = 50;
const int kMaxBubbleRadiusM = 5000;
const int kMinBubbleMinutes = 15;
const int kMaxBubbleMinutes = 24 * 60;

/// Maps a slider position (0..1) to a radius in metres. The scale is
/// logarithmic so the small end (a house, a playground) has as much travel as
/// the large end (a neighbourhood), and the result is rounded to a value that
/// reads well.
int bubbleRadiusFromSlider(double t) {
  final double c = t.clamp(0.0, 1.0);
  final double raw = kMinBubbleRadiusM *
      math.pow(kMaxBubbleRadiusM / kMinBubbleRadiusM, c).toDouble();
  final int step = raw < 200 ? 10 : (raw < 1000 ? 50 : 100);
  final int rounded = (raw / step).round() * step;
  return rounded.clamp(kMinBubbleRadiusM, kMaxBubbleRadiusM);
}

/// Inverse of [bubbleRadiusFromSlider].
double bubbleSliderFromRadius(int meters) {
  final int m = meters.clamp(kMinBubbleRadiusM, kMaxBubbleRadiusM);
  return math.log(m / kMinBubbleRadiusM) /
      math.log(kMaxBubbleRadiusM / kMinBubbleRadiusM);
}

/// "200 m", "1.2 km".
String formatBubbleRadius(int meters) =>
    meters >= 1000 ? '${(meters / 1000).toStringAsFixed(1)} km' : '$meters m';

/// A zoom level at which a circle of [radiusM] metres spans about [fraction]
/// of a map [widthPx] pixels wide, at [latitude].
double bubbleZoomFor(double radiusM, double latitude, double widthPx,
    {double fraction = 0.6}) {
  final double cosLat = math.cos(latitude * math.pi / 180).abs().clamp(0.01, 1.0);
  final double z = math.log(156543.03392 * cosLat * widthPx * fraction /
          (2 * radiusM)) /
      math.ln2;
  return z.clamp(3.0, 18.0);
}

/// One way to choose how long a Bubble lasts.
class BubbleDuration {
  const BubbleDuration(this.label, this.minutes);

  final String label;
  final int minutes;
}

/// The duration choices offered after Continue: 1 h, 4 h, "until tonight"
/// (23:00 local, only while at least [kMinBubbleMinutes] away) and 24 h.
List<BubbleDuration> bubbleDurationOptions(DateTime now) {
  final DateTime n = now.toLocal();
  final DateTime tonight = DateTime(n.year, n.month, n.day, 23);
  final int toTonight = tonight.difference(n).inMinutes;
  return <BubbleDuration>[
    const BubbleDuration('1 hour', 60),
    const BubbleDuration('4 hours', 240),
    if (toTonight >= kMinBubbleMinutes && toTonight < kMaxBubbleMinutes)
      BubbleDuration('Until tonight', toTonight),
    const BubbleDuration('24 hours', 24 * 60),
  ];
}

/// A Bubble the caller created (it carries the circle).
class Bubble {
  const Bubble({
    required this.id,
    required this.subjectId,
    required this.subjectName,
    required this.center,
    required this.radiusM,
    required this.expiresAt,
    this.notifyReenter = false,
    this.inside = true,
  });

  final String id;
  final String subjectId;
  final String subjectName;
  final LatLng center;
  final int radiusM;
  final DateTime expiresAt;
  final bool notifyReenter;
  final bool inside;

  bool expiredAt(DateTime now) => !expiresAt.isAfter(now);

  factory Bubble.fromJson(Map<String, dynamic> json) => Bubble(
        id: json['id'] as String,
        subjectId: json['subject_id'] as String,
        subjectName: (json['subject_name'] as String?) ?? '',
        center: LatLng((json['lat'] as num).toDouble(), (json['lon'] as num).toDouble()),
        radiusM: (json['radius_m'] as num).round(),
        expiresAt: DateTime.parse(json['expires_at'] as String).toLocal(),
        notifyReenter: json['notify_reenter'] == true,
        inside: json['inside'] != false,
      );
}

/// A Bubble drawn around the caller: who and until when, never where.
class BubbleAboutMe {
  const BubbleAboutMe({
    required this.id,
    required this.creatorName,
    required this.expiresAt,
  });

  final String id;
  final String creatorName;
  final DateTime expiresAt;

  factory BubbleAboutMe.fromJson(Map<String, dynamic> json) => BubbleAboutMe(
        id: json['id'] as String,
        creatorName: (json['creator_name'] as String?) ?? '',
        expiresAt: DateTime.parse(json['expires_at'] as String).toLocal(),
      );
}

class BubbleList {
  const BubbleList({
    this.mine = const <Bubble>[],
    this.aboutMe = const <BubbleAboutMe>[],
  });

  final List<Bubble> mine;
  final List<BubbleAboutMe> aboutMe;

  factory BubbleList.fromJson(Map<String, dynamic> json) {
    List<T> parse<T>(Object? v, T Function(Map<String, dynamic>) f) => v is List
        ? <T>[
            for (final Object? e in v)
              if (e is Map<String, dynamic>) f(e),
          ]
        : <T>[];
    return BubbleList(
      mine: parse(json['bubbles'], Bubble.fromJson),
      aboutMe: parse(json['about_me'], BubbleAboutMe.fromJson),
    );
  }

  /// Drops Bubbles that expired while the list was on screen.
  BubbleList withoutExpired(DateTime now) => BubbleList(
        mine: mine.where((Bubble b) => !b.expiredAt(now)).toList(),
        aboutMe: aboutMe.where((BubbleAboutMe b) => b.expiresAt.isAfter(now)).toList(),
      );
}
