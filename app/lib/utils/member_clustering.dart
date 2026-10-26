import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'package:latlong2/latlong.dart';

import '../models/member.dart';

/// Converts a geographic position to a screen-space offset (logical pixels)
/// at the map's current camera. Used to cluster by on-screen proximity, so
/// bubbles "cluster and separate as people move" *and* as the user zooms.
typedef LatLngToScreenOffset = Offset Function(LatLng latLng);

/// Inverse of [LatLngToScreenOffset]: converts a screen offset back to a
/// geographic position. Used to fan out expanded clusters in screen space so
/// their bubbles stay visually separated at any zoom.
typedef ScreenOffsetToLatLng = LatLng Function(Offset offset);

/// On-screen distance (logical pixels) within which two member bubbles are
/// considered to visually overlap and therefore cluster. Sized to the
/// diameter of a member bubble (~48 px) so bubbles that would overlap merge
/// into a single count bubble.
const double kClusterRadiusPx = 48.0;

/// On-screen radius (logical pixels) of the fan-out ring used to separate
/// clustered members so their bubbles never stack or overlap when expanded.
const double kFanOutRadiusPx = 60.0;

/// A group of members whose bubbles visually overlap at the current zoom.
class MemberCluster {
  const MemberCluster({
    required this.id,
    required this.centroid,
    required this.members,
  });

  /// Stable identifier (sorted member ids) so an expanded cluster can be
  /// tracked across rebuilds.
  final String id;

  /// Geographic centroid of the cluster (average of member positions).
  final LatLng centroid;

  final List<Member> members;
}

/// A single bubble to render on the map: either a lone member, a fanned-out
/// member within an expanded cluster, or a cluster-count bubble.
class BubblePlacement {
  const BubblePlacement({
    required this.position,
    this.member,
    this.clusterCount = 1,
    this.clusterId,
    this.clusterMembers = const [],
  });

  /// Where to pin the bubble.
  final LatLng position;

  /// The member this bubble represents; null when this is a cluster-count
  /// bubble.
  final Member? member;

  /// Number of members represented. Greater than 1 only for cluster-count
  /// bubbles.
  final int clusterCount;

  /// The cluster this count bubble represents (null for member bubbles).
  final String? clusterId;

  /// The members inside a cluster-count bubble, used to render an identity
  /// preview (stacked avatars) instead of a bare count. Empty for member
  /// bubbles.
  final List<Member> clusterMembers;

  bool get isCluster => member == null;
}

/// Groups [members] into clusters by *on-screen* proximity.
///
/// Each member's geographic position is projected to a screen offset via
/// [toScreenOffset] (which reflects the map's current center and zoom), and
/// members are clustered when their screen offsets are within
/// [clusterRadiusPx] of each other. This means the same set of members will
/// cluster at a low zoom and separate as the user zooms in — matching the
/// "cluster and separate as people move" behavior, now also zoom-aware.
List<MemberCluster> clusterMembers(
  List<Member> members, {
  required LatLngToScreenOffset toScreenOffset,
  double clusterRadiusPx = kClusterRadiusPx,
  LatLng Function(Member member)? positionOf,
}) {
  LatLng pos(Member m) => positionOf != null ? positionOf(m) : m.position!;
  // Members without a reported location have no bubble and are skipped.
  final List<Member> positioned =
      members.where((m) => m.position != null).toList();

  final Map<String, Offset> points = <String, Offset>{
    for (final Member m in positioned) m.id: toScreenOffset(pos(m)),
  };

  final List<MemberCluster> clusters = <MemberCluster>[];
  final List<Member> remaining = List<Member>.of(positioned);

  while (remaining.isNotEmpty) {
    final Member seed = remaining.removeAt(0);
    final List<Member> group = <Member>[seed];
    bool changed = true;
    while (changed) {
      changed = false;
      for (int i = remaining.length - 1; i >= 0; i--) {
        final Member m = remaining[i];
        final bool near = group.any(
          (Member g) =>
              _distancePx(points[g.id]!, points[m.id]!) <= clusterRadiusPx,
        );
        if (near) {
          group.add(m);
          remaining.removeAt(i);
          changed = true;
        }
      }
    }
    clusters.add(
      MemberCluster(
        id: _clusterId(group),
        centroid: _centroid(group, pos),
        members: group,
      ),
    );
  }

  return clusters;
}

/// Produces a flat list of [BubblePlacement]s:
///
/// * A lone member stays at its own position.
/// * A cluster (2+) collapses into a single cluster-count bubble.
/// * A cluster whose id is in [expandedClusterIds] fans out around its
///   screen-space centroid (converted back to geographic positions) so each
///   member can be tapped individually without overlapping.
List<BubblePlacement> placeBubbles(
  List<Member> members, {
  required LatLngToScreenOffset toScreenOffset,
  required ScreenOffsetToLatLng toLatLng,
  double clusterRadiusPx = kClusterRadiusPx,
  double fanOutRadiusPx = kFanOutRadiusPx,
  Set<String> expandedClusterIds = const {},
  LatLng Function(Member member)? positionOf,
}) {
  LatLng pos(Member m) => positionOf != null ? positionOf(m) : m.position!;
  final List<MemberCluster> clusters = clusterMembers(
    members,
    toScreenOffset: toScreenOffset,
    clusterRadiusPx: clusterRadiusPx,
    positionOf: positionOf,
  );
  final List<BubblePlacement> placements = <BubblePlacement>[];

  for (final MemberCluster cluster in clusters) {
    if (cluster.members.length == 1) {
      placements.add(
        BubblePlacement(
          position: pos(cluster.members.first),
          member: cluster.members.first,
        ),
      );
    } else if (expandedClusterIds.contains(cluster.id)) {
      final Offset centroid = _screenCentroid(cluster.members, toScreenOffset, pos);
      for (int i = 0; i < cluster.members.length; i++) {
        final double angle = (2 * math.pi * i) / cluster.members.length;
        final Offset offset =
            centroid + Offset.fromDirection(angle, fanOutRadiusPx);
        placements.add(
          BubblePlacement(
            position: toLatLng(offset),
            member: cluster.members[i],
          ),
        );
      }
    } else {
      placements.add(
        BubblePlacement(
          position: cluster.centroid,
          clusterCount: cluster.members.length,
          clusterId: cluster.id,
          clusterMembers: cluster.members,
        ),
      );
    }
  }

  return placements;
}

String _clusterId(List<Member> members) {
  final List<String> ids = members.map((m) => m.id).toList()..sort();
  return ids.join('|');
}

LatLng _centroid(List<Member> members, LatLng Function(Member) pos) {
  double lat = 0;
  double lng = 0;
  for (final Member m in members) {
    final LatLng p = pos(m);
    lat += p.latitude;
    lng += p.longitude;
  }
  return LatLng(lat / members.length, lng / members.length);
}

/// Screen-space centroid of a group of members (average of their projected
/// offsets), used as the fan-out center so expanded bubbles stay visually
/// centered on the cluster.
Offset _screenCentroid(
  List<Member> members,
  LatLngToScreenOffset toScreenOffset,
  LatLng Function(Member) pos,
) {
  double x = 0;
  double y = 0;
  for (final Member m in members) {
    final Offset o = toScreenOffset(pos(m));
    x += o.dx;
    y += o.dy;
  }
  return Offset(x / members.length, y / members.length);
}

double _distancePx(Offset a, Offset b) => (a - b).distance;
