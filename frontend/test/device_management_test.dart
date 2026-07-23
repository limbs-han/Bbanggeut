import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/app/app_controller.dart';
import 'package:william_james_app/core/api_client.dart';
import 'package:william_james_app/core/models.dart';
import 'package:william_james_app/ui/device_registration_screen.dart';

void main() {
  test('등록 코드를 입력하는 동안 대시와 대문자 형식을 유지한다', () {
    const formatter = RegistrationCodeFormatter();

    TextEditingValue format(String text) => formatter.formatEditUpdate(
      TextEditingValue.empty,
      TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      ),
    );

    expect(format('abcd1').text, 'ABCD-1');
    expect(format('abcd-1234').text, 'ABCD-1234');
    expect(format('ab!cd 12345').text, 'ABCD-1234');
  });

  test('기기 해제 성공 시 선택 기기와 연결 데이터를 즉시 비운다', () async {
    final api = _ReleaseApiClient();
    const device = DeviceSummary(
      id: 'device-1',
      name: '거실 카메라',
      model: 'test',
      status: 'ONLINE',
      myRole: 'OWNER',
      retentionDays: 30,
    );
    final controller = AppController(api: api)
      ..devices = const [device]
      ..selectedDevice = device
      ..deviceStatus = const DeviceStatus(
        status: 'ONLINE',
        recording: true,
        uploadQueueDepth: 0,
      );

    expect(await controller.releaseSelectedDevice(), isTrue);
    expect(api.releasedDeviceId, device.id);
    expect(controller.devices, isEmpty);
    expect(controller.selectedDevice, isNull);
    expect(controller.deviceStatus, isNull);
    controller.dispose();
  });
}

class _ReleaseApiClient extends ApiClient {
  String? releasedDeviceId;

  @override
  Future<void> releaseDevice(String deviceId) async {
    releasedDeviceId = deviceId;
  }
}
