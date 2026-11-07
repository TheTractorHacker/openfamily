import 'dart:async';

import 'package:flutter/material.dart';

import '../services/battery_optimization_service.dart';
import '../services/onboarding_service.dart';
import '../services/permission_service.dart';
import '../theme/app_theme.dart';
import 'create_circle_screen.dart';
import 'invite_screen.dart';
import 'join_circle_screen.dart';

/// Short, skippable first-run walkthrough. Shown once per user per device
/// (see [OnboardingService]) and replayable from Settings.
///
/// Every action is an injectable callback so tests never touch platform
/// plugins; the defaults call the app's existing services and screens.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({
    super.key,
    required this.userId,
    this.requestLocation,
    this.requestNotifications,
    this.openBatterySettings,
    this.openInvite,
    this.openJoin,
    this.openCreate,
    this.persist = true,
  });

  final String userId;

  /// Persist "seen" on Skip/Done. Replays pass true as well; harmless.
  final bool persist;

  final Future<void> Function()? requestLocation;
  final Future<void> Function()? requestNotifications;
  final Future<void> Function()? openBatterySettings;
  final VoidCallback? openInvite;
  final VoidCallback? openJoin;
  final VoidCallback? openCreate;

  /// Pushes the walkthrough as a full-screen route.
  static Future<void> show(BuildContext context, String userId) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => OnboardingScreen(userId: userId),
        ),
      );

  /// Shows the walkthrough if this user has not seen it on this device.
  static Future<void> maybeShow(BuildContext context, String userId) async {
    if (!OnboardingService.claimCheck(userId)) return;
    final bool seen = await OnboardingService.hasSeen(userId);
    if (seen || !context.mounted) return;
    await show(context, userId);
  }

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _controller = PageController();
  int _page = 0;
  static const int _count = 5;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    if (widget.persist) await OnboardingService.markSeen(widget.userId);
    if (mounted) Navigator.of(context).maybePop();
  }

  void _next() {
    if (_page >= _count - 1) {
      unawaited(_finish());
      return;
    }
    _controller.nextPage(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  void _push(Widget w) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => w));

  Future<void> _run(Future<void> Function()? override, Future<void> Function() d) =>
      (override ?? d)();

  List<_PageData> _pages() => <_PageData>[
        _PageData(
          icon: Icons.family_restroom,
          title: 'Welcome to Orbitly',
          body: 'Orbitly helps the people in your circles see where everyone is and keep '
              'each other safe.\n\nYour location goes only to your own server '
              'and the circle you choose to share with. No one else sees it.',
        ),
        _PageData(
          icon: Icons.my_location,
          title: 'Share your location',
          body: 'Choose precise location, and when asked, "Allow all the '
              'time". That lets Orbitly keep your place up to date in the '
              'background, so your people still see you when the app is '
              'closed.',
          actions: <_Action>[
            _Action(
              'Allow location',
              Icons.location_on_outlined,
              () => _run(
                widget.requestLocation,
                () => PermissionService.request(OnboardingPermission.location)
                    .then((_) {}),
              ),
            ),
          ],
        ),
        _PageData(
          icon: Icons.notifications_active_outlined,
          title: 'Alerts and background updates',
          body: 'Turn on notifications to hear about check-ins, arrivals and '
              'emergencies. On Android, also let Orbitly run freely in the '
              'background (the "Background updates" setting) so updates are '
              'not paused to save battery.',
          actions: <_Action>[
            _Action(
              'Allow notifications',
              Icons.notifications_outlined,
              () => _run(
                widget.requestNotifications,
                () => PermissionService.request(
                        OnboardingPermission.notifications)
                    .then((_) {}),
              ),
            ),
            if (widget.openBatterySettings != null ||
                BatteryOptimizationService.isSupported)
              _Action(
                'Background updates',
                Icons.battery_alert_outlined,
                () => _run(
                  widget.openBatterySettings,
                  () => BatteryOptimizationService.openSettings().then((_) {}),
                ),
              ),
          ],
        ),
        _PageData(
          icon: Icons.groups_outlined,
          title: 'Your circle',
          body: 'A circle is the group of people you share with. Create one, '
              'or join one with an invite code or QR code. Then invite '
              'someone so they can share back.',
          actions: <_Action>[
            _Action(
              'Create a circle',
              Icons.add_circle_outline,
              () async =>
                  (widget.openCreate ?? () => _push(const CreateCircleScreen()))(),
            ),
            _Action(
              'Join with a code',
              Icons.qr_code_scanner,
              () async =>
                  (widget.openJoin ?? () => _push(const JoinCircleScreen()))(),
            ),
            _Action(
              'Invite someone',
              Icons.person_add_alt_1_outlined,
              () async =>
                  (widget.openInvite ?? () => _push(const InviteScreen()))(),
            ),
          ],
        ),
        _PageData(
          icon: Icons.health_and_safety_outlined,
          title: 'Check in and get help',
          body: 'Tap the + button on the map and choose Check In to let your '
              'circle know you are okay. In an emergency, open the Safety tab '
              'and use SOS to alert everyone in your circle at once.\n\nYou '
              'can replay this walkthrough any time from Settings.',
        ),
      ];

  @override
  Widget build(BuildContext context) {
    final List<_PageData> pages = _pages();
    final bool last = _page == _count - 1;
    final ThemeData theme = Theme.of(context);
    final BrandTheme brand = BrandTheme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: TextButton(
                  onPressed: _finish,
                  child: const Text('Skip'),
                ),
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _controller,
                itemCount: _count,
                onPageChanged: (int i) => setState(() => _page = i),
                itemBuilder: (BuildContext c, int i) => _PageView(
                  data: pages[i],
                  accent: brand.accentInk,
                ),
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                for (int i = 0; i < _count; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: i == _page ? 20 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: i == _page
                          ? brand.accentInk
                          : theme.colorScheme.outlineVariant,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _next,
                  child: Text(last ? 'Done' : 'Next'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Action {
  const _Action(this.label, this.icon, this.onTap);
  final String label;
  final IconData icon;
  final Future<void> Function() onTap;
}

class _PageData {
  const _PageData({
    required this.icon,
    required this.title,
    required this.body,
    this.actions = const <_Action>[],
  });
  final IconData icon;
  final String title;
  final String body;
  final List<_Action> actions;
}

class _PageView extends StatelessWidget {
  const _PageView({required this.data, required this.accent});
  final _PageData data;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(data.icon, size: 56, color: accent),
          const SizedBox(height: 20),
          Text(data.title, style: text.headlineSmall),
          const SizedBox(height: 12),
          Text(data.body, style: text.bodyLarge),
          const SizedBox(height: 20),
          for (final _Action a in data.actions)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: a.onTap,
                  icon: Icon(a.icon),
                  label: Text(a.label),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
