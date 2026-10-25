import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/alert.dart';
import '../services/alert_service.dart';
import '../services/api_client.dart';
import '../services/location_reporter.dart';
import '../services/location_service.dart';
import '../services/server_features.dart';
import '../theme/app_theme.dart';
import 'alert_status_screen.dart';
import 'safety_screen.dart';

/// The SOS flow: a first-run explainer, tap-to-send (with confirm),
/// press-and-hold (discreet countdown), and slide-to-cancel.
///
/// * First open explains that the red button is live and that Practice
///   does not notify anyone. Emergency contacts are added on Safety.
/// * **Tap** asks before sending. **Hold** starts a 10-second countdown;
///   slide left to abort.
/// * **I'm safe** resolves the last real SOS, including after leaving
///   and coming back.
class SosScreen extends StatefulWidget {
  const SosScreen({
    super.key,
    this.smsConfigured,
    this.alertService = const AlertService(),
    this.dialer = const EmergencyDialer(),
  });

  final AlertService alertService;
  final EmergencyDialer dialer;

  /// When null, uses [ServerFeatures.smsConfigured].
  final bool? smsConfigured;

  @override
  State<SosScreen> createState() => _SosScreenState();
}

enum _SosPhase {
  loading,
  intro,
  idle,
  holding,
  countdown,
  practice,
  sending,
  sent,
  practiceDone,
  cancelled,
  resolved,
}

class _SosScreenState extends State<SosScreen> {
  static const String _introKey = 'sos_intro_seen';
  static const String _alertIdKey = 'sos_active_alert_id';
  static const String _alertAtKey = 'sos_active_alert_at';
  static const Duration _activeAlertTtl = Duration(hours: 24);

  _SosPhase _phase = _SosPhase.loading;
  int _countdown = 10;
  Timer? _timer;
  bool _practice = false;
  String? _alertId;
  String? _error;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _restore() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final bool seen = prefs.getBool(_introKey) ?? false;
    final String? storedId = prefs.getString(_alertIdKey);
    final int? sentAtMs = prefs.getInt(_alertAtKey);
    final bool alertFresh = storedId != null &&
        storedId.isNotEmpty &&
        sentAtMs != null &&
        DateTime.now().difference(
              DateTime.fromMillisecondsSinceEpoch(sentAtMs),
            ) <
            _activeAlertTtl;

