import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/app/app_controller.dart';
import 'package:william_james_app/app/app_theme.dart';
import 'package:william_james_app/core/api_client.dart';
import 'package:william_james_app/core/models.dart';
import 'package:william_james_app/ui/home_screen.dart';

void main() {
  test('온라인 기기를 앞에 두고 같은 상태의 등록 순서를 유지한다', () {
    final controller = AppController()
      ..devices = const [_offlineOne, _onlineOne, _offlineTwo, _onlineTwo];

    expect(controller.devicesForSelectedPlace.map((device) => device.id), [
      'online-1',
      'online-2',
      'offline-1',
      'offline-2',
    ]);
    controller.dispose();
  });

  test('첫 조회는 첫 온라인 기기를 기본 선택한다', () async {
    final api = _DeviceOrderApiClient(
      _vault(const [_offlineOne, _onlineOne, _offlineTwo, _onlineTwo]),
    );
    final controller = AppController(api: api);

    await controller.refreshVaults();

    expect(controller.selectedDevice?.id, 'online-1');
    controller.dispose();
  });

  test('온라인 기기가 없으면 기존 목록의 첫 기기를 선택한다', () async {
    final api = _DeviceOrderApiClient(_vault(const [_offlineOne, _offlineTwo]));
    final controller = AppController(api: api);

    await controller.refreshVaults();

    expect(controller.selectedDevice?.id, 'offline-1');
    expect(controller.deviceStatus?.isOnline, isFalse);
    controller.dispose();
  });

  test('상태 갱신으로 재정렬되어도 선택 기기 ID를 유지한다', () async {
    const selected = DeviceSummary(
      id: 'online-2',
      name: '온라인 2',
      model: 'test',
      status: 'ONLINE',
      myRole: 'OWNER',
      retentionDays: 30,
    );
    const nowOffline = DeviceSummary(
      id: 'online-1',
      name: '온라인 1',
      model: 'test',
      status: 'OFFLINE',
      myRole: 'OWNER',
      retentionDays: 30,
    );
    final initialVault = _vault(const [_onlineOne, selected]);
    final api = _DeviceOrderApiClient(_vault(const [nowOffline, selected]));
    final controller = AppController(api: api)
      ..authenticated = true
      ..vaults = [initialVault]
      ..selectedVault = initialVault
      ..devices = const [_onlineOne, selected]
      ..selectedDevice = selected
      ..deviceStatus = const DeviceStatus(
        status: 'ONLINE',
        recording: true,
        uploadQueueDepth: 0,
      );

    await controller.refreshPresence();

    expect(controller.selectedDevice?.id, 'online-2');
    expect(controller.devicesForSelectedPlace.map((device) => device.id), [
      'online-2',
      'online-1',
    ]);
    expect(controller.deviceStatus?.isOnline, isTrue);
    controller.dispose();
  });

  test('선택 기기가 사라지면 첫 온라인 기기로 전환한다', () async {
    final initialVault = _vault(const [_offlineOne, _offlineTwo]);
    final api = _DeviceOrderApiClient(
      _vault(const [_offlineOne, _onlineOne, _onlineTwo]),
    );
    final controller = AppController(api: api)
      ..authenticated = true
      ..vaults = [initialVault]
      ..selectedVault = initialVault
      ..devices = const [_offlineOne, _offlineTwo]
      ..selectedDevice = _offlineTwo;

    await controller.refreshPresence();

    expect(controller.selectedDevice?.id, 'online-1');
    controller.dispose();
  });

  test('빈 기기 목록은 선택 없이 그대로 유지한다', () async {
    final api = _DeviceOrderApiClient(_vault(const []));
    final controller = AppController(api: api);

    await controller.refreshVaults();

    expect(controller.devicesForSelectedPlace, isEmpty);
    expect(controller.selectedDevice, isNull);
    controller.dispose();
  });

  test('사용자 순서는 상태 그룹 안에서 유지되고 온라인 그룹은 계속 앞선다', () {
    final vault = _vault(const [
      _offlineOne,
      _onlineOne,
      _offlineTwo,
      _onlineTwo,
    ]);
    final controller = AppController()
      ..selectedVault = vault
      ..devices = const [_offlineOne, _onlineOne, _offlineTwo, _onlineTwo]
      ..selectedDevice = _onlineOne;

    controller.reorderDeviceForSelectedPlace(
      deviceId: 'online-2',
      beforeDeviceId: 'online-1',
    );

    expect(controller.devicesForSelectedPlace.map((device) => device.id), [
      'online-2',
      'online-1',
      'offline-1',
      'offline-2',
    ]);

    controller.devices = const [
      DeviceSummary(
        id: 'offline-1',
        name: '오프라인 1',
        model: 'test',
        status: 'ONLINE',
        myRole: 'OWNER',
        retentionDays: 30,
      ),
      DeviceSummary(
        id: 'online-1',
        name: '온라인 1',
        model: 'test',
        status: 'OFFLINE',
        myRole: 'OWNER',
        retentionDays: 30,
      ),
      _offlineTwo,
      _onlineTwo,
    ];

    expect(controller.devicesForSelectedPlace.map((device) => device.id), [
      'online-2',
      'offline-1',
      'online-1',
      'offline-2',
    ]);
    expect(controller.selectedDevice?.id, 'online-1');
    controller.dispose();
  });

  test('기기 순서를 Vault별로 저장하고 다시 불러온다', () async {
    final storage = _MemoryPlaceStorage();
    final vault = _vault(const [_onlineOne, _onlineTwo]);
    final controller = AppController(placeStorage: storage)
      ..user = _user
      ..selectedVault = vault
      ..devices = const [_onlineOne, _onlineTwo]
      ..selectedDevice = _onlineOne;

    controller.reorderDeviceForSelectedPlace(
      deviceId: 'online-2',
      beforeDeviceId: 'online-1',
    );
    await controller.waitForPlacePreferencesSaved();

    final saved = jsonDecode(storage.value!) as Map<String, dynamic>;
    expect(saved['deviceOrders'], {
      'vault-1': ['online-2', 'online-1'],
    });

    final restored =
        AppController(api: _DeviceOrderApiClient(vault), placeStorage: storage)
          ..user = _user
          ..selectedVault = vault;
    await restored.loadPlacePreferencesForTesting();
    await restored.refreshVaults();

    expect(restored.devicesForSelectedPlace.map((device) => device.id), [
      'online-2',
      'online-1',
    ]);
    expect(restored.selectedDevice?.id, 'online-2');
    controller.dispose();
    restored.dispose();
  });

  test('상태 조회 시 삭제한 ID를 제거하고 새 기기를 사용자 순서 뒤에 붙인다', () async {
    final storage = _MemoryPlaceStorage();
    final initialVault = _vault(const [_onlineOne, _onlineTwo]);
    final api = _DeviceOrderApiClient(_vault(const [_onlineTwo, _offlineOne]));
    final controller = AppController(api: api, placeStorage: storage)
      ..authenticated = true
      ..user = _user
      ..vaults = [initialVault]
      ..selectedVault = initialVault
      ..devices = const [_onlineOne, _onlineTwo]
      ..selectedDevice = _onlineTwo;
    controller.reorderDeviceForSelectedPlace(
      deviceId: 'online-2',
      beforeDeviceId: 'online-1',
    );
    await controller.waitForPlacePreferencesSaved();

    await controller.refreshPresence();
    await controller.waitForPlacePreferencesSaved();

    expect(controller.devicesForSelectedPlace.map((device) => device.id), [
      'online-2',
      'offline-1',
    ]);
    final saved = jsonDecode(storage.value!) as Map<String, dynamic>;
    expect(saved['deviceOrders'], {
      'vault-1': ['online-2', 'offline-1'],
    });
    controller.dispose();
  });

  testWidgets('재정렬 후 페이지도 선택 기기의 새 인덱스를 따라간다', (tester) async {
    const firstNowOffline = DeviceSummary(
      id: 'online-1',
      name: '온라인 1',
      model: 'test',
      status: 'OFFLINE',
      myRole: 'OWNER',
      retentionDays: 30,
    );
    final initialVault = _vault(const [_onlineOne, _onlineTwo]);
    final api = _DeviceOrderApiClient(
      _vault(const [firstNowOffline, _onlineTwo]),
    );
    final controller = AppController(api: api)
      ..authenticated = true
      ..vaults = [initialVault]
      ..selectedVault = initialVault
      ..devices = const [_onlineOne, _onlineTwo]
      ..selectedDevice = _onlineOne
      ..deviceStatus = const DeviceStatus(
        status: 'ONLINE',
        recording: true,
        uploadQueueDepth: 0,
      );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: AnimatedBuilder(
            animation: controller,
            builder: (_, _) => HomeScreen(
              controller: controller,
              isActive: false,
              openVideos: () {},
              openCalendar: () {},
            ),
          ),
        ),
      ),
    );

    final pager = find.byKey(const Key('home-live-device-pager'));
    await tester.drag(pager, const Offset(-700, 0));
    await tester.pumpAndSettle();
    expect(controller.selectedDevice?.id, 'online-2');

    await controller.refreshPresence();
    await tester.pumpAndSettle();

    expect(controller.selectedDevice?.id, 'online-2');
    final pageController = tester.widget<PageView>(pager).controller!;
    expect(pageController.page, 0);
  });

  testWidgets('바텀시트는 오른쪽 핸들로만 순서를 바꾸고 선택 기기를 유지한다', (tester) async {
    final vault = _vault(const [_onlineOne, _onlineTwo]);
    final api = _DeviceOrderApiClient(vault);
    final controller = AppController(api: api)
      ..selectedVault = vault
      ..vaults = [vault]
      ..devices = const [_onlineOne, _onlineTwo]
      ..selectedDevice = _onlineOne
      ..deviceStatus = const DeviceStatus(
        status: 'ONLINE',
        recording: true,
        uploadQueueDepth: 0,
      );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: AnimatedBuilder(
            animation: controller,
            builder: (_, _) => HomeScreen(
              controller: controller,
              isActive: false,
              openVideos: () {},
              openCalendar: () {},
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('home-place-device-selector')));
    await tester.pumpAndSettle();

    final reorderList = tester.widget<ReorderableListView>(
      find.byKey(const Key('home-device-reorder-list')),
    );
    expect(reorderList.buildDefaultDragHandles, isFalse);
    final handle = find.byKey(const Key('home-device-drag-online-2'));
    expect(tester.getSize(handle), const Size(44, 44));

    await tester.drag(
      find.byKey(const Key('home-device-select-online-2')),
      const Offset(0, -70),
    );
    await tester.pumpAndSettle();
    expect(controller.devicesForSelectedPlace.first.id, 'online-1');

    final drag = await tester.startGesture(tester.getCenter(handle));
    await tester.pump();
    await drag.moveTo(
      tester.getCenter(find.byKey(const Key('home-device-select-online-1'))),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await drag.up();
    await tester.pumpAndSettle();

    expect(controller.devicesForSelectedPlace.map((device) => device.id), [
      'online-2',
      'online-1',
    ]);
    expect(controller.selectedDevice?.id, 'online-1');
    final pageController = tester
        .widget<PageView>(find.byKey(const Key('home-live-device-pager')))
        .controller!;
    expect(pageController.page, 1);

    await tester.tap(find.byKey(const Key('home-device-select-online-2')));
    await tester.pumpAndSettle();
    expect(controller.selectedDevice?.id, 'online-2');
  });
}

