import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/api_client.dart';
import '../core/models.dart';
import '../core/push_notification_service.dart';
import '../editor/edit_recommendation_client.dart';

const devHomeCam = bool.fromEnvironment('DEV_HOME_CAM');

class AppController extends ChangeNotifier {
  AppController({
    ApiClient? api,
    this.pushNotifications,
    FlutterSecureStorage? placeStorage,
  }) : api = api ?? ApiClient(),
       _placeStorage = placeStorage ?? const FlutterSecureStorage() {
    // 편집 서버(editor-api)는 백엔드와 같은 액세스 토큰을 요구한다.
    // 편집 관련 화면들이 각자 만드는 EditRecommendationClient에 세션을
    // 여기서 한 번 이어 준다.
    EditRecommendationClient.sessionToken = () => this.api.accessToken;
    EditRecommendationClient.sessionRefresh = () =>
        this.api.refreshAccessToken();
  }
  final ApiClient api;
  final PushNotificationService? pushNotifications;
  final FlutterSecureStorage _placeStorage;

  bool initialized = false;
  bool authenticated = false;
  bool requiresInitialDeviceRegistration = false;
  bool busy = false;
  bool videosLoading = false;
  String? errorMessage;
  String? videosError;
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
  final List<String> _placeNames = ['집'];
  String _selectedPlaceName = '집';
  final Map<String, String> _devicePlaces = {};
  final Map<String, List<String>> _deviceOrders = {};
  Future<void> _placePreferenceSave = Future.value();
  String? pendingMembershipRequestToken;
  MembershipRequestPreview? pendingMembershipRequestPreview;
  bool openHomeAfterDeviceClaim = false;

  bool get isOwner =>
      selectedVault?.isOwner ?? selectedDevice?.isOwner ?? false;
  bool get isMember => selectedVault != null && !selectedVault!.isOwner;
  bool get canRegisterDevice => selectedVault == null || isOwner;
  List<String> get placeNames => List.unmodifiable(_placeNames);
  String get selectedPlaceName => _selectedPlaceName;
  List<DeviceSummary> get devicesForSelectedPlace {
    final placeDevices = _userOrderedDevices(devices).where(
      (device) =>
          (_devicePlaces[device.id] ?? _placeNames.first) == _selectedPlaceName,
    );
    return _onlineFirst(placeDevices);
  }

  String get _deviceOrderScope => selectedVault?.id ?? 'user';

  List<DeviceSummary> _userOrderedDevices(Iterable<DeviceSummary> source) {
    final snapshot = source.toList(growable: false);
    final savedOrder = _deviceOrders[_deviceOrderScope];
    if (savedOrder == null) return snapshot;
    final remaining = {for (final device in snapshot) device.id: device};
    return List.unmodifiable([
      for (final id in savedOrder) ?remaining.remove(id),
      ...snapshot.where((device) => remaining.containsKey(device.id)),
    ]);
  }

  /// ONLINE과 OFFLINE 내부에서는 서버가 준 등록 순서를 그대로 유지한다.
  List<DeviceSummary> _onlineFirst(Iterable<DeviceSummary> source) {
    final snapshot = source.toList(growable: false);
    return List.unmodifiable([
      ...snapshot.where((device) => device.isOnline),
      ...snapshot.where((device) => !device.isOnline),
    ]);
  }

  DeviceSummary? _preferredDevice(
    List<DeviceSummary> candidates, {
    String? preserveId,
  }) {
    if (candidates.isEmpty) return null;
    if (preserveId != null) {
      for (final device in candidates) {
        if (device.id == preserveId) return device;
      }
    }
    for (final device in candidates) {
      if (device.isOnline) return device;
    }
    return candidates.first;
  }

  List<DeviceSummary> get _selectionCandidates {
    final placeDevices = devicesForSelectedPlace;
    return placeDevices.isEmpty
        ? _onlineFirst(_userOrderedDevices(devices))
        : placeDevices;
  }

