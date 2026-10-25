import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../widgets/openfamily_map_layers.dart';
import '../models/member.dart';
import '../services/api_client.dart';
import '../services/location_refresh_service.dart';
import '../theme/app_theme.dart';
import '../widgets/member_avatar_bubble.dart';
import '../widgets/movement_icon.dart';
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
    return Scaffold(
      appBar: AppBar(title: Text(member.name)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        children: [
          // Header: avatar + name + status.
          Row(
            children: [
              StatusAvatar(member: member, size: 64),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      member.name,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      member.status.description,
                      style: TextStyle(
                        fontSize: 14,
                        color: member.status.color,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (member.position != null) ...[
            const SizedBox(height: 20),
            // A live map pinning the member, with the blue circle showing the
            // range (GPS accuracy) around their fix.
            _AccuracyMapPreview(member: member),
          ],
          const SizedBox(height: 24),
          _DetailRow(
            icon: Icon(_batteryIcon(), size: 22, color: _batteryColor()),
            label: 'Battery',
            value: member.batteryPercent > 0
                ? '${member.batteryPercent}%'
                : 'Offline',
          ),
          _DetailRow(
            icon: const Icon(Icons.schedule, size: 22, color: AppColors.purple),
            label: 'ETA',
            value: member.eta ?? '—',
          ),
          _DetailRow(
            icon: MovementIcon(
              movement: member.movement,
              size: 22,
              color: member.movement == MovementType.none
                  ? Theme.of(context).colorScheme.onSurfaceVariant
                  : null,
            ),
            label: 'Status',
            value: _drivingStatus(),
          ),
          _DetailRow(
            icon: const Icon(
              Icons.gps_fixed,
              size: 22,
              color: AppColors.accuracyBlue,
            ),
            label: 'Accuracy',
            value: _accuracyLabel,
          ),
          _DetailRow(
            icon: const Icon(
              Icons.place_outlined,
              size: 22,
              color: AppColors.purple,
            ),
            label: 'Address',
            value: member.address,
          ),
          const SizedBox(height: 16),
          _LocationRefreshButton(memberId: member.id),
          const SizedBox(height: 12),
          // Day Detail (location history) entry point.
          _DayDetailButton(member: member),
          const SizedBox(height: 12),
          TripsEntryButton(member: member),
        ],
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

  String _drivingStatus() {
    if (member.movement == MovementType.car && member.speedMph != null) {
      final String speed = '${member.speedMph} mph';
      return member.isSpeeding ? 'Speeding · $speed' : 'Driving · $speed';
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
        OutlinedButton.icon(
          onPressed: _sending ? null : _request,
          icon: _sending
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh),
          label: const Text('Update location'),
        ),
        if (_status != null) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            _status!,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
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
      borderRadius: BorderRadius.circular(16),
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          SizedBox(width: 22, child: Center(child: icon)),
          const SizedBox(width: 14),
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

/// The purple location-pin "Day Detail" entry point at the bottom of the
/// profile, opening the location-history timeline.
class _DayDetailButton extends StatelessWidget {
  const _DayDetailButton({required this.member});

  final Member member;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: BrandTheme.of(context).sheet,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => DayDetailScreen(member: member),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(
                Icons.location_on,
                color: BrandTheme.of(context).accentInk,
                size: 24,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Day Detail',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: BrandTheme.of(context).accentInk,
                  ),
                ),
              ),
              Text(
                'Location history',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.chevron_right,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
