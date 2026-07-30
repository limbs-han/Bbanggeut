import 'package:flutter/foundation.dart';

import '../core/api_client.dart';
import '../core/models.dart';

const devHlsUrl = String.fromEnvironment('DEV_HLS_URL');
const devHomeCam = bool.fromEnvironment('DEV_HOME_CAM');

class AppController extends ChangeNotifier {
  AppController({ApiClient? api}) : api = api ?? ApiClient();
  final ApiClient api;

  bool initialized = false;
  bool authenticated = false;
  bool busy = false;
  String? errorMessage;
  UserProfile? user;
  List<MemoryVault> vaults = const [];
  MemoryVault? selectedVault;
  List<DeviceSummary> devices = const [];
  DeviceSummary? selectedDevice;
  DeviceStatus? deviceStatus;
  VideoStats? videoStats;
  HomeSummary? homeSummary;
  List<VideoMemory> videos = const [];
  List<DeviceMember> members = const [];
  List<Invitation> sentInvitations = const [];
  List<Invitation> receivedInvitations = const [];
  String? pendingMembershipRequestToken;
  MembershipRequestPreview? pendingMembershipRequestPreview;
  bool openFamilyAfterDeviceClaim = false;

  Future<void> initialize() async {
    if (devHomeCam && devHlsUrl.isNotEmpty) {
      const demoDevice = DeviceSummary(
        id: 'local-raspberry-pi',
        name: '거실 홈캠 (개발용)',
        model: 'Raspberry Pi 5 + Logitech Brio 100',
        status: 'ONLINE',
        myRole: 'OWNER',
        retentionDays: 7,
      );
      const demoVault = MemoryVault(
        id: 'local-memory-vault',
        name: '우리 집',
        status: 'ACTIVE',
        myRole: 'OWNER',
        retentionDays: 7,
        subscriptionActive: false,
        devices: [
          VaultDevice(
            bindingId: 'local-device-binding',
            generation: 1,
            device: demoDevice,
          ),
        ],
      );
      authenticated = true;
      user = const UserProfile(
        id: 'local-demo-user',
        email: 'local@homecam.dev',
        displayName: '테스트 사용자',
      );
      vaults = const [demoVault];
      selectedVault = demoVault;
      devices = const [demoDevice];
      selectedDevice = demoDevice;
      deviceStatus = const DeviceStatus(
        status: 'ONLINE',
        recording: true,
        uploadQueueDepth: 0,
        bufferSeconds: 30,
        personCount: 0,
      );
      videoStats = const VideoStats(totalCount: 0, byTriggerType: {});
      homeSummary = const HomeSummary(
        captureCount: 0,
        savedCount: 0,
        memoCount: 0,
      );
      initialized = true;
      notifyListeners();
      return;
    }
    authenticated = await api.hasSession;
    if (authenticated) {
      user = await api.cachedUser;
      try {
        await refreshAll();
        await resolvePendingMembershipRequest();
      } on ApiFailure catch (error) {
        if (error.statusCode == 401) {
          await api.clearSession();
          authenticated = false;
        } else {
          errorMessage = error.message;
        }
      }
    }
    initialized = true;
    notifyListeners();
  }

  Future<bool> login(
    String email,
    String password, {
    bool persistSession = true,
  }) async => _guard(
    () async {
      final session = await api.login(
        email,
        password,
        persistSession: persistSession,
      );
      user = session.user;
      authenticated = true;
      await refreshAll();
      await resolvePendingMembershipRequest();
    },
    failureMessage: (error) =>
        error.code == 'INVALID_CREDENTIALS' || error.statusCode == 401
        ? '아이디 또는 비밀번호가 올바르지 않습니다. 입력한 정보를 다시 확인해 주세요.'
        : error.message,
  );

  Future<bool> signUp(
    String name,
    String email,
    String password, {
    bool persistSession = true,
  }) async => _guard(() async {
    final session = await api.signUp(
      name,
      email,
      password,
      persistSession: persistSession,
    );
    user = session.user;
    authenticated = true;
    await refreshAll();
    await resolvePendingMembershipRequest();
  });

  Future<void> logout() async {
    busy = true;
    notifyListeners();
    try {
      await api.logout();
    } finally {
      // 서버가 응답하지 않더라도 로컬 세션은 ApiClient에서 삭제된다.
      // 화면 상태도 반드시 초기화해 실제 로그인 화면으로 전환한다.
      _reset();
      busy = false;
      notifyListeners();
    }
  }

  Future<void> withdraw() async {
    await api.withdraw();
    _reset();
    notifyListeners();
  }

  Future<bool> updateProfile(String displayName) async => _guard(() async {
    user = await api.updateProfile(displayName);
    notifyListeners();
  });

