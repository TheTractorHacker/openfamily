import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/location_reporter.dart';

void main() {
  test('routing error fails closed: plaintext is not sent', () async {
    final int before = LocationReporter.privateRouteFailures;
    final bool send = await LocationReporter.routePrivateFailClosed(
      <String, dynamic>{'lat': 1.0},
      (_) async => throw StateError('prefs read failed'),
    );
    expect(send, isFalse);
    expect(LocationReporter.privateRouteFailures, before + 1);
  });

  test('non-private routing still reports', () async {
    expect(
      await LocationReporter.routePrivateFailClosed(
          <String, dynamic>{}, (_) async => true),
      isTrue,
    );
  });

  test('router throws and the user has a private circle: fix is withheld', () async {
    expect(
      await LocationReporter.routePrivateFailClosed(
        <String, dynamic>{},
        (_) async => throw StateError('boom'),
        hasPrivateCircles: () async => true,
      ),
      isFalse,
    );
  });

  test('router throws but the user has NO private circle: ordinary tracking continues', () async {
    final int before = LocationReporter.privateRouteFailures;
    expect(
      await LocationReporter.routePrivateFailClosed(
        <String, dynamic>{},
        (_) async => throw StateError('boom'),
        hasPrivateCircles: () async => false,
      ),
      isTrue,
    );
    expect(LocationReporter.privateRouteFailures, before);
  });

  test('router throws and private circles cannot be read: fails closed', () async {
    expect(
      await LocationReporter.routePrivateFailClosed(
        <String, dynamic>{},
        (_) async => throw StateError('boom'),
        hasPrivateCircles: () async => throw StateError('also boom'),
      ),
      isFalse,
    );
  });
}
