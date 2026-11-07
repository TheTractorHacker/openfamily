import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../../models/chat_message.dart' show ChatSendState;
import '../e2ee/private_channel.dart';
import 'chat_wire.dart';

/// One decrypted message as kept on this phone.
class StoredChat {
  StoredChat({
    required this.author,
    required this.id,
    required this.text,
    required this.tsMs,
    required this.seq,
    this.editedMs,
    this.editVer = '',
    this.attachment,
    this.state = ChatSendState.sent,
    this.queued = '',
  });

  final String author;
  final String id;
  String text;
  final int tsMs;

  /// Relay item id once the item was seen coming back; until then a local
  /// number far above any relay id so pending messages sort last.
  int seq;
  int? editedMs;

  /// "tsMs:itemSeq" of the newest applied edit.
  String editVer;
  final ChatAttachment? attachment;
  ChatSendState state;

  /// "device/seq" of the queued sealed item while [state] is sending.
  String queued;

  String get key => '$author:$id';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'a': author,
        'i': id,
        't': text,
        'ts': tsMs,
        's': seq,
        if (editedMs != null) 'e': editedMs,
        if (editVer.isNotEmpty) 'ev': editVer,
        if (attachment != null) 'img': attachment!.toJson(),
        'st': state.index,
        if (queued.isNotEmpty) 'q': queued,
      };

  static StoredChat? fromJson(Object? j) {
    if (j is! Map) return null;
    try {
      return StoredChat(
        author: j['a'] as String,
        id: j['i'] as String,
        text: j['t'] as String,
        tsMs: (j['ts'] as num).toInt(),
        seq: (j['s'] as num).toInt(),
        editedMs: (j['e'] as num?)?.toInt(),
        editVer: (j['ev'] as String?) ?? '',
        attachment: ChatAttachment.fromJson(j['img']),
        state: ChatSendState.values[(j['st'] as num?)?.toInt() ?? 0],
        queued: (j['q'] as String?) ?? '',
      );
    } catch (_) {
      return null;
    }
  }
}

/// What changed, so open screens can update.
enum ChatChangeKind { added, edited, deleted, delivered }

class ChatChange {
  const ChatChange(this.kind, this.circleId, this.message, {this.key = ''});
  final ChatChangeKind kind;
  final String circleId;
  final StoredChat? message;
  final String key;
}

class _Doc {
  _Doc(this.ver, this.w, this.msgs, this.tomb, this.pendingEdits, this.read);
  int ver;
  String w;
  final Map<String, StoredChat> msgs;

  /// key -> tsMs of a delete that was honoured (message gone or not seen yet).
  final Map<String, int> tomb;

  /// key -> {text, ver, e} edits that arrived before their message.
  final Map<String, Map<String, dynamic>> pendingEdits;

  /// Local read position (a relay item id).
  int read;
}