  Future<bool> requestPasswordReset(String email) async => _guard(() async {
    await api.requestPasswordReset(email);
  });

  Future<bool> changePassword(
    String currentPassword,
    String newPassword,
  ) async => _guard(() async {
    await api.changePassword(currentPassword, newPassword);
  });

  Future<void> refreshAll() async {
    receivedInvitations = await api.listMyInvitations();
    await refreshVaults();
  }

  Future<void> refreshVaults() async {
    vaults = await api.listVaults();
    if (vaults.isEmpty) {
      selectedVault = null;
      devices = const [];
      selectedDevice = null;
      videos = const [];
      members = const [];
      sentInvitations = const [];
      deviceStatus = null;
      videoStats = null;
      homeSummary = null;
      notifyListeners();
      return;
    }

    final previousVaultId = selectedVault?.id;
    final previousDeviceId = selectedDevice?.id;
    MemoryVault? previousVault;
    for (final vault in vaults) {
      if (vault.id == previousVaultId) {
        previousVault = vault;
        break;
      }
    }
    MemoryVault? connectedVault;
    for (final vault in vaults) {
      if (vault.hasConnectedDevice) {
        connectedVault = vault;
        break;
      }
    }
    selectedVault =
        previousVault != null &&
            (previousVault.hasConnectedDevice || connectedVault == null)
        ? previousVault
        : connectedVault ?? vaults.first;
    devices = selectedVault!.devices
        .map((binding) => binding.device)
        .toList(growable: false);
    selectedDevice = devices.isEmpty
        ? null
        : devices.firstWhere(
            (item) => item.id == previousDeviceId,
            orElse: () => devices.first,
          );
    if (selectedDevice == null) {
      await refreshVaultData();
    } else {
      await refreshDeviceData();
    }
  }

  @Deprecated('Use refreshVaults')
  Future<void> refreshDevices() async {
    await refreshVaults();
  }

  Future<void> refreshVaultData() async {
    final vault = selectedVault;
    if (vault == null) return;
    final results = await Future.wait<Object?>([
      _loadAccessibleVideos(),
      api.listVaultMembers(vault.id),
      if (vault.isOwner)
        api.listVaultInvitations(vault.id)
      else
        Future.value(<Invitation>[]),
    ]);
    videos = results[0] as List<VideoMemory>;
    members = results[1] as List<DeviceMember>;
    sentInvitations = results[2] as List<Invitation>;
    deviceStatus = null;
    videoStats = null;
    homeSummary = null;
    notifyListeners();
  }

  Future<HomeSummary?> _loadHomeSummary(String deviceId) async {
    try {
      return await api.getHomeSummary(deviceId);
    } catch (_) {
      return null;
    }
  }

  Future<void> selectDevice(DeviceSummary device) async {
    if (selectedDevice?.id == device.id) return;
    selectedDevice = device;
    deviceStatus = null;
    videoStats = null;
    homeSummary = null;
    videos = const [];
    members = const [];
    sentInvitations = const [];
    notifyListeners();
    try {
      await refreshDeviceData();
      errorMessage = null;
    } on ApiFailure catch (error) {
      errorMessage = error.message;
      notifyListeners();
    } catch (_) {
      errorMessage = '기기 정보를 불러오지 못했어요. 잠시 후 다시 시도해 주세요.';
      notifyListeners();
    }
  }

  Future<void> selectVault(MemoryVault vault) async {
    if (selectedVault?.id == vault.id) return;
    selectedVault = vault;
    devices = vault.devices
        .map((binding) => binding.device)
        .toList(growable: false);
    selectedDevice = devices.isEmpty ? null : devices.first;
    deviceStatus = null;
    videoStats = null;
    homeSummary = null;
    videos = const [];
    members = const [];
    sentInvitations = const [];
    notifyListeners();
    try {
      await (selectedDevice == null
          ? refreshVaultData()
          : refreshDeviceData());
      errorMessage = null;
    } on ApiFailure catch (error) {
      errorMessage = error.message;
      notifyListeners();
    } catch (_) {
      errorMessage = 'Vault 정보를 불러오지 못했어요. 잠시 후 다시 시도해 주세요.';
      notifyListeners();
    }
  }

