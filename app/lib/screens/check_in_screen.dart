import 'package:flutter/material.dart';

import '../models/alert.dart';
import '../services/alert_service.dart';
import '../services/api_client.dart';
import 'alert_status_screen.dart';
import '../services/location_service.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';

/// The Check In flow, reached from the map's `+` action sheet.
class CheckInScreen extends StatefulWidget {
  const CheckInScreen({super.key});

  @override
  State<CheckInScreen> createState() => _CheckInScreenState();
}

class _CheckInScreenState extends State<CheckInScreen> {
  final TextEditingController _note = TextEditingController();
  bool _sent = false;
  String? _alertId;
  bool _sending = false;
  String? _error;
  String _locationLabel = 'Finding your location…';
  double? _lat;
  double? _lon;

  @override
  void initState() {
    super.initState();
    _loadLocation();
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _loadLocation() async {
    final position = await LocationService.currentPosition();
    if (!mounted) return;
    if (position == null) {
      setState(() => _locationLabel = 'Last reported location will be used.');
      return;
    }
    setState(() {
      _lat = position.latitude;
      _lon = position.longitude;
      _locationLabel = 'Location found. It is shared when you check in.';
    });
  }

  Future<void> _checkIn() async {
    if (_sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final Map<String, dynamic> body = <String, dynamic>{
        'note': _note.text.trim(),
      };
      if (_lat != null && _lon != null) {
        body['lat'] = _lat;
        body['lon'] = _lon;
      }
      final dynamic response =
          await ApiClient.post('/alerts/check-in', body: body);
      if (response is Map && response['id'] is String) {
        _alertId = response['id'] as String;
      }
      if (!mounted) return;
      setState(() {
        _sent = true;
        _sending = false;
      });
    } on SessionExpiredException {
      return;
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = 'Not sent. ${alertErrorMessage(e)}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = 'Not sent. ${alertErrorMessage(e)}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_sent && _alertId != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Check In')),
        body: SafeArea(
          child: AlertStatusBody(
            alertId: _alertId!,
            kind: AlertKind.checkIn,
            title: 'Checked in',
            footer: <Widget>[
              DsPillButton(
                label: 'Done',
                style: DsPillStyle.tonal,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
      );
    }
    if (_sent) return _buildSent();
    return _buildForm();
  }

  Widget _buildForm() {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return DsPage(
      title: 'Check In',
      actions: <Widget>[
        DsBusyButton(
          label: 'Check In',
          icon: Icons.check,
          busy: _sending,
          onPressed: _sending ? null : _checkIn,
        ),
      ],
      children: <Widget>[
        const DsHeading(
          'Share your location with your family',
          subtitle: 'Your family will see where you are right now.',
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(AppSpace.lg),
          decoration: BoxDecoration(
            color: BrandTheme.of(context).sheet,
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          child: Row(
            children: <Widget>[
              DsListRow.iconTile(context, Icons.my_location),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Text('You', style: AppType.body),
                    const SizedBox(height: AppSpace.xxs),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        _locationLabel,
                        style: AppType.secondary.copyWith(
                          fontSize: 14,
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpace.xl),
        TextField(
          controller: _note,
          maxLines: 3,
          enabled: !_sending,
          decoration: const InputDecoration(
            labelText: 'Add a note (optional)',
            hintText: 'e.g. "Picked up the kids"',
          ),
        ),
        if (_error != null) DsMessage(_error!),
      ],
    );
  }

  Widget _buildSent() {
    return DsPage(
      title: 'Check In',
      showBack: false,
      actions: <Widget>[
        DsPillButton(label: 'Done', onPressed: () => Navigator.of(context).pop()),
      ],
      children: <Widget>[
        const SizedBox(height: AppSpace.xxl),
        const Center(
          child: Icon(Icons.check_circle, size: 72, color: AppColors.statusGreen),
        ),
        const SizedBox(height: AppSpace.lg),
        const DsHeading(
          'Checked in',
          subtitle: 'Your family was notified. Emergency services were NOT contacted.',
          center: true,
        ),
      ],
    );
  }
}
