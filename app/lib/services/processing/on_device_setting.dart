import '../e2ee/private_channel.dart' show ChannelKv;

/// The opt-in "Compute driving reports on this phone" switch.
///
/// OFF by default. A phone-only member's phone then does only the light essentials: send its own fix, receive and
/// decrypt the others' positions, show the map. Trips, driving figures and the weekly summary are NOT computed
/// (no trip segmentation, no result items are sealed or sent) until the member turns this on, knowing it costs
/// battery and CPU. Server-assisted members are not affected: their server does the work.
///
/// Stored in the private-circle key-value store under [kvKey] (SharedPreferences key `e2ee_chan_procset/on_device_reports`,
/// "1" = on), so the background location isolate sees the same value as the app.
class OnDeviceReportsSetting {
  OnDeviceReportsSetting._();

  /// Key inside the private-circle store (the prefs file prefixes it with `e2ee_chan_`).
  static const String kvKey = 'procset/on_device_reports';

  static Future<bool> isOn(ChannelKv kv) async => (await kv.getFresh(kvKey)) == '1';

  static Future<void> set(ChannelKv kv, bool on) async {
    if (on) {
      await kv.set(kvKey, '1');
    } else {
      await kv.remove(kvKey);
    }
  }

  /// Words for cards that need reports while the switch is off and the server is not computing them.
  static const String needServerMessage = 'Driving reports need the server. Turn on the server for this circle, or enable phone reports.';
}
