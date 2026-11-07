import '../e2ee/e2ee_models.dart';
import '../e2ee/private_runtime.dart';
import 'processing_source.dart';
import 'result_items.dart';

// What screens that show trips / weekly figures of the PRIMARY circle need when
// that circle is a Private circle with processing lanes (PRIVACY_PROCESSING 8.4):
// for each member where the figures come from, from their VERIFIED lane. The
// merge itself is `ProcessingSource`; this file only feeds it from the running
// app and keeps screens testable (they take a [PrimaryLanesLoader]).

class PrimaryLanes {
  const PrimaryLanes({required this.circleId, required this.members, required this.names});
  final String circleId;
  final List<MemberProcessing> members;
  final Map<String, String> names;

  MemberProcessing? memberById(String userId) {
    for (final MemberProcessing m in members) {
      if (m.userId == userId) return m;
    }
    return null;
  }

  String nameOf(String userId) => (names[userId] ?? '').isEmpty ? 'Member' : names[userId]!;
}

typedef PrimaryLanesLoader = Future<PrimaryLanes?> Function();

/// The server is not asked for results here: screens that talk to the server
/// (REST) fetch server-assisted members' figures themselves.
class _NoServerReader implements ServerProcessingReader {
  const _NoServerReader();
  @override
  Future<List<TripResult>> trips(String circleId, String userId, DateTime from, DateTime to) async => const <TripResult>[];
  @override
  Future<WeekResult?> week(String circleId, String userId, int weekStartMs) async => null;
}

/// Null when the primary circle is not a Private circle (nothing to compose).
Future<PrimaryLanes?> loadPrimaryLanes({PrivateRuntime? runtime, DateTime? now, int days = 62, String? circleId}) async {
  final PrivateRuntime rt = runtime ?? PrivateRuntime.instance;
  final String? cid = await rt.privateTargetFor(circleId);
  if (cid == null) return null;
  try {
    await rt.lanesService.refresh(cid);
  } catch (_) {
    // Offline: the last verified view is used.
  }
  final DateTime to = (now ?? DateTime.now()).toUtc().add(const Duration(days: 1));
  final List<MemberProcessing> members = await ProcessingSource(
    memberLanes: rt.lanesService.members,
    results: rt.results,
    server: const _NoServerReader(),
  ).load(cid, from: to.subtract(Duration(days: days + 1)), to: to);
  final Map<String, String> names = <String, String>{};
  try {
    final CircleE2eeState st = await rt.service.api.circleState(cid);
    for (final CircleE2eeMember m in st.members) {
      names[m.userId] = m.name;
    }
  } catch (_) {}
  return PrimaryLanes(circleId: cid, members: members, names: names);
}
