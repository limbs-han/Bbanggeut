import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api_client.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
}

/// 앱이 떠 있는 동안 직접 띄우는 알림이 들어갈 안드로이드 채널.
///
/// **왜 채널을 우리가 만드나**: FCM은 앱이 포그라운드일 때 알림 표시줄에
/// 아무것도 띄우지 않고 `onMessage`만 부른다. 그래서 앱을 켜 둔 사용자는
/// 휴대폰 알림이 오지 않는 것으로 느꼈다. 포그라운드 알림은 앱이 스스로
/// 띄워야 하고, 그러려면 채널이 미리 있어야 한다.
///
/// 이 채널 id는 `AndroidManifest.xml`의
/// `com.google.firebase.messaging.default_notification_channel_id`와 같은
/// 값이다. 백그라운드에서 OS가 띄우는 알림도 같은 채널로 모아야 소리·중요도
/// 설정이 한 벌이고, 시스템 알림 설정에도 '빵긋 알림' 하나만 보인다.
const _pushChannel = AndroidNotificationChannel(
  'bbanggeut_push',
  '빵긋 알림',
  description: '새 추억, 초대, 만화 완성 등 빵긋이 보내는 알림',
  // 화면 위로 잠깐 떠오르는(heads-up) 알림은 high부터다. default로 두면
  // 알림 표시줄에만 조용히 쌓여서, 앱을 보고 있는 사용자는 여전히 못 본다.
  importance: Importance.high,
);

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

  /// 시스템 알림의 payload로 실어 보낼 형태.
  ///
  /// 포그라운드에서 우리가 띄운 알림을 누르면 FCM이 아니라 로컬 알림 플러그인이
  /// 콜백을 준다. 그때는 원래의 `RemoteMessage`가 없으므로, 목적지를 정하는 데
  /// 필요한 값을 알림에 붙여 두었다가 그대로 되받는다.
  Map<String, String> toPayload() => {
    'title': title,
    'body': body,
    'type': type,
    'resourceId': ?resourceId,
    'deviceId': ?deviceId,
  };

  static PushMessageData? fromPayload(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map) return null;
      return PushMessageData(
        title: decoded['title'] as String? ?? '빵긋',
        body: decoded['body'] as String? ?? '새 알림이 도착했어요.',
        type: decoded['type'] as String? ?? '',
        resourceId: decoded['resourceId'] as String?,
        deviceId: decoded['deviceId'] as String?,
      );
    } catch (_) {
      // 알아볼 수 없는 payload로 알림 누르기를 죽이지 않는다.
      return null;
    }
  }
}

class PushNotificationService {
  PushNotificationService._();

  static final PushNotificationService shared = PushNotificationService._();
  static const _storage = FlutterSecureStorage();
  static const _installationIdKey = 'wj_push_installation_id';

  final _openedMessages = StreamController<PushMessageData>.broadcast();
  final _localNotifications = FlutterLocalNotificationsPlugin();
  StreamSubscription<RemoteMessage>? _foregroundSubscription;
  StreamSubscription<RemoteMessage>? _openedSubscription;
  StreamSubscription<String>? _tokenSubscription;
  ApiClient? _activeApi;
  String? _installationId;
  PushMessageData? _initialMessage;
  int _notificationId = 0;

  bool available = false;
  String? initializationError;

  Stream<PushMessageData> get openedMessages => _openedMessages.stream;

  Future<void> bootstrap() async {
    if (available || initializationError != null) return;
    if (!Platform.isAndroid && !Platform.isIOS) return;
    try {
      await Firebase.initializeApp();
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission(alert: true, badge: true, sound: true);
      // iOS는 이 옵션만 켜면 OS가 포그라운드에서도 알림을 띄워 준다. 안드로이드
      // 에는 대응하는 스위치가 없어 `_showSystemNotification`이 대신한다.
      await messaging.setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );
      await _setUpLocalNotifications();
      _foregroundSubscription = FirebaseMessaging.onMessage.listen(
        (message) => unawaited(
          _showSystemNotification(PushMessageData.fromRemoteMessage(message)),
        ),
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

  /// 포그라운드 알림을 우리가 띄우기 위한 준비 — 안드로이드 전용이다.
  ///
  /// iOS는 `setForegroundNotificationPresentationOptions`로 이미 OS가 띄우므로
  /// 여기서 또 띄우면 같은 알림이 두 번 보인다.
  Future<void> _setUpLocalNotifications() async {
    if (!Platform.isAndroid) return;
    await _localNotifications.initialize(
      // 상태 표시줄 아이콘은 백그라운드에서 FCM이 쓰는 기본값과 같은 앱
      // 아이콘으로 맞춘다 — 앱을 켜 뒀는지에 따라 알림 모양이 달라지면 안 된다.
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      onDidReceiveNotificationResponse: _handleLocalNotificationTap,
    );
    await _localNotifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(_pushChannel);
    // 앱이 떠 있을 때 띄운 알림을 사용자가 앱을 내린 뒤에 누르면, 앱이 새로
    // 뜨는 길이라 위의 콜백이 오지 않는다. 그 경우는 여기서 주워 온다.
    final launch = await _localNotifications.getNotificationAppLaunchDetails();
    if (launch != null && launch.didNotificationLaunchApp) {
      _initialMessage ??= PushMessageData.fromPayload(
        launch.notificationResponse?.payload,
      );
    }
  }

  void _handleLocalNotificationTap(NotificationResponse response) {
    final message = PushMessageData.fromPayload(response.payload);
    if (message != null) _openedMessages.add(message);
  }

  /// 앱이 포그라운드일 때 도착한 알림을 휴대폰 알림 표시줄에 띄운다.
  Future<void> _showSystemNotification(PushMessageData message) async {
    if (!Platform.isAndroid) return;
    try {
      // 같은 id를 다시 쓰면 앞의 알림을 덮어쓴다. 연달아 온 알림이 서로를
      // 지우지 않도록 매번 새 id를 쓰되, 안드로이드 알림 id는 32비트 정수라
      // 오래 켜 둔 앱에서 넘치지 않게 돌려 쓴다.
      _notificationId = (_notificationId + 1) % 0x7FFFFFFF;
      await _localNotifications.show(
        id: _notificationId,
        title: message.title,
        body: message.body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _pushChannel.id,
            _pushChannel.name,
            channelDescription: _pushChannel.description,
            importance: Importance.high,
            priority: Priority.high,
            // 알림 제목·본문이 길면 접힌 줄에서 잘린다. 펼치면 다 보이게 한다.
            styleInformation: BigTextStyleInformation(message.body),
          ),
        ),
        payload: jsonEncode(message.toPayload()),
      );
    } catch (_) {
      // 알림을 못 띄우는 것이 앱을 멈출 이유는 아니다. 알림함에는 남아 있다.
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
    await _openedMessages.close();
  }
}
