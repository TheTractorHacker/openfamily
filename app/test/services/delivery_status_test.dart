import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:openfamily/models/member.dart';
import 'package:openfamily/services/delivery_status.dart';
import 'package:openfamily/utils/member_status.dart';

MemberDelivery md(String reason, {String name = 'Kinsley Foley', String version = '0.21.1', DateTime? last}) =>
    MemberDelivery.fromJson(<String, dynamic>{
      'user_id': 'u-$name', 'name': name, 'reason': reason, 'app_version': version, 'app_bucket': 'ok',
      if (last != null) 'last_item_at': last.toIso8601String(),
    });

void main() {
  tearDown(DeliveryHints.clear);

  test('every reason is said in plain words with the first name', () {
    expect(describeMemberDelivery(md('ok')), isNull);
    expect(describeMemberDelivery(md('sharing_paused')), 'Location sharing paused by Kinsley');
    expect(describeMemberDelivery(md('update_needed', version: '0.15.0')), 'Kinsley needs to update the app (v0.15.0 is too old)');
    expect(describeMemberDelivery(md('no_key_wrap')), "Kinsley's phone has not received the circle key yet");
    expect(describeMemberDelivery(md('not_approved')), contains('waiting for an admin'));
    expect(describeMemberDelivery(md('no_device')), contains('set up encryption'));
    expect(describeMemberDelivery(md('never_sent')), contains("hasn't sent an encrypted update yet"));
  });

  test('a quiet member says since when', () {
    final DateTime at = DateTime.utc(2026, 11, 7, 9, 2);
    final String s = describeMemberDelivery(md('quiet', last: at), now: at.add(const Duration(hours: 5)))!;
    expect(s, startsWith("Kinsley hasn't sent an encrypted update since "));
    expect(s, endsWith('(their phone may be off or the app closed)'));
    expect(s, contains(formatClock(at.toLocal())));
  });

  test('the circle summary and parsing', () {
    final CircleDelivery d = CircleDelivery.fromJson(<String, dynamic>{
      'circle_id': 'c1', 'summary': 'nobody_sending',
      'members': <dynamic>[<String, dynamic>{'user_id': 'u1', 'name': 'A', 'you': true, 'reason': 'never_sent'}],
    });
    expect(d.nobodySending, isTrue);
    expect(d.members.single.you, isTrue);
    expect(kNobodySendingText, 'You are in private mode and nobody has sent an update.');
  });

  test('hints replace "No location yet" in the people list, never for the signed-in user', () {
    const Member kinsley = Member(
        id: 'u-Kinsley Foley', name: 'Kinsley Foley', position: null, status: MemberStatus.normal, batteryPercent: 0, address: '');
    expect(memberStatusLine(kinsley), 'No location yet');
    DeliveryHints.put(CircleDelivery(circleId: 'c1', summary: 'some_not_sending', at: DateTime.now(), members: <MemberDelivery>[md('no_key_wrap')]));
    expect(memberStatusLine(kinsley), "Kinsley's phone has not received the circle key yet");
    // A member who is fine in any circle gets no hint.
    DeliveryHints.put(CircleDelivery(circleId: 'c2', summary: 'ok', at: DateTime.now(), members: <MemberDelivery>[md('ok')]));
    expect(memberStatusLine(kinsley), 'No location yet');
    // With a position and a stopped status the reason also wins over "Updates stopped".
    DeliveryHints.clear();
    DeliveryHints.put(CircleDelivery(circleId: 'c1', summary: 'some_not_sending', at: DateTime.now(), members: <MemberDelivery>[md('quiet')]));
    final Member stopped = kinsley.copyWith(position: const LatLng(1, 2), status: MemberStatus.stopped);
    expect(memberStatusLine(stopped), startsWith("Kinsley hasn't sent"));
  });
}
