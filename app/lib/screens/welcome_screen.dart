import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../widgets/openfamily_map_layers.dart';
import '../theme/app_theme.dart';
import '../widgets/openfamily_brand.dart';
import 'login_screen.dart';
import 'sign_up_screen.dart';

/// The onboarding entry point: a brand hero with "Get Started" (sign-up) and
/// "Log In" (existing users).
///
/// Map-first: a subtle, non-interactive live map sits behind the hero so the
/// brand promise ("know where your family is") is visible from the first
/// screen. The map is a neutral world view — it deliberately does NOT request
/// the user's location here, because the OS permission prompt belongs in the
/// sequenced permissions step (requesting it here would leak a dialog out of
/// the flow and double-prompt on iOS).
class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  /// Neutral world view for the hero map (no location request on this screen).
  static const LatLng _center = LatLng(0, 0);
  static const double _zoom = 2;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Subtle map background (non-interactive).
          Positioned.fill(
            child: FlutterMap(
              options: const MapOptions(
                initialCenter: _center,
                initialZoom: _zoom,
                interactionOptions: InteractionOptions(
                  flags: InteractiveFlag.none,
                ),
              ),
              children: [
                const OpenFamilyTileLayer(),
              ],
            ),
          ),
          // Soft wash so the hero text stays readable over the map. Kept light
          // (0.55) so the map-first promise reads through — the map is the
          // hero, not a faint backdrop.
          Positioned.fill(
            child: Container(color: Colors.white.withValues(alpha: 0.55)),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Spacer(),
                  const Center(
                    child: OpenFamilyMark(
                      size: 112,
                      brightness: Brightness.light,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'OpenFamily',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                          // Map wash is always light; Night onSurface is white.
                          color: AppColors.iceInk,
                        ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Know where your family is — privately.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 16, color: AppColors.iceMuted),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Self-hosted. No ads. Your location stays in your family.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: AppColors.iceMuted),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const SignUpScreen(),
                      ),
                    ),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 14),
                      child:
                          Text('Get Started', style: TextStyle(fontSize: 16)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.iceInk,
                    ),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const LoginScreen(),
                      ),
                    ),
                    child: const Text('Log In'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
