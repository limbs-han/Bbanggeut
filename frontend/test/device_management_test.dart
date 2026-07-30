import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/app/app_controller.dart';
import 'package:william_james_app/app/app_theme.dart';
import 'package:william_james_app/core/api_client.dart';
import 'package:william_james_app/core/models.dart';
import 'package:william_james_app/ui/device_registration_screen.dart';

void main() {
  testWidgets('MEMBER는 기기 등록 화면에 직접 접근해도 차단된다', (tester) async {
    final controller = AppController()
      ..selectedVault = const MemoryVault(
        id: 'member-vault',
        name: '가족 추억',
        status: 'ACTIVE',
        myRole: 'MEMBER',
        retentionDays: 30,
        subscriptionActive: false,
        devices: [],
      );

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: DeviceRegistrationScreen(controller: controller),
      ),
    );

    expect(find.text('접근할 수 없어요'), findsOneWidget);
    expect(find.text('새 기기 등록은 OWNER만 사용할 수 있어요.'), findsOneWidget);
    expect(find.byKey(const Key('registration-code-prefix')), findsNothing);
    controller.dispose();
  });

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

  test('등록 코드의 앞뒤 네 자리 입력을 대문자 영숫자로 제한한다', () {
    const formatter = RegistrationCodePartFormatter();

    TextEditingValue format(String text) => formatter.formatEditUpdate(
      TextEditingValue.empty,
      TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      ),
    );

    expect(format('ab1!c').text, 'AB1C');
    expect(format('abcd12').text, 'ABCD');
  });

  test('기기 연결 해제 후에도 추억 금고와 과거 영상을 유지한다', () async {
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
      ..vaults = const [_ReleaseApiClient.vaultWithDevice]
      ..selectedVault = _ReleaseApiClient.vaultWithDevice
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
    expect(controller.selectedVault?.id, 'vault-1');
    expect(controller.videos.single.id, 'memory-1');
    expect(controller.deviceStatus, isNull);
    controller.dispose();
  });

  test('로그아웃 API가 실패해도 인증 상태를 초기화한다', () async {
    final controller = AppController(api: _FailingLogoutApiClient())
      ..authenticated = true
      ..user = const UserProfile(
        id: 'user-1',
        email: 'user@example.com',
        displayName: '사용자',
      );

    await expectLater(controller.logout(), throwsException);

    expect(controller.authenticated, isFalse);
    expect(controller.user, isNull);
    expect(controller.busy, isFalse);
    controller.dispose();
  });

  test('프로필 이름을 수정하면 현재 사용자에 즉시 반영한다', () async {
    final api = _ProfileApiClient();
    final controller = AppController(api: api)
      ..user = const UserProfile(
        id: 'user-1',
        email: 'user@example.com',
        displayName: '이전 이름',
      );

    expect(await controller.updateProfile('새 이름'), isTrue);
    expect(api.requestedName, '새 이름');
    expect(controller.user?.displayName, '새 이름');
    controller.dispose();
  });

  testWidgets('기기 코드를 입력할 때 키보드가 입력칸을 가리지 않는다', (tester) async {
    tester.view.physicalSize = const Size(390, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);

    final controller = AppController();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: DeviceRegistrationScreen(
          controller: controller,
          canGoBack: false,
        ),
      ),
    );
    expect(find.textContaining('QR'), findsNothing);
    expect(find.text('Owner'), findsOneWidget);
    expect(find.text('Member'), findsOneWidget);
    final codeField = find.byKey(const Key('registration-code-prefix'));
    expect(codeField, findsOneWidget);

    await tester.tap(codeField);
    await tester.pump();
    var editable = tester.widget<EditableText>(
      find.descendant(of: codeField, matching: find.byType(EditableText)),
    );
    expect(editable.focusNode.hasFocus, isTrue);

    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    await tester.pumpAndSettle();

    editable = tester.widget<EditableText>(
      find.descendant(of: codeField, matching: find.byType(EditableText)),
    );
    expect(editable.focusNode.hasFocus, isTrue);
    expect(tester.getBottomRight(codeField).dy, lessThanOrEqualTo(380));
    expect(tester.takeException(), isNull);
    controller.dispose();
  });

  testWidgets('기기 등록 전에 기존 Vault와 새 Vault를 명시적으로 선택한다', (tester) async {
    final controller = AppController()
      ..vaults = const [_ReleaseApiClient.vaultWithoutDevice]
      ..selectedVault = _ReleaseApiClient.vaultWithoutDevice;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: DeviceRegistrationScreen(controller: controller),
      ),
    );

    expect(find.byKey(const Key('vault-connection-choice')), findsOneWidget);
    expect(find.text('기존 구성원과 과거 영상을 그대로 함께 사용해요.'), findsOneWidget);
    expect(find.byKey(const Key('existing-vault-selector')), findsOneWidget);

    await tester.tap(find.text('새 Vault'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('new-vault-name')), findsOneWidget);
    expect(find.text('기존 Vault와 완전히 분리된 새 공간을 만들어요.'), findsOneWidget);
    expect(find.textContaining('연결 중에는 Vault를 바꿀 수 없어요'), findsOneWidget);
    controller.dispose();
  });

  test('이메일 초대 응답을 기기와 초대한 사람 정보까지 파싱한다', () {
    final invitation = Invitation.fromJson({
      'id': 'invitation-1',
      'deviceId': 'device-1',
      'deviceName': '거실 카메라',
      'inviteeEmail': 'family@example.com',
      'role': 'VIEWER',
      'inviter': {
        'id': 'owner-1',
        'email': 'owner@example.com',
        'displayName': '소유자',
      },
      'status': 'PENDING',
      'expiresAt': '2026-08-01T12:00:00Z',
      'createdAt': '2026-07-25T12:00:00Z',
    });

    expect(invitation.deviceName, '거실 카메라');
    expect(invitation.inviteeEmail, 'family@example.com');
    expect(invitation.role, 'VIEWER');
    expect(invitation.inviter?.displayName, '소유자');
    expect(invitation.isPending, isTrue);
    expect(invitation.expiresAt, isNotNull);
  });

  test('초대 수락 성공 시 받은 초대를 제거하고 기기 목록을 갱신한다', () async {
    final api = _AcceptInvitationApiClient();
    const invitation = Invitation(
      id: 'invitation-1',
      deviceId: 'device-1',
      deviceName: '거실 카메라',
      inviteeEmail: 'member@example.com',
      role: 'EDITOR',
      status: 'PENDING',
    );
    final controller = AppController(api: api)
      ..receivedInvitations = const [invitation];

    expect(await controller.acceptInvitation(invitation), isTrue);
    expect(api.acceptedInvitationId, invitation.id);
    expect(controller.receivedInvitations, isEmpty);
    expect(controller.devices.single.id, invitation.deviceId);
    expect(controller.selectedDevice?.id, invitation.deviceId);
    expect(api.listMyInvitationsCalls, 1);
    expect(api.listVaultsCalls, 1);
    expect(api.listVaultMembersCalls, 1);
    controller.dispose();
  });
  test(
    'refresh selects a connected vault and combines every accessible vault',
    () async {
      final api = _MultipleVaultApiClient();
      final controller = AppController(api: api);

      await controller.refreshVaults();

      expect(controller.selectedVault?.id, 'connected-vault');
      expect(controller.selectedDevice?.id, 'current-device');
      expect(controller.videos.map((video) => video.id), [
        'current-memory',
        'archived-memory',
      ]);
      expect(api.requestedVaultIds, {'archived-vault', 'connected-vault'});

      await controller.selectVault(controller.vaults.first);
      expect(controller.selectedVault?.id, 'archived-vault');
      expect(controller.selectedDevice, isNull);
      controller.dispose();
    },
  );
}

