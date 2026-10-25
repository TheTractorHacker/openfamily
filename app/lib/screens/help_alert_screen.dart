import 'package:flutter/material.dart';

import '../models/alert.dart';
import '../services/alert_service.dart';
import '../services/api_client.dart';
import 'alert_status_screen.dart';
import '../services/location_service.dart';
import '../theme/app_theme.dart';

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
    return Scaffold(
      appBar: AppBar(title: const Text('Help Alert')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _sent && _alertId != null
              ? AlertStatusBody(
                  alertId: _alertId!,
                  kind: AlertKind.help,
                  title: 'Help alert sent',
                  footer: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Done'),
                    ),
                  ],
                )
              : _sent
                  ? _buildSent()
                  : _buildForm(),
        ),
      ),
    );
  }

  Widget _buildForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.campaign_outlined, size: 56, color: AppColors.purple),
        const SizedBox(height: 16),
        const Text(
          'Ask your family for help',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        const Text(
          'Send a non-emergency help alert with your location. Your family '
          'members get a notification and can see where you are. Emergency '
          'contacts are not texted.',
          style: TextStyle(fontSize: 14, color: AppColors.textMuted),
        ),
        const SizedBox(height: 8),
        const Text(
          'For a real emergency, use SOS instead.',
          style: TextStyle(
            fontSize: 13,
            color: AppColors.sosRed,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 16),
          Text(_error!, style: const TextStyle(color: AppColors.sosRed)),
        ],
        const Spacer(),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _sending ? null : _send,
            child: _sending
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text('Send Help Alert'),
          ),
        ),
      ],
    );
  }

  Widget _buildSent() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.check_circle, size: 72, color: AppColors.statusGreen),
        const SizedBox(height: 16),
        const Text(
          'Help alert sent',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        const Text(
          'Your family was notified. Emergency services were NOT contacted.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 15, color: AppColors.textMuted),
        ),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
