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
      authenticated = true;
      user = const UserProfile(
        id: 'local-demo-user',
        email: 'local@homecam.dev',
        displayName: '테스트 사용자',
      );
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
  }) async => _guard(() async {
    final session = await api.login(
      email,
      password,
      persistSession: persistSession,
    );
    user = session.user;
    authenticated = true;
    await refreshAll();
    await resolvePendingMembershipRequest();
  });

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

  Future<void> refreshAll() async {
    receivedInvitations = await api.listMyInvitations();
    await refreshDevices();
  }

  Future<void> refreshDevices() async {
    devices = await api.listDevices();
    if (devices.isEmpty) {
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
    final previousId = selectedDevice?.id;
    selectedDevice = devices.firstWhere(
      (item) => item.id == previousId,
      orElse: () => devices.first,
    );
    await refreshDeviceData();
  }

  Future<HomeSummary?> _loadHomeSummary(String deviceId) async {
    try {
      return await api.getHomeSummary(deviceId);
    } catch (_) {
      return null;
    }
  }

  Future<void> selectDevice(DeviceSummary device) async {
    selectedDevice = device;
    notifyListeners();
    await refreshDeviceData();
  }

  Future<void> refreshDeviceData() async {
    if (devHomeCam && devHlsUrl.isNotEmpty) {
      notifyListeners();
      return;
    }
    final device = selectedDevice;
    if (device == null) return;
    final results = await Future.wait<Object?>([
      api.getDeviceStatus(device.id),
      api.getVideoStats(device.id),
      api.listAllVideos(device.id),
      api.listMembers(device.id),
      if (device.isOwner)
        api.listDeviceInvitations(device.id)
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

  Future<bool> claimDevice(String code) async => _guard(() async {
    final claimed = await api.claimDevice(code);
    devices = [...devices, claimed];
    selectedDevice = claimed;
    await refreshDeviceData();
  });

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

    devices = devices
        .where((item) => item.id != device.id)
        .toList(growable: false);
    selectedDevice = devices.isEmpty ? null : devices.first;
    deviceStatus = null;
    videoStats = null;
    homeSummary = null;
    videos = const [];
    members = const [];
    sentInvitations = const [];

    if (selectedDevice != null) {
      try {
        await refreshDeviceData();
      } catch (_) {
        // 기기 해제는 끝났으므로 다른 기기의 새로고침 실패와 분리한다.
      }
    }
    notifyListeners();
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

  Future<bool> createInvitation(String email) async => _guard(() async {
    final device = selectedDevice;
    if (device == null || !device.isOwner) return;
    final requestToken =
        pendingMembershipRequestPreview?.email.toLowerCase() ==
            email.trim().toLowerCase()
        ? pendingMembershipRequestToken
        : null;
    await api.createInvitation(
      device.id,
      email,
      membershipRequestToken: requestToken,
    );
    if (requestToken != null) {
      pendingMembershipRequestToken = null;
      pendingMembershipRequestPreview = null;
    }
    sentInvitations = await api.listDeviceInvitations(device.id);
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
    final ownerDevices = devices.where((device) => device.isOwner);
    final ownerDevice = ownerDevices.isEmpty ? null : ownerDevices.first;
    if (ownerDevice == null) {
      errorMessage = '기기를 소유한 계정만 멤버 요청 링크를 열 수 있어요.';
      notifyListeners();
      return;
    }
    try {
      if (selectedDevice?.id != ownerDevice.id) {
        selectedDevice = ownerDevice;
        await refreshDeviceData();
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
        final device = selectedDevice;
        if (device == null || !device.isOwner) return;
        await api.revokeInvitation(device.id, invitation.id);
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
        await api.revokeMember(selectedDevice!.id, member.id);
        await refreshDeviceData();
      });

  @Deprecated('Use revokeMemberAccess')
  Future<bool> revoke(DeviceMember member) async {
    return revokeMemberAccess(member);
  }

  Future<bool> transferOwnership(DeviceMember member) async => _guard(() async {
    await api.transferOwnership(selectedDevice!.id, member.id);
    await refreshAll();
  });

  void clearError() {
    errorMessage = null;
    notifyListeners();
  }

  Future<bool> _guard(Future<void> Function() action) async {
    busy = true;
    errorMessage = null;
    notifyListeners();
    try {
      await action();
      return true;
    } on ApiFailure catch (error) {
      errorMessage = error.message;
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
    devices = const [];
    selectedDevice = null;
    videos = const [];
    members = const [];
    sentInvitations = const [];
    receivedInvitations = const [];
    pendingMembershipRequestToken = null;
    pendingMembershipRequestPreview = null;
    deviceStatus = null;
    videoStats = null;
    homeSummary = null;
  }
}