  void _reconcileDeviceOrder() {
    final scope = _deviceOrderScope;
    final savedOrder = _deviceOrders[scope];
    if (savedOrder == null) return;
    final currentIds = devices.map((device) => device.id).toSet();
    final nextOrder = <String>[
      ...savedOrder.where(currentIds.contains),
      ...devices
          .map((device) => device.id)
          .where((id) => !savedOrder.contains(id)),
    ];
    if (listEquals(savedOrder, nextOrder)) return;
    _deviceOrders[scope] = nextOrder;
    unawaited(_savePlacePreferences());
    unawaited(_pushDeviceOrder());
  }

  void _syncPresenceStatus(
    DeviceSummary? device, {
    required bool preserveDetails,
  }) {
    if (device == null) {
      deviceStatus = null;
      return;
    }
    final previous = preserveDetails ? deviceStatus : null;
    deviceStatus = DeviceStatus(
      status: device.status,
      recording: previous?.recording ?? false,
      uploadQueueDepth: previous?.uploadQueueDepth ?? 0,
      bufferSeconds: previous?.bufferSeconds,
      personCount: previous?.personCount,
    );
  }

  String? get _placeStorageKey {
    final userId = user?.id;
    return userId == null ? null : 'bbanggeut_device_places_v1_$userId';
  }

  /// 장소 배치를 읽는다. 서버가 원본이고 로컬은 오프라인 사본이다.
  ///
  /// **왜 로컬을 남기는가**: 배치는 홈 화면이 처음 그려질 때 이미 필요하다.
  /// 서버 응답을 기다리면 기기 목록이 한 번 흔들리고, 비행기 모드에서는 아예
  /// 못 읽는다. 로컬로 먼저 그리고 서버 값이 오면 갈아 끼운다.
  ///
  /// 지금 보고 있는 장소(selectedPlace)는 화면 상태라 서버에 두지 않는다.
  Future<void> _loadPlacePreferences() async {
    await _loadLocalPlacePreferences();
    await _syncPlaceLayoutFromServer();
  }

  /// 서버 배치를 받아 반영한다. 서버가 비어 있으면 이 폰의 배치를 한 번 올린다.
  ///
  /// **왜 올려 주는가**: 서버화 이전에 각자 정리해 둔 배치가 있다. 그냥
  /// 서버 값(빈 목록)으로 덮으면 모두의 장소·순서가 기본값으로 초기화된다.
  Future<void> _syncPlaceLayoutFromServer() async {
    final vault = selectedVault;
    if (vault == null) return;
    try {
      final layout = await api.getPlaceLayout(vault.id);
      if (layout.isEmpty) {
        await _pushPlaceLayout();
        await _pushDeviceOrder();
        return;
      }
      _placeNames
        ..clear()
        ..addAll(layout.places);
      _devicePlaces
        ..clear()
        ..addAll(layout.devicePlaces);
      if (layout.deviceOrder.isNotEmpty) {
        _deviceOrders[vault.id] = List<String>.of(layout.deviceOrder);
      }
      if (!_placeNames.contains(_selectedPlaceName)) {
        _selectedPlaceName = _placeNames.first;
      }
      unawaited(_savePlacePreferences());
      notifyListeners();
    } on ApiFailure {
      // 오프라인이면 로컬 사본으로 계속 쓴다.
    }
  }

  Future<void> _pushPlaceLayout() async {
    final vault = selectedVault;
    if (vault == null) return;
    try {
      await api.replacePlaceLayout(
        vault.id,
        places: List<String>.of(_placeNames),
        devicePlaces: Map<String, String>.of(_devicePlaces),
      );
    } on ApiFailure {
      // 로컬에는 남아 있다. 다음 진입에서 다시 맞춘다.
    }
  }

  Future<void> _pushDeviceOrder() async {
    final vault = selectedVault;
    if (vault == null) return;
    final order = _deviceOrders[vault.id];
    if (order == null || order.isEmpty) return;
    try {
      await api.replaceDeviceOrder(vault.id, List<String>.of(order));
    } on ApiFailure {
      // 로컬에는 남아 있다.
    }
  }

