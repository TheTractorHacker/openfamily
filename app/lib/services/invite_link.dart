import 'secure_url.dart';

/// A parsed invite link: the server it belongs to and the invite code.
///
/// Two shapes are understood:
///  * `https://<server>/join/<code>` (the shareable link and QR payload), and
///  * `openfamily://join?server=<https url>&code=<code>` (the landing page's
///    "Open in the app" button).
class InviteLink {
  const InviteLink({required this.server, required this.code});

  /// Normalized HTTPS base URL of the server (no trailing slash).
  final String server;

  /// Upper-case invite code with separators removed.
  final String code;

  static final RegExp _codePattern = RegExp(r'^[A-HJ-NP-Z2-9]{8}$');

  /// Upper-cases a code and strips everything but letters and digits.
  static String normalizeCode(String raw) =>
      raw.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

  /// The shareable link for [code] on [server], or null when [server] is not
  /// a valid HTTPS base URL.
  static String? build(String server, String code) {
    final String? base = normalizeHttpsBaseUrl(server);
    final String c = normalizeCode(code);
    if (base == null || c.isEmpty) return null;
    return '$base/join/$c';
  }

  /// Parses [raw] (a link or QR payload). Returns null for anything that is
  /// not a well-formed invite link.
  static InviteLink? parse(String raw) {
    final Uri? uri = Uri.tryParse(raw.trim());
    if (uri == null) return null;
    String? server;
    String? code;
    if (uri.scheme == 'openfamily' && uri.host == 'join') {
      server = uri.queryParameters['server'];
      code = uri.queryParameters['code'];
    } else if (uri.scheme == 'https' &&
        uri.host.isNotEmpty &&
        uri.pathSegments.length >= 2 &&
        uri.pathSegments[uri.pathSegments.length - 2] == 'join') {
      final List<String> segs = uri.pathSegments;
      code = segs.last;
      final String prefix =
          segs.sublist(0, segs.length - 2).map((s) => '/$s').join();
      server = '${uri.scheme}://${uri.authority}$prefix';
    }
    if (server == null || code == null) return null;
    final String? base = normalizeHttpsBaseUrl(server);
    final String c = normalizeCode(code);
    if (base == null || !_codePattern.hasMatch(c)) return null;
    return InviteLink(server: base, code: c);
  }
}
