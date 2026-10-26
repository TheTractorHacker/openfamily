import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/alert.dart';
import '../services/alert_service.dart';
import '../services/api_client.dart';
import '../services/location_reporter.dart';
import '../services/location_service.dart';
import '../services/server_features.dart';
import '../theme/app_theme.dart';
import '../widgets/ds/ds.dart';
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
    // Felt confirmation that the SOS is armed.
    unawaited(HapticFeedback.heavyImpact());
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
    unawaited(HapticFeedback.vibrate());
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
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: _phase == _SosPhase.sent
                ? Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpace.sm,
                    ),
                    child: _buildBody(),
                  )
                : LayoutBuilder(
                    // Content is centred when it fits and scrolls when text
                    // is large, so no action is ever squeezed or clipped.
                    builder: (BuildContext c, BoxConstraints box) =>
                        SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpace.xxl,
                        vertical: AppSpace.lg,
                      ),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          minHeight: box.maxHeight - 2 * AppSpace.lg,
                        ),
                        child: Center(child: _buildBody()),
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    switch (_phase) {
      case _SosPhase.loading:
        return Semantics(
          label: 'Loading SOS',
          child: const DsSkeletonList(rows: 2, avatar: false),
        );
      case _SosPhase.intro:
        return _IntroCard(
          smsConfigured: _smsConfigured,
          onContinue: _continueFromIntro,
          onAddContacts: _openEmergencyContacts,
        );
      case _SosPhase.idle:
      case _SosPhase.holding:
        return _PhaseColumn(
          children: <Widget>[
            if (_error != null && _phase == _SosPhase.idle) ...<Widget>[
              DsMessage(_error!),
              const SizedBox(height: AppSpace.lg),
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
            if (_phase == _SosPhase.idle) ...<Widget>[
              const SizedBox(height: AppSpace.lg),
              Text(
                _smsConfigured
                    ? 'This alerts your family and emergency contacts. It '
                        'does not call emergency services.'
                    : 'This alerts your family. It does not call emergency '
                        'services.',
                textAlign: TextAlign.center,
                style: AppType.body.copyWith(
                  fontWeight: FontWeight.w500,
                  height: 1.35,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              if (widget.dialer.available) ...<Widget>[
                const SizedBox(height: AppSpace.lg),
                EmergencyCallButton(
                  key: const ValueKey<String>('sos-call-button'),
                  dialer: widget.dialer,
                  onPressed: _callEmergency,
                ),
              ],
              const SizedBox(height: AppSpace.sm),
              DsPillButton(
                label: 'Practice SOS',
                style: DsPillStyle.outlined,
                onPressed: _startPractice,
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
        return Semantics(
          liveRegion: true,
          child: const _PhaseColumn(
            children: <Widget>[
              Center(
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: CircularProgressIndicator(color: AppColors.sosRed),
                ),
              ),
              SizedBox(height: AppSpace.lg),
              Text(
                'Sending SOS…',
                textAlign: TextAlign.center,
                style: AppType.headline,
              ),
            ],
          ),
        );
      case _SosPhase.sent:
        return AlertStatusBody(
          alertId: _alertId!,
          kind: AlertKind.sos,
          service: widget.alertService,
          dialer: widget.dialer,
          title: 'SOS sent',
          footer: <Widget>[
            if (_error != null) DsMessage(_error!, tone: DsTone.info),
            const SizedBox(height: AppSpace.sm),
            DsPillButton(label: 'I\'m safe', onPressed: _imSafe),
            const SizedBox(height: AppSpace.sm),
            DsPillButton(
              label: 'Done',
              style: DsPillStyle.tonal,
              onPressed: () => Navigator.of(context).pop(),
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

  Future<void> _callEmergency() async {
    final bool ok = await widget.dialer.dial();
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Could not open the phone app. Dial your local emergency '
            'number yourself.',
          ),
        ),
      );
    }
  }
}

/// First-run explainer. This is not a settings wizard: it tells the user
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
    final TextStyle para = AppType.body.copyWith(
      fontWeight: FontWeight.w500,
      height: 1.4,
      color: muted,
    );
    return _PhaseColumn(
      children: <Widget>[
        const Center(
          child: Icon(Icons.sos, size: 72, color: AppColors.sosRed),
        ),
        const SizedBox(height: AppSpace.lg),
        const DsHeading('How SOS works', center: true),
        Text(
          smsConfigured
              ? 'The red button sends a real alert to your family and any '
                  'emergency contacts, with your location.'
              : 'The red button sends a real alert to your family, with your location.',
          textAlign: TextAlign.center,
          style: para,
        ),
        const SizedBox(height: AppSpace.md),
        Text(
          smsConfigured
              ? 'Practice runs the countdown only — nobody is notified. '
                  'The shield on the map is where you add emergency contacts, '
                  'not I\'m safe.'
              : 'Practice runs the countdown only — nobody is notified.',
          textAlign: TextAlign.center,
          style: para,
        ),
        const SizedBox(height: AppSpace.xxl),
        if (smsConfigured) ...<Widget>[
          DsPillButton(
            label: 'Add emergency contacts',
            onPressed: onAddContacts,
          ),
          const SizedBox(height: AppSpace.sm),
        ],
        DsPillButton(
          label: 'Continue',
          style: smsConfigured ? DsPillStyle.tonal : DsPillStyle.filled,
          onPressed: onContinue,
        ),
      ],
    );
  }
}

/// Centers phase content. The scaffold stretches this to full width so a
/// long hint line cannot shift the SOS disc.
class _PhaseColumn extends StatelessWidget {
  const _PhaseColumn({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
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

  static const double _size = 200;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Semantics(
          button: true,
          label: holding
              ? 'SOS armed. Release to start the countdown.'
              : 'SOS. Tap to send a real alert. Press and hold to arm discreetly.',
          onTap: holding ? null : onTap,
          excludeSemantics: true,
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
                border: Border.all(color: Colors.white, width: 4),
                boxShadow: <BoxShadow>[
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
                      child: CircularProgressIndicator(color: Colors.white),
                    )
                  : const Text(
                      'SOS',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 44,
                        height: 1,
                      ),
                    ),
            ),
          ),
        ),
        const SizedBox(height: AppSpace.xl),
        Text(
          holding
              ? 'Keep holding… release to start the countdown'
              : 'Tap to send · press and hold to arm discreetly',
          textAlign: TextAlign.center,
          style: AppType.body.copyWith(
            fontWeight: FontWeight.w500,
            color: Theme.of(context).colorScheme.onSurface,
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
      children: <Widget>[
        Semantics(
          label: '$label $seconds seconds',
          excludeSemantics: true,
          child: Text(
            '$seconds',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 96,
              fontWeight: FontWeight.w800,
              color: AppColors.sosRed,
              height: 1,
            ),
          ),
        ),
        const SizedBox(height: AppSpace.sm),
        Text(
          label,
          textAlign: TextAlign.center,
          style: AppType.headline.copyWith(
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: AppSpace.xxxl),
        _SlideToCancel(onCancel: onCancel),
        const SizedBox(height: AppSpace.md),
        DsPillButton(
          label: 'Cancel',
          style: DsPillStyle.outlined,
          semanticLabel: 'Cancel SOS',
          onPressed: onCancel,
        ),
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
      children: <Widget>[
        Center(child: Icon(icon, size: 72, color: color)),
        const SizedBox(height: AppSpace.lg),
        DsHeading(title, subtitle: subtitle, center: true),
        DsPillButton(label: actionLabel, onPressed: onAction),
      ],
    );
  }
}

/// A "slide to cancel" control: drag the thumb **left** to cancel. A plain
/// Cancel button sits under it for people who cannot drag.
class _SlideToCancel extends StatefulWidget {
  const _SlideToCancel({required this.onCancel});

  final VoidCallback onCancel;

  @override
  State<_SlideToCancel> createState() => _SlideToCancelState();
}

class _SlideToCancelState extends State<_SlideToCancel> {
  static const double _maxTrack = 320;
  static const double _thumbSize = 48;

  double _drag = 0; // 0..1 (0 = right, 1 = fully slid left)

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        final double track = box.maxWidth.isFinite
            ? box.maxWidth.clamp(_thumbSize * 3, _maxTrack).toDouble()
            : _maxTrack;
        final double maxTravel = track - _thumbSize - 8;
        return Center(
          child: Semantics(
            label: 'Slide left to cancel',
            onTap: widget.onCancel,
            excludeSemantics: true,
            child: GestureDetector(
              onHorizontalDragUpdate: (DragUpdateDetails details) {
                setState(() {
                  // Swipe LEFT (negative dx) advances the slider.
                  _drag = (_drag - details.delta.dx / maxTravel).clamp(
                    0.0,
                    1.0,
                  );
                });
                if (_drag >= 1.0) widget.onCancel();
              },
              child: Container(
                width: track,
                height: 56,
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                ),
                child: Stack(
                  children: <Widget>[
                    Center(
                      child: Text(
                        'Slide to Cancel',
                        style: AppType.body.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                    Positioned(
                      // Thumb starts on the right and moves left.
                      left: 4 + maxTravel * (1 - _drag),
                      top: 4,
                      child: Container(
                        width: _thumbSize,
                        height: _thumbSize,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: BrandTheme.of(context).sheet,
                          boxShadow: const <BoxShadow>[
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
            ),
          ),
        );
      },
    );
  }
}