    if (!mounted) return;
    if (alertFresh) {
      final bool stillActive = await _alertStillActive(storedId);
      if (!mounted) return;
      if (stillActive) {
        setState(() {
          _alertId = storedId;
          _phase = _SosPhase.sent;
        });
        return;
      }
      await _clearStoredAlert();
    } else if (storedId != null) {
      unawaited(_clearStoredAlert());
    }
    if (!mounted) return;
    setState(() {
      _phase = seen ? _SosPhase.idle : _SosPhase.intro;
    });
  }

  /// True when the server still has an active SOS for this id. A missing or
  /// already-resolved row must not keep the "SOS sent" screen up — there is
  /// then nothing for I'm safe to clear.
  Future<bool> _alertStillActive(String id) async {
    try {
      final dynamic response = await ApiClient.get('/alerts/$id');
      if (response is Map &&
          response['type'] == 'sos' &&
          response['status'] == 'active') {
        return true;
      }
      return false;
    } on SessionExpiredException {
      return true;
    } on ApiException catch (e) {
      if (e.status == 404) return false;
      return true;
    } catch (_) {
      return true;
    }
  }

  Future<void> _markIntroSeen() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_introKey, true);
  }

  Future<void> _storeAlert(String id) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_alertIdKey, id);
    await prefs.setInt(_alertAtKey, DateTime.now().millisecondsSinceEpoch);
  }

  Future<void> _clearStoredAlert() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_alertIdKey);
    await prefs.remove(_alertAtKey);
  }

  Future<String?> _storedAlertId() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? storedId = prefs.getString(_alertIdKey);
    final int? sentAtMs = prefs.getInt(_alertAtKey);
    if (storedId == null || storedId.isEmpty || sentAtMs == null) return null;
    if (DateTime.now().difference(
          DateTime.fromMillisecondsSinceEpoch(sentAtMs),
        ) >=
        _activeAlertTtl) {
      return null;
    }
    return storedId;
  }

  Future<void> _continueFromIntro() async {
    await _markIntroSeen();
    if (!mounted) return;
    setState(() => _phase = _SosPhase.idle);
  }

  bool get _smsConfigured =>
      widget.smsConfigured ?? ServerFeatures.instance.smsConfigured;

  Future<void> _openEmergencyContacts() async {
    await _markIntroSeen();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const SafetyScreen()),
    );
    if (!mounted) return;
    setState(() => _phase = _SosPhase.idle);
  }

  void _startPractice() {
    _practice = true;
    _startCountdown();
  }

  void _startCountdown() {
    _timer?.cancel();
    setState(() {
      _phase = _practice ? _SosPhase.practice : _SosPhase.countdown;
      _countdown = 10;
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_countdown <= 1) {
        timer.cancel();
        _send();
      } else {
        setState(() => _countdown--);
      }
    });
  }

  void _send() {
    _timer?.cancel();
    if (_practice) {
      setState(() {
        _phase = _SosPhase.practiceDone;
        _practice = false;
      });
      return;
    }
    unawaited(_sendReal());
  }

  Future<void> _confirmAndSend() async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Send SOS?'),
          content: Text(
            _smsConfigured
                ? 'This alerts your family and emergency contacts with your '
                    'location. Use Practice if you only want to try the countdown.'
                : 'This alerts your family with your location. Use Practice '
                    'if you only want to try the countdown.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.sosRed,
                foregroundColor: Colors.white,
              ),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Send SOS'),
            ),
          ],
        );
      },
    );
    if (confirmed == true && mounted) {
      unawaited(_sendReal());
    }
  }

  Future<void> _sendReal() async {
    setState(() {
      _phase = _SosPhase.sending;
      _error = null;
    });
    try {
      final position = await LocationService.currentPosition();
      final Map<String, dynamic> body = <String, dynamic>{};
      if (position != null) {
        body['lat'] = position.latitude;
        body['lon'] = position.longitude;
      }
      final dynamic response = await ApiClient.post('/alerts/sos', body: body);
      final String? id = _alertIdFrom(response);
      if (id == null || id.isEmpty) {
        throw const ApiException(500, 'SOS sent, but no alert id came back.');
      }
      await _storeAlert(id);
      LocationReporter.startSosBurst();
      if (!mounted) return;
      setState(() {
        _alertId = id;
        _phase = _SosPhase.sent;
        _practice = false;
      });
    } on SessionExpiredException {
      return;
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.status == 429) {
        final String? existing = _alertId ?? await _storedAlertId();
        if (!mounted) return;
        if (existing != null && await _alertStillActive(existing)) {
          if (!mounted) return;
          setState(() {
            _alertId = existing;
            _error = _sendErrorMessage(e);
            _phase = _SosPhase.sent;
          });
          return;
        }
      }
      setState(() {
        _phase = _SosPhase.idle;
        _error = _sendErrorMessage(e);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _phase = _SosPhase.idle;
        _error = 'SOS was not sent. Could not reach the server. Check your '
            'connection and try again, or call emergency services.';
      });
    }
  }

  String? _alertIdFrom(dynamic response) {
    if (response is Map) {
      final Object? id = response['id'];
      if (id is String && id.isNotEmpty) return id;
    }
    return null;
  }

  String _sendErrorMessage(ApiException e) {
    if (e.status == 429) {
      return 'An SOS was already sent recently. Wait a couple of minutes, '
          'or tap I\'m safe if that alert is still active. If you need help '
          'right now, call emergency services.';
    }
    return 'SOS was not sent. ${alertErrorMessage(e, action: 'send SOS')} '
        'You can try again, or call emergency services.';
  }

  void _cancel() {
    _timer?.cancel();
    setState(() {
      _phase = _practice ? _SosPhase.idle : _SosPhase.cancelled;
      _practice = false;
    });
  }

  Future<void> _imSafe() async {
    final String? id = _alertId;
    if (id == null || id.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'There\'s no SOS to resolve. Practice does not send an alert.',
          ),
        ),
      );
      return;
    }
    try {
      await ApiClient.post('/alerts/$id/resolve');
    } on SessionExpiredException {
      return;
    } on ApiException catch (e) {
      if (e.status == 404) {
        await _finishImSafe();
        return;
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
      return;
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Couldn\'t send I\'m safe. Try again.')),
      );
      return;
    }
    await _finishImSafe();
  }

  Future<void> _finishImSafe() async {
    await _clearStoredAlert();
    LocationReporter.stopSosBurst();
    if (!mounted) return;
    setState(() {
      _alertId = null;
      _phase = _SosPhase.resolved;
    });
  }

  void _reset() {
    _timer?.cancel();
    setState(() {
      _phase = _SosPhase.idle;
      _countdown = 10;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('SOS')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: _phase == _SosPhase.sent
                ? [Expanded(child: _buildBody())]
                : [
                    const Spacer(),
                    _buildBody(),
                    const Spacer(),
                  ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    switch (_phase) {
      case _SosPhase.loading:
        return const Center(child: CircularProgressIndicator());
      case _SosPhase.intro:
        return _IntroCard(
          smsConfigured: _smsConfigured,
          onContinue: _continueFromIntro,
          onAddContacts: _openEmergencyContacts,
        );
      case _SosPhase.idle:
      case _SosPhase.holding:
        return _PhaseColumn(
          children: [
            if (_error != null && _phase == _SosPhase.idle) ...[
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.sosRed),
              ),
              const SizedBox(height: 16),
            ],
            _SosButton(
              holding: _phase == _SosPhase.holding,
              onTap: _confirmAndSend,
              onHoldStart: () => setState(() => _phase = _SosPhase.holding),
              onHoldEnd: _startCountdown,
              onHoldCancel: () {
                if (_phase == _SosPhase.holding) {
                  setState(() => _phase = _SosPhase.idle);
                }
              },
            ),
            if (_phase == _SosPhase.idle) ...[
              const SizedBox(height: 8),
              TextButton(
                onPressed: _startPractice,
                style: TextButton.styleFrom(
                  foregroundColor: BrandTheme.of(context).accentInk,
                ),
                child: const Text('Practice SOS'),
              ),
            ],
          ],
        );
      case _SosPhase.countdown:
        return _Countdown(seconds: _countdown, onCancel: _cancel);
      case _SosPhase.practice:
        return _Countdown(
          seconds: _countdown,
          onCancel: _cancel,
          label: 'Practice SOS…',
        );
      case _SosPhase.sending:
        return const _PhaseColumn(
          children: [
            SizedBox(
              width: 48,
              height: 48,
              child: CircularProgressIndicator(color: AppColors.sosRed),
            ),
            SizedBox(height: 16),
            Text('Sending SOS…'),
          ],
        );
      case _SosPhase.sent:
        return AlertStatusBody(
          alertId: _alertId!,
          kind: AlertKind.sos,
          service: widget.alertService,
          dialer: widget.dialer,
          title: 'SOS sent',
          footer: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(_error!),
              ),
            SizedBox(
              height: 48,
              child: FilledButton(
                onPressed: _imSafe,
                child: const Text('I\'m safe'),
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Done'),
            ),
          ],
        );
      case _SosPhase.practiceDone:
        return _ResultCard(
          icon: Icons.check_circle,
          color: BrandTheme.of(context).accentInk,
          title: 'Practice complete',
          subtitle: 'No alert was sent. You are ready to send a real SOS.',
          actionLabel: 'Done',
          onAction: _reset,
        );
      case _SosPhase.cancelled:
        return _ResultCard(
          icon: Icons.info_outline,
          color: BrandTheme.of(context).accentInk,
          title: 'Cancelled',
          subtitle: 'No SOS was sent.',
          actionLabel: 'Back',
          onAction: _reset,
        );
      case _SosPhase.resolved:
        return _ResultCard(
          icon: Icons.check_circle,
          color: AppColors.statusGreen,
          title: 'You\'re safe',
          subtitle: _smsConfigured
              ? 'Your family and emergency contacts were told you\'re safe.'
              : 'Your family was told you\'re safe.',
          actionLabel: 'Done',
          onAction: () => Navigator.of(context).pop(),
        );
    }
  }
}

