import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/models/member.dart';
import 'package:openfamily/services/member_avatar_cache.dart';
import 'package:openfamily/widgets/member_avatar_bubble.dart';

final Uint8List _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

const Member _withPhoto = Member(
  id: 'photo-1',
  name: 'Ada Lovelace',
  position: null,
  status: MemberStatus.normal,
  batteryPercent: 50,
  address: '',
  hasAvatar: true,
  avatarVersion: 3,
);

Widget _host(double dpr, {double size = 44}) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(devicePixelRatio: dpr),
        child: Scaffold(
          body: Center(child: StatusAvatar(member: _withPhoto, size: size)),
        ),
      ),
    );

void main() {
  setUp(MemberAvatarCache.instance.clear);

  testWidgets('a cached photo is on screen in the very first frame',
      (tester) async {
    MemberAvatarCache.instance.debugPut(_withPhoto, _png);
    await tester.pumpWidget(_host(3));
    // No await / extra pump: the first frame already has the photo, so there
    // is no initials flash (before: the future's first snapshot was empty).
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('AL'), findsNothing);
  });

  testWidgets('photos decode at about display size, not file size',
      (tester) async {
    MemberAvatarCache.instance.debugPut(_withPhoto, _png);
    await tester.pumpWidget(_host(3, size: 44));
    final Image img = tester.widget<Image>(find.byType(Image));
    expect(img.image, isA<ResizeImage>());
    final ResizeImage r = img.image as ResizeImage;
    // 44 dp * 3.0 dpr * 2 = 264 px on the long side, aspect preserved.
    expect(r.width, 264);
    expect(r.height, 264);
    expect(r.policy, ResizeImagePolicy.fit);
    expect(r.allowUpscaling, isFalse);
    // ignore: avoid_print
    print('PERFMETRIC avatar-decode: 4000x3000 photo in a 44 dp circle at 3x '
        'decodes to 264x198 px (${264 * 198 * 4 ~/ 1024} KB) instead of '
        '4000x3000 (${4000 * 3000 * 4 ~/ 1024} KB)');
  });

  testWidgets('without a cached photo the initials show until it loads',
      (tester) async {
    await tester.pumpWidget(_host(2));
    expect(find.text('AL'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });
}
