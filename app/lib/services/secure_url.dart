/// URL helpers for endpoints that may receive account, location, or map data.
///
/// HTTPS is required so credentials and location-derived requests are not sent
/// over cleartext HTTP.
bool isHttpsUrl(String value) {
  final Uri? uri = Uri.tryParse(value.trim());
  return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty;
}

/// Normalizes a server base URL, returning `null` unless it is a valid HTTPS
/// URL without embedded credentials, query parameters, or a fragment.
String? normalizeHttpsBaseUrl(String value) {
  final String cleaned = value.trim().replaceAll(RegExp(r'/+$'), '');
  final Uri? uri = Uri.tryParse(cleaned);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }
  return cleaned;
}
