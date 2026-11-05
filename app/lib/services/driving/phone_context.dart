/// Where call audio is going. Derived natively from AudioManager; needs no
/// permission. Bluetooth/wired/car routes are hands-free.
enum AudioRoute { unknown, earpiece, speaker, bluetooth, wired, car }

/// Whether a call is active (telephony call or VoIP call).
enum CallMode { none, call, voip }

/// Proximity sensor state.
enum Proximity { unknown, near, far }

/// Snapshot of the phone's situation that decides whether a call or screen
/// session is hands-free. No call numbers, contacts or content are involved.
class PhoneContext {
  const PhoneContext({
    this.tMs = 0,
    this.proximity = Proximity.unknown,
    this.callMode = CallMode.none,
    this.route = AudioRoute.unknown,
    this.carMode = false,
  });

  factory PhoneContext.fromWire(Map<dynamic, dynamic> m) => PhoneContext(
        tMs: (m['t'] as num?)?.toInt() ?? 0,
        proximity: switch (m['proximity']) {
          'near' => Proximity.near,
          'far' => Proximity.far,
          _ => Proximity.unknown,
        },
        callMode: switch (m['mode']) {
          'call' => CallMode.call,
          'voip' => CallMode.voip,
          _ => CallMode.none,
        },
        route: switch (m['route']) {
          'earpiece' => AudioRoute.earpiece,
          'speaker' => AudioRoute.speaker,
          'bluetooth' => AudioRoute.bluetooth,
          'wired' => AudioRoute.wired,
          'car' => AudioRoute.car,
          _ => AudioRoute.unknown,
        },
        carMode: m['car'] == true,
      );

  final int tMs;
  final Proximity proximity;
  final CallMode callMode;
  final AudioRoute route;

  /// Android Auto / car UI mode is active.
  final bool carMode;

  bool get inCall => callMode != CallMode.none;
  bool get near => proximity == Proximity.near;

  /// Audio goes to a car, Bluetooth or wired headset (or Android Auto).
  bool get handsFree =>
      carMode ||
      route == AudioRoute.bluetooth ||
      route == AudioRoute.wired ||
      route == AudioRoute.car;

  PhoneContext copyWith({int? tMs}) => PhoneContext(
        tMs: tMs ?? this.tMs,
        proximity: proximity,
        callMode: callMode,
        route: route,
        carMode: carMode,
      );
}