const _user = UserProfile(
  id: 'user-1',
  email: 'user@example.com',
  displayName: '사용자',
);

const _offlineOne = DeviceSummary(
  id: 'offline-1',
  name: '오프라인 1',
  model: 'test',
  status: 'OFFLINE',
  myRole: 'OWNER',
  retentionDays: 30,
);

const _onlineOne = DeviceSummary(
  id: 'online-1',
  name: '온라인 1',
  model: 'test',
  status: 'ONLINE',
  myRole: 'OWNER',
  retentionDays: 30,
);

const _offlineTwo = DeviceSummary(
  id: 'offline-2',
  name: '오프라인 2',
  model: 'test',
  status: 'OFFLINE',
  myRole: 'OWNER',
  retentionDays: 30,
);

const _onlineTwo = DeviceSummary(
  id: 'online-2',
  name: '온라인 2',
  model: 'test',
  status: 'ONLINE',
  myRole: 'OWNER',
  retentionDays: 30,
);

MemoryVault _vault(List<DeviceSummary> devices) => MemoryVault(
  id: 'vault-1',
  name: '우리 집',
  status: 'ACTIVE',
  myRole: 'OWNER',
  retentionDays: 30,
  subscriptionActive: false,
  devices: [
    for (final device in devices)
      VaultDevice(
        bindingId: 'binding-${device.id}',
        generation: 1,
        device: device,
      ),
  ],
);