  Future<void> refreshDeviceData() async {
    if (devHomeCam && devHlsUrl.isNotEmpty) {
      notifyListeners();
      return;
    }
    final device = selectedDevice;
    if (device == null) {
      await refreshVaultData();
      return;
    }
    final vault = selectedVault;
    final results = await Future.wait<Object?>([
      api.getDeviceStatus(device.id),
      api.getVideoStats(device.id),
      vault == null ? api.listAllVideos(device.id) : _loadAccessibleVideos(),
      vault == null
          ? api.listMembers(device.id)
          : api.listVaultMembers(vault.id),
      if (vault?.isOwner ?? device.isOwner)
        vault == null
            ? api.listDeviceInvitations(device.id)
            : api.listVaultInvitations(vault.id)
      else
        Future.value(<Invitation>[]),
      // Home summary is best-effort so a summary hiccup never blanks the tab.
      _loadHomeSummary(device.id),
    ]);
    deviceStatus = results[0] as DeviceStatus;
    videoStats = results[1] as VideoStats;
    videos = results[2] as List<VideoMemory>;
    members = results[3] as List<DeviceMember>;
    sentInvitations = results[4] as List<Invitation>;
    homeSummary = results[5] as HomeSummary?;
    notifyListeners();
  }

  Future<List<VideoMemory>> _loadAccessibleVideos() async {
    final pages = await Future.wait(
      vaults.map((vault) => api.listAllVaultVideos(vault.id)),
    );
    final videosById = <String, VideoMemory>{};
    for (final page in pages) {
      for (final video in page) {
        videosById[video.id] = video;
      }
    }
    final result = videosById.values.toList();
    result.sort((left, right) {
      final leftAt = left.capturedStartAt ?? left.createdAt;
      final rightAt = right.capturedStartAt ?? right.createdAt;
      if (leftAt == null && rightAt == null) return 0;
      if (leftAt == null) return 1;
      if (rightAt == null) return -1;
      return rightAt.compareTo(leftAt);
    });
    return result;
  }

  Future<bool> claimDevice(
    String code, {
    String? vaultId,
    String? newVaultName,
  }) async => _guard(() async {
    await api.claimDevice(
      code,
      vaultId: vaultId,
      vaultName: vaultId == null ? newVaultName : null,
    );
    await refreshVaults();
    openFamilyAfterDeviceClaim = true;
  });

  bool consumeOpenFamilyAfterDeviceClaim() {
    if (!openFamilyAfterDeviceClaim) return false;
    openFamilyAfterDeviceClaim = false;
    return true;
  }

  Future<bool> updateSelectedDevice({String? name, int? retentionDays}) async =>
      _guard(() async {
        final device = selectedDevice;
        if (device == null) return;
        final updated = await api.updateDevice(
          device.id,
          name: name,
          retentionDays: retentionDays,
        );
        devices = devices
            .map((item) => item.id == updated.id ? updated : item)
            .toList(growable: false);
        selectedDevice = updated;
        notifyListeners();
      });

  Future<bool> releaseSelectedDevice() async => _guard(() async {
    final device = selectedDevice;
    if (device == null) return;
    await api.releaseDevice(device.id);
    await refreshVaults();
  });

  Future<bool> removeVideo(VideoMemory video) async => _guard(() async {
    await api.deleteVideo(video.id);
    videos = videos.where((item) => item.id != video.id).toList();
    notifyListeners();
  });

  Future<bool> toggleFavorite(VideoMemory video) async => _guard(() async {
    await api.updateVideo(video.id, favorite: !video.favorite);
    final index = videos.indexWhere((item) => item.id == video.id);
    if (index >= 0) {
      final next = [...videos];
      next[index] = VideoMemory(
        id: video.id,
        deviceId: video.deviceId,
        triggerType: video.triggerType,
        sourceType: video.sourceType,
        title: video.title,
        description: video.description,
        status: video.status,
        favorite: !video.favorite,
        durationMs: video.durationMs,
        thumbnailUrl: video.thumbnailUrl,
        capturedStartAt: video.capturedStartAt,
        createdAt: video.createdAt,
      );
      videos = next;
      notifyListeners();
    }
  });

  Future<bool> createInvitation(String email, String role) async =>
      _guard(() async {
        final vault = selectedVault;
        if (vault == null || !vault.isOwner) return;
        final requestToken =
            pendingMembershipRequestPreview?.email.toLowerCase() ==
                email.trim().toLowerCase()
            ? pendingMembershipRequestToken
            : null;
        await api.createVaultInvitation(
          vault.id,
          email,
          membershipRequestToken: requestToken,
        );
        if (requestToken != null) {
          pendingMembershipRequestToken = null;
          pendingMembershipRequestPreview = null;
        }
        sentInvitations = await api.listVaultInvitations(vault.id);
        notifyListeners();
      });