class _MultipleVaultApiClient extends ApiClient {
  final Set<String> requestedVaultIds = {};

  static const currentDevice = DeviceSummary(
    id: 'current-device',
    name: 'Current camera',
    model: 'test',
    status: 'ONLINE',
    myRole: 'OWNER',
    retentionDays: 30,
  );

  @override
  Future<List<MemoryVault>> listVaults() async => const [
    MemoryVault(
      id: 'archived-vault',
      name: 'Archive',
      status: 'ACTIVE',
      myRole: 'OWNER',
      retentionDays: 30,
      subscriptionActive: false,
      devices: [],
    ),
    MemoryVault(
      id: 'connected-vault',
      name: 'Current',
      status: 'ACTIVE',
      myRole: 'OWNER',
      retentionDays: 30,
      subscriptionActive: false,
      devices: [
        VaultDevice(
          bindingId: 'current-binding',
          generation: 1,
          device: currentDevice,
        ),
      ],
    ),
  ];

  @override
  Future<DeviceStatus> getDeviceStatus(String id) async => const DeviceStatus(
    status: 'ONLINE',
    recording: false,
    uploadQueueDepth: 0,
  );

  @override
  Future<VideoStats> getVideoStats(String id) async =>
      const VideoStats(totalCount: 1, byTriggerType: {});

  @override
  Future<List<VideoMemory>> listAllVaultVideos(
    String vaultId, {
    String? triggerType,
    DateTime? from,
    DateTime? to,
  }) async {
    requestedVaultIds.add(vaultId);
    if (vaultId == 'connected-vault') {
      return [
        VideoMemory(
          id: 'current-memory',
          deviceId: 'current-device',
          triggerType: 'MANUAL',
          title: 'Current memory',
          status: 'READY',
          favorite: false,
          capturedStartAt: DateTime.utc(2026, 7, 29),
        ),
      ];
    }
    return [
      VideoMemory(
        id: 'archived-memory',
        deviceId: 'old-device',
        triggerType: 'MANUAL',
        title: 'Archived memory',
        status: 'READY',
        favorite: false,
        capturedStartAt: DateTime.utc(2026, 7, 28),
      ),
    ];
  }

  @override
  Future<List<DeviceMember>> listMembers(String deviceId) async => const [];

