import 'package:flutter/foundation.dart';

import '../../models/emergency_contact.dart';

/// Builds the `sms:` link that opens the phone's own messaging app with the
/// emergency contacts and a ready SOS text. It needs no data connection and no
/// Orbitly server (the user's own carrier plan sends it, and the user presses
/// send). Used when an SOS could not be delivered because the server is
/// unreachable.
///
/// Returns null when there is nobody to text.
Uri? buildSosSmsUri(
  List<EmergencyContact> contacts, {
  double? lat,
  double? lon,
  String? name,
  TargetPlatform? platform,
}) {
  final List<String> numbers = <String>[
    for (final EmergencyContact c in contacts)
      if (_cleanNumber(c.phone).isNotEmpty) _cleanNumber(c.phone),
  ];
  if (numbers.isEmpty) return null;
  final StringBuffer text = StringBuffer(
    '${name == null || name.trim().isEmpty ? 'I' : name.trim()} need${name == null || name.trim().isEmpty ? '' : 's'} help. '
    'This is an SOS sent from my phone because I could not reach the Orbitly server.',
  );
  if (lat != null && lon != null) {
    text.write(' My last known location: '
        'https://www.openstreetmap.org/?mlat=${lat.toStringAsFixed(5)}&mlon=${lon.toStringAsFixed(5)}'
        '#map=17/${lat.toStringAsFixed(5)}/${lon.toStringAsFixed(5)}');
  }
  // Android separates recipients with ';', iOS with ','.
  final String sep = (platform ?? defaultTargetPlatform) == TargetPlatform.iOS ? ',' : ';';
  // %20 for spaces: some messaging apps show a '+' literally.
  return Uri.parse('sms:${numbers.join(sep)}?body=${Uri.encodeComponent(text.toString())}');
}

String _cleanNumber(String raw) => raw.replaceAll(RegExp(r'[^0-9+]'), '');
