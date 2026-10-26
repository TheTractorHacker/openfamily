import 'package:flutter/material.dart';

import '../models/alert.dart';
import '../services/alert_service.dart';
import '../services/api_client.dart';
import 'alert_status_screen.dart';
import '../services/location_service.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';

/// The Help Alert flow, reached from the map's `+` action sheet.
///
/// Sends a non-emergency help request to the family (distinct from SOS —
/// emergency contacts are not notified).
class HelpAlertScreen extends StatefulWidget {
  const HelpAlertScreen({super.key});

  @override
  State<HelpAlertScreen> createState() => _HelpAlertScreenState();
}

class _HelpAlertScreenState extends State<HelpAlertScreen> {
  bool _sent = false;
  String? _alertId;
  bool _sending = false;
  String? _error;
  double? _lat;
  double? _lon;

  @override
  void initState() {
    super.initState();
    _loadLocation();
  }

  Future<void> _loadLocation() async {
    final position = await LocationService.currentPosition();
    if (!mounted || position == null) return;
    setState(() {
      _lat = position.latitude;
      _lon = position.longitude;
    });
  }

  Future<void> _send() async {
    if (_sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final Map<String, dynamic> body = <String, dynamic>{};
      if (_lat != null && _lon != null) {
        body['lat'] = _lat;
        body['lon'] = _lon;
      }
      final dynamic response =
          await ApiClient.post('/alerts/help', body: body);
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
        appBar: AppBar(title: const Text('Help Alert')),
        body: SafeArea(
          child: AlertStatusBody(
            alertId: _alertId!,
            kind: AlertKind.help,
            title: 'Help alert sent',
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
      title: 'Help Alert',
      actions: <Widget>[
        DsBusyButton(
          label: 'Send Help Alert',
          icon: Icons.campaign_outlined,
          busy: _sending,
          onPressed: _sending ? null : _send,
        ),
      ],
      children: <Widget>[
        Center(
          child: Icon(
            Icons.campaign_outlined,
            size: 56,
            color: BrandTheme.of(context).accentInk,
          ),
        ),
        const SizedBox(height: AppSpace.lg),
        const DsHeading(
          'Ask your family for help',
          subtitle: 'Send a non-emergency help alert with your location. Your '
              'family members get a notification and can see where you are. '
              'Emergency contacts are not texted.',
        ),
        Container(
          padding: const EdgeInsets.all(AppSpace.lg),
          decoration: BoxDecoration(
            color: BrandTheme.of(context).sheet,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: cs.outlineVariant, width: 1.5),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Icon(Icons.sos, color: AppColors.sosRed),
              const SizedBox(width: AppSpace.md),
              Expanded(
                child: Text(
                  'For a real emergency, use SOS instead.',
                  style: AppType.body.copyWith(height: 1.4),
                ),
              ),
            ],
          ),
        ),
        if (_error != null) DsMessage(_error!),
      ],
    );
  }

  Widget _buildSent() {
    return DsPage(
      title: 'Help Alert',
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
          'Help alert sent',
          subtitle: 'Your family was notified. Emergency services were NOT contacted.',
          center: true,
        ),
      ],
    );
  }
}
