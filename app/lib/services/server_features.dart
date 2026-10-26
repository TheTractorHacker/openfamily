/// Runtime capability flags from the operator's `GET /config`.
///
/// Emergency contacts only receive SOS by SMS, so the Safety UI is hidden
/// unless [smsConfigured] is true.
class ServerFeatures {
  ServerFeatures._();

  static final ServerFeatures instance = ServerFeatures._();

  bool smsConfigured = false;

  /// Server-side address search (`geocoder.enabled` in `/config`). Older
  /// servers omit it, which means "off".
  bool geocoderEnabled = false;

  /// Whether search-as-you-type is allowed (false on the public Nominatim,
  /// whose policy forbids it; only explicit searches work there).
  bool geocoderAutocomplete = false;

  /// Applies `sms_configured` from a `/config` body.
  ///
  /// Older servers omit the field; assume SMS may be on so existing
  /// deployments keep showing contacts until the backend is updated.
  void apply(Map<String, dynamic> cfg) {
    final Object? geo = cfg['geocoder'];
    if (geo is Map) {
      geocoderEnabled = geo['enabled'] == true;
      geocoderAutocomplete = geocoderEnabled && geo['autocomplete'] == true;
    } else {
      geocoderEnabled = false;
      geocoderAutocomplete = false;
    }
    if (cfg.containsKey('sms_configured')) {
      smsConfigured = cfg['sms_configured'] == true;
    } else {
      smsConfigured = true;
    }
  }

  void reset() {
    smsConfigured = false;
    geocoderEnabled = false;
    geocoderAutocomplete = false;
  }
}