/// The phone's own chat history (local only). A versioned read-modify-write
/// with read-back, like the sealed queue: the background isolate that handles a
/// push wake-up shares the same store (PRIVACY_PROCESSING 19.1). Every
/// operation is idempotent, so a lost race is repaired by the next replay.
class ChatStore {
  ChatStore({required this.kv, this.maxMessages = 5000, DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final ChannelKv kv;
  final int maxMessages;
  final DateTime Function() _now;
  static final Random _rng = Random.secure();
  Future<void> _lock = Future<void>.value();

  /// Seq base for messages not yet seen on the relay.
  static const int pendingBase = 1 << 50;

  String _key(String c) => 'chat/v1/$c';

  Future<T> _locked<T>(Future<T> Function() f) {
    final Completer<T> c = Completer<T>();
    _lock = _lock.then((_) async {
      try {
        c.complete(await f());
      } catch (e, st) {
        c.completeError(e, st);
      }
    });
    return c.future;
  }

  Future<_Doc> _read(String circle) async {
    final String? raw = await kv.getFresh(_key(circle));
    if (raw != null && raw.isNotEmpty) {
      try {
        final Map<String, dynamic> d = jsonDecode(raw) as Map<String, dynamic>;
        final Map<String, StoredChat> msgs = <String, StoredChat>{};
        for (final MapEntry<String, dynamic> e in ((d['m'] as Map<String, dynamic>?) ?? <String, dynamic>{}).entries) {
          final StoredChat? m = StoredChat.fromJson(e.value);
          if (m != null) msgs[e.key] = m;
        }
        return _Doc(
          (d['v'] as num?)?.toInt() ?? 0,
          (d['w'] as String?) ?? '',
          msgs,
          ((d['t'] as Map<String, dynamic>?) ?? <String, dynamic>{}).map((String k, dynamic v) => MapEntry<String, int>(k, (v as num).toInt())),
          ((d['pe'] as Map<String, dynamic>?) ?? <String, dynamic>{})
              .map((String k, dynamic v) => MapEntry<String, Map<String, dynamic>>(k, (v as Map).cast<String, dynamic>())),
          (d['r'] as num?)?.toInt() ?? 0,
        );
      } catch (_) {}
    }
    return _Doc(0, '', <String, StoredChat>{}, <String, int>{}, <String, Map<String, dynamic>>{}, 0);
  }

  String _encode(_Doc d, int ver, String w) => jsonEncode(<String, dynamic>{
        'v': ver,
        'w': w,
        'm': d.msgs.map((String k, StoredChat v) => MapEntry<String, dynamic>(k, v.toJson())),
        't': d.tomb,
        'pe': d.pendingEdits,
        'r': d.read,
      });

  Future<T> _mutate<T>(String circle, T Function(_Doc d) op) => _locked(() async {
        final ChannelKv store = kv;
        Future<T> once() async {
          T? result;
          for (int attempt = 0; attempt < 8; attempt++) {
            final _Doc snap = await _read(circle);
            result = op(snap);
            _trim(snap);
            final int cur = (await _read(circle)).ver;
            if (cur != snap.ver && attempt < 7) continue;
            final String w = '${_rng.nextInt(1 << 30)}-${_now().microsecondsSinceEpoch}';
            await kv.set(_key(circle), _encode(snap, snap.ver + 1, w));
            final _Doc back = await _read(circle);
            if (back.ver == snap.ver + 1 && back.w == w) return result as T;
          }
          return result as T;
        }

        return store is LockableKv ? (store as LockableKv).withLock('chat/$circle', once) : once();
      });

  void _trim(_Doc d) {
    if (d.msgs.length > maxMessages) {
      final List<StoredChat> sorted = d.msgs.values.toList()..sort((StoredChat a, StoredChat b) => a.seq.compareTo(b.seq));
      for (final StoredChat m in sorted.take(d.msgs.length - maxMessages)) {
        d.msgs.remove(m.key);
      }
    }
    final int cut = _now().subtract(const Duration(days: 45)).millisecondsSinceEpoch;
    d.tomb.removeWhere((String _, int ts) => ts < cut);
    while (d.pendingEdits.length > 100) {
      d.pendingEdits.remove(d.pendingEdits.keys.first);
    }
  }

  // ----------------------------------------------------------------- writes

  /// Records a message this phone just queued (optimistic; shown as sending).
  Future<StoredChat> addPending(String circle, StoredChat m) => _mutate(circle, (_Doc d) {
        final StoredChat? old = d.msgs[m.key];
        if (old != null) return old;
        m.seq = pendingBase + m.tsMs;
        d.msgs[m.key] = m;
        return m;
      });

  /// Applies a verified message. Returns the change, or null when it is a
  /// duplicate or suppressed by a tombstone.
  Future<ChatChange?> applyMessage(String circle, String author, ChatEvent e, {required int tsMs, required int cursor}) =>
      _mutate(circle, (_Doc d) {
        final String key = '$author:${e.id}';
        if (d.tomb.containsKey(key)) return null;
        final StoredChat? old = d.msgs[key];
        if (old != null) {
          if (old.state != ChatSendState.sent || old.seq >= pendingBase) {
            old.state = ChatSendState.sent;
            old.queued = '';
            old.seq = cursor;
            return ChatChange(ChatChangeKind.delivered, circle, old, key: key);
          }
          return null;
        }
        final StoredChat m = StoredChat(author: author, id: e.id, text: e.text, tsMs: tsMs, seq: cursor, attachment: e.attachment);
        final Map<String, dynamic>? pe = d.pendingEdits.remove(key);
        if (pe != null) {
          m.text = pe['t'] as String;
          m.editedMs = (pe['e'] as num).toInt();
          m.editVer = pe['ev'] as String;
        }
        d.msgs[key] = m;
        return ChatChange(ChatChangeKind.added, circle, m, key: key);
      });

  /// Applies an edit signed by [editor]: only their own message can change.
  Future<ChatChange?> applyEdit(String circle, String editor, ChatEvent e, {required int tsMs, required int itemSeq}) =>
      _mutate(circle, (_Doc d) {
        final String key = '$editor:${e.id}';
        if (d.tomb.containsKey(key)) return null;
        final String ver = '$tsMs:$itemSeq';
        final StoredChat? m = d.msgs[key];
        if (m == null) {
          final Map<String, dynamic>? old = d.pendingEdits[key];
          if (old == null || _newer(ver, old['ev'] as String)) {
            d.pendingEdits[key] = <String, dynamic>{'t': e.text, 'e': tsMs, 'ev': ver};
          }
          return null;
        }
        if (m.editVer.isNotEmpty && !_newer(ver, m.editVer)) return null; // replay or reorder: keep the newer text
        if (m.text == e.text && m.editVer == ver) return null;
        m.text = e.text;
        m.editedMs = tsMs;
        m.editVer = ver;
        return ChatChange(ChatChangeKind.edited, circle, m, key: key);
      });

  /// Applies a tombstone whose authorization was already checked by the caller.
  Future<ChatChange?> applyDelete(String circle, String author, String id, {required int tsMs}) => _mutate(circle, (_Doc d) {
        final String key = '$author:$id';
        final bool had = d.msgs.remove(key) != null;
        d.pendingEdits.remove(key);
        final bool fresh = !d.tomb.containsKey(key);
        d.tomb[key] = max(d.tomb[key] ?? 0, tsMs);
        return had || fresh ? ChatChange(ChatChangeKind.deleted, circle, null, key: key) : null;
      });

  Future<void> setState(String circle, String key, ChatSendState s, {String queued = ''}) => _mutate(circle, (_Doc d) {
        final StoredChat? m = d.msgs[key];
        if (m != null && m.seq >= pendingBase) {
          m.state = s;
          m.queued = queued;
        }
      });

  Future<void> remove(String circle, String key) => _mutate(circle, (_Doc d) {
        d.msgs.remove(key);
      });

  Future<void> markRead(String circle, int cursor) => _mutate(circle, (_Doc d) {
        if (cursor > d.read && cursor < pendingBase) d.read = cursor;
      });

  Future<void> clear(String circle) => _mutate(circle, (_Doc d) {
        d.msgs.clear();
        d.tomb.clear();
        d.pendingEdits.clear();
        d.read = 0;
      });

  static bool _newer(String a, String b) {
    final List<int> x = a.split(':').map(int.parse).toList(), y = b.split(':').map(int.parse).toList();
    return x[0] != y[0] ? x[0] > y[0] : x[1] > y[1];
  }

  // ------------------------------------------------------------------ reads

  Future<List<StoredChat>> all(String circle) async {
    final _Doc d = await _read(circle);
    return d.msgs.values.toList()..sort((StoredChat a, StoredChat b) => b.seq.compareTo(a.seq));
  }

  /// Newest first. [before]: only older than this seq; [after]: only newer.
  Future<({List<StoredChat> items, int? nextBefore})> page(String circle, {int? before, int? after, int limit = 50}) async {
    final List<StoredChat> l = (await all(circle))
        .where((StoredChat m) => (before == null || m.seq < before) && (after == null || m.seq > after))
        .toList();
    if (l.length > limit) {
      final List<StoredChat> cut = l.sublist(0, limit);
      return (items: cut, nextBefore: cut.last.seq);
    }
    return (items: l, nextBefore: null);
  }

  Future<StoredChat?> find(String circle, String key) async => (await _read(circle)).msgs[key];

  Future<bool> isTombstoned(String circle, String key) async => (await _read(circle)).tomb.containsKey(key);

  Future<int> readPosition(String circle) async => (await _read(circle)).read;

  Future<int> newestCursor(String circle) async {
    int m = 0;
    for (final StoredChat x in (await _read(circle)).msgs.values) {
      if (x.seq < pendingBase && x.seq > m) m = x.seq;
    }
    return m;
  }

  /// Messages from other people newer than the local read position.
  Future<int> unread(String circle, String me) async {
    final _Doc d = await _read(circle);
    return d.msgs.values.where((StoredChat m) => m.author != me && m.seq < pendingBase && m.seq > d.read).length;
  }
}
