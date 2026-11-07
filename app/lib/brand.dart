/// Product name, tagline and the project links, in one place so a repository
/// rename or a rebrand only touches this file (and scripts/rebrand.sh).
///
/// Internal identifiers (Android applicationId / iOS bundle id `app.openfamily`,
/// the Dart package name `openfamily`, the `openfamily://` link scheme) stay
/// unchanged on purpose; see docs/developers/naming.md.
class Brand {
  const Brand._();

  static const String name = 'Orbitly';
  static const String tagline = 'Your people, in orbit.';
  static const String description =
      'Self-hosted location sharing for your circles.';

  /// This project's source (AGPL-3.0 section 13: source offer for network users).
  static const String sourceUrl = 'https://github.com/TheTractorHacker/orbitly';

  /// The project Orbitly is a fork of. Credit must stay visible in the app.
  static const String upstreamName = 'OpenFamily';
  static const String upstreamUrl = 'https://github.com/wheresfrank/openfamily';
  static const String upstreamCredit =
      'Based on OpenFamily by wheresfrank and contributors (AGPL-3.0)';

  static const String licenseName = 'GNU AGPL-3.0';
}
