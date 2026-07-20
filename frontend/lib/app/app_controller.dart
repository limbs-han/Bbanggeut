import 'package:flutter/foundation.dart';

import '../core/api_client.dart';
import '../core/models.dart';

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
  List<VideoMemory> videos = const [];
  List<DeviceMember> members = const [];
  List<JoinRequestInfo> joinRequests = const [];

  Future<void> initialize() async {
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

  Future<void> selectDevice(DeviceSummary device) async {
    selectedDevice = device;
    notifyListeners();
    await refreshDeviceData();
  }

  Future<void> refreshDeviceData() async {
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
    ]);
    deviceStatus = results[0] as DeviceStatus;
    videoStats = results[1] as VideoStats;
    videos = (results[2] as VideoPage).items;
    members = results[3] as List<DeviceMember>;
    joinRequests = results[4] as List<JoinRequestInfo>;
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
  }
}
