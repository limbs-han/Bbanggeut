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
  List<JoinRequestInfo> joinRequests = const [];

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
      try {
        await refreshAll();
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

  Future<bool> login(String email, String password) async => _guard(() async {
    final session = await api.login(email, password);
    user = session.user;
    authenticated = true;
    await refreshAll();
  });

  Future<bool> signUp(String name, String email, String password) async =>
      _guard(() async {
        final session = await api.signUp(name, email, password);
        user = session.user;
        authenticated = true;
        await refreshAll();
      });

  Future<void> logout() async {
    busy = true;
    notifyListeners();
    await api.logout();
    _reset();
    busy = false;
    notifyListeners();
  }

  Future<void> withdraw() async {
    await api.withdraw();
    _reset();
    notifyListeners();
  }

  Future<void> refreshAll() async {
    devices = await api.listDevices();
    if (devices.isEmpty) {
      selectedDevice = null;
      videos = const [];
      members = const [];
      joinRequests = const [];
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
      api.listVideos(device.id),
      api.listMembers(device.id),
      if (device.isOwner)
        api.listJoinRequests(device.id)
      else
        Future.value(<JoinRequestInfo>[]),
      // Home summary is best-effort so a summary hiccup never blanks the tab.
      _loadHomeSummary(device.id),
    ]);
    deviceStatus = results[0] as DeviceStatus;
    videoStats = results[1] as VideoStats;
    videos = (results[2] as VideoPage).items;
    members = results[3] as List<DeviceMember>;
    joinRequests = results[4] as List<JoinRequestInfo>;
    homeSummary = results[5] as HomeSummary?;
    notifyListeners();
  }

  Future<bool> claimDevice(String code) async => _guard(() async {
    final claimed = await api.claimDevice(code);
    devices = [...devices, claimed];
    selectedDevice = claimed;
    await refreshDeviceData();
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

  Future<bool> approve(JoinRequestInfo request) async => _guard(() async {
    await api.approveJoinRequest(selectedDevice!.id, request.id);
    await refreshDeviceData();
  });

  Future<bool> reject(JoinRequestInfo request) async => _guard(() async {
    await api.rejectJoinRequest(selectedDevice!.id, request.id);
    await refreshDeviceData();
  });

  Future<bool> revoke(DeviceMember member) async => _guard(() async {
    await api.revokeMember(selectedDevice!.id, member.id);
    await refreshDeviceData();
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
    joinRequests = const [];
    deviceStatus = null;
    videoStats = null;
    homeSummary = null;
  }
}