/// First-run explainer. This is not a settings wizard — it tells the user
/// what the red button actually does before they can fire it.
class _IntroCard extends StatelessWidget {
  const _IntroCard({
    required this.onContinue,
    required this.onAddContacts,
    required this.smsConfigured,
  });

  final VoidCallback onContinue;
  final VoidCallback onAddContacts;
  final bool smsConfigured;

  @override
  Widget build(BuildContext context) {
    final Color muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return _PhaseColumn(
      children: [
        const Icon(Icons.sos, size: 72, color: AppColors.sosRed),
        const SizedBox(height: 16),
        const Text(
          'How SOS works',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        Text(
          smsConfigured
              ? 'The red button sends a real alert to your family and any '
                  'emergency contacts, with your location.'
              : 'The red button sends a real alert to your family, with your location.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 15, color: muted),
        ),
        const SizedBox(height: 10),
        Text(
          smsConfigured
              ? 'Practice runs the countdown only — nobody is notified. '
                  'The shield on the map is where you add emergency contacts, '
                  'not I\'m safe.'
              : 'Practice runs the countdown only — nobody is notified.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 15, color: muted),
        ),
        const SizedBox(height: 24),
        if (smsConfigured) ...[
          FilledButton(
            onPressed: onAddContacts,
            child: const Text('Add emergency contacts'),
          ),
          const SizedBox(height: 8),
        ],
        TextButton(
          onPressed: onContinue,
          style: TextButton.styleFrom(
            foregroundColor: BrandTheme.of(context).accentInk,
          ),
          child: const Text('Continue'),
        ),
      ],
    );
  }
}

/// Centers phase content. The scaffold column stretches this to full
/// width so a long hint line cannot shift the SOS disc.
class _PhaseColumn extends StatelessWidget {
  const _PhaseColumn({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: children,
    );
  }
}

/// The large SOS button: tap to send, press-and-hold to arm discreetly.
/// Stay mounted while [holding] so release can start the countdown.
class _SosButton extends StatelessWidget {
  const _SosButton({
    required this.onTap,
    required this.onHoldStart,
    required this.onHoldEnd,
    required this.onHoldCancel,
    this.holding = false,
  });

