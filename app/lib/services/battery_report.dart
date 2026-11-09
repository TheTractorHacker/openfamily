import 'package:battery_plus/battery_plus.dart';

/// Whether [state] counts as "charging" for the bolt other members see: on the
/// charger and filling, or full while plugged in. Null when the platform does
/// not know (the report then leaves the flag out).
bool? chargingFromState(BatteryState state) {
  switch (state) {
    case BatteryState.charging:
    case BatteryState.full:
      return true;
    case BatteryState.discharging:
    case BatteryState.connectedNotCharging:
      return false;
    case BatteryState.unknown:
      return null;
  }
}

/// Reads the charging state, or null when it cannot be read (web, timeout).
Future<bool?> readCharging([Battery? battery]) async {
  try {
    final BatteryState st = await (battery ?? Battery())
        .batteryState
        .timeout(const Duration(seconds: 5));
    return chargingFromState(st);
  } catch (_) {
    return null;
  }
}

/// Adds `battery_pct` and, alongside it, the optional `charging` flag to a
/// report body. The flag is only sent with a battery reading: the server
/// treats a reading without it as "charging unknown". Servers older than
/// 0.26.14 ignore the extra field (their JSON decoding is not strict).
void addBatteryFields(Map<String, dynamic> body, int? batteryPct, bool? charging) {
  if (batteryPct == null) return;
  body['battery_pct'] = batteryPct;
  if (charging != null) body['charging'] = charging;
}