class _DeviceOrderApiClient extends ApiClient {
  _DeviceOrderApiClient(this.vault);

  final MemoryVault vault;

  @override
  Future<List<MemoryVault>> listVaults() async => [vault];

  @override
  Future<DeviceStatus> getDeviceStatus(String id) async {
    final device = vault.devices
        .map((binding) => binding.device)
        .firstWhere((device) => device.id == id);
    return DeviceStatus(
      status: device.status,
      recording: device.isOnline,
      uploadQueueDepth: 0,
    );
  }

  @override
  Future<VideoStats> getVideoStats(String id) async =>
      const VideoStats(totalCount: 0, byTriggerType: {});

  @override
  Future<List<VideoMemory>> listAllVaultVideos(
    String vaultId, {
    String? triggerType,
    DateTime? from,
    DateTime? to,
  }) async => const [];

  @override
  Future<List<DeviceMember>> listVaultMembers(String vaultId) async => const [];

  @override
  Future<List<Invitation>> listVaultInvitations(String vaultId) async =>
      const [];

  @override
  Future<HomeSummary> getHomeSummary(String id) async =>
      const HomeSummary(captureCount: 0, savedCount: 0, memoCount: 0);
}

class _MemoryPlaceStorage extends FlutterSecureStorage {
  String? value;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => value;

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    this.value = value;
  }
}
