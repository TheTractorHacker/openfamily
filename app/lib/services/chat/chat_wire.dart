import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../e2ee/e2ee_crypto.dart';

// Wire format of encrypted chat (docs/design/E2EE_CHAT.md). Everything here is
// the JSON `body` that goes INSIDE a sealed, signed `chat` item. Nothing in this
// file talks to the network or to storage.

/// Longest message text, in characters (same as plaintext chat).
const int kChatMaxText = 2000;

/// A photo attached to a message. The file key travels only in the sealed body.
class ChatAttachment {
  const ChatAttachment({required this.blobId, required this.key, required this.mime, required this.size});

  final String blobId;

  /// 32 byte per-file key, base64.
  final String key;
  final String mime;
  final int size;

  Map<String, dynamic> toJson() => <String, dynamic>{'b': blobId, 'k': key, 'm': mime, 's': size};

  static ChatAttachment? fromJson(Object? j) {
    if (j is! Map) return null;
    final Object? b = j['b'], k = j['k'], m = j['m'], s = j['s'];
    if (b is! String || k is! String || m is! String || s is! num) return null;
    if (!RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(b)) return null;
    try {
      if (E2ee.unb64(k).length != 32) return null;
    } catch (_) {
      return null;
    }
    if (m != 'image/jpeg' && m != 'image/png') return null;
    if (s < 1 || s > 6 * 1024 * 1024) return null;
    return ChatAttachment(blobId: b, key: k, mime: m, size: s.toInt());
  }
}

enum ChatEventKind { message, edit, delete }

/// A parsed, shape-checked chat event. The author is NOT in here: it is the
/// verified owner of the signing device (see ChatEngine).
class ChatEvent {
  const ChatEvent({required this.kind, required this.id, this.text = '', this.attachment, this.author});

  final ChatEventKind kind;

  /// The sender-chosen message id (1 to 64 chars).
  final String id;
  final String text;
  final ChatAttachment? attachment;

  /// Delete only: the author of the message to remove.
  final String? author;
}

class ChatWire {
  ChatWire._();

  static bool validId(String id) =>
      id.isNotEmpty && id.length <= 64 && !id.contains(':') && !id.contains('\u0000') && id == id.trim();

  static Map<String, dynamic> message(String id, String text, {ChatAttachment? attachment}) => <String, dynamic>{
        'v': 1,
        'k': 'msg',
        'id': id,
        't': text,
        if (attachment != null) 'img': attachment.toJson(),
      };

  static Map<String, dynamic> edit(String id, String text) =>
      <String, dynamic>{'v': 1, 'k': 'edit', 'id': id, 't': text};

  static Map<String, dynamic> delete(String id, String author) =>
      <String, dynamic>{'v': 1, 'k': 'del', 'id': id, 'a': author};

  /// Null for anything malformed or from a newer format: such items are ignored.
  static ChatEvent? parse(Map<String, dynamic> body) {
    if (body['v'] != 1) return null;
    final Object? id = body['id'];
    if (id is! String || !validId(id)) return null;
    switch (body['k']) {
      case 'msg':
        final Object? t = body['t'];
        if (t is! String) return null;
        final ChatAttachment? img = body['img'] == null ? null : ChatAttachment.fromJson(body['img']);
        if (body['img'] != null && img == null) return null;
        final String text = t.trim();
        if ((text.isEmpty && img == null) || text.runes.length > kChatMaxText || text.contains('\u0000')) return null;
        return ChatEvent(kind: ChatEventKind.message, id: id, text: text, attachment: img);
      case 'edit':
        final Object? t = body['t'];
        if (t is! String) return null;
        final String text = t.trim();
        if (text.runes.length > kChatMaxText || text.contains('\u0000')) return null;
        return ChatEvent(kind: ChatEventKind.edit, id: id, text: text);
      case 'del':
        final Object? a = body['a'];
        if (a is! String || a.isEmpty || a.length > 64) return null;
        return ChatEvent(kind: ChatEventKind.delete, id: id, author: a);
    }
    return null;
  }
}

/// Per-file encryption of attachments: XChaCha20-Poly1305 with a fresh random
/// key, `0x01 || nonce(24) || ciphertext || tag(16)`, AAD `"OFE2EE3-BLOB\0" || circle`.
class ChatBlobCrypto {
  ChatBlobCrypto._();
  static final Xchacha20 _aead = Xchacha20.poly1305Aead();

  static List<int> _aad(String circleId) => utf8.encode('OFE2EE3-BLOB\x00$circleId');

  static Uint8List newKey() => E2ee.randomBytes(32);

  static Future<Uint8List> encrypt(Uint8List plain, Uint8List key, String circleId) async {
    final Uint8List nonce = E2ee.randomBytes(24);
    final SecretBox box = await _aead.encrypt(plain, secretKey: SecretKey(key), nonce: nonce, aad: _aad(circleId));
    return E2ee.cat(<List<int>>[
      <int>[1],
      nonce,
      box.cipherText,
      box.mac.bytes,
    ]);
  }

  /// Throws [E2eeAuthException] on any tamper, wrong key or wrong circle.
  static Future<Uint8List> decrypt(Uint8List blob, Uint8List key, String circleId) async {
    if (blob.length < 1 + 24 + 16 || blob[0] != 1 || key.length != 32) throw const E2eeFormatException('bad attachment');
    final Uint8List nonce = Uint8List.fromList(blob.sublist(1, 25));
    final Uint8List mac = Uint8List.fromList(blob.sublist(blob.length - 16));
    final Uint8List ct = Uint8List.fromList(blob.sublist(25, blob.length - 16));
    try {
      return Uint8List.fromList(
          await _aead.decrypt(SecretBox(ct, nonce: nonce, mac: Mac(mac)), secretKey: SecretKey(key), aad: _aad(circleId)));
    } catch (_) {
      throw const E2eeAuthException();
    }
  }
}