  final VoidCallback onTap;
  final VoidCallback onHoldStart;
  final VoidCallback onHoldEnd;
  final VoidCallback onHoldCancel;
  final bool holding;

  static const double _size = 180;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Semantics(
          button: true,
          label: holding
              ? 'SOS armed. Release to start the countdown.'
              : 'SOS. Tap to send a real alert. Press and hold to arm discreetly.',
          child: GestureDetector(
            key: const ValueKey<String>('sos-send-button'),
            behavior: HitTestBehavior.opaque,
            onTap: holding ? null : onTap,
            onLongPressStart: (_) => onHoldStart(),
            onLongPressEnd: (_) => onHoldEnd(),
            onLongPressCancel: onHoldCancel,
            child: Container(
              width: _size,
              height: _size,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.sosRed,
                boxShadow: [
                  BoxShadow(
                    color: AppColors.sosRed.withValues(alpha: 0.32),
                    blurRadius: 28,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: holding
                  ? const SizedBox(
                      width: 48,
                      height: 48,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                      ),
                    )
                  : const Text(
                      'SOS',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 32,
                        height: 1,
                      ),
                    ),
            ),
          ),
        ),
        const SizedBox(height: 24),
        Text(
          holding
              ? 'Keep holding… release to start the countdown'
              : 'Tap to send · press and hold to arm discreetly',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            height: 1.35,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _Countdown extends StatelessWidget {
  const _Countdown({
    required this.seconds,
    required this.onCancel,
    this.label = 'Sending SOS…',
  });

  final int seconds;
  final VoidCallback onCancel;
  final String label;

  @override
  Widget build(BuildContext context) {
    return _PhaseColumn(
      children: [
        Text(
          '$seconds',
          style: const TextStyle(
            fontSize: 96,
            fontWeight: FontWeight.w800,
            color: AppColors.sosRed,
            height: 1,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 16,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 32),
        _SlideToCancel(onCancel: onCancel),
      ],
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.actionLabel,
    required this.onAction,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return _PhaseColumn(
      children: [
        Icon(icon, size: 72, color: color),
        const SizedBox(height: 16),
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 15,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 24),
        FilledButton(onPressed: onAction, child: Text(actionLabel)),
      ],
    );
  }
}

/// A "slide to cancel" control: drag the thumb **left** to cancel.
class _SlideToCancel extends StatefulWidget {
  const _SlideToCancel({required this.onCancel});

  final VoidCallback onCancel;

  @override
  State<_SlideToCancel> createState() => _SlideToCancelState();
}

class _SlideToCancelState extends State<_SlideToCancel> {
  static const double _trackWidth = 280;
  static const double _thumbSize = 48;

  double _drag = 0; // 0..1 (0 = right, 1 = fully slid left)

  @override
  Widget build(BuildContext context) {
    const double maxTravel = _trackWidth - _thumbSize - 8;

    return GestureDetector(
      onHorizontalDragUpdate: (details) {
        setState(() {
          // Swipe LEFT (negative dx) advances the slider.
          _drag = (_drag - details.delta.dx / maxTravel).clamp(0.0, 1.0);
        });
        if (_drag >= 1.0) {
          widget.onCancel();
        }
      },
      child: Container(
        width: _trackWidth,
        height: 56,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(28),
        ),
        child: Stack(
          children: [
            Center(
              child: Text(
                'Slide to Cancel',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Positioned(
              // Thumb starts on the right and moves left as _drag grows.
              left: 4 + maxTravel * (1 - _drag),
              top: 4,
              child: Container(
                width: _thumbSize,
                height: _thumbSize,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: BrandTheme.of(context).sheet,
                  boxShadow: const [
                    BoxShadow(color: Color(0x33000000), blurRadius: 6),
                  ],
                ),
                child: const Icon(
                  Icons.chevron_left,
                  color: AppColors.sosRed,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