  Future<Uri?> createMembershipRequestLink() async {
    busy = true;
    errorMessage = null;
    notifyListeners();
    try {
      final response = await api.createMembershipRequestLink();
      return Uri.parse(
        defaultApiBaseUrl,
      ).resolve('/api/membership-request-links/${response.token}/open');
    } on ApiFailure catch (error) {
      errorMessage = error.message;
      return null;
    } catch (_) {
      errorMessage = '요청 링크를 만들지 못했어요. 잠시 후 다시 시도해 주세요.';
      return null;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> setMembershipRequestLink(Uri uri) async {
    if (uri.scheme != 'bbanggeut' || uri.host != 'membership-request') return;
    final token = uri.pathSegments.isEmpty ? null : uri.pathSegments.first;
    if (token == null || token.isEmpty || token.length > 200) return;
    pendingMembershipRequestToken = token;
    pendingMembershipRequestPreview = null;
    notifyListeners();
    await resolvePendingMembershipRequest();
  }

  Future<void> resolvePendingMembershipRequest() async {
    final token = pendingMembershipRequestToken;
    if (!authenticated || token == null) return;
    final ownerVaults = vaults.where((vault) => vault.isOwner);
    final ownerVault = ownerVaults.isEmpty ? null : ownerVaults.first;
    if (ownerVault == null) {
      errorMessage = 'Vault를 소유한 계정만 멤버 요청 링크를 열 수 있어요.';
      notifyListeners();
      return;
    }
    try {
      if (selectedVault?.id != ownerVault.id) {
        selectedVault = ownerVault;
        devices = ownerVault.devices
            .map((binding) => binding.device)
            .toList(growable: false);
        selectedDevice = devices.isEmpty ? null : devices.first;
        await (selectedDevice == null
            ? refreshVaultData()
            : refreshDeviceData());
      }
      pendingMembershipRequestPreview = await api.previewMembershipRequest(
        token,
      );
      errorMessage = null;
    } on ApiFailure catch (error) {
      pendingMembershipRequestToken = null;
      pendingMembershipRequestPreview = null;
      errorMessage = error.message;
    }
    notifyListeners();
  }

  Future<bool> revokeInvitation(Invitation invitation) async =>
      _guard(() async {
        final vault = selectedVault;
        if (vault == null || !vault.isOwner) return;
        await api.revokeVaultInvitation(vault.id, invitation.id);
        sentInvitations = sentInvitations
            .where((item) => item.id != invitation.id)
            .toList(growable: false);
        notifyListeners();
      });

  Future<void> refreshMyInvitations() async {
    receivedInvitations = await api.listMyInvitations();
    notifyListeners();
  }

  Future<bool> acceptInvitation(Invitation invitation) async =>
      _guard(() async {
        await api.acceptInvitation(invitation.id);
        receivedInvitations = receivedInvitations
            .where((item) => item.id != invitation.id)
            .toList(growable: false);
        await refreshDevices();
      });

  Future<bool> declineInvitation(Invitation invitation) async =>
      _guard(() async {
        await api.declineInvitation(invitation.id);
        receivedInvitations = receivedInvitations
            .where((item) => item.id != invitation.id)
            .toList(growable: false);
        notifyListeners();
      });

  Future<bool> revokeMemberAccess(DeviceMember member) async =>
      _guard(() async {
        final vault = selectedVault;
        if (vault == null || !vault.isOwner) return;
        await api.revokeVaultMember(vault.id, member.id);
        await (selectedDevice == null
            ? refreshVaultData()
            : refreshDeviceData());
      });

  @Deprecated('Use revokeMemberAccess')
  Future<bool> revoke(DeviceMember member) async {
    return revokeMemberAccess(member);
  }

  Future<bool> transferOwnership(DeviceMember member) async => _guard(() async {
    final vault = selectedVault;
    if (vault == null || !vault.isOwner) return;
    await api.transferVaultOwnership(vault.id, member.id);
    await refreshAll();
  });

  void clearError() {
    errorMessage = null;
    notifyListeners();
  }

  Future<bool> _guard(
    Future<void> Function() action, {
    String Function(ApiFailure error)? failureMessage,
  }) async {
    if (busy) return false;
    busy = true;
    errorMessage = null;
    notifyListeners();
    try {
      await action();
      return true;
    } on ApiFailure catch (error) {
      errorMessage = failureMessage?.call(error) ?? error.message;
      return false;
    } catch (_) {
      errorMessage = '예상하지 못한 문제가 생겼어요. 잠시 후 다시 시도해 주세요.';
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  void _reset() {
    authenticated = false;
    user = null;
    vaults = const [];
    selectedVault = null;
    devices = const [];
    selectedDevice = null;
    videos = const [];
    members = const [];
    sentInvitations = const [];
    receivedInvitations = const [];
    pendingMembershipRequestToken = null;
    pendingMembershipRequestPreview = null;
    openFamilyAfterDeviceClaim = false;
    deviceStatus = null;
    videoStats = null;
    homeSummary = null;
  }
}
