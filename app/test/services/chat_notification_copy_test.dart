import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/notification_prefs_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('chatNotificationCopy (same rule as the server chatPushCopy)', () {
    test('names off: no sender and no text, just the circle', () {
      final c = chatNotificationCopy(
          showNames: false, circleName: 'Fam', senderName: 'Henry Smith', text: 'secret');
      expect(c.title, 'New message in Fam');
      expect(c.body, '');
      final p = chatNotificationCopy(
          showNames: false, circleName: 'Fam', senderName: 'Henry', text: '', photo: true);
      expect('${p.title}${p.body}', isNot(contains('Henry')));
    });

    test('names on: the sender first name is in the title, the text in the body', () {
      final c = chatNotificationCopy(
          showNames: true, circleName: 'Fam', senderName: 'Henry Smith', text: ' hi there ');
      expect(c.title, 'Henry in Fam');
      expect(c.body, 'hi there');
    });

    test('photos and empty names', () {
      expect(
          chatNotificationCopy(showNames: true, circleName: 'Fam', senderName: 'Henry', text: '', photo: true).body,
          'Sent a photo');
      expect(
          chatNotificationCopy(showNames: true, circleName: 'Fam', senderName: 'Henry', text: 'look', photo: true)
              .body,
          'Sent a photo: look');
      expect(chatNotificationCopy(showNames: true, circleName: 'Fam', senderName: ' ', text: 'x').title,
          'A family member in Fam');
      expect(chatNotificationCopy(showNames: false, circleName: '', senderName: 'H', text: 'x').title,
          'New message in your circle');
    });

    test('long text is cut to 120 characters plus an ellipsis', () {
      final String long = 'é' * 130;
      final String body =
          chatNotificationCopy(showNames: true, circleName: 'F', senderName: 'A', text: long).body;
      expect(body.runes.length, 121);
      expect(body.endsWith('…'), isTrue);
    });
  });

  group('NotificationNames', () {
    setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

    test('off until known, then remembers the server value on disk', () async {
      expect(await NotificationNames.load(), isFalse);
      await NotificationNames.remember(true);
      NotificationNames.cached = false;
      expect(await NotificationNames.load(), isTrue);
      await NotificationNames.remember(false);
      expect(await NotificationNames.load(), isFalse);
    });
  });
}
