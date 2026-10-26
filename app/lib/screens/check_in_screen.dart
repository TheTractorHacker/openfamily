import 'package:flutter/material.dart';

import '../models/alert.dart';
import '../services/alert_service.dart';
import '../services/api_client.dart';
import 'alert_status_screen.dart';
import '../services/location_service.dart';
import '../theme/app_theme.dart';

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
      _locationLabel =
          '${position.latitude.toStringAsFixed(4)}, ${position.longitude.toStringAsFixed(4)}';
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
    return Scaffold(
      appBar: AppBar(title: const Text('Check In')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _sent && _alertId != null
              ? AlertStatusBody(
                  alertId: _alertId!,
                  kind: AlertKind.checkIn,
                  title: 'Checked in',
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
        const Text(
          'Share your location with your family',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        const Text(
          'Your family will see where you are right now.',
          style: TextStyle(fontSize: 14, color: AppColors.textMuted),
        ),
        const SizedBox(height: 20),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.surfaceTint,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              const Icon(Icons.my_location, color: AppColors.purple, size: 24),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'You',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _locationLabel,
                      style: const TextStyle(
                        fontSize: 13,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _note,
          maxLines: 3,
          enabled: !_sending,
          decoration: const InputDecoration(
            labelText: 'Add a note (optional)',
            hintText: 'e.g. "Picked up the kids"',
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: const TextStyle(color: AppColors.sosRed)),
        ],
        const Spacer(),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _sending ? null : _checkIn,
            child: _sending
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text('Check In'),
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
          'Checked in',
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
