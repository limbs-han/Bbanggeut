import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/app/app_controller.dart';
import 'package:william_james_app/app/app_theme.dart';
import 'package:william_james_app/core/api_client.dart';
import 'package:william_james_app/core/models.dart';
import 'package:william_james_app/ui/settings_screen.dart';

const _memberVault = MemoryVault(
  id: 'vault-1',
  name: '가족 추억',
  status: 'ACTIVE',
  myRole: 'MEMBER',
  retentionDays: 30,
  subscriptionActive: false,
  devices: [],
);

const _ownedVault = MemoryVault(
  id: 'vault-1',
  name: '가족 추억',
  status: 'ACTIVE',
  myRole: 'OWNER',
  retentionDays: 30,
  subscriptionActive: false,
  devices: [],
);

void main() {
  test('OWNER가 아니면 초대는 실패로 보고된다', () async {
    final controller = AppController()..selectedVault = _memberVault;

    final ok = await controller.createInvitation('someone@example.com', 'MEMBER');

    expect(ok, isFalse);
    expect(controller.errorMessage, contains('OWNER'));
    controller.dispose();
  });

  test('금고를 고르지 않았으면 초대는 성공으로 보고되지 않는다', () async {
    final controller = AppController();

    final ok = await controller.createInvitation('someone@example.com', 'MEMBER');

    expect(ok, isFalse);
    expect(controller.errorMessage, isNotNull);
    controller.dispose();
  });

  test('presence를 다시 읽어 기기 상태를 갱신한다', () async {
    final api = _PresenceApiClient();
    final vault = _onlineVault;
    final controller = AppController(api: api)
      ..authenticated = true
      ..selectedVault = vault
      ..vaults = [vault]
      ..devices = vault.devices
          .map((binding) => binding.device)
          .toList(growable: false)
      ..selectedDevice = vault.devices.first.device;

    expect(controller.selectedDevice!.isOnline, isTrue);

    await controller.refreshPresence();

    expect(controller.selectedDevice!.isOnline, isFalse);
    expect(controller.selectedVault!.devices.first.device.status, 'OFFLINE');
    controller.dispose();
  });

  test('presence 조회가 실패해도 마지막 상태를 유지한다', () async {
    final vault = _onlineVault;
    final controller = AppController(api: _FailingPresenceApiClient())
      ..authenticated = true
      ..selectedVault = vault
      ..vaults = [vault]
      ..selectedDevice = vault.devices.first.device;

    await controller.refreshPresence();

    expect(controller.selectedDevice!.isOnline, isTrue);
    controller.dispose();
  });

  testWidgets('기기가 없는 금고에서도 설정 화면이 열린다', (tester) async {
    final controller = AppController()
      ..authenticated = true
      ..selectedVault = _ownedVault
      ..vaults = const [_ownedVault]
      ..devices = const []
      ..selectedDevice = null;

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: SettingsScreen(controller: controller),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('연결된 기기가 없어요'), findsOneWidget);
    // OWNER 기능은 기기 없이도 남아 있어야 한다.
    expect(find.text('접근 기록'), findsOneWidget);
    expect(find.text('보관 구독'), findsOneWidget);
    controller.dispose();
  });
}

MemoryVault get _onlineVault => MemoryVault(
  id: 'vault-1',
  name: '가족 추억',
  status: 'ACTIVE',
  myRole: 'OWNER',
  retentionDays: 30,
  subscriptionActive: false,
  devices: [_binding('ONLINE')],
);

VaultDevice _binding(String status) => VaultDevice.fromJson(
  {
    'bindingId': 'binding-1',
    'generation': 1,
    'deviceId': 'device-1',
    'name': 'Jetson',
    'model': 'WJ-DEV-01',
    'status': status,
  },
  myRole: 'OWNER',
  retentionDays: 30,
);

class _PresenceApiClient extends ApiClient {
  @override
  Future<List<MemoryVault>> listVaults() async => [
    MemoryVault(
      id: 'vault-1',
      name: '가족 추억',
      status: 'ACTIVE',
      myRole: 'OWNER',
      retentionDays: 30,
      subscriptionActive: false,
      devices: [_binding('OFFLINE')],
    ),
  ];
}

class _FailingPresenceApiClient extends ApiClient {
  @override
  Future<List<MemoryVault>> listVaults() async =>
      throw const ApiFailure('네트워크 오류');
}