  Future<void> _loadLocalPlacePreferences() async {
    final key = _placeStorageKey;
    if (key == null) return;
    try {
      final raw = await _placeStorage.read(key: key);
      if (raw == null) return;
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final places = (decoded['places'] as List? ?? const [])
          .whereType<String>()
          .map((place) => place.trim())
          .where((place) => place.isNotEmpty)
          .toSet()
          .toList();
      _placeNames
        ..clear()
        ..addAll(places.isEmpty ? const ['집'] : places);
      _devicePlaces
        ..clear()
        ..addAll(
          (decoded['devicePlaces'] as Map<String, dynamic>? ?? const {}).map(
            (deviceId, place) => MapEntry(deviceId, place.toString()),
          ),
        );
      _deviceOrders.clear();
      final savedOrders = decoded['deviceOrders'];
      if (savedOrders is Map<String, dynamic>) {
        for (final entry in savedOrders.entries) {
          final ids = (entry.value as List? ?? const [])
              .whereType<String>()
              .where((id) => id.isNotEmpty)
              .toSet()
              .toList();
          _deviceOrders[entry.key] = ids;
        }
      }
      final selected = decoded['selectedPlace'] as String?;
      _selectedPlaceName = _placeNames.contains(selected)
          ? selected!
          : _placeNames.first;
    } catch (_) {
      // 저장값이 없거나 손상돼도 기본 장소로 앱을 계속 사용할 수 있다.
    }
  }

  Future<void> _savePlacePreferences() {
    final key = _placeStorageKey;
    if (key == null) return Future.value();
    final value = jsonEncode({
      'places': List<String>.of(_placeNames),
      'selectedPlace': _selectedPlaceName,
      'devicePlaces': Map<String, String>.of(_devicePlaces),
      'deviceOrders': {
        for (final entry in _deviceOrders.entries)
          entry.key: List<String>.of(entry.value),
      },
    });
    _placePreferenceSave = _placePreferenceSave.then((_) async {
      try {
        await _placeStorage.write(key: key, value: value);
      } catch (_) {
        // 장소 저장 실패가 기기 연결 자체를 실패시키지는 않는다.
      }
    });
    return _placePreferenceSave;
  }

  @visibleForTesting
  Future<void> waitForPlacePreferencesSaved() => _placePreferenceSave;

  @visibleForTesting
  Future<void> loadPlacePreferencesForTesting() => _loadPlacePreferences();

  void selectPlace(String placeName) {
    final normalized = placeName.trim();
    if (!_placeNames.contains(normalized)) return;
    _selectedPlaceName = normalized;
    final placeDevices = devicesForSelectedPlace;
    if (placeDevices.isNotEmpty &&
        !placeDevices.any((device) => device.id == selectedDevice?.id)) {
      selectedDevice = _preferredDevice(placeDevices);
      deviceStatus = null;
      videoStats = null;
      homeSummary = null;
      unawaited(refreshDeviceData().catchError((_) {}));
    }
    unawaited(_savePlacePreferences());
    notifyListeners();
  }

  void assignDeviceToPlace(String deviceId, String placeName) {
    final normalized = placeName.trim();
    if (!_placeNames.contains(normalized) ||
        !devices.any((device) => device.id == deviceId)) {
      return;
    }
    _devicePlaces[deviceId] = normalized;
    unawaited(_savePlacePreferences());
    unawaited(_pushPlaceLayout());
    notifyListeners();
  }

  void reorderDeviceForSelectedPlace({
    required String deviceId,
    String? beforeDeviceId,
  }) {
    final visibleDevices = devicesForSelectedPlace;
    final visibleIds = visibleDevices.map((device) => device.id).toList();
    if (!visibleIds.remove(deviceId) || beforeDeviceId == deviceId) return;
    if (beforeDeviceId == null) {
      visibleIds.add(deviceId);
    } else {
      final targetIndex = visibleIds.indexOf(beforeDeviceId);
      if (targetIndex < 0) return;
      visibleIds.insert(targetIndex, deviceId);
    }

    final placeIds = visibleIds.toSet();
    final reordered = visibleIds.iterator;
    final baseOrder = _userOrderedDevices(
      devices,
    ).map((device) => device.id).toList();
    _deviceOrders[_deviceOrderScope] = [
      for (final id in baseOrder)
        if (placeIds.contains(id)) (reordered..moveNext()).current else id,
    ];
    unawaited(_savePlacePreferences());
    unawaited(_pushDeviceOrder());
    notifyListeners();
  }

