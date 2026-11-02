import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/inbox.dart';
import 'api_client.dart';
import 'sharing_service.dart';

/// Loads the received check-ins and live shares. Screens take one so tests can
/// fake it.
abstract class InboxService {
  Future<List<InboxItem>> load();
}

class ApiInboxService implements InboxService {
  const ApiInboxService([this._sharing = const SharingService()]);

  final SharingService _sharing;

  /// Check-ins other people sent to the caller (newest first).
  static Future<List<Map<String, dynamic>>> _receivedCheckIns() async {
    final dynamic r = await ApiClient.get('/checkins');
    final Object? v = r is Map<String, dynamic> ? r['checkins'] : null;
    return v is List
        ? <Map<String, dynamic>>[
            for (final Object? e in v)
              if (e is Map<String, dynamic>) e,
          ]
        : const <Map<String, dynamic>>[];
  }

  @override
  Future<List<InboxItem>> load() async {
    final List<Object> r = await Future.wait<Object>(<Future<Object>>[
      _receivedCheckIns(),
      _sharing.liveShares(),
    ]);
    final List<Map<String, dynamic>> checkIns = r[0] as List<Map<String, dynamic>>;
    final LiveShares shares = r[1] as LiveShares;
    return mergeInbox(
      checkIns.map(InboxItem.fromCheckInJson),
      shares.incoming.map((LiveShare s) => InboxItem(
            id: s.id,
            kind: InboxKind.liveShare,
            userId: s.userId,
            name: s.name.isEmpty ? 'A family member' : s.name,
            at: s.createdAt ?? DateTime.now(),
            lat: s.lat,
            lon: s.lon,
            expiresAt: s.expiresAt,
            paused: s.paused,
          )),
      DateTime.now(),
    );
  }
}

/// Shared inbox state: the map banner and the Activity screen read it, and the
/// WebSocket `checkin` frame refreshes it.
class InboxStore {
  InboxStore._();

  static final InboxStore instance = InboxStore._();

  final ValueNotifier<List<InboxItem>> items =
      ValueNotifier<List<InboxItem>>(const <InboxItem>[]);

  /// Items newer than the last time the Activity screen was opened.
  final ValueNotifier<int> unseen = ValueNotifier<int>(0);

  DateTime _seenAt = DateTime.now();

  Future<void> refresh([InboxService service = const ApiInboxService()]) async {
    try {
      final List<InboxItem> l = await service.load();
      items.value = l;
      _recount();
    } catch (_) {
      // The map works without the inbox; keep what we had.
    }
  }

  void _recount() =>
      unseen.value = items.value.where((InboxItem i) => i.at.isAfter(_seenAt)).length;

  void markSeen() {
    _seenAt = DateTime.now();
    unseen.value = 0;
  }

  /// The newest unseen item, for the map banner.
  InboxItem? get newestUnseen {
    for (final InboxItem i in items.value) {
      if (i.at.isAfter(_seenAt)) return i;
    }
    return null;
  }

  /// `checkin` WebSocket frames (a check-in addressed to this user).
  void handleFrame(Map<String, dynamic> frame) {
    if (frame['type'] == 'checkin') unawaited(refresh());
  }

  @visibleForTesting
  void reset() {
    items.value = const <InboxItem>[];
    unseen.value = 0;
    _seenAt = DateTime.now();
  }
}

/// One-shot request to focus a member on the map, set by the Activity screen
/// and consumed by the map.
class InboxFocus {
  InboxFocus._();

  static final ValueNotifier<String?> memberId = ValueNotifier<String?>(null);
}
