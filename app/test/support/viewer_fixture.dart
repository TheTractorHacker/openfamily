import 'dart:convert';
import 'dart:typed_data';

import 'package:openfamily/services/e2ee/e2ee_crypto.dart';
import 'package:openfamily/services/e2ee/e2ee_models.dart';

import 'fake_e2ee_server.dart';

/// What a browser viewer or the Go bridge does on its side of the pairing:
/// owns a fresh key pair, shows a request code and registers itself with the
/// approval code a phone produced.
class ViewerFixture {
  ViewerFixture._(this.userId, this.deviceId, this.edSeed, this.xSecret, this.edPub, this.xPub);

  final String userId;
  final String deviceId;
  final Uint8List edSeed, xSecret, edPub, xPub;

  static Future<ViewerFixture> create(String userId) async {
    final (Uint8List es, Uint8List xs) = await E2ee.deriveIdentity(E2ee.randomBytes(32));
    return ViewerFixture._(userId, E2ee.newUuid(), es, xs, await E2ee.edPublicFromSeed(es), await E2ee.xPublicFromSecret(xs));
  }

  Future<Uint8List> fingerprint() => E2ee.fingerprint(edPub, xPub);

  /// base64url(JSON {u,d,e,x,b,k,n}); [kind]/[name] may be null to emulate an old code.
  Future<String> request({String? kind = 'web', String? name = 'Browser'}) async {
    final Uint8List binding = await E2ee.sign(edSeed, E2ee.bindingMessage(userId, deviceId, edPub, xPub));
    return base64Url.encode(utf8.encode(jsonEncode(<String, String>{
      'u': userId, 'd': deviceId, 'e': E2ee.b64(edPub), 'x': E2ee.b64(xPub), 'b': E2ee.b64(binding),
      if (kind != null) 'k': kind,
      if (name != null) 'n': name,
    })));
  }

  /// POST /e2ee/devices with the phone's approval code {a, s}.
  Future<DeviceKey> register(FakeE2eeServer server, String approvalCode, {String kind = 'web', String label = 'Browser'}) async {
    final Map<String, dynamic> ap = jsonDecode(utf8.decode(base64Url.decode(approvalCode))) as Map<String, dynamic>;
    final Uint8List binding = await E2ee.sign(edSeed, E2ee.bindingMessage(userId, deviceId, edPub, xPub));
    return server.client(userId).register(<String, dynamic>{
      'device_id': deviceId,
      'kind': kind,
      'ed25519_pub': E2ee.b64(edPub),
      'x25519_pub': E2ee.b64(xPub),
      'signature': E2ee.b64(binding),
      'label': label,
      'actor_device_id': ap['a'],
      'log_signature': ap['s'],
      'reset': false,
    });
  }
}