  bool addPlace(String placeName) {
    final normalized = placeName.trim();
    if (normalized.isEmpty ||
        normalized.length > 15 ||
        _placeNames.any(
          (place) => place.toLowerCase() == normalized.toLowerCase(),
        )) {
      return false;
    }
    _placeNames.add(normalized);
    _selectedPlaceName = normalized;
    unawaited(_savePlacePreferences());
    unawaited(_pushPlaceLayout());
    notifyListeners();
    return true;
  }

  Future<void> initialize() async {
    if (devHomeCam) {
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
        // 저장한 장소와 기기 순서를 먼저 복원해야 서버 목록의 기본 선택도
        // 사용자가 정한 순서를 따른다.
        await _loadPlacePreferences();
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
      if (authenticated) _activatePushInBackground();
    }
    initialized = true;
    notifyListeners();
  }

  /// 푸시 등록을 시작하고 **기다리지 않는다.**
  ///
  /// **왜**: `activate`는 FCM 토큰을 받아 서버에 올리는 일이다. 토큰 발급은 네트워크
  /// 상태에 따라 몇 초가 걸리는데, 화면에 바꾸는 것은 하나도 없고 실패도 스스로
  /// 삼킨다. 그런데 이걸 기다리는 동안 [initialized]가 false여서 스플래시가 그대로
  /// 떠 있었고, 로그인 버튼도 계속 돌고 있었다 — 앱이 안 켜지는 것처럼 보이던
  /// 시간의 정체다. 등록은 그대로 일어나고, 다음 앱 시작이나 토큰 갱신 때 다시
  /// 시도하므로 놓칠 일도 없다.
  void _activatePushInBackground() {
    final activation = pushNotifications?.activate(api);
    if (activation != null) unawaited(activation);
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
      await _loadPlacePreferences();
      await refreshAll();
      await resolvePendingMembershipRequest();
      requiresInitialDeviceRegistration = false;
      authenticated = true;
      _activatePushInBackground();
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
    await _loadPlacePreferences();
    await refreshAll();
    await resolvePendingMembershipRequest();
    requiresInitialDeviceRegistration = selectedDevice == null;
    authenticated = true;
    _activatePushInBackground();
  });

  Future<void> logout() async {
    busy = true;
    notifyListeners();
    try {
      await pushNotifications?.deactivate(api);
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
    await pushNotifications?.deactivate(api);
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

  /// 받은 초대와 Vault 목록을 **나란히** 불러온다.
  ///
  /// **왜**: 두 요청은 서로의 결과를 쓰지 않는다. 차례로 부르면 왕복이 한 번 더
  /// 늘고, 그 시간은 그대로 스플래시·로그인 대기 시간이 된다. Vault 쪽은 이어서
  /// 기기·영상·멤버를 또 불러오므로 초대를 먼저 기다릴 이유가 없다.
  Future<void> refreshAll() async {
    final results = await Future.wait<Object?>([
      api.listMyInvitations(),
      refreshVaults(),
    ]);
    receivedInvitations = results[0] as List<Invitation>;
    // Vault 쪽이 중간에 알린 뒤에 초대가 들어오므로 한 번 더 알린다.
    notifyListeners();
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
    _reconcileDeviceOrder();
    selectedDevice = _preferredDevice(
      _selectionCandidates,
      preserveId: previousDeviceId,
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

  /// Device presence is a Redis key with a heartbeat TTL, so the ONLINE flag
  /// received at startup goes stale within minutes and the app would keep
  /// offering live view for a camera that is gone. Re-read the vault list only,
  /// leaving videos, members and invitations untouched.
  Future<void> refreshPresence() async {
    if (!authenticated) return;
    final List<MemoryVault> latest;
    try {
      latest = await api.listVaults();
    } catch (_) {
      // Presence is best effort; keep showing the last known state.
      return;
    }
    if (latest.isEmpty) return;
    vaults = latest;
    final vaultId = selectedVault?.id;
    if (vaultId == null) return;
    MemoryVault? current;
    for (final vault in latest) {
      if (vault.id == vaultId) {
        current = vault;
        break;
      }
    }
    if (current == null) return;
    selectedVault = current;
    devices = current.devices
        .map((binding) => binding.device)
        .toList(growable: false);
    _reconcileDeviceOrder();
    final deviceId = selectedDevice?.id;
    selectedDevice = _preferredDevice(
      _selectionCandidates,
      preserveId: deviceId,
    );
    final selectionChanged = selectedDevice?.id != deviceId;
    _syncPresenceStatus(selectedDevice, preserveDetails: !selectionChanged);
    if (selectionChanged) {
      videoStats = null;
      homeSummary = null;
    }
    notifyListeners();
  }

  Future<void> refreshVaultData() async {
    final vault = selectedVault;
    if (vault == null) return;
    videosLoading = true;
    videosError = null;
    notifyListeners();
    try {
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
    } on ApiFailure catch (error) {
      videosError = error.message;
      rethrow;
    } finally {
      videosLoading = false;
      notifyListeners();
    }
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
    _reconcileDeviceOrder();
    selectedDevice = _preferredDevice(_selectionCandidates);
    deviceStatus = null;
    videoStats = null;
    homeSummary = null;
    videos = const [];
    members = const [];
    sentInvitations = const [];
    notifyListeners();
    try {
      await (selectedDevice == null ? refreshVaultData() : refreshDeviceData());
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
    if (devHomeCam) {
      notifyListeners();
      return;
    }
    final device = selectedDevice;
    if (device == null) {
      await refreshVaultData();
      return;
    }
    final vault = selectedVault;
    videosLoading = true;
    videosError = null;
    notifyListeners();
    try {
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
    } on ApiFailure catch (error) {
      videosError = error.message;
      rethrow;
    } finally {
      videosLoading = false;
      notifyListeners();
    }
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
    String? placeName,
  }) async => _guard(() async {
    if (!canRegisterDevice) {
      throw const ApiFailure('OWNER만 새 기기를 등록할 수 있어요.', statusCode: 403);
    }
    final claimedDevice = await api.claimDevice(
      code,
      vaultId: vaultId,
      vaultName: vaultId == null ? newVaultName : null,
    );
    await refreshVaults();
    MemoryVault? claimedVault;
    for (final vault in vaults) {
      if (vault.devices.any(
        (binding) => binding.device.id == claimedDevice.id,
      )) {
        claimedVault = vault;
        break;
      }
    }
    if (claimedVault == null) {
      throw const ApiFailure('기기 연결 상태를 확인하지 못했어요. 잠시 후 다시 시도해 주세요.');
    }
    selectedVault = claimedVault;
    devices = claimedVault.devices
        .map((binding) => binding.device)
        .toList(growable: false);
    _reconcileDeviceOrder();
    selectedDevice = devices.firstWhere(
      (device) => device.id == claimedDevice.id,
    );
    assignDeviceToPlace(claimedDevice.id, placeName ?? _selectedPlaceName);
    await waitForPlacePreferencesSaved();
    await refreshDeviceData();
  });

  void completeDeviceRegistration() {
    requiresInitialDeviceRegistration = false;
    openHomeAfterDeviceClaim = true;
    notifyListeners();
  }

  bool consumeOpenHomeAfterDeviceClaim() {
    if (!openHomeAfterDeviceClaim) return false;
    openHomeAfterDeviceClaim = false;
    return true;
  }

  Future<bool> updateSelectedDevice({String? name, int? retentionDays}) async =>
      _guard(() async {
        final device = requireSelectedDevice('기기 설정을 바꿀 수 없어요.');
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
    final device = requireSelectedDevice('기기 연결을 해제할 수 없어요.');
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
    _replaceVideo(video.copyWith(favorite: !video.favorite));
  });

  /// 제목을 바꾸고 목록의 그 한 줄만 갈아 끼운다.
  ///
  /// **왜 다시 조회하지 않는가**: 예전에는 저장 뒤 그 영상을 다시 받고
  /// `refreshDeviceData()`까지 불러, 기기 상태·통계·목록·구성원·초대·홈 요약
  /// 여섯 요청이 끝날 때까지 화면이 예전 제목을 들고 기다렸다. 바뀐 값은 방금
  /// 우리가 보낸 그 값이라 서버에 되물을 이유가 없다.
  Future<bool> renameVideo(VideoMemory video, String title) async =>
      _guard(() async {
        await api.updateVideo(video.id, title: title);
        _replaceVideo(video.copyWith(title: title));
      });

  void _replaceVideo(VideoMemory updated) {
    final index = videos.indexWhere((item) => item.id == updated.id);
    if (index < 0) return;
    final next = [...videos];
    next[index] = updated;
    videos = next;
    notifyListeners();
  }

  Future<bool> createInvitation(String email, String role) async =>
      _guard(() async {
        final vault = requireOwnedVault('가족을 초대할 수 없어요.');
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
        _reconcileDeviceOrder();
        selectedDevice = _preferredDevice(_selectionCandidates);
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
        await refreshAll();
        final acceptedVaults = vaults.where(
          (vault) => vault.devices.any(
            (binding) => binding.device.id == invitation.deviceId,
          ),
        );
        if (acceptedVaults.isNotEmpty &&
            selectedVault?.id != acceptedVaults.first.id) {
          await selectVault(acceptedVaults.first);
        }
        notifyListeners();
      });

  Future<bool> declineInvitation(Invitation invitation) async =>
      _guard(() async {
        await api.declineInvitation(invitation.id);
        receivedInvitations = receivedInvitations
            .where((item) => item.id != invitation.id)
            .toList(growable: false);
        notifyListeners();
      });

  Future<bool> revokeMemberAccess(DeviceMember member) async => _guard(
    () async {
      final vault = requireOwnedVault('구성원을 내보낼 수 없어요.');
      await api.revokeVaultMember(vault.id, member.id);
      await (selectedDevice == null ? refreshVaultData() : refreshDeviceData());
    },
  );

  @Deprecated('Use revokeMemberAccess')
  Future<bool> revoke(DeviceMember member) async {
    return revokeMemberAccess(member);
  }

  Future<bool> transferOwnership(DeviceMember member) async => _guard(() async {
    final vault = requireOwnedVault('소유권을 이전할 수 없어요.');
    await api.transferVaultOwnership(vault.id, member.id);
    await refreshAll();
  });

  /// Throws instead of returning, so [_guard] reports the failure rather than
  /// leaving the caller to render a success message for work never done.
  MemoryVault requireOwnedVault(String whatFailed) {
    final vault = selectedVault;
    if (vault == null) {
      throw ApiFailure('금고를 먼저 선택해 주세요. $whatFailed');
    }
    if (!vault.isOwner) {
      throw ApiFailure('OWNER 권한이 필요해요. $whatFailed', statusCode: 403);
    }
    return vault;
  }

  DeviceSummary requireSelectedDevice(String whatFailed) {
    final device = selectedDevice;
    if (device == null) {
      throw ApiFailure('연결된 기기가 없어요. $whatFailed');
    }
    return device;
  }

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
    requiresInitialDeviceRegistration = false;
    _placeNames
      ..clear()
      ..add('집');
    _selectedPlaceName = '집';
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
    _devicePlaces.clear();
    _deviceOrders.clear();
    openHomeAfterDeviceClaim = false;
    deviceStatus = null;
    videoStats = null;
    homeSummary = null;
  }
}
