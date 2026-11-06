import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/invite_link.dart';

void main() {
  const String fp = 'ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12cd34ef56ab12';
  const String circle = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';

  test('the inviter fingerprint and circle id ride in the URL fragment and round trip', () {
    final String? url = InviteLink.build('https://of.example.com', 'ABCD2345', fingerprint: fp, circleId: circle);
    expect(url, 'https://of.example.com/join/ABCD2345#fp=$fp&c=$circle');
    final InviteLink? l = InviteLink.parse(url!);
    expect(l!.code, 'ABCD2345');
    expect(l.fingerprint, fp);
    expect(l.circleId, circle);
    // A fragment is never sent to the server by an HTTP client.
    expect(Uri.parse(url).hasFragment, isTrue);
    expect(Uri.parse(url).path, '/join/ABCD2345');
  });

  test('links without or with malformed anchors still work and drop the bad part', () {
    expect(InviteLink.build('https://of.example.com', 'ABCD2345'), 'https://of.example.com/join/ABCD2345');
    final InviteLink? plain = InviteLink.parse('https://of.example.com/join/ABCD2345');
    expect(plain!.fingerprint, isNull);
    final InviteLink? bad = InviteLink.parse('https://of.example.com/join/ABCD2345#fp=nothex&c=zz');
    expect(bad!.code, 'ABCD2345');
    expect(bad.fingerprint, isNull);
    expect(bad.circleId, isNull);
    expect(InviteLink.build('https://of.example.com', 'ABCD2345', fingerprint: 'short'), 'https://of.example.com/join/ABCD2345');
  });
}