  @override
  Future<List<Invitation>> listDeviceInvitations(String deviceId) async =>
      const [];

  @override
  Future<List<DeviceMember>> listVaultMembers(String vaultId) async => const [];

  @override
  Future<List<Invitation>> listVaultInvitations(String vaultId) async =>
      const [];

  @override
  Future<HomeSummary> getHomeSummary(String id) async =>
      const HomeSummary(captureCount: 1, savedCount: 1, memoCount: 0);
}

class _ReleaseApiClient extends ApiClient {
  static const vaultWithDevice = MemoryVault(
    id: 'vault-1',
    name: '우리 집',
    status: 'ACTIVE',
    myRole: 'OWNER',
    retentionDays: 30,
    subscriptionActive: false,
    devices: [
      VaultDevice(
        bindingId: 'binding-1',
        generation: 1,
        device: DeviceSummary(
          id: 'device-1',
          name: '거실 카메라',
          model: 'test',
          status: 'ONLINE',
          myRole: 'OWNER',
          retentionDays: 30,
        ),
      ),
    ],
  );
  static const vaultWithoutDevice = MemoryVault(
    id: 'vault-1',
    name: '우리 집',
    status: 'ACTIVE',
    myRole: 'OWNER',
    retentionDays: 30,
    subscriptionActive: false,
    devices: [],
  );
  String? releasedDeviceId;

  @override
  Future<void> releaseDevice(String deviceId) async {
    releasedDeviceId = deviceId;
  }

  @override
  Future<List<MemoryVault>> listVaults() async => const [vaultWithoutDevice];

  @override
  Future<List<VideoMemory>> listAllVaultVideos(
    String vaultId, {
    String? triggerType,
    DateTime? from,
    DateTime? to,
  }) async => const [
    VideoMemory(
      id: 'memory-1',
      deviceId: 'device-1',
      triggerType: 'LAUGHTER',
      title: '남아 있는 추억',
      status: 'READY',
      favorite: false,
    ),
  ];

  @override
  Future<List<DeviceMember>> listVaultMembers(String vaultId) async => const [];

  @override
  Future<List<Invitation>> listVaultInvitations(String vaultId) async =>
      const [];
}

class _FailingLogoutApiClient extends ApiClient {
  @override
  Future<void> logout() async => throw Exception('network unavailable');
}

class _ProfileApiClient extends ApiClient {
  String? requestedName;

  @override
  Future<UserProfile> updateProfile(String displayName) async {
    requestedName = displayName;
    return UserProfile(
      id: 'user-1',
      email: 'user@example.com',
      displayName: displayName,
    );
  }
}

class _AcceptInvitationApiClient extends ApiClient {
  String? acceptedInvitationId;
  int listMyInvitationsCalls = 0;
  int listVaultsCalls = 0;
  int listVaultMembersCalls = 0;

  static const device = DeviceSummary(
    id: 'device-1',
    name: '거실 카메라',
    model: 'test',
    status: 'ONLINE',
    myRole: 'EDITOR',
    retentionDays: 30,
  );

  @override
  Future<DeviceMember> acceptInvitation(String invitationId) async {
    acceptedInvitationId = invitationId;
    return const DeviceMember(
      id: 'membership-1',
      user: UserProfile(
        id: 'member-1',
        email: 'member@example.com',
        displayName: '구성원',
      ),
      role: 'EDITOR',
      status: 'ACTIVE',
    );
  }

  @override
  Future<List<Invitation>> listMyInvitations() async {
    listMyInvitationsCalls += 1;
    return const [];
  }

  @override
  Future<List<MemoryVault>> listVaults() async {
    listVaultsCalls += 1;
    return const [
      MemoryVault(
        id: 'vault-1',
        name: '우리 집',
        status: 'ACTIVE',
        myRole: 'MEMBER',
        retentionDays: 30,
        subscriptionActive: false,
        devices: [
          VaultDevice(bindingId: 'binding-1', generation: 1, device: device),
        ],
      ),
    ];
  }

  @override
  Future<DeviceStatus> getDeviceStatus(String id) async => const DeviceStatus(
    status: 'ONLINE',
    recording: false,
    uploadQueueDepth: 0,
  );

  @override
  Future<VideoStats> getVideoStats(String id) async =>
      const VideoStats(totalCount: 0, byTriggerType: {});

  @override
  Future<List<VideoMemory>> listAllVideos(
    String deviceId, {
    String? triggerType,
    DateTime? from,
    DateTime? to,
  }) async => const [];

  @override
  Future<List<VideoMemory>> listAllVaultVideos(
    String vaultId, {
    String? triggerType,
    DateTime? from,
    DateTime? to,
  }) async => const [];

  @override
  Future<List<DeviceMember>> listMembers(String deviceId) async => const [];

  @override
  Future<List<DeviceMember>> listVaultMembers(String vaultId) async {
    listVaultMembersCalls += 1;
    return const [];
  }

  @override
  Future<HomeSummary> getHomeSummary(String id) async =>
      const HomeSummary(captureCount: 0, savedCount: 0, memoCount: 0);
}
