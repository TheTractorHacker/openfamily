import 'package:flutter_test/flutter_test.dart';
import 'package:openfamily/services/api_client.dart';
import 'package:openfamily/services/device_service.dart';

void main() {
  test('only a 404 "device not found" counts as a gone device', () {
    expect(DeviceService.isDeviceGone(const ApiException(404, 'device not found')), isTrue);
    expect(DeviceService.isDeviceGone(const ApiException(404, 'Device not found')), isTrue);
    expect(DeviceService.isDeviceGone(const ApiException(404, 'circle not found')), isFalse);
    expect(DeviceService.isDeviceGone(const ApiException(403, 'device not found')), isFalse);
    expect(DeviceService.isDeviceGone(const ApiException(0, 'timeout')), isFalse);
    expect(DeviceService.isDeviceGone(StateError('x')), isFalse);
  });

  test('recoverIfGone does nothing for other errors', () async {
    expect(await DeviceService.recoverIfGone(const ApiException(500, 'boom')), isNull);
  });
}
