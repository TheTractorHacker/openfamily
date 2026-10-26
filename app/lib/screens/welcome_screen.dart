import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/dot_grid.dart';
import '../widgets/ds/ds.dart';
import '../widgets/openfamily_brand.dart';
import 'login_screen.dart';
import 'sign_up_screen.dart';

/// The onboarding entry point: three short value-prop pages, then
/// "Create account" and "Sign in".
///
/// Deliberately no map and no location request here: the OS permission
/// prompt belongs in the sequenced permissions step.
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _Page {
  const _Page(this.icon, this.title, this.body);
  final IconData icon;
  final String title;
  final String body;
}

const List<_Page> _pages = <_Page>[
  _Page(
    Icons.location_on_outlined,
    'Know where your family is',
    'See the people you love on one calm map, and let them see you, only '
        'when you share.',
  ),
  _Page(
    Icons.notifications_none,
    'Gentle heads-ups',
    'Get a note when someone arrives home or leaves school. Nothing noisy, '
        'never marketing.',
  ),
  _Page(
    Icons.shield_outlined,
    'Private by design',
    'Self-hosted. No ads. Your location stays in your family, on your own '
        'server.',
  ),
];

class _WelcomeScreenState extends State<WelcomeScreen> {
  final PageController _controller = PageController();
  int _index = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _push(Widget screen) => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => screen),
      );

  @override
  Widget build(BuildContext context) {
    final BrandTheme brand = BrandTheme.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: DotGridBackground(
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                children: <Widget>[
                  const SizedBox(height: AppSpace.xl),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      const OpenFamilyMark(size: 40),
                      const SizedBox(width: AppSpace.md),
                      Flexible(
                        child: Semantics(
                          header: true,
                          child: const Text(
                            'OpenFamily',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  Expanded(
                    child: PageView.builder(
                      controller: _controller,
                      itemCount: _pages.length,
                      onPageChanged: (int i) => setState(() => _index = i),
                      itemBuilder: (BuildContext context, int i) =>
                          _PageView(page: _pages[i]),
                    ),
                  ),
                  Semantics(
                    label: 'Page ${_index + 1} of ${_pages.length}',
                    excludeSemantics: true,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        for (int i = 0; i < _pages.length; i++)
                          AnimatedContainer(
                            duration: AppMotion.of(context, AppMotion.fast),
                            margin: const EdgeInsets.symmetric(
                              horizontal: AppSpace.xs,
                            ),
                            width: i == _index ? 24 : 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: i == _index
                                  ? brand.accent
                                  : cs.onSurface.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(AppSpace.xxl),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        DsPillButton(
                          label: 'Create account',
                          onPressed: () => _push(const SignUpScreen()),
                        ),
                        const SizedBox(height: AppSpace.sm),
                        DsPillButton(
                          label: 'Sign in',
                          style: DsPillStyle.outlined,
                          onPressed: () => _push(const LoginScreen()),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PageView extends StatelessWidget {
  const _PageView({required this.page});
  final _Page page;

  @override
  Widget build(BuildContext context) {
    final BrandTheme brand = BrandTheme.of(context);
    final ColorScheme cs = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.xxl,
        vertical: AppSpace.xxl,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          ExcludeSemantics(
            child: Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                color: brand.accent,
                borderRadius: BorderRadius.circular(AppRadius.xl),
              ),
              child: Icon(page.icon, size: 60, color: brand.onAccent),
            ),
          ),
          const SizedBox(height: AppSpace.xxxl),
          Semantics(
            header: true,
            child: Text(
              page.title,
              textAlign: TextAlign.center,
              style: AppType.title.copyWith(fontSize: 28),
            ),
          ),
          const SizedBox(height: AppSpace.md),
          Text(
            page.body,
            textAlign: TextAlign.center,
            style: AppType.body.copyWith(
              fontWeight: FontWeight.w500,
              color: cs.onSurfaceVariant,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}
