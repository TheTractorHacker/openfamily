import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../models/member.dart';
import 'api_client.dart';

/// In-memory cache for private family-member avatar bytes.
///
/// The cache only stores image bytes returned by the authenticated API; no
/// public image URLs are created or retained. A member's durable
/// `avatar_version` is part of the key, so a new profile photo naturally
/// bypasses the older cached image even when changes happen within one clock
/// tick.
class MemberAvatarCache {
  MemberAvatarCache._();

  static final MemberAvatarCache instance = MemberAvatarCache._();

  final Map<_MemberAvatarCacheKey, Uint8List> _images =
      <_MemberAvatarCacheKey, Uint8List>{};
  final Map<_MemberAvatarCacheKey, Future<Uint8List?>> _inFlight =
      <_MemberAvatarCacheKey, Future<Uint8List?>>{};
  final Map<String, int> _memberGenerations = <String, int>{};
  int _generation = 0;

  /// Bytes already in memory for [member]'s current avatar version, or null.
  /// Lets avatar widgets paint the photo on their very first frame instead of
  /// flashing initials while an already-completed future resolves.
  Uint8List? peek(Member member) {
    if (!member.hasAvatar || member.id.isEmpty) return null;
    return _images[_MemberAvatarCacheKey(
      memberId: member.id,
      avatarVersion: member.avatarVersion,
    )];
  }

  /// Seeds the cache (tests).
  @visibleForTesting
  void debugPut(Member member, Uint8List bytes) {
    _images[_MemberAvatarCacheKey(
      memberId: member.id,
      avatarVersion: member.avatarVersion,
    )] = bytes;
  }

  /// Returns the avatar bytes for [member], or null if they do not have one.
  ///
  /// Concurrent avatar widgets for the same member/version share a single
  /// request. Failed and 404 requests are not cached, so a later widget or
  /// metadata update can retry.
  Future<Uint8List?> load(Member member) {
    if (!member.hasAvatar || member.id.isEmpty) {
      return Future<Uint8List?>.value(null);
    }

    final _MemberAvatarCacheKey key = _MemberAvatarCacheKey(
      memberId: member.id,
      avatarVersion: member.avatarVersion,
    );
    final Uint8List? cached = _images[key];
    if (cached != null) return Future<Uint8List?>.value(cached);

    final Future<Uint8List?>? pending = _inFlight[key];
    if (pending != null) return pending;

    final Future<Uint8List?> request = _fetch(
      key,
      _generation,
      _memberGenerations[member.id] ?? 0,
    );
    _inFlight[key] = request;
    return request;
  }

  /// Removes every cached version for [memberId]. A per-member generation also
  /// prevents a request that started before invalidation from repopulating an
  /// old private image after a new snapshot or WebSocket frame arrives.
  void invalidate(String memberId) {
    _memberGenerations.update(memberId, (int value) => value + 1,
        ifAbsent: () => 1);
    _images.removeWhere(
      (_MemberAvatarCacheKey key, Uint8List _) => key.memberId == memberId,
    );
    _inFlight.removeWhere(
      (_MemberAvatarCacheKey key, Future<Uint8List?> _) =>
          key.memberId == memberId,
    );
  }

  /// Clears private image bytes when leaving the authenticated family map.
  void clear() {
    // An old request must not repopulate the cache after a logout / account
    // transition. The generation check in [_fetch] prevents that.
    _generation++;
    _images.clear();
    _inFlight.clear();
    _memberGenerations.clear();
  }

  Future<Uint8List?> _fetch(
    _MemberAvatarCacheKey key,
    int requestGeneration,
    int requestMemberGeneration,
  ) async {
    try {
      final Uint8List? bytes =
          await ApiClient.getFamilyMemberAvatar(key.memberId);
      if (bytes != null &&
          requestGeneration == _generation &&
          requestMemberGeneration == (_memberGenerations[key.memberId] ?? 0)) {
        _images[key] = bytes;
      }
      return bytes;
    } finally {
      if (requestGeneration == _generation &&
          requestMemberGeneration == (_memberGenerations[key.memberId] ?? 0)) {
        _inFlight.remove(key);
      }
    }
  }
}

/// A member id plus the backend's durable avatar revision. The versioned key
/// lets an updated photo load immediately without needing to evict every
/// widget's image.
class _MemberAvatarCacheKey {
  const _MemberAvatarCacheKey({
    required this.memberId,
    required this.avatarVersion,
  });

  final String memberId;
  final int avatarVersion;

  @override
  bool operator ==(Object other) {
    return other is _MemberAvatarCacheKey &&
        other.memberId == memberId &&
        other.avatarVersion == avatarVersion;
  }

  @override
  int get hashCode => Object.hash(memberId, avatarVersion);
}
