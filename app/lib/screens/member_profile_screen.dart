import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../widgets/openfamily_map_layers.dart';
import '../models/member.dart';
import '../services/api_client.dart';
import '../services/location_refresh_service.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';
import '../widgets/member_admin_section.dart';
import '../widgets/member_avatar_bubble.dart';
import '../widgets/live_speed.dart';
import '../widgets/movement_icon.dart';
import '../services/speed_units.dart';
import '../utils/member_status.dart';
import 'day_detail_screen.dart';
import '../widgets/trips_entry_button.dart';

/// A full-screen member profile: battery, location, and driving data, with a
/// purple location-pin "Day Detail" entry point at the bottom that opens the
/// location-history timeline.
///
/// Tapping a member bubble on the map opens this screen (not a modal bottom
/// sheet). Tapping a name in the member list still recenters the map.
class MemberProfileScreen extends StatelessWidget {
  const MemberProfileScreen({super.key, required this.member});

  final Member member;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(member.name)),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                AppSpace.xxl,
                AppSpace.lg,
                AppSpace.xxl,
                AppSpace.xxl,
              ),
              children: [
                // Header: avatar + name + status (icon and words).
                Row(
                  children: [
                    StatusAvatar(member: member, size: 64),
                    const SizedBox(width: AppSpace.lg),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Semantics(
                            header: true,
                            child: Text(member.name, style: AppType.title),
                          ),
                          const SizedBox(height: AppSpace.xs),
                          Text(
                            member.status.description,
                            style: AppType.secondary.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (member.position != null) ...[
                  const SizedBox(height: AppSpace.xl),
                  // A live map pinning the member, with the blue circle
                  // showing the range (GPS accuracy) around their fix.
                  _AccuracyMapPreview(member: member),
                ],
                const SizedBox(height: AppSpace.xl),
                DsRowGroup(
                  children: [
                    _DetailRow(
                      icon: DsListRow.iconTile(
                        context,
                        _batteryIcon(),
                        color: _batteryColor(),
                      ),
                      label: 'Battery',
                      value: member.batteryPercent > 0
                          ? '${member.batteryPercent}%'
                          : 'Offline',
                    ),
                    _DetailRow(
                      icon: DsListRow.iconTile(context, Icons.schedule),
                      label: 'ETA',
                      value: member.eta ?? '—',
                    ),
                    member.movement == MovementType.car
                        ? LiveSpeedBuilder(
                            member: member,
                            builder: (BuildContext _, double? mps,
                                    UnitSystem units) =>
                                _DetailRow(
                              icon: _MovementTile(member: member),
                              label: 'Status',
                              value: _drivingStatus(mps, units),
                            ),
                          )
                        : _DetailRow(
                            icon: _MovementTile(member: member),
                            label: 'Status',
                            value: _drivingStatus(),
                          ),
                    _DetailRow(
                      icon: DsListRow.iconTile(
                        context,
                        Icons.gps_fixed,
                        color: AppColors.accuracyBlue,
                      ),
                      label: 'Accuracy',
                      value: _accuracyLabel,
                    ),
                    if (member.placePresence != null)
                      _DetailRow(
                        icon: DsListRow.iconTile(context, Icons.home_outlined),
                        label: 'Place',
                        value: placePresenceLabel(member.placePresence!),
                      ),
                    _DetailRow(
                      icon: DsListRow.iconTile(context, Icons.place_outlined),
                      label: 'Address',
                      value: member.address,
                    ),
                  ],
                ),
                MemberAdminSection(
                  memberId: member.id,
                  memberName: member.name,
                ),
                const SizedBox(height: AppSpace.lg),
                _LocationRefreshButton(memberId: member.id),
                const SizedBox(height: AppSpace.lg),
                DsRowGroup(
                  children: [
                    // Day Detail (location history) entry point.
                    _DayDetailButton(member: member),
                    TripsEntryButton(member: member),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  IconData _batteryIcon() {
    if (member.batteryPercent <= 0) return Icons.battery_unknown;
    if (member.batteryPercent <= 20) return Icons.battery_1_bar;
    if (member.batteryPercent <= 50) return Icons.battery_3_bar;
    if (member.batteryPercent <= 80) return Icons.battery_5_bar;
    return Icons.battery_full;
  }

  Color _batteryColor() {
    if (member.batteryPercent <= 0) return AppColors.statusGrey;
    if (member.batteryPercent <= 20) return AppColors.statusRed;
    if (member.batteryPercent <= 50) return AppColors.statusOrange;
    return AppColors.statusGreen;
  }

  String _drivingStatus([double? mps, UnitSystem units = UnitSystem.imperial]) {
    final double? v = mps ?? member.speedMps;
    if (member.movement == MovementType.car && v != null) {
      final String speed = units.formatSpeed(v);
      return isSpeedingMps(v) ? 'Speeding · $speed' : 'Driving · $speed';
    }
    if (member.movement == MovementType.none) return 'Not moving';
    return member.movement.label;
  }

  /// Human-readable GPS accuracy label (e.g. "± 45 m"), or "—" when the member
  /// has never reported a location.
  String get _accuracyLabel {
    if (member.position == null) return '—';
    final double? acc = member.accuracyMeters;
    if (acc == null || acc <= 0) return 'Unknown';
    final int metres = acc < 1 ? 1 : acc.round();
    return '± $metres m';
  }
}

class _LocationRefreshButton extends StatefulWidget {
  const _LocationRefreshButton({required this.memberId});

  final String memberId;

  @override
  State<_LocationRefreshButton> createState() => _LocationRefreshButtonState();
}

class _LocationRefreshButtonState extends State<_LocationRefreshButton> {
  bool _sending = false;
  String? _status;

  Future<void> _request() async {
    if (_sending) return;
    setState(() {
      _sending = true;
      _status = 'Requesting a fresh location…';
    });
    try {
      final Map<String, dynamic> response =
          await LocationRefreshService.request(widget.memberId);
      if (!mounted) return;
      final String status = response['status'] as String? ?? 'queued';
      setState(() {
        _status = switch (status) {
          'cooldown' => 'A recent location request is still cooling down.',
          'coalesced' => 'A location request is already in progress.',
          _ => 'Request sent. The map will update when the phone responds.',
        };
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _status = error.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _status = 'Could not request a location right now.');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        DsBusyButton(
          label: 'Update location',
          icon: Icons.refresh,
          style: DsPillStyle.tonal,
          busy: _sending,
          onPressed: _request,
        ),
        if (_status != null)
          DsMessage(
            _status!,
            tone: _sending ? DsTone.info : DsTone.success,
          ),
      ],
    );
  }
}

/// A compact map pinning a single member with a blue circle that shows the
/// range (GPS accuracy) around their current position.
class _AccuracyMapPreview extends StatelessWidget {
  const _AccuracyMapPreview({required this.member});

  final Member member;

  @override
  Widget build(BuildContext context) {
    final LatLng center = member.position!;
    final double metres = _radiusFor();
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: SizedBox(
        height: 200,
        width: double.infinity,
        child: FlutterMap(
          options: MapOptions(
            initialCenter: center,
            initialZoom: 15,
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
            ),
          ),
          children: [
            const OpenFamilyTileLayer(),
            CircleLayer(
              circles: [
                CircleMarker(
                  point: center,
                  radius: metres,
                  useRadiusInMeter: true,
                  color: AppColors.accuracyBlue.withValues(alpha: 0.12),
                  borderColor: AppColors.accuracyBlue.withValues(alpha: 0.5),
                  borderStrokeWidth: 2,
                ),
              ],
            ),
            MarkerLayer(
              markers: [
                Marker(
                  point: center,
                  width: 44,
                  height: 44,
                  alignment: Alignment.center,
                  child: StatusAvatar(member: member, size: 40),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  double _radiusFor() {
    final double? acc = member.accuracyMeters;
    if (acc == null || acc <= 0) {
      return member.status == MemberStatus.gpsIssue ? 300.0 : 50.0;
    }
    return acc;
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final Widget icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return DsListRow(
      leading: icon,
      title: value,
      subtitle: label,
      semanticLabel: '$label: $value',
    );
  }
}

/// Movement glyph in the same tile shape as the other detail rows.
class _MovementTile extends StatelessWidget {
  const _MovementTile({required this.member});

  final Member member;

  @override
  Widget build(BuildContext context) {
    final BrandTheme brand = BrandTheme.of(context);
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: brand.accentInk.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Center(
        child: member.movement == MovementType.none
            ? Icon(
                Icons.pause_circle_outline,
                size: 22,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              )
            : MovementIcon(movement: member.movement, size: 22),
      ),
    );
  }
}

/// The "Day Detail" entry point opening the location-history timeline.
class _DayDetailButton extends StatelessWidget {
  const _DayDetailButton({required this.member});

  final Member member;

  @override
  Widget build(BuildContext context) {
    return DsListRow(
      leading: DsListRow.iconTile(context, Icons.location_on),
      title: 'Day Detail',
      subtitle: 'Location history',
      chevron: true,
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => DayDetailScreen(member: member),
          ),
        );
      },
    );
  }
}
