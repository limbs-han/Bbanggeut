import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api_client.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
}

class PushMessageData {
  const PushMessageData({
    required this.title,
    required this.body,
    required this.type,
    this.resourceId,
    this.deviceId,
  });

  final String title;
  final String body;
  final String type;
  final String? resourceId;
  final String? deviceId;

  factory PushMessageData.fromRemoteMessage(RemoteMessage message) {
    final data = message.data;
    return PushMessageData(
      title: message.notification?.title ?? data['title'] ?? '빵긋',
      body: message.notification?.body ?? data['body'] ?? '새 알림이 도착했어요.',
      type: data['type'] ?? '',
      resourceId: data['resourceId'],
      deviceId: data['deviceId'],
    );
  }
}

class PushNotificationService {
  PushNotificationService._();

  static final PushNotificationService shared = PushNotificationService._();
  static const _storage = FlutterSecureStorage();
  static const _installationIdKey = 'wj_push_installation_id';

  final _foregroundMessages = StreamController<PushMessageData>.broadcast();
  final _openedMessages = StreamController<PushMessageData>.broadcast();
  StreamSubscription<RemoteMessage>? _foregroundSubscription;
  StreamSubscription<RemoteMessage>? _openedSubscription;
  StreamSubscription<String>? _tokenSubscription;
  ApiClient? _activeApi;
  String? _installationId;
  PushMessageData? _initialMessage;

  bool available = false;
  String? initializationError;

  Stream<PushMessageData> get foregroundMessages => _foregroundMessages.stream;
  Stream<PushMessageData> get openedMessages => _openedMessages.stream;

  Future<void> bootstrap() async {
    if (available || initializationError != null) return;
    if (!Platform.isAndroid && !Platform.isIOS) return;
    try {
      await Firebase.initializeApp();
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission(alert: true, badge: true, sound: true);
      await messaging.setForegroundNotificationPresentationOptions(
        alert: false,
        badge: true,
        sound: false,
      );
      _foregroundSubscription = FirebaseMessaging.onMessage.listen(
        (message) =>
            _foregroundMessages.add(PushMessageData.fromRemoteMessage(message)),
      );
      _openedSubscription = FirebaseMessaging.onMessageOpenedApp.listen(
        (message) =>
            _openedMessages.add(PushMessageData.fromRemoteMessage(message)),
      );
      final initial = await messaging.getInitialMessage();
      if (initial != null) {
        _initialMessage = PushMessageData.fromRemoteMessage(initial);
      }
      _tokenSubscription = messaging.onTokenRefresh.listen(_registerToken);
      available = true;
    } catch (error) {
      initializationError = '$error';
    }
  }

  PushMessageData? takeInitialMessage() {
    final message = _initialMessage;
    _initialMessage = null;
    return message;
  }

  Future<void> activate(ApiClient api) async {
    _activeApi = api;
    if (!available) return;
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null && token.isNotEmpty) await _registerToken(token);
    } catch (_) {
      // 푸시 설정 오류가 로그인과 앱 초기화를 막아서는 안 된다.
    }
  }

  Future<void> deactivate(ApiClient api) async {
    final installationId = await _getInstallationId(create: false);
    _activeApi = null;
    if (installationId == null) return;
    try {
      await api.unregisterPushToken(installationId);
    } catch (_) {
      // 로그아웃은 토큰 해제 실패와 무관하게 계속되어야 한다.
    }
  }

  Future<void> _registerToken(String token) async {
    final api = _activeApi;
    if (api == null || token.isEmpty) return;
    final installationId = await _getInstallationId();
    if (installationId == null) return;
    try {
      await api.registerPushToken(
        installationId: installationId,
        token: token,
        platform: Platform.isIOS ? 'IOS' : 'ANDROID',
      );
    } catch (_) {
      // 다음 로그인, 앱 시작 또는 FCM 토큰 갱신 때 다시 등록한다.
    }
  }

  Future<String?> _getInstallationId({bool create = true}) async {
    if (_installationId != null) return _installationId;
    try {
      final stored = await _storage.read(key: _installationIdKey);
      if (stored != null && stored.isNotEmpty) {
        _installationId = stored;
        return stored;
      }
      if (!create) return null;
      final random = Random.secure();
      final bytes = List<int>.generate(24, (_) => random.nextInt(256));
      final generated = base64Url.encode(bytes).replaceAll('=', '');
      await _storage.write(key: _installationIdKey, value: generated);
      _installationId = generated;
      return generated;
    } catch (_) {
      return null;
    }
  }

  Future<void> dispose() async {
    await _foregroundSubscription?.cancel();
    await _openedSubscription?.cancel();
    await _tokenSubscription?.cancel();
    await _foregroundMessages.close();
    await _openedMessages.close();
  }
}
